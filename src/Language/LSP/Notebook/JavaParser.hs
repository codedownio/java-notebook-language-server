-- | Talking to @java-parser@, which splits a document into top-level Java snippets and says
-- what each one is.
--
-- The other notebook language servers fork their parser once per projection. This one holds a
-- single process open for the life of the server instead, because the parser is a JVM: forking
-- costs ~350ms against ~4ms for a round trip on a warm process, and a projection happens on
-- every document change. See java-parser/src/JavaParser.java.
module Language.LSP.Notebook.JavaParser (
  Category(..)
  , Unit(..)

  , ParserClient
  , newParserClient
  , parseDocument
  , stubParserClient
  ) where

import Control.Monad.IO.Class
import Data.Aeson
import qualified Data.Binary.Builder as B
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.String.Interpolate
import Data.Text (Text)
import qualified Data.Text.Encoding as T
import System.IO
import UnliftIO.Exception
import UnliftIO.MVar
import UnliftIO.Process


-- | Where a snippet has to end up in the projected document.
data Category =
  -- | An import, which has to go above the synthetic class.
  CategoryImport
  -- | A type, method, or field with an explicit type: goes in the class body.
  | CategoryDeclaration
  -- | Executable code, legal as-is inside a method body.
  | CategoryStatement
  -- | Executable code that is not a statement -- a bare @x + 1@ -- so the projection has to
  -- wrap it in something that is.
  | CategoryExpression
  deriving (Show, Eq, Ord)

instance FromJSON Category where
  parseJSON = withText "Category" $ \case
    "IMPORT" -> pure CategoryImport
    "DECLARATION" -> pure CategoryDeclaration
    "STATEMENT" -> pure CategoryStatement
    "EXPRESSION" -> pure CategoryExpression
    other -> fail [i|Unknown snippet category: #{other}|]

-- | One top-level snippet. Lines and characters are 0-based, and characters are UTF-16 code
-- units, matching LSP.
data Unit = Unit {
  unitCategory :: Category
  -- | JShell's own name for the snippet kind, carried through for diagnostics and tests.
  , unitKind :: Text
  , unitSubKind :: Text
  , unitStartLine :: Int
  , unitStartCh :: Int
  , unitEndLine :: Int
  , unitEndCh :: Int
  } deriving (Show, Eq)

instance FromJSON Unit where
  parseJSON = withObject "Unit" $ \o -> Unit
    <$> o .: "category"
    <*> o .: "kind"
    <*> o .: "subKind"
    <*> o .: "startLine"
    <*> o .: "startCh"
    <*> o .: "endLine"
    <*> o .: "endCh"

-- | A handle on the parser. The 'MVar' is the request lock as well as the state: only one
-- round trip can be in flight, since the protocol has no request ids.
data ParserClient =
  ParserClient (MVar ParserProcess)
  -- | A canned response, for tests that shouldn't need a JVM.
  | StubParserClient (Text -> Either String [Unit])

data ParserProcess = ParserProcess {
  parserStdin :: Handle
  , parserStdout :: Handle
  , parserHandle :: ProcessHandle
  }

-- | Start @java-parser --serve@. The process lives until the server exits.
newParserClient :: MonadIO m => FilePath -> [String] -> m ParserClient
newParserClient path extraArgs = liftIO $ do
  (Just pIn, Just pOut, _, ph) <- createProcess (proc path (extraArgs <> ["--serve"])) {
    std_in = CreatePipe
    , std_out = CreatePipe
    -- Left inheriting the server's stderr, so a JVM stack trace shows up in the log rather
    -- than filling a pipe nobody drains.
    , std_err = Inherit
    , close_fds = True
    }
  hSetBinaryMode pIn True
  hSetBinaryMode pOut True
  hSetBuffering pIn (BlockBuffering Nothing)
  hSetBuffering pOut (BlockBuffering Nothing)
  ParserClient <$> newMVar (ParserProcess pIn pOut ph)

-- | A client that answers from a pure function, for tests.
stubParserClient :: (Text -> Either String [Unit]) -> ParserClient
stubParserClient = StubParserClient

-- | Split and classify a document. A 'Left' means the parser could not be reached or did not
-- answer in the expected shape; callers fall back to the identity projection rather than
-- guessing at a structure.
parseDocument :: MonadIO m => ParserClient -> Text -> m (Either String [Unit])
parseDocument (StubParserClient f) source = pure (f source)
parseDocument (ParserClient processVar) source = liftIO $ try go >>= \case
  Left (e :: SomeException) -> pure (Left [i|java-parser request failed: #{show e}|])
  Right x -> pure x
  where
    go = withMVar processVar $ \(ParserProcess {..}) -> do
      let payload = T.encodeUtf8 source
      BL.hPut parserStdin (B.toLazyByteString (B.putWord32be (fromIntegral (BS.length payload))))
      BS.hPut parserStdin payload
      hFlush parserStdin

      lengthBytes <- readExactly parserStdout 4
      let responseLength = BS.foldl' (\acc w -> acc * 256 + fromIntegral w) (0 :: Int) lengthBytes
      response <- readExactly parserStdout responseLength
      pure $ eitherDecodeStrict response

-- | 'BS.hGet' can return short reads on a pipe, and a short read here would desynchronise the
-- stream for every later request.
readExactly :: Handle -> Int -> IO BS.ByteString
readExactly h n
  | n <= 0 = pure BS.empty
  | otherwise = do
      chunk <- BS.hGet h n
      if BS.null chunk
        then throwIO (userError "java-parser closed its output stream")
        else if BS.length chunk == n
          then pure chunk
          else (chunk <>) <$> readExactly h (n - BS.length chunk)
