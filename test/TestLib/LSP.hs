{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeOperators #-}

module TestLib.LSP (
  doNotebookSession
  , doRawSession

  , introduceMaybeBubblewrap
  , introduceJnls

  , listShouldContain
  ) where

import Control.Monad (void)
import Control.Monad.Catch (MonadMask)
import Control.Monad.Logger
import Control.Monad.Reader
import Data.Function (fix)
import qualified Data.List as L
import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Set as S
import Data.String.Interpolate
import qualified Data.Text as T
import GHC.Stack
import Language.LSP.Protocol.Types
import System.FilePath
import System.IO
import Test.Sandwich
import Test.Sandwich.Contexts.Files
import Test.Sandwich.Contexts.Nix
import UnliftIO (MonadUnliftIO)
import UnliftIO.Directory
import UnliftIO.Exception
import UnliftIO.Process
import qualified "lsp-test" Language.LSP.Test as LSP hiding (message)
import qualified Language.LSP.Test.Helpers as Helpers
import qualified System.Directory as Dir


doNotebookSession :: (
  Helpers.LspContext ctx m
  , HasFile ctx "java-notebook-language-server"
  , HasFile ctx "jdtls"
  ) => T.Text -> (Helpers.LspSessionInfo -> LSP.Session (ExampleT ctx m) a) -> ExampleT ctx m a
doNotebookSession = doSession "main.ipynb"

doRawSession :: (
  Helpers.LspContext ctx m
  , HasFile ctx "java-notebook-language-server"
  , HasFile ctx "jdtls"
  ) => T.Text -> (Helpers.LspSessionInfo -> LSP.Session (ExampleT ctx m) a) -> ExampleT ctx m a
doRawSession = doSession "main.java"

doSession :: (
  Helpers.LspContext ctx m
  , HasFile ctx "java-notebook-language-server"
  , HasFile ctx "jdtls"
  ) => FilePath -> T.Text -> (Helpers.LspSessionInfo -> LSP.Session (ExampleT ctx m) a) -> ExampleT ctx m a
doSession fileName codeToUse cb = do
  jnlsPath <- askFile @"java-notebook-language-server"
  jdtlsPath <- askFile @"jdtls"

  -- JDT LS builds its project for a loose folder out of an Eclipse linked resource, and
  -- Eclipse refuses to link a folder containing its own workspace. The session's HOME *is*
  -- the workspace and jdtls defaults -data to $HOME/.cache, so it needs somewhere else.
  --
  -- Directly under /tmp rather than TMPDIR: bubblewrap mounts a fresh tmpfs on /tmp, so a
  -- TMPDIR path like /tmp/nix-shell.XXX/... has no parent inside the sandbox and Eclipse
  -- hangs creating its workspace. Each session gets its own tmpfs, so one name is enough.
  let dataDir = "/tmp/jnls-jdtls-data" in do
    let lspConfig = Helpers.LanguageServerConfig {
          lspConfigName = "java-notebook-language-server"
          , lspConfigVersion = Nothing
          , lspConfigDescription = Just "Java notebook language server"
          , lspConfigDisplayName = Just "Java Notebook Language Server"
          , lspConfigIcon = Nothing
          , lspConfigExtensions = [".java"]
          , lspConfigAttrs = S.fromList ["java"]
          , lspConfigType = Helpers.LanguageServerTypeStream
          , lspConfigPrimary = Just True
          , lspConfigArgs = [
              T.pack jnlsPath
              , "--wrapped-server", T.pack jdtlsPath
              , "--wrapped-args", T.pack ("-data " <> dataDir)
              , "--log-level", "debug"
              ]
          , lspConfigLanguageId = Just LanguageKind_Java
          , lspConfigInitializationOptions = Just initializationOptions
          , lspConfigNotebookSuffix = ".java"
          , lspConfigKernelName = Nothing
          , lspConfigEnv = Nothing
          , lspConfigFile = Nothing
          , lspConfigIsBuiltIn = Just False
          }

    pathToUse <- getBasicPath
    closure <- getLspClosure [jnlsPath, jdtlsPath] pathToUse

    let lspSessionOptions = (Helpers.defaultLspSessionOptions lspConfig) {
          Helpers.lspSessionOptionsInitialFileName = fileName
          , Helpers.lspSessionOptionsInitialLanguageKind = LanguageKind_Java
          , Helpers.lspSessionOptionsInitialCode = codeToUse
          , Helpers.lspSessionOptionsExtraFiles = []
          , Helpers.lspSessionOptionsPathEnvVar = pathToUse
          , Helpers.lspSessionOptionsReadOnlyBinds = closure
          -- Generous, but never reached in practice: jdtls answers promptly even before
          -- its project is ready, and waitUntil below handles the not-ready-yet answers.
          , Helpers.lspSessionOptionsModifySessionConfig = \x -> x { LSP.messageTimeout = 90 }
          }

    Helpers.withLspSession lspSessionOptions cb

-- | The same settings codedown-languages ships. Without them JDT LS runs its Maven and
-- Gradle importers, which reach for the network -- and the test sandbox has none.
initializationOptions :: A.Object
initializationOptions = KM.fromList [("settings", A.object [
  ("java", A.object [
      ("import", A.object [
          ("maven", A.object [("enabled", A.Bool False)])
          , ("gradle", A.object [("enabled", A.Bool False)])
          ])
      , ("configuration", A.object [("updateBuildConfiguration", A.String "disabled")])
      ])
  ])]

getBasicPath :: (MonadUnliftIO m, MonadLogger m) => m FilePath
getBasicPath =
  bracket (liftIO $ openFile "/dev/null" WriteMode) (liftIO . hClose) $ \devNull -> do
    result <- readCreateProcess ((proc "nix" ["run", ".#print-basic-path"]) { std_err = UseHandle devNull }) ""
    let ret = T.unpack $ T.strip $ T.pack result
    info [i|getBasicPath: #{ret}|]
    return ret

getLspClosure :: (MonadUnliftIO m, MonadLogger m) => [FilePath] -> FilePath -> m [FilePath]
getLspClosure paths pathToUse = do
  closure <- (fmap T.unpack . Prelude.filter (/= "") . T.splitOn "\n" . T.pack) <$> readCreateProcess (
    proc "nix" (["path-info", "-r"] ++ paths ++ splitSearchPath pathToUse)
    ) ""
  info [i|Got Nix closure with #{L.length closure} entries|]
  return closure

introduceMaybeBubblewrap :: (
  HasBaseContext context, MonadIO m, MonadMask m, MonadUnliftIO m
  ) => SpecFree (LabelValue "maybeBubblewrap" (Maybe FilePath) :> context) m () -> SpecFree context m ()
introduceMaybeBubblewrap = introduceWith [i|maybeBubblewrap|] Helpers.maybeBubblewrap $ \action -> do
#ifdef darwin_HOST_OS
  void $ action Nothing
#else
  liftIO (Dir.findExecutable "bwrap") >>= \case
    Nothing -> do
      info "bubblewrap (bwrap) not found, proceeding without sandbox"
      void $ action Nothing
    Just path -> do
      info [i|Found bubblewrap at: #{path}|]
      void $ action (Just path)
#endif

-- | The wrapped build, so java-parser is on the server's PATH the way it is in a release.
introduceJnls :: forall context m. (
  HasBaseContext context, HasNixContext context, MonadUnliftIO m
  )
  => SpecFree (LabelValue "file-java-notebook-language-server" (EnvironmentFile "java-notebook-language-server") :> context) m ()
  -> SpecFree context m ()
introduceJnls = introduce [i|java-notebook-language-server (via Nix)|] (Label :: Label "file-java-notebook-language-server" (EnvironmentFile "java-notebook-language-server")) alloc (const $ return ())
  where
    alloc = do
      projectRoot <- getProjectRoot
      dir <- buildNixCallPackageDerivation [i|
{ ... }:

let
  flake = builtins.getFlake "#{projectRoot}";
in flake.packages.x86_64-linux.staticWrapped
|]
      liftIO (findExecutablesInDirectories [dir </> "bin"] "java-notebook-language-server") >>= \case
        (x:_) -> return (EnvironmentFile x :: EnvironmentFile "java-notebook-language-server")
        _ -> expectationFailure [i|Couldn't find binary in #{dir </> "bin"}|]

getProjectRoot :: (HasCallStack, MonadIO m) => m FilePath
getProjectRoot = do
  startDir <- getCurrentDirectory
  flip fix startDir $ \loop dir ->
    doesDirectoryExist (dir </> ".git") >>= \case
      True -> return dir
      False -> let dir' = takeDirectory dir in
                 if | dir == dir' -> throwIO $ userError [i|Couldn't find project root from #{startDir}|]
                    | otherwise -> loop dir'

listShouldContain :: (HasCallStack, MonadIO m, Eq a, Show a) => [a] -> a -> m ()
listShouldContain haystack needle
  | L.elem needle haystack = return ()
  | otherwise = expectationFailure [i|Expected list to contain #{show needle}, but had: #{show haystack}|]
