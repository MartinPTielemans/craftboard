# Ideas and requests

Community requests worth building, with the shape they should take. Ordered by value.

## Busy / do-not-disturb (Reddit, u/rhaesdaenys, 2026-09-27)
A crafter can mark themselves unavailable so they are not whispered while in a dungeon.
- One toggle: the minimap button's right-click menu, `/cb busy`, and a small "Available" switch
  on the board header. State is per character, saved.
- While busy: our hello carries `busy=true`; peers show the crafter greyed with "(busy)" and the
  Whisper button disabled; the crafter still appears so buyers know they exist.
- **Auto-busy** when in a dungeon/raid instance or in combat (`IsInInstance()`, `PLAYER_REGEN_*`),
  with an option to turn auto-busy off. Manual busy overrides auto.
- Requests posted to the board are still visible to a busy crafter; only inbound whispers via
  the addon are discouraged. We cannot block whispers, only steer them.
- Protocol: add optional `b` (busy) field to hello; older clients ignore unknown fields.

## Design line (Reddit thread, 2026-09-27, owner commitment)
Nothing in CraftBoard ever sends a whisper, invite, trade, or chat line on its own. Every outbound
message is one click by the player. No keyword-triggered automation. Keep it that way.

## Crafter ordering (Reddit, 2026-09-27)
Online first, then own characters, then shuffled per session. No ratings, no featured, nothing
purchasable. Shipped in 0.9.2.

## Chat watch tuning (in progress)
Detector must be tuned on real Trade lines (`CraftBoardDB.chatlog`), not synthetic ones.
