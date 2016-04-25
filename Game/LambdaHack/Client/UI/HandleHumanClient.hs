-- | Semantics of human player commands.
module Game.LambdaHack.Client.UI.HandleHumanClient
  ( cmdHumanSem
  ) where

import Prelude ()
import Prelude.Compat

import Game.LambdaHack.Client.UI.HandleHumanGlobalClient
import Game.LambdaHack.Client.UI.HandleHumanLocalClient
import Game.LambdaHack.Client.UI.HumanCmd
import Game.LambdaHack.Client.UI.MonadClientUI
import Game.LambdaHack.Client.UI.MsgClient
import Game.LambdaHack.Common.Request

-- | The semantics of human player commands in terms of the @Action@ monad.
-- Decides if the action takes time and what action to perform.
-- Some time cosuming commands are enabled in targeting mode, but cannot be
-- invoked in targeting mode on a remote level (level different than
-- the level of the leader).
cmdHumanSem :: MonadClientUI m => HumanCmd -> m (SlideOrCmd RequestUI)
cmdHumanSem cmd =
  if noRemoteHumanCmd cmd then do
    -- If in targeting mode, check if the current level is the same
    -- as player level and refuse performing the action otherwise.
    arena <- getArenaUI
    lidV <- viewedLevel
    if arena /= lidV then
      failWith "command disabled on a remote level, press ESC to switch back"
    else cmdAction cmd
  else cmdAction cmd

-- | Compute the basic action for a command and mark whether it takes time.
cmdAction :: MonadClientUI m => HumanCmd -> m (SlideOrCmd RequestUI)
cmdAction cmd = case cmd of
  ReplaceFail failureMsg cmd1 ->
    cmdAction cmd1 >>= either (const $ failWith failureMsg) (return . Right)
  Alias _ cmd1 -> cmdAction cmd1
  Macro kms -> Left <$> macroHuman kms
  ByArea l -> byAreaHuman cmdAction l
  ByAimMode{..} ->
    byAimModeHuman (cmdAction notAiming) (cmdAction aiming)
  ByItemMode{..} ->
    byItemModeHuman (cmdAction notChosen) (cmdAction chosen)
  ComposeIfLeft cmd1 cmd2 ->
    composeIfLeftHuman (cmdAction cmd1) (cmdAction cmd2)
  ComposeIfEmpty cmd1 cmd2 ->
    composeIfEmptyHuman (cmdAction cmd1) (cmdAction cmd2)

  Wait -> Right <$> fmap timedToUI waitHuman
  Move v -> fmap ReqUITimed <$> moveRunHuman True True False False v
  Run v -> fmap ReqUITimed <$> moveRunHuman True True True True v
  RunOnceAhead -> fmap ReqUITimed <$> runOnceAheadHuman
  MoveOnceToCursor -> fmap ReqUITimed <$> moveOnceToCursorHuman
  RunOnceToCursor  -> fmap ReqUITimed <$> runOnceToCursorHuman
  ContinueToCursor -> fmap ReqUITimed <$> continueToCursorHuman
  MoveItem cLegalRaw toCStore mverb _ auto ->
    fmap timedToUI <$> moveItemHuman cLegalRaw toCStore mverb auto
  Project ts -> fmap timedToUI <$> projectHuman ts
  Apply ts -> fmap timedToUI <$> applyHuman ts
  AlterDir ts -> fmap timedToUI <$> alterDirHuman ts
  TriggerTile ts -> fmap timedToUI <$> triggerTileHuman ts
  Help mstart -> helpHuman cmdAction mstart
  MainMenu -> mainMenuHuman cmdAction
  GameDifficultyIncr -> gameDifficultyIncr >> mainMenuHuman cmdAction

  GameRestart t -> gameRestartHuman t
  GameExit -> gameExitHuman
  GameSave -> fmap Right gameSaveHuman
  Tactic -> tacticHuman
  Automate -> automateHuman

  Clear -> addNoSlides clearHuman
  ChooseItem cstore -> Left <$> chooseItemHuman cstore
  PickLeader k -> Left <$> pickLeaderHuman k
  PickLeaderWithPointer -> Left <$> pickLeaderWithPointerHuman
  MemberCycle -> Left <$> memberCycleHuman
  MemberBack -> Left <$> memberBackHuman
  SelectActor -> addNoSlides selectActorHuman
  SelectNone -> addNoSlides selectNoneHuman
  SelectWithPointer -> addNoSlides selectWithPointerHuman
  Repeat n -> addNoSlides $ repeatHuman n
  Record -> Left <$> recordHuman
  History -> addNoSlides historyHuman
  MarkVision -> markVisionHuman >> settingsMenuHuman cmdAction
  MarkSmell -> markSmellHuman >> settingsMenuHuman cmdAction
  MarkSuspect -> markSuspectHuman >> settingsMenuHuman cmdAction
  SettingsMenu -> settingsMenuHuman cmdAction

  Cancel -> cancelHuman
  Accept -> acceptHuman
  TgtClear -> Left <$> tgtClearHuman
  MoveCursor v k -> Left <$> moveCursorHuman v k
  TgtFloor -> Left <$> tgtFloorHuman
  TgtEnemy -> Left <$> tgtEnemyHuman
  TgtAscend k -> Left <$> tgtAscendHuman k
  EpsIncr b -> Left <$> epsIncrHuman b
  CursorUnknown -> Left <$> cursorUnknownHuman
  CursorItem -> Left <$> cursorItemHuman
  CursorStair up -> Left <$> cursorStairHuman up
  CursorPointerFloor -> addNoSlides cursorPointerFloorHuman
  CursorPointerEnemy -> addNoSlides cursorPointerEnemyHuman
  TgtPointerFloor -> Left <$> tgtPointerFloorHuman
  TgtPointerEnemy -> Left <$> tgtPointerEnemyHuman

addNoSlides :: Monad m => m () -> m (SlideOrCmd RequestUI)
addNoSlides cmdCli = cmdCli >> return (Left mempty)
