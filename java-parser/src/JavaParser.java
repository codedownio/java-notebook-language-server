import jdk.jshell.JShell;
import jdk.jshell.Snippet;
import jdk.jshell.SourceCodeAnalysis;
import jdk.jshell.SourceCodeAnalysis.CompletionInfo;
import jdk.jshell.SourceCodeAnalysis.Completeness;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.EOFException;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * Splits a Java notebook document into top-level snippets and classifies each one, so
 * java-notebook-language-server knows which lines are imports, which are declarations, and
 * which are executable code.
 *
 * <p>The classifier is JShell's own ({@code jdk.jshell.SourceCodeAnalysis}), which is the
 * point: the kernel evaluating these cells is JShell, so the projection and the kernel agree
 * about what a snippet is by construction rather than by a parser we maintain in parallel.
 *
 * <p>Two things are worth knowing about how this uses that API.
 *
 * <p>First, splitting is done by accumulating one line at a time and asking after each whether
 * what we have is complete, rather than by handing JShell the whole document. Handed a whole
 * document, JShell cannot find the end of a snippet that has no terminating semicolon: given
 * {@code x + 1} followed by {@code foo();} it returns the two as a single erroneous unit. Fed
 * line by line, {@code x + 1} alone reports COMPLETE and terminates the snippet. That matters
 * because a trailing bare expression is the normal idiom in a Java notebook, and because the
 * document this sees is every code cell concatenated -- one cell's trailing expression sits
 * directly above the next cell's first line.
 *
 * <p>Second, classification is resolution-sensitive but only for expressions. An import of a
 * missing package, a class extending an unknown base, a method mentioning unknown types: all
 * still classify as IMPORT, TYPE_DECL and METHOD. Only expressions and {@code var}
 * declarations whose type cannot be inferred come back ERRONEOUS, and those belong in the
 * executable body anyway, which is where an unclassifiable snippet is put.
 */
public final class JavaParser {

  /** What the transformer does with a snippet, which is all it needs to know. */
  private enum Category {
    /** Must go above the synthetic class. */
    IMPORT,
    /** Must go in the class body: types, methods, and fields with an explicit type. */
    DECLARATION,
    /** Goes in the executable method body as-is. */
    STATEMENT,
    /** Goes in the executable method body, but is not a statement, so it needs wrapping. */
    EXPRESSION
  }

  private record Unit(Category category, String kind, String subKind, int startLine,
                      int startCh, int endLine, int endCh) {
    String toJson() {
      return "{\"category\":\"" + category + "\",\"kind\":\"" + kind
          + "\",\"subKind\":\"" + subKind
          + "\",\"startLine\":" + startLine + ",\"startCh\":" + startCh
          + ",\"endLine\":" + endLine + ",\"endCh\":" + endCh + "}";
    }
  }

  public static void main(String[] args) throws IOException {
    boolean serve = args.length > 0 && args[0].equals("--serve");

    JShell shell = JShell.builder().build();
    try {
      SourceCodeAnalysis analysis = shell.sourceCodeAnalysis();
      if (serve) {
        serve(analysis);
      } else {
        String source = new String(System.in.readAllBytes(), StandardCharsets.UTF_8);
        System.out.println(toJson(parse(analysis, source)));
      }
    } finally {
      shell.close();
    }
  }

  /**
   * Request/response over stdin/stdout, each framed as a four-byte big-endian length followed
   * by that many UTF-8 bytes.
   *
   * <p>The other notebook language servers fork their parser once per projection, which is
   * fine when it is a native binary that starts in single-digit milliseconds. A JVM takes
   * about 350ms to get this far, and a projection happens on every document change (twice, for
   * the diff), so forking per call would put most of a second between a keystroke and a
   * completion. Held open, the same work takes about 4ms.
   */
  private static void serve(SourceCodeAnalysis analysis) throws IOException {
    DataInputStream in = new DataInputStream(new BufferedInputStream(System.in));
    while (true) {
      int length;
      try {
        length = in.readInt();
      } catch (EOFException e) {
        return;
      }
      String source = new String(in.readNBytes(length), StandardCharsets.UTF_8);

      byte[] response = toJson(parse(analysis, source)).getBytes(StandardCharsets.UTF_8);
      System.out.write(new byte[] {
          (byte) (response.length >>> 24), (byte) (response.length >>> 16),
          (byte) (response.length >>> 8), (byte) response.length});
      System.out.write(response);
      System.out.flush();
    }
  }

  private static String toJson(List<Unit> units) {
    StringBuilder out = new StringBuilder("[");
    for (int i = 0; i < units.size(); i++) {
      if (i > 0) {
        out.append(",");
      }
      out.append(units.get(i).toJson());
    }
    return out.append("]").toString();
  }

  static List<Unit> parse(SourceCodeAnalysis analysis, String source) {
    List<Unit> units = new ArrayList<>();
    // Offsets are into `source` and are converted to line/character at the end, so that the
    // splitting loop only has to track one number.
    LineIndex lines = new LineIndex(source);

    StringBuilder pending = new StringBuilder();
    int pendingStart = 0;
    int consumed = 0;

    for (String line : splitLinesKeepingTerminators(source)) {
      pending.append(line);
      consumed += line.length();

      // One line can finish several snippets ("int x = 1; int y = 2;"), so drain rather than
      // emit at most one.
      while (pending.length() > 0) {
        CompletionInfo info = analysis.analyzeCompletion(pending.toString());
        if (!isComplete(info.completeness())) {
          break;
        }
        String unit = info.source();
        if (unit == null || unit.isEmpty()) {
          break;
        }
        emit(units, analysis, lines, unit, pendingStart);
        pendingStart += unit.length();

        String remaining = info.remaining();
        pending.setLength(0);
        if (remaining != null && !remaining.isEmpty()) {
          pending.append(remaining);
        } else {
          pendingStart = consumed;
          break;
        }
      }

      if (pending.length() == 0) {
        pendingStart = consumed;
      }
    }

    // Whatever is left never completed -- an unclosed brace, usually, which is what a document
    // looks like while it is being typed. Emit it so its lines still map somewhere.
    if (!pending.toString().isBlank()) {
      emit(units, analysis, lines, pending.toString(), pendingStart);
    }

    return units;
  }

  private static boolean isComplete(Completeness completeness) {
    return completeness == Completeness.COMPLETE
        || completeness == Completeness.COMPLETE_WITH_SEMI;
  }

  private static void emit(List<Unit> units, SourceCodeAnalysis analysis, LineIndex lines,
                           String unit, int offset) {
    String trimmed = unit.strip();
    if (trimmed.isEmpty()) {
      return;
    }
    int start = offset + (unit.length() - unit.stripLeading().length());
    int end = offset + unit.stripTrailing().length();

    String kind = "NONE";
    String subKind = "NONE";
    List<Snippet> snippets = analysis.sourceToSnippets(unit);
    if (!snippets.isEmpty()) {
      kind = snippets.get(0).kind().toString();
      subKind = snippets.get(0).subKind().toString();
    }

    units.add(new Unit(categorize(kind, subKind, trimmed), kind, subKind,
                       lines.lineOf(start), lines.characterOf(start),
                       lines.lineOf(end), lines.characterOf(end)));
  }

  private static Category categorize(String kind, String subKind, String trimmed) {
    switch (kind) {
      case "IMPORT":
        return Category.IMPORT;
      case "TYPE_DECL":
      case "METHOD":
        return Category.DECLARATION;
      case "VAR":
        // Not every VAR is a variable declaration. JShell reports a bare expression as a VAR
        // too, because the way it evaluates one is to assign it to a scratch variable ($1),
        // so `"hello"` and `Math.max(1, 2)` arrive here looking like declarations. The
        // subkind is what separates them.
        switch (subKind) {
          case "VAR_DECLARATION_SUBKIND":
          case "VAR_DECLARATION_WITH_INITIALIZER_SUBKIND":
            // `var` is legal for a local and illegal for a field, so an inferred-type
            // declaration stays in the method body even though every other one is hoisted.
            return trimmed.startsWith("var ") ? Category.STATEMENT : Category.DECLARATION;
          case "ASSIGNMENT_SUBKIND":
            return Category.STATEMENT;
          default:
            // TEMP_VAR_EXPRESSION_SUBKIND, VAR_VALUE_SUBKIND, OTHER_EXPRESSION_SUBKIND.
            return isStatementExpression(trimmed) ? Category.STATEMENT : Category.EXPRESSION;
        }
      case "STATEMENT":
        return Category.STATEMENT;
      case "EXPRESSION":
        return isStatementExpression(trimmed) ? Category.STATEMENT : Category.EXPRESSION;
      default:
        // ERRONEOUS, or a kind we don't know. Either it is already a statement, or it is a
        // bare expression that the transformer has to wrap.
        return isStatementExpression(trimmed) ? Category.STATEMENT : Category.EXPRESSION;
    }
  }

  /**
   * Whether appending a semicolon to this would be a legal Java statement.
   *
   * <p>This is the one judgement call in here, and it is needed because the two kinds of bare
   * expression want opposite treatment: {@code foo()} is a statement once a semicolon is added
   * and cannot be assigned (it may be void), while {@code x + 1} is the reverse. Java's
   * statement expressions are method calls, instance creations, assignments and
   * increment/decrement, so the test is syntactic -- no types involved.
   *
   * <p>Ending in {@code )} is the signal for the first two, except when the whole expression
   * is parenthesised, which is a value expression wearing the same clothes.
   */
  private static boolean isStatementExpression(String trimmed) {
    if (trimmed.endsWith(";") || trimmed.endsWith("}")) {
      return true;
    }
    if (trimmed.endsWith("++") || trimmed.endsWith("--")) {
      return true;
    }
    if (trimmed.endsWith(")")) {
      return !wholeExpressionIsParenthesised(trimmed);
    }
    return false;
  }

  /** True for "(x + 1)" and false for "foo(x + 1)" or "(a).b()". */
  private static boolean wholeExpressionIsParenthesised(String trimmed) {
    if (!trimmed.startsWith("(")) {
      return false;
    }
    int depth = 0;
    for (int i = 0; i < trimmed.length(); i++) {
      char c = trimmed.charAt(i);
      if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
        // The opening paren closed before the end, so the trailing ")" belongs to something
        // else, as in "(a).b()".
        if (depth == 0) {
          return i == trimmed.length() - 1;
        }
      }
    }
    return false;
  }

  /**
   * Lines with their terminators kept, so that concatenating them reproduces the input and
   * offsets stay exact. {@code String.split} would drop them, and {@code lines()} normalises.
   */
  private static List<String> splitLinesKeepingTerminators(String source) {
    List<String> out = new ArrayList<>();
    int start = 0;
    for (int i = 0; i < source.length(); i++) {
      if (source.charAt(i) == '\n') {
        out.add(source.substring(start, i + 1));
        start = i + 1;
      }
    }
    if (start < source.length()) {
      out.add(source.substring(start));
    }
    return out;
  }

  /**
   * Character offset to LSP position. Columns are UTF-16 code units, which is what Java string
   * offsets already are and what LSP asks for.
   */
  private static final class LineIndex {
    private final int[] lineStarts;

    LineIndex(String source) {
      List<Integer> starts = new ArrayList<>();
      starts.add(0);
      for (int i = 0; i < source.length(); i++) {
        if (source.charAt(i) == '\n') {
          starts.add(i + 1);
        }
      }
      lineStarts = starts.stream().mapToInt(Integer::intValue).toArray();
    }

    int lineOf(int offset) {
      int low = 0;
      int high = lineStarts.length - 1;
      while (low < high) {
        int mid = (low + high + 1) / 2;
        if (lineStarts[mid] <= offset) {
          low = mid;
        } else {
          high = mid - 1;
        }
      }
      return low;
    }

    int characterOf(int offset) {
      return offset - lineStarts[lineOf(offset)];
    }
  }

  private JavaParser() {}
}
