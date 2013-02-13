{-# LANGUAGE DeriveDataTypeable #-}
-- | Abstract syntax of server commands.
module Game.LambdaHack.CmdSer
  ( CmdSer(..), timedCmdSer
  ) where

import Data.Typeable

import Game.LambdaHack.Actor
import Game.LambdaHack.Faction
import Game.LambdaHack.Item
import Game.LambdaHack.Level
import Game.LambdaHack.Point
import Game.LambdaHack.Vector

-- | Abstract syntax of server commands.
data CmdSer =
    ApplySer ActorId ItemId Container
  | ProjectSer ActorId Point Int ItemId Container
  | TriggerSer ActorId Point
  | PickupSer ActorId ItemId Int InvChar
  | DropSer ActorId ItemId
  | WaitSer ActorId
  | MoveSer ActorId Vector
  | RunSer ActorId Vector
  | GameExitSer
  | GameRestartSer FactionId
  | GameSaveSer
  | CfgDumpSer
  | ClearPathSer ActorId
  | SetPathSer ActorId Vector [Vector]
  | DieSer ActorId
  | LeaderSer FactionId ActorId
  deriving (Show, Typeable)

timedCmdSer :: CmdSer -> Bool
timedCmdSer cmd = case cmd of
  GameExitSer -> False
  GameRestartSer{} -> False
  GameSaveSer -> False
  CfgDumpSer -> False
  ClearPathSer{} -> False
  SetPathSer{} -> False
  DieSer{} -> False
  LeaderSer _ _ -> False
  _ -> True
