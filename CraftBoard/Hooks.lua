-- CraftBoard Hooks: a small "CraftBoard" button on Blizzard's profession windows that toggles the board.
-- Both Blizzard UIs are load-on-demand, so buttons are attached on ADDON_LOADED (or right away when
-- they are already loaded). Plain, non-secure buttons parented to Blizzard frames; no hooks on
-- secure code, no protected calls. If a frame is missing on this client we silently do nothing.
-- When Embed.lua puts CraftBoard in the Professions window as a tab, it hides these buttons
-- (Hooks.SetShown(false)); they stay the way in on clients where embedding is off or fails.
local ADDON, NS = ...

local L = NS.L
local max = math.max

local Hooks = {}
NS.Hooks = Hooks

local done = {}
local buttons = {}
local shown = true

-- Shows or hides every CraftBoard button on Blizzard's windows, now and for ones made later.
function Hooks.SetShown(v)
  shown = v and true or false
  for i = 1, #buttons do buttons[i]:SetShown(shown) end
end

function Hooks.Buttons()
  return buttons
end

local function OnClick()
  if NS.UI and NS.UI.Toggle then NS.UI.Toggle() end
end

local function OnEnter(self)
  if not GameTooltip then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:SetText(L["Open CraftBoard"])
  GameTooltip:Show()
end

local function OnLeave()
  if GameTooltip then GameTooltip:Hide() end
end

local function MakeButton(name, parent)
  local b = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
  b:SetText("CraftBoard")
  local fs = b:GetFontString()
  if fs and GameFontNormalSmall then
    b:SetNormalFontObject(GameFontNormalSmall)
    b:SetHighlightFontObject(GameFontHighlightSmall or GameFontNormalSmall)
    if GameFontDisableSmall then b:SetDisabledFontObject(GameFontDisableSmall) end
  end
  local w = fs and fs.GetStringWidth and fs:GetStringWidth() or 0
  b:SetSize(max(72, w + 20), 22)
  b:SetFrameLevel(parent:GetFrameLevel() + 10)
  b:SetScript("OnClick", OnClick)
  b:SetScript("OnEnter", OnEnter)
  b:SetScript("OnLeave", OnLeave)
  buttons[#buttons + 1] = b
  b:SetShown(shown)
  return b
end

-- Professions overview. On this client (see docs/professionsframe-dump.txt) the overview is a page
-- inside ProfessionsFrame: ProfessionsFrame.BookPage (673x594, same rect as the frame), with
-- BookPage.ProfessionsContentFrame holding the cards. PrimaryProfession1 is 664x142 at TOPLEFT 5,-41;
-- its name sits at 20,-24 and its 441x18 StatusBar (+ UnlearnButton) is centred vertically at
-- RIGHT -40, so the card's top-right corner (y 0..-50) is free. Parented to BookPage so it hides
-- with the page. Older layouts: ProfessionsBookFrame (Blizzard_ProfessionsBook), then
-- SpellBookFrame's professions tab (SpellBookProfessionFrame).
local function HookBook()
  if done.book then return end
  local page = ProfessionsFrame and ProfessionsFrame.BookPage
  if page then
    done.book = true
    local b = MakeButton("CraftBoardProfessionsBookButton", page)
    local content = page.ProfessionsContentFrame
    local card = content and content.PrimaryProfession1
    if card then
      b:SetPoint("TOPRIGHT", card, "TOPRIGHT", -20, -18)
    else
      b:SetPoint("TOPRIGHT", page, "TOPRIGHT", -24, -58)
    end
    return
  end
  local parent, frame = nil, nil
  if ProfessionsBookFrame then
    parent, frame = ProfessionsBookFrame, ProfessionsBookFrame
  elseif SpellBookProfessionFrame then
    parent, frame = SpellBookProfessionFrame, SpellBookFrame or SpellBookProfessionFrame
  end
  if not parent then return end
  done.book = true
  local b = MakeButton("CraftBoardProfessionsBookButton", parent)
  local card = PrimaryProfession1
  if card and card.GetParent and (card:GetParent() == parent or card:GetParent() == frame) then
    b:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -8)
  else
    b:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -20, -46)
  end
end

-- Crafting window: ProfessionsFrame.CraftingPage (Blizzard_Professions). Parented to the crafting
-- page so it hides on the other tabs. From the dump: CraftingPage is 673x594; RankBar is 453x18 at
-- TOPLEFT 110,-40 (right edge x=563); LinkButton is 23x23, LEFT->RankBar.RIGHT -2,-4, so it spans
-- x=561..584. That leaves 89px to the frame edge, minus the metal border: the button goes 4px right
-- of LinkButton and is capped at 75 wide so its right edge stays at or left of x=663.
-- Fallbacks: right of the rank bar; then the frame's top-right below the title bar.
local CRAFT_MAX_W = 75
local function HookCrafting()
  if done.crafting then return end
  local pf = ProfessionsFrame
  local page = pf and pf.CraftingPage
  if not page then return end
  done.crafting = true
  local b = MakeButton("CraftBoardCraftingButton", page)
  if b:GetWidth() > CRAFT_MAX_W then b:SetWidth(CRAFT_MAX_W) end
  if page.LinkButton then
    b:SetPoint("LEFT", page.LinkButton, "RIGHT", 4, 0)
  elseif page.RankBar then
    b:SetPoint("LEFT", page.RankBar, "RIGHT", 8, -4)
  else
    b:SetPoint("TOPRIGHT", pf, "TOPRIGHT", -12, -30)
  end
end

local function IsLoaded(name)
  if C_AddOns and C_AddOns.IsAddOnLoaded then
    return C_AddOns.IsAddOnLoaded(name)
  elseif IsAddOnLoaded then
    return IsAddOnLoaded(name)
  end
  return false
end

local function TryAll()
  HookBook()
  HookCrafting()
end

NS.Register("ADDON_LOADED", function(_, name)
  if name == "Blizzard_ProfessionsBook" then
    HookBook()
  elseif name == "Blizzard_Professions" then
    HookCrafting()
    HookBook()
  end
end)

-- Already loaded before us (another addon forced them), or the old always-loaded SpellBookFrame.
if IsLoaded("Blizzard_ProfessionsBook") or SpellBookProfessionFrame then HookBook() end
if IsLoaded("Blizzard_Professions") then HookCrafting(); HookBook() end
NS.Register("PLAYER_LOGIN", TryAll)
