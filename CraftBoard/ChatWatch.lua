-- CraftBoard ChatWatch: spots people asking for a crafter in public chat (Trade / General /
-- LookingForGroup, say, yell, optionally guild), so the Requests tab is useful even when nobody
-- else runs CraftBoard. Read-only: nothing is ever sent from here, and nothing is saved.
--
-- Detector (ChatWatch.Detect, pure Lua): a line is a crafting request when it has
--   * an ask marker: "lf", "looking for", "need a/an", "wtb", "anyone (who/that) can",
--     "any <profession>";
--   * and a profession word (lw, bs, ench, alch, tailor, eng, cook, first aid and their long
--     forms) or an item / enchant link (or plain "[Name]");
--   * and no offer marker ("wts", "selling", "lfw", "can craft", "crafting for tips",
--     "tips welcome", "max ench") unless it also says "wtb".
-- Lines over 255 characters and my own lines are ignored.
local ADDON, NS = ...

local ChatWatch = {}
NS.ChatWatch = ChatWatch

local L = NS.L
local type, pairs, ipairs, time = type, pairs, ipairs, time
local lower, sort = string.lower, table.sort

local TTL = 30 * 60
local CAP = 40
local MAX_LEN = 255

-- Profession words -> { profession name as stored in profs, skill line ID }.
local LW = { "Leatherworking", 165 }
local BS = { "Blacksmithing", 164 }
local ENCH = { "Enchanting", 333 }
local ALCH = { "Alchemy", 171 }
local TAIL = { "Tailoring", 197 }
local ENG = { "Engineering", 202 }
local COOK = { "Cooking", 185 }
local FA = { "First Aid", 129 }
local PROF_WORDS = {
  lw = LW, leatherworker = LW, leatherworkers = LW, leatherworking = LW,
  bs = BS, blacksmith = BS, blacksmiths = BS, blacksmithing = BS,
  ench = ENCH, enchanter = ENCH, enchanters = ENCH, enchanting = ENCH,
  alch = ALCH, alchemist = ALCH, alchemists = ALCH, alchemy = ALCH,
  tailor = TAIL, tailors = TAIL, tailoring = TAIL,
  eng = ENG, engi = ENG, engineer = ENG, engineers = ENG, engineering = ENG,
  cook = COOK, cooks = COOK, cooking = COOK,
}

-- Phrases are matched on the normalized line (" " .. words .. " ", lower case, one space apart).
local ASK = { " lf ", " looking for ", " need a ", " need an ", " wtb ", " anyone can ", " anyone who can ",
  " anyone that can " }
local OFFER = { " wts ", " selling ", " lfw ", " can craft ", " crafting for tips ", " tips welcome ", " max ench " }
-- The asker brings the reagents.
local MATS = { " have mats ", " have the mats ", " have all mats ", " my mats ", " with mats ", " own mats ",
  " got mats ", " mats ready ", " i have mats " }

-- Links players can paste for something craftable (not quests, achievements, players...).
local LINK_TYPES = { item = true, enchant = true, spell = true, trade = true }

-- Runtime state (not saved)
local seen = {}          -- [Name-Realm] = entry
local hidden = {}        -- [Name-Realm] = lower-cased line the player hid (same line won't come back)
local firePending = false
local index, indexDirty = nil, true
local serverChannels     -- [localized server channel name] = true

-- Detector -----------------------------------------------------------------------

-- Every real link name in the line, in order (so a crafter listing four enchants is shown as
-- a list, not as a request for the first one).
local function LinkNames(text)
  local out = {}
  for kind, name in text:gmatch("|H(%a+):[^|]*|h%[([^%]]+)%]|h") do
    if LINK_TYPES[kind] then out[#out + 1] = name end
  end
  return out
end

local function FirstLinkName(text)
  local names = LinkNames(text)
  if names[1] then return names[1] end
  -- A plain "[Name]" with no real link only counts when it names one of my recipes or
  -- their outputs (otherwise "[PvP]" or "[Enchanting]" in adverts would read as an item).
  if not text:find("|H", 1, true) then
    local plain = text:match("%[([^%]|]+)%]")
    if plain and ChatWatch.Resolve and ChatWatch.Resolve(plain) then return plain end
  end
  return nil
end

-- Colour codes off (Forever's named "|cnIQ1:" ones too), links reduced to "[Name]", textures
-- and control characters dropped.
function ChatWatch.Clean(text)
  if type(text) ~= "string" then return "" end
  return (NS.StripCodes(text):gsub("|", ""):gsub("%c", " "))
end

local function Has(s, list)
  for i = 1, #list do
    if s:find(list[i], 1, true) then return true end
  end
  return false
end

-- Returns { prof=, profID=, itemName= } for a crafting request, else nil and a reason
-- ("long", "offer", "noask", "nothing").
function ChatWatch.Detect(text)
  if type(text) ~= "string" or text == "" then return nil, "nothing" end
  if #text > MAX_LEN then return nil, "long" end
  local itemName = FirstLinkName(text)
  -- Words only: bracketed names are left out so "[Enchant ...]" never reads as a profession.
  local plain = ChatWatch.Clean(text):gsub("%b[]", " ")
  local s = " " .. lower(plain):gsub("[^%w]+", " ") .. " "
  s = s:gsub("  +", " ")
  local wtb = s:find(" wtb ", 1, true) ~= nil
  if not wtb and Has(s, OFFER) then return nil, "offer" end
  local prof
  if s:find(" first aid ", 1, true) then prof = FA end
  if not prof then
    for w in s:gmatch("%S+") do
      if PROF_WORDS[w] then prof = PROF_WORDS[w] break end
    end
  end
  local ask = Has(s, ASK)
  if not ask and prof then
    -- "any lw around?" / "any enchanter?"
    for w in s:gmatch(" any (%S+)") do
      if PROF_WORDS[w] then ask = true break end
    end
    if not ask and s:find(" any first aid ", 1, true) then ask = true end
  end
  if not ask then return nil, "noask" end
  if not (prof or itemName) then return nil, "nothing" end
  local links = LinkNames(text)
  return { prof = prof and prof[1], profID = prof and prof[2], itemName = itemName,
           links = #links > 1 and links or nil, mats = Has(s, MATS) or nil }
end

-- Words that only restate "someone make this for me": the ask markers, fillers, counts and
-- profession words. A chat line made only of these (and the linked item) says nothing the
-- card's title doesn't already say.
local FILLER = {}
for w in ("lf lfm wtb need needs needed anyone any can craft crafter crafting make made pls plz please "
  .. "pst w me a an the for x i im looking someone somebody who that to ty thanks thx is are there around "
  .. "of on in with and or"):gmatch("%S+") do FILLER[w] = true end

-- The chat line of entry e adds something to its title (a tip, "have mats", a deadline...).
function ChatWatch.AddsDetail(e)
  if type(e) ~= "table" or type(e.text) ~= "string" then return false end
  local s = lower(e.text):gsub("%b[]", " ")
  for w in s:gmatch("[%w']+") do
    if not (FILLER[w] or PROF_WORDS[w] or w:match("^x?%d+x?$") or #w < 2) then return true end
  end
  return false
end

-- My recipes by lower-cased recipe name and output item name ------------------------

local function MyChars()
  local db = type(CraftBoardDB) == "table" and CraftBoardDB
  return db and type(db.chars) == "table" and db.chars or {}
end

local function BuildIndex()
  index, indexDirty = {}, false
  local itemName = NS.Inventory and NS.Inventory.ItemName
  local function take(c, current, key)
    if type(c) ~= "table" or type(c.recipes) ~= "table" then return end
    for id, rec in pairs(c.recipes) do
      if type(rec) == "table" and type(id) == "number" then
        local e = { recipeID = id, current = current, prof = rec.p, char = key }
        if type(rec.n) == "string" and not index[lower(rec.n)] then index[lower(rec.n)] = e end
        local out = type(rec.o) == "number" and itemName and itemName(rec.o)
        if type(out) == "string" and not index[lower(out)] then index[lower(out)] = e end
      end
    end
  end
  local chars = MyChars()
  if NS.Me then take(chars[NS.Me], true, NS.Me) end
  -- Alts in name order, so "Known on <alt>" doesn't change between sessions.
  local keys = {}
  for key in pairs(chars) do
    if key ~= NS.Me and type(key) == "string" then keys[#keys + 1] = key end
  end
  sort(keys)
  for _, key in ipairs(keys) do take(chars[key], false, key) end
end

-- Recipe of mine (current char first, then alts) for an item or enchant name:
-- recipeID, current, prof, char ("Name-Realm" of the character that knows it).
function ChatWatch.Resolve(name)
  if type(name) ~= "string" or name == "" then return nil end
  if indexDirty or not index then BuildIndex() end
  local e = index[lower(name)]
  if not e then return nil end
  return e.recipeID, e.current, e.prof, e.char
end

-- Resolve an entry's item name onto it: recipeID, current, knownOn (the alt that knows it
-- when the current character doesn't).
local function ResolveEntry(e)
  local id, current, _, char = ChatWatch.Resolve(e.itemName)
  e.recipeID, e.current = id, current
  e.knownOn = id and not current and char or nil
end

-- The current character has this profession, or knows the recipe.
function ChatWatch.CanHelp(entry)
  if type(entry) ~= "table" then return false end
  if entry.recipeID and entry.current then return true end
  local c = NS.Me and MyChars()[NS.Me]
  local profs = type(c) == "table" and type(c.profs) == "table" and c.profs or {}
  for id, p in pairs(profs) do
    if entry.profID and id == entry.profID then return true end
    local name = type(p) == "table" and (p.name or p[1])
    if entry.prof and name == entry.prof then return true end
  end
  return false
end

-- Options ------------------------------------------------------------------------

function ChatWatch.Enabled()
  return not (type(CraftBoardDB) == "table" and CraftBoardDB.chatWatch == false)
end

function ChatWatch.GuildEnabled()
  return type(CraftBoardDB) == "table" and CraftBoardDB.chatWatchGuild == true
end

local function FireSoon()
  if firePending then return end
  firePending = true
  local function go()
    firePending = false
    if NS.callbacks and NS.callbacks.Fire then pcall(NS.callbacks.Fire, NS.callbacks, "CHAT_SEEN_UPDATED") end
  end
  if C_Timer and C_Timer.After then C_Timer.After(1, go) else go() end
end

function ChatWatch.SetEnabled(on)
  if type(CraftBoardDB) == "table" then CraftBoardDB.chatWatch = on and true or false end
  if not on then
    seen, hidden = {}, {}
  end
  FireSoon()
end

function ChatWatch.SetGuildEnabled(on)
  if type(CraftBoardDB) == "table" then CraftBoardDB.chatWatchGuild = on and true or false end
  if not on then
    for k, e in pairs(seen) do
      if e.guild then seen[k] = nil end
    end
  end
  FireSoon()
end

-- Store ----------------------------------------------------------------------------

-- keep: a key never evicted by the cap (the line just added).
local function Prune(keep)
  local cutoff = time() - TTL
  local n = 0
  for k, e in pairs(seen) do
    if e.t < cutoff then seen[k] = nil else n = n + 1 end
  end
  while n > CAP do
    local oldK, oldT
    for k, e in pairs(seen) do
      if k ~= keep and (not oldT or e.t < oldT) then oldK, oldT = k, e.t end
    end
    seen[oldK] = nil
    n = n - 1
  end
end

-- Newest first: { from="Name-Realm", text=, prof=, profID=, itemName=, recipeID=, current=,
-- knownOn="Alt-Realm", channel="Trade", t=, first= (first time this ask was seen), asks=
-- (times seen), mats=true (brings the reagents) }. Copies; entries older than 30 min are gone.
function ChatWatch.Seen()
  Prune()
  local list = {}
  if not ChatWatch.Enabled() then return list end
  for _, e in pairs(seen) do
    if e.itemName and not e.recipeID then ResolveEntry(e) end
    local copy = {}
    for k, v in pairs(e) do copy[k] = v end
    list[#list + 1] = copy
  end
  sort(list, function(a, b)
    if a.t ~= b.t then return a.t > b.t end
    return a.from < b.from
  end)
  return list
end

function ChatWatch.Hide(from)
  local e = type(from) == "string" and seen[from]
  if not e then return false end
  hidden[from] = lower(e.text)
  seen[from] = nil
  FireSoon()
  return true
end

local function MyRealm()
  local r = GetNormalizedRealmName and GetNormalizedRealmName()
  if (not r or r == "") and type(NS.Realm) == "string" then r = NS.Realm end
  if r == "" then return nil end
  return r
end

local function FullName(name)
  -- Forever character names are two words ("Raion Lyzl"), so a space is allowed; only
  -- control characters and link markup are rejected.
  if type(name) ~= "string" or name == "" or #name > 64 or name:find("[|%c]") then return nil end
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then return nil end
  if not name:find("-", 1, true) then
    local realm = MyRealm()
    if not realm then return nil end
    name = name .. "-" .. realm
  end
  return name
end

-- Forever names are two words but UnitName("player") returns only the first, so a sender is
-- me when its first word and realm match mine.
local function IsMe(full)
  if NS.Me and full == NS.Me then return true end
  local mine, realm = UnitName and UnitName("player"), MyRealm()
  if not (mine and realm) then return false end
  local name, r = full:match("^(.-)%-([^%-]+)$")
  if not name then return false end
  return r == realm and (name == mine or name:match("^(%S+)") == mine)
end

-- Record a chat line (also the entry point for tests). Returns the stored entry or nil.
function ChatWatch.Add(text, sender, channel, guild)
  if not ChatWatch.Enabled() then return nil end
  local from = FullName(sender)
  if not from or IsMe(from) or (NS.IsIgnored and NS.IsIgnored(from)) then return nil end
  local hit = ChatWatch.Detect(text)
  if not hit then return nil end
  local clean = ChatWatch.Clean(text)
  local lclean = lower(clean)
  if hidden[from] then
    if hidden[from] == lclean then return nil end
    hidden[from] = nil
  end
  local now = time()
  local e = {
    from = from, text = clean, prof = hit.prof, profID = hit.profID, itemName = hit.itemName,
    links = hit.links, mats = hit.mats,
    channel = channel, guild = guild or nil, t = now, first = now, asks = 1,
  }
  -- One row per player: asking again for the same thing bumps the count and keeps when it was
  -- first seen; a different ask replaces the row.
  local prev = seen[from]
  if prev and (prev.itemName or prev.prof) == (e.itemName or e.prof) then
    e.first, e.asks = prev.first or prev.t, (prev.asks or 1) + 1
    e.mats = e.mats or prev.mats
  end
  if hit.itemName then ResolveEntry(e) end
  seen[from] = e
  Prune(from)
  FireSoon()
  return e
end

-- Events ---------------------------------------------------------------------------

local function ServerChannels()
  if serverChannels then return serverChannels end
  local found = {}
  if EnumerateServerChannels then
    local ok, a = pcall(function() return { EnumerateServerChannels() } end)
    if ok and type(a) == "table" then
      for _, name in ipairs(a) do
        if type(name) == "string" and name ~= "" then found[name] = true end
      end
    end
  end
  -- Empty while the client is still loading: ask again next time.
  if next(found) ~= nil then serverChannels = found end
  return found
end

-- "Trade - City" -> "Trade". Server channels (General, Trade, LookingForGroup...) only, never
-- defense / recruitment or custom channels.
local function PublicChannel(baseName, channelName)
  local base = type(baseName) == "string" and baseName ~= "" and baseName or nil
  if not base and type(channelName) == "string" then base = channelName:match("^%d+%.%s*(.+)$") or channelName end
  if not base then return nil end
  base = base:match("^(.-)%s+%-%s+.*$") or base
  if base:find("Defense", 1, true) or base:find("Recruitment", 1, true) then return nil end
  -- Forever splits channels by language and purpose: "Trade - English", "Trade (Services) -
  -- English". Match on the leading word so those all count; the server list is only used to
  -- also accept localized names it reports.
  -- The label shown in the list is the leading word ("Trade"), never the full server name.
  -- Second value: the name without its " - English" / " - City" suffix (for /cb chatdebug).
  local head = base:match("^(%a+)") or base
  local server = ServerChannels()
  if server[base] then return head, base end
  if head == "Trade" or head == "General" or head == "LookingForGroup" then return head, base end
  for name in pairs(server) do
    if base:sub(1, #name) == name then return head, base end
  end
  return nil
end

local function Secret(...)
  if not issecretvalue then return false end
  for i = 1, select("#", ...) do
    if issecretvalue((select(i, ...))) then return true end
  end
  return false
end

-- /cb chatdebug counters; bases = set of accepted channel names ("Trade (Services)"), capped.
local stats = { seen = 0, channel = 0, accepted = 0, matched = 0, last = "", bases = {}, nbases = 0 }
ChatWatch.Stats = function() return stats end

local function OnChat(event, text, sender, _, channelName, _, _, _, _, baseName)
  stats.seen = stats.seen + 1
  if not ChatWatch.Enabled() then return end
  if Secret(text, sender) then stats.secret = (stats.secret or 0) + 1; return end
  if type(text) ~= "string" or type(sender) ~= "string" then return end
  local label, guild
  if event == "CHAT_MSG_CHANNEL" then
    stats.channel = stats.channel + 1
    if Secret(channelName, baseName) then stats.secret = (stats.secret or 0) + 1; return end
    local base
    label, base = PublicChannel(baseName, channelName)
    stats.last = tostring(baseName or channelName)
    if label then
      stats.accepted = stats.accepted + 1
      if base and not stats.bases[base] and stats.nbases < 20 then
        stats.bases[base] = true
        stats.nbases = stats.nbases + 1
      end
      -- Keep the last 40 accepted lines (saved) so the detector can be tuned on real chat.
      if type(CraftBoardDB) == "table" then
        local log = CraftBoardDB.chatlog or {}
        CraftBoardDB.chatlog = log
        log[#log + 1] = NS.StripCodes(text)
        if #log > 40 then table.remove(log, 1) end
      end
    end
  elseif event == "CHAT_MSG_SAY" then
    label = L["Say"]
  elseif event == "CHAT_MSG_YELL" then
    label = L["Yell"]
  elseif event == "CHAT_MSG_GUILD" then
    if ChatWatch.GuildEnabled() then label, guild = L["Guild"], true end
  end
  if label then ChatWatch.Add(text, sender, label, guild) end
end

for _, ev in ipairs({ "CHAT_MSG_CHANNEL", "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_GUILD" }) do
  NS.Register(ev, OnChat)
end

-- My recipe names change with scans and as item names load. Players I ignore drop out.
if NS.RegisterCallback then
  NS.RegisterCallback(ChatWatch, "IGNORE_UPDATED", function()
    for k in pairs(seen) do
      if NS.IsIgnored(k) then seen[k] = nil end
    end
    FireSoon()
  end)
  local function dirty() indexDirty = true end
  NS.RegisterCallback(ChatWatch, "RECIPES_UPDATED", dirty)
  NS.RegisterCallback(ChatWatch, "ITEM_NAMES_UPDATED", dirty)
end
