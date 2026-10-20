{-# LANGUAGE DataKinds #-}

import Test.Sandwich
import Test.Sandwich.Contexts.Files
import Test.Sandwich.Contexts.Nix
import TestLib.LSP

import qualified Test.Notebook
import qualified Test.Transformer.Mixed


spec :: TopSpec
spec = describe "java-notebook-language-server" $ do
  Test.Transformer.Mixed.spec

  describe "Integration tests" $
    introduceMaybeBubblewrap $
    introduceNixContext nixpkgsReleaseDefault $
    introduceBinaryViaNixPackage @"jdtls" "jdt-language-server" $
    introduceJnls $
      Test.Notebook.spec

main :: IO ()
main = runSandwichWithCommandLineArgs defaultOptions spec
