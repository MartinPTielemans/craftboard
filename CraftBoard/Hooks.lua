-- CraftBoard Hooks: a small "CraftBoard" button on Blizzard's profession windows that toggles the board.
-- Both Blizzard UIs are load-on-demand, so buttons are attached on ADDON_LOADED (or right away when
-- they are already loaded). Plain, non-secure buttons parented to Blizzard frames; no hooks on
-- secure code, no protected calls. If a frame is missing on this client we silently do nothing.
local ADDON, NS = ...

local L = NS.L
local max = math.max

local done = {}

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
  return b
end

-- Professions overview. Modern: ProfessionsBookFrame (Blizzard_ProfessionsBook).
-- Older layouts: SpellBookFrame's professions tab (SpellBookProfessionFrame).
-- Anchor: top-right corner inside the first primary-profession card (free space right of the
-- "Leatherworking" header, above the skill bar and its unlearn button); frame corner as fallback.
local function HookBook()
  if done.book then return end
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
-- page so it hides on the other tabs. Anchor: right of the link-to-chat icon next to the rank bar;
-- then right of the rank bar; then the frame's top-right below the title bar.
local function HookCrafting()
  if done.crafting then return end
  local pf = ProfessionsFrame
  local page = pf and pf.CraftingPage
  if not page then return end
  done.crafting = true
  local b = MakeButton("CraftBoardCraftingButton", page)
  if page.LinkButton then
    b:SetPoint("LEFT", page.LinkButton, "RIGHT", 6, 0)
  elseif page.RankBar then
    b:SetPoint("LEFT", page.RankBar, "RIGHT", 36, 0)
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
  end
end)

-- Already loaded before us (another addon forced them), or the old always-loaded SpellBookFrame.
if IsLoaded("Blizzard_ProfessionsBook") or SpellBookProfessionFrame then HookBook() end
if IsLoaded("Blizzard_Professions") then HookCrafting() end
NS.Register("PLAYER_LOGIN", TryAll)
