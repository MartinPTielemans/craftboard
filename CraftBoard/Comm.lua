-- CraftBoard Comm: sync layer over addon messages (GUILD + hidden realm CHANNEL).
-- Wire format: one type char followed by LibSerialize -> CompressDeflate -> EncodeForWoWAddonChannel.
--   H hello   {v=1, profs={[profID]={n=,r=,m=}}, n=#recipes, h=hash, b=true when busy,
--              l=true on the first hello after a login (not a /reload),
--              cd={[recipeID]=seconds until ready}}                     GUILD/CHANNEL
--             (b, l and cd are optional: older clients read only the fields they know)
--   Q query   {v=1}                                                     WHISPER to hello sender
--   R recipes {v=1, h=hash, profs=..., list={ {id, name, outputItemID, profID}, ... }}  WHISPER
--             (GUILD/CHANNEL once when several peers query at once; only those who asked take it)
--   P post    {v=1, id=, item=, qty=, note=, t=, pa=parent post id, k="m"?}  GUILD/CHANNEL
--             (pa is optional: a linked order for an intermediate of the parent request; note
--             may be "", as linked orders send it, and never carries prices; k="m": looking for
--             materials, not a craft (older clients show it as an ordinary request))
--   X retract {v=1, id=}                                                GUILD/CHANNEL
--   W who     {v=1, id=, q=lower-case text?, i={itemID,...}?}            GUILD/CHANNEL
--             ("who can craft this?", sent from a Find search; crafters who know a match answer)
--   A answer  {v=1, id=W's id, list={ {id, name, outputItemID, profID}, ... }, profs=}  WHISPER
--             (taken only for a W I sent; merged into what I know of that peer)
--             Older clients drop W and A unread (unknown kinds).
-- Scale: with more than SCALE_PEERS channel players heard in a day, channel peers' full recipe
-- lists are no longer fetched (no Q on their hellos); Find asks W instead. Guild peers always sync.
local ADDON, NS = ...

local Comm = {}
NS.Comm = Comm

local L = NS.L
local format = string.format

local PREFIX = "CBRD"
local CHANNEL_NAME = "CraftBoardF"
local VERSION = 1

local MAX_DECODED = 8192          -- compressed payload cap (bytes after DecodeForWoWAddonChannel)
local MAX_RAW = 10000             -- encoded text cap, checked before any decoding work
local MAX_INFLATED = 131072       -- decompressed cap
local MAX_RECIPES = 2000
local MAX_PROFS = 24
local MAX_NAME = 100
local MAX_NOTE = 60

local HELLO_PERIOD = 600
local HELLO_JITTER = 60
local HELLO_MIN_GAP = 540         -- per distribution; periodic jitter can fire at 9 min
local HELLO_DEBOUNCE = 30
local QUERY_GAP = 60              -- we query a given peer at most once per minute
local ANSWER_GAP = 60             -- we send our full list to a given peer at most once per minute
local QUERY_TTL = 180             -- accept an R only if we asked that peer within this window
local DEDUPE_WINDOW = 8
local ONLINE_WINDOW = 15 * 60
local PEER_TTL = 30 * 86400
local POST_TTL = 24 * 3600
local MAX_POSTS_PER_SENDER = 5
local MAX_REPEATED_X = 20         -- my retractions re-sent with each hello (the rest take turns)
local MAX_POSTS = 300
local POST_GAP = 10               -- our own post rate limit
local INBOUND_WINDOW = 60
local INBOUND_MAX = 40            -- messages per sender per window before we ignore them
local BUSY_DEBOUNCE = 5           -- a busy change is announced this long after it happens
local BUSY_MIN_GAP = 15           -- per distribution, for hellos sent only to announce busy
local MAX_PAGES = 8               -- pages of one recipe list (R)
local MAX_CD = 32                 -- cooldown entries in a hello (grouped transmutes send every ID)
local MAX_CD_SECONDS = 14 * 86400
local R_BATCH = 3                 -- this many queries within R_BATCH_WINDOW: one broadcast R
local R_BATCH_WINDOW = 10
local R_BATCH_DELAY = 2           -- a broadcast R waits this long for more queries
-- Scale: limits and state for crowded channels (kept in one table: this file is near Lua's
-- limit of 200 locals).
local scale = {
  maxPeers = 1000,                -- stored peers; the longest unheard go first
  onDemandAt = 150,               -- channel players heard within window: on-demand mode
  window = 86400,
  answersPerMin = 12,             -- full recipe lists (R) whispered per minute; more wait
  peerCount = nil,                -- stored peers (counted on first need)
  on = false, checkedAt = 0, heard = 0,
  answerTimes = {},               -- whole lists sent within the last minute
  sentSpecs = {},                 -- [dist] = specializations the last hello there carried
}

local LibSerialize = LibStub and LibStub("LibSerialize", true)
local LibDeflate = LibStub and LibStub("LibDeflate", true)
local AceComm = LibStub and LibStub("AceComm-3.0", true)

local time, type, pairs, ipairs, tostring, tonumber = time, type, pairs, ipairs, tostring, tonumber
local floor, random, min, max = math.floor, math.random, math.min, math.max
local sort = table.sort

-- Runtime state (not saved)
local channelId = nil
local lastHello = {}      -- [dist] = time
local lastHelloHash = nil
local lastHelloAt = nil
local helloPending = {}   -- [dist] = true while a deferred hello is scheduled
local queried = {}        -- [peer] = time we sent Q
local queriedHash = {}    -- [peer] = the hash that Q asked for (only its answer closes the query)
local answered = {}       -- [peer] = time we sent R
local seenMsg = {}        -- [dedupe key] = time
local inbound = {}        -- [peer] = {t=, c=}
local lastPost = 0
local postCounter = 0
local rosterCache, rosterAt = nil, 0
local started = false
local busyNow = false     -- effective busy (manual, or auto in a dungeon / in combat)
local sentBusy = {}       -- [dist] = busy flag carried by the last hello sent there
local sentCd = {}         -- [dist] = cooldown signature (CooldownSig) of the last hello sent there
local busyPending = false -- a busy hello is scheduled
local loginHello = {}     -- [dist] = true once the login hello (l=true) went out there (or after a /reload)
local backAlerted = {}    -- [peer] = time of the last back-online notice
local xRotation = 0       -- where the next hello's turn through my older retractions starts
local rawNew, rawOld, rawAt = {}, {}, 0 -- exact copies seen: [peer .. message] = time, two generations
local heardOn = {}        -- [peer] = "GUILD" / "CHANNEL": where their last broadcast reached us
local queryTimes = {}     -- arrival times of the queries answered in the last R_BATCH_WINDOW
local batch = nil         -- [peer] = dist, queriers waiting for a broadcast R
local batchAsked = {}     -- [peer] = when that querier asked (their R is only read for QUERY_TTL)
local pagesIn = {}        -- [peer] = { h=, pgs=, got={[pg]=true}, n=, recipes={}, count= }: a paged R arriving
local batchAt = nil       -- time of the last broadcast R
local peersFirePending = false
local friends, friendsFirst = nil, nil -- friend list: [Name-Realm] = online; first-name-only entries
-- Retractions not yet sent everywhere: CraftBoardDB.pendingX[post id] = { dists = {[dist]=true},
-- t= } (saved, so a reload or disconnect before the retry doesn't lose them). Retracted post ids:
-- CraftBoardDB.retracted[id] = time, so a linked order for a retracted request is dropped even
-- when its author was offline for the retraction and announces it later.
local function PendingX()
  if type(CraftBoardDB) ~= "table" then return {} end
  if type(CraftBoardDB.pendingX) ~= "table" then CraftBoardDB.pendingX = {} end
  return CraftBoardDB.pendingX
end

local function Retracted()
  if type(CraftBoardDB) ~= "table" then return {} end
  if type(CraftBoardDB.retracted) ~= "table" then CraftBoardDB.retracted = {} end
  return CraftBoardDB.retracted
end

-- My own retracted post ids ([id] = time): their X goes out again with every hello for the post
-- lifetime, like the posts themselves, so peers who were offline for it still learn of it.
local function MyRetracted()
  if type(CraftBoardDB) ~= "table" then return {} end
  if type(CraftBoardDB.myRetracted) ~= "table" then CraftBoardDB.myRetracted = {} end
  return CraftBoardDB.myRetracted
end
local pendingXTimer = false

-- Helpers ---------------------------------------------------------------

local function Print(msg)
  if NS.Print then NS.Print(msg) end
end

local function Fire(event)
  if NS.callbacks and NS.callbacks.Fire then
    pcall(NS.callbacks.Fire, NS.callbacks, event)
  end
end

-- PEERS_UPDATED once for a burst (peers coming online at login, a channel toggle).
local function FirePeersSoon()
  if peersFirePending then return end
  if not (C_Timer and C_Timer.After) then
    Fire("PEERS_UPDATED")
    return
  end
  peersFirePending = true
  C_Timer.After(1, function()
    peersFirePending = false
    Fire("PEERS_UPDATED")
  end)
end

local function DB()
  if type(CraftBoardDB) ~= "table" then return nil end
  if type(CraftBoardDB.peers) ~= "table" then CraftBoardDB.peers = {} end
  if type(CraftBoardDB.posts) ~= "table" then CraftBoardDB.posts = {} end
  if type(CraftBoardDB.recipeNames) ~= "table" then CraftBoardDB.recipeNames = {} end
  return CraftBoardDB
end

local function MyRealm()
  local r = GetNormalizedRealmName and GetNormalizedRealmName()
  if (not r or r == "") and type(NS.Realm) == "string" then
    r = NS.Realm:gsub("[%s%-]", "")
  end
  if r == "" then return nil end
  return r
end

local function MyKey()
  if not NS.Me and NS.UpdateIdentity then NS.UpdateIdentity() end
  if type(NS.Me) == "string" and NS.Me ~= "" then return NS.Me end
  return nil
end

-- AceComm hands us Ambiguate(sender, "none"): bare "Name" for same-realm senders.
-- Peers are keyed "Name-Realm" so they line up with NS.Me and guild roster names.
local function FullName(name)
  if type(name) ~= "string" or name == "" or #name > 64 then return nil end
  -- Forever names contain a space ("Raion Lyzl"); reject only markup and control characters.
  if name:find("|", 1, true) or name:find("%c") then return nil end
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then return nil end
  if not name:find("-", 1, true) then
    local realm = MyRealm()
    if not realm then return nil end
    name = name .. "-" .. realm
  end
  return name
end

local function ShortName(full)
  if Ambiguate then return Ambiguate(full, "none") end
  return full
end

-- Me, by full name (NS.IsMe; a first name only matches a source without surnames).
local function IsMe(full)
  if not full then return true end
  return NS.IsMe(full)
end

-- Strip WoW escape sequences ("|c", "|H", "|T"...) from anything a peer sends us.
-- s cut to at most maxBytes bytes without splitting a UTF-8 character.
local function CutBytes(s, maxBytes)
  if #s <= maxBytes then return s end
  local i = maxBytes
  while i > 0 do
    local b = s:byte(i + 1) or 0
    if b < 128 or b >= 192 then break end   -- the next byte starts a character: cut here
    i = i - 1
  end
  return s:sub(1, i)
end

-- s cut to at most maxChars UTF-8 characters.
local function CutChars(s, maxChars)
  local n, i = 0, 1
  while i <= #s do
    n = n + 1
    if n > maxChars then return s:sub(1, i - 1) end
    local c = s:byte(i)
    i = i + (c < 0x80 and 1 or c < 0xE0 and 2 or c < 0xF0 and 3 or 4)
  end
  return s
end

local function CleanString(s, maxLen)
  if type(s) ~= "string" then return nil end
  s = NS.StripCodes(s):gsub("|", ""):gsub("%c", "")
  return CutBytes(s, maxLen)
end

-- Prices off a post note ("5g", "50 s", "1.5g", "10 gold", "50 silver", "25c", "gold", the
-- number in "tip 5"), trimmed: the board carries no gold amounts. "will tip" stays, and so do
-- item names ("20 copper bars", "gold ore", "Silver Rod").
local COIN = { g = true, s = true, c = true, gold = true, silver = true, copper = true,
  -- The other shipped languages' coin words (a note can come from any client).
  silber = true, kupfer = true, argent = true, cuivre = true, oro = true, plata = true, cobre = true }
-- The client's own coin words and symbols ("%d Gold", "g"; "%d or", "po" on French clients).
for _, key in ipairs({ "GOLD_AMOUNT", "SILVER_AMOUNT", "COPPER_AMOUNT",
  "GOLD_AMOUNT_SYMBOL", "SILVER_AMOUNT_SYMBOL", "COPPER_AMOUNT_SYMBOL" }) do
  local v = _G[key]
  if type(v) == "string" then
    local w = v:gsub("|T.-|t", ""):gsub("%%%d*%$?d", ""):match("^%s*(.-)%s*$")
    if w and w ~= "" and not w:find("[%s%%]") and w:find("^%a+$") then COIN[w:lower()] = true end
  end
end
-- "tip 5" in each shipped language: the amount goes, the word stays.
local TIP = { tip = true, tips = true, trinkgeld = true, pourboire = true, propina = true }
local METAL_ITEM = { bar = true, bars = true, ore = true, ores = true, rod = true, rods = true, tube = true,
  tubes = true, wire = true, nugget = true, nuggets = true, powder = true, dust = true, ring = true,
  rings = true, band = true, bands = true, necklace = true, pendant = true }

local function StripPrices(s)
  s = " " .. s .. " "
  -- The coin word starts an item's name: a metal item follows ("copper bars"), or it is written
  -- as a name, capitalized and followed by another capitalized word ("2 Gold Power Cores").
  local function ItemAfter(pos, word)
    local nxt = s:match("^%s*(%a+)", pos)
    if nxt == nil then return false end
    if METAL_ITEM[nxt:lower()] then return true end
    return #word > 1 and word:match("^%u") ~= nil and nxt:match("^%u") ~= nil
  end
  s = s:gsub("(%d+[%.,]?%d*)%s*(%a+)()", function(_, unit, pos)
    if COIN[unit:lower()] and not ItemAfter(pos, unit) then return " " end
  end)
  s = s:gsub("%f[%a]([gG][oO][lL][dD])%f[%A]()", function(word, pos)
    if not ItemAfter(pos, word) then return " " end
  end)
  s = s:gsub("%f[%a](%a+)%s*:?%s*%d+[%.,]?%d*", function(word)
    if TIP[word:lower()] then return word .. " " end
  end)
  s = s:gsub("%(%s*%)", " ")
  s = s:gsub("%s+", " "):gsub(" ([,;:%.!%?%)])", "%1")
    :gsub("^[%s,;:%-%+/&]+", ""):gsub("[%s,;:%-%+/&]+$", "")
  return s
end
Comm.StripPrices = StripPrices

local function PosInt(x, maxV)
  if type(x) ~= "number" or x ~= x or x < 1 or x > maxV or floor(x) ~= x then return nil end
  return x
end

local function CountTable(t)
  local c = 0
  if type(t) == "table" then for _ in pairs(t) do c = c + 1 end end
  return c
end

local function InGuild()
  return IsInGuild and IsInGuild() and true or false
end

-- Addon messages may be blocked in combat/encounters on modern clients: defer instead of failing.
local function CanSend()
  if InCombatLockdown and InCombatLockdown() then return false end
  if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
    local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
    if ok and locked then return false end
  end
  return true
end

-- Encoding --------------------------------------------------------------

local function Encode(tbl)
  if not (LibSerialize and LibDeflate) then return nil end
  local ser = LibSerialize:Serialize(tbl)
  if not ser then return nil end
  local comp = LibDeflate:CompressDeflate(ser)
  if not comp then return nil end
  return LibDeflate:EncodeForWoWAddonChannel(comp), #comp
end

-- An encoded message the receiver's Decode accepts: compressed within MAX_DECODED and the text
-- within MAX_RAW.
local function Fits(text, size)
  return type(text) == "string" and type(size) == "number" and size <= MAX_DECODED and #text <= MAX_RAW
end

local function Decode(text)
  if not (LibSerialize and LibDeflate) then return nil end
  if type(text) ~= "string" or #text > MAX_RAW then return nil end
  local comp = LibDeflate:DecodeForWoWAddonChannel(text)
  if not comp or #comp > MAX_DECODED then return nil end
  local ser = LibDeflate:DecompressDeflate(comp)
  if type(ser) ~= "string" or #ser > MAX_INFLATED then return nil end
  local ok, val = LibSerialize:Deserialize(ser)
  if not ok or type(val) ~= "table" then return nil end
  if val.v ~= VERSION then return nil end
  return val
end

-- Channel ---------------------------------------------------------------

local function ResolveChannel()
  if not GetChannelName then channelId = nil; return nil end
  local id = GetChannelName(CHANNEL_NAME)
  if type(id) == "number" and id > 0 then channelId = id else channelId = nil end
  return channelId
end

local function HideChannelFromChat()
  local remove = ChatFrame_RemoveChannel
    or (ChatFrameUtil and ChatFrameUtil.RemoveChannel)
  if not remove then return end
  local n = NUM_CHAT_WINDOWS or 10
  for i = 1, n do
    local f = _G["ChatFrame" .. i]
    if f then pcall(remove, f, CHANNEL_NAME) end
  end
  if DEFAULT_CHAT_FRAME then pcall(remove, DEFAULT_CHAT_FRAME, CHANNEL_NAME) end
end

-- Swallow "Joined/Left channel" notices and any stray text typed into our channel.
local function InstallChatFilter()
  local add = ChatFrame_AddMessageEventFilter
    or (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter)
  if not add then return end
  local function filter(_, _, _, _, _, channelString, _, _, _, _, baseName)
    if baseName == CHANNEL_NAME then return true end
    if type(channelString) == "string" and channelString:find(CHANNEL_NAME, 1, true) then return true end
    return false
  end
  pcall(add, "CHAT_MSG_CHANNEL_NOTICE", filter)
  pcall(add, "CHAT_MSG_CHANNEL_NOTICE_USER", filter)
  pcall(add, "CHAT_MSG_CHANNEL", filter)
end

local function RealmChannelOn()
  local db = DB()
  return db and db.realmChannel and true or false
end

-- Options "Share recipes with my guild": only an explicit false turns GUILD sends off.
local function GuildShareOn()
  local db = DB()
  return not (db and db.guildShare == false)
end

local SendHello -- forward

-- urgent: the player just turned sharing on: the channel hears me at once (not after the gap
-- between hellos).
local function JoinRealmChannel(attempt, urgent)
  attempt = attempt or 1
  if not RealmChannelOn() then return end
  if ResolveChannel() then
    HideChannelFromChat()
    if urgent and started then SendHello("CHANNEL", nil, true) end
    return
  end
  if JoinChannelByName then pcall(JoinChannelByName, CHANNEL_NAME) end
  C_Timer.After(2, function()
    if ResolveChannel() then
      HideChannelFromChat()
      FirePeersSoon()
      -- Login hello may have gone out to GUILD only because the channel wasn't ready yet.
      if started then SendHello("CHANNEL", nil, urgent) end
    elseif attempt < 5 then
      C_Timer.After(10, function() JoinRealmChannel(attempt + 1, urgent) end)
    end
  end)
end

-- Sending ---------------------------------------------------------------

local commObj = {}
if AceComm then
  AceComm:Embed(commObj)
end

local function Send(kind, payload, dist, target, prio)
  if not commObj.SendCommMessage then return false end
  if dist ~= "GUILD" and dist ~= "CHANNEL" and dist ~= "WHISPER" then return false end
  local text = Encode(payload)
  if not text then return false end
  local ok = pcall(commObj.SendCommMessage, commObj, PREFIX, kind .. text, dist, target, prio or "NORMAL")
  return ok
end

-- Broadcast to every active distribution. Returns list of distributions used.
local function Broadcast(kind, payload, prio)
  if not CanSend() then return {} end
  local used = {}
  if InGuild() and GuildShareOn() then
    if Send(kind, payload, "GUILD", nil, prio) then used[#used + 1] = "GUILD" end
  end
  if RealmChannelOn() and ResolveChannel() then
    if Send(kind, payload, "CHANNEL", channelId, prio) then used[#used + 1] = "CHANNEL" end
  end
  return used
end

-- Only recipes whose output can be handed to someone else (no Bind on Pickup / quest items):
-- this set drives hello n, the R list and (via Recipes.Hash) the hash.
local function MyRecipes()
  local R = NS.Recipes
  local get = R and (R.Shareable or R.Mine)
  if get then
    local ok, t = pcall(get)
    if ok and type(t) == "table" then return t end
  end
  return {}
end

local function MyHash()
  local R = NS.Recipes
  if R and R.Hash then
    local ok, h = pcall(R.Hash, MAX_RECIPES)
    if ok and h ~= nil then return tostring(h) end
  end
  return "0:" .. min(CountTable(MyRecipes()), MAX_RECIPES)
end

local function MyProfs()
  local db, me = DB(), MyKey()
  local out = {}
  local c = db and me and type(db.chars) == "table" and db.chars[me]
  local profs = type(c) == "table" and c.profs
  if type(profs) == "table" then
    for id, p in pairs(profs) do
      -- Recipes stores profs positionally: { name, rank, max }; unlearned ones (gone) aren't sent.
      if type(id) == "number" and type(p) == "table" and not p.gone then
        out[id] = { n = p.name or p[1], r = p.rank or p[2], m = p.max or p[3] }
      end
    end
  end
  return out
end

local function DistAvailable(dist)
  if dist == "GUILD" then return InGuild() and GuildShareOn() end
  if dist == "CHANNEL" then return RealmChannelOn() and ResolveChannel() ~= nil end
  return false
end

local SendMyPosts -- forward
local SendPost    -- forward

-- My crafting cooldowns as the hello carries them, reduced to what peers act on: ready or not,
-- and when it will be (to the quarter hour). A cast or a newly tracked cooldown changes it; the
-- clock running down doesn't (peers count that down themselves).
local function CooldownSig()
  local cd = NS.Cooldowns and NS.Cooldowns.ForHello and NS.Cooldowns.ForHello(MAX_CD)
  if type(cd) ~= "table" then return "" end
  local ids, now = {}, time()
  for id in pairs(cd) do ids[#ids + 1] = id end
  sort(ids)
  for i, id in ipairs(ids) do
    local sec = cd[id]
    ids[i] = id .. (sec == 0 and "r" or (":" .. floor((now + sec) / 900)))
  end
  return table.concat(ids, ",")
end

-- Specializations in the hello (sp): my current character's, as a list of spell IDs (nil: none).
function Comm.MySpecs()
  local db, me = DB(), MyKey()
  local c = db and me and type(db.chars) == "table" and db.chars[me]
  local list = NS.Skills and NS.Skills.SpecList and type(c) == "table" and NS.Skills.SpecList(c.specs) or {}
  return #list > 0 and list or nil
end

-- A peer's sp, kept to known specializations: { [spellID] = true } or nil.
function Comm.ReadSpecs(sp)
  if type(sp) ~= "table" or not (NS.Skills and NS.Skills.SPECS) then return nil end
  local out, n = {}, 0
  for k = 1, 8 do
    local id = PosInt(sp[k], 1e7)
    if id and NS.Skills.SPECS[id] then out[id], n = true, n + 1 end
  end
  return n > 0 and out or nil
end

function Comm.SpecKey(set)
  return NS.Skills and NS.Skills.SpecList and table.concat(NS.Skills.SpecList(set), ",") or ""
end

-- Announce a busy or cooldown change on every distribution whose last hello carried the other
-- state (a quick hello: see SendHello's busy argument).
local function StateFlush()
  busyPending = false
  local sig, specs = CooldownSig(), table.concat(Comm.MySpecs() or {}, ",")
  for _, dist in ipairs({ "GUILD", "CHANNEL" }) do
    if DistAvailable(dist) and ((sentBusy[dist] or false) ~= busyNow or (sentCd[dist] or "") ~= sig
      or (scale.sentSpecs[dist] or "") ~= specs) then
      SendHello(dist, true)
    end
  end
end

local function ScheduleStateFlush(delay)
  if busyPending or not (C_Timer and C_Timer.After) then return end
  busyPending = true
  C_Timer.After(delay, StateFlush)
end

-- Hello per distribution, rate-limited per spec (<= 1 per ~10 min per distribution).
-- If we're inside the gap, schedule one deferred hello instead of dropping it.
-- busy: sent to announce a busy change, allowed every BUSY_MIN_GAP instead.
-- urgent: skip the ordinary gap between hellos (a one-off recovery, not the periodic hello).
function SendHello(dist, busy, urgent)
  if not dist then
    SendHello("GUILD", busy, urgent)
    SendHello("CHANNEL", busy, urgent)
    return
  end
  if not DistAvailable(dist) then return end
  local now = time()
  local last = lastHello[dist]
  if busy then
    local wait = 0
    if last and now - last < BUSY_MIN_GAP then
      wait = BUSY_MIN_GAP - (now - last) + 1
    elseif not CanSend() then
      wait = 30
    end
    if wait > 0 then
      ScheduleStateFlush(wait)
      return
    end
  elseif last and now - last < HELLO_MIN_GAP and not urgent then
    if not helloPending[dist] then
      helloPending[dist] = true
      C_Timer.After(HELLO_MIN_GAP - (now - last) + 1, function()
        helloPending[dist] = nil
        SendHello(dist)
      end)
    end
    return
  end
  if not CanSend() then
    -- An urgent hello waits on its own (an ordinary one may already be waiting out the gap).
    local key = urgent and ("urgent:" .. dist) or dist
    if not helloPending[key] then
      helloPending[key] = true
      C_Timer.After(30, function()
        helloPending[key] = nil
        SendHello(dist, busy, urgent)
      end)
    end
    return
  end
  local h = MyHash()
  -- n must match the count part of h ("count:poly") so peers' empty-book shortcut is right.
  local n = tonumber(h:match("^(%d+):")) or min(CountTable(MyRecipes()), MAX_RECIPES)
  local payload = { v = VERSION, profs = MyProfs(), n = n, h = h, b = busyNow or nil,
    l = not loginHello[dist] or nil, cd = NS.Cooldowns and NS.Cooldowns.ForHello and NS.Cooldowns.ForHello(MAX_CD) or nil,
    pg = 1, sp = Comm.MySpecs() }
  local target = dist == "CHANNEL" and channelId or nil
  if Send("H", payload, dist, target, "BULK") then
    lastHello[dist] = now
    lastHelloAt = now
    lastHelloHash = h
    sentBusy[dist] = busyNow
    sentCd[dist] = CooldownSig()
    scale.sentSpecs[dist] = table.concat(payload.sp or {}, ",")
    loginHello[dist] = true
    -- A busy-only hello doesn't repeat the posts, unless it is the first hello there.
    if not busy or not last then SendMyPosts(dist) end
  end
end

local function BuildRecipeList(withNames)
  local mine = MyRecipes()
  local ids = {}
  for id in pairs(mine) do
    if type(id) == "number" then ids[#ids + 1] = id end
  end
  sort(ids)
  local list = {}
  for i = 1, min(#ids, MAX_RECIPES) do
    local id = ids[i]
    local r = mine[id]
    local name = withNames and type(r) == "table" and type(r.n) == "string" and r.n:sub(1, MAX_NAME) or false
    local o = type(r) == "table" and type(r.o) == "number" and r.o or false
    local p = type(r) == "table" and type(r.p) == "number" and r.p or false
    -- Where it is learned (5th field; older clients read the first four).
    local src = NS.Recipes and NS.Recipes.SourceOf and NS.Recipes.SourceOf(id) or nil
    list[i] = { id, name, o, p, src }
  end
  return list
end

-- R must fit MAX_DECODED on the receiver: first try with names, then without
-- (receivers can still resolve the output item's name), then truncate.
-- dist: "WHISPER" (to = the querier) or, for a batch of queriers, "GUILD" / "CHANNEL".
-- A list too big for one message goes out in pages (pg = 1..pgs, each within MAX_DECODED; names
-- kept). The receiver stores the list, under this hash, only once every page is in: a partial
-- list must never carry the full set's hash, or the missing recipes would never be asked for.
-- A list that fits is sent exactly as before (no page fields), so older clients read it as ever.
-- paged: the receiver announced it reads pages (hello pg=1). Pages only ever go by whisper to
-- such a peer: an older client would store the first page as the whole list. Older clients get
-- the single message they always got (names dropped, then trimmed to fit, as 0.9 did: all they
-- can hold), and a list too big for one message isn't broadcast at all (FlushBatch then whispers
-- each querier).
local function SendRecipes(dist, to, paged)
  if not commObj.SendCommMessage then return false end
  if dist == "CHANNEL" then to = channelId end
  local h, profs, list = MyHash(), MyProfs(), BuildRecipeList(true)
  local text, size = Encode({ v = VERSION, h = h, profs = profs, list = list })
  if not text then return false end
  if Fits(text, size) then
    return (pcall(commObj.SendCommMessage, commObj, PREFIX, "R" .. text, dist, to, "BULK"))
  end
  if dist ~= "WHISPER" then return false end
  if not paged then
    local payload = { v = VERSION, h = h, profs = profs, list = BuildRecipeList(false) }
    text, size = Encode(payload)
    -- Trimmed, it still carries the full hash: an older client can only ever hold one message,
    -- so asking again would bring back the same list with every hello and never the rest.
    while text and not Fits(text, size) and #payload.list > 1 do
      local keep = floor(#payload.list * 0.75)
      for k = #payload.list, keep + 1, -1 do payload.list[k] = nil end
      text, size = Encode(payload)
    end
    return Fits(text, size) and (pcall(commObj.SendCommMessage, commObj, PREFIX, "R" .. text, dist, to, "BULK")) or false
  end
  -- Pages: as many list entries as fit, the first page also carrying the professions. Sized with
  -- the largest page numbers, then every page is encoded as sent and checked again; a page that
  -- still doesn't fit makes the pages smaller and the whole list is paged again.
  local function Paginate(per)
    local pages, i = {}, 1
    while i <= #list do
      local n = min(per, #list - i + 1)
      local chunk, ptext, psize
      repeat
        chunk = {}
        for k = i, i + n - 1 do chunk[#chunk + 1] = list[k] end
        ptext, psize = Encode({ v = VERSION, h = h, profs = #pages == 0 and profs or nil, list = chunk,
          pg = MAX_PAGES, pgs = MAX_PAGES })
        if not Fits(ptext, psize) and n > 1 then n = max(1, floor(n * 0.75)) else break end
      until false
      if not ptext then return nil end
      pages[#pages + 1] = chunk
      i = i + n
      if #pages > MAX_PAGES then return nil end
    end
    return pages
  end
  local per = max(1, floor(#list * MAX_DECODED / size * 0.8))
  for _ = 1, 3 do
    local pages = Paginate(per)
    if not pages then return false end
    local texts = {}
    for pg, chunk in ipairs(pages) do
      local ptext, psize = Encode({ v = VERSION, h = h, profs = pg == 1 and profs or nil, list = chunk, pg = pg, pgs = #pages })
      if not Fits(ptext, psize) then texts = nil break end
      texts[pg] = ptext
    end
    if texts then
      for _, ptext in ipairs(texts) do
        if not pcall(commObj.SendCommMessage, commObj, PREFIX, "R" .. ptext, dist, to, "BULK") then return false end
      end
      return true
    end
    per = max(1, floor(per * 0.75))
  end
  return false
end

-- Peers -----------------------------------------------------------------

-- Any message marks the peer as seen now. One who wasn't seen within ONLINE_WINDOW just came
-- online: PEERS_UPDATED, so "N crafters online" and the green names follow.
-- Peers' online state as last checked ([full] = true/false; CheckOnline, below), and until when
-- (after my login) a change isn't news: the roster and friend list are still filling in.
local lastOnline = {}
local quietUntil = math.huge
local OnlineNow -- forward: a peer's online state as shown (roster, friends, last heard)

-- At maxPeers, the peer heard from longest ago makes room for a new one.
function scale.MakeRoom(db)
  -- Counted again before anyone goes (the peers may have been forgotten in the settings).
  if not scale.peerCount or scale.peerCount >= scale.maxPeers then
    scale.peerCount = 0
    for _ in pairs(db.peers) do scale.peerCount = scale.peerCount + 1 end
  end
  while scale.peerCount >= scale.maxPeers do
    local oldest, oldestT
    for name, p in pairs(db.peers) do
      local t = type(p) == "table" and type(p.seen) == "number" and p.seen or 0
      if not oldestT or t < oldestT then oldest, oldestT = name, t end
    end
    if not oldest then scale.peerCount = 0 break end
    db.peers[oldest] = nil
    scale.peerCount = scale.peerCount - 1
  end
end

local function Touch(full)
  local db = DB()
  if not db then return nil end
  local p = db.peers[full]
  if type(p) ~= "table" then
    scale.MakeRoom(db)
    p = { recipes = {}, profs = {} }
    db.peers[full] = p
    scale.peerCount = (scale.peerCount or 0) + 1
  end
  if type(p.recipes) ~= "table" then p.recipes = {} end
  if type(p.profs) ~= "table" then p.profs = {} end
  local now = time()
  if not (type(p.seen) == "number" and now - p.seen < ONLINE_WINDOW) then FirePeersSoon() end
  p.seen = now
  -- Their state as shown now (the roster or friend list may still say offline; its update to
  -- online is then the change CheckOnline reports).
  local on = true
  if OnlineNow then on = OnlineNow(full, p) end
  if lastOnline[full] ~= nil and lastOnline[full] ~= on then FirePeersSoon() end
  lastOnline[full] = on
  return p
end

-- "165:111:150:Leatherworking,...": a peer's professions, to tell whether they changed (a new
-- client language renames them).
local function ProfsKey(t)
  local parts = {}
  for id, v in pairs(type(t) == "table" and t or {}) do
    if type(v) == "table" then
      parts[#parts + 1] = tostring(id) .. ":" .. tostring(v.rank) .. ":" .. tostring(v.max) .. ":" .. tostring(v.name)
    end
  end
  sort(parts)
  return table.concat(parts, ",")
end

local function CleanProfs(t)
  if type(t) ~= "table" then return nil end
  local out, c = {}, 0
  for id, v in pairs(t) do
    if c >= MAX_PROFS then break end
    if PosInt(id, 1e6) then
      if type(v) == "number" then
        out[id] = { rank = v }
        c = c + 1
      elseif type(v) == "table" then
        out[id] = {
          name = CleanString(v.n, 40),
          rank = type(v.r) == "number" and v.r or nil,
          max = type(v.m) == "number" and v.m or nil,
        }
        c = c + 1
      end
    end
  end
  return out
end

local function PrunePeers()
  local db = DB()
  if not db then return end
  local cutoff = time() - PEER_TTL
  for name, p in pairs(db.peers) do
    -- IsMe also drops entries an older build stored for my own character.
    if type(p) ~= "table" or type(p.seen) ~= "number" or p.seen < cutoff or IsMe(name) then
      db.peers[name] = nil
    end
  end
  scale.peerCount = nil
end

local function GuildRoster()
  local now = time()
  if rosterCache and now - rosterAt < 30 then return rosterCache end
  rosterCache, rosterAt = {}, now
  if not (InGuild() and GetNumGuildMembers and GetGuildRosterInfo) then return rosterCache end
  local n = GetNumGuildMembers() or 0
  for i = 1, n do
    local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
    if type(name) == "string" then
      local full = FullName(name)
      if full then rosterCache[full] = online and true or false end
    end
  end
  return rosterCache
end

-- The friend list, read once per FRIENDLIST_UPDATE: friends[Name-Realm] = online, and
-- friendsFirst for entries listed by first name only (they match "First Surname" on the same
-- realm, NS.SamePlayer's rule).
local function Friends()
  if friends then return friends, friendsFirst end
  friends, friendsFirst = {}, {}
  local FL = C_FriendList
  if not (FL and FL.GetNumFriends and FL.GetFriendInfoByIndex) then return friends, friendsFirst end
  local okN, n = pcall(FL.GetNumFriends)
  if not okN or type(n) ~= "number" then return friends, friendsFirst end
  for i = 1, min(n, 1000) do
    local ok, info = pcall(FL.GetFriendInfoByIndex, i)
    local name = ok and type(info) == "table" and info.name
    if type(name) == "string" and not (issecretvalue and issecretvalue(name)) then
      local full = FullName(name)
      if full then
        local on = info.connected and true or false
        friends[full] = on
        if not full:find(" ", 1, true) then friendsFirst[full] = on end
      end
    end
  end
  return friends, friendsFirst
end


-- true / false when the friend list knows the player, else nil.
local function FriendOnline(full)
  local all, firstOnly = Friends()
  local on = all[full]
  if on == nil then
    local first, realm = full:match("^(%S+) [^%-]*%-(.+)$")
    if first then on = firstOnly[first .. "-" .. realm] end
  end
  return on
end

-- Online: heard from within ONLINE_WINDOW, overridden by the guild roster, else the friend
-- list, when they know the answer.
local function OnlineOf(full, p, roster, now)
  local r = roster[full]
  if r ~= nil then return r end
  local f = FriendOnline(full)
  if f ~= nil then return f end
  return type(p) == "table" and type(p.seen) == "number" and now - p.seen < ONLINE_WINDOW or false
end

-- A change of online state nobody sends a message about (a friend or guild member logging on or
-- off, a peer not heard from within ONLINE_WINDOW) fires PEERS_UPDATED, so the request count,
-- badges and Find's order follow.
function OnlineNow(full, p)
  return OnlineOf(full, p, GuildRoster(), time()) and true or false
end

local function CheckOnline()
  local db = DB()
  if not (db and type(db.peers) == "table") then return end
  local roster, now, current, changed = GuildRoster(), time(), {}, false
  local back = {}
  for full, p in pairs(db.peers) do
    local on = OnlineOf(full, p, roster, now) and true or false
    current[full] = on
    if lastOnline[full] ~= nil and lastOnline[full] ~= on then
      changed = true
      if on then back[#back + 1] = full end
    end
  end
  lastOnline = current
  if changed then FirePeersSoon() end
  -- Came online by the friend list or roster, with or without a login hello (their addon off,
  -- sharing off): the back-online notice (it checks for a request and rate-limits itself).
  if now >= quietUntil then
    for _, full in ipairs(back) do Comm.NoteBackOnline(full) end
  end
end

local checkOnlinePending = false
local function CheckOnlineSoon()
  if checkOnlinePending or not (C_Timer and C_Timer.After) then return end
  checkOnlinePending = true
  C_Timer.After(2, function()
    checkOnlinePending = false
    CheckOnline()
  end)
end

if NS.Register then
  NS.Register("FRIENDLIST_UPDATE", function()
    friends, friendsFirst = nil, nil
    CheckOnlineSoon()
  end)
  NS.Register("GUILD_ROSTER_UPDATE", function()
    rosterCache = nil
    CheckOnlineSoon()
    if C_Timer and C_Timer.After then C_Timer.After(2, function() scale.ReconcileGuild() end) end
  end)
end

-- One player's online state (a board post's author, a crafter), as Comm.Peers() would say it.
function Comm.IsOnline(name)
  local full = FullName(name)
  if not full then return false end
  if IsMe(full) then return true end
  local db = DB()
  return OnlineOf(full, db and db.peers[full], GuildRoster(), time()) and true or false
end

-- On-demand mode: more channel players heard within scale.window (guildmates aside) than full
-- recipe lists can be swapped with. Counted at most once a minute.
function Comm.OnDemand()
  local now = time()
  if now - scale.checkedAt < 60 then return scale.on end
  scale.checkedAt = now
  local db = DB()
  local roster, n = GuildRoster(), 0
  for full, p in pairs(db and db.peers or {}) do
    if type(p) == "table" and type(p.ch) == "number" and now - p.ch < scale.window and roster[full] == nil then
      n = n + 1
    end
  end
  scale.heard = n
  scale.on = n > scale.onDemandAt or (type(CraftBoardDB) == "table" and CraftBoardDB.forceOnDemand == true)
  return scale.on
end

-- A channel player heard now. One not heard within the window adds to the count at once, so a
-- burst of hellos turns on-demand mode on mid-burst instead of a minute later.
function scale.Heard(full)
  local p = Touch(full)
  if not p then return end
  local now = time()
  local fresh = type(p.ch) == "number" and now - p.ch < scale.window
  p.ch = now
  if fresh or GuildRoster()[full] ~= nil then return end
  scale.heard = scale.heard + 1
  if scale.heard > scale.onDemandAt then scale.on = true end
end

-- Count again on the next question (the forced mode was toggled).
function Comm.RecheckScale() scale.checkedAt = 0 end

-- A peer whose full recipe list isn't fetched in on-demand mode: heard on the channel, not a
-- guildmate.
function scale.Peer(full)
  return heardOn[full] == "CHANNEL" and GuildRoster()[full] == nil and Comm.OnDemand()
end

-- A peer's cooldowns as stored ([recipeID] = time ready; read only), nil if unknown or ignored.
-- Cheaper than Comm.Peers() for one crafter.
function Comm.PeerCooldowns(name)
  local db, full = DB(), FullName(name)
  if not (db and full) or (NS.IsIgnored and NS.IsIgnored(full)) then return nil end
  local p = db.peers[full]
  return type(p) == "table" and type(p.cd) == "table" and p.cd or nil
end

-- A member of my guild (by the roster, which knows offline members too).
function Comm.IsGuildmate(name)
  local full = FullName(name)
  return full ~= nil and GuildRoster()[full] ~= nil
end

-- One peer as Comm.Peers() would give it (nil if unknown or ignored), without copying them all.
function Comm.Peer(name)
  local db, full = DB(), FullName(name)
  if not (db and full) or (NS.IsIgnored and NS.IsIgnored(full)) then return nil end
  local p = db.peers[full]
  if type(p) ~= "table" then return nil end
  local online = OnlineOf(full, p, GuildRoster(), time())
  -- partial: on demand, their recipes are only what searches brought in.
  return { recipes = p.recipes or {}, profs = p.profs or {}, seen = p.seen, online = online and true or false,
    busy = online and p.busy and true or false, cd = p.cd, specs = p.specs,
    partial = (p.odHash ~= nil or scale.Peer(full)) and true or nil }
end

-- Returns a copy of the stored peers with `online` derived from last message time,
-- overridden by guild roster / friend list when they know the answer.
function Comm.Peers()
  local db = DB()
  local out = {}
  if not db then return out end
  local now = time()
  local roster = GuildRoster()
  for name, p in pairs(db.peers) do
    if type(p) == "table" and not (NS.IsIgnored and NS.IsIgnored(name)) then
      local online = OnlineOf(name, p, roster, now)
      out[name] = {
        recipes = p.recipes or {},
        profs = p.profs or {},
        seen = p.seen,
        hash = p.hash,
        online = online and true or false,
        -- Busy only means something while online (an offline peer's last flag is stale).
        busy = online and p.busy and true or false,
        cd = p.cd,
        specs = p.specs,
      }
    end
  end
  return out
end

-- Posts -----------------------------------------------------------------

local RetractMine -- forward (Retracting, below)

local function PrunePosts()
  local db = DB()
  if not db then return end
  local cutoff = time() - POST_TTL
  local gone = {}
  for id, p in pairs(db.posts) do
    if type(p) ~= "table" or type(p.t) ~= "number" or p.t < cutoff then
      db.posts[id] = nil
      gone[id] = true
      -- Tombstoned too: a linked order of it that reaches me later is dropped on arrival.
      Retracted()[id] = Retracted()[id] or time()
    end
  end
  -- A linked order goes with its expired parent (however deep the chain): mine are retracted for
  -- everyone, other players' are dropped here.
  local me, more = MyKey(), next(gone) ~= nil
  while more do
    more = false
    for id, p in pairs(db.posts) do
      if type(p) == "table" and p.pa ~= nil and gone[p.pa] then
        db.posts[id], gone[id], more = nil, true, true
        if p.from == me and RetractMine then RetractMine(id, p.sentTo) end
      end
    end
  end
  for _, tomb in ipairs({ Retracted(), MyRetracted() }) do
    for id, t in pairs(tomb) do
      if type(t) ~= "number" or t < cutoff then tomb[id] = nil end
    end
  end
  if type(db.offered) == "table" then
    for id in pairs(db.offered) do
      if not db.posts[id] then db.offered[id] = nil end
    end
  end
end

local function PostList()
  PrunePosts()
  local db = DB()
  local list = {}
  if not db then return list end
  for _, p in pairs(db.posts) do
    if not (p.from and NS.IsIgnored and NS.IsIgnored(p.from)) then list[#list + 1] = p end
  end
  sort(list, function(a, b) return (a.t or 0) > (b.t or 0) end)
  return list
end

-- Posts are re-sent alongside each hello so players who log in later still see them.
function SendMyPosts(dist)
  local db, me = DB(), MyKey()
  if not (db and me) then return end
  local now = time()
  -- My retractions still within the post lifetime all stay; each hello repeats the newest half
  -- of MAX_REPEATED_X and a rotating share of the older ones, so the burst stays bounded and
  -- every tombstone keeps reaching peers who were away.
  local live = {}
  for id, t in pairs(MyRetracted()) do
    if type(t) == "number" and now - t < POST_TTL then live[#live + 1] = { id = id, t = t } end
  end
  sort(live, function(a, b)
    if a.t ~= b.t then return a.t > b.t end
    return a.id < b.id
  end)
  local newest = floor(MAX_REPEATED_X / 2)
  local send = {}
  for i = 1, min(#live, newest) do send[#send + 1] = live[i].id end
  local older = #live - newest
  if older > 0 then
    for k = 0, min(older, MAX_REPEATED_X - newest) - 1 do
      send[#send + 1] = live[newest + 1 + (xRotation + k) % older].id
    end
    xRotation = (xRotation + MAX_REPEATED_X - newest) % older
  end
  for _, id in ipairs(send) do
    Send("X", { v = VERSION, id = id }, dist, dist == "CHANNEL" and channelId or nil, "BULK")
  end
  -- Then the live posts: a peer still holding retracted ones at the per-sender limit has room
  -- for them once the retractions above are in.
  for id, p in pairs(db.posts) do
    if type(p) == "table" and p.from == me and type(p.t) == "number" and now - p.t < POST_TTL then
      local target = dist == "CHANNEL" and channelId or nil
      if Send("P", { v = VERSION, id = id, item = p.item, qty = p.qty, note = p.note, t = p.t, pa = p.pa, k = p.k }, dist, target, "BULK") then
        p.sentTo = p.sentTo or {}
        p.sentTo[dist] = true
      end
    end
  end
end

function Comm.Requests()
  return PostList()
end

-- My open posts (expired ones pruned first).
local function MyOpenPosts()
  PrunePosts()
  local db, me = DB(), MyKey()
  local open = 0
  if not (db and me) then return open end
  for _, p in pairs(db.posts) do
    if type(p) == "table" and p.from == me then open = open + 1 end
  end
  return open
end

-- How many more posts I can make now (peers keep at most MAX_POSTS_PER_SENDER per sender): a
-- request with linked orders needs 1 + #linked.
function Comm.OpenSlots()
  return math.max(0, MAX_POSTS_PER_SENDER - MyOpenPosts())
end

-- A note without prices, trimmed, at most MAX_NOTE characters ("" when nothing is left).
local function PostNote(note)
  local s = StripPrices(CleanString(note, 255) or "")
  local cut = CutChars(s, MAX_NOTE)
  if cut ~= s then s = cut:gsub("%s+$", "") end
  return s
end
Comm.PostNote = PostNote

-- parent: id of one of my posts this one is an intermediate for (a linked order). Linked
-- orders posted with their parent in the same click skip the few-seconds gap. note may be
-- nil or "" (linked orders have none); prices are taken out of it.
-- kind "m": looking for the materials themselves (a gatherer or anyone holding them can help).
function Comm.PostRequest(itemID, qty, note, parent, kind)
  local db, me = DB(), MyKey()
  itemID = PosInt(tonumber(itemID), 1e8)
  qty = PosInt(floor(tonumber(qty) or 1), 1000)
  if not (db and me and itemID and qty) then return nil end
  if parent ~= nil and not (type(parent) == "string" and type(db.posts[parent]) == "table") then parent = nil end
  local now = time()
  if not parent and now - lastPost < POST_GAP then
    Print(L["Please wait a few seconds before posting again."])
    return nil
  end
  local open = MyOpenPosts()
  if open >= MAX_POSTS_PER_SENDER then
    Print(format(L["You already have %d open requests. Retract one first."], open))
    return nil
  end
  lastPost = now
  postCounter = postCounter + 1
  local id = me .. ":" .. now .. ":" .. postCounter
  note = PostNote(note)
  db.posts[id] = { id = id, from = me, item = itemID, qty = qty, note = note, t = now, mine = true, pa = parent,
    k = kind == "m" and "m" or nil }
  SendPost(id)
  Fire("POSTS_UPDATED")
  return id
end

-- Broadcast P for one of my new posts on every wanted distribution (guild, realm channel). One
-- that can't be sent to right now (combat, chat lockdown, channel not joined yet) is retried
-- every 15 s while the post is still open, instead of waiting for the next hello's repeat.
local pendingP = {}       -- [post id] = { [dist] = true } still to send
local pendingPTimer = false

function SendPost(id)
  local db = DB()
  local p = db and db.posts[id]
  if type(p) ~= "table" or time() - (p.t or 0) >= POST_TTL then pendingP[id] = nil return end
  local dists = pendingP[id] or { GUILD = true, CHANNEL = true }
  local left
  for dist in pairs(dists) do
    local wanted = (dist == "GUILD" and InGuild() and GuildShareOn()) or (dist == "CHANNEL" and RealmChannelOn())
    if wanted then
      local sent = CanSend() and DistAvailable(dist) and Send("P", { v = VERSION, id = id, item = p.item, qty = p.qty,
        note = p.note, t = p.t, pa = p.pa, k = p.k }, dist, dist == "CHANNEL" and channelId or nil)
      if sent then
        -- Where it went: its retraction goes there too, whatever the sharing settings are by then.
        p.sentTo = p.sentTo or {}
        p.sentTo[dist] = true
      else
        left = left or {}
        left[dist] = true
      end
    end
  end
  pendingP[id] = left
  if not left or pendingPTimer or not (C_Timer and C_Timer.After) then return end
  pendingPTimer = true
  C_Timer.After(15, function()
    pendingPTimer = false
    for pid in pairs(pendingP) do SendPost(pid) end
  end)
end

-- Broadcast X for one of my posts on every distribution it may have reached (guild, realm
-- channel). A distribution that can't be sent to right now (combat, chat lockdown, channel not
-- joined yet) keeps it pending and is retried every 15 s for as long as the post would have
-- lived, so peers never keep a post I already dropped. Distributions turned off are skipped.
local SendRetract

-- Realm sharing turned off after a post went to the channel: the (hidden) channel is joined just
-- long enough to retract it there, then left again once no retraction waits for it.
local retractJoinAt, retractJoined = 0, false
local function JoinForRetract()
  if RealmChannelOn() or ResolveChannel() or time() - retractJoinAt < 30 then return end
  retractJoinAt, retractJoined = time(), true
  if JoinChannelByName then pcall(JoinChannelByName, CHANNEL_NAME) end
  C_Timer.After(2, function() if ResolveChannel() then HideChannelFromChat() end end)
end

local function LeaveAfterRetract()
  if not retractJoined then return end
  if RealmChannelOn() then retractJoined = false return end
  for _, e in pairs(PendingX()) do
    if type(e) == "table" and type(e.dists) == "table" and e.dists.CHANNEL then return end
  end
  retractJoined = false
  if LeaveChannelByName and ResolveChannel() then pcall(LeaveChannelByName, CHANNEL_NAME) end
  channelId = nil
end

local function RetryRetracts()
  pendingXTimer = false
  local now = time()
  local pending = PendingX()
  for pid, e in pairs(pending) do
    pending[pid] = nil
    if type(e) == "table" and type(e.dists) == "table" and type(e.t) == "number" and now - e.t < POST_TTL then
      SendRetract(pid, e.dists, e.t, e.sentTo)
    end
  end
end

-- sentTo: where the post went ({ [dist] = true }, saved on it). A retraction goes there even when
-- sharing on that distribution has been turned off since (the guild can still be written to; the
-- realm channel is joined again for it), as well as wherever sharing is on now.
function SendRetract(id, dists, since, sentTo)
  sentTo = type(sentTo) == "table" and sentTo or {}
  dists = dists or { GUILD = true, CHANNEL = true }
  local left
  for dist in pairs(dists) do
    local wanted, reachable
    if dist == "GUILD" then
      wanted = InGuild() and (GuildShareOn() or sentTo.GUILD) and true or false
      reachable = InGuild()
    else
      -- Sent there once: retracted there too. With sharing off since, the channel is joined
      -- again for it (and left once the retraction has gone out).
      wanted = (RealmChannelOn() or sentTo.CHANNEL) and true or false
      reachable = ResolveChannel() ~= nil
      if wanted and not reachable and C_Timer and C_Timer.After then JoinForRetract() end
    end
    if wanted then
      local sent = CanSend() and reachable
        and Send("X", { v = VERSION, id = id }, dist, dist == "CHANNEL" and channelId or nil)
      if not sent then
        left = left or {}
        left[dist] = true
      end
    end
  end
  if not left then
    -- Give the queued X time to leave before a channel joined only for it is left again.
    if retractJoined and C_Timer and C_Timer.After then C_Timer.After(10, LeaveAfterRetract) end
    return
  end
  PendingX()[id] = { dists = left, t = since or time(), sentTo = sentTo }
  if pendingXTimer or not (C_Timer and C_Timer.After) then return end
  pendingXTimer = true
  C_Timer.After(15, RetryRetracts)
end

-- Retracting one of my posts also retracts the linked orders posted for it.
-- One of my posts is retracted: tombstone it, remember it for repeating with hellos and send
-- the X.
function RetractMine(id, sentTo)
  local now = time()
  Retracted()[id] = now
  -- Kept for the post lifetime (PrunePosts drops expired ones); SendMyPosts takes turns with them.
  MyRetracted()[id] = now
  SendRetract(id, nil, nil, sentTo)
end

-- The whole chain of linked orders under a retracted request goes with it, however deep (a linked
-- order can have linked orders of its own): mine are retracted for everyone, other players' are
-- dropped here and tombstoned, so their late copies are dropped on arrival too.
local function DropLinked(id, seen)
  local db, me = DB(), MyKey()
  if not db then return end
  seen = seen or {}
  seen[id] = true
  for cid, c in pairs(db.posts) do
    if type(c) == "table" and c.pa == id and not seen[cid] then
      db.posts[cid] = nil
      if c.from == me then RetractMine(cid, c.sentTo) else Retracted()[cid] = Retracted()[cid] or time() end
      DropLinked(cid, seen)
    end
  end
end

function Comm.Retract(id)
  local db, me = DB(), MyKey()
  if not (db and type(id) == "string") then return false end
  local p = db.posts[id]
  if not p then return false end
  db.posts[id] = nil
  if p.from == me then
    RetractMine(id, p.sentTo)
    -- (I never receive my own X, so nothing else would drop its linked orders on this client.)
    DropLinked(id)
  end
  Fire("POSTS_UPDATED")
  return true
end

-- Renew: one of my posts goes up again as a new post (the old one is retracted), with its
-- linked orders, for another POST_TTL. Returns the new id.
function Comm.Renew(id)
  local db, me = DB(), MyKey()
  local p = db and type(id) == "string" and db.posts[id]
  if not (type(p) == "table" and p.from == me) then return nil end
  -- The whole chain of my linked orders under it, however deep, goes up again the same shape.
  local function Tree(pid, seen)
    seen[pid] = true
    local out = {}
    for cid, c in pairs(db.posts) do
      if type(c) == "table" and c.pa == pid and c.from == me and not seen[cid] then
        out[#out + 1] = { item = c.item, qty = c.qty, k = c.k, kids = Tree(cid, seen) }
      end
    end
    return out
  end
  -- The gap between posts holds for Renew too (checked before anything is retracted).
  if time() - lastPost < POST_GAP then
    Print(L["Please wait a few seconds before posting again."])
    return nil
  end
  local tree = Tree(id, {})
  Comm.Retract(id)
  local nid = Comm.PostRequest(p.item, p.qty, p.note, nil, p.k)
  if not nid then return nil end
  local function Post(list, parent)
    for _, k in ipairs(list) do
      local kid = Comm.PostRequest(k.item, k.qty, "", parent, k.k)
      if kid then Post(k.kids, kid) end
    end
  end
  Post(tree, nid)
  return nid
end

-- My posts that expire within RENEW_WINDOW and haven't been mentioned yet: one quiet chat line
-- each (option oldPostNotice, default on). Checked with every hello round and at login.
function Comm.NudgeOld()
  if type(CraftBoardDB) == "table" and CraftBoardDB.oldPostNotice == false then return end
  local db, me = DB(), MyKey()
  if not (db and me) then return end
  local now = time()
  for _, p in pairs(db.posts) do
    if type(p) == "table" and p.from == me and not p.pa and not p.nudged and type(p.t) == "number"
      and now - p.t >= POST_TTL - Comm.RENEW_WINDOW and now - p.t < POST_TTL then
      p.nudged = true
      local label = NS.ItemLabel and NS.ItemLabel(p.item) or format(L["Item %d"], p.item)
      local left = math.max(1, floor((POST_TTL - (now - p.t)) / 3600 + 0.5))
      Print(format(L["Your request for %s expires in about %dh. Renew it on the Requests tab to keep it up."], label, left))
    end
  end
end
Comm.RENEW_WINDOW = 4 * 3600
Comm.POST_TTL = POST_TTL

-- Posts linked to post id (its intermediates), and the post it is linked to.
function Comm.Linked(id)
  local db = DB()
  local children, parent = {}, nil
  if not (db and type(id) == "string") then return children, parent end
  local me = db.posts[id]
  if type(me) == "table" and me.pa then parent = db.posts[me.pa] end
  for _, p in pairs(db.posts) do
    if type(p) == "table" and p.pa == id and not (NS.IsIgnored and NS.IsIgnored(p.from)) then
      children[#children + 1] = p
    end
  end
  sort(children, function(a, b) return (a.t or 0) < (b.t or 0) end)
  return children, parent
end

-- Remember that I offered on a post (for the back-online notice). Local only.
function Comm.MarkOffered(id)
  local db = DB()
  if not (db and type(id) == "string") then return end
  if type(db.offered) ~= "table" then db.offered = {} end
  db.offered[id] = time()
end

function Comm.Offered(id)
  local db = DB()
  return db and type(db.offered) == "table" and db.offered[id] ~= nil or false
end

-- Plain chat whisper (never SAY/YELL/party). Newer clients moved it to C_ChatInfo.
function Comm.Whisper(toName, msg)
  local target = FullName(toName)
  if not target or IsMe(target) or type(msg) ~= "string" or msg == "" then return false end
  local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
  if not send then return false end
  return (pcall(send, msg, "WHISPER", nil, ShortName(target)))
end

function Comm.Request(itemID, qty, toName)
  itemID = PosInt(tonumber(itemID), 1e8)
  qty = PosInt(floor(tonumber(qty) or 1), 1000) or 1
  if not itemID or type(toName) ~= "string" then return false end
  local target = FullName(toName)
  if not target or IsMe(target) then return false end
  local label
  if C_Item and C_Item.GetItemInfo then
    local a, b = C_Item.GetItemInfo(itemID)
    if type(a) == "table" then label = a.itemLink or a.hyperlink or a.itemName or a.name
    elseif type(b) == "string" then label = b
    elseif type(a) == "string" then label = a end
  elseif GetItemInfo then
    label = select(2, GetItemInfo(itemID))
  end
  if not label and C_Item and C_Item.GetItemNameByID then label = C_Item.GetItemNameByID(itemID) end
  label = label or format(L["Item %d"], itemID)
  local msg = NS.Templates and NS.Templates.Request(label, qty)
    or format(L["[CraftBoard] Could you craft %dx %s for me? I have/can get the mats."], qty, label)
  return Comm.Whisper(target, msg)
end

-- Back online ------------------------------------------------------------
-- A peer's first hello after their login (l=true): if they have an open post I can craft or
-- offered on, one quiet chat line (option "backOnline", default on). Never more than one per
-- peer per 30 min; nothing is sent.
local BACK_GAP = 30 * 60

local function BackOnlineOn()
  return not (type(CraftBoardDB) == "table" and CraftBoardDB.backOnline == false)
end

-- My recipe for an item: recipeID, record, charKey, current (Inventory.MyRecipeFor).
local function MyRecipeFor(itemID)
  local find = NS.Inventory and NS.Inventory.MyRecipeFor
  if not find then return nil end
  return find(itemID)
end

-- A clickable name in a chat line ("[Name]", whisper / menu on click).
local function PlayerLink(full)
  return format("|Hplayer:%s|h[%s]|h", full, ShortName(full))
end

function Comm.NoteBackOnline(full)
  if not BackOnlineOn() or (NS.IsIgnored and NS.IsIgnored(full)) then return end
  local now = time()
  if backAlerted[full] and now - backAlerted[full] < BACK_GAP then return end
  local db = DB()
  if not db then return end
  local best, offered, alt
  for id, p in pairs(db.posts) do
    if type(p) == "table" and p.from == full then
      local mine = Comm.Offered(id)
      local recipeID, rec, charKey, current = MyRecipeFor(p.item)
      -- Bind-on-Pickup and quest outputs can't be made for them (as on the Requests tab).
      if recipeID and NS.Recipes and NS.Recipes.IsTradeable and not NS.Recipes.IsTradeable(rec) then recipeID = nil end
      if (mine or recipeID) and (not best or (p.t or 0) > (best.t or 0)) then
        best, offered = p, mine
        alt = recipeID and not current and charKey or nil
      end
    end
  end
  if not best then return end
  backAlerted[full] = now
  local label = NS.ItemLabel and NS.ItemLabel(best.item) or format(L["Item %d"], best.item)
  local who, qty = PlayerLink(full), best.qty or 1
  local msg
  if offered then
    msg = qty > 1 and format(L["%s is back online (you offered on their %dx %s)."], who, qty, label)
      or format(L["%s is back online (you offered on their %s)."], who, label)
  elseif alt then
    -- Only one of my other characters knows the recipe.
    local altName = NS.ShortName and NS.ShortName(alt) or alt
    msg = qty > 1 and format(L["%s is back online (your alt %s can craft their %dx %s)."], who, altName, qty, label)
      or format(L["%s is back online (your alt %s can craft their %s)."], who, altName, label)
  else
    msg = qty > 1 and format(L["%s is back online (you can craft their %dx %s)."], who, qty, label)
      or format(L["%s is back online (you can craft their %s)."], who, label)
  end
  Print(msg)
  Fire("PEERS_UPDATED")
end

-- Receiving -------------------------------------------------------------

local function RateOk(full)
  local now = time()
  local b = inbound[full]
  if not b or now - b.t >= INBOUND_WINDOW then
    inbound[full] = { t = now, c = 1 }
    return true
  end
  b.c = b.c + 1
  return b.c <= INBOUND_MAX
end

-- Exact copies of a message within DEDUPE_WINDOW (a guildmate in the realm channel sends
-- everything on both), dropped before the rate limit counts them. Two generations of
-- DEDUPE_WINDOW seconds each keep the table small.
local function RawDuplicate(full, message)
  local now = time()
  if now - rawAt >= DEDUPE_WINDOW then rawOld, rawNew, rawAt = rawNew, {}, now end
  local k = full .. "\t" .. message
  local t = rawNew[k] or rawOld[k]
  if t and now - t <= DEDUPE_WINDOW then return true end
  rawNew[k] = now
  return false
end

-- Guildmates who are also in the realm channel get every broadcast twice.
local function Duplicate(full, kind, key)
  local now = time()
  local k = full .. "\t" .. kind .. "\t" .. tostring(key)
  local t = seenMsg[k]
  seenMsg[k] = now
  return t ~= nil and now - t <= DEDUPE_WINDOW
end

local function SweepDedupe()
  local now = time()
  for k, t in pairs(seenMsg) do
    if now - t > DEDUPE_WINDOW then seenMsg[k] = nil end
  end
  for k, b in pairs(inbound) do
    if now - b.t > INBOUND_WINDOW then inbound[k] = nil end
  end
  for k, t in pairs(queried) do
    if now - t > QUERY_TTL then queried[k], queriedHash[k] = nil, nil end
  end
  for k, t in pairs(answered) do
    if now - t > ANSWER_GAP then answered[k] = nil end
  end
end

local handlers = {}

-- Recipe lists wanted while sending wasn't possible (combat, chat lockdown) or while a query to
-- that peer was still inside QUERY_GAP: pendingQ[full] = the hash they announced. Asked for
-- (checked every 15 s) once sending is possible and the gap is over, while that peer's list is
-- still not that one.
local pendingQ, pendingQTimer = {}, false
local function RetryQueries()
  pendingQTimer = false
  local db, now = DB(), time()
  for full, h in pairs(pendingQ) do
    local p = db and db.peers[full]
    -- (A peer on demand by now isn't asked for its full list after all.)
    if type(p) ~= "table" or p.hash == h or scale.Peer(full) then
      pendingQ[full] = nil
    elseif CanSend() and not (queried[full] and now - queried[full] < QUERY_GAP) then
      pendingQ[full] = nil
      queried[full], queriedHash[full] = now, h
      Send("Q", { v = VERSION }, "WHISPER", ShortName(full), "NORMAL")
    end
  end
  if next(pendingQ) and C_Timer and C_Timer.After then
    pendingQTimer = true
    C_Timer.After(15, RetryQueries)
  end
end

-- Guildmates the roster didn't know yet when they were heard on the channel (a login on a
-- crowded realm) were taken for on-demand peers: their full list is asked for now.
function scale.ReconcileGuild()
  local db = DB()
  local roster = GuildRoster()
  if not (db and next(roster)) then return end
  local any = false
  for full, p in pairs(db.peers) do
    if type(p) == "table" and p.odHash ~= nil and roster[full] ~= nil then
      pendingQ[full] = p.odHash
      p.odHash, p.hash = nil, nil
      any = true
    end
  end
  if any and not pendingQTimer and C_Timer and C_Timer.After then
    pendingQTimer = true
    C_Timer.After(1, RetryQueries)
  end
end

function handlers.H(full, data)
  local h = CleanString(data.h, 64)
  if not h or type(data.n) ~= "number" then return end
  local busy = data.b == true
  -- The same hello through guild and channel is one; a quick hello right after with other
  -- cooldowns (a cast) is not: its cooldown state is part of the key.
  local cdKey = ""
  if type(data.cd) == "table" then
    local now, ids = time(), {}
    for id, sec in pairs(data.cd) do
      if type(id) == "number" and type(sec) == "number" then
        ids[#ids + 1] = id .. (sec == 0 and "r" or (":" .. floor((now + sec) / 900)))
      end
    end
    sort(ids)
    cdKey = table.concat(ids, ",")
  end
  -- (Specializations too: a hello sent only to announce one isn't a copy of the one before.)
  if Duplicate(full, "H", h .. (busy and ":b" or "") .. "|" .. cdKey .. "|" .. Comm.SpecKey(Comm.ReadSpecs(data.sp))) then return end
  local p = Touch(full)
  if not p then return end
  if type(data.cd) == "table" then
    local cd, c, now, changed = {}, 0, time(), false
    for id, sec in pairs(data.cd) do
      if c >= MAX_CD then break end
      if PosInt(id, 1e8) and type(sec) == "number" and sec >= 0 and sec <= MAX_CD_SECONDS then
        cd[id] = now + floor(sec)
        c = c + 1
        -- Ready-state flips and drifts over a minute count; the clock ticking doesn't.
        local was = type(p.cd) == "table" and p.cd[id]
        if not was or (was <= now) ~= (sec == 0) or math.abs(was - cd[id]) > 60 then changed = true end
      end
    end
    if type(p.cd) == "table" then
      for id in pairs(p.cd) do
        if cd[id] == nil then changed = true end
      end
    end
    p.cd = cd
    if changed then Fire("PEERS_UPDATED") end
  elseif p.cd ~= nil then
    -- A hello without cd (an older build): their cooldowns are unknown again, not ready forever.
    p.cd = nil
    Fire("PEERS_UPDATED")
  end
  -- Their posts follow the login hello: check once they have had time to arrive (the second
  -- check only speaks if the first found nothing; NoteBackOnline rate-limits itself).
  if data.l == true and C_Timer and C_Timer.After then
    C_Timer.After(5, function() Comm.NoteBackOnline(full) end)
    C_Timer.After(20, function() Comm.NoteBackOnline(full) end)
  end
  -- pg=1: this client reads recipe lists sent in pages (older ones take a single message only).
  p.paging = data.pg == 1 or nil
  -- Specializations (sp, optional): known spell IDs only.
  local specs = Comm.ReadSpecs(data.sp)
  if Comm.SpecKey(specs) ~= Comm.SpecKey(p.specs) then
    p.specs = specs
    FirePeersSoon()
  end
  local profs = CleanProfs(data.profs)
  if profs then
    -- New ranks with the same recipes (a skill-up): tooltips and lists showing them update.
    if ProfsKey(profs) ~= ProfsKey(p.profs) then FirePeersSoon() end
    p.profs = profs
  end
  if (p.busy and true or false) ~= busy then
    p.busy = busy or nil
    Fire("PEERS_UPDATED")
  end
  -- Too many players on the channel to swap whole recipe lists: Find asks them (W) instead.
  -- Checked before the same-hash shortcut: a book that changed while on demand and changed back
  -- still drops what came in under the other hash.
  if scale.Peer(full) then
    -- Their book changed: what I had of it may be gone (an unlearned profession). Searches
    -- (W / A) bring back what they still know. (The hash their full list was stored under counts
    -- as what I knew, the first time.)
    local known = p.odHash or p.hash
    if known == nil then
      -- Nothing to compare with yet (only search answers so far): they belong to this book.
      p.odHash = h
    elseif known ~= h then
      -- Answers since their last hello come from this book already: they stay.
      local keep = {}
      for id in pairs(p.aRec or {}) do keep[id] = true end
      if next(p.recipes) then
        p.recipes = keep
        Fire("PEERS_UPDATED")
      end
      p.odHash = h
    end
    p.aRec = nil
    return
  end
  -- Out of on-demand mode again: what I have of them is only what searches brought in, so their
  -- full list is asked for once, whatever the hash says.
  if p.odHash ~= nil then p.odHash, p.hash = nil, nil end
  if p.hash == h then return end
  if data.n <= 0 then
    -- Nothing to fetch; record the empty book without a round trip. A query still open for an
    -- older list is closed with it, so a late answer can't bring the recipes back.
    p.recipes, p.hash = {}, h
    queried[full], queriedHash[full], pagesIn[full], pendingQ[full] = nil, nil, nil, nil
    Fire("PEERS_UPDATED")
    return
  end
  local now = time()
  if (queried[full] and now - queried[full] < QUERY_GAP) or not CanSend() then
    pendingQ[full] = h
    if not pendingQTimer and C_Timer and C_Timer.After then
      pendingQTimer = true
      C_Timer.After(15, RetryQueries)
    end
    return
  end
  queried[full], queriedHash[full] = now, h
  Send("Q", { v = VERSION }, "WHISPER", ShortName(full), "NORMAL")
end

-- One R on each distribution the waiting queriers heard me on; anyone it can't reach gets
-- their whisper after all.
-- The peer's hello said it reads paged recipe lists.
local function ReadsPages(full)
  local db = DB()
  local p = db and db.peers[full]
  return type(p) == "table" and p.paging == true
end

local function FlushBatch()
  if not batch then return end
  -- Combat or chat lockdown began while it waited: the batch waits too (queries that come in
  -- meanwhile join it), then goes out.
  if not CanSend() and C_Timer and C_Timer.After then
    C_Timer.After(15, FlushBatch)
    return
  end
  -- Its broadcast is a full list: it waits for room under the per-minute limit as well (counted
  -- when it goes, not when the batch began).
  if not scale.AnswerRoom() and C_Timer and C_Timer.After then
    C_Timer.After(15, FlushBatch)
    return
  end
  local b = batch
  batch = nil
  -- Queriers who asked too long ago (a long lockdown) would no longer read the answer: they are
  -- let go, and a hello (my hash differs from theirs) makes them ask again.
  local now, stale, askedAt = time(), false, {}
  for peer in pairs(b) do
    askedAt[peer] = batchAsked[peer] or now
    if now - askedAt[peer] > QUERY_TTL - 15 then
      b[peer], answered[peer], stale = nil, nil, true
    end
    batchAsked[peer] = nil
  end
  if stale then SendHello(nil, nil, true) end
  if not next(b) then return end
  batchAt = time()
  local sent = {}
  for _, dist in pairs(b) do
    if sent[dist] == nil then
      -- Each distribution's broadcast is a list of its own: room is checked for each (its
      -- askers are whispered through the limit below if there is none).
      sent[dist] = CanSend() and DistAvailable(dist) and scale.AnswerRoom() and SendRecipes(dist) or false
      if sent[dist] then scale.CountAnswer() end
    end
  end
  -- The broadcast didn't go (too big for one message, or the channel was gone): each of them is
  -- whispered after all, through the per-minute limit like any other whispered list.
  for peer, dist in pairs(b) do
    if not sent[dist] then scale.QueueAnswer(peer, askedAt[peer]) end
  end
end

-- Answers a query with my recipe list. When several peers ask at once (my hash changes with
-- every recipe learned, and each peer who hears the hello asks), R_BATCH queries within
-- R_BATCH_WINDOW seconds start a batch: after R_BATCH_DELAY one R goes to the guild / realm
-- channel instead of a whisper each (at most one batch per ANSWER_GAP). Peers that didn't ask
-- ignore it (handlers.R). Only peers on this version join a batch: before it, R was read by
-- whisper only (their hello's pg=1 came with reading broadcast lists), so older ones are
-- whispered as ever.
-- Queries that came in while sending wasn't possible (combat, chat lockdown): pendingR[peer] =
-- when they asked. Answered by whisper once sending works, while the asker still reads the
-- answer (QUERY_TTL); anyone past that gets a hello instead, which makes them ask again.
local pendingR, pendingRTimer = {}, false
function scale.AnswerRoom()
  local now, t = time(), scale.answerTimes
  for i = #t, 1, -1 do
    if now - t[i] >= 60 then table.remove(t, i) end
  end
  return #t < scale.answersPerMin
end
function scale.CountAnswer() scale.answerTimes[#scale.answerTimes + 1] = time() end

local function RetryAnswers()
  pendingRTimer = false
  if not CanSend() then
    if next(pendingR) and C_Timer and C_Timer.After then
      pendingRTimer = true
      C_Timer.After(15, RetryAnswers)
    end
    return
  end
  local now, stale, staleGuild = time(), false, false
  for peer, t in pairs(pendingR) do
    if now - t > QUERY_TTL - 15 then
      pendingR[peer] = nil
      stale = true
      if GuildRoster()[peer] ~= nil then staleGuild = true end
    elseif scale.AnswerRoom() and SendRecipes("WHISPER", ShortName(peer), ReadsPages(peer)) then
      -- (Only a list that went counts; one that didn't stays queued until it goes stale.)
      pendingR[peer] = nil
      answered[peer] = now
      scale.CountAnswer()
    end
  end
  if next(pendingR) and not pendingRTimer and C_Timer and C_Timer.After then
    pendingRTimer = true
    C_Timer.After(15, RetryAnswers)
  end
  -- Askers who waited too long ask again after a hello. With crowds on the channel only the
  -- guild hears it (a channel hello would bring the crowd's queries back; guildmates always
  -- sync in full).
  if stale and not Comm.OnDemand() then
    SendHello(nil, nil, true)
  elseif staleGuild then
    SendHello("GUILD", nil, true)
  end
end

-- A query answered by whisper once the per-minute limit allows (askedAt: when they asked).
function scale.QueueAnswer(peer, askedAt)
  pendingR[peer] = askedAt or time()
  if not pendingRTimer and C_Timer and C_Timer.After then
    pendingRTimer = true
    C_Timer.After(1, RetryAnswers)
  end
end

function handlers.Q(full)
  Touch(full)
  local now = time()
  if answered[full] and now - answered[full] < ANSWER_GAP then return end
  if not CanSend() then
    pendingR[full] = now
    if not pendingRTimer and C_Timer and C_Timer.After then
      pendingRTimer = true
      C_Timer.After(15, RetryAnswers)
    end
    return
  end
  for i = #queryTimes, 1, -1 do
    if now - queryTimes[i] > R_BATCH_WINDOW then table.remove(queryTimes, i) end
  end
  queryTimes[#queryTimes + 1] = now
  -- Joining a broadcast batch costs nothing more: one R reaches them all. Only whispered lists
  -- count toward the per-minute limit (the batch's own R counts once).
  local dist = ReadsPages(full) and heardOn[full]
  -- A new batch is a full list too: only with room under the per-minute limit (else the queries
  -- wait in the whisper queue below).
  if dist and C_Timer and C_Timer.After and (batch or (#queryTimes >= R_BATCH
    and not (batchAt and now - batchAt < ANSWER_GAP) and scale.AnswerRoom())) then
    if not batch then
      batch = {}
      C_Timer.After(R_BATCH_DELAY, FlushBatch)
    end
    answered[full] = now
    batch[full] = dist
    batchAsked[full] = now
    return
  end
  if not scale.AnswerRoom() then
    pendingR[full] = now
    if not pendingRTimer and C_Timer and C_Timer.After then
      pendingRTimer = true
      C_Timer.After(15, RetryAnswers)
    end
    return
  end
  if SendRecipes("WHISPER", ShortName(full), ReadsPages(full)) then
    answered[full] = now
    scale.CountAnswer()
  else
    scale.QueueAnswer(full, now)
  end
end

function handlers.R(full, data)
  -- Only accept recipe lists we asked for.
  local q = queried[full]
  if not q or time() - q > QUERY_TTL then return end
  if type(data.list) ~= "table" then return end
  local h = CleanString(data.h, 64)
  if not h then return end
  local db = DB()
  local p = Touch(full)
  if not (db and p) then return end
  -- A paged list: collect pages under their hash until all are in (a different hash starts over).
  local pgs, pg = PosInt(data.pgs, MAX_PAGES), PosInt(data.pg, MAX_PAGES)
  local acc
  if pgs and pgs > 1 then
    if not (pg and pg <= pgs) then return end
    acc = pagesIn[full]
    if not acc or acc.h ~= h or acc.pgs ~= pgs then
      acc = { h = h, pgs = pgs, got = {}, n = 0, recipes = {}, count = 0 }
      pagesIn[full] = acc
    end
    if acc.got[pg] then return end
    acc.got[pg], acc.n = true, acc.n + 1
  end
  local recipes, count = acc and acc.recipes or {}, acc and acc.count or 0
  for _, e in ipairs(data.list) do
    if count >= MAX_RECIPES then break end
    local id, name, o, prof
    if type(e) == "number" then
      id = e
    elseif type(e) == "table" then
      id, name, o, prof = e[1], e[2], e[3], e[4]
    end
    id = PosInt(id, 1e8)
    if id then
      recipes[id] = true
      count = count + 1
      local src = type(e) == "table" and PosInt(e[5], 1e8)
      if src and NS.Recipes and NS.Recipes.SetSource then NS.Recipes.SetSource(id, src) end
      name = CleanString(name, MAX_NAME)
      o = PosInt(o, 1e8)
      prof = PosInt(prof, 1e6)
      if name or o then
        local rn = db.recipeNames[id]
        if type(rn) ~= "table" then rn = {}; db.recipeNames[id] = rn end
        if name and name ~= "" then rn.n = name end
        if o then rn.o = o end
        if prof then rn.p = prof end
      end
    end
  end
  local profs = CleanProfs(data.profs)
  if profs then p.profs = profs end
  if acc then
    acc.count = count
    if acc.n < acc.pgs then return end    -- more pages to come; the query stays open for them
    pagesIn[full] = nil
  end
  p.recipes = recipes
  p.hash, p.odHash = h, nil
  -- The answer to the hash asked for closes the query; an older one (a slow answer to an
  -- earlier query) is taken but leaves it open for the one asked for.
  if queriedHash[full] == nil or queriedHash[full] == h then queried[full], queriedHash[full] = nil, nil end
  Fire("PEERS_UPDATED")
end

function handlers.P(full, data)
  local id = CleanString(data.id, 96)
  local item = PosInt(data.item, 1e8)
  local qty = PosInt(data.qty, 1000)
  if not (id and id ~= "" and item and qty) then return end
  -- The note is optional (linked orders send "").
  if data.note ~= nil and type(data.note) ~= "string" then return end
  if Duplicate(full, "P", id) then return end
  Touch(full)
  local db = DB()
  if not db then return end
  local existing = db.posts[id]
  if type(existing) == "table" then
    if existing.from ~= full then return end
    return -- already known; keep original local timestamp so expiry stays anchored
  end
  -- A request that was retracted (its X can overtake a late copy of it), or a linked order for one.
  if Retracted()[id] then return end
  local pa = CleanString(data.pa, 96)
  if pa and Retracted()[pa] then return end
  local count, total = 0, 0
  local oldestId, oldestT
  local me = MyKey()
  for pid, p in pairs(db.posts) do
    total = total + 1
    if type(p) == "table" then
      if p.from == full then count = count + 1 end
      -- Room is made from other players' posts, never mine.
      if p.from ~= me and (not oldestT or (p.t or 0) < oldestT) then oldestId, oldestT = pid, p.t or 0 end
    end
  end
  if count >= MAX_POSTS_PER_SENDER then return end
  if total >= MAX_POSTS and oldestId then
    -- The oldest goes, tombstoned, with other players' linked orders under it (however deep), so
    -- none of them is left looking like a request of its own.
    local gone = { [oldestId] = true }
    db.posts[oldestId] = nil
    Retracted()[oldestId] = Retracted()[oldestId] or time()
    local more = true
    while more do
      more = false
      for cid, c in pairs(db.posts) do
        if type(c) == "table" and c.pa ~= nil and gone[c.pa] and c.from ~= me then
          db.posts[cid], gone[cid], more = nil, true, true
          Retracted()[cid] = Retracted()[cid] or time()
        end
      end
    end
  end
  -- Expiry uses our receive time: peers' clocks can't be trusted.
  local now = time()
  local st = type(data.t) == "number" and data.t or now
  db.posts[id] = {
    id = id, from = full, item = item, qty = qty,
    -- Prices off here too: older or other clients may still send them.
    note = PostNote(data.note),
    t = (st <= now and now - st < POST_TTL) and st or now,
    pa = pa,
    k = data.k == "m" and "m" or nil,
  }
  if NS.Stats and NS.Stats.NoteDemand then NS.Stats.NoteDemand(item, full) end
  Fire("POSTS_UPDATED")
end

function handlers.X(full, data)
  local id = CleanString(data.id, 96)
  if not id then return end
  if Duplicate(full, "X", id) then return end
  Touch(full)
  local db = DB()
  if not db then return end
  local p = db.posts[id]
  -- The sender must own the post: as stored, or (a post we never saw, e.g. an X repeated with a
  -- later hello) by the author in its id ("Name-Realm:time:n").
  local owner = type(p) == "table" and p.from or id:match("^(.+):%d+:%d+$")
  if owner and NS.SamePlayer(owner, full) then
    db.posts[id] = nil
    if Retracted()[id] then
      -- Already known: only children that arrived since need dropping.
      local any = false
      for _, c in pairs(db.posts) do
        if type(c) == "table" and c.pa == id then any = true break end
      end
      if not any then return end
    end
    Retracted()[id] = Retracted()[id] or time()
    DropLinked(id)
    Fire("POSTS_UPDATED")
  end
end

-- Who can craft this (W / A) ---------------------------------------------------------

do
local W_GAP = 4                   -- our own W rate limit
local W_REPEAT = 300              -- the same question is asked again only after this long
local W_TTL = 60                  -- an A is taken this long after our W
local W_MAX_ITEMS = 8
local W_MAX_TEXT = 40
local A_MAX = 30                  -- recipes in one answer
local A_GAP = 30                  -- one answer per asker per this long
local A_PER_MIN = 20              -- answers we send per minute

-- A Find search asks the board "who can craft <text or items>?"; crafters with a match whisper
-- back the matching recipes, which join what I know of them. Nothing here is automatic on the
-- crafter's side beyond the addon answer itself (no chat line, no whisper).

local asked = {}          -- [W id] = time we sent it
local askedKey = {}       -- [question key] = time: the same question isn't asked twice in W_REPEAT
local lastAsk, askCounter = 0, 0
local answeredW = {}      -- [asker] = time we answered them
local wAnswerTimes = {}   -- times of our answers within the last minute

-- Lower-case text cut to W_MAX_TEXT, letters, digits and spaces only (it is matched as plain text).
local function QueryText(text)
  if type(text) ~= "string" then return nil end
  local q = strlower(NS.StripCodes(text)):gsub("[%c|%%]", ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  q = CutChars(q, W_MAX_TEXT)
  if #q < 2 then return nil end   -- as Find: two letters are a search
  return q
end
Comm.QueryText = QueryText

-- My shareable recipes matching a W: text in the recipe or output item name (this client's
-- language), or one of its item IDs as output. At most A_MAX, as R list entries.
function Comm.MatchQuery(q, items)
  local want = {}
  for _, id in ipairs(type(items) == "table" and items or {}) do want[id] = true end
  local out, ids, mine, added = {}, {}, MyRecipes(), {}
  for id in pairs(mine) do if type(id) == "number" then ids[#ids + 1] = id end end
  sort(ids)
  -- Two passes: the items asked for by ID first (they never lose their place to a broad text
  -- match), then the text matches in what room is left.
  for pass = 1, 2 do
    for _, id in ipairs(ids) do
      if #out >= A_MAX then break end
      local r = mine[id]
      if type(r) == "table" and not added[id] then
        local hit = pass == 1 and type(r.o) == "number" and want[r.o]
        if pass == 2 and q then
          -- As Find matches: every word in the recipe name or the output item's name.
          local name = type(r.n) == "string" and strlower(r.n) or ""
          local item = type(r.o) == "number" and NS.Inventory and NS.Inventory.ItemName and NS.Inventory.ItemName(r.o)
          item = type(item) == "string" and strlower(item) or ""
          hit = true
          for w in q:gmatch("%S+") do
            if not (name:find(w, 1, true) or item:find(w, 1, true)) then hit = false break end
          end
        end
        if hit then
          added[id] = true
          out[#out + 1] = { id, type(r.n) == "string" and r.n:sub(1, MAX_NAME) or false,
            type(r.o) == "number" and r.o or false, type(r.p) == "number" and r.p or false,
            NS.Recipes and NS.Recipes.SourceOf and NS.Recipes.SourceOf(id) or nil }
        end
      end
    end
  end
  return out
end

-- Ask the board. text and/or items (output item IDs). Returns true when a W went out.
function Comm.Ask(text, items)
  local q = QueryText(text)
  local list = {}
  for _, id in ipairs(type(items) == "table" and items or {}) do
    if #list >= W_MAX_ITEMS then break end
    if PosInt(id, 1e8) then list[#list + 1] = id end
  end
  -- Items in my catalogue whose name in my language matches go along by ID, so a crafter on a
  -- client in another language finds them too (the text only matches names in theirs).
  if q and #list < W_MAX_ITEMS and NS.Inventory and NS.Inventory.ItemName then
    local cat = type(CraftBoardDB) == "table" and type(CraftBoardDB.recipeNames) == "table" and CraftBoardDB.recipeNames or {}
    local seenID = {}
    for _, id in ipairs(list) do seenID[id] = true end
    for _, e in pairs(cat) do
      if #list >= W_MAX_ITEMS then break end
      local o = type(e) == "table" and e.o
      local name = type(o) == "number" and not seenID[o] and NS.Inventory.ItemName(o)
      if type(name) == "string" then
        -- As Find matches: each word in the item's name or the recipe's ("Transmute: ...").
        name = strlower(name)
        local rname = type(e.n) == "string" and strlower(e.n) or ""
        local hit = true
        for w in q:gmatch("%S+") do
          if not (name:find(w, 1, true) or rname:find(w, 1, true)) then hit = false break end
        end
        if hit then list[#list + 1], seenID[o] = o, true end
      end
    end
    sort(list)
  end
  if not q and #list == 0 then return false end
  local now = time()
  local key = (q or "") .. "|" .. table.concat(list, ",")
  if askedKey[key] and now - askedKey[key] < W_REPEAT then return false end
  if now - lastAsk < W_GAP or not CanSend() then return false, "wait" end
  local me = MyKey()
  if not me then return false end
  askCounter = askCounter + 1
  local id = me .. ":" .. now .. ":" .. askCounter
  if #Broadcast("W", { v = VERSION, id = id, q = q, i = #list > 0 and list or nil }, "NORMAL") == 0 then return false end
  lastAsk, askedKey[key], asked[id] = now, now, now
  return true
end

-- Ask once the typing has stopped (Find calls this on every keystroke).
local askPending, askText, askItems = false, nil, nil
-- A search and the item it picks arrive together: both go in the one question.
function Comm.AskSoon(text, items)
  if text ~= nil then askText = text end
  if type(items) == "table" then
    -- Newest first, each once: the card the player stopped on is never cut off by W_MAX_ITEMS.
    askItems = askItems or {}
    for _, id in ipairs(items) do
      for k = #askItems, 1, -1 do
        if askItems[k] == id then table.remove(askItems, k) end
      end
      table.insert(askItems, 1, id)
    end
  end
  if askPending or not (C_Timer and C_Timer.After) then return end
  askPending = true
  C_Timer.After(1.5, function()
    askPending = false
    local t, i = askText, askItems
    askText, askItems = nil, nil
    local _, why = Comm.Ask(t, i)
    -- Inside the gap between questions, or in combat: tried again shortly (unless a newer
    -- search came in meanwhile, which goes instead).
    -- (Put back as it was, newest first: AskSoon's items argument would reverse it.)
    if why == "wait" and askText == nil and askItems == nil then
      askText, askItems = t, i
      Comm.AskSoon()
    end
  end)
end

function handlers.W(full, data)
  local id = CleanString(data.id, 96)
  if not id or id == "" then return end
  if Duplicate(full, "W", id) then return end
  Touch(full)
  local q = data.q ~= nil and QueryText(data.q) or nil
  local items = {}
  if type(data.i) == "table" then
    for k = 1, W_MAX_ITEMS do
      local it = PosInt(data.i[k], 1e8)
      if it then items[#items + 1] = it end
    end
  end
  if not q and #items == 0 then return end
  scale.AnswerW(full, { id = id, q = q, items = items, t = time() })
end

-- One answer per asker per A_GAP: a newer question inside the gap waits for its end (the latest
-- one only), and an answer held up by combat or chat lockdown is tried again, both only while the
-- asker still takes answers (W_TTL).
scale.heldW = {}          -- [asker] = the question waiting out the gap
scale.capHeld = {}        -- [asker] = the question waiting for room under A_PER_MIN
scale.wPending = 0        -- answers scheduled but not sent yet
scale.pendingA = {}       -- [asker] = { w=, list= }: their answer waiting to go out
function scale.AnswerW(full, w)
  local now = time()
  if now - w.t > W_TTL - 1 then return end
  local wait = answeredW[full] and A_GAP - (now - answeredW[full])
  if wait and wait > 0 then
    local had = scale.heldW[full]
    scale.heldW[full] = w
    if not had and C_Timer and C_Timer.After then
      C_Timer.After(wait + 0.1, function()
        local x = scale.heldW[full]
        scale.heldW[full] = nil
        if x then scale.AnswerW(full, x) end
      end)
    end
    return
  end
  local list = Comm.MatchQuery(w.q, w.items)
  if #list == 0 then return end
  for i = #wAnswerTimes, 1, -1 do
    if now - wAnswerTimes[i] >= 60 then table.remove(wAnswerTimes, i) end
  end
  -- Answers waiting to go out (the spreading wait, a lockdown) count too, so they can't all
  -- leave at once later.
  if #wAnswerTimes + scale.wPending >= A_PER_MIN then
    -- At the limit: tried again when the oldest answer leaves the minute (AnswerW drops it if
    -- the asker has stopped listening by then).
    -- One retry per asker, with their newest question.
    local had = scale.capHeld[full]
    scale.capHeld[full] = w
    if not had and C_Timer and C_Timer.After then
      -- Every slot may still be waiting to be sent (no time to count from yet): look again soon.
      local wait = wAnswerTimes[1] and (60 - (now - wAnswerTimes[1]) + 0.1) or 3
      C_Timer.After(wait, function()
        local x = scale.capHeld[full]
        scale.capHeld[full] = nil
        if x then scale.AnswerW(full, x) end
      end)
    end
    return
  end
  -- One answer per asker on its way at a time: a newer question while it waits (a lockdown)
  -- replaces what it will say instead of sending a second one.
  local pend = scale.pendingA[full]
  if pend then
    pend.w, pend.list = w, list
    return
  end
  pend = { w = w, list = list }
  scale.pendingA[full] = pend
  -- Held for this asker meanwhile; the minute's count takes the answer when it is sent.
  answeredW[full] = now
  scale.wPending = scale.wPending + 1
  -- A moment's wait, different for every crafter, so the answers don't arrive in one burst.
  local function answer()
    local cur = pend.w
    if CanSend() then
      scale.wPending = max(0, scale.wPending - 1)
      scale.pendingA[full] = nil
      if Send("A", { v = VERSION, id = cur.id, list = pend.list, profs = MyProfs() }, "WHISPER", ShortName(full), "BULK") then
        answeredW[full] = time()
        wAnswerTimes[#wAnswerTimes + 1] = time()
      end
    elseif time() - cur.t < W_TTL - 5 and C_Timer and C_Timer.After then
      C_Timer.After(5, answer)
    else
      scale.wPending = max(0, scale.wPending - 1)
      scale.pendingA[full] = nil
    end
  end
  -- The spreading wait, cut short so the answer still arrives while the asker listens.
  local delay = min(0.5 + random() * 2.5, max(0, W_TTL - 1 - (now - w.t)))
  if C_Timer and C_Timer.After and delay > 0 then C_Timer.After(delay, answer) else answer() end
end

function handlers.A(full, data)
  local id = CleanString(data.id, 96)
  local t = id and asked[id]
  if not t or time() - t > W_TTL then return end
  if type(data.list) ~= "table" then return end
  local db = DB()
  local p = Touch(full)
  if not (db and p) then return end
  local added = false
  for k = 1, A_MAX do
    local e = data.list[k]
    if type(e) ~= "table" then break end
    local rid = PosInt(e[1], 1e8)
    if rid then
      if not p.recipes[rid] then p.recipes[rid], added = true, true end
      -- (Remembered until their next hello, which keeps them whatever its hash.)
      p.aRec = p.aRec or {}
      p.aRec[rid] = true
      local src = PosInt(e[5], 1e8)
      if src and NS.Recipes and NS.Recipes.SetSource then NS.Recipes.SetSource(rid, src) end
      local name, o, prof = CleanString(e[2], MAX_NAME), PosInt(e[3], 1e8), PosInt(e[4], 1e6)
      if name or o then
        local rn = db.recipeNames[rid]
        if type(rn) ~= "table" then rn = {}; db.recipeNames[rid] = rn end
        if name and name ~= "" then rn.n = name end
        if o then rn.o = o end
        if prof then rn.p = prof end
      end
    end
  end
  local profs = CleanProfs(data.profs)
  if profs then p.profs = profs end
  if added then FirePeersSoon() end
end

function scale.SweepAsked()
  local now = time()
  for k, t in pairs(asked) do if now - t > W_TTL then asked[k] = nil end end
  for k, t in pairs(askedKey) do if now - t > W_REPEAT then askedKey[k] = nil end end
  for k, t in pairs(answeredW) do if now - t > A_GAP then answeredW[k] = nil end end
end
end

local ALLOWED = {
  H = { GUILD = true, CHANNEL = true },
  P = { GUILD = true, CHANNEL = true },
  X = { GUILD = true, CHANNEL = true },
  Q = { WHISPER = true },
  R = { WHISPER = true, GUILD = true, CHANNEL = true },
  W = { GUILD = true, CHANNEL = true },
  A = { WHISPER = true },
}

function commObj:OnCommReceived(prefix, message, distribution, from)
  if prefix ~= PREFIX then return end
  if type(from) ~= "string" or type(message) ~= "string" or #message < 2 then return end
  local full = FullName(from)
  if not full or IsMe(full) then return end
  local kind = message:sub(1, 1)
  local allowed = ALLOWED[kind]
  if not allowed or not allowed[distribution] then return end
  -- The channel joined only to retract a post there: nothing is read from it.
  if distribution == "CHANNEL" and not RealmChannelOn() then return end
  -- A recipe list I didn't ask for (a batch answer to other peers) isn't even decoded.
  if kind == "R" and not (queried[full] and time() - queried[full] <= QUERY_TTL) then return end
  if distribution ~= "WHISPER" then
    if RawDuplicate(full, message) then return end
    heardOn[full] = distribution
  end
  if not RateOk(full) then return end
  local data = Decode(message:sub(2))
  if not data then return end
  -- Heard on the channel (on-demand mode counts these players), before the handler reads it.
  if distribution == "CHANNEL" then scale.Heard(full) end
  local ok, err = pcall(handlers[kind], full, data)
  if not ok and NS.debug then Print("comm error: " .. tostring(err)) end
end

-- Lifecycle -------------------------------------------------------------

local function ScheduleHello()
  local delay = HELLO_PERIOD + random(-HELLO_JITTER, HELLO_JITTER)
  C_Timer.After(delay, function()
    PrunePeers()
    PrunePosts()
    SweepDedupe()
    scale.SweepAsked()
    Comm.NudgeOld()
    SendHello()
    ScheduleHello()
  end)
end

local helloDebounce = false
local function OnRecipesUpdated()
  if helloDebounce then return end
  helloDebounce = true
  C_Timer.After(HELLO_DEBOUNCE, function()
    helloDebounce = false
    if MyHash() ~= lastHelloHash then SendHello() end
  end)
end

local function Start()
  if started then return end
  started = true
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
  end
  if commObj.RegisterComm then
    commObj:RegisterComm(PREFIX, "OnCommReceived")
  else
    Print(L["AceComm-3.0 missing; sync disabled."])
  end
  if NS.RegisterCallback then
    pcall(NS.RegisterCallback, Comm, "RECIPES_UPDATED", OnRecipesUpdated)
    -- A cast of a cooldown craft (or one newly tracked) reaches peers within seconds, not with the
    -- next periodic hello: they would otherwise see it ready for up to ten minutes.
    pcall(NS.RegisterCallback, Comm, "COOLDOWNS_UPDATED", function() ScheduleStateFlush(BUSY_DEBOUNCE) end)
    -- A specialization learned or dropped goes out the same way (only when it differs from what
    -- the last hello said).
    pcall(NS.RegisterCallback, Comm, "SKILLS_UPDATED", function()
      if lastHelloAt then ScheduleStateFlush(BUSY_DEBOUNCE) end   -- (the login hello carries them)
    end)
  end
  InstallChatFilter()
  PrunePeers()
  PrunePosts()
  -- Retractions a reload or disconnect interrupted go out once sending is possible.
  if next(PendingX()) and C_Timer and C_Timer.After then
    pendingXTimer = true
    C_Timer.After(15, RetryRetracts)
  end
  C_Timer.After(10, function() SendHello() end)
  C_Timer.After(30, function() Comm.NudgeOld() end)
  ScheduleHello()
  if C_Timer.NewTicker then
    C_Timer.NewTicker(300, function()
      if InGuild() and C_GuildInfo and C_GuildInfo.GuildRoster then pcall(C_GuildInfo.GuildRoster) end
      SweepDedupe()
    end)
    -- Nobody says goodbye: a peer not heard from within ONLINE_WINDOW goes offline without a
    -- message. Checked once a minute (from a first look now).
    CheckOnline()
    quietUntil = time() + 120
    C_Timer.NewTicker(60, CheckOnline)
  end
end

-- Busy ------------------------------------------------------------------
-- Effective busy = manual (CraftBoardDB.chars[Me].busy) or, with CraftBoardDB.autoBusy (default
-- on), in a dungeon / raid instance or in combat. Peers learn it from the hello's b flag.

local function MyChar()
  local db, me = DB(), MyKey()
  local c = db and me and type(db.chars) == "table" and db.chars[me]
  return type(c) == "table" and c or nil
end

local function ManualBusy()
  local c = MyChar()
  return c and c.busy == true or false
end

local function AutoBusyOn()
  return not (type(CraftBoardDB) == "table" and CraftBoardDB.autoBusy == false)
end

local function InDungeon()
  if not IsInInstance then return false end
  local ok, inside, kind = pcall(IsInInstance)
  return ok and inside and (kind == "party" or kind == "raid") and true or false
end

-- Busy because of where I am, regardless of the option. Only dungeons and raids: addon messages
-- are held back in combat, so a busy flag raised by combat would reach nobody before it ends.
local function AutoReason()
  return InDungeon()
end

local function ComputeBusy()
  if ManualBusy() then return true end
  return AutoBusyOn() and AutoReason() and true or false
end

-- Recompute; on a change fire BUSY_UPDATED and announce it within BUSY_DEBOUNCE seconds.
-- notify: fire BUSY_UPDATED even when the effective state didn't change (manual toggled).
local function UpdateBusy(notify)
  local b = ComputeBusy()
  local changed = b ~= busyNow
  busyNow = b
  if changed and started then ScheduleStateFlush(BUSY_DEBOUNCE) end
  if changed or notify then Fire("BUSY_UPDATED") end
end

-- isInitialLogin: a real login. After a /reload the back-online flag (l) must not go out
-- again, so both distributions count as already announced.
local guildShareWas = nil   -- guild sharing as last acted on (Comm.SetGuildShare)

local function OnEnteringWorld(_, isInitialLogin)
  if guildShareWas == nil then guildShareWas = GuildShareOn() end
  if not started and isInitialLogin ~= true then
    loginHello.GUILD, loginHello.CHANNEL = true, true
  end
  Start()
  UpdateBusy()
  -- Channel joins fail during the first seconds of loading; re-checked on every zone-in.
  C_Timer.After(5, function()
    JoinRealmChannel(1)
    -- Still in the channel with sharing off (joined for a retraction before a reload): left
    -- again once no retraction waits for it.
    if not RealmChannelOn() and ResolveChannel() then
      retractJoined = true
      LeaveAfterRetract()
    end
  end)
end

if NS.Register then
  NS.Register("PLAYER_ENTERING_WORLD", OnEnteringWorld)
  NS.Register("ZONE_CHANGED_NEW_AREA", function() UpdateBusy() end)
else
  local f = CreateFrame("Frame")
  f:RegisterEvent("PLAYER_ENTERING_WORLD")
  f:SetScript("OnEvent", function(_, event, ...) OnEnteringWorld(event, ...) end)
end

-- Public ----------------------------------------------------------------

-- Announce ourselves now (still rate-limited; deferred if a hello went out recently).
function Comm.Broadcast()
  SendHello()
end

function Comm.SetRealmChannel(on)
  local db = DB()
  if not db then return end
  local changed = (db.realmChannel and true or false) ~= (on and true or false)
  if changed then FirePeersSoon() end
  db.realmChannel = on and true or false
  if on then
    retractJoined = false
    -- Turned on just now: the channel hears me at once.
    JoinRealmChannel(1, changed)
  else
    if LeaveChannelByName and ResolveChannel() then pcall(LeaveChannelByName, CHANNEL_NAME) end
    channelId = nil
  end
end

-- Options "Share recipes with my guild": turned on, the guild hears my hello and my posts now
-- rather than with the next periodic hello. guildShareWas: the state last acted on (the modern
-- settings panel has already saved the new value when this is called).
function Comm.SetGuildShare(on)
  local db = DB()
  if not db then return end
  on = on and true or false
  local was = guildShareWas
  if was == nil then was = db.guildShare ~= false end
  db.guildShare, guildShareWas = on, on
  if was ~= on then FirePeersSoon() end
  if on and not was then SendHello("GUILD", nil, true) end
end

function Comm.ChannelId()
  return ResolveChannel()
end

-- Manual busy for this character (saved); the effective state may still be busy by auto.
function Comm.SetBusy(on)
  local c = MyChar()
  if not c then return end
  c.busy = on and true or nil
  UpdateBusy(true)
end

-- Effective busy: manual, or auto in a dungeon / in combat.
function Comm.IsBusy()
  return busyNow
end

-- busy (effective), manual, auto (busy only because of a dungeon / combat).
function Comm.BusyState()
  local manual = ManualBusy()
  return busyNow, manual, busyNow and not manual
end

function Comm.SetAutoBusy(on)
  if type(CraftBoardDB) ~= "table" then return end
  CraftBoardDB.autoBusy = on and true or false
  UpdateBusy(true)
end

function Comm.AutoBusy()
  return AutoBusyOn()
end

-- /cb busy, shift-right-click on the minimap button, the board header toggle: flips manual busy.
-- quiet: no chat line (the header button shows the state itself).
function Comm.ToggleBusy(quiet)
  Comm.SetBusy(not ManualBusy())
  if quiet then return end
  local busy, manual = Comm.BusyState()
  if manual then
    Print(L["You are busy: other CraftBoard users see it and can't whisper you from the board."])
  elseif busy then
    Print(L["Manual busy off, but you are still busy automatically in this dungeon or raid."])
  else
    Print(L["You are available for whispers from the board."])
  end
end

-- Compact status for the UI footer: { peers=, online=, posts=, channel=joined, channelOn=, guild= }.
function Comm.Status()
  local total, online = 0, 0
  for _, p in pairs(Comm.Peers()) do
    total = total + 1
    if p.online then online = online + 1 end
  end
  return {
    peers = total,
    online = online,
    posts = #PostList(),
    channel = RealmChannelOn() and ResolveChannel() ~= nil,
    channelOn = RealmChannelOn(),
    guild = InGuild() and GuildShareOn(),
  }
end

function Comm.Debug()
  local peers = Comm.Peers()
  local total, online = 0, 0
  for _, p in pairs(peers) do
    total = total + 1
    if p.online then online = online + 1 end
  end
  local function ago(t) return t and format(L["%ds ago"], time() - t) or L["never"] end
  Print(format(L["channel %s: %s"], CHANNEL_NAME, ResolveChannel() and format(L["id %d"], channelId) or L["not joined"])
    .. (RealmChannelOn() and "" or L[" (disabled)"]))
  Print(format(L["guild: %s"], InGuild() and L["yes"] or L["no"]) .. (GuildShareOn() and "" or L[" (sharing off)"]))
  Print(format(L["peers: %d (%d online), open posts: %d"], total, online, #PostList()))
  Print(format(L["last hello: %s (guild %s, channel %s), my hash %s"], ago(lastHelloAt), ago(lastHello.GUILD),
    ago(lastHello.CHANNEL), tostring(MyHash())))
  local od = Comm.OnDemand()
  Print(format(L["channel players heard today: %d; recipe lists: %s"], scale.heard,
    od and L["asked per search (many players)"] or L["swapped in full"]))
  if not (LibSerialize and LibDeflate and AceComm) then Print(L["missing comm libraries; sync disabled"]) end
end
