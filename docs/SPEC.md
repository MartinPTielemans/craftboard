# CraftBoard — spec (v0.1, 2026-09-26)

A WoW: Forever addon: a realm-wide crafting order board over addon messages, that is
also useful alone as a personal "what can I craft / what am I missing" tool.

## Target client facts (verified from installed addons on 2026-09-26)
- Forever is a **mainline-type** client. TOC `## Interface: 16001`. Addons detect it with
  `local build = select(4, GetBuildInfo()); IsForever = build >= 16000 and build < 20000`.
- Modern profession API: `C_TradeSkillUI.*` (`GetAllRecipeIDs`, `GetRecipeInfo`,
  `GetRecipeSchematic(recipeID,false)` → `.reagentSlotSchematics[i].reagents[j].itemID` and
  `.quantityRequired`, `GetRecipeOutputItemData`, `GetTradeSkillLine`, `GetBaseProfessionInfo`,
  `IsTradeSkillLinked`), events `TRADE_SKILL_SHOW`, `TRADE_SKILL_LIST_UPDATE`, `TRADE_SKILL_CLOSE`.
  Only known (learned) recipes: `C_TradeSkillUI.GetRecipeInfo(id).learned`.
- Bags/bank: `C_Item.GetItemCount(itemID, true)` (bank included) plus `C_Container` APIs.
  Item names: `C_Item.GetItemInfo` / `C_Item.GetItemNameByID`, may be nil until cached → use
  `Item:CreateFromItemID(id):ContinueOnItemLoad(cb)`.
- Comms: AceComm-3.0 + ChatThrottleLib (vendored in `CraftBoard/Libs`), LibSerialize + LibDeflate.
  Distributions: "GUILD" and "CHANNEL" (custom hidden channel joined via `JoinChannelByName`,
  id via `GetChannelName`). Never "SAY"/"YELL". Whisper is a normal `SendChatMessage(..., "WHISPER", nil, name)`.
- Everything is non-combat. No gold amounts in the protocol.

## Modules (one file each, all under `CraftBoard/`)
`CraftBoard.toc` lists them in this order. Global namespace: `local ADDON, NS = ...` ; public
API on `NS`. SavedVariables: `CraftBoardDB` (account-wide).

1. `Core.lua` — addon object, event frame, `NS.Register(event, fn)`, slash `/cb`, `NS.Print`,
   `NS.IsForever`, DB init/defaults, `NS.Realm`/`NS.Faction`/`NS.Me` (name-realm string).
2. `Recipes.lua` — recipe scanner. On profession window open, records every *learned* recipe for
   the open profession into `CraftBoardDB.chars[Me].recipes[recipeID] = {p=profID, o=outputItemID, r={ {itemID,qty}, ... }, n=name}`.
   Also `CraftBoardDB.chars[Me].profs[profID] = {name, rank, max}`. API: `NS.Recipes.Scan()`,
   `NS.Recipes.Mine()` → table, `NS.Recipes.Search(text)` → list of {recipeID, name, outputItemID, crafters={...}} across my chars and peers.
3. `Inventory.lua` — `NS.Inventory.Count(itemID)` (bags+bank), `NS.Inventory.CanCraft(recipe)` →
   `{ready=bool, missing={ {itemID, need, have}... } }`, `NS.Inventory.ShoppingList(recipeIDs)`.
4. `Comm.lua` — sync layer (see protocol). API: `NS.Comm.Broadcast()`, `NS.Comm.Peers()` →
   `{ [name-realm] = {recipes={[recipeID]=true}, profs={...}, seen=time, online=bool} }`,
   `NS.Comm.Request(itemID, qty, toName)` (sends a whisper), `NS.Comm.PostRequest(itemID, qty, note)`
   (open board post), `NS.Comm.Requests()` → open posts. Peers persisted in `CraftBoardDB.peers`.
5. `UI.lua` — one movable window: search box, results list ("who can make X", online first,
   my own chars marked), reagent panel with have/need, buttons "Whisper" (pre-filled template) and
   "Post request". Second tab "Requests" listing open board posts. Minimal, Blizzard-styled
   (`BasicFrameTemplateWithInset`), no external UI libs.

## Protocol (Comm.lua) — prefix `CBRD`, version byte first
Payloads are LibSerialize → LibDeflate:CompressDeflate → EncodeForWoWAddonChannel.
- `H` hello: `{v=1, profs={[profID]=rank}, n=#recipes, h=hash}` on login/channel join and every
  10 min (jittered). Recipients whose stored hash differs reply `Q` (query) to that sender only.
- `Q` query → sender answers `R` recipes: `{v=1, list={recipeID,...}, h=hash}` (recipe IDs only,
  compact). Whisper-distribution replies are fine (AceComm whisper → "WHISPER" addon msg).
- `P` post: `{v=1, id=<sender..time>, item=itemID, qty=n, note=<=60 chars, t=time}`; `X` retract.
  Posts expire after 24h locally.
- Two distributions: GUILD always (if in guild), CHANNEL when `CraftBoardDB.realmChannel` is on
  (default on). Channel name `CraftBoardF` (hidden from chat: leave it out of chat frames).
- Rate limit: hello ≤1/10min, full list ≤1/min per peer; ignore malformed / oversize input.

## Non-goals (v0.1)
No gold/tips in protocol, no cross-faction, no auction-house integration, no combat anything.

## Dev loop
`tools/link.sh` symlinks into the beta AddOns dir; `tools/check.sh` parses all Lua.
In game: `/reload`, `/cb` opens window, `/cb scan` forces a scan, `/cb debug` prints peers.
