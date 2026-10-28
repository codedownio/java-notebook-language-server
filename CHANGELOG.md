# Changelog

## 0.1.5.0

- Transform the call and type hierarchies, whose answers named the shadow document and so couldn't be followed

## 0.1.4.0

- Answer textDocument/documentSymbol for a notebook, which came back empty because every cell symbol hangs off the projection's synthetic class

## 0.1.3.0

- Write the shadow document to disk before the server is told about it, which jdtls needs to answer a goto
- Recognize the shadow document in an answer however the server escaped its path
- Rewrite the shadow document's name and line in a hover's "Source:" link, which named a file the user doesn't have

## 0.1.2.0

- Transform workspace/symbol answers, which named the shadow document instead of the notebook

## 0.1.1.0

- Transform textDocument/selectionRange, textDocument/semanticTokens and the goto family, which reached the client in shadow coordinates
- Transform textDocument/rename, prepareRename, references, signatureHelp and declaration, which reached the server naming the notebook

## 0.1.0.0

Initial version.

- Projects Java notebook cells into a compilation unit jdtls accepts, and maps positions back.
- Classifies snippets with JShell's own `SourceCodeAnalysis`, via a persistent `java-parser`
  process rather than a fork per projection.
- Normalizes jdtls's non-conforming `shutdown` response, which otherwise makes strict clients
  wait out their timeout on every session.
