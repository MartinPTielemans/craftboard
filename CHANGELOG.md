# Changelog

All notable changes to CraftBoard are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
