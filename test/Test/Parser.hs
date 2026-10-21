{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | How the client behaves when the parser process misbehaves.
module Test.Parser (spec) where

import Control.Monad.Catch (MonadMask)
import Control.Monad.IO.Class
import Data.String.Interpolate
import Language.LSP.Notebook.JavaParser
import System.FilePath
import System.IO.Temp
import System.Posix.Files (ownerModes, setFileMode)
import Test.Sandwich
import Test.Sandwich.Contexts.Files


spec :: (HasFile ctx "java-parser", MonadIO m, MonadMask m) => SpecFree ctx m ()
spec = describe "Parser process" $ do
  it "classifies a document" $ do
    parserPath <- askFile @"java-parser"
    client <- newParserClient parserPath []
    parseDocument client "import java.util.List;\nint x = 1;\nx + 1" >>= \case
      Left err -> expectationFailure [i|Parser failed: #{err}|]
      Right units -> map unitCategory units
        `shouldBe` [CategoryImport, CategoryDeclaration, CategoryExpression]

  -- The document the proxy sees is every code cell concatenated, with nothing marking the
  -- boundary, so one cell's trailing bare expression sits directly above the next cell's
  -- first line. Handed the whole document at once JShell merges the two into one erroneous
  -- unit; fed a line at a time it does not. This is that difference.
  it "does not merge a bare expression into what follows it" $ do
    parserPath <- askFile @"java-parser"
    client <- newParserClient parserPath []
    parseDocument client "x + 1\nint after(int v) {\n    return v;\n}" >>= \case
      Left err -> expectationFailure [i|Parser failed: #{err}|]
      Right units -> do
        map unitCategory units `shouldBe` [CategoryExpression, CategoryDeclaration]
        map unitStartLine units `shouldBe` [0, 1]

  -- A void call and a value expression want opposite treatment: `foo()` is a statement once a
  -- semicolon is added and cannot be assigned, `x + 1` is the reverse. Getting this backwards
  -- produces "void cannot be converted to Object" on the cell's last line.
  it "calls a void bare expression a statement, not an expression" $ do
    parserPath <- askFile @"java-parser"
    client <- newParserClient parserPath []
    parseDocument client "System.out.println(1)" >>= \case
      Left err -> expectationFailure [i|Parser failed: #{err}|]
      Right units -> map unitCategory units `shouldBe` [CategoryStatement]

  -- A JVM can die: out of memory, or killed along with the session it was serving. Without a
  -- restart every later projection falls back to passing the notebook through untouched, so
  -- jdtls sees raw cells and paints the document with errors that aren't real.
  it "restarts the parser after it dies" $ do
    realParser <- askFile @"java-parser"

    withSystemTempDirectory "jnls-flaky-parser" $ \dir -> do
      let marker = dir </> "spawned-once"
          script = dir </> "flaky-parser"

      -- Fails the first time it is started and works every time after, so the first request
      -- can only succeed by way of a restart.
      liftIO $ do
        writeFile script $ unlines [
          "#!/bin/sh"
          , "if [ ! -f " <> marker <> " ]; then touch " <> marker <> "; exit 1; fi"
          , "exec " <> realParser <> " \"$@\""
          ]
        setFileMode script ownerModes

      client <- newParserClient script []
      parseDocument client "int x = 1;" >>= \case
        Left err -> expectationFailure [i|Expected a restart to recover, got: #{err}|]
        Right units -> map unitCategory units `shouldBe` [CategoryDeclaration]

  it "reports an error when the parser cannot be started at all" $ do
    client <- newParserClient "/nonexistent/java-parser" []
    parseDocument client "int x = 1;" >>= \case
      Right units -> expectationFailure [i|Expected failure, got: #{show units}|]
      Left _ -> return ()
