# java-notebook-language-server

Wraps [`jdt-language-server`](https://github.com/eclipse-jdtls/eclipse.jdt.ls) so it can serve a
Java notebook, projecting cells into a document javac accepts and mapping positions back. A
sibling of `rust-`, `cpp-`, `go-` and `haskell-notebook-language-server`, built on
[`notebook-language-server-core`](https://github.com/codedownio/notebook-language-server-core).

## Why

JDT LS needs every document to be a valid compilation unit. A cell isn't one:

```java
import java.util.List;
int x = 41;
int doubled(int v) { return v * 2; }
System.out.println(doubled(x));
x + 1
```

Imports, declarations and statements in any order, and a trailing bare expression. Without a
proxy the kernel ships `notebook_suffix = ""`, so `.java` files get full code intelligence and
notebook cells get none.

## The projection

A cell is a sequence of JShell *snippets*, sorted into the three places a Java file has for
them:

```java
<imports>
class __Cells {
<types, methods, and fields with an explicit type>
void __notebookExec() throws Exception {
<statements, and expressions wrapped so they are statements>
}
}
```

Nothing is indented and every synthetic line is its own line. Java ignores whitespace, so no
original line moves sideways: the projection is a pure line permutation and position mapping
leaves the column alone. A bare expression is assigned to something, because `x + 1;` isn't a
statement:

```java
Object __expr0 =
x + 1
;
```

Which treatment an expression gets depends on whether appending a semicolon would already be
legal — `foo()` is a statement with a semicolon and can't be assigned because it may be void;
`x + 1` is the reverse. Java's statement expressions are calls, `new`, assignment and
`++`/`--`, so the test is syntactic.

Lines no snippet claims — blanks, free-standing comments — go into the method body in original
order, so a position on them still maps.

## Parsing

`java-parser/` splits a document into snippets and classifies them, using JShell's own
`jdk.jshell.SourceCodeAnalysis`. That's the point: the kernel evaluating these cells *is*
JShell, so the projection and the kernel agree on what a snippet is by construction. It also
needs no dependency beyond the JDK the kernel already has.

Three things about that API shaped the design:

- **Classification is syntactic where it matters.** Unresolvable names don't derail it: an
  import of a missing package, a class extending an unknown base, a method mentioning unknown
  types all still classify correctly. Only expressions and uninferable `var`s report
  `ERRONEOUS`, and those belong in the body anyway.
- **It has to be fed a line at a time.** Given a whole document, JShell can't find the end of a
  snippet with no semicolon: `x + 1` followed by `foo();` comes back as one erroneous unit.
  Accumulating lines and checking `completeness()` after each, `x + 1` alone reports `COMPLETE`.
  That matters because a trailing bare expression is the normal notebook idiom, and because the
  document is every code cell concatenated — one cell's trailing expression sits directly above
  the next cell's first line.
- **Not every `VAR` is a variable.** JShell evaluates a bare expression by assigning it to a
  scratch variable, so `"hello"` and `Math.max(1, 2)` report as `VAR` and would be hoisted into
  the class body as fields. The subkind separates them.

The parser emits one of four categories — `IMPORT`, `DECLARATION`, `STATEMENT`, `EXPRESSION` —
so the judgement lives in one place.

### It's a server, not a fork

The other proxies fork their parser per projection, which is fine for a native binary. This one
is a JVM, and a projection happens on every document change — twice, since `handleDiff` projects
before and after. Measured on JDK 21:

| | |
|---|---|
| fork per call | ~450 ms |
| persistent, startup + first answer | ~350 ms |
| persistent, warm, 17 lines | ~4 ms |
| persistent, warm, 240 lines | ~93 ms |

So `java-parser --serve` is started once and held open, framing requests and responses as a
four-byte big-endian length plus that many UTF-8 bytes. It is built from source by whoever
packages the server rather than shipped as a release artifact, since it needs a JDK anyway.

Not yet done: only consulting JShell at brace depth zero, which would skip the per-line call
for every line inside a method or class body.

## Status

Working, covered by `stack test`: the projection and its position mapping as unit tests, and
hover, completion and diagnostics against a real jdtls over a notebook document as integration
tests.

Formatting is off (`notebookConfigHandlesFormatting = False`): it means untransforming a whole
rewritten document rather than a position, and `SnippetSifter` has no `unproject` yet.

No release is tagged, so `codedown-languages` can't consume this yet. Cut one with
`.aliases/dev-upload-to-github`, which tags the commit and uploads
`.#grandCombinedGithubArtifacts` — the four per-platform server binaries. `java-parser` is not
in there by design: it needs a JDK at runtime, so whoever packages the server builds it from
source at the tag, the way `codedown-languages` does for `cling-parser`.
