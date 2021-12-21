--------------------------------------------------------------------------------
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wno-incomplete-patterns #-}
import           Data.Monoid                   (mappend, mconcat)
import           Data.List                     (sortBy, intersperse, intercalate)
import           Data.Ord                      (comparing)
import           Hakyll
import           Control.Monad                 (liftM, forM_)
import           System.FilePath               (takeBaseName)
import           Text.Blaze.Html               (toHtml, toValue, (!))
import qualified Text.Blaze.Html5              as H
import qualified Text.Blaze.Html5.Attributes   as A
import           Text.Blaze.Html.Renderer.String (renderHtml)


--------------------------------------------------------------------------------
config :: Configuration
config = defaultConfiguration
  { destinationDirectory = "docs"
  }

main :: IO ()
main = hakyllWith config $ do
    match ("images/*" .||. "js/*") $ do
        route   idRoute
        compile copyFileCompiler

    match "css/*" $ do
        route   idRoute
        compile compressCssCompiler

    match "error/*" $ do
        route $ gsubRoute "error/" (const "") `composeRoutes` setExtension "html"
        compile $ pandocCompiler
            >>= applyAsTemplate siteCtx
            >>= loadAndApplyTemplate "templates/default.html" (baseSidebarCtx <> siteCtx)

    match "pages/*" $ do
        route $ setExtension "html"
        compile $ do
            pageName <- takeBaseName . toFilePath <$> getUnderlying
            let pageCtx = constField pageName "" <>
                          baseNodeCtx
            let evalCtx = functionField "get-meta" getMetadataKey <>
                          functionField "eval" (evalCtxKey pageCtx)
            let activeSidebarCtx = sidebarCtx (evalCtx <> pageCtx)

            pandocCompiler
                >>= saveSnapshot "page-content"
                >>= loadAndApplyTemplate "templates/page.html"    siteCtx
                >>= loadAndApplyTemplate "templates/default.html" (activeSidebarCtx <> siteCtx)
                >>= relativizeUrls

    tags <- buildTags "posts/*" (fromCapture "tags/*.html")

    tagsRules tags $ \ tag pat -> do
        let title = "Posts tagged \"" ++ tag ++ "\""
        route idRoute
        compile $ do
            posts <- recentFirst =<< loadAll pat
            let ctx = constField "title" title <>
                      listField "posts" (postCtxWithTags tags) (return posts) <>
                      defaultContext

            makeItem ""
                >>= loadAndApplyTemplate "templates/tag.html" ctx
                >>= loadAndApplyTemplate "templates/default.html" (baseSidebarCtx <> siteCtx)
                >>= relativizeUrls

    match "posts/*" $ do
        route $ setExtension "html"
        compile $ pandocCompiler
            >>= \post -> do  
                    teaser <- makeTeaser post
                    saveSnapshot "teaser" teaser
                    saveSnapshot "content" post
            >>= loadAndApplyTemplate "templates/post.html" (postCtxWithTags tags)
            >>= loadAndApplyTemplate "templates/default.html" (baseSidebarCtx <> siteCtx)
            >>= relativizeUrls

    match "About.markdown" $ do
        route $ constRoute "index.html"
        compile $ do
            posts <- fmap (take 3) . recentFirst
                        =<< loadAllSnapshots "posts/*" "content"
            let indexCtx =
                    listField "posts" postCtx (return posts) <>
                    field "tags" (\_ -> renderAllTags tags)   <>
                    constField "home" ""                     <>
                    constField "title" "About"               <>
                    siteCtx

            pandocCompiler
                >>= loadAndApplyTemplate "templates/index.html" indexCtx
                >>= loadAndApplyTemplate "templates/page.html" indexCtx
                >>= loadAndApplyTemplate "templates/default.html" (baseSidebarCtx <> indexCtx)
                >>= relativizeUrls

    create ["archive.html"] $ do
        route idRoute
        compile $ do
            posts <- recentFirst =<< loadAllSnapshots "posts/*" "content"
            let archiveCtx =
                    listField "posts" postCtx (return posts) <>
                    constField "title" "Archive"             <>
                    constField "archive" ""                  <>
                    siteCtx

            makeItem ""
                >>= loadAndApplyTemplate "templates/archive.html" archiveCtx
                >>= loadAndApplyTemplate "templates/default.html" (baseSidebarCtx <> archiveCtx)
                >>= relativizeUrls

    paginate <- buildPaginateWith postsGrouper "posts/*" postsPageId

    paginateRules paginate $ \ page pat -> do
        route idRoute
        compile $ do
            let posts = recentFirst =<< loadAllSnapshots pat "teaser"
            let indexCtx =
                    constField "title" ("Blog posts, page " ++ show page) <>
                    listField "posts" postCtx posts                       <>
                    constField "blog" ""                                  <>
                    paginateContext paginate page                         <>
                    siteCtx

            makeItem ""
                >>= applyAsTemplate indexCtx
                >>= loadAndApplyTemplate "templates/blog.html" indexCtx
                >>= loadAndApplyTemplate "templates/default.html" (baseSidebarCtx <> indexCtx)
                >>= relativizeUrls

    match "templates/*" $ compile templateBodyCompiler

    create ["atom.xml"] $ do
        route idRoute
        compile $ do
            let feedCtx = postCtx <> bodyField "description"
            posts <- fmap (take 10) . recentFirst =<< loadAllSnapshots "posts/*" "teaser"
            renderAtom feedConfig feedCtx posts

    create ["rss.xml"] $ do
        route idRoute
        compile $ do
            let feedCtx = postCtx <> bodyField "description"
            posts <- fmap (take 10) . recentFirst =<< loadAllSnapshots "posts/*" "teaser"
            renderRss feedConfig feedCtx posts

--------------------------------------------------------------------------------

postsGrouper :: (MonadFail m, MonadMetadata m) => [Identifier] -> m [[Identifier]]
postsGrouper = fmap (paginateEvery 5) . sortRecentFirst

postsPageId :: PageNumber -> Identifier
postsPageId n = fromFilePath $ "blog/page" ++ show n ++ ".html"

makeTeaserWithSeparator :: String -> Item String -> Compiler (Item String)
makeTeaserWithSeparator separator item =
    case needlePrefix separator (itemBody item) of
        Nothing -> fail $
            "Main: no teaser defined for " ++
                show (itemIdentifier item)
        Just t -> return (itemSetBody t item)

teaserSeparator :: String
teaserSeparator = "<!--more-->"

makeTeaser :: Item String -> Compiler (Item String)
makeTeaser = makeTeaserWithSeparator teaserSeparator

--------------------------------------------------------------------------------

feedConfig :: FeedConfiguration
feedConfig = FeedConfiguration
    { feedTitle       = "synthetic"
    , feedDescription = "A blog about higher category theory and life"
    , feedAuthorName  = "Dominic Verity"
    , feedAuthorEmail = "dominic.verity@mq.edu.au"
    , feedRoot        = "https://dom-verity.github.io"
    }

--------------------------------------------------------------------------------

siteCtx :: Context String
siteCtx =
    constField "site-description" "Synthetic Perspectives"                        <>
    constField "site-url" "https://dom-verity.github.io"                          <>
    constField "tagline" "Life, the Universe, and Higher Categories"              <>
    constField "site-title" "Em/Prof. Dominic Verity"                             <>
    constField "copy-year" "2021"                                                 <>
    constField "site-author" "Dom Verity"                                         <>
    constField "site-email" "dominic.verity@mq.edu.au"                            <>
    constField "github-url" "https://github.com/dom-verity"                       <>
    constField "github-repo" "https://github.com/dom-verity/dom-verity.github.io" <>
    constField "twitter-url" "https://twitter.com/DomVerity"                      <>
    defaultContext

--------------------------------------------------------------------------------

postCtx :: Context String
postCtx =
    dateField "date" "%B %e, %Y" <>
    modificationTimeField "modified" "%B %e, %Y" <>
    defaultContext

postCtxWithTags :: Tags -> Context String
postCtxWithTags tags = makeTagsField "tags" tags <> postCtx

makeTagLink :: String -> FilePath -> H.Html
makeTagLink tag filePath =
    H.a ! A.title (H.stringValue ("All posts tagged '"++tag++"'."))
        ! A.href (toValue $ toUrl filePath)
        ! A.class_ "tag"
        $ toHtml tag

renderAllTags :: Tags -> Compiler String
renderAllTags = 
    return . mconcat . 
        fmap (\case (s, _) -> renderHtml $ makeTagLink s ("/tags/" ++ s ++ ".html")) .
        tagsMap

makeTagsField :: String -> Tags -> Context a
makeTagsField =
  tagsFieldWith getTags (fmap . makeTagLink) mconcat

--------------------------------------------------------------------------------

sidebarCtx :: Context String -> Context String
sidebarCtx nodeCtx =
    listField "list_pages" nodeCtx (loadAllSnapshots "pages/*" "page-content") <>
    defaultContext

baseNodeCtx :: Context String
baseNodeCtx =
    urlField "node-url" <>
    titleField "title"

baseSidebarCtx = sidebarCtx baseNodeCtx

evalCtxKey :: Context String -> [String] -> Item String -> Compiler String
evalCtxKey context [key] item =
    unContext context key [] item >>=
    \case
        StringField s -> return s
        _             -> error "Internal error: StringField expected"

getMetadataKey :: [String] -> Item String -> Compiler String
getMetadataKey [key] item = getMetadataField' (itemIdentifier item) key
