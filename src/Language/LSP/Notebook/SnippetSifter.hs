{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE TypeFamilies #-}

-- | Projecting a Java notebook into something javac will accept.
--
-- A cell is a sequence of JShell snippets in any order; a @.java@ file is imports, then one
-- type, with statements only inside methods. So the projection sorts snippets into the three
-- places a Java file has for them:
--
-- @
-- <imports>
-- class __Cells {
-- <types, methods and explicitly-typed fields>
-- void __notebookExec() throws Exception {
-- <statements, and expressions wrapped so they are statements>
-- }
-- }
-- @
--
-- Nothing is indented and every synthetic line is its own line, so no original line moves
-- sideways and position mapping is a pure line permutation.
module Language.LSP.Notebook.SnippetSifter (
  SnippetSifter(..)
  , SnippetSifterParams(..)

  , classLine
  , execLine
  , closeLine
  , expressionPrefix
  , expressionSuffix
  ) where

import Control.Monad.IO.Class
import Data.Function (on)
import qualified Data.List as L
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Data.Vector (Vector)
import qualified Data.Vector as V
import Language.LSP.Notebook.JavaParser
import Language.LSP.Protocol.Types
import Language.LSP.Transformer


-- | The projection, as the line permutation it amounts to. Both directions are kept so
-- mapping a position either way is O(1); it happens on every request and response.
data SnippetSifter = SnippetSifter {
  -- | @forward ! originalLine@ is the line it was projected to, or -1 if it was dropped.
  forward :: Vector Int
  -- | @inverse ! projectedLine@ is the line it came from, or -1 if it is synthetic.
  , inverse :: Vector Int
  } deriving (Show, Eq)

data SnippetSifterParams =
  SnippetSifterParams {
    parserClient :: ParserClient
    -- | Name of the synthetic class holding the notebook's declarations.
    , className :: Text
    -- | Name of the synthetic method holding the notebook's statements.
    , execMethodName :: Text
    }
  -- | Leave the document alone: a real @.java@ file is already a compilation unit. Explicit
  -- rather than a degenerate projection, so it stays out of the error path.
  | IdentityParams

instance Transformer SnippetSifter where
  type Params SnippetSifter = SnippetSifterParams

  transformPosition :: SnippetSifter -> Position -> Maybe Position
  transformPosition sifter (Position l c)
    | original < 0 || original >= V.length (forward sifter) = Nothing
    | projected < 0 = Nothing
    | otherwise = Just (Position (fromIntegral projected) c)
    where
      original = fromIntegral l
      projected = forward sifter V.! original

  untransformPosition :: SnippetSifter -> Position -> Maybe Position
  untransformPosition sifter (Position l c)
    | projected < 0 || projected >= V.length (inverse sifter) = Nothing
    | original < 0 = Nothing -- a synthetic line, which has nowhere to go in the notebook
    | otherwise = Just (Position (fromIntegral original) c)
    where
      projected = fromIntegral l
      original = inverse sifter V.! projected

instance MonadIO m => ProjectIn m SnippetSifter where
  project :: Params SnippetSifter -> Doc -> m (Doc, SnippetSifter, Either Text ())
  project IdentityParams doc =
    pure (doc, identitySifter (length (docToList doc)), Right ())
  project params doc = do
    let originalLines = docToList doc
        lineCount = length originalLines

    parseDocument (parserClient params) (T.intercalate "\n" originalLines) >>= \case
      -- Without the parser we don't know where anything goes. Passing the document through
      -- means the server's complaints are at least about lines the user can see.
      Left err -> pure (doc, identitySifter lineCount, Left (T.pack err))
      Right units -> do
        let plan = buildPlan params originalLines units
        pure (listToDoc (map pieceText plan), sifterFor lineCount plan, Right ())

-- | One line of the projected document, and which original line it came from.
data Piece = Piece {
  pieceText :: Text
  , pieceOrigin :: Maybe Int
  }

synthetic :: Text -> Piece
synthetic t = Piece t Nothing

fromOriginal :: [Text] -> Int -> Piece
fromOriginal originalLines i = Piece (originalLines !! i) (Just i)

classLine :: Text -> Text
classLine name = "class " <> name <> " {"

-- | @throws Exception@ so that calling a throwing method doesn't produce an error on every
-- such line, burying the diagnostics that matter.
execLine :: Text -> Text
execLine name = "void " <> name <> "() throws Exception {"

closeLine :: Text
closeLine = "}"

-- | A bare expression isn't a statement, so it gets assigned to something. Prefix and suffix
-- take their own lines, so the expression's lines keep their exact columns.
expressionPrefix :: Int -> Text
expressionPrefix n = "Object __expr" <> T.pack (show n) <> " ="

expressionSuffix :: Text
expressionSuffix = ";"

-- | Decide where every original line goes.
buildPlan :: SnippetSifterParams -> [Text] -> [Unit] -> [Piece]
buildPlan params originalLines units =
     map (fromOriginal originalLines) importLines
  <> [synthetic (classLine (className params))]
  <> map (fromOriginal originalLines) declarationLines
  <> [synthetic (execLine (execMethodName params))]
  <> bodyPieces
  <> [synthetic closeLine, synthetic closeLine]
  where
    lineCount = length originalLines
    categoryOf = lineCategories units lineCount

    importLines = [i | i <- [0 .. lineCount - 1], categoryOf i == Just CategoryImport]
    declarationLines = [i | i <- [0 .. lineCount - 1], categoryOf i == Just CategoryDeclaration]

    -- Everything else in original order, including lines no snippet claimed: they have to
    -- land somewhere for a position on them to map, and the body accepts anything.
    bodyLines = [i | i <- [0 .. lineCount - 1]
                   , categoryOf i /= Just CategoryImport
                   , categoryOf i /= Just CategoryDeclaration]

    -- Expressions wrap as a unit, so the body is built from runs rather than single lines.
    expressionSpans = M.fromList [(unitStartLine u, unitEndLine u)
                                 | u <- units, unitCategory u == CategoryExpression]

    -- Expressions are numbered among themselves rather than by position in the body, so that
    -- adding a blank line above one doesn't rename it.
    bodyPieces = go 0 (groupBodyLines bodyLines)
      where
        go _ [] = []
        go n (run : rest) = case run of
          (firstLine : _) | Just lastLine <- M.lookup firstLine expressionSpans
                          , L.last run == lastLine ->
            [synthetic (expressionPrefix n)]
            <> map (fromOriginal originalLines) run
            <> [synthetic expressionSuffix]
            <> go (n + 1) rest
          _ -> map (fromOriginal originalLines) run <> go n rest

    -- One run per expression span, single-line runs for everything else.
    groupBodyLines :: [Int] -> [[Int]]
    groupBodyLines [] = []
    groupBodyLines (i : rest) = case M.lookup i expressionSpans of
      Just end | end > i ->
        let (within, after) = L.span (<= end) rest
        in (i : within) : groupBodyLines after
      _ -> [i] : groupBodyLines rest

-- | Which category each original line belongs to, or 'Nothing' if no snippet covers it.
--
-- Two snippets can share a line (@int x = 1; x + 1@). The outermost placement wins: that can
-- strand a statement in the class body, but the alternative stranding an import inside the
-- class makes every name in the document unresolvable.
lineCategories :: [Unit] -> Int -> (Int -> Maybe Category)
lineCategories units lineCount = \i ->
  if i < 0 || i >= lineCount then Nothing else table V.! i
  where
    table = V.generate lineCount $ \i ->
      case [unitCategory u | u <- units, unitStartLine u <= i, i <= unitEndLine u] of
        [] -> Nothing
        cs -> Just (L.minimumBy (compare `on` placementRank) cs)

    placementRank :: Category -> Int
    placementRank CategoryImport = 0
    placementRank CategoryDeclaration = 1
    placementRank CategoryStatement = 2
    placementRank CategoryExpression = 2

sifterFor :: Int -> [Piece] -> SnippetSifter
sifterFor lineCount plan = SnippetSifter {
  forward = V.unsafeAccum (\_ new -> new) (V.replicate lineCount (-1))
              [(original, projected) | (projected, Just original) <- zip [0 ..] (map pieceOrigin plan)]
  , inverse = V.fromList [maybe (-1) id (pieceOrigin p) | p <- plan]
  }

identitySifter :: Int -> SnippetSifter
identitySifter n = SnippetSifter {
  forward = V.enumFromN 0 n
  , inverse = V.enumFromN 0 n
  }
