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
   `{ready=bool, reagents=, missing={ {itemID, need, have}... }, times=}` (count = output items, turned
   into crafts by the recipe's yield), `NS.Inventory.Totals(list)` (reagents summed over crafts).
4. `Comm.lua` — sync layer (see protocol). API: `NS.Comm.Broadcast()`, `NS.Comm.Peers()` →
   `{ [name-realm] = {recipes={[recipeID]=true}, profs={...}, seen=time, online=bool} }`,
   `NS.Comm.Request(itemID, qty, toName)` (sends a whisper), `NS.Comm.PostRequest(itemID, qty, note)`
   (open board post), `NS.Comm.Requests()` → open posts. Peers persisted in `CraftBoardDB.peers`.
4b. `ChatWatch.lua` — reads public chat (CHAT_MSG_CHANNEL for server channels Trade/General/
   LookingForGroup, SAY, YELL, GUILD when opted in) for crafting requests; pure-Lua detector
   `ChatWatch.Detect(text)`, in-memory store `ChatWatch.Seen()` (one per player, 30 min, cap 40),
   fires `CHAT_SEEN_UPDATED`. Never sends anything. Shown as "Seen in chat" on Requests.
5. `UI.lua` — one window that reproduces the client's own Professions window exactly
   (atlases, fonts, offsets captured in `docs/professionsframe-dump.txt`; `/cb dump` recaptures).
   Three tabs (side tabs standalone, top tabs inside ProfessionsFrame): **Plan** (1.0, see below),
   **Find** (grouped recipe list under Blizzard category headers, search + Filter
   dropdown, recipe card with reagent slots have/need, a "Missing: ..." line for my own short
   recipes, crafters, Whisper and Post request) and **Requests** (open board posts). A one-line
   board status ("N crafters online · M open requests") sits where Blizzard shows the skill bar;
   nothing that WoW's own UI already shows is repeated. No external UI libs. Status data from
   `NS.Comm.Status()` → `{peers, online, posts, channel, channelOn, guild}`.
   Design rules: Bind-on-Pickup outputs never appear in Find (they cannot be made for others).
   The Find / Requests content is built by `NS.UI.BuildContent(host)` and moves between hosts
   (one at a time): the standalone window or Embed.lua's page.
6. `Embed.lua` — a CraftBoard side tab on Blizzard's `ProfessionsFrame` (under its lowest
   side tab) and a 673x594 overlay page holding the same content. Never goes through Blizzard's
   tab system (no AddNamedTab/SetTab calls, no fields written on Blizzard frames, no page
   shown/hidden by us); Blizzard tab clicks hide the page via post-hooks. /cb, the minimap
   button and the key binding open ProfessionsFrame on this tab when Blizzard_Professions is
   loaded, the player has a profession and is out of combat; otherwise the standalone window.
   Option "Open CraftBoard inside the Professions window" (default on). Hooks.lua's buttons
   are hidden while the tab exists.

## 1.0 modules (2026-09-28)
- `Skills.lua` — profession ranks from the profession book (`GetProfessions`), trainer reminders,
  `Skills.Ranks()` / `Skills.NextRank(profID)`.
- `Cooldowns.lua` — crafting cooldowns per character, shared in the hello, ready notice.
- `Queue.lua` — crafts I'll make (`chars[Me].queue`), summed reagents, `made` counts from casts.
- `Craft.lua` — Craft / Craft next through `C_TradeSkillUI.CraftRecipe` from a click, only with
  that profession's window open on my own character.
- `Trade.lua` — crafted-for-you counts, queue delivery, one-click enchant button.
- `Merchant.lua` — "Buy missing reagents" for the queue's vendor reagents (leaving out crafts
  whose player brings the reagents), checked against money, stock and bag space.
- `Tooltips.lua` — group crafters, reagent use / queue needs / alt counts, recipe items vs. my
  characters.
- Inventory keeps `chars[key].bags` and `.bank` (reagent-like items only; the bank as last seen,
  topped up from the client's cached counts at login) for counts on alts of the same realm and
  faction.
- UI has a third tab, Plan (recipes by skill-up colour from `rec.d`, saved at each scan).

## After 1.0 (2026-10-06)
- `Marks.lua` — pinned recipes (`CraftBoardDB.pinned[recipeID]`) and the wishlist
  (`CraftBoardDB.wish[itemID]`), with a chat-link notice. Fires `MARKS_UPDATED`.
- `Templates.lua` — the player's whisper wording (`CraftBoardDB.templates.request/offer`, with
  `{item}` / `{qty}`) and its editor (`/cb texts`).
- `Stats.lua` — private crafting history (`chars[Me].crafts[recipeID]`), session counts,
  milestones, and demand counts (`CraftBoardDB.demand[itemID][day] = asks`, 14 days, no names).
- Skills reads specializations (`chars[Me].specs[spellID]`); Recipes records where a recipe was
  learned (catalogue field `s`: 1 = trainer, else the recipe item's ID).
- Plan lists recipes not learned yet (from the catalogue); Find's Filter adds "Most asked for
  first" and "Only guild crafters"; reagent slots ask the board for materials.

## Protocol (Comm.lua) — prefix `CBRD`, version byte first
Payloads are LibSerialize → LibDeflate:CompressDeflate → EncodeForWoWAddonChannel.
- `H` hello: `{v=1, profs={[profID]={n=name,r=rank,m=max}}, n=#recipes, h=hash, b=true?, l=true?, cd={[recipeID]=secs}?}`
  on login/channel join and every 10 min (jittered); `b` (busy) is optional and also triggers an
  extra hello within ~5 s when it changes; `l` marks the first hello after login (back-online
  notice); `cd` carries crafting cooldowns as seconds until ready. Recipients whose stored hash differs reply `Q` (query) to that sender only.
- `Q` query → sender answers `R` recipes: `{v=1, list={{id,name,outputItemID,profID},...}, h=hash, profs=}` (names
  dropped, then the list truncated, to fit 8 KB compressed;
  compact). Whisper-distribution replies are fine (AceComm whisper → "WHISPER" addon msg).
- `P` post: `{v=1, id=<sender..time>, item=itemID, qty=n, note=<=60 chars, t=time, pa=parent id?, k="m"?}`;
  `X` retract. `pa` links an order for an intermediate to the request it is for; `k="m"` asks for
  the materials themselves (older clients show it as an ordinary request).
- Hello `sp={spellID,...}` (optional): the sender's specializations. R and A list entries may carry
  a fifth field: where the recipe is learned (1 = trainer, else the recipe item's ID).
  Posts expire after 24h locally.
- `W` who-can-craft: `{v=1, id=, q=lower-case text?, i={outputItemID,...}?}` on GUILD/CHANNEL, sent
  from a Find search (debounced 1.5 s, one per 4 s, the same question once per 5 min). Crafters
  with matching shareable recipes (name or output item name in their language, or the item IDs)
  whisper `A` `{v=1, id=W id, list={{id,name,outputItemID,profID},...} (<=30), profs=}` after a
  0.5-3 s random wait (one per asker per 30 s, 20 per minute). An `A` is only taken for my own `W`
  within 60 s and is merged into that peer's recipes. Older clients drop both unread.
- On-demand mode (`Comm.OnDemand()`): over 150 channel players heard within a day (guildmates
  aside), channel peers' hellos no longer trigger `Q`; Find asks `W` instead. Guild peers always
  sync in full. At most 1000 peers are stored (the longest unheard go) and at most 12 full
  recipe lists are whispered per minute (the rest wait). `/cb debug ondemand` forces the mode.
- Two distributions: GUILD always (if in guild), CHANNEL when `CraftBoardDB.realmChannel` is on
  (default on). Channel name `CraftBoardF` (hidden from chat: leave it out of chat frames).
- Rate limit: hello ≤1/10min per distribution (busy changes: ≤1/15 s), full list ≤1/min per peer;
  ignore malformed / oversize input; exact duplicates (guild + channel) are dropped before counting.

## Non-goals (v0.1)
No gold/tips in protocol, no cross-faction, no auction-house integration, no combat anything.

## Dev loop
`tools/link.sh` symlinks into the beta AddOns dir; `tools/check.sh` parses all Lua.
In game: `/reload`, `/cb` opens window, `/cb scan` forces a scan, `/cb debug` prints peers.
