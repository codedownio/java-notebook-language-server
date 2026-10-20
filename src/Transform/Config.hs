{-# LANGUAGE RankNTypes #-}

module Transform.Config (javaNotebookConfig) where

import Data.String.Interpolate
import qualified Data.Text as T
import Language.LSP.Notebook
import Language.LSP.Notebook.JavaParser (ParserClient)
import Language.LSP.NotebookLanguageServer.Config
import Language.LSP.NotebookLanguageServer.Transform.ServerRsp.Hover (mkDocRegex)
import Language.LSP.NotebookLanguageServer.Transform.Util
import Language.LSP.Protocol.Types
import Language.LSP.Transformer (Doc)
import Text.Regex.PCRE.Light (Regex)
import UnliftIO.Exception


javaNotebookConfig :: ParserClient -> Int -> NotebookConfig JavaNotebookTransformer
javaNotebookConfig client didSaveDebounceMs = NotebookConfig {
  notebookConfigHandles = const True
  , notebookConfigDidSaveDebounceMs = Just didSaveDebounceMs
  -- Formatting a notebook would mean untransforming a whole rewritten document rather than a
  -- position, and the projection throws away the information needed to put the synthetic
  -- class back -- so it stays off until SnippetSifter implements `unproject`.
  , notebookConfigHandlesFormatting = False
  , notebookConfigTransformerParamsFor = \u ->
      if isNotebook u then transformerParams client else idTransformerParams
  , notebookConfigMakeShadowDocument = makeShadowDocument
  , notebookConfigUnopenedUri = addExtensionToUri ".java"
  , notebookConfigOnDocumentsChanged = pure ()
  , notebookConfigTransformInitialize = pure
  , notebookConfigCustomUriMethods = []
  , notebookConfigIgnoreSymbol = const False
  , notebookConfigLanguageName = "java"
  }

makeShadowDocument :: TransformerMonad JavaNotebookTransformer n => Uri -> Doc -> n (Uri, FilePath, Regex)
makeShadowDocument origUri _projected = do
  newUri <- if isNotebook origUri then addExtensionToUri ".java" origUri else pure origUri

  newPath <- case uriToFilePath newUri of
    Nothing -> throwIO $ userError [i|Failed to convert new URI to file path: #{newUri}|]
    Just x -> pure x

  pure (newUri, newPath, mkDocRegex (T.pack newPath))
