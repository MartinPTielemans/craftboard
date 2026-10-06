-- CraftBoard Launcher: ways to reach the window besides /cb and the Professions button.
-- A LibDataBroker launcher shown as a draggable minimap button by LibDBIcon (state saved in
-- CraftBoardDB.minimap; also listed in the addon compartment when the client has one), the
-- "Toggle CraftBoard window" key binding (Bindings.xml). The first-run splash is Welcome.lua.
-- The button's tooltip sums up what is waiting: craftable requests, the queue, ready cooldowns,
-- ranks to train. Broker displays that show text get a short version ("3 requests · 1 ready"),
-- kept current from BADGE_UPDATED / QUEUE_UPDATED / COOLDOWNS_UPDATED and once a minute
-- (cooldowns run out without an event).
local ADDON, NS = ...

local L = NS.L
local format = string.format
local Launcher = {}
NS.Launcher = Launcher

local NAME = "CraftBoard"
local ICON = "Interface\\AddOns\\CraftBoard\\Media\\icon"   -- same as the window portrait
local DOT = " \194\183 "

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

-- Left: open / close; shift-left: record the open profession again (/cb scan); right: settings;
-- shift-right: busy / available.
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

-- What is waiting ------------------------------------------------------------------

-- Other players' requests I can craft (UI's count).
local function Requests()
  local ok, n = pcall(function() return NS.UI and NS.UI.RequestCount and NS.UI.RequestCount() end)
  return ok and type(n) == "number" and n or 0
end

-- Crafts the queue still has to make (entries' item counts over their yield, minus crafts
-- made), and (withMissing) how many of its reagents I'm short of.
local function QueueState(withMissing)
  local Q = NS.Queue
  if not (Q and Q.Entries and Q.CraftsLeft) then return 0, 0 end
  local ok, crafts = pcall(function()
    local mine = NS.Recipes and NS.Recipes.Mine and NS.Recipes.Mine() or {}
    local n = 0
    for _, x in ipairs(Q.Entries()) do
      local rec = mine[x.recipeID]
      if rec then n = n + (Q.CraftsLeft(x, rec) or 0) end
    end
    return n
  end)
  crafts = ok and type(crafts) == "number" and crafts or 0
  local missing = 0
  if withMissing and crafts > 0 and Q.Totals then
    local okT, totals = pcall(Q.Totals)
    for _, r in ipairs(okT and type(totals) == "table" and totals or {}) do
      if type(r) == "table" and (r.have or 0) < (r.need or 0) then missing = missing + 1 end
    end
  end
  return crafts, missing
end

-- Ready cooldowns on my characters, transmutes that share a cooldown as one.
local function ReadyGroups()
  local C = NS.Cooldowns
  local ok, groups = pcall(function() return C and C.ReadyGroups and C.ReadyGroups() end)
  return ok and type(groups) == "table" and groups or {}
end

-- Summary lines, each only when it has something to say: requests I can craft, the queue and
-- what it still lacks, cooldowns ready on my characters, ranks and recipes I can train now.
local function Summary(tt)
  local n = Requests()
  if n > 0 then
    tt:AddLine(format(n == 1 and L["%d request you can craft"] or L["%d requests you can craft"], n), 1, 0.82, 0)
  end

  local crafts, missing = QueueState(true)
  if crafts > 0 then
    local line = format(crafts == 1 and L["Queue: %d craft"] or L["Queue: %d crafts"], crafts)
    if missing > 0 then line = line .. DOT .. format(L["%d reagents missing"], missing) end
    tt:AddLine(line, 1, 1, 1)
  end

  local ready = ReadyGroups()
  if #ready > 0 then
    local parts = {}
    for i = 1, math.min(3, #ready) do
      parts[i] = tostring(ready[i].name) .. " (" .. NS.ShortName(ready[i].key) .. ")"
    end
    if #ready > 3 then parts[#parts + 1] = "\226\128\166" end
    tt:AddLine(format(L["Ready: %s"], table.concat(parts, ", ")), 0.1, 1, 0.1, true)
  end

  -- One "Train now" line for ranks a trainer teaches and trainers with new recipes; ranks from
  -- a book or quest (Cooking, First Aid, Fishing) get their own line.
  local S = NS.Skills
  if S and S.Ranks and S.NextRank then
    local train, other = {}, {}
    for _, p in ipairs(S.Ranks()) do
      local r = S.NextRank(p.profID)
      local t = S.Trainer and S.Trainer(p.profID)
      if r and r.ready and r.source ~= "trainer" and S.ReadyText then
        other[#other + 1] = S.ReadyText(p.name, r)
      elseif r and r.ready then
        train[#train + 1] = p.name .. " (" .. tostring(r.title) .. ")"
      elseif type(t) == "table" and ((type(t.available) == "number" and t.available > 0)
        or (type(t.next) == "number" and type(p.rank) == "number" and p.rank >= t.next)) then
        train[#train + 1] = p.name .. " (" .. L["new recipes"] .. ")"
      end
    end
    if #train > 0 then tt:AddLine(format(L["Train now: %s"], table.concat(train, ", ")), 0.1, 1, 0.1, true) end
    for _, line in ipairs(other) do tt:AddLine(line, 0.1, 1, 0.1, true) end
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
  tt:AddLine(L["Left-click: open or close \194\183 Right-click: settings"], 0.6, 0.6, 0.6)
  tt:AddLine(L["Shift-left-click: record the open profession again"], 0.6, 0.6, 0.6)
  tt:AddLine(L["Shift-right-click: busy / available"], 0.6, 0.6, 0.6)
end

local dataObject = LDB and LDB:NewDataObject(NAME, {
  type = "launcher",
  label = NAME,
  icon = ICON,
  text = "",
  OnClick = OnClick,
  OnTooltipShow = OnTooltipShow,
})
Launcher.dataObject = dataObject

-- Broker text: "3 requests · 5 queued · 1 ready", "" when nothing is waiting.
function Launcher.Text()
  local parts = {}
  local n = Requests()
  if n > 0 then parts[#parts + 1] = format(n == 1 and L["%d request"] or L["%d requests"], n) end
  local crafts = QueueState()
  if crafts > 0 then parts[#parts + 1] = format(L["%d queued"], crafts) end
  local ready = #ReadyGroups()
  if ready > 0 then parts[#parts + 1] = format(ready == 1 and L["%d cooldown ready"] or L["%d cooldowns ready"], ready) end
  return table.concat(parts, DOT)
end

local textPending = false
local function UpdateText()
  if not dataObject or textPending then return end
  textPending = true
  C_Timer.After(1, function()
    textPending = false
    local ok, text = pcall(Launcher.Text)
    dataObject.text = ok and text or ""
  end)
end

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

NS.Register("PLAYER_LOGIN", function()
  Launcher.Register()
  if dataObject then
    C_Timer.After(10, UpdateText)
    if C_Timer.NewTicker then C_Timer.NewTicker(60, UpdateText) end
  end
end)
if NS.RegisterCallback and dataObject then
  for _, ev in ipairs({ "BADGE_UPDATED", "QUEUE_UPDATED", "COOLDOWNS_UPDATED" }) do
    NS.RegisterCallback(Launcher, ev, UpdateText)
  end
end
