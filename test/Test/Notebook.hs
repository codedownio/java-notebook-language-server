{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PackageImports #-}

-- | Against a real jdtls, over a real notebook document.
--
-- The transformer tests cover the projection in isolation. These cover the two things they
-- cannot: that the projection is something jdtls will actually compile, and that positions
-- come back in cell coordinates.

module Test.Notebook (spec) where

import Control.Lens ((^.))
import Data.String.Interpolate
import Data.Text (Text)
import qualified Data.Text as T
import Language.LSP.Protocol.Lens (label, message, range)
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
