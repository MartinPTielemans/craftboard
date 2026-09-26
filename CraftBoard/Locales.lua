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
  "Mine",
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
  "Crafters",
  "Reagents",
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
  "x%d",
  "%d short",
  "Shopping list",
  "Select a recipe to see what you're short on.",
  "You have everything for %dx.",
  "%d reagent(s) short",
  "Nothing craftable from your bags and bank right now.",
  "No open requests. Post one from the Find tab.",
  "[CraftBoard] I can craft %s for you.",
  "Type to search",
  "All",
  "alt",
  "Click to whisper a request.",
  "Whisper %s",
  "Only you and your alts know this recipe.",
  "Short on",
  "Also list recipes you're missing reagents for.",
  "Offer",
  "%s wants %dx %s",
  "You want %dx %s",
  "channel ok",
  "channel off",

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
