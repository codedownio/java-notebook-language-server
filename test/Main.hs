import Test.Sandwich

import qualified Test.Transformer.Mixed


spec :: TopSpec
spec = describe "java-notebook-language-server" $
  Test.Transformer.Mixed.spec

main :: IO ()
main = runSandwichWithCommandLineArgs defaultOptions spec
