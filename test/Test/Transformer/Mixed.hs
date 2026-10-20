{-# LANGUAGE OverloadedStrings #-}

-- | The projection, over a cell with one of everything in it.
--
-- The parser is stubbed rather than run, so these are a test of the sifting and the position
-- mapping alone and need no JVM. Test.Transformer.Parser covers the real parser.
module Test.Transformer.Mixed (spec) where

import Data.String.Interpolate
import Data.Text (Text)
import qualified Data.Text as T
import Language.LSP.Notebook.JavaParser
import Language.LSP.Notebook.SnippetSifter
import Language.LSP.Protocol.Types (Position(..))
import Language.LSP.Transformer
import Test.Sandwich


testCode :: Text
testCode = [__i|import java.util.List;

                int x = 41;

                int doubled(int v) {
                    return v * 2;
                }

                System.out.println(doubled(x));
                x + 1|]

-- | What java-parser reports for 'testCode'. Pinned by Test.Transformer.Parser, which runs
-- the real thing and checks it still says this.
units :: [Unit]
units = [
  Unit CategoryImport "IMPORT" "SINGLE_TYPE_IMPORT_SUBKIND" 0 0 0 22
  , Unit CategoryDeclaration "VAR" "VAR_DECLARATION_WITH_INITIALIZER_SUBKIND" 2 0 2 11
  , Unit CategoryDeclaration "METHOD" "METHOD_SUBKIND" 4 0 6 1
  , Unit CategoryStatement "ERRONEOUS" "UNKNOWN_SUBKIND" 8 0 8 31
  , Unit CategoryExpression "ERRONEOUS" "UNKNOWN_SUBKIND" 9 0 9 5
  ]

params :: SnippetSifterParams
params = SnippetSifterParams {
  parserClient = stubParserClient (const (Right units))
  , className = "__Cells"
  , execMethodName = "__notebookExec"
  }

-- | Imports above the class; the field and the method inside it; the statement and the
-- expression inside the method, with the expression assigned to something so it is legal.
--
-- The three blank lines are the cell's own (original lines 1, 3 and 7): no snippet claims a
-- blank line, so it lands in the body. They are not cosmetic -- every original line has to
-- map somewhere for a position on it to survive the round trip.
expected :: Text
expected = [__i|import java.util.List;
                class __Cells {
                int x = 41;
                int doubled(int v) {
                    return v * 2;
                }
                void __notebookExec() throws Exception {



                System.out.println(doubled(x));
                Object __expr0 =
                x + 1
                ;
                }
                }|]

spec :: TopSpec
spec = describe "Mixed cell" $ do
  it "sorts snippets into imports, class body and method body" $ do
    (projected, _ :: SnippetSifter, err) <- project params (listToDoc (T.splitOn "\n" testCode))
    err `shouldBe` Right ()
    T.intercalate "\n" (docToList projected) `shouldBe` expected

  it "maps a position in a hoisted declaration" $ do
    -- "doubled" on the method's line: original line 4 -> projected line 3, same column.
    roundTrip (Position 4 4) (Position 3 4)

  it "maps a position in the method body" $
    roundTrip (Position 8 11) (Position 10 11)

  it "maps a position inside a wrapped expression" $
    -- The "Object __exprN =" prefix is a line of its own, so the column is untouched.
    roundTrip (Position 9 4) (Position 12 4)

  it "refuses to map a synthetic line back to the notebook" $ do
    (_, sifter :: SnippetSifter, _) <- project params (listToDoc (T.splitOn "\n" testCode))
    -- Projected line 1 is "class __Cells {", which exists in no cell.
    untransformPosition sifter (Position 1 0) `shouldBe` Nothing

  it "leaves a real .java file alone" $ do
    let doc = listToDoc (T.splitOn "\n" testCode)
    (projected, sifter :: SnippetSifter, err) <- project IdentityParams doc
    err `shouldBe` Right ()
    docToList projected `shouldBe` docToList doc
    transformPosition sifter (Position 8 11) `shouldBe` Just (Position 8 11)

roundTrip :: Position -> Position -> ExampleT context IO ()
roundTrip original projected = do
  (_, sifter :: SnippetSifter, _) <- project params (listToDoc (T.splitOn "\n" testCode))
  transformPosition sifter original `shouldBe` Just projected
  untransformPosition sifter projected `shouldBe` Just original
