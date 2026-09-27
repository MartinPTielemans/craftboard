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
    frame:RegisterEvent(event)
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
function NS.UpdateIdentity()
  local name = UnitName and UnitName("player")
  local realm = GetNormalizedRealmName and GetNormalizedRealmName()
  if (not realm or realm == "") and GetRealmName then
    realm = (GetRealmName() or ""):gsub("[%s%-]", "")
  end
  if name and name ~= "" and realm and realm ~= "" then
    NS.Realm = realm
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

function NS.SamePlayer(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then return false end
  if a == b then return true end
  local na, ra = SplitName(a)
  local nb, rb = SplitName(b)
  if ra ~= rb then return false end
  return na:match("^(%S+)") == nb:match("^(%S+)")
end

-- On my ignore list. Never errors; unknown API = not ignored.
function NS.IsIgnored(full)
  if type(full) ~= "string" or full == "" then return false end
  local check = (C_FriendList and C_FriendList.IsIgnored) or IsIgnored
  if not check then return false end
  local ok, yes = pcall(check, NS.ShortName(full))
  return ok and yes and true or false
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
      local name, realm = UnitName(unit)
      local full = NS.FullName(name, realm)
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

NS.Register("PLAYER_LOGIN", function()
  if not NS.db then InitDB() end
  NS.UpdateIdentity()
  if NS.Me then
    local c = CraftBoardDB.chars[NS.Me]
    if type(c) ~= "table" then
      c = {}
      CraftBoardDB.chars[NS.Me] = c
    end
    c.recipes = c.recipes or {}
    c.profs = c.profs or {}
    c.faction = NS.Faction
  end
end)

-- Slash commands. NS.L comes from Locales.lua, which loads after this file: look it up at call time.
local function PrintHelp()
  local L = NS.L
  NS.Print(L["/cb - toggle window"])
  NS.Print(L["/cb scan - rescan the open profession window"])
  NS.Print(L["/cb options - open the settings panel"])
  NS.Print(L["/cb welcome - show the welcome window again"])
  NS.Print(L["/cb busy - toggle busy (the board won't whisper you)"])
  NS.Print(L["/cb cd - crafting cooldowns on your characters"])
  NS.Print(L["/cb debug - list known peers"])
  NS.Print(L["/cb help - this help"])
end

local function PrintPeers()
  local L = NS.L
  local peers = NS.Comm and NS.Comm.Peers and NS.Comm.Peers()
  if not peers then
    NS.Print(L["comm module not loaded"])
    return
  end
  local names = {}
  for name in pairs(peers) do names[#names + 1] = name end
  table.sort(names)
  NS.Print(string.format(L["%d peer(s)"], #names))
  for i = 1, #names do
    local p = peers[names[i]]
    local n = 0
    if type(p.recipes) == "table" then
      for _ in pairs(p.recipes) do n = n + 1 end
    end
    local ago = p.seen and time and (time() - p.seen) or nil
    NS.Print("  " .. string.format(L["%s: %d recipes, %s"], names[i], n,
      p.online and L["online"] or L["offline"])
      .. (ago and string.format(L[", seen %dm ago"], math.floor(ago / 60)) or ""))
  end
end

-- Forced rescan of the open profession window, reported in chat (/cb scan, shift-click on the
-- minimap button).
function NS.ScanNow()
  local L = NS.L
  if NS.Recipes and NS.Recipes.Scan then
    local n, why = NS.Recipes.Scan(true)
    NS.Print(n and string.format(L["scanned %d recipe(s)"], n) or string.format(L["scan skipped: %s"], tostring(why)))
  end
end

SLASH_CRAFTBOARD1 = "/cb"
SLASH_CRAFTBOARD2 = "/craftboard"
SlashCmdList["CRAFTBOARD"] = function(msg)
  local L = NS.L
  local cmd, rest = strsplit(" ", strtrim(msg or ""), 2)
  cmd = strlower(cmd or "")
  if cmd == "" then
    if NS.UI and NS.UI.Toggle then
      NS.UI.Toggle()
    else
      NS.Print(L["UI not loaded"])
    end
  elseif cmd == "scan" then
    NS.ScanNow()
  elseif cmd == "options" or cmd == "config" then
    if NS.Options and NS.Options.Open then NS.Options.Open() end
  elseif cmd == "welcome" then
    if NS.Welcome and NS.Welcome.Show then NS.Welcome.Show() end
  elseif cmd == "debug" then
    if NS.Comm and NS.Comm.Debug then NS.Comm.Debug() end
    PrintPeers()
  elseif cmd == "dump" then
    if NS.DumpFrame then NS.DumpFrame(rest) end
  elseif cmd == "chatdebug" then
    local st = NS.ChatWatch and NS.ChatWatch.Stats and NS.ChatWatch.Stats()
    if st then
      NS.Print(string.format(L["chat events %d, channel %d, accepted %d, secret %d, last channel '%s'"],
        st.seen, st.channel, st.accepted, st.secret or 0, st.last))
      -- Distinct channel names accepted so far (" - English" / " - City" suffix dropped).
      local names = {}
      for name in pairs(type(st.bases) == "table" and st.bases or {}) do names[#names + 1] = name end
      table.sort(names)
      NS.Print(string.format(L["accepted channels: %s"], #names > 0 and table.concat(names, ", ") or L["none yet"]))
    end
  elseif cmd == "cd" or cmd == "cooldowns" then
    if NS.Cooldowns and NS.Cooldowns.Print then NS.Cooldowns.Print() end
  elseif cmd == "busy" then
    if NS.Comm and NS.Comm.ToggleBusy then NS.Comm.ToggleBusy() end
  elseif cmd == "frames" then
    if NS.ListFrames then NS.ListFrames() end
  else
    PrintHelp()
  end
end
