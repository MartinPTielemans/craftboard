-- CraftBoard ChatWatch: spots people asking for a crafter in public chat (Trade / General /
-- LookingForGroup, say, yell, optionally guild), so the Requests tab is useful even when nobody
-- else runs CraftBoard. Read-only: nothing is ever sent from here, and chat lines are kept in
-- memory only. The one exception is the detector's tuning log (the last 40 accepted channel
-- lines in CraftBoardDB.chatlog), written only while /cb chatdebug log turns it on
-- (CraftBoardDB.chatlogOn); with it off any old log is dropped at load.
--
-- Detector (ChatWatch.Detect, pure Lua): a line is a crafting request when it has
--   * no advert marker: "recruiting", "raiders", "guild" (outside guild chat), and "lfm" / "lfg"
--     when no profession is named;
--   * an ask marker: "lf", "looking for", "need a/an", "wtb", "can anyone/someone", "who can",
--     "anyone (who/that) can", "anybody", "any <profession>", "need <profession>",
--     "<profession> needed/wanted";
--   * and a profession word (lw, bs, ench/enchant, alch, tailor, eng, cook, first aid and their
--     long forms; "eng speaking" is the language) or a link: enchant / spell / trade links
--     always, an item link with a profession word or when the item is something my characters
--     or my peers craft ("WTB [Linen Cloth] x20" is shopping), a plain "[Name]" when it names
--     one of my recipes;
--   * and no offer marker ("wts", "selling", "lfw", "lf work", "can craft" - not "who can
--     craft" -, "for tips", "customers", "your mats", "all patterns", "max ench"...) unless it
--     also says "wtb".
-- Lines over 255 characters and my own lines are ignored. A player's "nvm" / "found one" drops
-- their row.
local ADDON, NS = ...

local ChatWatch = {}
NS.ChatWatch = ChatWatch

local L = NS.L
local type, pairs, ipairs, time, tonumber = type, pairs, ipairs, time, tonumber
local lower, sort = string.lower, table.sort

local TTL = 30 * 60
local CAP = 40
local MAX_LEN = 255
local LOG_MAX = 40

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
  ench = ENCH, enchant = ENCH, enchants = ENCH, enchanter = ENCH, enchanters = ENCH, enchanting = ENCH,
  alch = ALCH, alchemist = ALCH, alchemists = ALCH, alchemy = ALCH,
  tailor = TAIL, tailors = TAIL, tailoring = TAIL,
  eng = ENG, engi = ENG, engineer = ENG, engineers = ENG, engineering = ENG,
  cook = COOK, cooks = COOK, cooking = COOK,
}
-- "eng speaking" / "eng only" is the language, not Engineering.
local NOT_ENG = { speaking = true, speaker = true, speakers = true, only = true }

-- Phrases are matched on the normalized line (" " .. words .. " ", lower case, one space apart).
local ASK = { " lf ", " looking for ", " need a ", " need an ", " wtb ", " anyone can ", " anyone who can ",
  " anyone that can ", " can anyone ", " can someone ", " can somebody ", " who can ", " anyone able ", " anybody " }
local OFFER = { " wts ", " selling ", " lfw ", " lf work ", " looking for work ", " can craft ", " for tips ",
  " tips welcome ", " max ench ", " customers ", " your mats ", " ur mats ", " all patterns " }
-- " can craft " is the speaker's offer ("I can craft all BS patterns") unless the word before it
-- asks who can ("who can craft [X]?", "anyone that can craft").
local ASKING = { who = true, anyone = true, anybody = true, someone = true, somebody = true, that = true,
  you = true, u = true }
-- Adverts that name professions without asking for a craft: guild recruitment, group searches.
local SKIP = { " recruiting ", " recruit ", " raiders " }
local SKIP_NO_PROF = { " lfm ", " lfg " }
-- The asker brings the reagents (unless the line says they don't: NO_MATS, which wins).
local NO_MATS = { " no longer have ", " dont have any ", " don t have any ", " ran out of ", " out of mats ", " dont have ", " don t have ", " do not have ", " no mats ", " without mats ", " need mats ",
  " havent got ", " haven t got ", " not have ", " no have " }
local MATS = { " have mats ", " have the mats ", " have all mats ", " have all the mats ", " my mats ", " with mats ",
  " with my mats ", " w mats ", " own mats ", " got mats ", " got all mats ", " mats ready ", " i have mats ",
  " bring mats ", " bring my mats ", " mats provided " }
-- The player no longer needs what they asked for.
local DONE = { " nvm ", " nevermind ", " never mind ", " found one ", " found someone ", " got one ", " got it ",
  " no longer " }
-- Cancellations that contain an ask marker themselves ("I no longer need an enchanter"): they end
-- the ask wherever they stand in the line.
local CANCEL = { " no longer need ", " dont need ", " don t need ", " do not need ", " not needed ", " no need for ",
  " no longer looking ", " not looking for " }

-- Links players can paste for something craftable (not quests, achievements, players...).
local LINK_TYPES = { item = true, enchant = true, spell = true, trade = true }

-- Runtime state (not saved)
local seen = {}          -- [Name-Realm] = entry
local hidden = {}        -- [Name-Realm] = lower-cased line the player hid (same line won't come back)
local firePending = false
local index, byItem, indexDirty = nil, nil, true
local outputs            -- [itemID] = true for every item my characters or my peers craft
local serverChannels     -- [localized server channel name] = true

-- My recipes and the shared catalogue ---------------------------------------------

local function MyChars()
  local db = type(CraftBoardDB) == "table" and CraftBoardDB
  return db and type(db.chars) == "table" and db.chars or {}
end

-- Items someone crafts: my characters' recipe outputs and the catalogue's (my scans and the
-- recipe lists peers sent). Rebuilt after RECIPES_UPDATED / PEERS_UPDATED.
local function KnownOutputs()
  if outputs then return outputs end
  local set = {}
  -- My characters that can craft for someone here (this realm and faction), what can be traded.
  local reachable = NS.Inventory and NS.Inventory.Reachable
  local tradeable = NS.Recipes and NS.Recipes.IsTradeable
  for key, c in pairs(MyChars()) do
    if type(c) == "table" and type(c.recipes) == "table" and (key == NS.Me or not reachable or reachable(key, c)) then
      for _, rec in pairs(c.recipes) do
        if type(rec) == "table" and type(rec.o) == "number" and (not tradeable or tradeable(rec)) then set[rec.o] = true end
      end
    end
  end
  -- Peers' current recipe lists (the catalogue only turns their recipe IDs into items: it keeps
  -- recipes nobody advertises any more).
  local db = type(CraftBoardDB) == "table" and CraftBoardDB
  local cat = db and type(db.recipeNames) == "table" and db.recipeNames or {}
  for name, p in pairs(db and type(db.peers) == "table" and db.peers or {}) do
    local ignored = NS.IsIgnored and NS.IsIgnored(name)
    for id in pairs(not ignored and type(p) == "table" and type(p.recipes) == "table" and p.recipes or {}) do
      local e = cat[id]
      if type(e) == "table" and type(e.o) == "number" then set[e.o] = true end
    end
  end
  -- Not cached before the saved variables are in.
  if type(CraftBoardDB) == "table" then outputs = set end
  return set
end

-- Detector -----------------------------------------------------------------------

-- Every real link in the line, in order: { kind=, id= (the link's first number: the item ID
-- of an item link), name= }.
local function Links(text)
  local out = {}
  for kind, data, name in text:gmatch("|H(%a+):([^|]*)|h%[([^%]]+)%]|h") do
    if LINK_TYPES[kind] then out[#out + 1] = { kind = kind, id = tonumber(data:match("^(%d+)") or ""), name = name } end
  end
  return out
end

-- The link a line asks for: the first enchant / spell / trade link or crafted item. Without a
-- profession word nothing else counts; with one, the first link. A plain "[Name]" with no
-- real link only counts when it names one of my recipes or their outputs (otherwise "[PvP]"
-- or "[Enchanting]" in adverts would read as an item). Returns name, itemID.
local function Asked(text, links, prof)
  for _, l in ipairs(links) do
    if l.kind ~= "item" then return l.name, nil end
    if l.id and KnownOutputs()[l.id] then return l.name, l.id end
  end
  if links[1] then
    if prof then return links[1].name, links[1].kind == "item" and links[1].id or nil end
    return nil
  end
  if not text:find("|H", 1, true) then
    local plain = text:match("%[([^%]|]+)%]")
    if plain and ChatWatch.Resolve and ChatWatch.Resolve(plain) then return plain, nil end
  end
  return nil
end

-- Colour codes off (Forever's named "|cnIQ1:" ones too), links reduced to "[Name]", textures
-- and control characters dropped.
function ChatWatch.Clean(text)
  if type(text) ~= "string" then return "" end
  return (NS.StripCodes(text):gsub("|", ""):gsub("%c", " "))
end

-- Words only, for the phrase lists: bracketed names are left out so "[Enchant ...]" never
-- reads as a profession.
local function Normalize(clean)
  local s = " " .. lower(clean:gsub("%b[]", " ")):gsub("[^%w]+", " ") .. " "
  return (s:gsub("  +", " "))
end

local function Has(s, list)
  for i = 1, #list do
    if s:find(list[i], 1, true) then return true end
  end
  return false
end

local function Offer(s)
  for i = 1, #OFFER do
    local p = OFFER[i]
    local at = s:find(p, 1, true)
    while at do
      if p ~= " can craft " or not ASKING[s:sub(1, at):match("(%S+) $") or ""] then return true end
      at = s:find(p, at + 1, true)
    end
  end
  return false
end

-- Profession of word i, or nil ("eng" followed by "speaking" is the language).
local function ProfAt(words, i)
  local p = PROF_WORDS[words[i]]
  if p == ENG and words[i] == "eng" and NOT_ENG[words[i + 1] or ""] then return nil end
  return p
end

-- mentioned, brings: the line talks about reagents at all, and says the asker brings them
-- (a negation wins: "have mats? no, don't have mats").
local function Mats(s)
  local no = Has(s, NO_MATS)
  return no or Has(s, MATS), not no and Has(s, MATS)
end

-- How many, when the line says (1..1000, what one request can ask for): a number right before a
-- link ("5 [Item]", "5x [Item]"), "x 5" right after one, else "5x" / "x5" anywhere.
local function Quantity(clean, s)
  local q = tonumber(clean:match("(%d+)%s*[xX]?%s*%[") or clean:match("%]%s*[xX]%s*(%d+)")
    or s:match(" (%d+) ?x ") or s:match(" x ?(%d+) ") or "")
  if q and (q < 1 or q > 1000) then return nil end
  return q
end

-- Returns { prof=, profID=, itemName=, itemID=, links=, mats=, matsSaid=, qty= } for a crafting
-- request, else nil and a reason ("long", "skip", "offer", "noask", "nothing").
-- guildChat: the line is from guild chat (where "guild" isn't an advert).
function ChatWatch.Detect(text, guildChat)
  if type(text) ~= "string" or text == "" then return nil, "nothing" end
  if #text > MAX_LEN then return nil, "long" end
  local clean = ChatWatch.Clean(text)
  local s = Normalize(clean)
  local words = {}
  for w in s:gmatch("%S+") do words[#words + 1] = w end
  local prof, profAsk
  if s:find(" first aid ", 1, true) then prof = FA end
  for i = 1, #words do
    local p = ProfAt(words, i)
    if p then
      -- "any lw around?", "need enchanter", "enchanter needed", "LW wanted": the profession asked
      -- for wins over one merely named ("tailor, need enchanter").
      local before, after = words[i - 1], words[i + 1]
      if before == "any" or before == "need" or before == "needs" or after == "needed" or after == "wanted" then
        if not profAsk then prof = p end
        profAsk = true
      end
      prof = prof or p
    end
  end
  if Has(s, SKIP) or (not guildChat and s:find(" guild ", 1, true)) or (not prof and Has(s, SKIP_NO_PROF)) then
    return nil, "skip"
  end
  local wtb = s:find(" wtb ", 1, true) ~= nil
  if not wtb and Offer(s) then return nil, "offer" end
  local ask = profAsk or Has(s, ASK) or s:find(" any first aid ", 1, true) ~= nil
  if not ask then return nil, "noask" end
  local links = Links(text)
  local itemName, itemID = Asked(text, links, prof)
  if not (prof or itemName) then return nil, "nothing" end
  local names
  if #links > 1 then
    names = {}
    for i = 1, #links do names[i] = links[i].name end
  end
  local matsSaid, mats = Mats(s)
  return { prof = prof and prof[1], profID = prof and prof[2], itemName = itemName, itemID = itemID,
           links = names, mats = mats or nil, matsSaid = matsSaid or nil, qty = Quantity(clean, s) }
end

-- Words that say nothing beyond the card's title: the ask markers and fillers, courtesy,
-- payment and timing words, "have mats" (shown on its own). Shared by Topic and AddsDetail.
local FILLER = {}
for w in ("lf lfm wtb need needs needed anyone any can craft crafter crafting make made pls plz please "
  .. "pst w me a an the for x i im looking someone somebody who that to ty thanks thx is are there around "
  .. "of on in with and or pay paying paid gold will well tip tips my your ur u online now asap alt "
  .. "have has got mats own bring anybody no not dont don't without"):gmatch("%S+") do FILLER[w] = true end
-- Profession words that also name the thing asked for ("head enchant"); dropped only in front.
local TOPIC_WORDS = { enchant = true, enchants = true }

-- Noise for Topic / AddsDetail: fillers, profession words, the quantity ("5x", "x5", or the
-- plain number the line's quantity came from) and prices ("5g", "50s", "5gold"). Other plain
-- numbers stay ("15 agi").
local function Noise(w, qty, first)
  if FILLER[w] or #w < 2 then return true end
  if PROF_WORDS[w] and (first or not TOPIC_WORDS[w]) then return true end
  if w:match("^x%d+$") or w:match("^%d+x$") or w:match("^%d+[gsc]$") or w:match("^%d+gold$") then return true end
  return qty ~= nil and tonumber(w) == qty
end

-- Up to max words of entry e's line that aren't noise.
local function DetailWords(e, max)
  local words = {}
  if type(e) ~= "table" or type(e.text) ~= "string" then return words end
  for w in lower(e.text):gsub("%b[]", " "):gmatch("[%w'+]+") do
    if not Noise(w, e.qty, #words == 0) then
      words[#words + 1] = w
      if #words == max then break end
    end
  end
  return words
end

-- A few words saying what a profession-only ask is about ("head enchant" from "any enchanter
-- have head enchant?", "15 agi 2h" from "LF ench 15 agi 2h will pay 5g"), at most three. nil
-- when nothing is left.
function ChatWatch.Topic(e)
  local words = DetailWords(e, 3)
  if #words == 0 then return nil end
  return table.concat(words, " ")
end

-- The chat line of entry e adds something to its title (what the enchant is for, a
-- deadline...).
function ChatWatch.AddsDetail(e)
  return #DetailWords(e, 1) > 0
end

-- My recipes by lower-cased recipe name and output item name, and by output item ID ---------

local function BuildIndex()
  index, byItem, indexDirty = {}, {}, false
  local itemName = NS.Inventory and NS.Inventory.ItemName
  local function take(c, current, key)
    if type(c) ~= "table" or type(c.recipes) ~= "table" then return end
    local tradeable = NS.Recipes and NS.Recipes.IsTradeable
    for id, rec in pairs(c.recipes) do
      -- Bind-on-Pickup and quest items can't be made for someone else (as in Find).
      if type(rec) == "table" and type(id) == "number" and (not tradeable or tradeable(rec)) then
        local e = { recipeID = id, current = current, prof = rec.p, char = key }
        if type(rec.n) == "string" and not index[lower(rec.n)] then index[lower(rec.n)] = e end
        if type(rec.o) == "number" and not byItem[rec.o] then byItem[rec.o] = e end
        local out = type(rec.o) == "number" and itemName and itemName(rec.o)
        if type(out) == "string" and not index[lower(out)] then index[lower(out)] = e end
      end
    end
  end
  local chars = MyChars()
  if NS.Me then take(chars[NS.Me], true, NS.Me) end
  -- Alts in name order, so "Known on <alt>" doesn't change between sessions.
  local keys = {}
  -- Only alts on this realm and faction: another's crafts can't reach the asker.
  local reachable = NS.Inventory and NS.Inventory.Reachable
  for key, c in pairs(chars) do
    if key ~= NS.Me and type(key) == "string" and (not reachable or reachable(key, c)) then keys[#keys + 1] = key end
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

-- Resolve an entry's item onto it (by item ID when the line linked one, else by name):
-- recipeID, current, knownOn (the alt that knows it when the current character doesn't).
local function ResolveEntry(e)
  if indexDirty or not index then BuildIndex() end
  local r = (e.itemID and byItem[e.itemID]) or (type(e.itemName) == "string" and index[lower(e.itemName)]) or nil
  e.recipeID, e.current = r and r.recipeID, r and r.current
  e.knownOn = r and not r.current and r.char or nil
end

-- The current character can help: it knows the recipe when the ask names an item (an alt
-- knowing it isn't enough), or has the profession when the ask only names a profession.
function ChatWatch.CanHelp(entry)
  if type(entry) ~= "table" then return false end
  if entry.itemName then return entry.recipeID ~= nil and entry.current == true end
  local c = NS.Me and MyChars()[NS.Me]
  local profs = type(c) == "table" and type(c.profs) == "table" and c.profs or {}
  for id, p in pairs(profs) do
    if type(p) == "table" and p.gone then p = nil end
    if p and entry.profID and id == entry.profID then return true end
    local name = type(p) == "table" and (p.name or p[1])
    if entry.prof and name == entry.prof then return true end
  end
  return false
end

-- Display name of an entry's profession: my characters' (the client's language), else the
-- client's name for the skill line, else the English one the detector stored.
local clientProfNames = {}  -- [profID] = name or false
function ChatWatch.ProfName(entry)
  if type(entry) ~= "table" then return nil end
  local id = entry.profID
  local n = id ~= nil and NS.ProfessionName and NS.ProfessionName(id)
  if n then return n end
  if type(id) == "number" then
    if clientProfNames[id] == nil then
      clientProfNames[id] = false
      local get = C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillDisplayName
      if get then
        local ok, name = pcall(get, id)
        if ok and type(name) == "string" and name ~= "" and not (issecretvalue and issecretvalue(name)) then
          clientProfNames[id] = name
        end
      end
    end
    if clientProfNames[id] then return clientProfNames[id] end
  end
  return entry.prof
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

-- Tuning log (/cb chatdebug log): the last LOG_MAX accepted channel lines, saved. Off by
-- default; turning it off (or loading with it off) drops the saved lines.
function ChatWatch.Logging()
  return type(CraftBoardDB) == "table" and CraftBoardDB.chatlogOn == true
end

function ChatWatch.SetLogging(on)
  if type(CraftBoardDB) ~= "table" then return false end
  CraftBoardDB.chatlogOn = on and true or nil
  if not on then CraftBoardDB.chatlog = nil end
  return on and true or false
end

local function LogLine(text)
  if not ChatWatch.Logging() then
    if type(CraftBoardDB) == "table" then CraftBoardDB.chatlog = nil end
    return
  end
  local log = type(CraftBoardDB.chatlog) == "table" and CraftBoardDB.chatlog or {}
  CraftBoardDB.chatlog = log
  log[#log + 1] = NS.StripCodes(text)
  while #log > LOG_MAX do table.remove(log, 1) end
end

NS.Register("ADDON_LOADED", function(_, name)
  if name == ADDON and type(CraftBoardDB) == "table" and not ChatWatch.Logging() then CraftBoardDB.chatlog = nil end
end)

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

-- Newest first: { from="Name-Realm", text=, prof=, profID=, itemName=, itemID=, recipeID=,
-- current=, knownOn="Alt-Realm", channel="Trade", t=, first= (first time this ask was seen),
-- asks= (times seen), mats=true (brings the reagents), qty= }. Copies; entries older than
-- 30 min are gone.
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

-- My own lines (NS.IsMe: full name, or a first name when the sender has no surname).
local function IsMe(full)
  return NS.IsMe(full)
end

-- The line with its reagent phrases taken out, to read whether it calls the ask off: "I no
-- longer have mats" isn't "no longer" done, while "found someone, I no longer have mats" is.
local function WithoutMats(s)
  for _, list in ipairs({ NO_MATS, MATS }) do
    for i = 1, #list do
      local p = list[i]
      local at = s:find(p, 1, true)
      while at do
        s = s:sub(1, at - 1) .. " " .. s:sub(at + #p)
        at = s:find(p, 1, true)
      end
    end
  end
  return s
end

-- The normalized line asks for a craft, as Detect reads it: an ask phrase, or a profession asked
-- for ("need enchanter", "any lw", "enchanter needed", "LW wanted", "any first aid").
local function Asks(s)
  if Has(s, ASK) or s:find(" any first aid ", 1, true) then return true end
  local words = {}
  for w in s:gmatch("%S+") do words[#words + 1] = w end
  for i = 1, #words do
    if ProfAt(words, i) then
      local before, after = words[i - 1], words[i + 1]
      if before == "any" or before == "need" or before == "needs" or after == "needed" or after == "wanted" then
        return true
      end
    end
  end
  return false
end

-- Where the last phrase calling an ask off ("nvm", "found one", "don't need") ends in the
-- normalized line, and which phrase it is (nil: none).
local function LastCallOff(s)
  local stop, phrase = 0, nil
  for _, list in ipairs({ CANCEL, DONE }) do
    for i = 1, #list do
      local at = s:find(list[i], 1, true)
      while at do
        local e = at + #list[i] - 1
        if e > stop then stop, phrase = e, list[i] end
        at = s:find(list[i], at + 1, true)
      end
    end
  end
  return stop, phrase
end

-- The raw line after the last place a normalized phrase (" don t need ") is written in it
-- ("Don't need"), links intact, or nil.
local function RawAfter(text, phrase)
  local parts = {}
  for w in phrase:gmatch("%S+") do parts[#parts + 1] = "%f[%w]" .. w .. "%f[%W]" end
  if #parts == 0 then return nil end
  local pat = table.concat(parts, "[^%w|]+")
  local low, last = lower(text), nil
  local a, b = low:find(pat)
  while a do
    last = b
    a, b = low:find(pat, b + 1)
  end
  return last and text:sub(last + 1) or nil
end

-- Record a chat line (also the entry point for tests). Returns the stored entry or nil.
-- A later line from the same player can also drop their row ("nvm, found one") or say
-- whether they bring the reagents ("have mats" / "don't have mats") without asking again.
function ChatWatch.Add(text, sender, channel, guild)
  if not ChatWatch.Enabled() or type(text) ~= "string" or #text > MAX_LEN then return nil end
  local from = FullName(sender)
  if not from or IsMe(from) or (NS.IsIgnored and NS.IsIgnored(from)) then return nil end
  local hit = ChatWatch.Detect(text, guild)
  local prev = seen[from]
  if not (hit or prev) then return nil end
  local clean = ChatWatch.Clean(text)
  local s = Normalize(clean)
  -- "nvm found one" / "don't need an enchanter" isn't a request and drops their row, and so does
  -- a line ending on it ("LF enchanter, nvm found one"). An ask after it ("nvm, LF tailor
  -- instead", "don't need tailor, need enchanter") is a new ask, read from the words after it
  -- alone. Reagent phrases aside: "I no longer have mats" only changes whether they bring them.
  local d = WithoutMats(s)
  local stop, phrase = LastCallOff(d)
  if phrase then
    local rest = hit and Asks(" " .. d:sub(stop)) and RawAfter(text, phrase)
    hit = rest and ChatWatch.Detect(rest, guild) or nil
    if not hit then
      if prev then
        seen[from] = nil
        FireSoon()
      end
      return nil
    end
    clean = ChatWatch.Clean(rest)
    s = Normalize(clean)
  end
  if not hit then
    local said, mats = Mats(s)
    if prev and said and (prev.mats or false) ~= mats then
      prev.mats = mats or nil
      FireSoon()
    end
    return nil
  end
  local lclean = lower(clean)
  if hidden[from] then
    if hidden[from] == lclean then return nil end
    hidden[from] = nil
  end
  local now = time()
  local e = {
    from = from, text = clean, prof = hit.prof, profID = hit.profID, itemName = hit.itemName, itemID = hit.itemID,
    links = hit.links, mats = hit.mats, qty = hit.qty,
    channel = channel, guild = guild or nil, t = now, first = now, asks = 1,
  }
  -- One row per player: asking again for the same thing bumps the count and keeps when it was
  -- first seen (and what it said about quantity and reagents, unless the new line says); a
  -- different ask replaces the row.
  if prev and (prev.itemName or prev.prof) == (e.itemName or e.prof) then
    e.first, e.asks = prev.first or prev.t, (prev.asks or 1) + 1
    if not hit.matsSaid then e.mats = prev.mats end
    e.qty = e.qty or prev.qty
  end
  if hit.itemName then ResolveEntry(e) end
  -- Counted toward what is asked for around here (Stats keeps counts only, never who).
  if NS.Stats and NS.Stats.NoteDemand and e.itemID then NS.Stats.NoteDemand(e.itemID, from) end
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

-- Server channels never watched, by their static zone channel ID (the event's zoneChannelID), as
-- their names are localized: LocalDefense (22), WorldDefense (23), GuildRecruitment (25).
local NOT_WATCHED = { [22] = true, [23] = true, [25] = true }

-- "Trade - City" -> "Trade". Server channels (General, Trade, LookingForGroup...) only, never
-- defense / recruitment or custom channels.
local function PublicChannel(baseName, channelName, zoneChannelID)
  if NOT_WATCHED[zoneChannelID] then return nil end
  local base = type(baseName) == "string" and baseName ~= "" and baseName or nil
  if not base and type(channelName) == "string" then base = channelName:match("^%d+%.%s*(.+)$") or channelName end
  if not base then return nil end
  base = base:match("^(.-)%s+%-%s+.*$") or base
  if base:find("Defense", 1, true) or base:find("Recruitment", 1, true) then return nil end
  -- Forever splits channels by language and purpose: "Trade - English", "Trade (Services) -
  -- English". Match on the leading word so those all count; the server list is only used to
  -- also accept localized names it reports.
  -- The label shown in the list is the leading word ("Trade", "Général": up to a space, dash or
  -- bracket, so non-ASCII letters stay), never the full server name.
  -- Second value: the name without its " - English" / " - City" suffix (for /cb chatdebug).
  local head = base:match("^([^%s%-%(]+)") or base
  local server = ServerChannels()
  if server[base] then return head, base end
  -- A custom channel (no zone channel ID) under a server channel's name ("Trade - Guild"): not
  -- watched, unless the server lists that very name.
  if zoneChannelID == 0 then return nil end
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

-- The client's own chat type names (SAY, YELL, GUILD globals), else ours.
local function ChatTypeLabel(global, fallback)
  local v = _G[global]
  if type(v) == "string" and v ~= "" then return v end
  return fallback
end

-- /cb chatdebug counters; bases = set of accepted channel names ("Trade (Services)"), capped.
local stats = { seen = 0, channel = 0, accepted = 0, matched = 0, last = "", bases = {}, nbases = 0 }
ChatWatch.Stats = function() return stats end

local function OnChat(event, text, sender, _, channelName, _, _, zoneChannelID, _, baseName)
  stats.seen = stats.seen + 1
  if not ChatWatch.Enabled() then return end
  if Secret(text, sender) then stats.secret = (stats.secret or 0) + 1; return end
  if type(text) ~= "string" or type(sender) ~= "string" then return end
  local label, guild
  if event == "CHAT_MSG_CHANNEL" then
    stats.channel = stats.channel + 1
    if Secret(channelName, baseName) then stats.secret = (stats.secret or 0) + 1; return end
    local base
    label, base = PublicChannel(baseName, channelName, zoneChannelID)
    stats.last = tostring(baseName or channelName)
    if label then
      stats.accepted = stats.accepted + 1
      if base and not stats.bases[base] and stats.nbases < 20 then
        stats.bases[base] = true
        stats.nbases = stats.nbases + 1
      end
      LogLine(text)
    end
  elseif event == "CHAT_MSG_SAY" then
    label = ChatTypeLabel("SAY", L["Say"])
  elseif event == "CHAT_MSG_YELL" then
    label = ChatTypeLabel("YELL", L["Yell"])
  elseif event == "CHAT_MSG_GUILD" then
    if ChatWatch.GuildEnabled() then label, guild = ChatTypeLabel("GUILD", L["Guild"]), true end
  end
  if label then ChatWatch.Add(text, sender, label, guild) end
end

for _, ev in ipairs({ "CHAT_MSG_CHANNEL", "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_GUILD" }) do
  NS.Register(ev, OnChat)
end

-- My recipe names change with scans and as item names load; a recipe learned or forgotten
-- changes who can help with every row (resolved again on the next Seen). Peers' recipe lists
-- add crafted items. Players I ignore drop out.
if NS.RegisterCallback then
  NS.RegisterCallback(ChatWatch, "IGNORE_UPDATED", function()
    outputs = nil
    for k in pairs(seen) do
      if NS.IsIgnored(k) then seen[k] = nil end
    end
    FireSoon()
  end)
  NS.RegisterCallback(ChatWatch, "RECIPES_UPDATED", function()
    indexDirty, outputs = true, nil
    if next(seen) == nil then return end
    for _, e in pairs(seen) do
      e.recipeID, e.current, e.knownOn = nil, nil, nil
    end
    FireSoon()
  end)
  NS.RegisterCallback(ChatWatch, "PEERS_UPDATED", function() outputs = nil end)
  NS.RegisterCallback(ChatWatch, "ITEM_NAMES_UPDATED", function() indexDirty = true end)
end
