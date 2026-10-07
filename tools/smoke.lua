-- Smoke test: loads every CraftBoard file in TOC order against stubbed WoW APIs, then checks the
-- behaviour that can be checked outside the game (chat detection, names and identity, queue and
-- crafting counts, cooldowns, tooltips, merchant plan, locales). Nothing here draws a frame.
-- Usage (repo root): lua tools/smoke.lua [locale]    -- exits 1 on any failure
local LOCALE = arg and arg[1] or "enUS"

-- Stubs ----------------------------------------------------------------------------
-- Anything not defined below is a harmless callable table, so optional client APIs look present
-- but do nothing. Frames are tables whose every method is a no-op returning nil.
local Stub
Stub = setmetatable({}, { __index = function() return Stub end, __call = function() return nil end })
setmetatable(_G, { __index = function() return Stub end })

local frames, timers = {}, {}
local drawn = false            -- frames report shown/visible once the UI walk starts (end of file)
local function noop() end
-- Child regions templates would create (data fields, not methods): absent on stub frames.
-- CraftBoard's own fields start lowercase ("cb...", "stripe"): unset ones read as nil too.
local FIELDS = {}
for f in ("clearButton ClearButton searchIcon SearchIcon Instructions Left Right Middle Mid NineSlice Bg Inset "
  .. "TitleContainer PortraitContainer Text Background ScrollBar TitleText TopTileStreaks Icon ScrollBox Label "
  .. "DecrementButton IncrementButton Arrow Border"):gmatch("%S+") do FIELDS[f] = true end
local FrameMT = { __index = function(t, k)
  if FIELDS[k] or k:match("^%l") then return nil end
  if k == "GetFontString" then return function(self) return self end end
  if k == "GetScript" then return function(self, name) return rawget(self, "_scripts")[name] end end
  if k == "SetScript" or k == "HookScript" then
    return function(self, name, fn) rawget(self, "_scripts")[name] = fn end
  end
  if k == "CreateFontString" or k == "CreateTexture" or k == "CreateMaskTexture" or k == "CreateAnimationGroup" then
    return function() return CreateFrame() end
  end
  if k == "GetText" then return function(self) return rawget(self, "_text") or "" end end
  if k == "SetText" then return function(self, v) rawset(self, "_text", v) end end
  if k == "GetWidth" or k == "GetHeight" or k == "GetStringWidth" or k == "GetStringHeight" or k == "GetFrameLevel"
    or k == "GetUnboundedStringWidth" or k == "GetVerticalScroll" or k == "GetTop" or k == "GetBottom"
    or k == "GetLeft" or k == "GetRight" or k == "GetScale" or k == "GetEffectiveScale" then
    return function() return 0 end
  end
  if k == "GetPoint" then return function() return "CENTER", nil, "CENTER", 0, 0 end end
  if k == "IsShown" or k == "IsVisible" or k == "IsEnabled" then return function() return drawn end end
  return noop
end }
function CreateFrame()
  local f = setmetatable({ _scripts = {} }, FrameMT)
  frames[#frames + 1] = f
  return f
end

-- The clock can be moved on (clock.skip) past the addon's rate limits.
local clock = { skip = 0 }
time = function(t) if t then return os.time(t) end return os.time() + clock.skip end
GetTime = os.clock
GetBuildInfo = function() return "", "", "", 16001 end
GetLocale = function() return LOCALE end
GetNormalizedRealmName = function() return "Forever" end
GetRealmName = function() return "Forever" end
UnitName = function(u)
  if u == "player" then return "Raion", "Lyzl" end
  if u == "party1" then return "Lollo", "Causto" end
  return nil
end
UnitLevel = function() return 20 end
issecretvalue = nil
InCombatLockdown = function() return false end
strlower, strupper = string.lower, string.upper
strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
strsplit = function(_, s) return s:match("^(%S*)%s*(.-)$") end
Ambiguate = function(n) return (n:gsub("%-Forever$", "")) end
tinsert, tremove = table.insert, table.remove
C_Timer = { After = function(_, f) timers[#timers + 1] = f end, NewTicker = function() end }
LibStub = setmetatable({}, { __call = function() return nil end })
C_FriendList = { IsIgnored = function(n) return n == "Troll" end }
IsInGroup = function() return false end
C_TradeSkillUI = nil
C_Spell = { GetSpellName = function(id) return id == 17187 and "Transmute: Arcanite" or nil end,
  GetSpellCooldown = function() return { startTime = 0, duration = 0 } end }
ITEM_MIN_SKILL = "Requires %s (%d)"
-- Blizzard's load-on-demand windows aren't loaded yet (false, so the catch-all stub doesn't fake them).
for _, name in ipairs({ "ProfessionsFrame", "ProfessionsBookFrame", "SpellBookProfessionFrame", "SpellBookFrame",
  "PrimaryProfession1", "TradeFrame", "MerchantFrame", "GameTooltip", "ItemRefTooltip", "TooltipDataProcessor",
  "DEFAULT_CHAT_FRAME", "Settings", "InterfaceOptions_AddCategory" }) do
  rawset(_G, name, false)
end
CraftBoardDB = {}

local function fire(event, ...)
  for _, f in ipairs(frames) do
    local h = f._scripts.OnEvent
    if h then h(f, event, ...) end
  end
end
local function runTimers()
  for _ = 1, 5 do
    local list = timers
    timers = {}
    if #list == 0 then return end
    for _, f in ipairs(list) do pcall(f) end
  end
end

-- Checks ---------------------------------------------------------------------------
local failures, passed = 0, 0
local function check(cond, what)
  if cond then passed = passed + 1 else failures = failures + 1; print("FAIL " .. what) end
end
local function eq(got, want, what)
  check(got == want, string.format("%s: got %s, want %s", what, tostring(got), tostring(want)))
end

-- Load -----------------------------------------------------------------------------
local NS = {}
for line in io.lines("CraftBoard/CraftBoard.toc") do
  local file = line:match("^([%w_]+%.lua)%s*$")
  if file then
    local chunk, err = loadfile("CraftBoard/" .. file)
    check(chunk ~= nil, "parse " .. file .. ": " .. tostring(err))
    if chunk then
      local ok, e = pcall(chunk, "CraftBoard", NS)
      check(ok, "load " .. file .. ": " .. tostring(e))
    end
  end
end

-- Printing goes to a list so tests can look at chat lines.
local printed = {}
NS.Print = function(m) printed[#printed + 1] = tostring(m) end

fire("ADDON_LOADED", "CraftBoard")
local db = CraftBoardDB
-- An older version keyed this character by first name only; login migrates it.
db.chars["Raion-Forever"] = { recipes = {}, profs = {}, busy = true }
db.posts["Raion-Forever:9:1"] = { id = "Raion-Forever:9:1", from = "Raion-Forever", item = 1, qty = 1, t = time(), mine = true }
-- Another player's cached post under the same first-name-only key (they share my first name).
db.posts["other:1"] = { id = "other:1", from = "Raion-Forever", item = 1, qty = 1, t = time() }
fire("PLAYER_LOGIN")

-- Identity and names
eq(NS.Me, "Raion Lyzl-Forever", "NS.Me has the surname")
check(db.chars["Raion-Forever"] == nil and db.chars[NS.Me].busy == true, "legacy character data migrated")
eq(db.posts["Raion-Forever:9:1"].from, NS.Me, "my old post migrated")
eq(db.posts["other:1"].from, "Raion-Forever", "another player's post under the old key stays theirs")
db.posts["other:1"] = nil
check(NS.IsMe("Raion Lyzl-Forever") and NS.IsMe("Raion-Forever"), "IsMe: full and first-name-only")
check(not NS.IsMe("Raion Other-Forever"), "IsMe: a namesake is not me")
check(not NS.SamePlayer("Lollo Causto-Forever", "Lollo Other-Forever"), "SamePlayer: different surnames")
eq(NS.UnitFullName("party1"), "Lollo Causto-Forever", "UnitFullName joins the surname")

-- Recipes and inventory fixtures
local me = db.chars[NS.Me]
me.profs[165] = { "Leatherworking", 87, 150 }
me.recipes[2152] = { p = 165, n = "Light Armor Kit", o = 2304, r = { { 2318, 1 } }, d = 0 }
me.recipes[7443] = { p = 333, n = "Enchant Chest - Minor Mana", e = true, r = { { 10940, 1 } } }
db.recipeNames[2152] = { n = "Light Armor Kit", o = 2304, p = 165 }
-- A peer's recipe (resolved through the shared catalogue): its output (test item 1) counts as a
-- crafted item in chat.
db.recipeNames[18560] = { n = "Mooncloth", o = 1, p = 197 }
db.peers["Tailor Peer-Forever"] = { recipes = { [18560] = true }, profs = {}, seen = time() }
local names = { [2304] = "Light Armor Kit", [2318] = "Light Leather", [2320] = "Coarse Thread" }
NS.Inventory.Count = function(id) return id == 2318 and 1 or 0 end
NS.Inventory.ItemName = function(id) return names[id] end
db.chars["Bankalt-Forever"] = { recipes = {}, profs = {}, items = { [2318] = 12 } }

-- Chat detection
local CW = NS.ChatWatch
eq(CW.Clean("lf |cnIQ1:|Hitem:2318::|h[Light Leather]|h|r x1"), "lf [Light Leather] x1", "named colour codes stripped")
local hit = CW.Detect("LF 5x |Hitem:1:|h[Mooncloth]|h have mats")
check(hit and hit.itemName == "Mooncloth" and hit.qty == 5 and hit.mats, "detect item, quantity, mats")
check(not (CW.Detect("LF |Hitem:1:|h[Mooncloth]|h, don't have mats") or {}).mats, "negated mats")
check(CW.Detect("WTS [Mooncloth] pst") == nil, "offers are not requests")
eq(CW.Topic({ text = "any enchanter have head enchant?" }), "head enchant", "topic of a profession ask")
check(not CW.AddsDetail({ text = "lf [Light Leather] x1" }), "bare ask adds nothing to the title")
CW.Add("lf |Hitem:2304::|h[Light Armor Kit]|h have mats", "Lollo Causto", "Trade")
CW.Add("lf |Hitem:2304::|h[Light Armor Kit]|h have mats", "Lollo Causto", "Trade")
CW.Add("LF enchanter chest mana pls", "Troll", "Trade")
CW.Add("LF lw pls", "Raion Lyzl", "Trade")
local seen = CW.Seen()
eq(#seen, 1, "one row: repeat ask merged, ignored player and my own line skipped")
eq(seen[1] and seen[1].asks, 2, "repeat ask counted")
eq(seen[1] and seen[1].recipeID, 2152, "ask resolved to my recipe")
eq(seen[1] and seen[1].itemID, 2304, "the linked item's id is kept")

-- Detector precision and recall (lines verified in real chat)
local KIT = "|Hitem:2304::|h[Light Armor Kit]|h"
check(CW.Detect("can anyone make " .. KIT .. "?") ~= nil, "'can anyone make [X]?' is an ask")
check(CW.Detect("who can craft " .. KIT .. "?") ~= nil, "'who can craft [X]?' is an ask")
eq(select(2, CW.Detect("I can craft " .. KIT .. " pst")), "offer", "'I can craft [X]' is an offer")
eq(select(2, CW.Detect("LF LW customers, have all patterns")), "offer", "a crafter looking for customers is not a request")
eq(select(2, CW.Detect("<Guild> recruiting LW BS ench")), "skip", "guild recruitment is not a request")
check(CW.Detect("LF guild eng speaking") == nil, "'eng speaking' is not Engineering")
check(CW.Detect("LF enchanter, anyone in guild?", true) ~= nil, "'guild' in guild chat is not an advert")
check(CW.Detect("WTB |Hitem:2589::|h[Linen Cloth]|h x20") == nil, "shopping for an item nobody crafts is not a request")
hit = CW.Detect("WTB " .. KIT .. " x20")
check(hit and hit.itemID == 2304 and hit.qty == 20, "an item someone crafts is, with its id and quantity")
hit = CW.Detect("need enchanter")
eq(hit and hit.prof, "Enchanting", "'need enchanter' asks for Enchanting")
eq((CW.Detect("tailor wanted") or {}).prof, "Tailoring", "'<profession> wanted' is an ask")
eq((CW.Detect("LF someone to enchant my bracers") or {}).prof, "Enchanting", "'enchant' names Enchanting")
eq((CW.Detect("LF 3 " .. KIT) or {}).qty, 3, "quantity right before a link")
check((CW.Detect("LF lw for " .. KIT .. ", bring my mats") or {}).mats, "'bring my mats' brings the reagents")

-- CanHelp: an ask naming an item needs the current character's recipe, not just the profession
check(not CW.CanHelp({ itemName = "Mooncloth", prof = "Leatherworking", profID = 165 }), "item ask: profession isn't enough")
check(not CW.CanHelp({ itemName = "Light Armor Kit", recipeID = 2152, current = false, knownOn = "Bankalt-Forever" }),
  "item ask: an alt's recipe isn't the current character's")
check(CW.CanHelp({ itemName = "Light Armor Kit", recipeID = 2152, current = true }), "item ask: my recipe")
check(CW.CanHelp({ prof = "Leatherworking", profID = 165 }), "profession ask: my profession")
eq(CW.ProfName({ prof = "Leatherworking", profID = 165 }), "Leatherworking", "profession name from my records")
eq(CW.ProfName({ prof = "Enchanting", profID = 333 }), "Enchanting", "profession name falls back to the detector's")

-- Topic and detail: payment words and prices are noise, plain numbers are not
eq(CW.Topic({ text = "LF ench 15 agi 2h will pay 5g" }), "15 agi 2h", "topic keeps '15 agi 2h'")
eq(CW.Topic({ text = "LF ench 2h will pay 5g asap" }), "2h", "topic drops 'will pay 5g asap'")
eq(CW.Topic({ text = "LF 4x ench 2h", qty = 4 }), "2h", "topic drops the quantity")
check(not CW.AddsDetail({ text = "LF [Light Armor Kit] have mats, will tip 5g" }), "mats and tips add nothing to the title")
check(CW.AddsDetail({ text = "LF [Light Armor Kit] before raid tonight" }), "a deadline adds detail")

-- Stale rows: a later line updates the reagents or drops the row
local function row(from)
  for _, s in ipairs(CW.Seen()) do
    if s.from == from then return s end
  end
end
CW.Add("LF 2x " .. KIT .. " dont have mats", "Mira Vale", "Trade")
check(row("Mira Vale-Forever") and not row("Mira Vale-Forever").mats, "negated mats on the row")
CW.Add("oh wait, I have mats", "Mira Vale", "Trade")
check((row("Mira Vale-Forever") or {}).mats, "a later 'have mats' line updates the row")
CW.Add("LF " .. KIT .. " pls", "Mira Vale", "Trade")
local mira = row("Mira Vale-Forever") or {}
check(mira.mats and mira.qty == 2 and mira.asks == 2, "asking again keeps the reagents and the quantity")
CW.Add("LF " .. KIT .. ", don't have mats", "Mira Vale", "Trade")
check(not (row("Mira Vale-Forever") or {}).mats, "a new line's negation wins")
check(CW.Add("nvm found one", "Mira Vale", "Trade") == nil and row("Mira Vale-Forever") == nil, "'nvm found one' drops the row")
check(CW.Add("nvm, LF lw", "Mira Vale", "Trade") ~= nil, "an ask after an opening 'nvm' is a new ask")
CW.Add("LF " .. KIT .. " pls", "Mira Vale", "Trade")
check(CW.Add("LF " .. KIT .. ", nvm found one", "Mira Vale", "Trade") == nil and row("Mira Vale-Forever") == nil,
  "an ask that ends in 'nvm found one' is called off")
check(CW.Add("LF " .. KIT .. " nvm, need enchanter", "Mira Vale", "Trade") ~= nil, "an ask after 'nvm' in the line stands")
local swap = CW.Add("don't need tailor, need enchanter", "Mira Vale", "Trade")
check(swap ~= nil and swap.profID == 333, "a new ask after a call-off is read from its own words")

-- Channel labels (non-ASCII channel names, the client's chat type names) and the tuning log
EnumerateServerChannels = function() return "Général", "Commerce" end
fire("CHAT_MSG_CHANNEL", "LF lw pls", "Nora Pell", "", "1. Général - Elwynn", "", "", 1, 1, "Général - Elwynn")
eq((row("Nora Pell-Forever") or {}).channel, "Général", "channel label keeps non-ASCII letters")
check(db.chatlog == nil, "chat lines are not saved by default")
SAY = "Say (client)"
fire("CHAT_MSG_SAY", "LF lw pls", "Otto Lind")
eq((row("Otto Lind-Forever") or {}).channel, "Say (client)", "say label from the client's SAY")
CW.SetLogging(true)
fire("CHAT_MSG_CHANNEL", "WTS stuff", "Nora Pell", "", "1. Général - Elwynn", "", "", 1, 1, "Général - Elwynn")
check(type(db.chatlog) == "table" and #db.chatlog == 1, "tuning log only while turned on")
CW.SetLogging(false)
check(db.chatlog == nil and not db.chatlogOn, "turning the log off drops it")

-- Board posts and the ignore list
db.posts["Bob-Forever:1:1"] = { id = "Bob-Forever:1:1", from = "Bob-Forever", item = 2304, qty = 2, t = time() }
db.posts["Troll-Forever:1:1"] = { id = "Troll-Forever:1:1", from = "Troll-Forever", item = 2304, qty = 1, t = time() }
-- Bob is online (heard from just now): only online authors' posts count.
db.peers["Bob-Forever"] = { recipes = {}, profs = {}, seen = time() }
local visible = {}
for _, p in ipairs(NS.Comm.Requests()) do visible[p.from] = true end
check(visible["Bob-Forever"] and not visible["Troll-Forever"], "ignored player's post hidden")
check((NS.UI.RequestCount() or 0) >= 2, "requests I can craft are counted")

-- Online state: heard from recently, or the friend list (first-name-only entries too)
local C = NS.Comm
check(C.IsOnline("Bob-Forever") and C.IsOnline(NS.Me) and not C.IsOnline("Cara-Forever"), "IsOnline from peers")
C_FriendList.GetNumFriends = function() return 1 end
C_FriendList.GetFriendInfoByIndex = function() return { name = "Dana", connected = true } end
fire("FRIENDLIST_UPDATE")
check(C.IsOnline("Dana Moor-Forever"), "IsOnline from a friend listed by first name")

-- Posting: open slots for linked orders, notes without prices
local slots = C.OpenSlots()
local pid = C.PostRequest(2304, 1, "will tip 5g, pay 10 gold (1.5g)")
eq(pid and db.posts[pid].note, "will tip, pay", "prices stripped from the note")
local cid = pid and C.PostRequest(2318, 2, "", pid)
check(cid and db.posts[cid].note == "" and db.posts[cid].pa == pid, "linked order without a note")
eq(C.OpenSlots(), slots - 2, "open slots count my posts")

-- Who can craft this (W / A): the question's text, and my recipes that answer it
eq(C.QueryText("  LF Light   |cff00ff00Armor|r "), "lf light armor", "question text: plain, lower case, one space")
eq(C.QueryText("a"), nil, "question text: too short to ask")
eq(C.QueryText("ax"), "ax", "two letters are a question, as in Find")
local m = C.MatchQuery("armor kit", nil)
check(#m == 1 and m[1][1] == 2152 and m[1][3] == 2304, "a question matches my recipe by name")
m = C.MatchQuery(nil, { 2304 })
check(#m == 1 and m[1][1] == 2152, "a question matches my recipe by its output item")
eq(#C.MatchQuery("mooncloth", { 9999 }), 0, "a peer's recipe isn't mine to answer")
m = C.MatchQuery("light kit", nil)
check(#m == 1 and m[1][1] == 2152, "a question matches word by word, as Find does")
m = C.MatchQuery("enchant", { 2304 })
check(#m == 2 and m[1][1] == 2152, "the item asked for by ID leads the answer")

-- Marks: pins and the wishlist (a wished item, or the recipe item named after it, linked in chat)
local M = NS.Marks
M.TogglePin(2152)
check(M.IsPinned(2152) and M.AnyPinned(), "recipe pinned")
M.TogglePin(2152)
check(not M.IsPinned(2152), "recipe unpinned")
M.SetWished(2304, true)
eq((M.WishedIn("WTS |Hitem:2304::|h[Light Armor Kit]|h")), 2304, "a wished item linked")
local wished, linked = M.WishedIn("WTS |Hitem:9999::|h[Pattern: Light Armor Kit]|h cheap")
check(wished == 2304 and linked == 9999, "the recipe item for a wished item")
check(M.WishedIn("WTS |Hitem:2318::|h[Light Leather]|h") == nil, "an item not on the wishlist")
printed = {}
M.CheckChat("WTS |Hitem:2304::|h[Light Armor Kit]|h", "Nora Pell", "Trade")
M.CheckChat("WTS |Hitem:2304::|h[Light Armor Kit]|h again", "Nora Pell", "Trade")
check(#printed == 1 and printed[1]:find("Nora Pell", 1, true) ~= nil, "one wishlist line per item and player")
check(M.RemoveWish("light armor") and not M.IsWished(2304), "/cb wish remove by part of the name")

-- Old requests: one nudge near the end of the day, and Renew posts it (and its linked order) again
do
  local old = db.posts[pid]
  old.t = time() - C.POST_TTL + 3600
  printed = {}
  C.NudgeOld()
  C.NudgeOld()
  check(#printed == 1, "one nudge for a request about to expire")
  check(C.Renew(pid) == nil and db.posts[pid] ~= nil, "Renew waits out the gap between posts, keeping the request")
  clock.skip = clock.skip + 11
  local nid = C.Renew(pid)
  check(nid and nid ~= pid and db.posts[pid] == nil and db.posts[nid].qty == old.qty, "renewed as a new post")
  local kids = C.Linked(nid)
  check(#kids == 1 and kids[1].item == 2318, "its linked order went up with it")
  pid = nid
  -- A linked order of the linked order goes up with them too.
  C.PostRequest(2320, 3, "", kids[1].id)
  clock.skip = clock.skip + 11
  nid = C.Renew(pid)
  local k1 = nid and C.Linked(nid) or {}
  local k2 = k1[1] and C.Linked(k1[1].id) or {}
  check(#k1 == 1 and #k2 == 1 and k2[1].item == 2320, "renewed with its whole chain")
  pid = nid
end

-- Whisper texts: the built-in wording until the player saves their own
do
  local T = NS.Templates
  local builtin = T.Request("[Kit]", 3)
  check(builtin:find("[Kit]", 1, true) and builtin:find("3", 1, true), "built-in request text has the item and quantity")
  eq(T.Get("request"):find("{qty}", 1, true) ~= nil and T.Get("request"):find("{item}", 1, true) ~= nil, true,
    "the default as a template")
  T.Set("offer", "hey, I can do {qty}x {item} (50% done)")
  eq(T.Offer("[Kit]", 2), "hey, I can do 2x [Kit] (50% done)", "own offer text filled in")
  T.Set("offer", string.rep("a", 199) .. "\195\169")
  eq(#db.templates.offer, 199, "an own text is cut on a character boundary")
  T.Set("offer", string.rep("b", 190) .. " {item}")
  local long = T.Offer("|cff1eff00|Hitem:2304::|h[Light Armor Kit]|h|r", 1)
  check(#long <= 255 and long:find("[Light Armor Kit]", 1, true) ~= nil, "an expanded text fits one message, plain name instead of the link")
  T.Set("offer", T.Default("offer"))
  check(db.templates.offer == nil, "saving the default goes back to the built-in text")
end

-- Back online: a player link, no "1x", and which character knows the recipe
printed = {}
C.NoteBackOnline("Bob-Forever")
local line = printed[1] or ""
check(line:find("|Hplayer:Bob-Forever|h[Bob]|h", 1, true) and line:find("2x", 1, true), "back-online line: link and quantity")
names[4305] = "Bolt of Silk"
db.chars["Bankalt-Forever"].recipes[3914] = { p = 197, n = "Bolt of Silk Cloth", o = 4305, r = { { 4306, 4 } } }
db.posts["Cara-Forever:1:1"] = { id = "Cara-Forever:1:1", from = "Cara-Forever", item = 4305, qty = 1, t = time() }
C.NoteBackOnline("Cara-Forever")
line = printed[2] or ""
check(line:find("[Cara]", 1, true) and line:find("Bankalt", 1, true) and not line:find("1x", 1, true),
  "back-online line: alt's recipe, quantity 1 left out")
db.chars["Bankalt-Forever"].recipes[3914] = nil
db.posts["Cara-Forever:1:1"] = nil

-- Queue: items vs crafts, carry-over, yield, made counts
local Q = NS.Queue
Q.Add({ recipeID = 2152, item = 2304, qty = 2, who = "Bob-Forever", src = "a" })
Q.Add({ recipeID = 2152, item = 2304, qty = 3, who = "Bob-Forever", src = "b" })
Q.Delivered("Bob-Forever", 2304, nil, 4)
local entries = Q.Entries()
check(#entries == 1 and entries[1].qty == 1, "delivery carries over to the next row")
Q.Delivered("Bob-Forever", 2304, nil, 1)
eq(#Q.Entries(), 0, "fully delivered queue is empty")
-- Queue totals: slots accepting the same tiers add up; a stack two rows could use counts once.
do
  local count = NS.Inventory.Count
  NS.Inventory.Count = function(id) return id == 5001 and 4 or 0 end
  local t = NS.Inventory.Totals({
    { record = { r = { { 5001, 3, alts = { 5002 } } } }, qty = 1 },
    { record = { r = { { 5002, 3, alts = { 5001 } } } }, qty = 1 },
  })
  check(#t == 1 and t[1].need == 6 and t[1].have == 4, "the same tiers in any order are one row")
  t = NS.Inventory.Totals({
    { record = { r = { { 5001, 3 } } }, qty = 1 },
    { record = { r = { { 5001, 3, alts = { 5002 } } } }, qty = 1 },
  })
  check(#t == 2 and t[1].have == 3 and t[2].have == 1, "overlapping tiers share the stack")
  -- {b,a} and {b,c} with one a and one b: both covered, whichever row comes first.
  NS.Inventory.Count = function(id) return (id == 5001 or id == 5002) and 1 or 0 end
  t = NS.Inventory.Totals({
    { record = { r = { { 5002, 1, alts = { 5001 } } } }, qty = 1 },
    { record = { r = { { 5002, 1, alts = { 5003 } } } }, qty = 1 },
  })
  check(#t == 2 and t[1].have >= 1 and t[2].have >= 1, "a row switches tiers so another row is covered")
  NS.Inventory.Count = count
end

-- Buy missing: two short slots that the same sold tier fills buy it for both.
do
  local totals = NS.Queue.Totals
  NS.Queue.Totals = function()
    return { { itemID = 6001, alts = { 6002 }, need = 3, have = 0 }, { itemID = 6003, alts = { 6002 }, need = 2, have = 0 } }
  end
  GetMerchantNumItems = function() return 1 end
  GetMerchantItemID = function() return 6002 end
  GetMerchantItemInfo = function() return "x", nil, 10, 1, -1, true, nil, false end
  GetMoney = function() return 100000 end
  local plan, _, info = NS.Merchant.Plan()
  check(#plan == 1 and plan[1].count == 5 and #info.notSold == 0, "a sold tier covers every slot it fits")
  -- Limited stock (7 items) sold in bundles of 5: one bundle, not seven.
  GetMerchantItemInfo = function() return "x", nil, 10, 5, 7, true, nil, false end
  plan = NS.Merchant.Plan()
  check(#plan == 1 and plan[1].count == 5, "limited stock caps the bundles by the items in stock")
  -- {b,a} and {b,c} short one each, one b in stock, a and c unlimited: both slots get bought.
  NS.Queue.Totals = function()
    return { { itemID = 6102, alts = { 6101 }, need = 1, have = 0 }, { itemID = 6102, alts = { 6103 }, need = 1, have = 0 } }
  end
  local sold = { 6102, 6101, 6103 }
  GetMerchantNumItems = function() return #sold end
  GetMerchantItemID = function(i) return sold[i] end
  GetMerchantItemInfo = function(i) return "x", nil, 10, 1, i == 1 and 1 or -1, true, nil, false end
  plan = NS.Merchant.Plan()
  local items = 0
  for _, e in ipairs(plan) do items = items + e.count end
  check(items == 2 and #plan == 2, "a slot moves to another tier when a limited one runs out")
  -- Its own item costs more than I have; another accepted tier is affordable: that one is bought.
  NS.Queue.Totals = function() return { { itemID = 6201, alts = { 6202 }, need = 2, have = 0 } } end
  sold = { 6201, 6202 }
  GetMerchantItemInfo = function(i) return "x", nil, i == 1 and 1000000 or 10, 1, -1, true, nil, false end
  plan = NS.Merchant.Plan()
  check(#plan == 1 and plan[1].itemID == 6202 and plan[1].count == 2, "an unaffordable tier gives way to an affordable one")
  NS.Queue.Totals = totals
  GetMerchantNumItems, GetMerchantItemID, GetMerchantItemInfo, GetMoney = nil, nil, nil, nil
end

-- Queued from a chat ask, then posted to the board: the queued craft moves to the post.
do
  local c = Q.Add({ recipeID = 2152, item = 2304, qty = 1, who = "Bob-Forever", src = "chat:Bob-Forever:Light Armor Kit" })
  Q.Adopt("Bob-Forever", 2304, "post:bob:1")
  check(Q.Has("post:bob:1") and Q.Has("chat:Bob-Forever:Light Armor Kit") and Q.Get("post:bob:1") == c,
    "a posted chat ask keeps its queued craft (the chat ask still points at it)")
  -- That post is gone and they post again: the craft moves to the new post (never from a live one),
  -- taking the post's quantity while nothing is made yet.
  Q.Adopt("Bob-Forever", 2304, "post:bob:2", 5)
  check(Q.Get("post:bob:2") == c and Q.Has("chat:Bob-Forever:Light Armor Kit") and c.qty == 5,
    "a repost takes the queued craft over, with its quantity")
  -- Two handed over already: a later post doesn't bring the delivered ones back.
  Q.Delivered("Bob-Forever", 2304, nil, 2)
  db.posts["post:bob:2"] = nil
  Q.Adopt("Bob-Forever", 2304, "post:bob:3", 5)
  check(Q.Get("post:bob:3") == c and c.qty == 3, "adoption keeps what was handed over")
  -- Made already, then posted with a bigger total: the rest is owed too, the made one stays made.
  c.madeItems = 1
  db.posts["post:bob:3"] = nil
  Q.Adopt("Bob-Forever", 2304, "post:bob:4", 7)
  check(Q.Get("post:bob:4") == c and c.qty == 5 and Q.MadeItems(c) == 1, "a bigger post total reaches a started craft")
  Q.Remove(c.id)
end
-- They take back "have mats": the queued craft needs the reagents again.
do
  local m = Q.Add({ recipeID = 2152, item = 2304, qty = 1, who = "Bob-Forever", src = "mats", mats = true })
  Q.SetMats(m, false)
  check(m.mats == nil and Q.Totals(true)[1] ~= nil, "a queued craft follows a change of mats")
  Q.Remove(m.id)
end
-- Two of my recipes make the same item: a request uses the one my bags allow.
me.recipes[8801] = { p = 165, n = "Kit (rare hide)", o = 8800, r = { { 2320, 1 } } }
me.recipes[8802] = { p = 165, n = "Kit (leather)", o = 8800, r = { { 2318, 1 } } }
eq((NS.Inventory.RecipeToUse(8800, 1)), 8802, "the craftable one of two recipes for an item")
eq((NS.Inventory.RecipeToUse(8800, 5)), 8801, "none craftable: the lowest recipe ID")
me.recipes[8801], me.recipes[8802] = nil, nil
local arrows = { p = 202, o = 999, y = 200, r = { { 2318, 1 } } }
eq(NS.Inventory.CanCraft(arrows, 200).reagents[1].need, 1, "yield: 200 items is one craft")
eq(NS.Inventory.CanCraft(arrows, 201).reagents[1].need, 2, "yield rounds up")
me.recipes[2152].y = 2
local x = Q.Add({ recipeID = 2152, item = 2304, qty = 4, src = "plan:2152" })
eq(Q.CraftsLeft(x, me.recipes[2152]), 2, "crafts left use the yield")
Q.Crafted(2152, me.recipes[2152])
Q.Crafted(2152, me.recipes[2152])
check(not Q.Has("plan:2152"), "planned entry done when fully made")
me.recipes[2152].y = nil

-- Alts
local total, list = NS.Inventory.AltCounts(2318)
check(total == 12 and list[1] and list[1].name == "Bankalt-Forever", "alt counts")
check(NS.Inventory.AltText(2318) ~= nil, "alt text")
eq((NS.Inventory.AltCounts(9999, { 2318 })), 12, "alt counts add the slot's other quality tiers")

-- Cooldowns
me.recipes[17187] = { p = 171, n = "Transmute: Arcanite", o = 12360, r = {} }
check(NS.Cooldowns.Is(17187, me.recipes[17187]), "transmute is a cooldown craft")
NS.Cooldowns.Update()
local h = NS.Cooldowns.ForHello(16)
check(h and h[17187] == 0, "ready cooldown goes out in the hello")

-- Tooltips
if NS.Tooltips and NS.Tooltips.ItemLines then
  local lines = NS.Tooltips.ItemLines(2318, {})
  check(type(lines) == "table" and #lines >= 1, "reagent tooltip lines")
end

-- Crafting without a profession window open
local ok, why = NS.Craft.CanCraft(2152)
check(not ok and type(why) == "string", "Craft explains why it can't")

-- A recipe learned marks its profession until the next scan
fire("NEW_RECIPE_LEARNED", 2152)
check(me.profs[165].newRecipes == true, "new recipe flags its profession")
check(NS.Recipes.Search("armor kit")[1] ~= nil, "search finds my recipe")

-- Crafting history: casts of my recipes count, lifetime and this session
do
  local before = NS.Stats.Made(2152)
  fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 2152)
  fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 99999)
  eq(NS.Stats.Made(2152), before + 1, "a cast of my recipe is counted")
  eq(NS.Stats.SessionMade(2152), 1, "and counted for this session")
  eq(NS.Stats.Made(99999), 0, "a spell that isn't a recipe of mine is not")
  me.made = me.made or {}
  me.made[2304] = time() - 100   -- Craft.lua's recent-craft time for the item
  fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 2152)
  eq(NS.Stats.Made(2152), before + 2, "lifetime counts aren't mixed with recent-craft times")
end

-- Specializations: read from the spellbook, sent as spell IDs, read back to known ones only
do
  IsPlayerSpell = function(id) return id == 10656 end
  NS.Skills.ReadSpecs()
  check(me.specs and me.specs[10656] and not me.specs[10658], "specialization read from the spellbook")
  local sp = C.MySpecs()
  check(sp and #sp == 1 and sp[1] == 10656, "the hello carries it")
  local got = C.ReadSpecs({ 10656, 123, "x", 20219 })
  check(got and got[10656] and got[20219] and not got[123], "unknown spell IDs are dropped")
  eq(NS.Skills.SpecFor(got, 165), "Dragonscale Leatherworking", "the specialization of a profession")
  eq(NS.Skills.SpecFor({ [9787] = true, [17039] = true }, 164), "Master Swordsmith", "a master smith over Weaponsmith")
  local card = NS.UI and NS.UI.CrafterCardText and NS.UI.CrafterCardText({ name = NS.Me, mine = true }) or ""
  check(card:find("Dragonscale", 1, true) ~= nil, "my crafter card names it")
end

-- Where recipes are learned: the first source heard is kept
do
  local R = NS.Recipes
  R.SetSource(18560, 1)
  R.SetSource(18560, 14468)
  eq(R.SourceOf(18560), 1, "first recipe source kept")
  check(R.GuessSource() == nil, "no trainer, no recipe item used: no source")
end

-- Demand: one ask per player, item and day; counts only
do
  local S = NS.Stats
  S.NoteDemand(4305, "Ann Lee-Forever")
  S.NoteDemand(4305, "Ann Lee-Forever")
  S.NoteDemand(4305, "Bo Rin-Forever")
  S.NoteDemand(4305, NS.Me)
  eq(S.Demand(4305), 2, "asks counted once per player and day, mine left out")
  CW.Add("WTB |Hitem:2304::|h[Light Armor Kit]|h and |Hitem:1::|h[Mooncloth]|h", "Cy Ward", "Trade")
  check(S.Demand(2304) >= 1 and S.Demand(1) >= 1, "every crafted item a line links counts")
  local listed = false
  for _, e in ipairs(S.TopDemand(5, 7, 2)) do listed = listed or (e.itemID == 4305 and e.n == 2) end
  check(listed, "most asked for")
  local saved = false
  for k in pairs(db.demand[4305]) do saved = type(k) == "number" end
  check(saved, "only day counts are saved")
end

-- Materials requests: k="m" on the post, kept through Renew
do
  clock.skip = clock.skip + 11   -- past the gap between posts
  local mid = C.PostRequest(2318, 20, "", nil, "m")
  check(mid and db.posts[mid].k == "m", "a materials request")
  clock.skip = clock.skip + 11
  local rid = C.Renew(mid)
  check(rid and db.posts[rid].k == "m", "renewed as a materials request")
  C.Retract(rid)
end

-- Timers run cleanly (back-online checks, notices)
runTimers()

-- Locales: every translation loads and covers the enUS list (the check-locales tool does the rest)
eq(NS.L["Find"] ~= nil, true, "locale table")


-- Review fixes: a partial delivery of a multi-item batch keeps the rest made; retracting a
-- request drops its linked orders however deep; an empty cooldown list still goes out.
do
  local batch = { p = 202, o = 998, y = 200, r = { { 2318, 1 } } }
  me.recipes[9901] = batch
  local x = Q.Add({ recipeID = 9901, item = 998, qty = 250, who = "Bob-Forever", src = "batch" })
  Q.Crafted(9901, batch); Q.Crafted(9901, batch)
  Q.Delivered("Bob-Forever", 998, nil, 1)
  eq(Q.CraftsLeft(x, batch), 0, "partial delivery keeps the rest of the batch made")
  Q.Remove(x.id)
  me.recipes[9901] = nil
  -- A cast that makes more than the oldest entry needs: the rest goes to the next one.
  local vy = { p = 171, o = 997, y = 1, yMax = 3, r = { { 2318, 1 } } }
  me.recipes[9902] = vy
  local a = Q.Add({ recipeID = 9902, item = 997, qty = 2, who = "Bob-Forever", src = "vy1" })
  local b = Q.Add({ recipeID = 9902, item = 997, qty = 1, who = "Bob-Forever", src = "vy2" })
  Q.Crafted(9902, vy, nil, 3)
  check(Q.CraftsLeft(a, vy) == 0 and Q.CraftsLeft(b, vy) == 0, "spare items from a cast carry to the next entry")
  Q.Remove(a.id); Q.Remove(b.id)
  -- Casts started from a row's Craft are credited to that row first, not the oldest.
  local r1 = Q.Add({ recipeID = 9902, item = 997, qty = 2, who = "Alice-Forever", src = "row1" })
  local r2 = Q.Add({ recipeID = 9902, item = 997, qty = 2, who = "Bob-Forever", src = "row2" })
  Q.Crafted(9902, vy, nil, nil, nil, r2.id)
  check(Q.MadeItems(r2) == 1 and Q.MadeItems(r1) == 0, "the clicked row gets its craft")
  Q.Remove(r1.id); Q.Remove(r2.id)
  -- A planned entry counts casts: a varying yield's extra items only go to orders.
  local plan = Q.Add({ recipeID = 9902, item = 997, qty = 5, src = "plan:9902" })
  Q.Crafted(9902, vy); Q.Crafted(9902, vy, nil, 2, true)
  eq(Q.CraftsLeft(plan, vy), 4, "extra items don't use up planned casts")
  Q.Remove(plan.id)
  -- A saved alt under its old first-name key isn't taken for someone sharing that first name.
  db.chars["Oldalt-Forever"] = { recipes = {}, profs = {} }
  check(NS.MyCharKey("Oldalt Stranger-Forever") == nil and NS.MyCharKey("Oldalt-Forever") == "Oldalt-Forever",
    "saved characters are recognized by their exact name")
  db.chars["Oldalt-Forever"] = nil
  me.recipes[9902] = nil
  local mine = NS.Me
  db.posts["root"] = { id = "root", from = mine, item = 2304, qty = 1, t = time() }
  db.posts["child"] = { id = "child", from = "Carl-Forever", item = 5, qty = 1, t = time(), pa = "root" }
  db.posts["grandchild"] = { id = "grandchild", from = "Dora-Forever", item = 6, qty = 1, t = time(), pa = "child" }
  NS.Comm.Retract("root")
  check(db.posts["child"] == nil and db.posts["grandchild"] == nil, "retract drops the whole chain of linked orders")
  -- An expired parent takes its (younger) linked orders with it.
  db.posts["old"] = { id = "old", from = "Carl-Forever", item = 2304, qty = 1, t = time() - 25 * 3600 }
  db.posts["young"] = { id = "young", from = "Dora-Forever", item = 5, qty = 1, t = time(), pa = "old" }
  NS.Comm.Requests()
  check(db.posts["old"] == nil and db.posts["young"] == nil, "linked orders expire with their parent")
  check(db.retracted and db.retracted["old"] ~= nil, "the expired parent is tombstoned for late copies")
  local saved = me.cd
  me.cd = nil
  local h2 = NS.Cooldowns.ForHello(16)
  check(type(h2) == "table" and next(h2) == nil, "no cooldowns: an empty list goes out, so peers clear theirs")
  me.cd = saved
end

-- "I no longer need an enchanter" ends the ask, though "need an" is an ask marker.
do
  local function row()
    for _, e in ipairs(CW.Seen()) do if e.from == "Cancel Person-Forever" then return e end end
  end
  CW.Add("LF enchanter for bracer", "Cancel Person", "Trade")
  check(row() ~= nil, "the ask was listed")
  CW.Add("I no longer need an enchanter", "Cancel Person", "Trade")
  check(row() == nil, "a first-person cancellation removes the ask")
end

-- Quantities up to what one request can hold survive detection.
eq((CW.Detect("LF 300x |Hitem:2304::|h[Light Armor Kit]|h") or {}).qty, 300, "a 300x ask keeps its quantity")

-- "I no longer have mats" only changes the reagents; the ask stays.
do
  CW.Add("LF |Hitem:2304::|h[Light Armor Kit]|h have mats", "Mats Person", "Trade")
  CW.Add("I no longer have mats", "Mats Person", "Trade")
  local row
  for _, e in ipairs(CW.Seen()) do if e.from == "Mats Person-Forever" then row = e end end
  check(row ~= nil and not row.mats, "a line about reagents keeps the ask and clears 'brings the reagents'")
  CW.Add("found someone, I no longer have mats", "Mats Person", "Trade")
  row = nil
  for _, e in ipairs(CW.Seen()) do if e.from == "Mats Person-Forever" then row = e end end
  check(row == nil, "a cancellation next to a reagent phrase still ends the ask")
end

-- Progress counts what CraftsLeft leaves: 3 of 4 items from a yield-2 recipe is 1 of 2 crafts.
do
  local x = { qty = 4, madeItems = 3, recipeID = 1 }
  local made, total = NS.Queue.Progress(x, { y = 2, r = {} })
  check(made == 1 and total == 2, "a varying yield leaves the row incomplete while a craft is left")
end

-- Every live retraction is kept (hellos take turns sending them), and an alt on the other
-- faction doesn't count as able to craft for someone here.
do
  for i = 1, 25 do
    local id = NS.Me .. ":x:" .. i
    db.posts[id] = { id = id, from = NS.Me, item = 2304, qty = 1, t = time() }
    NS.Comm.Retract(id)
  end
  local n = 0
  for _ in pairs(db.myRetracted or {}) do n = n + 1 end
  check(n >= 25, "all live retractions are kept, not just the newest 20")
  db.chars["Horde Alt-Forever"] = { faction = "Horde", profs = {}, recipes = { [5555] = { p = 1, o = 5556, r = {} } } }
  NS.Faction = "Alliance"
  check(NS.Inventory.MyRecipeFor(5556) == nil, "an alt on the other faction can't craft for this realm's players")
  db.chars["Horde Alt-Forever"] = nil
end

-- Buy missing reagents: a slot that takes several quality tiers is bought in the tier this
-- merchant sells, once.
do
  local totals = NS.Queue.Totals
  NS.Queue.Totals = function() return { { itemID = 7001, alts = { 7002, 7003 }, need = 5, have = 1 } } end
  local ids = { 5000, 7002, 7003 }
  GetMerchantNumItems = function() return #ids end
  GetMerchantItemID = function(i) return ids[i] end
  GetMerchantItemInfo = function() return "x", nil, 10, 1, -1, true, nil, false end
  GetMoney = function() return 100000 end
  local plan, _, info = NS.Merchant.Plan()
  eq(#plan, 1, "one purchase for a tiered slot")
  eq(plan[1] and plan[1].itemID, 7002, "the first tier the merchant sells")
  eq(plan[1] and plan[1].count, 4, "the slot's shortfall")
  eq(#info.notSold, 0, "an accepted tier counts as sold here")
  NS.Queue.Totals = totals
  GetMerchantNumItems, GetMerchantItemID, GetMerchantItemInfo, GetMoney = nil, nil, nil, nil
end

-- Post notes carry no prices, in any coin, but keep item names made of metal.
eq(NS.Comm.StripPrices("will pay 50 silver"), "will pay", "silver amounts leave a note")
eq(NS.Comm.StripPrices("25c or 2 gold, tip 5"), "or, tip", "copper, gold and tip amounts leave a note")
eq(NS.Comm.StripPrices("need 20 copper bars"), "need 20 copper bars", "copper bars are an item, not a price")
eq(NS.Comm.StripPrices("need 2 Gold Power Cores"), "need 2 Gold Power Cores", "a coin word starting an item name stays")
eq(NS.Comm.StripPrices("pay 5 Gold please"), "pay please", "a capitalized price still goes")
eq(NS.Comm.StripPrices("10 oro y propina 5"), "y propina", "other languages' coin and tip amounts leave a note")
-- Notes are cut on whole UTF-8 characters.
eq(NS.Comm.PostNote(string.rep("a", 59) .. "\195\169\195\169"), string.rep("a", 59) .. "\195\169",
  "a note is cut on whole characters")

-- Recipe tooltips: Blizzard's "Requires %s (%d)" becomes a pattern (a "^" with a start offset
-- anchors at that offset in Lua 5.1, which the parser relies on) that reads profession and skill.
do
  local pat, order = NS.Tooltips.FormatToPattern("Requires %s (%d)")
  check(type(pat) == "string", "FormatToPattern handles a literal prefix")
  local a, b = ("Requires Leatherworking (150)"):match(pat or "^$")
  check(a == "Leatherworking" and b == "150" and order and order[1] == 1, "the pattern reads profession and skill")
  local pat2 = NS.Tooltips.FormatToPattern("Benötigt %2$s (%1$d)")
  check(type(pat2) == "string", "positional placeholders")
  -- Requirements past the skill are the recipe's own (before its "Use:" line), not the crafted
  -- item's that follow.
  local req = NS.Tooltips.OtherRequirements({ "Schematic: Gnomish Cloaking Device", "Requires Engineering (200)",
    "Requires Gnomish Engineer", "Use: Teaches you how to make a Gnomish Cloaking Device.",
    "Gnomish Cloaking Device", "Requires Level 40" })
  check(req.level == nil and req.other[1] == "Gnomish Engineer" and #req.other == 1, "a specialization is a requirement")
  req = NS.Tooltips.OtherRequirements({ "Plans: Thorium Belt", "Requires Blacksmithing (250)", "Requires Level 45",
    "Use: Teaches you how to make a Thorium Belt." })
  check(req.level == 45 and #req.other == 0, "the recipe's own level requirement")
end

-- UI walk: build the window, open every tab, and select every row's card (requests of each
-- kind, queue entries and the queue total, Plan and Find recipes), which runs the list, card,
-- button and badge code with the data above. Frames draw nothing; this catches runtime errors.
drawn = true
local function walk(what, fn)
  local ok, err = pcall(fn)
  check(ok, what .. ": " .. tostring(err))
end
Q.Add({ recipeID = 2152, item = 2304, qty = 3, src = "plan:2152" })
Q.Add({ recipeID = 2152, item = 2304, qty = 2, who = "Bob-Forever", src = "Bob-Forever:1:1" })
Q.Add({ recipeID = 7443, qty = 1, who = "Lollo Causto-Forever", src = "enchant" })
walk("build the window", function() NS.UI.ShowWindow() end)
for tab = 1, 3 do walk("open tab " .. tab, function() NS.UI.ShowTab(tab); NS.UI.Refresh() end) end
NS.UI.ShowTab(2)
local ids = { "queue:total" }
for _, p in ipairs(NS.Comm.Requests()) do ids[#ids + 1] = p.id end
for _, x in ipairs(Q.Entries()) do ids[#ids + 1] = "queue:" .. x.id end
for _, e in ipairs(CW.Seen()) do ids[#ids + 1] = "chat:" .. e.from .. ":" .. (e.itemName or e.prof or "") end
for _, id in ipairs(ids) do
  walk("request card " .. id, function() NS.UI.SelectRequest(id); NS.UI.RequestPrimary() end)
end
NS.UI.ShowTab(3)
for _, id in ipairs({ 2152, 7443, 17187 }) do walk("plan card " .. id, function() NS.UI.SelectPlan(id, true) end) end
NS.UI.ShowTab(1)
for _, id in ipairs({ 2152, 7443, 17187 }) do walk("find card " .. id, function() NS.UI.SelectRecipe(id) end) end
-- "Hide what I can craft": my Light Armor Kit leaves Find, the peer's Mooncloth stays.
do
  local function shows(id)
    for _, x in ipairs(NS.UI.FindShown()) do if x == id then return true end end
    return false
  end
  NS.UI.RefreshFind()
  check(shows(2152) and shows(18560), "Find lists my recipes and a peer's")
  db.ui.findHideMine = true
  walk("find: hide what I can craft", function() NS.UI.FilterFind(false) end)
  check(not shows(2152) and shows(18560), "hiding what I can craft keeps only others' recipes")
  -- An alt's item can be mailed to me (hidden); an alt's enchant can't reach my gear (stays).
  local alt = db.chars["Bankalt-Forever"]
  alt.recipes[9501] = { p = 333, n = "Enchant Boots - Minor Speed", e = true, r = {} }
  alt.recipes[9502] = { p = 165, n = "Alt Armor Kit", o = 2305, r = {} }
  NS.UI.RefreshFind()
  check(shows(9501) and not shows(9502), "an alt's enchant stays, an alt's item is hidden")
  alt.recipes[9501], alt.recipes[9502] = nil, nil
  db.ui.findHideMine = nil
  NS.UI.RefreshFind()
end
walk("badge and status", function() NS.UI.UpdateBadge(); NS.UI.RefreshStatus() end)
walk("hide", function() NS.UI.Hide() end)
runTimers()

-- CraftBoardAPI (for Town Square)
local API = CraftBoardAPI
check(type(API) == "table" and API.version == 1, "CraftBoardAPI v1 is global")
check(API.AddChatSeen("LF enchanter for 15 agi 2h", "Tess Varn", "Trade") == true, "API: a crafting ask is added")
local before = #CW.Seen()
check(API.AddChatSeen("LF enchanter for 15 agi 2h", "Tess Varn", "Trade") == true and #CW.Seen() == before,
  "API: the same ask twice adds one row")
check(API.AddChatSeen("anyone going to DM?", "Tess Varn", "Trade") == false, "API: a group line isn't a crafting ask")
walk("API: show requests for a sender", function() API.ShowRequests("Tess Varn") end)
walk("API: find", function() API.Find("Linen Bag") end)
runTimers()

-- Forgetting other players takes the private trade history with it.
db.crafted = { ["Bob-Forever"] = { m = 2, t = 1 } }
NS.Options.ForgetPeers()
eq(next(db.crafted), nil, "forgetting players clears the crafted history")

print(string.format("smoke (%s): %d passed, %d failed", LOCALE, passed, failures))
os.exit(failures == 0 and 0 or 1)
