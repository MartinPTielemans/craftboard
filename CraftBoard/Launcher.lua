-- CraftBoard Launcher: ways to reach the window besides /cb and the Professions button.
-- A LibDataBroker launcher shown as a draggable minimap button by LibDBIcon (state saved in
-- CraftBoardDB.minimap; also listed in the addon compartment when the client has one), the
-- "Toggle CraftBoard window" key binding (Bindings.xml), and a one-time welcome line in chat.
local ADDON, NS = ...

local L = NS.L
local Launcher = {}
NS.Launcher = Launcher

local NAME = "CraftBoard"
local ICON = "Interface\\Icons\\INV_Misc_Note_01"   -- same as the window portrait

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
  if button == "RightButton" then
    if NS.Options and NS.Options.Open then NS.Options.Open() end
  elseif button == "LeftButton" and IsShiftKeyDown and IsShiftKeyDown() then
    NS.ScanNow()
  else
    Toggle()
  end
end

local function OnTooltipShow(tt)
  if not (tt and tt.AddLine) then return end
  tt:AddLine(L["CraftBoard"])
  local status = NS.UI and NS.UI.StatusText and NS.UI.StatusText()
  if status then tt:AddLine(status, 1, 1, 1) end
  tt:AddLine(L["Left-click: open \194\183 Right-click: settings"], 0.6, 0.6, 0.6)
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

NS.Register("PLAYER_LOGIN", function()
  Launcher.Register()
  if type(CraftBoardDB) == "table" and not CraftBoardDB.seenWelcome then
    CraftBoardDB.seenWelcome = true
    -- Not NS.Print: its "CraftBoard:" prefix would repeat the name.
    local msg = L["CraftBoard loaded. Minimap button, /cb, or set a key in Key Bindings."]
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
      DEFAULT_CHAT_FRAME:AddMessage(msg, 0.2, 0.8, 1)
    else
      print(msg)
    end
  end
end)
