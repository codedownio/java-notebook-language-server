{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE TypeFamilies #-}

-- | Projecting a Java notebook into something javac will accept.
--
-- A cell is a sequence of JShell snippets: imports, type and method declarations, variable
-- declarations, statements, and bare expressions, in any order. A @.java@ file is none of
-- those things -- it is imports, then one type declaration, with statements only inside method
-- bodies. So the projection sorts the snippets into the three places a Java file has for them:
--
-- @
-- <imports>
-- class __Cells {
-- <types, methods and explicitly-typed fields>
-- void __notebook_exec() throws Exception {
-- <statements, and expressions wrapped so they are statements>
-- }
-- }
-- @
--
-- Every synthetic line is a line of its own and nothing is indented, which is the one piece of
-- luck in this transform: Java ignores whitespace, so no original line ever moves sideways and
-- position mapping is a pure line permutation. (The C++ projection indents its wrapper body
-- and has to add and subtract two columns on the way through.)
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


-- | The projection, stored as the line permutation it amounts to.
--
-- Both directions are kept so transforming and untransforming a position are both O(1), which
-- matters because they happen on every request and every response.
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
  -- | Leave the document alone. A real @.java@ file in the environment is already a valid
  -- compilation unit, so it is handed to the server untouched; this is not a degenerate case
  -- of the projection but the absence of one, and saying so explicitly keeps it out of the
  -- error path.
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
      -- The parser is how we know where anything goes, so without it the honest thing is to
      -- pass the document through untouched. The server will complain about it, but the
      -- complaints will at least be about lines the user can see.
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

-- | @throws Exception@ because notebook code calls throwing methods without ceremony, and an
-- unhandled-exception error on every such line would bury the diagnostics that matter.
execLine :: Text -> Text
execLine name = "void " <> name <> "() throws Exception {"

closeLine :: Text
closeLine = "}"

-- | A bare expression is not a statement, so it is assigned to something. The prefix and
-- suffix get lines of their own so the expression's own lines keep their exact columns.
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

    -- Everything else, in original order: statements, expressions, and the lines no snippet
    -- claimed (blank lines and free-standing comments). Those have to land somewhere so that
    -- a position on them still maps, and the method body is the only place that accepts
    -- anything.
    bodyLines = [i | i <- [0 .. lineCount - 1]
                   , categoryOf i /= Just CategoryImport
                   , categoryOf i /= Just CategoryDeclaration]

    -- Expressions are wrapped as a unit, so the body is built from runs of lines rather than
    -- line by line.
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

    -- Split the body lines into the runs that have to stay together: one run per expression
    -- span, and single-line runs for everything else.
    groupBodyLines :: [Int] -> [[Int]]
    groupBodyLines [] = []
    groupBodyLines (i : rest) = case M.lookup i expressionSpans of
      Just end | end > i ->
        let (within, after) = L.span (<= end) rest
        in (i : within) : groupBodyLines after
      _ -> [i] : groupBodyLines rest

-- | Which category each original line belongs to, or 'Nothing' if no snippet covers it.
--
-- A line can be covered by more than one snippet when two are written on one line
-- (@int x = 1; x + 1@). The more restrictive placement wins: an import has to be outside the
-- class and a declaration has to be outside the method, so the line goes to the outermost
-- place any of its snippets needs. That can put a statement in the class body, which is
-- invalid -- but the alternative puts an import inside a class, which is invalid *and* makes
-- every name in the document unresolvable.
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
