-- CraftBoard Launcher: ways to reach the window besides /cb and the Professions button.
-- A LibDataBroker launcher shown as a draggable minimap button by LibDBIcon (state saved in
-- CraftBoardDB.minimap; also listed in the addon compartment when the client has one), the
-- "Toggle CraftBoard window" key binding (Bindings.xml). The first-run splash is Welcome.lua.
-- The button's tooltip sums up what is waiting: craftable requests, the queue, ready cooldowns.
local ADDON, NS = ...

local L = NS.L
local format = string.format
local Launcher = {}
NS.Launcher = Launcher

local NAME = "CraftBoard"
local ICON = "Interface\\AddOns\\CraftBoard\\Media\\icon"   -- same as the window portrait

local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)

local function Toggle()
  if NS.UI and NS.UI.Toggle then
    NS.UI.Toggle()
  else
    NS.Print(L["UI not loaded"])
  end
end

-- Key binding (Bindings.xml). No default key.
BINDING_HEADER_CRAFTBOARD = L["CraftBoard"]
BINDING_NAME_CRAFTBOARD_TOGGLE = L["Toggle CraftBoard window"]
function CraftBoard_ToggleBinding()
  Toggle()
end

local function OnClick(_, button)
  local shift = IsShiftKeyDown and IsShiftKeyDown()
  if button == "RightButton" and shift then
    if NS.Comm and NS.Comm.ToggleBusy then NS.Comm.ToggleBusy() end
  elseif button == "RightButton" then
    if NS.Options and NS.Options.Open then NS.Options.Open() end
  elseif button == "LeftButton" and shift then
    NS.ScanNow()
  else
    Toggle()
  end
end

-- Summary lines, each only when it has something to say: requests I can craft, the queue and
-- what it still lacks, cooldowns ready on my characters, a profession rank I can train now.
local function Summary(tt)
  local ok, n = pcall(function() return NS.UI and NS.UI.RequestCount and NS.UI.RequestCount() end)
  if ok and type(n) == "number" and n > 0 then
    tt:AddLine(format(L["%d requests you can craft"], n), 1, 0.82, 0)
  end

  local Q = NS.Queue
  local okQ, entries = pcall(function() return Q and Q.Entries and Q.Entries() end)
  if okQ and type(entries) == "table" and #entries > 0 then
    local missing = 0
    local okT, totals = pcall(Q.Totals)
    for _, r in ipairs(okT and type(totals) == "table" and totals or {}) do
      if type(r) == "table" and (r.have or 0) < (r.need or 0) then missing = missing + 1 end
    end
    local line = format(L["Queue: %d crafts"], #entries)
    if missing > 0 then line = line .. " \194\183 " .. format(L["%d reagents missing"], missing) end
    tt:AddLine(line, 1, 1, 1)
  end

  local okR, ready = pcall(function() return NS.Cooldowns and NS.Cooldowns.Ready and NS.Cooldowns.Ready() end)
  if okR and type(ready) == "table" and #ready > 0 then
    local parts = {}
    for i = 1, math.min(3, #ready) do
      parts[i] = tostring(ready[i].name) .. " (" .. NS.ShortName(ready[i].key) .. ")"
    end
    if #ready > 3 then parts[#parts + 1] = "\226\128\166" end
    tt:AddLine(format(L["Ready: %s"], table.concat(parts, ", ")), 0.1, 1, 0.1, true)
  end

  local S = NS.Skills
  if S and S.Ranks and S.NextRank then
    for _, p in ipairs(S.Ranks()) do
      local r = S.NextRank(p.profID)
      if r and r.ready then
        tt:AddLine(format(L["You can train %s %s at a trainer now."], r.title, p.name), 0.1, 1, 0.1, true)
      end
    end
  end
end

local function OnTooltipShow(tt)
  if not (tt and tt.AddLine) then return end
  tt:AddLine(L["CraftBoard"])
  local status = NS.UI and NS.UI.StatusText and NS.UI.StatusText()
  if status then tt:AddLine(status, 1, 1, 1) end
  Summary(tt)
  if NS.Comm and NS.Comm.IsBusy and NS.Comm.IsBusy() then
    tt:AddLine(L["Busy: you won't be whispered from the board"], 0.62, 0.62, 0.62)
  end
  tt:AddLine(L["Left-click: open \194\183 Right-click: settings"], 0.6, 0.6, 0.6)
  tt:AddLine(L["Shift-right-click: busy / available"], 0.6, 0.6, 0.6)
end

local dataObject = LDB and LDB:NewDataObject(NAME, {
  type = "launcher",
  label = NAME,
  icon = ICON,
  OnClick = OnClick,
  OnTooltipShow = OnTooltipShow,
})
Launcher.dataObject = dataObject

local function MinimapDB()
  if type(CraftBoardDB) ~= "table" then return nil end
  if type(CraftBoardDB.minimap) ~= "table" then CraftBoardDB.minimap = { hide = false } end
  return CraftBoardDB.minimap
end

function Launcher.IsShown()
  local db = MinimapDB()
  return not (db and db.hide)
end

-- Live show/hide from the options checkbox; remembered in CraftBoardDB.minimap.hide.
function Launcher.SetShown(v)
  local db = MinimapDB()
  if db then db.hide = not v end
  if DBIcon and DBIcon.IsRegistered and DBIcon:IsRegistered(NAME) then
    if v then DBIcon:Show(NAME) else DBIcon:Hide(NAME) end
  end
end

local registered = false
function Launcher.Register()
  if registered or not (DBIcon and dataObject) then return end
  local db = MinimapDB()
  if not db then return end
  registered = true
  if not DBIcon:IsRegistered(NAME) then DBIcon:Register(NAME, dataObject, db) end
end

NS.Register("PLAYER_LOGIN", function() Launcher.Register() end)
