-- CraftBoard Comm: sync layer over addon messages (GUILD + hidden realm CHANNEL).
-- Wire format: one type char followed by LibSerialize -> CompressDeflate -> EncodeForWoWAddonChannel.
--   H hello   {v=1, profs={[profID]={n=,r=,m=}}, n=#recipes, h=hash}      GUILD/CHANNEL
--   Q query   {v=1}                                                     WHISPER to hello sender
--   R recipes {v=1, h=hash, profs=..., list={ {id, name, outputItemID, profID}, ... }}  WHISPER
--   P post    {v=1, id=, item=, qty=, note=, t=}                        GUILD/CHANNEL
--   X retract {v=1, id=}                                                GUILD/CHANNEL
local ADDON, NS = ...

local Comm = {}
NS.Comm = Comm

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
local MAX_POSTS = 300
local POST_GAP = 10               -- our own post rate limit
local INBOUND_WINDOW = 60
local INBOUND_MAX = 40            -- messages per sender per window before we ignore them

local LibSerialize = LibStub and LibStub("LibSerialize", true)
local LibDeflate = LibStub and LibStub("LibDeflate", true)
local AceComm = LibStub and LibStub("AceComm-3.0", true)

local time, type, pairs, ipairs, tostring, tonumber = time, type, pairs, ipairs, tostring, tonumber
local floor, random, min = math.floor, math.random, math.min
local sort = table.sort

-- Runtime state (not saved)
local channelId = nil
local lastHello = {}      -- [dist] = time
local lastHelloHash = nil
local lastHelloAt = nil
local helloPending = {}   -- [dist] = true while a deferred hello is scheduled
local queried = {}        -- [peer] = time we sent Q
local answered = {}       -- [peer] = time we sent R
local seenMsg = {}        -- [dedupe key] = time
local inbound = {}        -- [peer] = {t=, c=}
local lastPost = 0
local postCounter = 0
local rosterCache, rosterAt = nil, 0
local started = false

-- Helpers ---------------------------------------------------------------

local function Print(msg)
  if NS.Print then NS.Print(msg) end
end

local function Fire(event)
  if NS.callbacks and NS.callbacks.Fire then
    pcall(NS.callbacks.Fire, NS.callbacks, event)
  end
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
  if type(NS.Me) == "string" and NS.Me ~= "" then return NS.Me end
  local name, realm = UnitName and UnitName("player"), MyRealm()
  if name and realm then return name .. "-" .. realm end
  return nil
end

-- AceComm hands us Ambiguate(sender, "none"): bare "Name" for same-realm senders.
-- Peers are keyed "Name-Realm" so they line up with NS.Me and guild roster names.
local function FullName(name)
  if type(name) ~= "string" or name == "" or #name > 64 then return nil end
  if name:find("|", 1, true) or name:find(" ", 1, true) then return nil end
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

local function IsMe(full)
  if not full then return true end
  local me = MyKey()
  if me and full == me then return true end
  local mine = UnitName and UnitName("player")
  if mine and ShortName(full) == mine then return true end
  return false
end

-- Strip WoW escape sequences ("|c", "|H", "|T"...) from anything a peer sends us.
local function CleanString(s, maxLen)
  if type(s) ~= "string" then return nil end
  s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1")
  s = s:gsub("|T.-|t", ""):gsub("|", ""):gsub("%c", "")
  if #s > maxLen then s = s:sub(1, maxLen) end
  return s
end

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

local SendHello -- forward

local function JoinRealmChannel(attempt)
  attempt = attempt or 1
  if not RealmChannelOn() then return end
  if ResolveChannel() then
    HideChannelFromChat()
    return
  end
  if JoinChannelByName then pcall(JoinChannelByName, CHANNEL_NAME) end
  C_Timer.After(2, function()
    if ResolveChannel() then
      HideChannelFromChat()
      -- Login hello may have gone out to GUILD only because the channel wasn't ready yet.
      if started then SendHello("CHANNEL") end
    elseif attempt < 5 then
      C_Timer.After(10, function() JoinRealmChannel(attempt + 1) end)
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
  if InGuild() then
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
    local ok, h = pcall(R.Hash)
    if ok and h ~= nil then return tostring(h) end
  end
  return "0:" .. CountTable(MyRecipes())
end

local function MyProfs()
  local db, me = DB(), MyKey()
  local out = {}
  local c = db and me and type(db.chars) == "table" and db.chars[me]
  local profs = type(c) == "table" and c.profs
  if type(profs) == "table" then
    for id, p in pairs(profs) do
      if type(id) == "number" and type(p) == "table" then
        -- Recipes stores profs positionally: { name, rank, max }.
        out[id] = { n = p.name or p[1], r = p.rank or p[2], m = p.max or p[3] }
      end
    end
  end
  return out
end

local function DistAvailable(dist)
  if dist == "GUILD" then return InGuild() end
  if dist == "CHANNEL" then return RealmChannelOn() and ResolveChannel() ~= nil end
  return false
end

local SendMyPosts -- forward

-- Hello per distribution, rate-limited per spec (<= 1 per ~10 min per distribution).
-- If we're inside the gap, schedule one deferred hello instead of dropping it.
function SendHello(dist)
  if not dist then
    SendHello("GUILD")
    SendHello("CHANNEL")
    return
  end
  if not DistAvailable(dist) then return end
  local now = time()
  local last = lastHello[dist]
  if last and now - last < HELLO_MIN_GAP then
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
    if not helloPending[dist] then
      helloPending[dist] = true
      C_Timer.After(30, function()
        helloPending[dist] = nil
        SendHello(dist)
      end)
    end
    return
  end
  local h = MyHash()
  -- n must match the count part of h ("count:poly") so peers' empty-book shortcut is right.
  local n = tonumber(h:match("^(%d+):")) or CountTable(MyRecipes())
  local payload = { v = VERSION, profs = MyProfs(), n = n, h = h }
  local target = dist == "CHANNEL" and channelId or nil
  if Send("H", payload, dist, target, "BULK") then
    lastHello[dist] = now
    lastHelloAt = now
    lastHelloHash = h
    SendMyPosts(dist)
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
    list[i] = { id, name, o, p }
  end
  return list
end

-- R must fit MAX_DECODED on the receiver: first try with names, then without
-- (receivers can still resolve the output item's name), then truncate.
local function SendRecipes(to)
  local payload = { v = VERSION, h = MyHash(), profs = MyProfs(), list = BuildRecipeList(true) }
  local text, size = Encode(payload)
  if text and size > MAX_DECODED then
    payload.list = BuildRecipeList(false)
    text, size = Encode(payload)
    while text and size > MAX_DECODED and #payload.list > 1 do
      local keep = floor(#payload.list * 0.75)
      for i = #payload.list, keep + 1, -1 do payload.list[i] = nil end
      text, size = Encode(payload)
    end
  end
  if not text or not commObj.SendCommMessage then return false end
  return pcall(commObj.SendCommMessage, commObj, PREFIX, "R" .. text, "WHISPER", to, "BULK")
end

-- Peers -----------------------------------------------------------------

local function Touch(full)
  local db = DB()
  if not db then return nil end
  local p = db.peers[full]
  if type(p) ~= "table" then
    p = { recipes = {}, profs = {} }
    db.peers[full] = p
  end
  if type(p.recipes) ~= "table" then p.recipes = {} end
  if type(p.profs) ~= "table" then p.profs = {} end
  p.seen = time()
  return p
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
    if type(p) ~= "table" or type(p.seen) ~= "number" or p.seen < cutoff then
      db.peers[name] = nil
    end
  end
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

local function FriendOnline(full)
  if not (C_FriendList and C_FriendList.GetFriendInfo) then return nil end
  local ok, info = pcall(C_FriendList.GetFriendInfo, ShortName(full))
  if ok and type(info) == "table" then return info.connected and true or false end
  return nil
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
    if type(p) == "table" then
      local online = type(p.seen) == "number" and now - p.seen < ONLINE_WINDOW
      local r = roster[name]
      if r ~= nil then
        online = r
      else
        local f = FriendOnline(name)
        if f ~= nil then online = f end
      end
      out[name] = {
        recipes = p.recipes or {},
        profs = p.profs or {},
        seen = p.seen,
        hash = p.hash,
        online = online and true or false,
      }
    end
  end
  return out
end

-- Posts -----------------------------------------------------------------

local function PrunePosts()
  local db = DB()
  if not db then return end
  local cutoff = time() - POST_TTL
  for id, p in pairs(db.posts) do
    if type(p) ~= "table" or type(p.t) ~= "number" or p.t < cutoff then
      db.posts[id] = nil
    end
  end
end

local function PostList()
  PrunePosts()
  local db = DB()
  local list = {}
  if not db then return list end
  for _, p in pairs(db.posts) do list[#list + 1] = p end
  sort(list, function(a, b) return (a.t or 0) > (b.t or 0) end)
  return list
end

-- Posts are re-sent alongside each hello so players who log in later still see them.
function SendMyPosts(dist)
  local db, me = DB(), MyKey()
  if not (db and me) then return end
  local now = time()
  for id, p in pairs(db.posts) do
    if type(p) == "table" and p.from == me and type(p.t) == "number" and now - p.t < POST_TTL then
      local target = dist == "CHANNEL" and channelId or nil
      Send("P", { v = VERSION, id = id, item = p.item, qty = p.qty, note = p.note, t = p.t }, dist, target, "BULK")
    end
  end
end

function Comm.Requests()
  return PostList()
end

function Comm.PostRequest(itemID, qty, note)
  local db, me = DB(), MyKey()
  itemID = PosInt(tonumber(itemID), 1e8)
  qty = PosInt(floor(tonumber(qty) or 1), 1000)
  if not (db and me and itemID and qty) then return nil end
  local now = time()
  if now - lastPost < POST_GAP then
    Print("Please wait a few seconds before posting again.")
    return nil
  end
  local open = 0
  for _, p in pairs(db.posts) do
    if type(p) == "table" and p.from == me then open = open + 1 end
  end
  if open >= MAX_POSTS_PER_SENDER then
    Print("You already have " .. open .. " open requests. Retract one first.")
    return nil
  end
  lastPost = now
  postCounter = postCounter + 1
  local id = me .. ":" .. now .. ":" .. postCounter
  note = CleanString(note, MAX_NOTE) or ""
  db.posts[id] = { id = id, from = me, item = itemID, qty = qty, note = note, t = now, mine = true }
  Broadcast("P", { v = VERSION, id = id, item = itemID, qty = qty, note = note, t = now })
  Fire("POSTS_UPDATED")
  return id
end

function Comm.Retract(id)
  local db, me = DB(), MyKey()
  if not (db and type(id) == "string") then return false end
  local p = db.posts[id]
  if not p then return false end
  db.posts[id] = nil
  if p.from == me then
    Broadcast("X", { v = VERSION, id = id })
  end
  Fire("POSTS_UPDATED")
  return true
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
    label = select(2, C_Item.GetItemInfo(itemID))
    if not label then label = C_Item.GetItemInfo(itemID) end
  elseif GetItemInfo then
    label = select(2, GetItemInfo(itemID))
  end
  if not label and C_Item and C_Item.GetItemNameByID then label = C_Item.GetItemNameByID(itemID) end
  label = label or ("item " .. itemID)
  local msg = "[CraftBoard] Could you craft " .. qty .. "x " .. label .. " for me? I have/can get the mats."
  return Comm.Whisper(target, msg)
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
    if now - t > QUERY_TTL then queried[k] = nil end
  end
  for k, t in pairs(answered) do
    if now - t > ANSWER_GAP then answered[k] = nil end
  end
end

local handlers = {}

function handlers.H(full, data)
  local h = CleanString(data.h, 64)
  if not h or type(data.n) ~= "number" then return end
  if Duplicate(full, "H", h) then return end
  local p = Touch(full)
  if not p then return end
  local profs = CleanProfs(data.profs)
  if profs then p.profs = profs end
  if p.hash == h then return end
  if data.n <= 0 then
    -- Nothing to fetch; record the empty book without a round trip.
    p.recipes, p.hash = {}, h
    Fire("PEERS_UPDATED")
    return
  end
  local now = time()
  if queried[full] and now - queried[full] < QUERY_GAP then return end
  if not CanSend() then return end
  queried[full] = now
  Send("Q", { v = VERSION }, "WHISPER", ShortName(full), "NORMAL")
end

function handlers.Q(full)
  Touch(full)
  local now = time()
  if answered[full] and now - answered[full] < ANSWER_GAP then return end
  if not CanSend() then return end
  answered[full] = now
  SendRecipes(ShortName(full))
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
  local recipes, count = {}, 0
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
  p.recipes = recipes
  p.hash = h
  local profs = CleanProfs(data.profs)
  if profs then p.profs = profs end
  queried[full] = nil
  Fire("PEERS_UPDATED")
end

function handlers.P(full, data)
  local id = CleanString(data.id, 96)
  local item = PosInt(data.item, 1e8)
  local qty = PosInt(data.qty, 1000)
  if not (id and id ~= "" and item and qty) then return end
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
  local count, total = 0, 0
  local oldestId, oldestT
  for pid, p in pairs(db.posts) do
    total = total + 1
    if type(p) == "table" then
      if p.from == full then count = count + 1 end
      if not oldestT or (p.t or 0) < oldestT then oldestId, oldestT = pid, p.t or 0 end
    end
  end
  if count >= MAX_POSTS_PER_SENDER then return end
  if total >= MAX_POSTS and oldestId then db.posts[oldestId] = nil end
  -- Expiry uses our receive time: peers' clocks can't be trusted.
  local now = time()
  local st = type(data.t) == "number" and data.t or now
  db.posts[id] = {
    id = id, from = full, item = item, qty = qty,
    note = CleanString(data.note, MAX_NOTE) or "",
    t = (st <= now and now - st < POST_TTL) and st or now,
  }
  Fire("POSTS_UPDATED")
end

function handlers.X(full, data)
  local id = CleanString(data.id, 96)
  if not id then return end
  if Duplicate(full, "X", id) then return end
  Touch(full)
  local db = DB()
  local p = db and db.posts[id]
  if type(p) == "table" and p.from == full then
    db.posts[id] = nil
    Fire("POSTS_UPDATED")
  end
end

local ALLOWED = {
  H = { GUILD = true, CHANNEL = true },
  P = { GUILD = true, CHANNEL = true },
  X = { GUILD = true, CHANNEL = true },
  Q = { WHISPER = true },
  R = { WHISPER = true },
}

function commObj:OnCommReceived(prefix, message, distribution, from)
  if prefix ~= PREFIX then return end
  if type(from) ~= "string" or type(message) ~= "string" or #message < 2 then return end
  local full = FullName(from)
  if not full or IsMe(full) then return end
  local kind = message:sub(1, 1)
  local allowed = ALLOWED[kind]
  if not allowed or not allowed[distribution] then return end
  if not RateOk(full) then return end
  local data = Decode(message:sub(2))
  if not data then return end
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
    Print("AceComm-3.0 missing; sync disabled.")
  end
  if NS.RegisterCallback then
    pcall(NS.RegisterCallback, Comm, "RECIPES_UPDATED", OnRecipesUpdated)
  end
  InstallChatFilter()
  PrunePeers()
  PrunePosts()
  C_Timer.After(10, function() SendHello() end)
  ScheduleHello()
  if C_Timer.NewTicker then
    C_Timer.NewTicker(300, function()
      if InGuild() and C_GuildInfo and C_GuildInfo.GuildRoster then pcall(C_GuildInfo.GuildRoster) end
      SweepDedupe()
    end)
  end
end

local function OnEnteringWorld()
  Start()
  -- Channel joins fail during the first seconds of loading; re-checked on every zone-in.
  C_Timer.After(5, function() JoinRealmChannel(1) end)
end

if NS.Register then
  NS.Register("PLAYER_ENTERING_WORLD", OnEnteringWorld)
else
  local f = CreateFrame("Frame")
  f:RegisterEvent("PLAYER_ENTERING_WORLD")
  f:SetScript("OnEvent", OnEnteringWorld)
end

-- Public ----------------------------------------------------------------

-- Announce ourselves now (still rate-limited; deferred if a hello went out recently).
function Comm.Broadcast()
  SendHello()
end

function Comm.SetRealmChannel(on)
  local db = DB()
  if not db then return end
  db.realmChannel = on and true or false
  if on then
    JoinRealmChannel(1)
  else
    if LeaveChannelByName and ResolveChannel() then pcall(LeaveChannelByName, CHANNEL_NAME) end
    channelId = nil
  end
end

function Comm.ChannelId()
  return ResolveChannel()
end

function Comm.Debug()
  local peers = Comm.Peers()
  local total, online = 0, 0
  for _, p in pairs(peers) do
    total = total + 1
    if p.online then online = online + 1 end
  end
  local function ago(t) return t and ((time() - t) .. "s ago") or "never" end
  Print("channel " .. CHANNEL_NAME .. ": " .. (ResolveChannel() and ("id " .. channelId) or "not joined")
    .. (RealmChannelOn() and "" or " (disabled)"))
  Print("guild: " .. (InGuild() and "yes" or "no"))
  Print("peers: " .. total .. " (" .. online .. " online), open posts: " .. #PostList())
  Print("last hello: " .. ago(lastHelloAt) .. " (guild " .. ago(lastHello.GUILD)
    .. ", channel " .. ago(lastHello.CHANNEL) .. "), my hash " .. tostring(MyHash()))
  if not (LibSerialize and LibDeflate and AceComm) then Print("missing comm libraries; sync disabled") end
end
