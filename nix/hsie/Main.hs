{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE TypeFamilies      #-}

-- | Haskell Imports and Exports tool
--
-- This tool parses imports and exports from Haskell source files and provides
-- analysis on these imports. For example, you can check whether consistent
-- import aliases are used across your codebase.

module Main (main) where

import qualified Data.Aeson                              as JSON
import qualified Data.ByteString.Lazy.Char8              as LBS8
import qualified Data.Csv                                as Csv
import qualified Data.Map                                as Map
import qualified Data.Set                                as Set
import qualified Data.Text                               as T
import qualified Data.Text.IO                            as T
import qualified Dot
import qualified GHC
import qualified Language.Haskell.GHC.ExactPrint.Parsers as ExactPrint
import qualified Options.Applicative                     as O
import qualified System.FilePath                         as FP

import Control.Applicative        ((<|>))
import Data.Aeson.Encode.Pretty   (encodePretty)
import Data.Function              ((&))
import Data.List                  (intercalate)
import Data.Maybe                 (catMaybes, mapMaybe)
import Data.Text                  (Text)
import GHC.Generics               (Generic)
import HsExtension                (GhcPs)
import Module                     (moduleNameString)
import OccName                    (occNameString)
import RdrName                    (rdrNameOcc)
import System.Directory.Recursive (getFilesRecursive)
import System.Exit                (exitFailure)

-- TYPES

data Options =
  Options
    { command :: Command
    , sources :: [Source]
    }

data Source
  = SourceDir FilePath
  | ImportsDir FilePath
  deriving (Generic, JSON.ToJSON)

sourceDir :: Source -> FilePath
sourceDir (SourceDir path)  = path
sourceDir (ImportsDir path) = path

instance Csv.ToField Source where
  toField (SourceDir _)  = "source"
  toField (ImportsDir _) = "imports"

data Command
  = Dump OutputFormat
  | GraphSymbols
  | GraphModules
  | CheckAliases
  | CheckWildcards [Text]

data OutputFormat = OutputCsv | OutputJson

data ImportedSymbol =
  ImportedSymbol
    { impSourceFile :: Text
    , impSourceType :: Source
    , impFromModule :: Text
    , impModule     :: Text
    , impQualified  :: ImportQualified
    , impAs         :: Maybe Text
    , impHiding     :: ImportHiding
    , impSymbol     :: Maybe Text
    }
    deriving (Generic, Csv.ToNamedRecord, Csv.DefaultOrdered, JSON.ToJSON)

data ImportQualified
  = Qualified
  | NotQualified
  deriving (Eq, Generic, JSON.ToJSON)

instance Csv.ToField ImportQualified where
  toField Qualified    = "qualified"
  toField NotQualified = "not qualified"

data ImportHiding
  = Wildcard
  | Hiding
  | NotHiding
  deriving (Eq, Generic, JSON.ToJSON)

instance Csv.ToField ImportHiding where
  toField Wildcard  = "wildcard"
  toField Hiding    = "hiding"
  toField NotHiding = "not hiding"

-- | Mapping of modules to their aliases and to the files they are found in
type ModuleAliases = [(Text, [(Text, [Text])])]

-- | Mapping of modules to files
type WildcardImports = [(Text, [Text])]


-- MAIN

main :: IO ()
main =
  run =<< O.customExecParser prefs infoOpts
  where
    prefs = O.prefs $ O.subparserInline <> O.showHelpOnEmpty
    infoOpts =
      O.info (O.helper <*> opts) $
        O.fullDesc
        <> O.header "hsie - Swiss army knife for HaSkell Imports and Exports"
        <> O.progDesc "Parse Haskell code to analyze it's imports and exports"
    opts =
      Options <$> commandOption <*> O.some (srcOption <|> importsOption)
    srcOption =
      O.option (SourceDir <$> O.str) $
        O.long "src"
        <> O.short 's'
        <> O.metavar "SRCDIR"
        <> O.help "Haskell source directory"
        <> O.action "directory"
    importsOption =
      O.option (ImportsDir <$> O.str) $
        O.long "imports"
        <> O.short 'i'
        <> O.metavar "IMPORTSDIR"
        <> O.help "Imports directory generated with GHC's '--ddump-minimal-imports'"
        <> O.action "directory"
    commandOption =
      O.subparser $
        command "dump" "Dump imported symbols as CSV or JSON"
          (Dump <$> jsonOutputFlag)
        <> command "graph-modules" "Print dot graph of module imports"
             (pure GraphModules)
        <> command "graph-symbols" "Print dot graph of symbol imports"
             (pure GraphSymbols)
        <> command "check-aliases"
             "Check that aliases of imported modules are consistent"
             (pure CheckAliases)
        <> command "check-wildcards"
             "Check that no unwanted modules are imported as wildcards"
             (CheckWildcards <$> O.many okModuleOption)
    command name desc options =
      O.command name . O.info (O.helper <*> options) $ O.progDesc desc
    jsonOutputFlag =
      O.flag OutputCsv OutputJson $
        O.long "json" <> O.short 'j' <> O.help "Output JSON"
    okModuleOption =
      O.option O.auto $
        O.long "ok"
        <> O.short 'o'
        <> O.metavar "OKMODULE"
        <> O.help "Module that is ok to import as wildcard"

run :: Options -> IO ()
run Options{command, sources} =
  runCommand command . concat =<< mapM sourceSymbols sources
  where
    runCommand :: Command -> [ImportedSymbol] -> IO ()
    runCommand (Dump format) = LBS8.putStr . dump format
    runCommand GraphSymbols = T.putStr . symbolsGraph
    runCommand GraphModules = T.putStr . Dot.encode . modulesGraph
    runCommand CheckAliases = runInconsistentAliases . inconsistentAliases
    runCommand (CheckWildcards okModules) = runWildcards . wildcards okModules

    runInconsistentAliases :: ModuleAliases -> IO ()
    runInconsistentAliases [] = T.putStrLn "No inconsistent module aliases found."
    runInconsistentAliases xs = T.putStr (formatInconsistentAliases xs) >> exitFailure

    runWildcards :: WildcardImports -> IO ()
    runWildcards [] = T.putStrLn "No unwanted wildcard imports found."
    runWildcards xs = T.putStr (formatWildcards xs) >> exitFailure


-- SYMBOLS

-- | Parse all imported symbols from a source of Haskell source files
sourceSymbols :: Source -> IO [ImportedSymbol]
sourceSymbols source = do
  files <-
    case source of
      SourceDir dirpath ->
        filterExts [".hs"] <$> getFilesRecursive dirpath
      ImportsDir dirpath ->
        filterExts [".imports"] <$> getFilesRecursive dirpath
  concat <$> mapM moduleSymbols files
  where
    filterExts exts = filter $ flip elem exts . FP.takeExtension
    moduleSymbols filepath = do
      GHC.HsModule{..} <- parseModule filepath
      return $ concatMap (importSymbols source filepath . GHC.unLoc) hsmodImports

-- | Parse a Haskell module
parseModule :: String -> IO (GHC.HsModule GhcPs)
parseModule filepath = do
  result <- ExactPrint.parseModule filepath
  case result of
    Right (_, hsmod) ->
      return $ GHC.unLoc hsmod
    Left (loc, err) ->
      fail $ "Error with " <> show filepath <> " at " <> show loc <> ": " <> err

-- | Symbols imported in an import declaration.
--
-- If the import is a wildcard, i.e. no symbols are selected for import, then
-- only one item is returned.
importSymbols :: Source -> FilePath -> GHC.ImportDecl GhcPs -> [ImportedSymbol]
importSymbols _ _  (GHC.XImportDecl _) = mempty
importSymbols source filepath GHC.ImportDecl{..} =
  case ideclHiding of
    Just (hiding, syms) ->
      symbol (if hiding then Hiding else NotHiding) . Just . GHC.unLoc <$> GHC.unLoc syms
    Nothing ->
      [ symbol Wildcard Nothing ]
  where
    symbol hiding sym =
      ImportedSymbol
        { impSourceFile = T.pack filepath
        , impSourceType = source
        , impFromModule = T.pack $ moduleFromPath filepath
        , impModule = T.pack . moduleNameString . GHC.unLoc $ ideclName
        , impQualified = if ideclQualified then Qualified else NotQualified
        , impAs = T.pack . moduleNameString . GHC.unLoc <$> ideclAs
        , impHiding = hiding
        , impSymbol = T.pack . occNameString . rdrNameOcc . GHC.ieName <$> sym
        }
    moduleFromPath =
      intercalate "." . FP.splitDirectories . FP.dropExtension . relativePath
    relativePath = FP.makeRelative $ sourceDir source


-- DUMP

-- | Dump list of symbols as CSV or JSON
dump :: OutputFormat -> [ImportedSymbol] -> LBS8.ByteString
dump OutputCsv  = Csv.encodeDefaultOrderedByName
dump OutputJson = encodePretty


-- ALIASES

-- | Find modules that are imported under different aliases
inconsistentAliases :: [ImportedSymbol] -> ModuleAliases
inconsistentAliases symbols =
  fmap moduleAlias symbols
    & foldr insertSetMapMap Map.empty
    & Map.map (aliases . Map.toList)
    & Map.filter ((<) 1 . length)
    & Map.toList
  where
    moduleAlias ImportedSymbol{..} = (impModule, impAs, impSourceFile)
    insertSetMapMap (k1, k2, v) =
      Map.insertWith (Map.unionWith Set.union) k1
        (Map.singleton k2 $ Set.singleton v)
    aliases :: [(Maybe Text, Set.Set Text)] -> [(Text, [Text])]
    aliases = mapMaybe (\(k, v) -> fmap (, Set.toList v) k)

formatInconsistentAliases :: ModuleAliases -> Text
formatInconsistentAliases modules =
  "The following imports have inconsistent aliases:\n\n"
    <> T.concat (fmap formatModule modules)
  where
    formatModule (modName, aliases) =
      "Module '"
        <> modName
        <> "' has the aliases:\n"
        <> T.concat (fmap formatAlias aliases)
        <> "\n"
    formatAlias (alias, sourceFiles) =
      "  '"
        <> alias
        <> "' in file"
        <> (if length sourceFiles > 2 then "s" else "")
        <> ":\n"
        <> T.concat (fmap formatFile sourceFiles)
    formatFile sourceFile =
      "    " <> sourceFile <> "\n"


-- WILDCARDS

-- | Find modules that are imported as wildcards, excluding whitelisted modules.
--
-- Wildcard imports are ones that are not qualified and do not specify which
-- symbols should be imported.
wildcards :: [Text] -> [ImportedSymbol] -> WildcardImports
wildcards okModules =
  groupByFile . filter isWildcard . filter (not . isOkModule)
  where
    isWildcard ImportedSymbol{..} =
      impQualified == NotQualified && impHiding /= NotHiding
    isOkModule = flip Set.member (Set.fromList okModules) . impModule
    groupByFile = Map.toList . fmap Set.toList . foldr insertMap Map.empty
    insertMap ImportedSymbol{..} =
      Map.insertWith Set.union impSourceFile (Set.singleton impModule)

formatWildcards :: WildcardImports -> Text
formatWildcards files =
  "Modules in the following files were imported as wildcards:\n\n"
    <> T.concat (fmap formatFile files)
  where
    formatFile (filepath, modules) =
      "In " <> filepath <> ":\n" <> T.concat (fmap formatModule modules) <> "\n"
    formatModule moduleName = "  " <> moduleName <> "\n"


-- GRAPHS

modulesGraph :: [ImportedSymbol] -> Dot.DotGraph
modulesGraph symbols =
  Dot.DotGraph Dot.Strict Dot.Directed (Just "Modules") $ fmap edge edges
  where
    edge (from, to) =
      Dot.StatementEdge $ Dot.EdgeStatement
        (Dot.ListTwo (edgeNode from) (edgeNode to) mempty) mempty
    edgeNode t = Dot.EdgeNode $ Dot.NodeId (Dot.Id t) Nothing
    edges = unique . fmap edgeTuple . filter isInternalModule $ symbols
    edgeTuple ImportedSymbol{..} = (impFromModule, impModule)
    isInternalModule = flip Set.member internalModules . impModule
    internalModules = Set.fromList $ fmap impFromModule symbols
    unique = Set.toList . Set.fromList

-- Building Text directly as the Dot package currently doesn't support subgraphs.
symbolsGraph :: [ImportedSymbol] -> Text
symbolsGraph symbols =
  "digraph Symbols {\n"
    <> "  rankdir=LR\n"
    <> "  ranksep=5\n"
    <> T.concat (fmap edge edges)
    <> T.concat (fmap cluster symbolsByModule)
    <> "}\n"
  where
    edge (from, to, symbol) =
      "  "
        <> quoted from
        <> " -> "
        <> quoted (to <> maybe "" ("." <>) symbol)
        <> "\n"
    cluster (moduleName, clusterSymbols) =
      "  subgraph "
        <> quoted ("cluster_" <> moduleName)
        <> " {\n"
        <> "    " <> quoted moduleName <> "\n"
        <> T.concat (fmap (clusterNode moduleName) clusterSymbols)
        <> "  }\n"
    clusterNode moduleName symbol =
      "    " <> quoted (moduleName <> "." <> symbol) <> "\n"
    quoted t = "\"" <> t <> "\""
    edges = unique . fmap edgeTuple . filter isInternalModule $ symbols
    edgeTuple ImportedSymbol{..} = (impFromModule, impModule, impSymbol)
    internalModules = Set.fromList $ fmap impFromModule symbols
    isInternalModule = flip Set.member internalModules . impModule
    unique = Set.toList . Set.fromList
    symbolsByModule =
      Map.toList . Map.map (catMaybes . Set.toList) . foldr insertMap Map.empty $ edges
    insertMap (_, to, symbol) =
      Map.insertWith Set.union to $ Set.singleton symbol
