{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The incremental-edit invariant, against the real parser.
--
-- Stubbing the parser would make this vacuous: the stub answers the same units whatever the
-- document says, so the projection wouldn't track the edit it is being asked about.
module Test.Transformer.Diff (spec) where

import Control.Monad.IO.Class
import Data.String.Interpolate
import qualified Data.Text as T
import Language.LSP.Notebook.JavaParser
import Language.LSP.Notebook.SnippetSifter
import Language.LSP.Transformer
import Test.QuickCheck (forAll, ioProperty, quickCheckWithResult, stdArgs)
import qualified Test.QuickCheck as Q
import Test.Sandwich
import Test.Sandwich.Contexts.Files
import TestLib.Core


testCode :: T.Text
testCode = T.intercalate "\n" [
  "import java.util.List;"
  , ""
  , "int x = 41;"
  , ""
  , "int doubled(int v) {"
  , "    return v * 2;"
  , "}"
  , ""
  , "System.out.println(doubled(x));"
  , "x + 1"
  ]

spec :: (HasFile ctx "java-parser", MonadIO m) => SpecFree ctx m ()
spec = describe "Incremental edits" $
  it "handleDiff agrees with reprojecting from scratch" $ do
    parserPath <- askFile @"java-parser"
    client <- newParserClient parserPath []
    let params = SnippetSifterParams {
          parserClient = client
          , className = "__Cells"
          , execMethodName = "__notebookExec"
          }
        doc = listToDoc (T.splitOn "\n" testCode)

    -- Each case is five parser round trips, and the process is reused, so this is a couple of
    -- seconds rather than the minutes a per-case JVM would cost.
    result <- liftIO $ quickCheckWithResult (stdArgs { Q.maxSuccess = 50, Q.chatty = False }) $
      forAll (arbitrarySingleLineChange doc) $ \change ->
        ioProperty (testChange @SnippetSifter params doc change)

    case result of
      Q.Success {} -> return ()
      failed -> expectationFailure [i|Property failed:\n#{Q.output failed}|]
