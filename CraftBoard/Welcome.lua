-- CraftBoard Welcome: the first-run splash, in the main window's metal portrait frame.
-- Hero art (Media\welcome, 400x200 under the title bar), three steps (slot-framed icon, gold
-- title, grey line) and a button row: red "Open Professions" (or "Get started" when this client
-- has no way to open the profession book) and "Later". "Open Professions" lands on CraftBoard's
-- tab in the Professions window when that is on (Embed.lua).
-- Shown once, 3 s after the first login after install (CraftBoardDB.seenWelcome), never in
-- combat (waits for PLAYER_REGEN_ENABLED). /cb welcome and the options button reopen it.
local ADDON, NS = ...

local L = NS.L
local Welcome = {}
NS.Welcome = Welcome

local NAME = "CraftBoardWelcomeFrame"
local PORTRAIT = "Interface\\Icons\\INV_Misc_Note_01"
local HERO = "Interface\\AddOns\\CraftBoard\\Media\\welcome"
local WIDTH = 420
local HERO_W, HERO_H, HERO_Y = 400, 200, -24   -- under the title bar
local ROW_H, ICON = 44, 32
local ROWS_Y = HERO_Y - HERO_H - 8             -- first step row under the hero
local ROWS_Y_BARE = -64                        -- no hero: clear of the portrait
local BAR_H = 46                               -- button row (28 px red button at 7 px) + gap
local GREY = { 0.78, 0.78, 0.78 }

local STEPS = {
  { icon = "Interface\\Icons\\INV_Misc_Book_09",
    title = L["Record your recipes"],
    body = L["Open each profession window once. CraftBoard records what you can craft."] },
  { icon = "Interface\\Icons\\INV_Misc_GroupLooking", fallback = "Interface\\Icons\\INV_Misc_Note_01",
    title = L["Find crafters"],
    body = L["Guildmates and realm players who run CraftBoard appear in Find."] },
  { icon = "Interface\\Icons\\Ability_Warrior_BattleShout",
    title = L["Ask and offer"],
    body = L["Whisper a crafter, post a request, or announce in Trade."] },
}

local frame, openButton, laterButton
local pending = false          -- asked to show during combat

local function InCombat()
  return InCombatLockdown and InCombatLockdown() and true or false
end

local function Opener()
  local get = NS.Onboarding and NS.Onboarding.ProfessionsOpener
  return type(get) == "function" and get() or nil
end

-- Minimal stand-ins for UI.Kit when UI.lua did not load.
local Plain = {
  NewWindow = function(name)
    return CreateFrame("Frame", name, UIParent, "BasicFrameTemplateWithInset"), false
  end,
  SetTitle = function(f, text)
    local title = f.TitleText or f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if not f.TitleText then title:SetPoint("TOP", 0, -5) end
    title:SetText(text)
  end,
  PanelButton = function(parent, text, width, height)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 80, height or 22)
    b:SetText(text)
    return b
  end,
  HasAtlas = function() return false end,
}

local function Kit()
  local k = NS.UI and NS.UI.Kit
  if type(k) == "table" and k.NewWindow then return k end
  return Plain
end

-- False only when the client says the file does not exist.
local function FileExists(path)
  if type(GetFileIDFromPath) ~= "function" then return true end
  local ok, id = pcall(GetFileIDFromPath, path)
  return not ok or id ~= nil
end

local function SetIcon(tex, path, fallback)
  if fallback and not FileExists(path) then path = fallback end
  if tex:SetTexture(path) == false and fallback then tex:SetTexture(fallback) end
end

-- 32 px icon in a Professions-Slot-Frame box like the reagent slots (bg behind, frame over it at
-- -5,4 / 4,-5); without the atlases, the icon trimmed on a 1 px dark border.
local function SlotIcon(parent, kit)
  local icon = parent:CreateTexture(nil, "ARTWORK")
  icon:SetSize(ICON, ICON)
  if kit.slotBg and kit.slotFrame and kit.HasAtlas(kit.slotBg) and kit.HasAtlas(kit.slotFrame) then
    local bg = parent:CreateTexture(nil, "BACKGROUND", nil, 2)
    bg:SetAtlas(kit.slotBg, false)
    bg:SetAllPoints(icon)
    local border = parent:CreateTexture(nil, "OVERLAY")
    border:SetAtlas(kit.slotFrame, false)
    border:SetPoint("TOPLEFT", icon, "TOPLEFT", -5, 4)
    border:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 4, -5)
    icon.border = border
  else
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local border = parent:CreateTexture(nil, "BORDER")
    border:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0, 0, 0, 0.85)
    icon.border = border
  end
  return icon
end

local function StepRow(parent, kit, step)
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(ROW_H)
  row.icon = SlotIcon(row, kit)
  row.icon:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -6)
  SetIcon(row.icon, step.icon, step.fallback)

  row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.title:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 12, 0)
  row.title:SetPoint("RIGHT", row, "RIGHT", -4, 0)
  row.title:SetJustifyH("LEFT")
  row.title:SetText(step.title)

  row.body = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.body:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -3)
  row.body:SetPoint("RIGHT", row, "RIGHT", -4, 0)
  row.body:SetJustifyH("LEFT")
  row.body:SetJustifyV("TOP")
  if row.body.SetWordWrap then row.body:SetWordWrap(true) end
  if row.body.SetMaxLines then row.body:SetMaxLines(2) end
  row.body:SetTextColor(GREY[1], GREY[2], GREY[3])
  row.body:SetText(step.body)
  return row
end

-- The hero, or nil when the file did not load (then the frame is built without it).
local function Hero(f)
  local hero = f:CreateTexture(nil, "ARTWORK")
  hero:SetSize(HERO_W, HERO_H)
  hero:SetPoint("TOP", f, "TOP", 0, HERO_Y)
  local ok, set = pcall(hero.SetTexture, hero, HERO)
  if not ok or set == false or not hero:GetTexture() then
    hero:Hide()
    return nil
  end
  local edge = f:CreateTexture(nil, "BORDER")
  edge:SetPoint("TOPLEFT", hero, "TOPLEFT", -1, 1)
  edge:SetPoint("BOTTOMRIGHT", hero, "BOTTOMRIGHT", 1, -1)
  edge:SetColorTexture(0, 0, 0, 0.9)
  hero.edge = edge
  return hero
end

local function Create()
  local kit = Kit()
  local f, modern = kit.NewWindow(NAME)
  frame = f
  f:Hide()
  f:SetFrameStrata("DIALOG")      -- over the settings panel when opened from there
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)

  kit.SetTitle(f, L["CraftBoard"])
  if modern then
    if kit.SetPortrait then kit.SetPortrait(f, PORTRAIT) end
    if kit.SetupChrome then kit.SetupChrome(f, true) end
  end

  f.hero = Hero(f)
  local top = f.hero and ROWS_Y or ROWS_Y_BARE
  f.rows = {}
  for i, step in ipairs(STEPS) do
    local row = StepRow(f, kit, step)
    row:SetPoint("TOPLEFT", f, "TOPLEFT", 16, top - (i - 1) * ROW_H)
    row:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    f.rows[i] = row
  end
  f:SetSize(WIDTH, -(top - #STEPS * ROW_H) + BAR_H)

  -- Button row like the main window's (red button at BOTTOMRIGHT -9,7), Later to its left.
  openButton = (kit.RedButton or kit.PanelButton)(f, L["Open Professions"], 150, 28)
  openButton:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -9, 7)
  -- With CraftBoard embedded in the Professions window this opens that window on our tab
  -- (Embed.Open may load it first); otherwise just the profession book.
  openButton:SetScript("OnClick", function()
    f:Hide()
    if InCombat() then return end
    local E = NS.Embed
    if E and E.Open and E.Open(true) then return end
    local fn = Opener()
    if fn then pcall(fn) end
  end)
  laterButton = kit.PanelButton(f, L["Later"], 96, 22)
  laterButton:SetPoint("RIGHT", openButton, "LEFT", -8, 0)
  laterButton:SetScript("OnClick", function() f:Hide() end)

  if UISpecialFrames then tinsert(UISpecialFrames, NAME) end
end

-- Label the buttons for this client: no profession opener -> one "Get started" that closes.
local function SyncButtons()
  local has = Opener() ~= nil
  openButton:SetText(has and L["Open Professions"] or L["Get started"])
  if has then laterButton:Show() else laterButton:Hide() end
end

-- Shows the splash; in combat it waits for combat to end. False when it could not be built.
function Welcome.Show()
  if InCombat() then
    pending = true
    return true
  end
  pending = false
  if not frame then
    local ok, err = pcall(Create)
    if not ok then
      frame = nil
      local eh = geterrorhandler and geterrorhandler()
      if eh then eh(err) end
      return false
    end
  end
  SyncButtons()
  frame:Show()
  if type(CraftBoardDB) == "table" then CraftBoardDB.seenWelcome = true end
  return true
end

function Welcome.Hide()
  pending = false
  if frame then frame:Hide() end
end

function Welcome.Frame()
  return frame
end

local function FirstRun()
  if type(CraftBoardDB) ~= "table" or CraftBoardDB.seenWelcome then return end
  if not Welcome.Show() then
    CraftBoardDB.seenWelcome = true
    NS.Print(L["CraftBoard loaded. Minimap button, /cb, or set a key in Key Bindings."])
  end
end

NS.Register("PLAYER_LOGIN", function()
  if type(CraftBoardDB) ~= "table" or CraftBoardDB.seenWelcome then return end
  if C_Timer and C_Timer.After then C_Timer.After(3, FirstRun) else FirstRun() end
end)

NS.Register("PLAYER_REGEN_ENABLED", function()
  if pending then Welcome.Show() end
end)
