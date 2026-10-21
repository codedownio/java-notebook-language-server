{-# LANGUAGE DataKinds #-}

import Test.Sandwich
import Test.Sandwich.Contexts.Files
import Test.Sandwich.Contexts.Nix
import TestLib.LSP

import qualified Test.Notebook
import qualified Test.Parser
import qualified Test.RawFile
import qualified Test.Transformer.Diff
import qualified Test.Transformer.Mixed


spec :: TopSpec
spec = describe "java-notebook-language-server" $ do
  Test.Transformer.Mixed.spec

  describe "Against Nix-built binaries" $
    introduceMaybeBubblewrap $
    introduceNixContext nixpkgsReleaseDefault $ do
      introduceJavaParser $ do
        Test.Parser.spec
        Test.Transformer.Diff.spec

      introduceBinaryViaNixPackage @"jdtls" "jdt-language-server" $
        introduceJnls $ do
          Test.Notebook.spec
          Test.RawFile.spec

main :: IO ()
main = runSandwichWithCommandLineArgs defaultOptions spec
