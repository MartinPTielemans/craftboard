-- CraftBoard Comm: sync layer over addon messages (GUILD + hidden realm CHANNEL).
-- Wire format: one type char followed by LibSerialize -> CompressDeflate -> EncodeForWoWAddonChannel.
--   H hello   {v=1, profs={[profID]={n=,r=,m=}}, n=#recipes, h=hash, b=true when busy,
--              l=true on the first hello after login, cd={[recipeID]=seconds until ready}}  GUILD/CHANNEL
--             (b, l and cd are optional: older clients read only the fields they know)
--   Q query   {v=1}                                                     WHISPER to hello sender
--   R recipes {v=1, h=hash, profs=..., list={ {id, name, outputItemID, profID}, ... }}  WHISPER
--   P post    {v=1, id=, item=, qty=, note=, t=, pa=parent post id}     GUILD/CHANNEL
--             (pa is optional: a linked order for an intermediate of the parent request)
--   X retract {v=1, id=}                                                GUILD/CHANNEL
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
local MAX_POSTS = 300
local POST_GAP = 10               -- our own post rate limit
local INBOUND_WINDOW = 60
local INBOUND_MAX = 40            -- messages per sender per window before we ignore them
local BUSY_DEBOUNCE = 5           -- a busy change is announced this long after it happens
local BUSY_MIN_GAP = 15           -- per distribution, for hellos sent only to announce busy
local MAX_CD = 16                 -- cooldown entries carried by a hello
local MAX_CD_SECONDS = 14 * 86400

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
local busyNow = false     -- effective busy (manual, or auto in a dungeon / in combat)
local inCombat = false    -- PLAYER_REGEN_DISABLED .. PLAYER_REGEN_ENABLED
local sentBusy = {}       -- [dist] = busy flag carried by the last hello sent there
local busyPending = false -- a busy hello is scheduled
local loginHello = {}     -- [dist] = true once the login hello (l=true) went out there
local backAlerted = {}    -- [peer] = time of the last back-online notice
local pendingX = {}       -- [post id] = { dists = {[dist]=true}, t= }: retractions not yet sent everywhere
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

-- Forever names are two words but UnitName("player") returns only the first ("Raion" vs the
-- sender "Raion Lyzl"), so compare the first word too, on my realm only.
local function IsMe(full)
  if not full then return true end
  local me = MyKey()
  if me and full == me then return true end
  local mine, realm = UnitName and UnitName("player"), MyRealm()
  if not mine then return false end
  local short = ShortName(full)
  if short == mine then return true end
  local name, r = full:match("^(.-)%-([^%-]+)$")
  if name and r == realm and name:match("^(%S+)") == mine then return true end
  return false
end

-- Strip WoW escape sequences ("|c", "|H", "|T"...) from anything a peer sends us.
local function CleanString(s, maxLen)
  if type(s) ~= "string" then return nil end
  s = NS.StripCodes(s):gsub("|", ""):gsub("%c", "")
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

-- Options "Share recipes with my guild": only an explicit false turns GUILD sends off.
local function GuildShareOn()
  local db = DB()
  return not (db and db.guildShare == false)
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
  if dist == "GUILD" then return InGuild() and GuildShareOn() end
  if dist == "CHANNEL" then return RealmChannelOn() and ResolveChannel() ~= nil end
  return false
end

local SendMyPosts -- forward

-- Announce a busy change on every distribution whose last hello carried the other state.
local function BusyFlush()
  busyPending = false
  for _, dist in ipairs({ "GUILD", "CHANNEL" }) do
    if DistAvailable(dist) and (sentBusy[dist] or false) ~= busyNow then SendHello(dist, true) end
  end
end

local function ScheduleBusyFlush(delay)
  if busyPending or not (C_Timer and C_Timer.After) then return end
  busyPending = true
  C_Timer.After(delay, BusyFlush)
end

-- Hello per distribution, rate-limited per spec (<= 1 per ~10 min per distribution).
-- If we're inside the gap, schedule one deferred hello instead of dropping it.
-- busy: sent to announce a busy change, allowed every BUSY_MIN_GAP instead.
function SendHello(dist, busy)
  if not dist then
    SendHello("GUILD")
    SendHello("CHANNEL")
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
      ScheduleBusyFlush(wait)
      return
    end
  elseif last and now - last < HELLO_MIN_GAP then
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
  local payload = { v = VERSION, profs = MyProfs(), n = n, h = h, b = busyNow or nil,
    l = not loginHello[dist] or nil, cd = NS.Cooldowns and NS.Cooldowns.ForHello and NS.Cooldowns.ForHello(MAX_CD) or nil }
  local target = dist == "CHANNEL" and channelId or nil
  if Send("H", payload, dist, target, "BULK") then
    lastHello[dist] = now
    lastHelloAt = now
    lastHelloHash = h
    sentBusy[dist] = busyNow
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
    -- IsMe also drops entries an older build stored for my own character.
    if type(p) ~= "table" or type(p.seen) ~= "number" or p.seen < cutoff or IsMe(name) then
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
    if type(p) == "table" and not (NS.IsIgnored and NS.IsIgnored(name)) then
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
        -- Busy only means something while online (an offline peer's last flag is stale).
        busy = online and p.busy and true or false,
        cd = p.cd,
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
  for id, p in pairs(db.posts) do
    if type(p) == "table" and p.from == me and type(p.t) == "number" and now - p.t < POST_TTL then
      local target = dist == "CHANNEL" and channelId or nil
      Send("P", { v = VERSION, id = id, item = p.item, qty = p.qty, note = p.note, t = p.t, pa = p.pa }, dist, target, "BULK")
    end
  end
end

function Comm.Requests()
  return PostList()
end

-- parent: id of one of my posts this one is an intermediate for (a linked order). Linked
-- orders posted with their parent in the same click skip the few-seconds gap.
function Comm.PostRequest(itemID, qty, note, parent)
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
  local open = 0
  for _, p in pairs(db.posts) do
    if type(p) == "table" and p.from == me then open = open + 1 end
  end
  if open >= MAX_POSTS_PER_SENDER then
    Print(format(L["You already have %d open requests. Retract one first."], open))
    return nil
  end
  lastPost = now
  postCounter = postCounter + 1
  local id = me .. ":" .. now .. ":" .. postCounter
  note = CleanString(note, MAX_NOTE) or ""
  db.posts[id] = { id = id, from = me, item = itemID, qty = qty, note = note, t = now, mine = true, pa = parent }
  Broadcast("P", { v = VERSION, id = id, item = itemID, qty = qty, note = note, t = now, pa = parent })
  Fire("POSTS_UPDATED")
  return id
end

-- Broadcast X for one of my posts on every distribution it may have reached (guild, realm
-- channel). A distribution that can't be sent to right now (combat, chat lockdown, channel not
-- joined yet) keeps it pending and is retried every 15 s for as long as the post would have
-- lived, so peers never keep a post I already dropped. Distributions turned off are skipped.
local SendRetract
local function RetryRetracts()
  pendingXTimer = false
  local now = time()
  for pid, e in pairs(pendingX) do
    pendingX[pid] = nil
    if now - e.t < POST_TTL then SendRetract(pid, e.dists, e.t) end
  end
end

function SendRetract(id, dists, since)
  dists = dists or { GUILD = true, CHANNEL = true }
  local left
  for dist in pairs(dists) do
    local wanted = (dist == "GUILD" and InGuild() and GuildShareOn()) or (dist == "CHANNEL" and RealmChannelOn())
    if wanted then
      local sent = CanSend() and DistAvailable(dist)
        and Send("X", { v = VERSION, id = id }, dist, dist == "CHANNEL" and channelId or nil)
      if not sent then
        left = left or {}
        left[dist] = true
      end
    end
  end
  if not left then return end
  pendingX[id] = { dists = left, t = since or time() }
  if pendingXTimer or not (C_Timer and C_Timer.After) then return end
  pendingXTimer = true
  C_Timer.After(15, RetryRetracts)
end

-- Retracting one of my posts also retracts the linked orders posted for it.
function Comm.Retract(id)
  local db, me = DB(), MyKey()
  if not (db and type(id) == "string") then return false end
  local p = db.posts[id]
  if not p then return false end
  db.posts[id] = nil
  if p.from == me then
    SendRetract(id)
    for cid, c in pairs(db.posts) do
      if type(c) == "table" and c.pa == id and c.from == me then
        db.posts[cid] = nil
        SendRetract(cid)
      end
    end
  end
  Fire("POSTS_UPDATED")
  return true
end

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
  label = label or format(L["item %d"], itemID)
  local msg = format(L["[CraftBoard] Could you craft %dx %s for me? I have/can get the mats."], qty, label)
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

function Comm.NoteBackOnline(full)
  if not BackOnlineOn() or (NS.IsIgnored and NS.IsIgnored(full)) then return end
  local now = time()
  if backAlerted[full] and now - backAlerted[full] < BACK_GAP then return end
  local db = DB()
  if not db then return end
  local best, offered
  for id, p in pairs(db.posts) do
    if type(p) == "table" and p.from == full then
      local mine = Comm.Offered(id)
      local can = NS.CanCraftItem and NS.CanCraftItem(p.item)
      if (mine or can) and (not best or (p.t or 0) > (best.t or 0)) then best, offered = p, mine end
    end
  end
  if not best then return end
  backAlerted[full] = now
  local label = NS.ItemLabel and NS.ItemLabel(best.item) or format(L["item %d"], best.item)
  Print(format(offered and L["%s is back online (you offered on their %dx %s)."]
    or L["%s is back online (you can craft their %dx %s)."], ShortName(full), best.qty or 1, label))
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
  local busy = data.b == true
  if Duplicate(full, "H", h .. (busy and ":b" or "")) then return end
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
  end
  if data.l == true then Comm.NoteBackOnline(full) end
  local profs = CleanProfs(data.profs)
  if profs then p.profs = profs end
  if (p.busy and true or false) ~= busy then
    p.busy = busy or nil
    Fire("PEERS_UPDATED")
  end
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
    pa = CleanString(data.pa, 96),
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
    -- My linked orders for that request go with it (theirs are retracted by their authors).
    local me = MyKey()
    for cid, c in pairs(db.posts) do
      if type(c) == "table" and c.pa == id and c.from == me then Comm.Retract(cid) end
    end
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
    Print(L["AceComm-3.0 missing; sync disabled."])
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

-- Busy because of where I am / what I'm doing, regardless of the option.
local function AutoReason()
  return InDungeon() or inCombat
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
  if changed and started then ScheduleBusyFlush(BUSY_DEBOUNCE) end
  if changed or notify then Fire("BUSY_UPDATED") end
end

local function OnEnteringWorld()
  Start()
  inCombat = (UnitAffectingCombat and UnitAffectingCombat("player")) and true or false
  UpdateBusy()
  -- Channel joins fail during the first seconds of loading; re-checked on every zone-in.
  C_Timer.After(5, function() JoinRealmChannel(1) end)
end

if NS.Register then
  NS.Register("PLAYER_ENTERING_WORLD", OnEnteringWorld)
  NS.Register("ZONE_CHANGED_NEW_AREA", function() UpdateBusy() end)
  NS.Register("PLAYER_REGEN_DISABLED", function() inCombat = true; UpdateBusy() end)
  NS.Register("PLAYER_REGEN_ENABLED", function() inCombat = false; UpdateBusy() end)
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
    Print(L["You are busy: other CraftBoard users see it and the board won't whisper you."])
  elseif busy then
    Print(L["Manual busy off, but you are still busy automatically (dungeon or combat)."])
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
  if not (LibSerialize and LibDeflate and AceComm) then Print(L["missing comm libraries; sync disabled"]) end
end
