--------------------------------------------------------------------------------
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DeriveAnyClass #-}

{-# OPTIONS_GHC -Wno-incomplete-patterns #-}
{-# OPTIONS_GHC -fno-warn-redundant-constraints -O2 #-}
--------------------------------------------------------------------------------

module Compilers
    ( compileToPandocAST
    , renderPandocASTtoLaTeX
    , renderPandocASTtoPDF
    , renderPandocASTtoHTML
    , buildLaTeX
    ) where

import           Hakyll
import           XMLWalker

import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Text.Lazy as LT
import qualified Data.ByteString.Lazy as LB
import qualified Data.Map as M
import           Data.Char                     (isDigit, isSpace, isAlpha)
import           Data.Maybe                    (fromMaybe, mapMaybe)
import           Data.List                     (isPrefixOf, stripPrefix, sort, intersperse, zipWith4)
import           Data.Fixed                    (Fixed)
import           Data.Functor                  ((<&>))
import           Data.Traversable
import           Data.Foldable
import qualified Data.Set as S
import qualified Data.Char as C
import qualified Data.Binary as B

import           GHC.IO                        (unsafePerformIO)

import           System.Process                (system, readProcessWithExitCode)
import           System.Exit                   (ExitCode(..))
import           System.Directory              (createDirectory, setCurrentDirectory, listDirectory,
                                                renameFile, copyFile, doesFileExist)
import           System.FilePath               (replaceExtension, takeDirectory,
                                                dropExtensions, takeFileName, takeBaseName,
                                                replaceBaseName, takeExtension, (</>), (<.>), (-<.>),
                                                replaceDirectory, dropExtension, stripExtension)

import           Control.Monad
import           Control.Applicative
import           Control.Monad.State.Lazy
import qualified Control.Monad.Reader as R
import           Control.Monad.Except


import           Text.Pandoc
import           Text.Pandoc.Walk
import           Text.Pandoc.Shared            (filteredFilesFromArchive)
import           Text.Pandoc.Builder as B
import           Text.Pandoc.Parsing           (runF, defaultParserState, extractIdClass)
import           Text.Pandoc.Readers.Markdown  (yamlToMeta)
import           Text.Blaze.Html5.Attributes   (xmlns, item)
import qualified Text.XML as X
import Text.Pandoc.Citeproc (processCitations)

buildLaTeX :: Item String -> Compiler (Item TmpFile)
buildLaTeX item = do
    latexFile@(TmpFile latexPath) <- newTmpFile "lualatex.tex"
    unsafeCompiler $ writeFile latexPath $ itemBody item
    runLuaLaTeX latexPath >>= makeItem . TmpFile

runLuaLaTeX :: FilePath  -> Compiler FilePath
runLuaLaTeX latexPath = do
    exitCode <- unsafeCompiler $ system $ unwords
        ["lualatex", "-halt-on-error", "-output-directory"
        , takeDirectory latexPath, latexPath, ">/dev/null", "2>&1"]
    id <- getUnderlying
    let idPath = toFilePath id
        logDir = takeDirectory idPath </> "_texlog"
        logDestinationPath = case identifierVersion id of
            Nothing -> logDir </> takeBaseName idPath <.> "log"
            Just v -> logDir </> (takeBaseName idPath ++ "#" ++ v) <.> "log"
        logSourcePath = latexPath -<.> "log"
    unsafeCompiler $ do
        exists <- doesFileExist logSourcePath
        when exists $ do
                makeDirectories logDestinationPath
                copyFile logSourcePath logDestinationPath
    case exitCode of
        ExitSuccess ->
            return $ latexPath -<.> "pdf"
        ExitFailure err ->
            throwError ["LaTeX compiler: failed while processing item " ++
                show id ++ " exit code " ++ show err ++ "."]

pdfToSVGs :: FilePath -> Compiler [FilePath]
pdfToSVGs pdfPath = do
    exitCode <- unsafeCompiler $ system $ unwords
        ["pdf2svg", pdfPath, svgPath, "all"]
    case exitCode of
        ExitSuccess ->
            map snd . sort . mapMaybe processSVGFileNo <$>
                unsafeCompiler (listDirectory (takeDirectory pdfPath))
        ExitFailure err -> do
            id <- getUnderlying
            throwError ["PDFtoSVG compiler: failed while processing item " ++
                show id ++ " exit code " ++ show err ++ "."]
    where
        svgPath :: FilePath
        svgPath =
            replaceBaseName
                (pdfPath -<.> "svg")
                (takeBaseName pdfPath ++ "-eqn-%i")

        processSVGFileNo :: FilePath -> Maybe (Integer, FilePath)
        processSVGFileNo fp = do
            bare <- stripExtension "svg" fp
            num <- stripPrefix (takeBaseName pdfPath ++ "-eqn-") bare
            guard $ not (null num) && all isDigit num
            return (read num, takeDirectory pdfPath </> fp)

cleanImageSVG :: Integer -> T.Text -> Compiler T.Text
cleanImageSVG num svg = do
    (exitCode, svgout, _) <- unsafeCompiler $
        readProcessWithExitCode "svgcleaner" ["--remove-nonsvg-attributes=no","-c", "-"] (T.unpack svg)
    case exitCode of
        ExitSuccess -> return $ T.pack svgout
        ExitFailure err -> do
            id <- getUnderlying
            throwError ["SVGCleaner: failed while processing image " ++ show num ++
                " from item " ++ show id ++ " exit code " ++ show err ++ "."]

--------------------------------------------------------------------------------

domsDefaultReaderOptions :: ReaderOptions
domsDefaultReaderOptions = defaultHakyllReaderOptions

domsDefaultHTMLWriterOptions :: WriterOptions
domsDefaultHTMLWriterOptions = defaultHakyllWriterOptions

domsDefaultLaTeXWriterOptions :: WriterOptions
domsDefaultLaTeXWriterOptions = defaultHakyllWriterOptions

{-# NOINLINE domsDefaultStandaloneLaTeXWriterOptions #-}
domsDefaultStandaloneLaTeXWriterOptions :: WriterOptions
domsDefaultStandaloneLaTeXWriterOptions = unsafePerformIO $ do
    templ <- runIO (compileDefaultTemplate "latex") >>= handleError
    return $ def
        {   writerTemplate = Just templ
        }

domsDefaultXMLRenderSettings :: X.RenderSettings
domsDefaultXMLRenderSettings = X.def { X.rsXMLDeclaration = False }

-------------------------------------------------------------------------------
-- Load standard pandoc option sets

{-# NOINLINE commonOptions #-}
commonOptions :: Meta
commonOptions = unsafePerformIO $ do
    yaml <- LB.readFile "pandoc/commonOptions.yaml"
    runIOorExplode $ yamlToMeta domsDefaultReaderOptions Nothing yaml

{-# NOINLINE pdfGenOptions #-}
pdfGenOptions :: Meta
pdfGenOptions = unsafePerformIO $ do
    yaml <- LB.readFile "pandoc/pdfGenOptions.yaml"
    meta <- runIOorExplode $ yamlToMeta domsDefaultReaderOptions Nothing yaml
    return (meta <> commonOptions)

{-# NOINLINE imgGenOptions #-}
imgGenOptions :: Meta
imgGenOptions = unsafePerformIO $ do
    yaml <- LB.readFile "pandoc/imgGenOptions.yaml"
    meta <- runIOorExplode $ yamlToMeta domsDefaultReaderOptions Nothing yaml
    return (meta <> commonOptions)

-- Meta is a monoid and when applying <> options in its rhs override corresponding 
-- options in its lhs.

--------------------------------------------------------------------------------

writePandocTyped :: (Pandoc -> PandocPure T.Text) -> Pandoc -> String
writePandocTyped writer doc =
    case runPure $ writer doc of
        Left err    -> error $ "Compiler.writePandocTyped: " ++ show err
        Right doc' -> T.unpack doc'

writePandocToLaTeX :: Pandoc -> String
writePandocToLaTeX = writePandocTyped $ writeLaTeX domsDefaultLaTeXWriterOptions

writePandocToStandaloneLaTeX :: Pandoc -> String
writePandocToStandaloneLaTeX = 
    writePandocTyped $ writeLaTeX domsDefaultStandaloneLaTeXWriterOptions

writePandocToHTML :: Pandoc -> String
writePandocToHTML = writePandocTyped $ writeHtml5String domsDefaultHTMLWriterOptions

--------------------------------------------------------------------------------

compileToPandocAST :: Compiler (Item Pandoc)
compileToPandocAST = do
    bibs <- loadAll "pandoc/*.bib"
    csl <- load "pandoc/elsevier.csl"
    getResourceString >>= readPandocBiblios domsDefaultReaderOptions csl bibs

-- Generate LaTeX body only
renderPandocASTtoLaTeX :: Item Pandoc -> Compiler (Item String)
renderPandocASTtoLaTeX =
    return . fmap writePandocToLaTeX

-- Apply standard pandoc LaTeX template and compile 
renderPandocASTtoPDF :: Item Pandoc -> Compiler (Item TmpFile)
renderPandocASTtoPDF =
    buildLaTeX . fmap (writePandocToStandaloneLaTeX . prependMeta pdfGenOptions)

-------------------------------------------------------------------------------
-- Standalone Binary instances for pandoc types

deriving instance B.Binary Pandoc
deriving instance B.Binary CitationMode
deriving instance B.Binary Citation
deriving instance B.Binary Inline
deriving instance B.Binary Block
deriving instance B.Binary QuoteType
deriving instance B.Binary MathType
deriving instance B.Binary Format
deriving instance B.Binary ListNumberStyle
deriving instance B.Binary ListNumberDelim
deriving instance B.Binary Caption
deriving instance B.Binary Alignment
deriving instance B.Binary ColWidth
deriving instance B.Binary TableHead
deriving instance B.Binary TableBody
deriving instance B.Binary TableFoot
deriving instance B.Binary Row
deriving instance B.Binary Cell
deriving instance B.Binary RowSpan
deriving instance B.Binary ColSpan
deriving instance B.Binary RowHeadColumns
deriving instance B.Binary Meta
deriving instance B.Binary MetaValue

-------------------------------------------------------------------------------
-- Very simple backtracking parser monad.

type ParserMonad = StateT String Maybe

stripSpaces :: ParserMonad ()
stripSpaces = modify $ dropWhile isSpace

word :: (Char -> Bool) -> ParserMonad String
word p = do
    s0 <- get
    let (x, s1) = span p s0
    put s1
    return x

token :: String -> ParserMonad String
token t = do
    s0 <- get
    let (s,s1) = splitAt (length t) s0
    guard (s == t)
    put s1
    return s

number :: ParserMonad Int
number = read <$> word isDigit

-------------------------------------------------------------------------------
-- Parser to read the image dimensions recorded in a LaTeX log file.

type Points = Fixed 100000

ptConvFactor :: Points
ptConvFactor = 1.00375

data ImageInfo = ImageInfo
    { depth :: Points
    , height :: Points
    , width :: Points
    } deriving (Show)

getEqnDimens :: FilePath -> Compiler [ImageInfo]
getEqnDimens fp = unsafeCompiler $
        mapMaybe (evalStateT parseImageDimens) . lines <$> readFile fp
    where
        parseDimen :: ParserMonad Points
        parseDimen = do
            n1 <- word isDigit
            n2 <- (token "." >> word isDigit) <|> return "0"
            token "pt"
            return $ read $ n1 ++ "." ++ n2

        parseImageDimens :: ParserMonad ImageInfo
        parseImageDimens = do
            token "Preview: eqn" >> stripSpaces
            token "("
            e <- number
            stripSpaces
            token ")" >> stripSpaces
            token "dims" >> stripSpaces
            d1 <- parseDimen
            token ","
            d2 <- parseDimen
            token ","
            d3 <- parseDimen
            return $ ImageInfo
                (d1 / ptConvFactor)
                (d2 / ptConvFactor)
                (d3 / ptConvFactor)

-------------------------------------------------------------------------------
-- Build an HTML file with embedded SVG sections from an input containing 
-- LaTeX equations

renderPandocASTtoHTML :: Item Pandoc -> Compiler (Item String)
renderPandocASTtoHTML (Item _ body) = do
    svgs <- makeEquationSVGs body
    makeItem (writePandocToHTML $ embedEquationImages svgs body)

embedEquationImages :: [T.Text] -> Pandoc -> Pandoc
embedEquationImages imgs doc = evalState (walkM transformEquation doc) imgs
    where
        transformEquation :: Inline -> State [T.Text] Inline
        transformEquation (Math typ body) = do
            imgs <- get
            case imgs of
                [] ->
                    let classes = case typ of
                            InlineMath -> ["inline-equation"]
                            DisplayMath -> ["displayed-equation"]
                    in return $
                        Span ("", classes, [("style", "color: red;")])
                            [Str "<missing image>"]
                (img:imgs') -> do
                    put imgs'
                    return $ RawInline "html" img
        transformEquation x = return x

prependMeta :: Meta -> Pandoc -> Pandoc
prependMeta pmeta (Pandoc meta body) = Pandoc (pmeta <> meta) body

getMeta :: Pandoc -> Meta
getMeta (Pandoc meta _) = meta

makeEquationSVGs :: Pandoc -> Compiler [T.Text]
makeEquationSVGs inputDoc =
    if null eqnBlocks
    then return []
    else do
        TmpFile latexPath <- newTmpFile "eqnimages.tex"
        unsafeCompiler $ writeFile latexPath imgGenLaTeX
        svgDocs <- runLuaLaTeX latexPath >>=
            pdfToSVGs >>= traverse (unsafeCompiler . X.readFile X.def)
        imgInfo <- getEqnDimens $ latexPath -<.> "log"
        sequenceA $ zipWith4 processImage [1..] svgDocs imgInfo eqnTypes
    where
        queryEquation :: Inline -> [(MathType, Block)]
        queryEquation (Math typ text) =
            [( typ
            , RawBlock "latex" $ T.concat
                [ "\\begin{shipper}{"
                , case typ of
                    InlineMath -> "\\textstyle"
                    DisplayMath -> "\\displaystyle"
                , "}"
                , text
                , "\\end{shipper}\n"
                ]
            )]
        queryEquation x = []

        eqnTypes :: [MathType]
        eqnBlocks :: [Block]
        (eqnTypes, eqnBlocks) = unzip $ query queryEquation inputDoc

        imgGenDoc :: Pandoc
        imgGenDoc =
            prependMeta imgGenOptions $
                doc $ B.fromList eqnBlocks

        imgGenLaTeX :: String
        imgGenLaTeX = writePandocToStandaloneLaTeX imgGenDoc

processImage :: Integer -> X.Document -> ImageInfo -> MathType -> Compiler T.Text
processImage num svg (ImageInfo dp _ _) typ =
    return $ (LT.toStrict . X.renderText domsDefaultXMLRenderSettings) transformedSVG
    where
        queryID :: X.Element -> S.Set T.Text
        queryID (X.Element _ attr _) = maybe S.empty S.singleton (M.lookup "id" attr)

        allIDs :: S.Set T.Text
        allIDs = query queryID svg

        transformID :: X.Element -> X.Element
        transformID e@(X.Element nm attr nodes) =
            case M.lookup "id" attr of
                Just t ->
                    X.Element
                        nm
                        (M.insert "id" (T.concat ["eqn", T.pack (show num), "-", t]) attr)
                        nodes
                Nothing -> e

        transformTags :: X.Element -> X.Element
        transformTags (X.Element nm attr nodes) =
            X.Element nm (fmap transformAttrValue attr) nodes

        transformAttrValue :: T.Text -> T.Text
        transformAttrValue s =
            T.concat $ intersperse "#" $ head splitup:map transformTag (tail splitup)
            where
                splitup :: [T.Text]
                splitup = T.splitOn "#" s

                transformTag :: T.Text -> T.Text
                transformTag s  =
                    if S.member (T.takeWhile (\c -> C.isAlphaNum c || c == '-') s) allIDs
                        then T.concat ["eqn", T.pack (show num), "-", s]
                        else s

        extraRootAttr :: M.Map X.Name T.Text
        extraRootAttr = case typ of
            InlineMath -> M.fromList
                [ ("style", T.concat ["transform: translateY(", T.pack (show dp), "pt);"])
                , ("class", "inline-equation")
                ]
            DisplayMath -> M.fromList
                [ ("class", "displayed-equation") ]

        transformedSVG :: X.Document
        transformedSVG = case walk (transformID . transformTags) svg of
            X.Document pro (X.Element nm attr nodes) epi |
                nm == "{http://www.w3.org/2000/svg}svg" ->
                X.Document pro (X.Element nm (attr <> extraRootAttr) nodes) epi
            d -> d
