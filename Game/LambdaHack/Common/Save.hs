-- | Saving and restoring game state, used by both server and clients.
module Game.LambdaHack.Common.Save
  ( ChanSave, saveToChan, wrapInSaves, restoreGame, saveNameCli, saveNameSer
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , loopSave, vExevLib, showVersion2, delayPrint
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

-- Cabal
import qualified Paths_LambdaHack as Self (version)

import           Control.Concurrent
import           Control.Concurrent.Async
import qualified Control.Exception as Ex
import           Data.Binary
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import           Data.Version
import           System.FilePath
import           System.IO (hFlush, stdout)
import qualified System.Random as R

import Game.LambdaHack.Common.File
import Game.LambdaHack.Common.Kind
import Game.LambdaHack.Common.Misc (FactionId, appDataDir)
import Game.LambdaHack.Content.RuleKind

type ChanSave a = MVar (Maybe a)

saveToChan :: ChanSave a -> a -> IO ()
saveToChan toSave s = do
  -- Wipe out previous candidates for saving.
  void $ tryTakeMVar toSave
  putMVar toSave $ Just s

-- | Repeatedly save serialized snapshots of current state.
loopSave :: Binary a => COps -> (a -> FilePath) -> ChanSave a -> IO ()
loopSave cops stateToFileName toSave =
  loop
 where
  loop = do
    -- Wait until anyting to save.
    ms <- takeMVar toSave
    case ms of
      Just s -> do
        dataDir <- appDataDir
        tryCreateDir (dataDir </> "saves")
        let fileName = stateToFileName s
        yield  -- minimize UI lag due to saving
        encodeEOF (dataDir </> "saves" </> fileName) (vExevLib cops, s)
        -- Wait until the save finished. During that time, the mvar
        -- is continually updated to newest state values.
        loop
      Nothing -> return ()  -- exit

wrapInSaves :: Binary a
            => COps -> (a -> FilePath) -> (ChanSave a -> IO ()) -> IO ()
{-# INLINE wrapInSaves #-}
wrapInSaves cops stateToFileName exe = do
  -- We don't merge this with the other calls to waitForChildren,
  -- because, e.g., for server, we don't want to wait for clients to exit,
  -- if the server crashes (but we wait for the save to finish).
  toSave <- newEmptyMVar
  a <- async $ loopSave cops stateToFileName toSave
  link a
  let fin = do
        -- Wait until the last save (if any) starts
        -- and tell the save thread to end.
        putMVar toSave Nothing
        -- Wait 0.5s to flush debug and then until the save thread ends.
        threadDelay 500000
        wait a
  exe toSave `Ex.finally` fin
  -- The creation of, e.g., the initial client state, is outside the 'finally'
  -- clause, but this is OK, since no saves are ordered until 'runActionCli'.
  -- We save often, not only in the 'finally' section, in case of
  -- power outages, kill -9, GHC runtime crashes, etc. For internal game
  -- crashes, C-c, etc., the finalizer would be enough.
  -- If we implement incremental saves, saving often will help
  -- to spread the cost, to avoid a long pause at game exit.

-- | Restore a saved game, if it exists. Initialize directory structure
-- and copy over data files, if needed.
restoreGame :: Binary a => COps -> FilePath -> IO (Maybe a)
restoreGame cops fileName = do
  -- Create user data directory and copy files, if not already there.
  dataDir <- appDataDir
  tryCreateDir dataDir
  let path bkp = dataDir </> "saves" </> bkp <> fileName
  saveExists <- doesFileExist (path "")
  -- If the savefile exists but we get IO or decoding errors,
  -- we show them and start a new game. If the savefile was randomly
  -- corrupted or made read-only, that should solve the problem.
  -- OTOH, serious IO problems (e.g. failure to create a user data directory)
  -- terminate the program with an exception.
  res <- Ex.try $
    if saveExists then do
      (vExevLib2, s) <- strictDecodeEOF (path "")
      if vExevLib2 == vExevLib cops
      then return $ Just s
      else do
        let msg = "Savefile" <+> T.pack (path "") <+> "from old version"
                  <+> showVersion2 vExevLib2
                  <+> "detected while trying to restore"
                  <+> showVersion2 (vExevLib cops)
                  <+> "game."
        fail $ T.unpack msg
    else return Nothing
  let handler :: Ex.SomeException -> IO (Maybe a)
      handler e = do
        let msg = "Restore failed. The old file moved aside. The error message is:"
                  <+> (T.unwords . T.lines) (tshow e)
        delayPrint msg
        renameFile (path "") (path "bkp.")
        return Nothing
  either handler return res

vExevLib :: COps -> (Version, Version)
vExevLib cops =
  let exeVersion = rexeVersion $ getStdRuleset cops
      libVersion = Self.version
  in (exeVersion, libVersion)

showVersion2 :: (Version, Version) -> Text
showVersion2 (exeVersion, libVersion) = T.pack $
  showVersion exeVersion <> "-" <> showVersion libVersion

delayPrint :: Text -> IO ()
delayPrint t = do
  delay <- R.randomRIO (0, 1000000)
  threadDelay delay  -- try not to interleave saves with other clients
  T.hPutStrLn stdout t
  hFlush stdout

saveNameCli :: COps -> FactionId -> String
saveNameCli cops side =
  let gameShortName =
        case T.words $ rtitle $ getStdRuleset cops of
          w : _ -> T.unpack w
          _ -> "Game"
      n = fromEnum side  -- we depend on the numbering hack to number saves
  in gameShortName
     ++ (if n > 0
         then ".human_" ++ show n
         else ".computer_" ++ show (-n))
     ++ ".sav"

saveNameSer :: COps -> String
saveNameSer cops =
  let gameShortName =
        case T.words $ rtitle $ getStdRuleset cops of
          w : _ -> T.unpack w
          _ -> "Game"
  in gameShortName ++ ".server.sav"
