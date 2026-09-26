# Changelog

All notable changes to CraftBoard are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Options panel in the game settings (`/cb options` or `/cb config`): share recipes on the realm
  channel, share recipes with your guild (new, on by default; off stops all guild broadcasts),
  and "Forget all peer data" to clear known crafters and board posts.
- Localization: every user-visible string goes through a locale table (`Locales.lua`), English
  by default, ready for translations.

### Changed
- The window now looks and works like Blizzard's Professions crafting page. Find and Mine
  have a left column with the search box and a Filter dropdown (All professions, or one
  profession; Mine also has "Short on") above a bordered list. Recipes are grouped under gold
  collapsible headers: Blizzard's own categories ("Cloaks", "Reagents", ...) for recipes any
  of your characters knows, otherwise a group from the crafted item's slot or type. With
  All professions selected, each profession gets a header above its categories. Collapsed
  groups are remembered, and searching opens every group that has a match. The right inset
  shows the recipe page: a round icon, the quality-coloured name, the item's description,
  reagent boxes ("2/5 Light Leather", red when short) and the crafters (online in green).
  The page is never empty: the first visible recipe is selected. Quantity, note, Whisper and
  Post request sit in the bottom button bar. The portrait shows the selected profession's
  icon. The window is larger by default (760x520). Requests sit in the same inset layout,
  and the status line moved beside the portrait.
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
- Mine: profession headers show a count, and a "Short on" chip replaces the checkbox.
  Clicking a reagent puts its item link into an open chat box.
- Requests: card rows ("Bob wants 3x Item", note, age) with one Offer / Retract button, and a
  check on requests you can craft.
- The window can be resized (the size is remembered). A footer shows recipes, peers and
  channel state.
- Recipes whose crafted item is Bind on Pickup (or a quest item) are no longer shared with
  other players and are hidden from the Find tab. They still appear on the Mine tab.
- Reopening a profession window skips the full recipe read when your learned recipes haven't
  changed; `/cb scan` still forces a full rescan.
- Reagents with several quality tiers count every tier you own toward have/need, craftable
  counts and the shopping list.

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
