-- | Server operations used when ending game and deciding whether to end.
module Game.LambdaHack.Server.EndM
  ( endOrLoop, dieSer, writeSaveAll
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , gameExit, dropAllItems
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Data.EnumMap.Strict as EM

import Game.LambdaHack.Atomic
import Game.LambdaHack.Client
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.State
import Game.LambdaHack.Content.ModeKind
import Game.LambdaHack.Server.CommonM
import Game.LambdaHack.Server.Fov
import Game.LambdaHack.Server.HandleEffectM
import Game.LambdaHack.Server.ItemM
import Game.LambdaHack.Server.MonadServer
import Game.LambdaHack.Server.ProtocolM
import Game.LambdaHack.Server.ServerOptions
import Game.LambdaHack.Server.State

-- | Continue or exit or restart the game.
endOrLoop :: (MonadServerAtomic m, MonadServerReadRequest m)
          => m () -> (Maybe (GroupName ModeKind) -> m ())
          -> m ()
endOrLoop loop restart = do
  factionD <- getsState sfactionD
  let inGame fact = case gquit fact of
        Nothing -> True
        Just Status{stOutcome=Camping} -> True
        _ -> False
      gameOver = not $ any inGame $ EM.elems factionD
  let getQuitter fact = case gquit fact of
        Just Status{stOutcome=Restart, stNewGame} -> stNewGame
        _ -> Nothing
      quitters = mapMaybe getQuitter $ EM.elems factionD
      restartNeeded = gameOver || not (null quitters)
  let isCamper fact = case gquit fact of
        Just Status{stOutcome=Camping} -> True
        _ -> False
      campers = filter (isCamper . snd) $ EM.assocs factionD
  -- Wipe out the quit flag for the savegame files.
  mapM_ (\(fid, fact) ->
    execUpdAtomic $ UpdQuitFaction fid (gquit fact) Nothing) campers
  swriteSave <- getsServer swriteSave
  when swriteSave $ do
    modifyServer $ \ser -> ser {swriteSave = False}
    writeSaveAll True
  if | restartNeeded -> restart (listToMaybe quitters)
     | not $ null campers -> gameExit  -- and @loop@ is not called
     | otherwise -> loop  -- continue current game

gameExit :: (MonadServerAtomic m, MonadServerReadRequest m) => m ()
gameExit = do
--  debugPossiblyPrint "Verifying all perceptions."
  -- Verify that the possibly not saved caches are equal to future
  -- reconstructed. Otherwise, save/restore would change game state.
  -- This is done even in released binaries, because it only prolongs
  -- game shutdown a bit. The same checks at each periodic game save
  -- would icrease the game saving lag, so they are normally avoided.
  verifyCaches
  -- Kill all clients, including those that did not take part
  -- in the current game.
  -- Clients exit not now, but after they print all ending screens.
  -- debugPrint "Server kills clients"
--  debugPossiblyPrint "Killing all clients."
  killAllClients
--  debugPossiblyPrint "All clients killed."
  return ()

verifyCaches :: MonadServer m => m ()
verifyCaches = do
  sperCacheFid <- getsServer sperCacheFid
  sperValidFid <- getsServer sperValidFid
  sactorAspect2 <- getsState sactorAspect
  sfovLucidLid <- getsServer sfovLucidLid
  sfovClearLid <- getsServer sfovClearLid
  sfovLitLid <- getsServer sfovLitLid
  sperFid <- getsServer sperFid
  actorAspect <- getsState actorAspectInDungeon
  ( fovLitLid, fovClearLid, fovLucidLid
   ,perValidFid, perCacheFid, perFid ) <- getsState perFidInDungeon
  let !_A7 = assert (sfovLitLid == fovLitLid
                     `blame` "wrong accumulated sfovLitLid"
                     `swith` (sfovLitLid, fovLitLid)) ()
      !_A6 = assert (sfovClearLid == fovClearLid
                     `blame` "wrong accumulated sfovClearLid"
                     `swith` (sfovClearLid, fovClearLid)) ()
      !_A5 = assert (sactorAspect2 == actorAspect
                     `blame` "wrong accumulated sactorAspect"
                     `swith` (sactorAspect2, actorAspect)) ()
      !_A4 = assert (sfovLucidLid == fovLucidLid
                     `blame` "wrong accumulated sfovLucidLid"
                     `swith` (sfovLucidLid, fovLucidLid)) ()
      !_A3 = assert (sperValidFid == perValidFid
                     `blame` "wrong accumulated sperValidFid"
                     `swith` (sperValidFid, perValidFid)) ()
      !_A2 = assert (sperCacheFid == perCacheFid
                     `blame` "wrong accumulated sperCacheFid"
                     `swith` (sperCacheFid, perCacheFid)) ()
      !_A1 = assert (sperFid == perFid
                     `blame` "wrong accumulated perception"
                     `swith` (sperFid, perFid)) ()
  return ()

dieSer :: MonadServerAtomic m => ActorId -> Actor -> m ()
dieSer aid b = do
  unless (bproj b) $ do
    kindId <- getsState $ getIidKindIdServer $ btrunk b
    execUpdAtomic $ UpdRecordKill aid kindId 1
    -- At this point the actor's body exists and his items are not dropped.
    deduceKilled aid
    electLeader (bfid b) (blid b) aid
    fact <- getsState $ (EM.! bfid b) . sfactionD
    -- Prevent faction's stash from being lost in case they are not spawners.
    -- Projectiles can't drop stash, because they are blind and so the faction
    -- would not see the actor that drops the stash, leading to a crash.
    -- But this is OK; projectiles can't be leaders, so stash dropped earlier.
    when (isNothing $ gleader fact) $ moveStores False aid CSha CInv
  -- If the actor was a projectile and no effect was triggered by hitting
  -- an enemy, the item still exists and @OnSmash@ effects will be triggered:
  dropAllItems aid b
  b2 <- getsState $ getActorBody aid
  execUpdAtomic $ UpdDestroyActor aid b2 []

-- | Drop all actor's items.
dropAllItems :: MonadServerAtomic m => ActorId -> Actor -> m ()
dropAllItems aid b = do
  mapActorCStore_ CInv (dropCStoreItem False CInv aid b maxBound) b
  mapActorCStore_ CEqp (dropCStoreItem False CEqp aid b maxBound) b

-- | Save game on server and all clients.
writeSaveAll :: MonadServerAtomic m => Bool -> m ()
writeSaveAll uiRequested = do
  bench <- getsServer $ sbenchmark . sclientOptions . soptions
  noConfirmsGame <- isNoConfirmsGame
  when (uiRequested || not bench && not noConfirmsGame) $ do
    execUpdAtomic UpdWriteSave
    saveServer
#ifdef WITH_EXPENSIVE_ASSERTIONS
    -- This check is sometimes repeated in @gameExit@, but we don't care about
    -- speed of shutdown and even more so in WITH_EXPENSIVE_ASSERTIONS mode.
    verifyCaches
#endif
