# Changelog

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
