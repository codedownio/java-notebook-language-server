{-# LANGUAGE AllowAmbiguousTypes #-}

-- | The invariant every transformer has to hold under incremental edits.
module TestLib.Core (
  testChange
  , arbitrarySingleLineChange
  ) where

import Control.Monad.IO.Class
import qualified Data.List as L
import qualified Data.Text as T
import Language.LSP.Protocol.Types
import Language.LSP.Transformer
import Test.QuickCheck as Q


-- | Editing a document and asking the transformer to update incrementally has to give the
-- same answer as projecting the edited document from scratch.
--
-- This is what the server actually does all day: a full projection happens on `didOpen`, and
-- everything after is `handleDiff`. If the two can disagree, the shadow document drifts from
-- the notebook and every position after the drift is wrong, with nothing to signal it.
testChange :: forall a m. (
  ProjectIn m a, Eq a, Show a, MonadIO m
  ) => Params a -> Doc -> TextDocumentContentChangeEvent -> m Property
testChange params docLines change = do
  let docLines' = applyChanges [change] docLines

  (projectedBefore, transformer :: a, _) <- project params docLines
  (projectedAfter, reprojected :: a, _) <- project params docLines'

  (changes, transformer') <- handleDiff params docLines change transformer

  return $ conjoin [
    counterexample "applying handleDiff's changes should reconstruct the fresh projection" $
      applyChanges changes projectedBefore === projectedAfter
    , counterexample "handleDiff's transformer should equal a fresh one" $
      reprojected === transformer'
    ]

-- | An edit to a random span of a random line. Deliberately not arbitrary text: the point is
-- to exercise the projection under realistic editing, and random bytes mostly just produce
-- documents where every snippet is erroneous.
arbitrarySingleLineChange :: Doc -> Gen TextDocumentContentChangeEvent
arbitrarySingleLineChange (docToList -> docLines) = do
  lineNo <- chooseInt (0, max 0 (L.length docLines - 1))
  let lineLen = T.length (docLines L.!! lineNo)

  start <- chooseInt (0, lineLen)
  end <- chooseInt (start, lineLen)
  inserted <- T.pack <$> listOf (elements "abcxyz01(){};.+ \n")

  pure $ TextDocumentContentChangeEvent $ InL $ TextDocumentContentChangePartial
    (Range (Position (fromIntegral lineNo) (fromIntegral start))
           (Position (fromIntegral lineNo) (fromIntegral end)))
    Nothing
    inserted
