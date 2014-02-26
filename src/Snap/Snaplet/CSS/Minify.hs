{-# LANGUAGE DeriveDataTypeable #-}

------------------------------------------------------------------------------
-- | Nest this Snaplet within another to have it retrieve and minify the CSS
-- in its directory.
--
-- First, embed this Snaplet in your application:
--
-- > import Snap.Snaplet.CSS.Minify
-- >
-- > data App = App { cssMin :: Snaplet CssMin, ... }
--
-- Then nest this Snaplet in your initializer at the route you want your
-- stylesheets to be available at:
--
-- > nestSnaplet "style" cssMin cssMinInit
--
-- The stylesheets in @snaplets/css-min@ will now be available in minified
-- form at the @/style@ route.
--
-- To have the files reloaded in development mode add @\"snaplets/css-min\"@
-- to the list of watched directories in the Main module generated by Snap.
module Snap.Snaplet.CSS.Minify
    ( CssMin
    , cssMinInit
    , ParseException
    ) where

------------------------------------------------------------------------------
import qualified Data.Text              as T
import qualified Data.Text.IO           as T
import qualified Data.Text.Lazy         as LT
import qualified Data.Text.Lazy.Builder as LT
import qualified Data.ByteString.UTF8   as BS

------------------------------------------------------------------------------
import Control.Applicative    ((<$), (<$>), (<*>))
import Control.Exception      (Exception (..), SomeException (..), throw)
import Control.Lens           (Lens', (<&>), over, view)
import Control.Monad          (unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State    (get, modify)
import Data.List              (isSuffixOf)
import Data.Text              (Text)
import Data.Typeable          (Typeable, cast)
import Snap.Core
import Snap.Snaplet
import System.FilePath        ((</>))
import System.Directory       (doesFileExist)
import Text.CSS.Parse         (NestedBlock, parseNestedBlocks)
import Text.CSS.Render        (renderNestedBlocks)


------------------------------------------------------------------------------
-- | The Snaplet's state, storing the cache of minified files.
data CssMin = CssMin { _cache :: [(FilePath, Text)] }

cache :: Lens' CssMin [(FilePath, Text)]
cache f m = f (_cache m) <&> \ c -> m { _cache = c }


------------------------------------------------------------------------------
-- | Initializes the CSS minifier by adding a route for reading, minifying and
-- serving the CSS files in the snaplet/css-min directory.
cssMinInit :: SnapletInit b CssMin
cssMinInit = makeSnaplet "css-min" "CSS minifier" Nothing $
    CssMin [] <$ addRoutes [("", serveCss)]

serveCss :: Handler b CssMin ()
serveCss = do
    fp <- (</>) <$> getSnapletFilePath <*>
        (BS.toString . rqPathInfo <$> getRequest)
    liftIO (doesFileExist fp) >>=
        flip unless pass . (".css" `isSuffixOf` fp &&)
    view cache <$> get >>= maybe (minify fp) writeCss . lookup fp

minify :: FilePath -> Handler b CssMin ()
minify fp = parseNestedBlocks <$>
    (getSnapletFilePath >>= liftIO . T.readFile . (</> fp)) >>=
        either (throw . ParseException) (cacheAndWrite fp)

cacheAndWrite :: FilePath -> [NestedBlock] -> Handler b CssMin ()
cacheAndWrite fp css = do
    let text = LT.toStrict $ LT.toLazyText $ renderNestedBlocks css
    modify $ over cache ((fp, text) :)
    writeCss text

writeCss :: Text -> Handler b v ()
writeCss css = do
    modifyResponse
        $ setContentLength (fromIntegral $ T.length css)
        . setContentType "text/css"
        . setResponseCode 200
    writeText css


------------------------------------------------------------------------------
data ParseException = ParseException String
    deriving (Typeable)

instance Show ParseException where
    show (ParseException msg) = "CSS parse exception: " ++ msg

instance Exception ParseException where
    toException = SomeException
    fromException = cast

