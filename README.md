# CraftBoard

A World of Warcraft: Forever addon. A realm-wide crafting order board that runs entirely over
addon messages: crafters' recipe books are shared automatically, buyers search "who can make X",
and requests go out as a pre-filled whisper or an open board post. With nobody else installed it
still works as a personal crafting tool: what you can craft right now, what is missing, shopping list.

- Non-combat only. Unaffected by Forever's combat addon restrictions.
- No gold in the protocol. Tips are negotiated in whispers, nothing resembles an auction house or GDKP.
- Guild channel sync works with two people; the hidden realm channel lights up as more install it.

## Install (beta)
`tools/link.sh` symlinks `CraftBoard/` into the Forever beta AddOns folder. Or copy the folder to
`World of Warcraft/_classic_beta_/Interface/AddOns/CraftBoard`.

## Use
`/cb` opens the window. Open each profession window once so your recipes are recorded.
`/cb scan` forces a rescan, `/cb options` opens the settings, `/cb debug` shows sync status.

## Layout
- `CraftBoard/` the addon. Modules: Core, Locales, Options, Recipes, Inventory, Comm, UI. Design in `docs/SPEC.md`.
- `tools/check.sh` parses all Lua. `tools/link.sh` links into the game.
