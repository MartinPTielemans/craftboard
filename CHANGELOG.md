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
- Recipes whose crafted item is Bind on Pickup (or a quest item) are no longer shared with
  other players. They still show in your own Find list, tagged "BoP", with whisper and post
  disabled.
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
