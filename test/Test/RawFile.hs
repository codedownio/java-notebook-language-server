{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PackageImports #-}

-- | A real .java file, which the proxy must leave alone.
--
-- The projection only applies to notebooks; a file in the environment is already a valid
-- compilation unit, so it goes to jdtls untouched and positions pass straight through. The
-- unit tests cover `IdentityParams`; this covers the routing that chooses it.
module Test.RawFile (spec) where

import Control.Lens ((^.))
import Data.String.Interpolate
import Data.Text (Text)
import qualified Data.Text as T
import Language.LSP.Protocol.Lens (message, range)
import Language.LSP.Protocol.Types
import Test.Sandwich
import Test.Sandwich.Contexts.Files
import Test.Sandwich.Waits (waitUntil)
import TestLib.LSP
import qualified "lsp-test" Language.LSP.Test as LSP hiding (message)
import qualified Language.LSP.Test.Helpers as Helpers


-- | An ordinary compilation unit, with the unused import on line 0 as in the notebook tests
-- so the two can be compared directly.
rawFile :: Text
rawFile = [__i|import java.util.List;

               class Example {
                   int doubled(int v) {
                       return v * 2;
                   }
               }|]

spec :: (
  Helpers.LspContext ctx m
  , HasFile ctx "java-notebook-language-server"
  , HasFile ctx "jdtls"
  ) => SpecFree ctx m ()
spec = describe "Raw .java file" $ do
  it "hovers without naming a synthetic class" $
    doRawSession rawFile $ \(Helpers.LspSessionInfo {..}) -> do
      doc <- LSP.openDoc lspSessionInfoFileName LanguageKind_Java

      -- The real class, not __Cells: proof the projection stayed out of the way.
      waitUntil 300 $ do
        hover <- Helpers.getHoverOrException doc (Position 3 10)
        Helpers.allHoverText hover `textShouldContain` "int Example.doubled(int v)"

  it "reports diagnostics at unshifted positions" $
    doRawSession rawFile $ \(Helpers.LspSessionInfo {..}) -> do
      _ <- LSP.openDoc lspSessionInfoFileName LanguageKind_Java

      waitUntil 300 $ do
        diagnostics <- LSP.waitForDiagnostics
        info [i|Got diagnostics: #{diagnostics}|]
        case [d ^. range | d <- diagnostics, "never used" `T.isInfixOf` (d ^. message)] of
          (r : _) -> r `shouldBe` Range (Position 0 7) (Position 0 21)
          [] -> expectationFailure [i|No unused-import diagnostic in: #{diagnostics}|]
