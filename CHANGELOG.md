# Changelog

All notable changes to CraftBoard are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

CraftBoard 1.0: from a crafting-order board to a crafting companion for Forever.

### Added
- Find: "Hide what I can craft" in the Filter menu leaves out what you can get without anyone
  else: what this character makes, and items your characters on this realm and faction make and
  can mail you. An enchant only an alt knows stays listed (without a scroll it has to be put on
  your gear in person), with the other players who know it. Professions with nothing left drop
  out of the menu while it is on.
- Plan tab: your professions with their learned recipes by skill-up colour (orange, yellow,
  green, grey), ready ones first. The card says how many crafts reach the next milestone, when you
  can train the next rank, and which reagents the planned crafts need (with what your alts hold).
  Queue adds the planned crafts to your queue; Craft makes them while that profession's window is
  open, one click per batch.
- Craft and Craft next on the queue: make a queued craft, or the next one your bags allow, from
  the Requests tab while the profession window is open.
- Mats across alts: CraftBoard remembers bags and bank per character; reagent slots show "+12 on
  alts" and item tooltips say which alt holds how many.
- Reagent tooltips: how many of your recipes use the item and what your queue needs of it.
- Recipe tooltips: which of your characters know the recipe, can learn it, or need more skill.
- Buy missing mats: at a merchant, one button buys the vendor reagents your queue still lacks.
- Cooldown-ready notice and trainer reminders (one quiet chat line each; options).
- The minimap button's tooltip sums it up: requests you can craft, the queue, ready cooldowns,
  trainable ranks.
- Welcome window rewritten for the wider focus.
- Requests tab reworked: rows show what is wanted (item icon and name, "3x" for more than one)
  and who asked, in a muted "Bob · 8m". New group order: "You can craft" (board requests and chat
  asks one of your characters can make, ready ones first), "My queue", "Open requests", "Seen in
  chat", "My requests". Rows older than 10 minutes are dimmed. A Filter with "Only what I can
  craft", a right-click menu on every row, and a count on the Requests tab.
- The request card says whether you know the recipe (or which alt does), whether they bring the
  mats, what you are missing, and how often they asked. The chat line is only quoted when it says
  more than the title. Asking again for the same thing updates the one row instead of adding one.
- Crafter queue: "Queue" on a request you can craft; "My queue" lists them with an "All reagents"
  row summing everything against your bags and bank. A trade that hands the craft over takes it
  off the queue.
- Multi-crafter chains: when a craft needs an intermediate someone else makes (for example an
  Elixir of Lesser Defense for Toughened Leather Gloves), reagent tooltips name who makes it,
  "Post linked orders" asks the board for it, and Post request in Find posts those linked orders
  with the request. Linked orders show on each other's cards and are retracted together.
- Cooldown sharing: transmutes, Mooncloth and other crafting cooldowns show as "ready" or time
  left next to crafters in Find; `/cb cd` lists your characters' cooldowns.
- One-click enchant: when your trade partner asked for an enchant you know (queued, or seen in
  chat), a button under the trade window casts it on their item in "Will not be traded". It
  waits while the enchant's reagents aren't in your bags.
- Private "crafted for you" counts, read from completed trades and shown on crafter and request
  tooltips. Never sent anywhere.
- "Back online" notice: one quiet chat line when a player whose request you can craft, or offered
  on, logs back in (option, default on).
- Group tooltips: in a party or raid, item tooltips name the group members who can craft the item
  and their tooltips list their professions (option, default on).
- Gamepad controls in the window: D-pad moves through the list, A whispers or offers, B closes,
  shoulder buttons switch tabs (option, default on; only with gamepad mode enabled).
- Full German, French and Spanish translations.

### Changed
- Players on your ignore list no longer appear as crafters, board requests or chat asks.
- Requests: requests from players who are offline are dimmed, listed last and left out of the
  count; Offer only appears for requests you can craft; a player who both posts and asks in chat
  is listed once; your alts' requests show under My requests (retract them on that alt). The list
  no longer moves while the mouse is over it. Offering shows "Offered" for ten minutes.
- Chat detection: "can anyone make [X]?", "who can craft [X]?", "need enchanter", "5x [item]" and
  "bring mats" are understood; crafter adverts, guild recruitment, LFG lines and item links for
  things nobody crafts are no longer taken for requests; "nvm, found one" removes the ask.
- Plan: a "Best next" pick per profession (from what your bags allow), Blizzard's skill-up marks, honest estimates for yellow
  and green recipes, notices at the cap and when colors are out of date, and a bar for every
  profession (gathering ones too). The Craft button opens the profession window when it is
  closed and says "Crafting..." while a batch runs; a picked recipe stays picked under filters.
- Craft checks cooldowns, required tools and the reagents in your bags (not the bank).
- Queue: shows what is made ("2/5", "made · Bob"); reagent totals and Buy missing count only
  what is still to make and skip crafts whose player brings the reagents.
- Tooltips: alt counts only on reagents, per alt; recipe tooltips group "Known by", "Can learn"
  (naming a specialization, reputation or level it can't check for an alt), "Needs level" and
  "Needs more skill"; only characters on your realm and faction count as alts.
- Buy missing reagents: stays clear of the Buyback tab, checks money and bag space, and reports
  what actually arrived.
- The one-click enchant button works with the Enchanting window open (crafting through the API)
  or closed (a macro), and says why it is disabled.
- Trainer reminders know book and quest ranks for Cooking, First Aid and Fishing; trainers'
  waiting recipes are remembered. Transmutes that share a cooldown are one notice.
- Settings are grouped into sections; "Forget other players' data" asks first and keeps your own
  requests. The welcome window shows once more for the 1.0 changes.
- Auto-busy covers dungeons and raids only (addon messages can't go out in combat).
- /cb find, /cb requests, /cb plan, /cb chars and /cb forget; /cb opens the Professions-window tab
  even before a profession window was opened this session.
- Whispers from Find and Requests now open the chat box with the text typed in, for you to send.
  Only Offer and Advertise send straight away, and their tooltips say so.

### Fixed
- Chat watching kept the last 40 Trade lines in your saved variables; they are deleted now and
  only kept when you turn on `/cb chatdebug log`.
- "Back online" notices no longer fire after a /reload.
- Forever names: `UnitName` returns the surname there, not the realm. Your character is now
  keyed "First Surname" (saved data and your open posts move over on first login), party
  members and trade partners are read the same way, and a player who shares your first name is
  no longer taken for you (#4).
- "Seen in chat" quoted Forever's item links as "cnIQ1:[Light Leather]": its named quality colour
  codes are now stripped everywhere (chat lines, peer data, the tuning log).

## [0.9.4] - 2026-09-27

### Added
- Busy / available (requested on Reddit): mark yourself busy with `/cb busy`, shift-right-click
  on the minimap button, or the "Available" / "Busy" switch on the board header. Other
  CraftBoard users then see you greyed out with "(busy)" in the crafter list, can't pick you
  from it, and their Whisper button stays off; busy crafters are listed after available ones
  and still count as online. By default you are also busy automatically in dungeons, raids and
  combat (option "Automatically mark me busy in dungeons and combat"). Older versions simply
  don't see the flag.
- "Seen in chat" knows your alts: the check is green when any of your characters knows the
  recipe and this one carries the mats, and grey when only an alt knows it; the row tooltip
  says which alt.
- `/cb chatdebug` also lists the chat channels the watcher has accepted so far (for example
  "Trade, Trade (Services)").

## [0.9.3] - 2026-09-27

### Fixed
- Your own character no longer shows up as a peer ("1 crafter online" with nobody else installed).
- Adverts with bracketed words like [PvP] are no longer read as crafting requests; a plain
  [Name] only counts when it is one of your recipes.

## [0.9.2] - 2026-09-27

### Fixed
- Player names with a space (every Forever character) were rejected by the sync layer and the
  chat watcher, so peers and chat requests never appeared.
- Forever's language-split channels ("Trade - English", "Trade (Services) - English") are now
  recognised by the chat watcher.

### Added
- "Seen in chat" on the Requests tab (suggested on Reddit): CraftBoard reads Trade, General,
  LookingForGroup, say and yell for players looking for a crafter ("LF LW for...",
  "WTB [item]", "need an alch", "anyone can make [item]?") and lists them between Open requests
  and My requests, one line per player, newest first, for 30 minutes. Offers ("WTS", "selling",
  "LFW", "can craft", "tips welcome", "max ench") are skipped. A green check marks lines for one
  of your professions or a recipe you know; the card shows the chat line and, for a known
  recipe, your reagents. Whisper opens the chat box to the player with
  "[CraftBoard] I can craft that for you." typed in; Hide drops the line. Nothing is sent
  without a click and nothing is saved.
- Options "Watch chat for crafting requests" (on) and "Include guild chat" (off).

## [0.9.1] - 2026-09-27

### Changed
- CraftBoard now lives in Blizzard's Professions window as its own side tab (under the
  profession tabs, CraftBoard icon). Find and Requests are top tabs inside the page. Clicking a Blizzard tab goes back to Blizzard's page; Escape
  closes the Professions window as usual. The minimap button, `/cb` and the key binding open the
  Professions window on the CraftBoard tab once it has been opened this session; before that, in
  combat, or without any profession they open the standalone window, which stays available.
  "Open Professions" in the welcome window lands on the CraftBoard tab. The old "CraftBoard"
  buttons on the Professions window are gone while the tab is there. CraftBoard never goes
  through Blizzard's own tab switching, so crafting is unaffected.
- First login after install shows a welcome window instead of a chat line (see Added).
- "Show tips again" now opens the window and plays the three tips straight away.
- Advertise defaults to the Trade channel.

### Added
- Minimap button (LibDataBroker launcher shown by LibDBIcon): left-click opens the window,
  right-click opens the settings, shift-left-click rescans the open profession window. The
  tooltip shows the board status ("2 crafters online · 1 open request"). Drag it around the
  minimap edge; the position is remembered. Also listed in the addon compartment (the addon
  list button by the minimap) on clients that have one.
- "Show minimap button" option.
- "Open CraftBoard inside the Professions window" option (on by default); off keeps CraftBoard
  in its own window and brings back the CraftBoard buttons on the Professions window.
- Key binding "Toggle CraftBoard window" under Key Bindings > AddOns > CraftBoard (no default key).
- Welcome window, 3 s after the first login after install (waits for combat to end): the board
  art, three steps (record your recipes, find crafters, ask and offer) and an "Open Professions"
  button that opens the profession book. `/cb welcome` and "Show welcome" in the options bring it
  back.
- First-run tips on the window (Blizzard help tips, each shown once): how recipes get recorded
  (with an "Open Professions" button), that your recipes are now shared, and where to post a
  request. "Show tips again" in the options brings them back.

## [0.9.0] - 2026-09-26

First public beta. The sync layer has not yet been exercised between two players; please report
anything odd from `/cb debug`.

### Added
- Options panel in the game settings (`/cb options` or `/cb config`): share recipes on the realm
  channel, share recipes with your guild (new, on by default; off stops all guild broadcasts),
  and "Forget all peer data" to clear known crafters and board posts.
- Localization: every user-visible string goes through a locale table (`Locales.lua`), English
  by default, ready for translations.
- Advertise button (small square next to Post request in Find, tooltip "Announce in chat"):
  posts one plain line for players without CraftBoard, e.g. `LF crafter: 2x [Dark Leather
  Belt], have mats — whisper me (CraftBoard)`, in the channel chosen in Options ("Advertise
  channel": General by default, Trade (cities only), or Off). Only on your click, at most
  once a minute; nothing is ever sent automatically.

### Changed
- The window now looks and works like Blizzard's Professions crafting page, rebuilt from the
  client's own frame (captured in `docs/professionsframe-dump.txt`): the same 673x594 metal
  portrait frame and backgrounds, a quiet status line under the title ("2 crafters online ·
  1 open request", or "No other crafters yet · invite your guild to install CraftBoard";
  " · realm channel off" is added when the realm channel is disabled; hover the portrait for
  "61 recipes · 0 peers · channel ok"), and Find / Requests as side tabs on the window's
  right edge. Find has the 304 px recipe list on the left: search box and Filter dropdown
  (All professions, or one profession) above gold collapsible category bars, Blizzard's own categories
  ("Cloaks", "Reagents", ...) for recipes any of your characters knows, otherwise a group
  from the crafted item's slot or type. With All professions selected, each profession gets
  a bar above its categories. Collapsed groups are remembered, and searching opens every
  group that has a match. Recipe rows show how many you can craft right now as " [n]" after
  the name. The recipe card on the right shows the round output icon in its quality ring,
  the name, the item's description, reagent slots ("2/5 Light Leather", grey when short),
  for recipes one of your characters knows a "Missing: 3 Light Leather, 1 Coarse Thread"
  line when something is short (click a name to put its item link in chat), and the
  crafters (online in green); it is never empty (the first visible recipe is selected).
  Note, quantity, a Whisper button and a red Post request button sit in the Create row
  under the card. The portrait shows the selected profession's icon. The window can be made
  larger, never smaller than Blizzard's.
- Scans record each recipe's Blizzard category and the profession icon (local only; the
  sync protocol is unchanged).
- Window polish. Find: the search box has focus when the window opens, filters as you type
  (2+ characters, every word must match), Enter picks the first result, arrow keys move the
  selection, Escape clears the text and then closes the window. With no search it lists what
  you can craft right now plus everything other players can make. Profession filter chips sit
  above the list. Rows show a right-aligned "you" / alt / "3 online" column and a check when
  you can craft it now. The detail pane shows a large icon and the name in item-quality colour,
  then reagents (have/need), then crafters (click a name to open a pre-filled whisper), and
  qty, note, Whisper and Post request at the bottom.
- Clicking a reagent puts its item link into an open chat box.
- Requests now uses the same two panels as Find, so it feels like the same window. Left: a
  search box (item name or requester) over the recipe list background, with gold
  "Open requests" and "My requests" bars (collapsible) and 20 px rows: the item name in its
  quality colour, "3x · 8m" on the right, and a ready check when your current character can
  craft the whole request right now. Right: the selected request as a recipe card (round
  icon in its quality ring, "Requested by Bob · 8m ago", the note, reagent slots with your
  bags' have/need when one of your characters knows the recipe, else "Reagents unknown",
  and "Requested quantity: 3"). Under the card: a red Offer button (whispers "I can craft
  [item] for you") and a chat button that opens a whisper to the requester, or Retract for
  your own posts. The first request is selected automatically; an empty board says
  "No open requests".
- The window can be resized (the size is remembered).
- Recipes whose crafted item is Bind on Pickup (or a quest item) are no longer shared with
  other players and are hidden from the Find tab.
- Reopening a profession window skips the full recipe read when your learned recipes haven't
  changed; `/cb scan` still forces a full rescan.
- Reagents with several quality tiers count every tier you own toward have/need, craftable
  counts and the shopping list.

### Fixed
- Scrolling a list no longer throws a Lua error on every scroll (`executingEvents` in
  CallbackRegistry): the list scrollbar is now created as the EventFrame its template needs,
  and falls back to the classic scrollbar if it cannot be set up.

### Removed
- The Mine tab (its recipe list, "Short on" filter and shopping list panel). What you are
  short on now shows as the "Missing:" line on the Find recipe card.
- The profession skill bar under the title, replaced by the board status line.

## [0.1.0] - 2026-09-26

First working build for WoW: Forever (Interface 16001).

### Added
- Recipe scanning: opening a profession window records every learned recipe (output item,
  reagents, profession rank). `/cb scan` forces a rescan.
- Personal can-craft: counts reagents in bags and bank, shows what is craftable now and what
  is missing, and builds a shopping list.
- Sync over addon messages (prefix `CBRD`): hello/query/recipe-list exchange and open board
  posts, sent on the guild channel and on a hidden realm channel (`CraftBoardF`), rate limited,
  with peers saved between sessions.
- Window (`/cb`) with Find (who can make an item, online first, your own characters marked,
  reagent have/need, pre-filled whisper), Mine (your recipes) and Requests (open board posts,
  expire after 24h) tabs.
- `/cb debug` prints sync status and known peers.

[Unreleased]: https://github.com/mpt/craftboard/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mpt/craftboard/releases/tag/v0.1.0
