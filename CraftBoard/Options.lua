-- CraftBoard Options: settings panel in the Blizzard settings UI.
-- Modern clients: vertical layout category (Settings.RegisterAddOnSetting / RegisterProxySetting,
-- 11.0.2+ signatures, same as BugSack on Forever). Otherwise a plain frame, registered as a canvas
-- category if the Settings API exists, else with the legacy InterfaceOptions_AddCategory.
local ADDON, NS = ...

local Options = {}
NS.Options = Options

local L = NS.L
local format = string.format
local CATEGORY_NAME = "CraftBoard"
local PANEL_NAME = "CraftBoardOptionsPanel"   -- the plain-frame fallback's global name

local registered = false
local categoryID                                -- modern / canvas path
local legacyPanel                               -- InterfaceOptions path

-- Clears every known peer and every board post, then lets Comm/UI refresh.
function Options.ForgetPeers()
  if type(CraftBoardDB) ~= "table" then return end
  CraftBoardDB.peers = {}
  CraftBoardDB.posts = {}
  NS.Fire("PEERS_UPDATED")
  NS.Fire("POSTS_UPDATED")
  NS.Print(L["Forgot all peer data."])
end

local function GetRealmChannel()
  return type(CraftBoardDB) == "table" and CraftBoardDB.realmChannel and true or false
end

local function SetRealmChannel(v)
  v = v and true or false
  if NS.Comm and NS.Comm.SetRealmChannel then
    NS.Comm.SetRealmChannel(v)
  elseif type(CraftBoardDB) == "table" then
    CraftBoardDB.realmChannel = v
  end
end

local function GetGuildShare()
  return not (type(CraftBoardDB) == "table" and CraftBoardDB.guildShare == false)
end

local function SetGuildShare(v)
  if type(CraftBoardDB) == "table" then CraftBoardDB.guildShare = v and true or false end
end

-- Advertise channel: where Find's Advertise button posts its one line ("General" by default,
-- "Trade" (cities only), or "Off").
local ADVERTISE = { "General", "Trade", "Off" }
local ADVERTISE_LABEL = { General = L["General"], Trade = L["Trade"], Off = L["Off"] }

function Options.AdvertiseChannel()
  local v = type(CraftBoardDB) == "table" and CraftBoardDB.advertiseChannel
  if v == "Trade" or v == "Off" then return v end
  return "General"
end

function Options.SetAdvertiseChannel(v)
  if v ~= "Trade" and v ~= "Off" then v = "General" end
  if type(CraftBoardDB) == "table" then CraftBoardDB.advertiseChannel = v end
  if NS.UI and NS.UI.Refresh then NS.UI.Refresh() end
end

-- General -> Trade -> Off -> General; returns the new choice.
local function CycleAdvertise()
  local cur = Options.AdvertiseChannel()
  local nextV = ADVERTISE[1]
  for i, v in ipairs(ADVERTISE) do
    if v == cur then nextV = ADVERTISE[i % #ADVERTISE + 1] end
  end
  Options.SetAdvertiseChannel(nextV)
  return nextV
end

local ADVERTISE_TIP = L["Where the Advertise button in Find posts one line for players without CraftBoard. Trade chat exists in cities only. Nothing is ever sent without a click."]

-- Modern: vertical layout ------------------------------------------------------

local function HasVerticalAPI()
  local S = Settings
  return type(S) == "table" and S.RegisterVerticalLayoutCategory and S.RegisterAddOnSetting
    and S.RegisterProxySetting and S.RegisterAddOnCategory and (S.CreateCheckbox or S.CreateCheckBox)
    and CreateSettingsButtonInitializer and true or false
end

local function RegisterVertical()
  local S = Settings
  local bool = S.VarType and S.VarType.Boolean or "boolean"
  local createCheckbox = S.CreateCheckbox or S.CreateCheckBox
  local category, layout = S.RegisterVerticalLayoutCategory(CATEGORY_NAME)

  local realm = S.RegisterProxySetting(category, "CRAFTBOARD_REALM_CHANNEL", bool,
    L["Share recipes on the realm channel"], true, GetRealmChannel, SetRealmChannel)
  createCheckbox(category, realm,
    L["Announce your recipes and see other players' on the hidden realm-wide channel (CraftBoardF)."])

  local guild = S.RegisterAddOnSetting(category, "CRAFTBOARD_GUILD_SHARE", "guildShare", CraftBoardDB, bool,
    L["Share recipes with my guild"], true)
  createCheckbox(category, guild, L["Announce your recipes and board posts to guildmates who use CraftBoard."])

  -- Advertise channel: a dropdown where the API has one, else a button that cycles.
  local dropdown = S.CreateDropdown and S.CreateControlTextContainer and pcall(function()
    local str = S.VarType and S.VarType.String or "string"
    local adv = S.RegisterProxySetting(category, "CRAFTBOARD_ADVERTISE_CHANNEL", str,
      L["Advertise channel"], "General", Options.AdvertiseChannel, Options.SetAdvertiseChannel)
    local function choices()
      local c = S.CreateControlTextContainer()
      for _, v in ipairs(ADVERTISE) do c:Add(v, ADVERTISE_LABEL[v]) end
      return c:GetData()
    end
    S.CreateDropdown(category, adv, choices, ADVERTISE_TIP)
  end)
  if not dropdown then
    layout:AddInitializer(CreateSettingsButtonInitializer(L["Advertise channel"], L["Change"], function()
      NS.Print(format(L["Advertise channel: %s"], ADVERTISE_LABEL[CycleAdvertise()]))
    end, ADVERTISE_TIP, true))
  end

  local forget = CreateSettingsButtonInitializer(L["Forget all peer data"], L["Forget"], Options.ForgetPeers,
    L["Clears every known crafter and every board post, including your own. They come back as peers announce themselves again."],
    true)
  layout:AddInitializer(forget)

  S.RegisterAddOnCategory(category)
  return category:GetID()
end

-- Fallback: plain frame ----------------------------------------------------------

local function ShowTip(self)
  if not (GameTooltip and self.tip) then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:SetText(self.label, 1, 1, 1)
  GameTooltip:AddLine(self.tip, nil, nil, nil, true)
  GameTooltip:Show()
end

local function HideTip()
  if GameTooltip then GameTooltip:Hide() end
end

local function BuildPanel()
  local p = CreateFrame("Frame", PANEL_NAME)
  p.name = CATEGORY_NAME
  p:Hide()

  local title = p:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText(CATEGORY_NAME)

  local checks = {}
  local function Check(label, tip, y, get, set)
    local cb = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 16, y)
    local text = cb.Text or cb.text
    if type(text) ~= "table" then
      text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
      text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    end
    text:SetText(label)
    cb.label, cb.tip, cb.get = label, tip, get
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    cb:SetScript("OnEnter", ShowTip)
    cb:SetScript("OnLeave", HideTip)
    checks[#checks + 1] = cb
    return cb
  end

  Check(L["Share recipes on the realm channel"],
    L["Announce your recipes and see other players' on the hidden realm-wide channel (CraftBoardF)."],
    -48, GetRealmChannel, SetRealmChannel)
  Check(L["Share recipes with my guild"],
    L["Announce your recipes and board posts to guildmates who use CraftBoard."],
    -76, GetGuildShare, SetGuildShare)

  local advertise = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  advertise:SetSize(220, 22)
  advertise:SetPoint("TOPLEFT", 20, -114)
  advertise.label = L["Advertise channel"]
  advertise.tip = ADVERTISE_TIP
  local function syncAdvertise()
    advertise:SetText(format(L["Advertise channel: %s"], ADVERTISE_LABEL[Options.AdvertiseChannel()]))
  end
  advertise:SetScript("OnClick", function()
    CycleAdvertise()
    syncAdvertise()
  end)
  advertise:SetScript("OnEnter", ShowTip)
  advertise:SetScript("OnLeave", HideTip)
  syncAdvertise()

  local forget = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  forget:SetSize(180, 22)
  forget:SetPoint("TOPLEFT", 20, -146)
  forget:SetText(L["Forget all peer data"])
  forget.label = L["Forget all peer data"]
  forget.tip = L["Clears every known crafter and every board post, including your own. They come back as peers announce themselves again."]
  forget:SetScript("OnClick", function() Options.ForgetPeers() end)
  forget:SetScript("OnEnter", ShowTip)
  forget:SetScript("OnLeave", HideTip)

  p:SetScript("OnShow", function()
    for i = 1, #checks do checks[i]:SetChecked(checks[i].get()) end
    syncAdvertise()
  end)
  return p
end

-- Registration --------------------------------------------------------------------

function Options.Register()
  if registered or type(CraftBoardDB) ~= "table" then return end
  registered = true

  if HasVerticalAPI() then
    local ok, id = pcall(RegisterVertical)
    if ok and id then
      categoryID = id
      return
    end
  end

  local panel = BuildPanel()
  if type(Settings) == "table" and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    local ok, category = pcall(Settings.RegisterCanvasLayoutCategory, panel, CATEGORY_NAME)
    if ok and category then
      Settings.RegisterAddOnCategory(category)
      categoryID = category:GetID()
      return
    end
  end
  if InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
    legacyPanel = panel
  end
end

function Options.Open()
  if InCombatLockdown and InCombatLockdown() then
    NS.Print(L["Can't open settings in combat."])
    return
  end
  Options.Register()
  if categoryID and type(Settings) == "table" and Settings.OpenToCategory then
    Settings.OpenToCategory(categoryID)
  elseif legacyPanel and InterfaceOptionsFrame_OpenToCategory then
    -- The first call can land on the wrong page when the addon list isn't built yet.
    InterfaceOptionsFrame_OpenToCategory(legacyPanel)
    InterfaceOptionsFrame_OpenToCategory(legacyPanel)
  else
    NS.Print(L["Settings panel not available."])
  end
end

NS.Register("PLAYER_LOGIN", function() Options.Register() end)
