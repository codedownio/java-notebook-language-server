module Language.LSP.Notebook (
  JavaNotebookTransformer
  , transformerParams
  , idTransformerParams
  ) where

import Language.LSP.Notebook.JavaParser (ParserClient)
import Language.LSP.Notebook.SnippetSifter
import Language.LSP.Transformer


-- | Java needs one transformation, not a pipeline: sorting snippets into the places a .java
-- file has for them. (The Haskell proxy chains seven, because Haskell cells need directives
-- rewritten and expressions and statements converted separately.)
type JavaNotebookTransformer = SnippetSifter

transformerParams :: ParserClient -> Params JavaNotebookTransformer
transformerParams client = SnippetSifterParams {
  parserClient = client
  , className = "__Cells"
  , execMethodName = "__notebookExec"
  }

-- | For documents that are already real .java files, where the projection must do nothing.
idTransformerParams :: Params JavaNotebookTransformer
idTransformerParams = IdentityParams
