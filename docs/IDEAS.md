# Ideas and requests

Community requests worth building, with the shape they should take. Ordered by value.

## Busy / do-not-disturb (Reddit, u/rhaesdaenys, 2026-09-27) — shipped in 0.9.4
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

## Owner verdicts on the ambitious list (2026-09-27)
- **Rejected:** orders by mail (requires too much trust), web board with a desktop uploader.
- **Wanted:** multi-crafter chains (a request missing an intermediate splits into linked orders for
  each crafter, e.g. Toughened Leather Gloves needs an alchemist for Elixir of Lesser Defense).
- **Maybe:** realm demand insights (most-requested crafts, recipes wanted but rarely known);
  crowd-sourced recipe sources (record trainer / vendor / drop when a recipe is learned).
- **Rejected:** a board that persists while authors are offline. The trade itself needs both
  players online, so offline posts are mostly clutter.
- **Instead, small:** "back online" alert. When a player whose request I can craft (or offered on)
  comes online again, show a quiet notice. Uses posts already kept locally for 24 h; no relaying.
- **Wanted, small:** crafter queue with total mats; one-click enchant in the trade window via a
  secure button; cooldown sharing (transmutes, Mooncloth); private "crafted for you N times";
  respect the ignore list; crafters-in-your-group tooltips; gamepad support; full UI translations
  (deDE, frFR, esES).

## Built (Unreleased, 2026-09-28)
Everything under "Wanted" above, plus the Requests tab rework:
- Multi-crafter chains: P carries an optional `pa` (parent post id). Reagent tooltips name who
  makes an intermediate; "Post linked orders" on a request card and Post request in Find post
  them. Retracting a post retracts its linked orders. Chains only work where one of my characters
  knows the craft's reagents (peers' recipe lists carry no reagents).
- Back-online notice: the hello's first send after login carries `l=true`; a peer whose `l` hello
  arrives and who has a post I can craft or offered on (`CraftBoardDB.offered`) gets one chat line,
  at most once per 30 min. Option `backOnline`.
- Crafter queue (`chars[Me].queue`) with summed reagents; trades complete entries.
- One-click enchant: secure macro button under TradeFrame (`/cast` + `/click
  TradeRecipientItem7ItemButton`), shown when the partner queued or asked in chat for an enchant
  the current character knows.
- Cooldown sharing: hello `cd = {[recipeID] = seconds until ready}` (at most 16). Cooldown crafts:
  a known list, "Transmute" names, and any recipe seen with a running cooldown in the profession
  window (`rec.cdr`). Localized clients rely on the last two.
- Private crafted-for-you counts (`CraftBoardDB.crafted`), from the trade window on completion.
- Ignore list respected in Peers, posts, chat asks and tooltips.
- Group tooltips (items: group members who craft it; units: their professions). Option.
- Gamepad: D-pad / A / B / shoulders while the window is up. Option.
- deDE, frFR, esES translations (`Locales_<locale>.lua`, checked by `tools/check-locales.lua`).
  Chat detection still matches English words only ("lf", "ench", "lw"...).
Still "maybe": realm demand insights, crowd-sourced recipe sources.

## Scaling on a realmless game (2026-09-27)
Forever has no realms, only region + ruleset. If the hidden channel spans that whole population,
the current sync (hello every ~10 min from every client, then a whispered full recipe list per
peer) will not scale past a few hundred users: every login queries every peer. Before that point:
- Replace full recipe sync with on-demand queries: "who can craft item X?" goes out on search,
  crafters who know it answer. Recipe lists stay local.
- Hellos carry only professions and busy state; cap how many peers are tracked.
- Verify first whether the channel really spans the region (peers from far-away zones, counts).
