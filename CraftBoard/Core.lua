-- CraftBoard Core: event frame, DB, identity, slash commands, callbacks.
local ADDON, NS = ...

local build = select(4, GetBuildInfo())
NS.IsForever = (build or 0) >= 16000 and (build or 0) < 20000

-- Callbacks (CallbackHandler puts RegisterCallback/UnregisterCallback on NS).
-- Consumers call NS.RegisterCallback(owner, "EVENT", fn); owner must not be NS itself.
local CBH = LibStub and LibStub("CallbackHandler-1.0", true)
if CBH then
  NS.callbacks = CBH:New(NS)
else
  NS.callbacks = { Fire = function() end }
  NS.RegisterCallback = function() end
  NS.UnregisterCallback = function() end
  NS.UnregisterAllCallbacks = function() end
end
NS.Callbacks = NS.callbacks

function NS.Fire(name, ...)
  if NS.callbacks and NS.callbacks.Fire then
    NS.callbacks:Fire(name, ...)
  end
end

function NS.Print(msg)
  local text = "|cff33ccffCraftBoard:|r " .. tostring(msg)
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(text)
  else
    print(text)
  end
end

-- Event dispatch: one frame, many handlers per event; a failing handler doesn't block the rest.
local frame = CreateFrame("Frame")
local handlers = {}
NS.frame = frame

function NS.Register(event, fn)
  local list = handlers[event]
  if not list then
    list = {}
    handlers[event] = list
    -- Every unit event CraftBoard uses is about the player: skip the raid's casts.
    if event:find("^UNIT_") and frame.RegisterUnitEvent then
      frame:RegisterUnitEvent(event, "player")
    else
      frame:RegisterEvent(event)
    end
  end
  list[#list + 1] = fn
end

frame:SetScript("OnEvent", function(_, event, ...)
  local list = handlers[event]
  if not list then return end
  for i = 1, #list do
    local ok, err = pcall(list[i], event, ...)
    if not ok then
      local eh = geterrorhandler and geterrorhandler()
      if eh then eh(err) else NS.Print(err) end
    end
  end
end)

-- DB
local DEFAULTS = { chars = {}, peers = {}, posts = {}, realmChannel = true, guildShare = true, recipeNames = {}, tips = {},
  autoBusy = true, offered = {}, crafted = {}, backOnline = true, groupTooltips = true, gamepad = true }

local function InitDB()
  if type(CraftBoardDB) ~= "table" then CraftBoardDB = {} end
  for k, v in pairs(DEFAULTS) do
    if CraftBoardDB[k] == nil then
      if type(v) == "table" then CraftBoardDB[k] = {} else CraftBoardDB[k] = v end
    end
  end
  -- LibDBIcon's saved state (hide, minimapPos, lock, showInCompartment). The vendored
  -- LibDBIcon only adds the addon compartment entry when showInCompartment is set.
  if type(CraftBoardDB.minimap) ~= "table" then
    CraftBoardDB.minimap = { hide = false, showInCompartment = true }
  end
  NS.db = CraftBoardDB
end

-- Identity. Safe to call repeatedly; returns NS.Me (may be nil very early in loading).
-- NS.Me is "First Surname-Realm" on Forever (the way chat and addon messages name me), else
-- "Name-Realm". NS.MeLegacy is the first-name-only key older versions stored me under.
function NS.UpdateIdentity()
  local ok, name, surname = false, nil, nil
  if UnitName then ok, name, surname = pcall(UnitName, "player") end
  local realm = GetNormalizedRealmName and GetNormalizedRealmName()
  if (not realm or realm == "") and GetRealmName then
    realm = (GetRealmName() or ""):gsub("[%s%-]", "")
  end
  if ok and type(name) == "string" and name ~= "" and realm and realm ~= "" then
    NS.Realm = realm
    NS.MeLegacy = name .. "-" .. realm
    if NS.IsSurname(surname) then name = name .. " " .. surname end
    NS.Me = name .. "-" .. realm
  end
  if UnitFactionGroup then
    NS.Faction = UnitFactionGroup("player")
  end
  return NS.Me
end

-- Escape sequences off a chat line or peer string: colours (both "|cffRRGGBB" and Forever's
-- named "|cnIQ1:" quality colours), "|r", links reduced to their "[Name]", textures, atlases.
function NS.StripCodes(s)
  if type(s) ~= "string" then return "" end
  s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:|]*:", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1")
  s = s:gsub("|T.-|t", ""):gsub("|A.-|a", "")
  return s
end

-- Names ------------------------------------------------------------------------
-- Characters are keyed "Name-Realm". Forever names are two words ("Raion Lyzl") and some APIs
-- return only the first, so NS.SamePlayer also accepts a first-word match on the same realm.

function NS.ShortName(full)
  if type(full) ~= "string" then return "?" end
  if Ambiguate then return Ambiguate(full, "none") end
  return full:match("^[^%-]+") or full
end

local function SplitName(full)
  local name, realm = full:match("^(.-)%-([^%-]+)$")
  return name or full, realm
end

-- "Name" (my realm), "Name-Realm" or a unit's name and realm -> "Name-Realm", or nil.
function NS.FullName(name, realm)
  if type(name) ~= "string" or name == "" or name:find("[|%c]") then return nil end
  if type(realm) == "string" and realm ~= "" then return name .. "-" .. realm:gsub("[%s%-]", "") end
  if name:find("-", 1, true) then return name end
  local mine = NS.Realm or (GetNormalizedRealmName and GetNormalizedRealmName())
  if type(mine) ~= "string" or mine == "" then return nil end
  return name .. "-" .. mine
end

-- UnitName's second return is a Forever surname (not a realm, as on retail).
function NS.IsSurname(second)
  if not NS.IsForever or type(second) ~= "string" or second == "" then return false end
  if issecretvalue and issecretvalue(second) then return false end
  -- Guard in case a client does hand back the realm there after all.
  local realm = GetNormalizedRealmName and GetNormalizedRealmName()
  return second ~= realm and second ~= (GetRealmName and GetRealmName())
end

-- Same character. Names are compared whole; only when one side has no surname (a source that
-- gives first names only, like roll lines) does its first name match the other's first word.
function NS.SamePlayer(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then return false end
  if a == b then return true end
  local na, ra = SplitName(a)
  local nb, rb = SplitName(b)
  if (ra or NS.Realm) ~= (rb or NS.Realm) then return false end
  if na == nb then return true end
  if na:find(" ", 1, true) and nb:find(" ", 1, true) then return false end
  return na:match("^(%S+)") == nb:match("^(%S+)")
end

-- The saved character (CraftBoardDB.chars key) this name is, or nil. Exact: a key still saved
-- under a first name only (an alt not logged in since surnames came) is never taken for someone
-- "First Surname" who merely shares that first name.
function NS.MyCharKey(name)
  local full = NS.FullName(name)
  local chars = type(CraftBoardDB) == "table" and type(CraftBoardDB.chars) == "table" and CraftBoardDB.chars or {}
  if full and type(chars[full]) == "table" then return full end
  return nil
end

-- A name ("Name", "Name-Realm", "First Surname-Realm") is my current character.
function NS.IsMe(full)
  if type(full) ~= "string" or full == "" then return false end
  if not NS.Me and NS.UpdateIdentity then NS.UpdateIdentity() end
  if not NS.Me then return false end
  return NS.SamePlayer(full, NS.Me)
end

-- On my ignore list. Never errors; unknown API = not ignored.
function NS.IsIgnored(full)
  if type(full) ~= "string" or full == "" then return false end
  local check = (C_FriendList and C_FriendList.IsIgnored) or IsIgnored
  if not check then return false end
  local ok, yes = pcall(check, NS.ShortName(full))
  return ok and yes and true or false
end

-- A unit's "Name-Realm", the way chat and addon messages name the player. On Forever
-- UnitName's second return is the character's surname, not a realm (retail: the realm), and
-- senders arrive as "First Surname" on my realm, so the two are joined with a space. Forever has
-- no realms, so the key always takes mine there.
function NS.UnitFullName(unit)
  if not UnitName then return nil end
  local ok, name, second = pcall(UnitName, unit)
  if not ok or type(name) ~= "string" or name == "" then return nil end
  if issecretvalue and (issecretvalue(name) or issecretvalue(second)) then return nil end
  if NS.IsForever then
    if NS.IsSurname(second) then name = name .. " " .. second end
    return NS.FullName(name)
  end
  return NS.FullName(name, second)
end

-- Party / raid members other than me: list of "Name-Realm".
function NS.GroupMembers()
  local out = {}
  if not (IsInGroup and IsInGroup() and GetNumGroupMembers and UnitName) then return out end
  local raid = IsInRaid and IsInRaid()
  local n = GetNumGroupMembers() or 0
  for i = 1, raid and n or n - 1 do
    local unit = (raid and "raid" or "party") .. i
    if not (UnitIsUnit and UnitIsUnit(unit, "player")) then
      local full = NS.UnitFullName(unit)
      if full then out[#out + 1] = full end
    end
  end
  return out
end

NS.Register("IGNORELIST_UPDATE", function() NS.Fire("IGNORE_UPDATED") end)

NS.Register("ADDON_LOADED", function(_, name)
  if name == ADDON then
    InitDB()
  end
end)

-- Older versions keyed my character by first name only ("Raion-Realm"); move its data, and my
-- own open posts, to the full key ("Raion Lyzl-Realm"). If both exist the full one wins.
local function MigrateIdentity()
  local old, new = NS.MeLegacy, NS.Me
  if not (old and new) or old == new then return end
  local chars = CraftBoardDB.chars
  if type(chars[old]) == "table" then
    if type(chars[new]) ~= "table" then chars[new] = chars[old] end
    chars[old] = nil
  end
  -- Only posts made here (mine = true): another player's cached post can carry the same
  -- first-name-only sender when they share my first name.
  for _, p in pairs(type(CraftBoardDB.posts) == "table" and CraftBoardDB.posts or {}) do
    if type(p) == "table" and p.mine and p.from == old then p.from = new end
  end
end

-- The surname may not be known yet at login on a slow load: try again on entering the world
-- while the identity is still the first-name-only key.
NS.Register("PLAYER_ENTERING_WORLD", function()
  if not (NS.db and NS.Me and NS.Me == NS.MeLegacy) then return end
  local old = NS.Me
  NS.UpdateIdentity()
  if NS.Me ~= old then
    MigrateIdentity()
    NS.Fire("RECIPES_UPDATED")
  end
end)

NS.Register("PLAYER_LOGIN", function()
  if not NS.db then InitDB() end
  NS.UpdateIdentity()
  MigrateIdentity()
  if NS.Me then
    local c = CraftBoardDB.chars[NS.Me]
    if type(c) ~= "table" then
      c = {}
      CraftBoardDB.chars[NS.Me] = c
    end
    c.recipes = c.recipes or {}
    c.profs = c.profs or {}
    c.faction = NS.Faction
    -- Last login (for /cb chars and to tell forgotten characters apart), class (name colours)
    -- and level (recipe tooltips: whether this character can learn one).
    c.seen = time and time() or nil
    if UnitClass then
      local ok, _, classFile = pcall(UnitClass, "player")
      if ok and type(classFile) == "string" then c.class = classFile end
    end
    if UnitLevel then
      local ok, level = pcall(UnitLevel, "player")
      if ok and type(level) == "number" and not (issecretvalue and issecretvalue(level)) and level > 0 then c.level = level end
    end
  end
end)

NS.Register("PLAYER_LEVEL_UP", function(_, level)
  local c = NS.Me and type(CraftBoardDB) == "table" and type(CraftBoardDB.chars) == "table" and CraftBoardDB.chars[NS.Me]
  if type(c) == "table" and type(level) == "number" and not (issecretvalue and issecretvalue(level)) then c.level = level end
end)

-- /cb chars: my characters CraftBoard remembers, with their last login.
local function PrintChars()
  local L = NS.L
  local chars = type(CraftBoardDB) == "table" and type(CraftBoardDB.chars) == "table" and CraftBoardDB.chars or {}
  local keys = {}
  for key in pairs(chars) do keys[#keys + 1] = key end
  table.sort(keys)
  NS.Print(string.format(L["%d characters remembered:"], #keys))
  for _, key in ipairs(keys) do
    local c = chars[key]
    local n = 0
    for _ in pairs(type(c) == "table" and type(c.recipes) == "table" and c.recipes or {}) do n = n + 1 end
    local seen = type(c) == "table" and type(c.seen) == "number" and c.seen
    local when = key == NS.Me and L["now"]
      or seen and string.format(L["%dd ago"], math.floor((time() - seen) / 86400))
      or L["never"]
    NS.Print("  " .. string.format(L["%s: %d recipes, last seen %s"], NS.ShortName(key), n, when))
  end
end

-- /cb forget <name>: drop a deleted or renamed character's recipes, bags and queue.
local function ForgetChar(name)
  local L = NS.L
  name = strtrim(name or "")
  local chars = type(CraftBoardDB) == "table" and type(CraftBoardDB.chars) == "table" and CraftBoardDB.chars or {}
  if name == "" then
    NS.Print(L["/cb forget <name> - forget one of your characters (see /cb chars)"])
    return
  end
  local target
  for key in pairs(chars) do
    if strlower(key) == strlower(name) or strlower(NS.ShortName(key)) == strlower(name) then target = key break end
  end
  if not target then
    NS.Print(string.format(L["No character named %s. /cb chars lists them."], name))
  elseif target == NS.Me then
    NS.Print(L["That's the character you're playing."])
  else
    chars[target] = nil
    NS.Fire("RECIPES_UPDATED")
    NS.Fire("INVENTORY_UPDATED")
    NS.Print(string.format(L["Forgot %s."], NS.ShortName(target)))
  end
end

-- Slash commands. NS.L comes from Locales.lua, which loads after this file: look it up at call time.
local function PrintHelp()
  local L = NS.L
  NS.Print(L["/cb - open or close CraftBoard"])
  NS.Print(L["/cb find [text] | requests | plan - open a tab (Find searches for the text)"])
  NS.Print(L["/cb busy - toggle busy (CraftBoard users can't whisper you from the board)"])
  NS.Print(L["/cb cd - crafting cooldowns on your characters"])
  NS.Print(L["/cb uses <reagent> - your recipes that use a reagent"])
  NS.Print(L["/cb wish - your wishlist"])
  NS.Print(L["/cb texts - edit the whisper texts CraftBoard types in for you"])
  NS.Print(L["/cb chars - your characters CraftBoard remembers"])
  NS.Print(L["/cb forget <name> - forget one of your characters (see /cb chars)"])
  NS.Print(L["/cb scan - record the open profession window again"])
  NS.Print(L["/cb options - open the settings"])
  NS.Print(L["/cb welcome - show the welcome window again"])
  NS.Print(L["/cb debug, /cb chatdebug - sync and chat watcher details (for bug reports)"])
end

-- /cb debug: known CraftBoard users. Diagnostics stay in English so bug reports read the same.
local function PrintPeers()
  local peers = NS.Comm and NS.Comm.Peers and NS.Comm.Peers()
  if not peers then
    NS.Print("comm module not loaded")
    return
  end
  local names = {}
  for name in pairs(peers) do names[#names + 1] = name end
  table.sort(names)
  NS.Print(string.format("%d peer(s)", #names))
  for i = 1, #names do
    local p = peers[names[i]]
    local n = 0
    if type(p.recipes) == "table" then
      for _ in pairs(p.recipes) do n = n + 1 end
    end
    local ago = p.seen and time and (time() - p.seen) or nil
    NS.Print("  " .. string.format("%s: %d recipes, %s", names[i], n, p.online and "online" or "offline")
      .. (ago and string.format(", seen %dm ago", math.floor(ago / 60)) or ""))
  end
end

-- Forced rescan of the open profession window, reported in chat (/cb scan, shift-click on the
-- minimap button).
function NS.ScanNow()
  local L = NS.L
  if NS.Recipes and NS.Recipes.Scan then
    local n, why = NS.Recipes.Scan(true)
    NS.Print(n and string.format(n == 1 and L["Recorded %d recipe."] or L["Recorded %d recipes."], n)
      or string.format(L["Nothing recorded: %s"], tostring(why)))
  end
end

SLASH_CRAFTBOARD1 = "/cb"
SLASH_CRAFTBOARD2 = "/craftboard"
SlashCmdList["CRAFTBOARD"] = function(msg)
  local L = NS.L
  local cmd, rest = strsplit(" ", strtrim(msg or ""), 2)
  cmd = strlower(cmd or "")
  local tabs = { find = 1, f = 1, requests = 2, request = 2, req = 2, r = 2, plan = 3, p = 3 }
  if cmd == "" then
    if NS.UI and NS.UI.Toggle then
      NS.UI.Toggle()
    else
      NS.Print(L["UI not loaded"])
    end
  elseif tabs[cmd] then
    if NS.UI and NS.UI.ShowTab then
      NS.UI.ShowTab(tabs[cmd])
      -- /cb find <text>: search for it.
      if tabs[cmd] == 1 and rest and strtrim(rest) ~= "" and NS.UI.Search then NS.UI.Search(strtrim(rest)) end
    end
  elseif cmd == "scan" then
    NS.ScanNow()
  elseif cmd == "options" or cmd == "config" then
    if NS.Options and NS.Options.Open then NS.Options.Open() end
  elseif cmd == "welcome" then
    if NS.Welcome and NS.Welcome.Show then NS.Welcome.Show() end
  elseif cmd == "debug" then
    -- /cb debug ondemand: act as if the channel were crowded (Find asks the board, no full lists
    -- from channel players), to try it out with few players around. Plain English like chatdebug.
    if strlower(strtrim(rest or "")) == "ondemand" and type(CraftBoardDB) == "table" then
      CraftBoardDB.forceOnDemand = not CraftBoardDB.forceOnDemand or nil
      if NS.Comm and NS.Comm.RecheckScale then NS.Comm.RecheckScale() end
      NS.Print("on-demand recipe questions forced " .. (CraftBoardDB.forceOnDemand and "on" or "off"))
      return
    end
    if NS.Comm and NS.Comm.Debug then NS.Comm.Debug() end
    PrintPeers()
  elseif cmd == "dump" then
    if rest and strlower(strtrim(rest)) == "clear" and NS.DumpClear then
      NS.DumpClear()
    elseif NS.DumpFrame then
      NS.DumpFrame(rest)
    end
  elseif cmd == "chatdebug" then
    local arg = strlower(strtrim(rest or ""))
    -- /cb chatdebug log [off]: keep the last accepted chat lines (saved) to tune the detector.
    if arg == "log" or arg == "log on" or arg == "log off" then
      local on = arg ~= "log off"
      if NS.ChatWatch and NS.ChatWatch.SetLogging then NS.ChatWatch.SetLogging(on) end
      NS.Print(on and "chat log on: the last 40 accepted lines are saved (/cb chatdebug log off clears them)"
        or "chat log off and cleared")
      return
    end
    local st = NS.ChatWatch and NS.ChatWatch.Stats and NS.ChatWatch.Stats()
    if st then
      NS.Print(string.format("chat events %d, channel %d, accepted %d, secret %d, last channel '%s'",
        st.seen, st.channel, st.accepted, st.secret or 0, st.last))
      -- Distinct channel names accepted so far (" - English" / " - City" suffix dropped).
      local names = {}
      for name in pairs(type(st.bases) == "table" and st.bases or {}) do names[#names + 1] = name end
      table.sort(names)
      NS.Print(string.format("accepted channels: %s", #names > 0 and table.concat(names, ", ") or "none yet"))
    end
  elseif cmd == "chars" or cmd == "characters" then
    PrintChars()
  elseif cmd == "forget" then
    ForgetChar(rest)
  elseif cmd == "cd" or cmd == "cooldowns" then
    if NS.Cooldowns and NS.Cooldowns.Print then NS.Cooldowns.Print() end
  elseif cmd == "texts" or cmd == "templates" then
    if NS.Templates and NS.Templates.Show then NS.Templates.Show() end
  elseif cmd == "wish" or cmd == "wishlist" then
    if NS.Marks and NS.Marks.PrintWishes then NS.Marks.PrintWishes() end
  elseif cmd == "uses" then
    -- /cb uses <reagent>: Plan's recipes that use it.
    if NS.UI and NS.UI.SearchReagent then NS.UI.SearchReagent(strtrim(rest or "")) end
  elseif cmd == "busy" then
    if NS.Comm and NS.Comm.ToggleBusy then NS.Comm.ToggleBusy() end
  elseif cmd == "frames" then
    if NS.ListFrames then NS.ListFrames() end
  else
    PrintHelp()
  end
end
