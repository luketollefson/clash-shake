{-# LANGUAGE OverloadedStrings, RecordWildCards, ViewPatterns #-}
module ShakeClash
    ( ClashProject(..)
    , HDL(..)
    , clashShake
    , ClashKit(..)
    , clashRules
    , XilinxTarget(..), papilioPro, papilioOne, nexysA750T
    , xilinxISE
    , xilinxVivado
    , hexImage
    ) where

import Development.Shake hiding ((~>))
import Development.Shake.Command
import Development.Shake.FilePath
import Development.Shake.Config
import Development.Shake.Util

import Control.Monad.Trans

import Text.Mustache
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.IO as T
import qualified Data.Map as M
import qualified Data.HashMap.Strict as HM
import Data.List (sort, nub)
import Data.Maybe (fromMaybe)
import Data.Char (toLower)
import Control.Monad (guard, msum)
import Control.Monad.Reader
import qualified Data.ByteString as BS

import Clash.Driver.Types
import Clash.Prelude (pack)

data HDL
    = VHDL
    | Verilog
    | SystemVerilog
    deriving (Eq, Enum, Bounded, Show, Read)

hdlDir :: HDL -> FilePath
hdlDir VHDL = "vhdl"
hdlDir Verilog = "verilog"
hdlDir SystemVerilog = "systemverilog"

hdlExt :: HDL -> FilePath
hdlExt VHDL = "vhdl"
hdlExt Verilog = "v"
hdlExt SystemVerilog = "sv"

data XilinxTarget = XilinxTarget
    { targetFamily :: String
    , targetDevice :: String
    , targetPackage :: String
    , targetSpeed :: String
    }

targetMustache XilinxTarget{..} =
    [ "targetFamily" ~> T.pack targetFamily
    , "targetDevice" ~> T.pack targetDevice
    , "targetPackage" ~> T.pack targetPackage
    , "targetSpeed" ~> T.pack targetSpeed
    , "part" ~> T.pack (targetDevice <> targetPackage <> targetSpeed)
    ]

papilioPro :: XilinxTarget
papilioPro = XilinxTarget "Spartan6" "xc6slx9" "tqg144" "-2"

papilioOne :: XilinxTarget
papilioOne = XilinxTarget "Spartan3E" "xc3s500e" "vq100" "-5"

nexysA750T :: XilinxTarget
nexysA750T = XilinxTarget "Artrix7" "xc7a50t" "icsg324" "-1L"

data ClashProject = ClashProject
    { projectName :: String
    , clashModule :: String
    , clashTopName :: String
    , topName :: String
    , clashFlags :: [String]
    , shakeDir :: FilePath
    , buildDir :: FilePath
    , clashDir :: FilePath
    }

type ClashRules = ReaderT ClashProject Rules

data ClashKit = ClashKit
    { clash :: String -> [String] -> Action ()
    , manifestSrcs :: Action [FilePath]
    }

clashRules :: HDL -> FilePath -> Action () -> ClashRules ClashKit
clashRules hdl srcDir extraGenerated = do
    ClashProject{..} <- ask
    let synDir = buildDir </> clashDir
        rootDir = joinPath . map (const "..") . splitPath $ buildDir
        srcDir' = rootDir </> srcDir

    let clash cmd args = do
            clashExe <- fromMaybe ("clash") <$> getConfig "CLASH"
            cmd_ (Cwd buildDir) clashExe
              ([cmd, "-i" <> srcDir', "-outputdir", clashDir] <> clashFlags <> args)

    let manifest = synDir </> hdlDir hdl </> clashModule </> clashTopName </> clashTopName <.> "manifest"
        manifestSrcs = do
            need [manifest]
            Manifest{..} <- read <$> readFile' manifest
            let clashSrcs = map T.unpack componentNames <>
                            [ map toLower clashTopName <> "_types" | hdl == VHDL ]
            return [ synDir </> hdlDir hdl </> clashModule </> clashTopName </> c <.> hdlExt hdl | c <- clashSrcs ]

    lift $ do
      synDir </> hdlDir hdl <//> "*.manifest" %> \out -> do
          let src = srcDir </> clashModule <.> "hs" -- TODO
          alwaysRerun
          need [ src ]
          extraGenerated
          clash "clash" [case hdl of { VHDL -> "--vhdl"; Verilog -> "--verilog"; SystemVerilog -> "--systemverilog" }, rootDir </> src]

      phony "clashi" $ do
          let src = srcDir </> clashModule <.> "hs" -- TODO
          clash "clashi" [rootDir </> src]

      phony "clash" $ do
          need [manifest]

      phony "clean-clash" $ do
          putNormal $ "Cleaning files in " ++ synDir
          removeFilesAfter synDir [ "//*" ]

    let kit = ClashKit{..}
    return kit


xilinxISE :: ClashKit -> XilinxTarget -> FilePath -> FilePath -> ClashRules ()
xilinxISE kit@ClashKit{..} fpga srcDir targetDir = do
    ClashProject{..} <- ask
    let outDir = buildDir </> targetDir
        rootDir = joinPath . map (const "..") . splitPath $ outDir

    let ise tool args = do
            root <- getConfig "ISE_ROOT"
            wrap <- getConfig "ISE"
            let exe = case (wrap, root) of
                    (Just wrap, _) -> [wrap, tool]
                    (Nothing, Just root) -> [root </> "ISE/bin/lin64" </> tool]
                    (Nothing, Nothing) -> error "ISE_ROOT or ISE must be set"
            cmd_ (Cwd outDir) exe args

    let getFiles dir pats = getDirectoryFiles srcDir [ dir </> pat | pat <- pats ]
        hdlSrcs = getFiles "src-hdl" ["*.vhdl", "*.v", "*.ucf" ]
        ipCores = getFiles "ipcore_dir" ["*.xco", "*.xaw"]

    lift $ do
        outDir <//> "*.tcl" %> \out -> do
            let src = shakeDir </> "xilinx-ise.tcl.mustache"
            s <- T.pack <$> readFile' src
            alwaysRerun

            srcs1 <- manifestSrcs
            srcs2 <- hdlSrcs
            cores <- ipCores

            template <- case compileTemplate src s of
                Left err -> fail (show err)
                Right template -> return template
            let values = object . mconcat $
                         [ [ "project" ~> T.pack projectName ]
                         , [ "top" ~> T.pack topName ]
                         , targetMustache fpga
                         , [ "srcs" ~> mconcat
                             [ [ object [ "fileName" ~> (rootDir </> src) ] | src <- srcs1 ]
                             , [ object [ "fileName" ~> (rootDir </> srcDir </> src) ] | src <- srcs2 ]
                             , [ object [ "fileName" ~> core ] | core <- cores ]
                             ]
                           ]
                         , [ "ipcores" ~> [ object [ "name" ~> takeBaseName core ] | core <- cores ] ]
                         ]
            writeFileChanged out . T.unpack $ substitute template values

        outDir </> "ipcore_dir" <//> "*" %> \out -> do
            let src = srcDir </> makeRelative outDir out
            copyFileChanged src out

        phony (takeBaseName targetDir </> "ise") $ do
            need [outDir </> projectName <.> "tcl"]
            ise "ise" [outDir </> projectName <.> "tcl"]

        phony (takeBaseName targetDir </> "bitfile") $ do
            need [outDir </> topName <.> "bit"]

        outDir </> topName <.> "bit" %> \_out -> do
            srcs1 <- manifestSrcs
            srcs2 <- hdlSrcs
            cores <- ipCores
            need $ mconcat
              [ [ outDir </> projectName <.> "tcl" ]
              , [ src | src <- srcs1 ]
              , [ srcDir </> src | src <- srcs2 ]
              , [ outDir </> core | core <- cores ]
              ]
            ise "xtclsh" [projectName <.> "tcl", "rebuild_project"]

xilinxVivado :: ClashKit -> XilinxTarget -> FilePath -> FilePath -> ClashRules ()
xilinxVivado kit@ClashKit{..} fpga srcDir targetDir = do
    ClashProject{..} <- ask
    let outDir = buildDir </> targetDir
        rootDir = joinPath . map (const "..") . splitPath $ outDir

    let vivado tool args = do
            root <- getConfig "VIVADO_ROOT"
            wrap <- getConfig "VIVADO"
            let exe = case (wrap, root) of
                    (Just wrap, _) -> [wrap, tool]
                    (Nothing, Just root) -> [root </> "bin" </> tool]
                    (Nothing, Nothing) -> error "VIVADO_ROOT or VIVADO must be set"
            cmd_ (Cwd outDir) exe args

    let getFiles dir pats = getDirectoryFiles srcDir [ dir </> pat | pat <- pats ]
        hdlSrcs = getFiles "src-hdl" ["*.vhdl", "*.v" ]
        constrSrcs = getFiles "src-hdl" ["*.xdc" ]
        ipCores = getFiles "ip" ["*.xci"]

    lift $ do
        outDir <//> "*.xpr" %> \out -> do
            let tcl = takeDirectory out -<.> "tcl"
            need [tcl]
            vivado "vivado"
              [ "-mode batch"
              , "-nojournal"
              , "-nolog"
              , "-source", rootDir </> tcl
              ]

        outDir <//> "*.tcl" %> \out -> do
            let src = shakeDir </> "xilinx-vivado.tcl.mustache"
            s <- T.pack <$> readFile' src
            alwaysRerun

            srcs1 <- manifestSrcs
            srcs2 <- hdlSrcs
            cores <- ipCores
            constrs <- constrSrcs

            template <- case compileTemplate src s of
                Left err -> fail (show err)
                Right template -> return template
            let values = object . mconcat $
                         [ [ "project" ~> T.pack projectName ]
                         , [ "top" ~> T.pack topName ]
                         , targetMustache fpga
                         , [ "board" ~> T.pack "digilentinc.com:nexys-a7-50t:part0:1.0" ] -- TODO
                         , [ "srcs" ~> mconcat
                             [ [ object [ "fileName" ~> src ] | src <- srcs1 ]
                             , [ object [ "fileName" ~> (srcDir </> src) ] | src <- srcs2 ]
                             ]
                           ]
                         , [ "coreSrcs" ~> object
                             [ "nonempty" ~> not (null cores)
                             , "items" ~> [ object [ "fileName" ~> (srcDir </> core) ] | core <- cores ]
                             ]
                           ]
                         , [ "ipcores" ~> [ object [ "name" ~> takeBaseName core ] | core <- cores ] ]
                         , [ "constraintSrcs" ~> [ object [ "fileName" ~> (srcDir </> src) ] | src <- constrs ] ]
                         ]
            writeFileChanged out . T.unpack $ substitute template values

        phony (takeBaseName targetDir </> "vivado") $ do
            need [outDir </> projectName </> projectName <.> "xpr"]
            vivado "vivado" [outDir </> projectName </> projectName <.> "tcl"]

        -- phony (takeBaseName targetDir </> "bitfile") $ do
        --     need [outDir </> topName <.> "bit"]

        -- outDir </> topName <.> "bit" %> \_out -> do
        --     srcs1 <- manifestSrcs
        --     srcs2 <- hdlSrcs
        --     cores <- ipCores
        --     need $ mconcat
        --       [ [ outDir </> projectName <.> "tcl" ]
        --       , [ src | src <- srcs1 ]
        --       , [ srcDir </> src | src <- srcs2 ]
        --       , [ outDir </> core | core <- cores ]
        --       ]
        --     ise "xtclsh" [projectName <.> "tcl", "rebuild_project"]

clashShake :: ClashProject -> ClashRules () -> IO ()
clashShake proj@ClashProject{..} rules = shakeArgs shakeOptions{ shakeFiles = buildDir } $ do
    usingConfigFile "build.mk"
    cfg <- liftIO $ readConfigFile "build.mk"
    runReaderT rules proj

    phony "clean" $ do
        putNormal $ "Cleaning files in " ++ buildDir
        removeFilesAfter buildDir [ "//*" ]

    want $ case HM.lookup "TARGET" cfg of
        Nothing -> ["clash"]
        Just target -> [target </> "bitfile"]

hexImage :: Maybe Int -> FilePath -> FilePath -> Action ()
hexImage size src out = do
    bs <- liftIO $ maybe id ensureSize size . BS.unpack <$> BS.readFile src
    let bvs = map (filter (/= '_') . show . pack) bs
    writeFileChanged out (unlines bvs)
  where
    ensureSize size bs = take size $ bs <> repeat 0
