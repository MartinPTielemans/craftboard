-- CraftBoard Onboarding: four first-run tips on the window, using Blizzard's HelpTip.
-- Each tip is shown at most once (CraftBoardDB.tips[key] = true when shown; the "Show tips
-- again" setting clears the table and opens CraftBoard on Find). Without HelpTip on this client,
-- nothing is shown.
--   scan     window opens and this character has no recorded recipes -> the Find list
--   shared   recipes were recorded this session and the window is shown -> the status line
--   request  a recipe is picked in Find after "shared" has gone -> the Post request button
--   plan     the window is shown, this character has recorded recipes and no other tip is up
--            -> the Plan tab
-- UI calls Onboarding.Check("shown") when the window opens and Check("selected") when the player
-- picks a recipe; RECIPES_UPDATED is watched here. Anchors come from UI.TipAnchors, i.e. from
-- whichever host shows CraftBoard (standalone window or its tab in the Professions window).
local ADDON, NS = ...

local L = NS.L
local Onboarding = {}
NS.Onboarding = Onboarding

local TEXT = {
  scan = L["Open each of your profession windows once. CraftBoard records your recipes as you do."],
  shared = L["Your recipes are now shared with guildmates and realm players who run CraftBoard. Everyone on the board appears in Find."],
  request = L["Post a request to the board, or whisper a crafter directly."],
  plan = L["Plan shows your recipes by skill-up color and what to craft next."],
}

local showing = {}       -- [key] = parent frame the tip was shown on (this session)
local recorded = false   -- RECIPES_UPDATED with recipes seen this session
local tour = false          -- set by Reset so the tour plays even with recipes recorded
local openButton         -- "Open Professions" under the scan tip

local function Available()
  return type(HelpTip) == "table" and type(HelpTip.Show) == "function"
end

local function Tips()
  if type(CraftBoardDB) ~= "table" then return nil end
  if type(CraftBoardDB.tips) ~= "table" then CraftBoardDB.tips = {} end
  return CraftBoardDB.tips
end

-- Recipes recorded for the character I'm playing.
local function MyRecipeCount()
  local c = NS.Me and type(CraftBoardDB) == "table" and type(CraftBoardDB.chars) == "table"
    and CraftBoardDB.chars[NS.Me]
  local n = 0
  if type(c) == "table" and type(c.recipes) == "table" then
    for _ in pairs(c.recipes) do n = n + 1 end
  end
  return n
end

local function IsShowing(key)
  local parent = showing[key]
  if not parent then return false end
  if type(HelpTip.IsShowing) == "function" then
    local ok, v = pcall(HelpTip.IsShowing, HelpTip, parent, TEXT[key])
    if ok then
      if not v then showing[key] = nil end
      return v and true or false
    end
  end
  return true
end

-- First opener that exists on this client for the profession book / Professions window.
local function ProfessionsOpener()
  if type(ToggleProfessionsBook) == "function" then
    return ToggleProfessionsBook
  end
  if type(ToggleSpellBook) == "function" and BOOKTYPE_PROFESSION then
    return function() ToggleSpellBook(BOOKTYPE_PROFESSION) end
  end
  if type(PlayerSpellsUtil) == "table" and type(PlayerSpellsUtil.ToggleProfessionsFrame) == "function" then
    return function() PlayerSpellsUtil.ToggleProfessionsFrame() end
  end
  return nil
end
Onboarding.ProfessionsOpener = ProfessionsOpener

-- The pooled HelpTip frame showing `info`, if the pool is reachable.
local function TipFrame(info)
  local pool = HelpTip.framePool
  if type(pool) ~= "table" or type(pool.EnumerateActive) ~= "function" then return nil end
  local ok, found = pcall(function()
    for f in pool:EnumerateActive() do
      if f.info == info then return f end
    end
  end)
  return ok and found or nil
end

local function HideOpenButton()
  if openButton then openButton:Hide() end
end

-- What "Open Professions" under the scan tip does: inside the Professions window, step off our
-- tab to Blizzard's page underneath (its profession tabs are right there); in the standalone
-- window, open the profession book. nil when neither is possible.
local function OpenAction(a)
  if a and a.embedded and NS.Embed and NS.Embed.Deselect then
    return function() NS.Embed.Deselect() end
  end
  if not ProfessionsOpener() then return nil end
  return function()
    local fn = ProfessionsOpener()
    if fn then pcall(fn) end
  end
end

local function ShowOpenButton(parent, info, anchor, action)
  if not action then return end
  if not openButton then
    openButton = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    openButton:SetSize(140, 22)
    openButton:SetText(L["Open Professions"])
    openButton:SetScript("OnClick", function(self)
      if InCombatLockdown and InCombatLockdown() then return end
      if self.cbAction then self.cbAction() end
    end)
  end
  openButton.cbAction = action
  openButton:SetParent(parent)
  openButton:ClearAllPoints()
  local tip = TipFrame(info)
  if tip then
    openButton:SetPoint("TOP", tip, "BOTTOM", 0, -4)
    if tip.GetFrameStrata then openButton:SetFrameStrata(tip:GetFrameStrata()) end
    if tip.GetFrameLevel then openButton:SetFrameLevel(tip:GetFrameLevel() + 5) end
  else
    openButton:SetPoint("BOTTOM", anchor, "BOTTOM", 0, 24)
    openButton:SetFrameLevel((anchor:GetFrameLevel() or 1) + 10)
  end
  openButton:Show()
end

-- buttonAction: when given, an "Open Professions" button under the tip runs it.
local function Show(key, parent, anchor, targetPoint, buttonAction)
  local tips = Tips()
  if not (tips and parent and anchor) then return false end
  local P = HelpTip.Point or {}
  local S = HelpTip.ButtonStyle or {}
  local info = {
    text = TEXT[key],
    buttonStyle = key == "scan" and S.Close or S.Okay,
    targetPoint = P[targetPoint],
    alignment = HelpTip.Alignment and HelpTip.Alignment.Center,
    checkCVars = false,
    onAcknowledgeCallback = function()
      showing[key] = nil
      if key == "scan" then HideOpenButton() end
      if tour and key ~= "plan" then C_Timer.After(0.2, function() Onboarding.Check("shown") end) end
    end,
    onHideCallback = function()
      showing[key] = nil
      if key == "scan" then HideOpenButton() end
    end,
  }
  local ok = pcall(HelpTip.Show, HelpTip, parent, info, anchor)
  if not ok then return false end
  tips[key] = true
  showing[key] = parent
  if buttonAction then ShowOpenButton(parent, info, anchor, buttonAction) end
  return true
end

local function Acknowledge(key)
  local parent = showing[key]
  if not parent then return end
  showing[key] = nil
  if key == "scan" then HideOpenButton() end
  local fn = HelpTip.Acknowledge or HelpTip.Hide
  if type(fn) == "function" then pcall(fn, HelpTip, parent, TEXT[key]) end
end

-- context: "shown" (window opened), "recipes" (RECIPES_UPDATED), "selected" (recipe picked in Find).
function Onboarding.Check(context)
  if not Available() then return end
  local tips = Tips()
  if not tips then return end

  if context == "recipes" and MyRecipeCount() > 0 then
    recorded = true
    Acknowledge("scan")
  end

  local a = NS.UI and NS.UI.TipAnchors and NS.UI.TipAnchors()
  if not (a and a.shown) then return end

  if not tips.scan and context == "shown" and a.findTab and a.list and (MyRecipeCount() == 0 or tour) then
    Show("scan", a.findPanel, a.list, "RightEdgeCenter", OpenAction(a))
    return
  end
  if not tips.shared and (recorded or (tour and tips.scan)) and not IsShowing("scan") and a.status then
    Show("shared", a.frame, a.status, "BottomEdgeCenter")
    return
  end
  if not tips.request and (context == "selected" or (tour and context == "shown")) and tips.shared and not IsShowing("shared")
    and not IsShowing("plan") and a.findTab and a.post then
    Show("request", a.findPanel, a.post, "TopEdgeCenter")
    return
  end
  -- Plan: once there is something to plan with, on its own. In the tour it comes last.
  if not tips.plan and context ~= "selected" and a.planTab and MyRecipeCount() > 0
    and (not tour or tips.request)
    and not (IsShowing("scan") or IsShowing("shared") or IsShowing("request")) then
    -- Side tabs hang off the window's right edge; the top tabs inside the Professions window
    -- get the tip underneath.
    Show("plan", a.frame, a.planTab, a.embedded and "BottomEdgeCenter" or "RightEdgeCenter")
  end
end

-- Options: "Show tips again".
function Onboarding.Reset()
  for key in pairs(TEXT) do
    local parent = showing[key]
    if parent and type(HelpTip) == "table" and type(HelpTip.Hide) == "function" then
      pcall(HelpTip.Hide, HelpTip, parent, TEXT[key])
    end
    showing[key] = nil
  end
  HideOpenButton()
  if type(CraftBoardDB) == "table" then CraftBoardDB.tips = {} end
  tour = true
  -- The first tip is on the Find tab.
  if NS.UI and NS.UI.ShowTab then
    NS.UI.ShowTab(1)
  elseif NS.UI and NS.UI.Show then
    NS.UI.Show()
  end
  Onboarding.Check("shown")
end

if NS.RegisterCallback then
  NS.RegisterCallback(Onboarding, "RECIPES_UPDATED", function() Onboarding.Check("recipes") end)
end
