-- CraftBoard Locales: NS.L["English text"] -> text for the client locale.
-- Keys are the enUS strings themselves; a missing key returns the key, so enUS needs no table
-- entries and an incomplete translation falls back to English per string.
-- Format strings keep their %s/%d placeholders in the same order; callers use string.format.
local ADDON, NS = ...

local L = setmetatable({}, { __index = function(_, key) return key end })
NS.L = L

-- enUS base: every key in use, so translators have the full list. Value = key.
local enUS = {
  -- Core: slash help and messages
  "/cb - toggle window",
  "/cb scan - rescan the open profession window",
  "/cb options - open the settings panel",
  "/cb debug - list known peers",
  "/cb help - this help",
  "UI not loaded",
  "scanned %d recipe(s)",
  "scan skipped: %s",
  "comm module not loaded",
  "%d peer(s)",
  "%s: %d recipes, %s",
  ", seen %dm ago",
  "online",
  "offline",

  -- Recipes: scan skip reasons, fallback name
  "profession API unavailable",
  "viewing someone else's profession",
  "profession data not ready",
  "profession data loading",
  "character not known yet",
  "no profession window open",
  "Recipe %d",

  -- Recipe groups for items without a Blizzard category (by equip slot)
  "Cloaks",
  "Helmets",
  "Chest",
  "Pants",
  "Boots",
  "Gloves",
  "Bracers",
  "Belts",
  "Shoulders",
  "Bags",

  -- Comm: whispers, posting, debug
  "[CraftBoard] Could you craft %dx %s for me? I have/can get the mats.",
  "item %d",
  "Please wait a few seconds before posting again.",
  "You already have %d open requests. Retract one first.",
  "AceComm-3.0 missing; sync disabled.",
  "channel %s: %s",
  "id %d",
  "not joined",
  " (disabled)",
  "guild: %s",
  " (sharing off)",
  "yes",
  "no",
  "peers: %d (%d online), open posts: %d",
  "last hello: %s (guild %s, channel %s), my hash %s",
  "%ds ago",
  "never",
  "missing comm libraries; sync disabled",

  -- UI
  "Find",
  "Requests",
  "Open a profession window to record your recipes.",
  "No one on the board yet \226\128\148 guildmates who install CraftBoard appear here.",
  "Item %s",
  "now",
  "%dm",
  "%dh",
  "you",
  "%d online",
  "%d known",
  "Other",
  "Whisper",
  "Retract",
  "Could not whisper %s.",
  "Select a recipe to see who can craft it.",
  "Qty",
  "Note",
  "Post request",
  "Posted request: %dx %s",
  "Post an open request to the board",
  "Guild and realm-channel CraftBoard users see it for 24h.",
  "This recipe makes no item to request",
  "No known crafters.",
  "No reagents recorded.",
  "Reagents unknown (peer recipe).",
  "No known crafter for \"%s\".",
  "%d recipes",
  "%d peers",
  "No open requests. Post one from the Find tab.",
  "[CraftBoard] I can craft %s for you.",
  "alt",
  "Click to whisper a request.",
  "Whisper %s",
  "Only you and your alts know this recipe.",
  "Offer",
  "channel ok",
  "channel off",
  "Search",
  "Filter",
  "All professions",
  "Right-click: %s",
  "Reagents:",
  "Crafters:",
  "%d/%d %s",
  "Missing:",
  "%d %s",
  "%d crafter online",
  "%d crafters online",
  "%d open request",
  "%d open requests",
  "No other crafters yet \194\183 invite your guild to install CraftBoard",
  "realm channel off",
  "Apprentice",
  "Journeyman",
  "Expert",
  "Artisan",
  "Master",
  "Grand Master",
  -- Requests tab
  "Open requests",
  "My requests",
  "No open requests",
  "Posts from other CraftBoard users appear here.",
  "No request matches \"%s\".",
  "Select a request to see its details.",
  "%dx",
  "Requested by %s",
  "just now",
  "%s ago",
  "Reagents unknown",
  "Requested quantity: %d",
  "Takes the request off the board for everyone.",
  -- Advertise (Find) and its channel names
  "Advertise",
  "Announce in chat",
  "Posts once in %s: %s",
  "LF crafter: %dx %s, have mats \226\128\148 whisper me (CraftBoard)",
  "Advertising is off in the CraftBoard options.",
  "Please wait %d seconds before advertising again.",
  "You are not in the %s channel here.",
  "Could not post in %s.",
  "General",
  "Trade",
  "Off",

  -- Options
  "Share recipes on the realm channel",
  "Announce your recipes and see other players' on the hidden realm-wide channel (CraftBoardF).",
  "Share recipes with my guild",
  "Announce your recipes and board posts to guildmates who use CraftBoard.",
  "Forget all peer data",
  "Forget",
  "Clears every known crafter and every board post, including your own. They come back as peers announce themselves again.",
  "Forgot all peer data.",
  "Settings panel not available.",
  "Can't open settings in combat.",
  "Open CraftBoard",
  "Advertise channel",
  "Advertise channel: %s",
  "Change",
  "Where the Advertise button in Find posts one line for players without CraftBoard. Trade chat exists in cities only. Nothing is ever sent without a click.",
  "Show minimap button",
  "Show the CraftBoard button on the minimap. Drag it around the minimap edge to move it.",
  "Show tips again",
  "Reset",
  "Shows the first-run tips on the CraftBoard window again.",

  -- Launcher: minimap button, key binding, welcome line
  "CraftBoard",
  "Toggle CraftBoard window",
  "Left-click: open \194\183 Right-click: settings",
  "CraftBoard loaded. Minimap button, /cb, or set a key in Key Bindings.",

  -- Onboarding: first-run tips
  "Open each of your profession windows once. CraftBoard records your recipes as you do.",
  "Your recipes are now shared with guildmates and realm players who run CraftBoard. Everyone on the board appears in Find.",
  "Post a request to the board, or whisper a crafter directly.",
  "Open Professions",
  "Tips will show again.",
}
for i = 1, #enUS do L[enUS[i]] = enUS[i] end

local locale = GetLocale and GetLocale() or "enUS"

--[[ deDE (stub: copy this block, uncomment, and translate the rest of the keys above)
if locale == "deDE" then
  L["Post request"] = "Anfrage posten"
  L["Share recipes with my guild"] = "Rezepte mit meiner Gilde teilen"
  L["%d online"] = "%d online"
end
--]]
