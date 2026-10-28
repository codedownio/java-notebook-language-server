{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE TypeOperators #-}

-- | Against a real jdtls, over a real notebook document.
--
-- The transformer tests cover the projection in isolation. These cover the two things they
-- cannot: that the projection is something jdtls will actually compile, and that positions
-- come back in cell coordinates.
--
-- Not the "Source:" link core rewrites in a hover: the jdtls nixpkgs gives this suite is
-- 1.46.1, which doesn't add one.

module Test.Notebook (spec) where

import Control.Lens ((^.))
import Data.String.Interpolate
import Data.Text (Text)
import qualified Data.Text as T
import Language.LSP.Protocol.Lens (label, message, name, range)
import Language.LSP.Protocol.Types
import Test.Sandwich
import Test.Sandwich.Contexts.Files
import Test.Sandwich.Waits (waitUntil)
import TestLib.LSP
import qualified "lsp-test" Language.LSP.Test as LSP hiding (message)
import qualified Language.LSP.Test.Helpers as Helpers


-- | One of everything: an import, a field, a method, a statement, a bare expression.
cells :: Text
cells = [__i|import java.util.List;

             int x = 41;

             int doubled(int v) {
                 return v * 2;
             }

             System.out.println(doubled(x));
             x + 1|]

-- | The ranges a goto answer points at, keeping only those in the document asked about.
locations :: TextDocumentIdentifier -> (Definition |? ([DefinitionLink] |? Null)) -> [Range]
locations (TextDocumentIdentifier wanted) = \case
  InL (Definition (InL loc)) -> ranges [loc]
  InL (Definition (InR locs)) -> ranges locs
  InR (InL links) -> ranges [Location u r | DefinitionLink (LocationLink _ u r _) <- links]
  InR (InR Null) -> []
  where ranges locs = [r | Location u r <- locs, u == wanted]

spec :: (
  Helpers.LspContext ctx m
  , HasFile ctx "java-notebook-language-server"
  , HasFile ctx "jdtls"
  ) => SpecFree ctx m ()
spec = describe "Notebook" $ do
  it "hovers a method declared in the notebook" $ do
    doNotebookSession cells $ \(Helpers.LspSessionInfo {..}) -> do
      doc <- LSP.openDoc lspSessionInfoFileName LanguageKind_Java

      -- Cell line 4 is "int doubled(int v) {". Naming the synthetic class proves jdtls
      -- compiled the projection rather than falling back to syntax-only.
      waitUntil 300 $ do
        hover <- Helpers.getHoverOrException doc (Position 4 6)
        Helpers.allHoverText hover `textShouldContain` "int __Cells.doubled(int v)"

  -- Answered out of jdtls's Java model rather than the didOpen text, so this covers core
  -- writing the shadow document before the open, not just the untransform.
  it "goes to a method declared in the notebook" $ do
    doNotebookSession cells $ \(Helpers.LspSessionInfo {..}) -> do
      doc <- LSP.openDoc lspSessionInfoFileName LanguageKind_Java

      waitUntil 300 $ do
        defs <- LSP.getDefinitions doc (Position 8 19)
        locations doc defs `shouldBe` [Range (Position 4 4) (Position 4 11)]

  it "completes a method declared in an earlier cell" $ do
    doNotebookSession cells $ \(Helpers.LspSessionInfo {..}) -> do
      doc <- LSP.openDoc lspSessionInfoFileName LanguageKind_Java

      -- This is the thing running jdtls without a proxy cannot do: resolve a name from one
      -- cell while in another.
      waitUntil 300 $ do
        completions <- LSP.getCompletions doc (Position 8 26)
        info [i|Got completions: #{completions}|]
        fmap (^. label) completions `listShouldContain` "doubled(int v) : int"

  it "reports a diagnostic at the cell's own line" $ do
    doNotebookSession cells $ \(Helpers.LspSessionInfo {..}) -> do
      _ <- LSP.openDoc lspSessionInfoFileName LanguageKind_Java

      -- The unused import is on cell line 0. Untransformed badly it would land wherever the
      -- projection put it, which is nowhere near.
      --
      -- Matched on the message rather than the diagnostic code, which is a jdtls-internal
      -- number that differs between versions.
      waitUntil 300 $ do
        diagnostics <- LSP.waitForDiagnostics
        info [i|Got diagnostics: #{diagnostics}|]
        case [d ^. range | d <- diagnostics, "never used" `T.isInfixOf` (d ^. message)] of
          (r : _) -> r `shouldBe` Range (Position 0 7) (Position 0 21)
          [] -> expectationFailure [i|No unused-import diagnostic in: #{diagnostics}|]

  -- jdtls answers with the projection's tree: everything hangs off the synthetic __Cells
  -- class, which spans lines no cell owns. Core replaces a node it can't place with its
  -- children, so the method surfaces at the top rather than the whole outline vanishing.
  it "outlines a method declared in the notebook" $ do
    doNotebookSession cells $ \(Helpers.LspSessionInfo {..}) -> do
      doc <- LSP.openDoc lspSessionInfoFileName LanguageKind_Java

      waitUntil 300 $ do
        symbols <- LSP.getDocumentSymbols doc
        info [i|Got document symbols: #{symbols}|]
        case symbols of
          Right documentSymbols ->
            [(s ^. name, s ^. range) | s <- documentSymbols]
              `listShouldContain` ("doubled(int)", Range (Position 4 0) (Position 6 1))
          Left symbolInformations ->
            expectationFailure [i|Expected a document symbol tree, got: #{symbolInformations}|]
