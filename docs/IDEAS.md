# Ideas and requests

Community requests worth building, with the shape they should take. Ordered by value.

## Busy / do-not-disturb (Reddit, u/rhaesdaenys, 2026-09-27) — shipped (Unreleased)
A crafter can mark themselves unavailable so they are not whispered while in a dungeon.
- One toggle: shift-right-click on the minimap button, `/cb busy`, and a small "Available" switch
  on the board header. State is per character, saved (`CraftBoardDB.chars[Me].busy`).
- While busy: our hello carries `busy=true`; peers show the crafter greyed with "(busy)" and the
  Whisper button disabled; the crafter still appears so buyers know they exist.
- **Auto-busy** when in a dungeon/raid instance or in combat (`IsInInstance()`, `PLAYER_REGEN_*`),
  with an option to turn auto-busy off. Manual busy overrides auto.
- Requests posted to the board are still visible to a busy crafter; only inbound whispers via
  the addon are discouraged. We cannot block whispers, only steer them.
- Protocol: add optional `b` (busy) field to hello; older clients ignore unknown fields.
- As built: a busy change is announced by a hello within ~5 s (at most one per 15 s per
  distribution); addon messages are held back in combat, so combat-only busy rarely reaches
  peers before the fight ends. Option "Automatically mark me busy in dungeons and combat"
  (`CraftBoardDB.autoBusy`, default on).

## Design line (Reddit thread, 2026-09-27, owner commitment)
Nothing in CraftBoard ever sends a whisper, invite, trade, or chat line on its own. Every outbound
message is one click by the player. No keyword-triggered automation. Keep it that way.

## Crafter ordering (Reddit, 2026-09-27)
Online first, then own characters, then shuffled per session. No ratings, no featured, nothing
purchasable. Shipped in 0.9.2.

## Chat watch tuning (in progress)
Detector must be tuned on real Trade lines (`CraftBoardDB.chatlog`), not synthetic ones.
