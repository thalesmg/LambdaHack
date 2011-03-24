module Display.Gtk
  (displayId, startup, shutdown,
   display, nextEvent, setBG, setFG, defaultAttr, Session) where

import qualified Data.Binary
import Control.Monad
import Control.Concurrent
import Graphics.UI.Gtk.Gdk.Events  -- TODO: replace, deprecated
import Graphics.UI.Gtk hiding (Attr)
import Data.List as L
import Data.IORef
import Data.Map as M

import Geometry
import qualified Keys as K (Key(..))
import qualified Attr

displayId = "gtk"

data Session =
  Session {
    schan :: Chan String,
    stags :: Map AttrKey TextTag,
    sview :: TextView }

startup :: (Session -> IO ()) -> IO ()
startup k =
  do
    -- initGUI
    unsafeInitGUIForThreadedRTS
    w <- windowNew

    ttt <- textTagTableNew
    -- text attributes
    tts <- fmap M.fromList $
           mapM (\ c -> do
                          tt <- textTagNew Nothing
                          textTagTableAdd ttt tt
                          doAttr tt c
                          return (c, tt))
                [ x | c <- [minBound .. maxBound], x <- [FG c, BG c]]

    -- text buffer
    tb <- textBufferNew (Just ttt)
    textBufferSetText tb (unlines (replicate 25 (replicate 80 ' ')))

    -- create text view
    tv <- textViewNewWithBuffer tb
    containerAdd w tv
    textViewSetEditable tv False
    textViewSetCursorVisible tv False

    -- font
    f <- fontDescriptionNew
    fontDescriptionSetFamily f "Monospace"
    fontDescriptionSetSize f 12
    widgetModifyFont tv (Just f)
    currentfont <- newIORef f
    onButtonPress tv (\ e -> case e of
                               Button { Graphics.UI.Gtk.Gdk.Events.eventButton = RightButton } ->
                                 do
                                   fsd <- fontSelectionDialogNew "Choose font"
                                   cf <- readIORef currentfont
                                   fd <- fontDescriptionToString cf
                                   fontSelectionDialogSetFontName fsd fd
                                   fontSelectionDialogSetPreviewText fsd "+##@##-...|"
                                   response <- dialogRun fsd
                                   when (response == ResponseOk) $
                                     do
                                       fn <- fontSelectionDialogGetFontName fsd
                                       case fn of
                                         Just fn' -> do
                                                       fd <- fontDescriptionFromString fn'
                                                       writeIORef currentfont fd
                                                       widgetModifyFont tv (Just fd)
                                         Nothing  -> return ()
                                   widgetDestroy fsd
                                   return True
                               _ -> return False)

    let black = Color minBound minBound minBound  -- Attr.defBG == Attr.Black
        white = Color 0xAAAA 0xAAAA 0xAAAA        -- Attr.defFG == Attr.White
    widgetModifyBase tv StateNormal black
    widgetModifyText tv StateNormal white

    ec <- newChan
    forkIO $ k (Session ec tts tv)

    onKeyPress tv (\ e -> postGUIAsync (writeChan ec (Graphics.UI.Gtk.Gdk.Events.eventKeyName e)) >> return True)

    onDestroy w mainQuit -- set quit handler
    widgetShowAll w
    yield
    mainGUI

shutdown _ = mainQuit

display :: Area -> Session -> (Loc -> (Attr, Char)) -> String -> String -> IO ()
display ((y0,x0),(y1,x1)) session f msg status =
  postGUIAsync $
  do
    tb <- textViewGetBuffer (sview session)
    let text = unlines [ [ snd (f (y,x)) | x <- [x0..x1] ] | y <- [y0..y1] ]
    textBufferSetText tb (msg ++ "\n" ++ text ++ status)
    sequence_ [ setTo tb (stags session) (y,x) a |
                y <- [y0..y1], x <- [x0..x1], let loc = (y,x), let (a,c) = f (y,x) ]

setTo :: TextBuffer -> Map AttrKey TextTag -> Loc -> Attr -> IO ()
setTo tb tts (ly,lx) a =
  do
    ib <- textBufferGetIterAtLineOffset tb (ly+1) lx
    ie <- textIterCopy ib
    textIterForwardChar ie
    mapM_ (\ c -> textBufferApplyTag tb (tts ! c) ib ie) a

-- | reads until a non-dead key encountered
readUndeadChan :: Chan String -> IO String
readUndeadChan ch =
  do
    x <- readChan ch
    if dead x then readUndeadChan ch else return x
      where
        dead x =
          case x of
            "Shift_R"          -> True
            "Shift_L"          -> True
            "Control_L"        -> True
            "Control_R"        -> True
            "Super_L"          -> True
            "Super_R"          -> True
            "Menu"             -> True
            "Alt_L"            -> True
            "Alt_R"            -> True
            "ISO_Level2_Shift" -> True
            "ISO_Level3_Shift" -> True
            "ISO_Level2_Latch" -> True
            "ISO_Level3_Latch" -> True
            "Num_Lock"         -> True
            "Caps_Lock"        -> True
            _                  -> False

keyTranslate :: String -> Maybe K.Key
keyTranslate "less"          = Just (K.Char '<')
keyTranslate "greater"       = Just (K.Char '>')
keyTranslate "period"        = Just (K.Char '.')
keyTranslate "colon"         = Just (K.Char ':')
keyTranslate "comma"         = Just (K.Char ',')
keyTranslate "space"         = Just (K.Char ' ')
keyTranslate "question"      = Just (K.Char '?')
keyTranslate "dollar"        = Just (K.Char '$')
keyTranslate "asterisk"      = Just (K.Char '*')
keyTranslate "KP_Multiply"   = Just (K.Char '*')
keyTranslate "slash"         = Just (K.Char '/')
keyTranslate "KP_Divide"     = Just (K.Char '/')
keyTranslate "Escape"        = Just K.Esc
keyTranslate "Return"        = Just K.Return
keyTranslate "Tab"           = Just K.Tab
keyTranslate "KP_Up"         = Just K.Up
keyTranslate "KP_Down"       = Just K.Down
keyTranslate "KP_Left"       = Just K.Left
keyTranslate "KP_Right"      = Just K.Right
keyTranslate "KP_Home"       = Just K.Home
keyTranslate "KP_End"        = Just K.End
keyTranslate "KP_Page_Up"    = Just K.PgUp
keyTranslate "KP_Page_Down"  = Just K.PgDn
keyTranslate "KP_Begin"      = Just K.Begin
keyTranslate "KP_Enter"      = Just K.Return
keyTranslate ['K','P','_',c] = Just (K.KP c)
keyTranslate [c]             = Just (K.Char c)
keyTranslate _               = Nothing
-- keyTranslate e               = Just (K.Dbg $ show e)

nextEvent :: Session -> IO K.Key
nextEvent session =
  do
    e <- readUndeadChan (schan session)
    maybe (nextEvent session) return (keyTranslate e)

type Attr = [AttrKey]

data AttrKey =
    FG Attr.Color
  | BG Attr.Color
  deriving (Eq, Ord)

setBG c = (BG c :)
setFG c = (FG c :)
defaultAttr = []

doAttr :: TextTag -> AttrKey -> IO ()
doAttr tt (FG color) = set tt [ textTagForeground := Attr.colorToRGB color ]
doAttr tt (BG color) = set tt [ textTagBackground := Attr.colorToRGB color ]
