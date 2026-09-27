-- CraftBoard Embed: CraftBoard as a tab of Blizzard's Professions window (Blizzard_Professions,
-- ProfessionsFrame; layout in docs/professionsframe-dump.txt). The standalone window stays for
-- clients where this cannot be done, for players without professions, in combat, and when the
-- "Open CraftBoard inside the Professions window" option is off.
--
-- Taint: nothing here goes through Blizzard's tab system. On this client ProfessionsFrame has
-- side tabs (ProfessionsOverviewTab, Professions1..7Tab) and two pages (CraftingPage,
-- BookPage); retail's TabSystemOwnerMixin (AddNamedTab / SetTab / TabSystem) would, if present,
-- store our page in Blizzard's own tab tables, and a SetTab run from our code would then
-- initialise CraftingPage (and the schematic form behind the Create button) under our taint.
-- So instead:
--   * our page (CraftBoardEmbedPage, 673x594) and our side tab (CraftBoardEmbedTab) are plain
--     frames parented to ProfessionsFrame, created without parentKey (no Lua writes into
--     Blizzard's tables); the page is an opaque overlay one frame level above Blizzard's pages;
--     Blizzard's pages are never shown, hidden or re-anchored by us;
--   * clicking a Blizzard tab hides our page: HookScript on the tabs' own click/mouse scripts,
--     HookScript OnShow on CraftingPage / BookPage, hooksecurefunc(ProfessionsFrame, "SetTab")
--     when that method exists (plain Lua, a post-hook), TRADE_SKILL_SHOW. All post-hooks: the
--     Blizzard code runs first and untouched;
--   * while our page is up, Blizzard's selected tab marker is faded with SetAlpha (a C call on a
--     texture, no Lua state) and restored when our page hides;
--   * ESC closes ProfessionsFrame as usual (it is Blizzard's UI panel); our page hides with it.
-- Opening ProfessionsFrame for /cb, the minimap button and the key binding uses the same opener
-- as the tips (ToggleProfessionsBook on this client), outside combat only, and only when
-- Blizzard_Professions is already loaded; otherwise the standalone window opens.
local ADDON, NS = ...

local L = NS.L
local max, min = math.max, math.min

local Embed = {}
NS.Embed = Embed

local PAGE_NAME, TAB_NAME = "CraftBoardEmbedPage", "CraftBoardEmbedTab"
local WIDTH, HEIGHT = 673, 594   -- ProfessionsFrame / CraftingPage / BookPage
local TAB_GAP = 2                -- Blizzard's side tabs: TOPLEFT->previous tab's BOTTOMLEFT 0,-2
local FIRST_TAB_Y = -60          -- ProfessionsOverviewTab: TOPLEFT->ProfessionsFrame.TOPRIGHT 0,-60
local SUB_GAP = 12               -- our Find / Requests tabs, set apart under our tab
local TITLE_H = 24               -- title bar + close button: left to Blizzard's frame for the mouse
local GUARD = 0.3                -- s after selecting in which Blizzard page changes don't deselect
local SIDETAB = "common-sidetab"

local pf, page, tab, ctl
local built, failed = false, false
local blizzTabs = {}             -- Blizzard's side tabs, top to bottom
local hooked = {}                -- [frame] = true once its scripts are hooked
local dimmed = {}                -- Blizzard selected-tab textures faded while our page is up
local selectedAt = -1

local function Now()
  return (GetTime and GetTime()) or 0
end

local function InCombat()
  return InCombatLockdown and InCombatLockdown() and true or false
end

local function IsLoaded(name)
  if C_AddOns and C_AddOns.IsAddOnLoaded then return C_AddOns.IsAddOnLoaded(name) and true or false end
  if IsAddOnLoaded then return IsAddOnLoaded(name) and true or false end
  return false
end

local function Kit()
  local k = NS.UI and NS.UI.Kit
  if type(k) == "table" and k.SideTab and k.HasAtlases and k.atlas then return k end
  return nil
end

local function Opener()
  local get = NS.Onboarding and NS.Onboarding.ProfessionsOpener
  return type(get) == "function" and get() or nil
end

-- At least one profession learned (primary or secondary). Without the API: assume yes.
local function HasProfession()
  if type(GetProfessions) ~= "function" then return true end
  local ok, a, b, c, d, e = pcall(GetProfessions)
  if not ok then return true end
  return (a or b or c or d or e) ~= nil
end

-- Option "Open CraftBoard inside the Professions window" (CraftBoardDB.embed, default on).
function Embed.IsEnabled()
  return not (type(CraftBoardDB) == "table" and CraftBoardDB.embed == false)
end

-- The tab exists on ProfessionsFrame and the option is on.
function Embed.IsActive()
  return built and Embed.IsEnabled()
end

function Embed.Page() return page end
function Embed.Tab() return tab end
function Embed.Controller() return ctl end

-- Our page is the one showing in ProfessionsFrame.
function Embed.IsShown()
  return built and page:IsShown() and pf:IsShown() and true or false
end

-- Blizzard's side tabs ------------------------------------------------------------

local function AtlasOf(r)
  if type(r) ~= "table" or not r.GetAtlas then return nil end
  local ok, a = pcall(r.GetAtlas, r)
  return ok and a or nil
end

local function IsSideTab(f)
  if type(f) ~= "table" or f == tab or f == page then return false end
  if AtlasOf(f.Background) == SIDETAB then return true end
  if f.GetRegions then
    for _, r in ipairs({ f:GetRegions() }) do
      if AtlasOf(r) == SIDETAB then return true end
    end
  end
  return false
end

local function RelativeTo(f)
  if not f.GetPoint then return nil end
  local ok, _, rel = pcall(f.GetPoint, f, 1)
  return ok and rel or nil
end

-- ProfessionsOverviewTab, Professions1..12Tab, then any other child with the common-sidetab
-- background; ordered along their anchor chain (each hangs off the previous one's BOTTOMLEFT)
-- when they form one, else in that order.
local function FindTabs()
  local list, seen = {}, {}
  local function add(f)
    if type(f) == "table" and f.GetObjectType and f ~= tab and f ~= page and not seen[f] then
      seen[f] = true
      list[#list + 1] = f
    end
  end
  add(pf.ProfessionsOverviewTab)
  for i = 1, 12 do add(pf["Professions" .. i .. "Tab"]) end
  if pf.GetChildren then
    for _, c in ipairs({ pf:GetChildren() }) do
      if not seen[c] and IsSideTab(c) then add(c) end
    end
  end
  local nextOf, heads, clash = {}, {}, false
  for _, f in ipairs(list) do
    local rel = RelativeTo(f)
    if rel and seen[rel] then
      if nextOf[rel] then clash = true end
      nextOf[rel] = f
    else
      heads[#heads + 1] = f
    end
  end
  if clash or #heads ~= 1 then return list end
  local chain, f = {}, heads[1]
  while f and #chain <= #list do
    chain[#chain + 1] = f
    f = nextOf[f]
  end
  return #chain == #list and chain or list
end

-- Our tab under the lowest shown Blizzard side tab; where the first one would be without any.
local function PlaceTab()
  blizzTabs = FindTabs()
  local last
  for _, f in ipairs(blizzTabs) do
    if f:IsShown() then last = f end
  end
  tab:ClearAllPoints()
  if last then
    tab:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -TAB_GAP)
  else
    tab:SetPoint("TOPLEFT", pf, "TOPRIGHT", 0, FIRST_TAB_Y)
  end
end

-- Fades (or restores) the selected marker of Blizzard's current tab.
local function Dim(on)
  for i = #dimmed, 1, -1 do
    dimmed[i]:SetAlpha(1)
    dimmed[i] = nil
  end
  if not on then return end
  for _, f in ipairs(blizzTabs) do
    local s = f.SelectedTexture
    if type(s) == "table" and s.SetAlpha and s.IsShown and s:IsShown() then
      s:SetAlpha(0)
      dimmed[#dimmed + 1] = s
    end
  end
end

local function SetSelected(on)
  if tab and tab.cbSelected then tab.cbSelected:SetShown(on) end
  Dim(on)
end

-- Page level ----------------------------------------------------------------------
-- One above the highest frame of Blizzard's pages (CraftingPage, BookPage, and any other shown
-- child covering the whole frame), so the overlay hides them without touching them.

local function MaxLevel(f, depth)
  local m = f.GetFrameLevel and f:GetFrameLevel() or 0
  if depth < 25 and f.GetChildren then
    for _, c in ipairs({ f:GetChildren() }) do
      local l = MaxLevel(c, depth + 1)
      if l > m then m = l end
    end
  end
  return m
end

local function Raise()
  local top = pf:GetFrameLevel() or 0
  local w, h = pf:GetWidth() or WIDTH, pf:GetHeight() or HEIGHT
  for _, c in ipairs({ pf:GetChildren() }) do
    if c ~= page and c ~= tab and c ~= pf.NineSlice and c ~= pf.FrameGlow then
      local isPage = c == pf.CraftingPage or c == pf.BookPage
        or (c:IsShown() and (c:GetWidth() or 0) >= w - 4 and (c:GetHeight() or 0) >= h - 4)
      if isPage then top = max(top, MaxLevel(c, 0)) end
    end
  end
  page:SetFrameLevel(min(top + 1, 9000))
end

-- Deselecting ---------------------------------------------------------------------

function Embed.Deselect()
  if built and page:IsShown() then page:Hide() end
end

-- Blizzard changing its page on its own right after we selected ours (a deferred refresh from
-- the opener) must not undo the selection; a click on a Blizzard tab always does.
local function AutoDeselect()
  if Now() - selectedAt >= GUARD then Embed.Deselect() end
end

local function OnBlizzardTab()
  Embed.Deselect()
end

local CLICK_SCRIPTS = { "OnClick", "OnMouseDown", "OnMouseUp" }

-- Post-hooks f's existing click scripts; true when it had any.
local function HookClicks(f)
  local any = false
  if not (f.HookScript and f.GetScript) then return false end
  for _, s in ipairs(CLICK_SCRIPTS) do
    if (not f.HasScript or f:HasScript(s)) and f:GetScript(s) then
      f:HookScript(s, OnBlizzardTab)
      any = true
    end
  end
  return any
end

-- Post-hooks on a Blizzard tab: its click scripts (or those of a button inside it) deselect us,
-- showing / hiding it moves our tab.
local function HookTab(f)
  if hooked[f] or not f.HookScript then return end
  hooked[f] = true
  local any = HookClicks(f)
  if f.GetChildren then
    for _, c in ipairs({ f:GetChildren() }) do
      if HookClicks(c) then any = true end
    end
  end
  if not any and f.IsMouseEnabled and f:IsMouseEnabled() and (not f.HasScript or f:HasScript("OnMouseDown")) then
    f:HookScript("OnMouseDown", OnBlizzardTab)
  end
  f:HookScript("OnShow", function() if built then PlaceTab() end end)
  f:HookScript("OnHide", function() if built then PlaceTab() end end)
end

local function HookAll()
  for _, f in ipairs(blizzTabs) do HookTab(f) end
  -- Retail's top tab bar, if this client has one.
  local ts = pf.TabSystem
  if type(ts) == "table" and ts.GetChildren then
    for _, c in ipairs({ ts:GetChildren() }) do
      if not hooked[c] and c.HookScript and (not c.HasScript or c:HasScript("OnClick")) then
        hooked[c] = true
        c:HookScript("OnClick", OnBlizzardTab)
      end
    end
  end
end

-- Building ------------------------------------------------------------------------

local function BuildPage(kit)
  page = CreateFrame("Frame", PAGE_NAME, pf)
  page:Hide()
  page:SetSize(WIDTH, HEIGHT)
  page:SetPoint("TOPLEFT", pf, "TOPLEFT", 0, 0)
  page:SetPoint("BOTTOMRIGHT", pf, "BOTTOMRIGHT", 0, 0)
  -- Swallow clicks and the wheel over Blizzard's hidden page, but not on the title bar.
  page:EnableMouse(true)
  if page.SetHitRectInsets then page:SetHitRectInsets(0, 0, TITLE_H, 0) end
  if page.EnableMouseWheel then
    page:EnableMouseWheel(true)
    page:SetScript("OnMouseWheel", function() end)
  end
  -- CraftingPage's background: Profession-Background-Overview (ProfessionsFrameBg, 2,-21 /
  -- -2,2) with Profession-Background-Template2 over it (665x570 at 3,-21), on a dark fill.
  local A = kit.atlas
  local fill = page:CreateTexture(nil, "BACKGROUND", nil, -8)
  fill:SetPoint("TOPLEFT", page, "TOPLEFT", 2, -21)
  fill:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -2, 2)
  fill:SetColorTexture(0.05, 0.04, 0.03, 1)
  if kit.HasAtlas(A.frameBg) then
    local bg = page:CreateTexture(nil, "BACKGROUND", nil, -7)
    bg:SetAtlas(A.frameBg, false)
    bg:SetAllPoints(fill)
  end
  if kit.HasAtlas(A.pageBg) then
    local bg = page:CreateTexture(nil, "BACKGROUND", nil, 1)
    bg:SetAtlas(A.pageBg, false)
    bg:SetPoint("TOPLEFT", page, "TOPLEFT", 3, -21)
    bg:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -5, 3)
  end
  page:HookScript("OnHide", function() SetSelected(false) end)
  -- Find / Requests side tabs under our tab (Blizzard's column already fills the usual spot).
  ctl = NS.UI.BuildContent(page, {
    placeTabs = function(t1, side)
      if not side then return false end
      t1:SetPoint("TOPLEFT", tab, "BOTTOMLEFT", 0, -SUB_GAP)
    end,
  })
end

local function BuildTab(kit)
  tab = kit.SideTab(pf, TAB_NAME, kit.portrait, L["CraftBoard"])
  tab:SetScript("OnClick", function()
    if not page:IsShown() then Embed.Select() end
  end)
end

local function HookFrame()
  pf:HookScript("OnShow", function()
    if not built then return end
    PlaceTab()
    HookAll()
  end)
  pf:HookScript("OnHide", function()
    if built and page:IsShown() then page:Hide() end
  end)
  for _, key in ipairs({ "CraftingPage", "BookPage" }) do
    local p = pf[key]
    if type(p) == "table" and p.HookScript then p:HookScript("OnShow", AutoDeselect) end
  end
  if type(pf.SetTab) == "function" and hooksecurefunc then
    hooksecurefunc(pf, "SetTab", AutoDeselect)
  end
end

-- Shows or hides the tab for the option, and the Hooks.lua buttons the other way round.
local function Apply()
  if not built then return end
  local on = Embed.IsEnabled()
  tab:SetShown(on)
  if not on then Embed.Deselect() end
  if NS.Hooks and NS.Hooks.SetShown then NS.Hooks.SetShown(not on) end
end

-- Builds the page and tab once ProfessionsFrame exists. False (standalone mode) when it does
-- not, or when this client's Professions window is not the side-tab design.
local function Build()
  if built then return true end
  if failed then return false end
  pf = ProfessionsFrame
  local kit = Kit()
  if type(pf) ~= "table" or not (kit and CreateFrame and pf.HookScript and pf.GetChildren and pf.GetFrameLevel) then
    return false
  end
  local A = kit.atlas
  if not kit.HasAtlases(A.sidetab, A.sidetabSel, A.sidetabHover) then
    failed = true
    return false
  end
  local ok, err = pcall(function()
    BuildTab(kit)
    BuildPage(kit)
    PlaceTab()
    HookAll()
    HookFrame()
  end)
  if not ok then
    failed = true
    if page then page:Hide() end
    if tab then tab:Hide() end
    local eh = geterrorhandler and geterrorhandler()
    if eh then eh(err) end
    return false
  end
  built = true
  Apply()
  return true
end
Embed.Build = Build

-- Shows our page in the (open) Professions window and marks our tab selected.
function Embed.Select()
  if not (Embed.IsActive() and pf:IsShown()) then return false end
  selectedAt = Now()
  PlaceTab()
  HookAll()
  Raise()
  ctl.Show()
  SetSelected(true)
  return true
end

-- Opens CraftBoard inside the Professions window: selects our tab, opening ProfessionsFrame first
-- when it is closed. Needs the option on, no combat, and (unless allowLoad) Blizzard_Professions
-- already loaded and at least one profession. allowLoad (Welcome's button) may run the opener to
-- load and open the Professions window, then selects our tab if it could be built. True when
-- something was opened; false means "use the standalone window".
function Embed.Open(allowLoad)
  if not Embed.IsEnabled() or InCombat() then return false end
  if not built and not allowLoad then return false end
  if built and not allowLoad and not HasProfession() then return false end
  if not (built and pf:IsShown()) then
    local opener = Opener()
    if not opener or not pcall(opener) then return false end
    if not built then Build() end
    if not (built and pf:IsShown()) then return allowLoad and true or false end
  end
  if HasProfession() then Embed.Select() end
  return true
end

-- Closes the Professions window our page is in (UI.Hide / Toggle while it shows).
function Embed.Close()
  if not (built and pf:IsShown()) then return end
  if HideUIPanel then pcall(HideUIPanel, pf) end
  if pf:IsShown() then pf:Hide() end
end

-- Options: live on / off.
function Embed.SetEnabled(v)
  if type(CraftBoardDB) == "table" then CraftBoardDB.embed = v and true or false end
  if v and not built then Build() end
  Apply()
end

NS.Register("ADDON_LOADED", function(_, name)
  if name == "Blizzard_Professions" then Build() end
end)

NS.Register("PLAYER_LOGIN", function()
  if IsLoaded("Blizzard_Professions") then Build() end
  Apply()   -- saved option now known
end)

NS.Register("TRADE_SKILL_SHOW", AutoDeselect)

if IsLoaded("Blizzard_Professions") then Build() end
