Hyakko
======

**Hyakko** is a Haskell port of [docco](http://jashkenas.github.com/docco/):
the original quick-and-dirty documentation generate. It produces an HTML
document that displays your comments intermingled with you code. All prose
is passed through
[Markdown](http://daringfireball.net/projects/markdown/syntax), and code is
passed through [Kate](http://johnmacfarlane.net/highlighting-kate/) syntax
highlighing. This page is the result of running Hyakko against its own
[source
file](https://github.com/sourrust/hyakko/blob/master/src/Hyakko.lhs).

1. Install Hyakko with **cabal**: `cabal update; cabal install hyakko`

2. Run it agianst your code: `hyakko src/*.hs` or just `hyakko src` and
   Hyakko will search for supported files inside the directory recursively.

There is no "Step 3". This will generate an HTML page for each of the named
source files, with a menu linking to the other pages, saving the whole mess
into a `docs` folder — and is also configurable.

The [Hyakko source](https://github.com/sourrust/hyakko) is available on
GitHub, and is released under the [MIT
license](http://opensource.org/licenses/MIT).

There is a ["literate"
style](http://www.haskell.org/haskellwiki/Literate_programming) of Haskell,
only one supported at this time, but other literate styles can be added
fairly easily via a [separate languages
file](https://github.com/sourrust/hyakko/blob/master/resources/languages.json).

> {-# LANGUAGE OverloadedStrings, DeriveDataTypeable #-}

> module Main where

> import Text.Markdown

> import Data.Aeson
> import Data.HashMap.Strict (HashMap)
> import qualified Data.HashMap.Strict as M
> import Data.ByteString.Lazy.Char8 (ByteString)
> import qualified Data.ByteString.Lazy.Char8 as L
> import Data.Text (Text)
> import qualified Data.Text as T
> import qualified Data.Text.IO as T
> import Data.List (sort)
> import Data.Maybe (fromJust, isNothing)
> import Data.Version (showVersion)
> import Control.Applicative ((<$>), (<*>), empty)
> import Control.Monad (filterM, (>=>), forM, forM_, unless)
> import qualified Text.Blaze.Html as B
> import Text.Blaze.Html.Renderer.Utf8 (renderHtml)
> import qualified Text.Highlighting.Kate as K
> import Text.Pandoc.Templates
> import Text.Regex.PCRE ((=~))
> import System.Console.CmdArgs
> import System.Directory ( getDirectoryContents
>                         , doesDirectoryExist
>                         , doesFileExist
>                         , createDirectoryIfMissing
>                         , copyFile
>                         )
> import System.IO.Unsafe (unsafePerformIO)
> import System.FilePath ( takeBaseName
>                        , takeExtension
>                        , takeFileName
>                        , (</>)
>                        , addTrailingPathSeparator
>                        )
> import Paths_hyakko (getDataFileName, version, getDataDir)

Main Documentation Generation Functions
---------------------------------------

Generate the documentation for our configured source file by copyinh over
static assets, reading all the source files in, splitting them up into
prose+code sections, highlighting each file in the approapiate language, and
printing them out in an HTML template.

> generateDocumentation :: Hyakko -> [FilePath] -> IO ()
> generateDocumentation _ [] =
>   putStrLn "hyakko: no files or options given (try --help)"
> generateDocumentation opts xs = do
>   dataDir <- getDataDir
>   let opts'  = configHyakko opts dataDir
>       dirout = output opts'
>   style <- hyakkoStyles opts'
>   T.writeFile (dirout </> "hyakko.css") style
>   unless (isNothing $ layout opts') $ do
>     let layoutDir = fromJust $ layout opts'
>     copyDirectory opts' $ dataDir </> "resources" </> layoutDir
>                                   </> "public"
>   forM_ xs $ \x -> do
>     code <- T.readFile x
>     let sections  = parse (getLanguage x) code
>     if null sections then
>       putStrLn $ "hyakko doesn't support the language extension "
>                ++ takeExtension x
>       else do
>         let highlighted = highlight x sections
>             y           = mapSections sections highlighted
>         generateHTML opts' x y

Given a string of source code, parse out eacg block of prose and the code
that follows it — by detecting which is which, line by line — then create an
individual **section** for it. Each section is Map with `docText` and
`codeText` properties, and eventuall `docsHtml` and `codeHtml` as well.

> inSections :: [Text] -> ByteString -> Sections
> inSections xs r =
>   let sections = sectionOff "" "" xs
>   in map M.fromList sections

>   where save :: Text -> Text -> [(String, Text)]
>         save code docs = [ ("codeText", code)
>                          , ("docsText", docs)
>                          ]

>         sectionOff :: Text -> Text -> [Text] -> [[(String, Text)]]
>         sectionOff code docs [] = save code docs : []
>         sectionOff code docs (y:ys) =
>           let line    = T.unpack y
>               shebang = L.pack "(^#![/]|^\\s*#\\{)"
>           in if line =~ r && (not $ line =~ shebang) then
>                handleDocs code
>                else
>                  sectionOff (code ++. y ++. "\n") docs ys

>           where handleDocs "" = handleHeaders code (newdocs docs) ys
>                 handleDocs _  = save code docs
>                               : handleHeaders "" (newdocs "") ys

>                 newdocs d = d ++. (replace r y "") ++. "\n"

If there is a header markup, only for `---` and `===`, it will get its own
line from the other documentation.

>                 handleHeaders c d zs =
>                   if T.unpack d =~ L.pack "^(---|===)+" then
>                     save c d : sectionOff "" "" zs
>                     else
>                       sectionOff c d zs

The higher level interface for calling `inSections`. `parse` basically
sanitates the file — turing literate into regular source and take out
shebangs — then feed it to `inSections`, and finally return the results.

> parse :: Maybe Language -> Text -> Sections
> parse Nothing _       = []
> parse (Just src) code =
>   inSections (fromLiterate (T.lines code) (literate src) True)
>              ("^\\s*" ++* symbol src ++* "\\s?")

Transforms a literate style language file into its normal, non-literate
style language. If it is normal, `fromLiterate` for returns the same list of
`Text` that was passed in.

>   where fromLiterate :: [Text] -> Maybe Bool -> Bool -> [Text]
>         fromLiterate [] _ _            = []
>         fromLiterate xs Nothing _      = xs
>         fromLiterate (x:xs) lit isText =
>           let s       = symbol src
>               r       = "^" ++* (fromJust $ litSymbol src) ++* "\\s?"
>               r1      = L.pack "^\\s*$"
>               (x', y) = if T.unpack x =~ r then
>                      (replace r x "", False)
>                      else
>                        insert (T.unpack x =~ r1) isText
>                          ((T.pack $ L.unpack s)  ++. " " ++. x)
>           in x': fromLiterate xs lit y

Inserts a comment symbol and a single space into the documentation line and
check if the last line was code and documentation. If the previous line was
code and the line is blank or has just whitespace, it returns a blank `Text`
datatype; otherwise it will return just the comment symbol.

>           where insert :: Bool -> Bool -> Text -> (Text, Bool)
>                 insert True True _  = (T.pack . L.unpack
>                                       $ symbol src, True)
>                 insert True False _ = ("", False)
>                 insert False _ y    = (y, True)

Highlights the current file of code, using **Kate**, and outputs the the
highlighted html to its caller.

> highlight :: FilePath -> Sections -> [Text]
> highlight src section =
>   let language = fromJust $ getLanguage src
>       langName = L.unpack $ name_ language
>       input    = map (\x -> T.unpack $ x M.! "codeText") section
>       html     = B.toHtml . K.formatHtmlBlock K.defaultFormatOpts
>                           . K.highlightAs langName
>       htmlText = T.pack . L.unpack . renderHtml . html
>   in map htmlText input

`mapSections` is used to insert the html parts of the mapped sections of
text into the corresponding keys of `docsHtml` and `codeHtml`.

> mapSections :: Sections -> [Text] -> Sections
> mapSections section highlighted =
>   let docText s  = toHTML . T.unpack $ s M.! "docsText"
>       codeText i = highlighted !! i
>       sectLength = (length section) - 1
>       intoMap x  = let sect = section !! x
>                    in M.insert "docsHtml" (docText sect) $
>                       M.insert "codeHtml" (codeText x) sect
>   in map intoMap [0 .. sectLength]

Determine whether or not there is a `Jump to` section.

> multiTemplate :: Int -> [(String, String)]
> multiTemplate 1 = []
> multiTemplate _ = [("multi", "1")]

Produces a list of anchor tags to different files in docs. This will only
show up if the template support it and there are more than one source file
generated.

> sourceTemplate :: Hyakko -> [FilePath] -> [(String, String)]
> sourceTemplate opts = map source
>   where source x = ("source", concat
>           [ "<a class=\"source\" href=\""
>           , takeFileName $ destination (output opts) x
>           , "\">"
>           , takeFileName x
>           , "</a>"
>           ])

Depending on the layout type, `sectionTemplate` will produce the HTML that
will be hooked into the templates layout theme.

> sectionTemplate :: Sections
>                 -> Maybe String
>                 -> [Int]
>                 -> [(String, String)]
> sectionTemplate section layoutType count =
>   let isLayout = not $ isNothing layoutType
>       sections = if isLayout then layoutFn $ fromJust layoutType
>                  else undefined
>   in map sections count
>   where layoutFn "parallel" = parallel
>         layoutFn "linear"   = linear
>         layoutFn _          = undefined
>         parallel x =
>           let x'   = x + 1
>               sect = section !! x
>               docsHtml = T.unpack $ sect M.! "docsHtml"
>               codeHtml = T.unpack $ sect M.! "codeHtml"
>               codeText = T.unpack $ sect M.! "codeText"
>               header   = docsHtml =~ L.pack "^\\s*<(h\\d)"
>               isBlank  = T.null $ replace "\\s" (T.pack codeText) ""
>           in ("section", concat
>              [ "<li id=\"section-"
>              , show x'
>              , "\"><div class=\"annotation\">"
>              , "<div class=\"pilwrap"
>              , if null header then "" else " for-" ++ tail header
>              , "\"><a class=\"pilcrow\" href=\""
>              , show x'
>              , "\">&#955;</a></div>"
>              , docsHtml
>              , "</div>"
>              , if isBlank then "" else "<div class=\"content\">"
>                  ++ codeHtml ++ "</div>"
>              ])
>         linear x =
>           let sect   = section !! x
>               codeText = T.unpack $ sect M.! "codeText"
>               isText = not $ null codeText
>           in ("section", concat
>              [ T.unpack $ sect M.! "docsHtml"
>              , if isText then T.unpack $ sect M.! "codeHtml" else []
>              ])

> cssTemplate :: Hyakko -> [(String, String)]
> cssTemplate opts =
>   let maybeLayout = layout opts
>       normalize   = "public" </> "stylesheets" </> "normalize.css"
>       otherFile   = if isNothing maybeLayout then id else
>         ([normalize] ++)
>   in zip ["css", "css"] $ otherFile ["hyakko.css"]

Once all of the code is finished highlighting, we can generate the HTML file
and write out the documentation. Pass the completed sections into the
template found in `resources/linear/hyakko.html` or
`resources/parallel/hyakko.html`.

> generateHTML :: Hyakko -> FilePath -> Sections -> IO ()
> generateHTML opts src section = do
>   let title       = takeFileName src
>       dest        = destination (output opts) src
>       maybeLayout = layout opts
>       header      = T.unpack $ (section !! 0) M.! "docsHtml"
>       isHeader    = header =~ L.pack "^<(h\\d)"
>       count       = [0 .. (length section) - 1]
>       (h, count') = if isHeader then
>         let layout' = if isNothing maybeLayout then ""
>                       else fromJust maybeLayout
>         in ( [("header", header)]
>            , (if layout' == "linear" then tail else id) count)
>         else
>           ([("header", header)], count)
>   source <- sources $ dirOrFiles opts
>   html <- hyakkoTemplate opts $ concat
>     [ [("title", if isHeader then getHeader header else title)]
>     , h
>     , cssTemplate opts
>     , multiTemplate $ length source
>     , sourceTemplate opts source
>     , sectionTemplate section maybeLayout count'
>     ]
>   putStrLn $ "hyakko: " ++ src ++ " -> " ++ dest
>   T.writeFile dest html

Small helper to yank out the header text from an html string, if there is a
header at the top of the file.

> getHeader :: String -> String
> getHeader htmlheader =
>   let reg            = L.pack ">(.+)</h\\d>"
>       [(_:header:_)] = htmlheader =~ reg
>   in header

Helpers & Setup
---------------

The `Sections` type is just an alias to keep type signatures short.

> type Sections = [HashMap String Text]

Alias `Languages`, for the multiple different languages inside the
`languages.json` file.

> type Languages = HashMap String Language

Better data type for language info — compared to the `Object` data type in
`Aeson`.

> data Language =
>   Language { name_     :: ByteString
>            , symbol    :: ByteString
>            , literate  :: Maybe Bool
>            , litSymbol :: Maybe ByteString
>            }

> instance FromJSON Language where
>   parseJSON (Object o) = Language
>                      <$> o .:  "name"
>                      <*> o .:  "symbol"
>                      <*> o .:? "literate"
>                      <*> o .:? "litSymbol"
>   parseJSON _          = empty

Infix functions for easier concatenation with Text and ByteString.

> (++.) :: Text -> Text -> Text
> (++.) = T.append
> {-# INLINE (++.) #-}

> (++*) :: ByteString -> ByteString -> ByteString
> (++*) = L.append
> {-# INLINE (++*) #-}

Simpler type signatuted regex replace function.

> replace :: ByteString -> Text -> Text -> Text
> replace reg x y =
>   let str  = T.unpack x
>       (_, _, rp) = str =~ reg :: (String, String, String)
>   in y ++. (T.pack rp)

> readLanguageFile :: IO ByteString
> readLanguageFile = getDataFileName "resources/languages.json"
>                >>= L.readFile

A list of the languages that Hyakko supports, mapping the file extension to
the name of the Pygments lexer and the symbol that indicates a comment. To
add another language to Hyakko's repertoire, add it here.

> languages :: Languages
> languages =
>   let content  = unsafePerformIO $ readLanguageFile
>       jsonData = decode' content
>   in fromJust jsonData

Get the current language we're documenting, based on the extension.

> getLanguage :: FilePath -> Maybe Language
> getLanguage src = M.lookup (takeExtension src) languages

Compute the destination HTML path for an input source file path. If the
source is `lib/example.hs`, the HTML will be at docs/example.html

> destination :: FilePath -> FilePath -> FilePath
> destination out fp = out </> (takeBaseName fp) ++ ".html"

The function `hyakkoFile`, used to grab the contents of either the default
css and html or a custom css and html. Then move it to the output directory.

> hyakkoFile :: String -> Hyakko -> IO Text
> hyakkoFile filetype opts = do
>   let maybeFile = (if filetype == "css" then css else template) opts
>   if isNothing maybeFile then
>     readDataFile $ "resources"
>                </> (fromJust $ layout opts)
>                </> "hyakko." ++ filetype
>     else
>       T.readFile $ fromJust maybeFile


Create the template that we will use to generate the Hyakko HTML page.

> hyakkoTemplate :: Hyakko -> [(String, String)] -> IO Text
> hyakkoTemplate opts var = do
>   content <- hyakkoFile "html" opts
>   return . T.pack . renderTemplate var $ T.unpack content

The CSS styles we'd like to apply to the documentation.

> hyakkoStyles :: Hyakko -> IO Text
> hyakkoStyles = hyakkoFile "css"

Reads from resource path given in cabal package

> readDataFile :: FilePath -> IO Text
> readDataFile = getDataFileName >=> T.readFile

For each source file passed in as an argument, generate the documentation.

> sources :: [FilePath] -> IO [FilePath]
> sources file = do
>   files <- forM file $ \x -> do
>     isDir <- doesDirectoryExist x
>     if isDir then
>       unpackDirectories x >>= return . fst
>       else
>         return [x]
>   return . sort $ concat files

Turns the directory give into a list of files including all of the files in
sub-directories.

> unpackDirectories :: FilePath -> IO ([FilePath], [FilePath])
> unpackDirectories d = do
>   let reg = L.pack "[^(^\\.{1,2}$)]"
>   content <- getDirectoryContents d >>= return . filter (=~ reg)
>   let content' = map (d </>) content
>   files <- filterM doesFileExist content'
>   subdir <- filterM doesDirectoryExist content'
>   subcontent <- mapM unpackDirectories subdir >>= \x ->
>     return (concatMap fst x, concatMap snd x)
>   return (files ++ fst subcontent, subdir ++ snd subcontent)

> copyDirectory :: Hyakko -> FilePath -> IO ()
> copyDirectory opts dir = do
>   (files, dirs) <- unpackDirectories dir
>   dataDir       <- getDataDir
>   let oldLocation = T.pack . addTrailingPathSeparator $ dataDir
>                       </> "resources"
>                       </> (fromJust $ layout opts)
>       dirout      = output opts
>   createDirectoryIfMissing False $ dirout </> "public"

Create all the directories needed to put future files into.

>   forM_ dirs $ \x -> do
>     let x'   = T.pack x
>         dir' = T.unpack $ T.replace oldLocation "" x'
>     createDirectoryIfMissing False $ dirout </> dir'

Copy all the files into the recently created directories.

>   forM_ files $ \x -> do
>     let x'   = T.pack x
>         file = dirout </> (T.unpack $ T.replace oldLocation "" x')
>     copyFile x file

Configuration
-------------

Data structure for command line argument parsing.

> data Hyakko =
>   Hyakko { layout     :: Maybe String
>          , output     :: FilePath
>          , css        :: Maybe FilePath
>          , template   :: Maybe FilePath
>          , dirOrFiles :: [FilePath]
>          } deriving (Show, Data, Typeable)

Default configuration **options**. If no arguments for these flags are
specifed, it will just use the ones in `defaultConfig`.

> defaultConfig :: Hyakko
> defaultConfig = Hyakko
>   { layout     = Just "parallel" &= typ "LAYOUT"
>               &= help "choose a built-in layout (parallel, linear)"
>   , output     = "docs"  &= typDir
>               &= help "use a custom output path"
>   , css        = Nothing &= typFile
>               &= help "use a custom css file"
>   , template   = Nothing &= typFile
>               &= help "use a custom pandoc template"
>   , dirOrFiles = [] &= args &= typ "FILES/DIRS"
>   } &= summary ("hyakko v" ++ showVersion version)

**Configure** this particular run of hyakko. We might use a passed-in
external template, or one of the built-in **layouts**.

> configHyakko :: Hyakko -> FilePath -> Hyakko
> configHyakko oldConfig datadir =
>   if isNothing $ template oldConfig then
>     let dir    = datadir </> "resources"
>                          </> (fromJust $ layout oldConfig)
>     in oldConfig { template = Just $ dir </> "hyakko.html"
>                  , css      = Just $ dir </> "hyakko.css"
>                  }
>     else
>       oldConfig { layout = Nothing }

Finally, using [CmdArgs](http://community.haskell.org/~ndm/cmdargs/), define
a command line interface. Parse options and hyakko does the rest.

> main :: IO ()
> main = do
>   opts <- cmdArgs defaultConfig
>   source <- sources $ dirOrFiles opts
>   createDirectoryIfMissing False $ output opts
>   generateDocumentation opts source
