# java-notebook-language-server

Wraps [`jdt-language-server`](https://github.com/eclipse-jdtls/eclipse.jdt.ls) so it can serve a
Java notebook, by projecting cells into a document javac will accept and rewriting positions
between the two coordinate spaces. A sibling of `rust-`, `cpp-`, `go-` and
`haskell-notebook-language-server`, built on the same
[`notebook-language-server-core`](https://github.com/codedownio/notebook-language-server-core).

## Why a proxy is needed

JDT LS is a full Eclipse Java compiler, and every document it is given has to be a valid
compilation unit. A notebook cell is not one. This is legal in a cell and illegal in a file:

```java
import java.util.List;
int x = 41;
int doubled(int v) { return v * 2; }
System.out.println(doubled(x));
x + 1
```

Imports, declarations and loose statements in any order, and a trailing bare expression. Without
a proxy, the kernel ships with `notebook_suffix = ""` so JDT LS never sees the notebook at all:
`.java` files in the environment get full code intelligence, notebook cells get none.

## The projection

A cell is a sequence of JShell *snippets*. The projection sorts them into the three places a
Java file has for them:

```java
<imports>
class __Cells {
<types, methods, and fields with an explicit type>
void __notebookExec() throws Exception {
<statements, and expressions wrapped so they are statements>
}
}
```

Two properties are worth calling out.

**Nothing is indented, and every synthetic line is a line of its own.** Java ignores whitespace,
so no original line ever moves sideways: the projection is a pure line permutation and
`transformPosition` is a vector lookup that leaves the column alone. The C++ projection indents
its wrapper body and has to add and subtract two columns on the way through; this one does not
have to.

**A bare expression is assigned to something**, because `x + 1;` is not a statement:

```java
Object __expr0 =
x + 1
;
```

The prefix and suffix take lines of their own, so the expression's own lines keep their exact
columns. Which treatment an expression gets depends on whether appending a semicolon would
already be legal — `foo()` is a statement once a semicolon is added and cannot be assigned
because it may be void; `x + 1` is the reverse. Java's statement expressions are method calls,
instance creations, assignments and increment/decrement, so the test is syntactic.

Lines no snippet claims — blank lines, free-standing comments — go into the method body in
original order. They have to land somewhere for a position on them to survive the round trip,
and a method body is the only place that accepts anything.

## How the parsing works

`java-parser/` is a small Java program that splits a document into top-level snippets and
classifies each one. The classifier is JShell's own `jdk.jshell.SourceCodeAnalysis`, and that is
the point: the kernel evaluating these cells *is* JShell, so the projection and the kernel agree
about what a snippet is by construction rather than through a second parser maintained in
parallel. It also ships with the JDK the kernel already depends on.

Three things about that API shaped the design, each found by running it rather than reading
about it.

**Classification is syntactic where it matters.** Unresolvable names do not derail it: an import
of a missing package, a class extending an unknown base, a method mentioning unknown types all
still come back `IMPORT`, `TYPE_DECL` and `METHOD`. Only expressions and `var` declarations whose
type cannot be inferred report `ERRONEOUS`, and those belong in the executable body anyway, which
is where anything unclassifiable goes.

**It has to be fed a line at a time.** Handed a whole document, JShell cannot find the end of a
snippet with no terminating semicolon: given `x + 1` followed by `foo();` it returns both as a
single erroneous unit. Accumulating lines and asking `completeness()` after each, `x + 1` alone
reports `COMPLETE` and terminates the snippet. That matters twice over, because a trailing bare
expression is the normal idiom in a Java notebook, and because the document the proxy is given is
every code cell concatenated — one cell's trailing expression sits directly above the next cell's
first line. The core has no notion of cells, so this is what makes cell boundaries a non-issue.

**Not every `VAR` is a variable.** JShell evaluates a bare expression by assigning it to a scratch
variable, so `"hello"` and `Math.max(1, 2)` arrive reported as `VAR` and would otherwise be
hoisted into the class body as fields. The subkind separates them:
`TEMP_VAR_EXPRESSION_SUBKIND` against `VAR_DECLARATION_*`.

The parser reduces all of this to one of four categories — `IMPORT`, `DECLARATION`, `STATEMENT`,
`EXPRESSION` — so the Haskell side stays simple and the judgement lives in one place.

### The parser is a server, not a fork

The other proxies fork their parser once per projection, which is fine for a native binary that
starts in single-digit milliseconds. This one is a JVM. Measured on the pinned JDK 21:

| | |
|---|---|
| fork per call | ~450 ms |
| persistent process, startup + first answer | ~350 ms |
| persistent process, warm, 17-line document | ~4 ms |
| persistent process, warm, 240-line document | ~93 ms |

A projection happens on every document change, twice — `handleDiff` projects both before and
after. So `java-parser --serve` is started once and held open for the life of the server, with
requests and responses framed as a four-byte big-endian length and that many UTF-8 bytes.

There is an obvious optimization not yet done: only consult JShell when brace depth is zero,
which would skip the per-line call for every line inside a method or class body.

## Status

Working: the projection and its position mapping, with tests; the parser, against the cases in
`java-parser/`; the server wiring, copied from `cpp-notebook-language-server`.

Not done yet:

- Nix packaging (`flake.nix`, the `java-parser` derivation) and CI, so there is no release
  artifact and `codedown-languages` cannot consume this yet.
- Integration tests against a real `jdtls` — only the transformer is covered so far.
- `unproject`, so `notebookConfigHandlesFormatting` is `False`. Formatting a notebook means
  untransforming a whole rewritten document rather than a position, and the projection currently
  throws away what it would need to put the synthetic class back.
- The brace-depth optimization above.
