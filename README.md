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
CraftBoard is a tab of the game's Professions window: the note icon under the profession tabs
on its right edge. The minimap button (left-click; right-click for settings, shift-click to
rescan, shift-right-click for busy), `/cb` and a key set under Key Bindings > AddOns > CraftBoard open the Professions window
on that tab. Before the Professions window has been opened in a session, in combat, for
characters without professions, or with "Open CraftBoard inside the Professions window" turned
off in the options, they open CraftBoard in its own window instead. The minimap button can be dragged around the minimap edge or hidden in
the options; it is also in the addon compartment. Open each profession window once so your
recipes are recorded (first-run tips on the window point the way). The window looks like the game's own
Professions window: Find lists every tradeable recipe on the board grouped by category, Requests
lists open posts and, under "Seen in chat", players asking for a crafter in Trade, General,
LookingForGroup, say or yell (guild chat too if turned on), so the tab is useful even when no one
else runs CraftBoard. A green check marks lines for a profession or recipe you have (or an alt's
recipe when you carry the mats; grey when only an alt knows it); Whisper opens
the chat box to that player with an offer typed in, Hide drops the line. Lines expire after 30
minutes and are never saved; "Watch chat for crafting requests" in the options turns it off.
Escape closes the Professions window as usual. `/cb scan` forces a rescan, `/cb options` opens the settings, `/cb debug`
shows sync status. `/cb busy` (or the "Available" switch on the board header) marks you busy:
other CraftBoard users see you greyed out and can't whisper you from the board. You are also busy
automatically in dungeons, raids and combat unless that option is off.

## Layout
- `CraftBoard/` the addon. Modules: Core, Locales, Options, Launcher, Recipes, Inventory, Comm, ChatWatch, UI, Onboarding, Welcome, Hooks, Embed. Design in `docs/SPEC.md`.
- `tools/check.sh` parses all Lua. `tools/link.sh` links into the game.
