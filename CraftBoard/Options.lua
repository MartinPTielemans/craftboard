-- CraftBoard Options: settings panel in the Blizzard settings UI.
-- Modern clients: vertical layout category (Settings.RegisterAddOnSetting / RegisterProxySetting,
-- 11.0.2+ signatures, same as BugSack on Forever), in sections (Sharing, Chat, Crafting notices,
-- Tooltips, Window) where the client has section headers, "Include guild chat" nested under
-- "Watch chat". Otherwise a plain frame with the same sections, registered as a canvas category
-- if the Settings API exists, else with the legacy InterfaceOptions_AddCategory.
local ADDON, NS = ...

local Options = {}
NS.Options = Options

local L = NS.L
local format = string.format
local CATEGORY_NAME = "CraftBoard"
local PANEL_NAME = "CraftBoardOptionsPanel"   -- the plain-frame fallback's global name
local FORGET_POPUP = "CRAFTBOARD_FORGET"

local registered = false
local categoryID                                -- modern / canvas path
local legacyPanel                               -- InterfaceOptions path

-- A post's sender is one of my characters (the one I'm playing, or another CraftBoard knows).
-- By exact name only: another player's cached post can carry an old first-name-only sender that
-- matches mine.
local function IsMine(from)
  if type(from) ~= "string" then return false end
  return (NS.MyCharKey and NS.MyCharKey(from)) ~= nil
end

-- Clears every known crafter and every request from other players (my own requests stay), then
-- lets Comm/UI refresh.
function Options.ForgetPeers()
  if type(CraftBoardDB) ~= "table" then return end
  CraftBoardDB.peers = {}
  local kept = {}
  for id, p in pairs(type(CraftBoardDB.posts) == "table" and CraftBoardDB.posts or {}) do
    if type(p) == "table" and IsMine(p.from) then kept[id] = p end
  end
  CraftBoardDB.posts = kept
  -- The private "crafted for you" history is about other players too.
  CraftBoardDB.crafted = {}
  NS.Fire("PEERS_UPDATED")
  NS.Fire("POSTS_UPDATED")
  NS.Fire("CRAFTED_UPDATED")
  NS.Print(L["Forgot other players' data."])
end

-- The settings button: asks first where the client has StaticPopup (defined on first use).
local function ConfirmForget()
  if type(StaticPopupDialogs) ~= "table" or type(StaticPopup_Show) ~= "function" then
    Options.ForgetPeers()
    return
  end
  if not StaticPopupDialogs[FORGET_POPUP] then
    StaticPopupDialogs[FORGET_POPUP] = {
      text = L["Forget every crafter and request CraftBoard has seen from other players? Your own requests stay."],
      button1 = L["Forget"],
      button2 = CANCEL,
      OnAccept = function() Options.ForgetPeers() end,
      timeout = 0,
      whileDead = true,
      hideOnEscape = true,
      preferredIndex = 3,
    }
  end
  if not pcall(StaticPopup_Show, FORGET_POPUP) then Options.ForgetPeers() end
end

local FORGET_TIP = L["Forgets every crafter and request CraftBoard has seen from other players. They reappear as they come online."]

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

local REALM_TIP = L["Announce your recipes and see other players' on the hidden realm-wide channel (CraftBoardF)."]

local function GetGuildShare()
  return not (type(CraftBoardDB) == "table" and CraftBoardDB.guildShare == false)
end

local function SetGuildShare(v)
  if NS.Comm and NS.Comm.SetGuildShare then
    NS.Comm.SetGuildShare(v)
  elseif type(CraftBoardDB) == "table" then
    CraftBoardDB.guildShare = v and true or false
  end
end

local GUILD_TIP = L["Announce your recipes and requests to guildmates who use CraftBoard."]

-- Minimap button (Launcher.lua via LibDBIcon): stored inverted in CraftBoardDB.minimap.hide.
local function GetMinimap()
  local db = type(CraftBoardDB) == "table" and CraftBoardDB.minimap
  return not (type(db) == "table" and db.hide)
end

local function SetMinimap(v)
  v = v and true or false
  if NS.Launcher and NS.Launcher.SetShown then
    NS.Launcher.SetShown(v)
  elseif type(CraftBoardDB) == "table" then
    if type(CraftBoardDB.minimap) ~= "table" then CraftBoardDB.minimap = {} end
    CraftBoardDB.minimap.hide = not v
  end
end

local MINIMAP_TIP = L["Show the CraftBoard button on the minimap. Drag it around the minimap edge to move it."]

-- CraftBoard as a tab of the Professions window (Embed.lua): CraftBoardDB.embed, default on.
local function GetEmbed()
  return not (type(CraftBoardDB) == "table" and CraftBoardDB.embed == false)
end

local function SetEmbed(v)
  v = v and true or false
  if NS.Embed and NS.Embed.SetEnabled then
    NS.Embed.SetEnabled(v)
  elseif type(CraftBoardDB) == "table" then
    CraftBoardDB.embed = v
  end
end

local EMBED_TIP = L["CraftBoard opens as a tab of the Professions window. Off, in combat, or on a character without a profession, it opens in its own window."]

-- Chat watcher (ChatWatch.lua): CraftBoardDB.chatWatch (default on), .chatWatchGuild (default off).
local function GetChatWatch()
  return not (type(CraftBoardDB) == "table" and CraftBoardDB.chatWatch == false)
end

local function SetChatWatch(v)
  v = v and true or false
  if NS.ChatWatch and NS.ChatWatch.SetEnabled then
    NS.ChatWatch.SetEnabled(v)
  elseif type(CraftBoardDB) == "table" then
    CraftBoardDB.chatWatch = v
  end
end

local function GetChatGuild()
  return type(CraftBoardDB) == "table" and CraftBoardDB.chatWatchGuild == true
end

local function SetChatGuild(v)
  v = v and true or false
  if NS.ChatWatch and NS.ChatWatch.SetGuildEnabled then
    NS.ChatWatch.SetGuildEnabled(v)
  elseif type(CraftBoardDB) == "table" then
    CraftBoardDB.chatWatchGuild = v
  end
end

local CHAT_TIP = L["Lists players asking for a crafter in Trade, General, LookingForGroup, say and yell under \"Seen in chat\" on the Requests tab. Nothing is sent. Works best with English shorthand (LF, WTB)."]
local CHAT_GUILD_TIP = L["Also watch guild chat for crafting requests."]

-- Auto-busy (Comm.lua): CraftBoardDB.autoBusy, default on. Addon messages can't be sent in
-- combat, so only dungeons and raids reach other players.
local function GetAutoBusy()
  return not (type(CraftBoardDB) == "table" and CraftBoardDB.autoBusy == false)
end

local function SetAutoBusy(v)
  v = v and true or false
  if NS.Comm and NS.Comm.SetAutoBusy then
    NS.Comm.SetAutoBusy(v)
  elseif type(CraftBoardDB) == "table" then
    CraftBoardDB.autoBusy = v
  end
end

local AUTO_BUSY_TIP = L["While you are in a dungeon or raid, other CraftBoard users see you as busy and can't whisper you from the board. /cb busy marks you busy by hand."]

-- Plain on/off options stored on CraftBoardDB, default on (only an explicit false is off).
local function Flag(key)
  return function() return not (type(CraftBoardDB) == "table" and CraftBoardDB[key] == false) end,
    function(v)
      if type(CraftBoardDB) == "table" then CraftBoardDB[key] = v and true or false end
      NS.Fire("OPTIONS_UPDATED")
    end
end
local GetBackOnline, SetBackOnline = Flag("backOnline")
local GetGroupTips, SetGroupTips = Flag("groupTooltips")
local GetGamepad, SetGamepad = Flag("gamepad")
local BACK_ONLINE_TIP = L["One quiet chat line when a player whose request you can craft, or offered on, logs back in. Nothing is sent."]
local GROUP_TIPS_TIP = L["In a party or raid, item tooltips name the group members who can craft the item, and their tooltips list their professions."]
local GAMEPAD_TIP = L["With gamepad mode on: D-pad up/down moves through the list, A whispers or offers, B closes, the shoulder buttons switch tabs."]
-- Crafting helpers: cooldown / trainer notices (Cooldowns.lua, Skills.lua), item tooltip lines
-- (Tooltips.lua).
local GetCooldownNotice, SetCooldownNotice = Flag("cooldownNotice")
local GetTrainerNotice, SetTrainerNotice = Flag("trainerNotice")
local GetReagentTips, SetReagentTips = Flag("reagentTooltips")
local GetRecipeTips, SetRecipeTips = Flag("recipeTooltips")
local COOLDOWN_NOTICE_TIP = L["One quiet chat line when a crafting cooldown on one of your characters is ready again."]
local TRAINER_NOTICE_TIP = L["One quiet chat line when a profession is ready for its next rank (Journeyman, Expert, Artisan), and when your skill reaches recipes your trainer had waiting."]
local REAGENT_TIPS_TIP = L["Item tooltips show how many of your recipes use a reagent, what your queue needs, and how many your other characters hold."]
local RECIPE_TIPS_TIP = L["Recipe tooltips show which of your characters know the recipe, can learn it, or need more skill."]

-- "Show tips again": the first tip is on the Find tab, so CraftBoard opens there.
local function ResetTips()
  if NS.Onboarding and NS.Onboarding.Reset then
    NS.Onboarding.Reset()
  else
    if type(CraftBoardDB) == "table" then CraftBoardDB.tips = {} end
    if NS.UI and NS.UI.ShowTab then NS.UI.ShowTab(1) end
  end
end

local TIPS_TIP = L["Shows the first-run tips on the CraftBoard window again."]

local function ShowWelcome()
  if NS.Welcome and NS.Welcome.Show then NS.Welcome.Show() end
end

local WELCOME_TIP = L["Shows the CraftBoard welcome window again."]

-- Advertise channel: where Find's Advertise button posts its one line ("Trade" (cities only) by
-- default, "General", or "Off").
local ADVERTISE = { "Trade", "General", "Off" }
local ADVERTISE_LABEL = { General = L["General"], Trade = L["Trade"], Off = L["Off"] }

function Options.AdvertiseChannel()
  local v = type(CraftBoardDB) == "table" and CraftBoardDB.advertiseChannel
  if v == "General" or v == "Off" then return v end
  return "Trade"
end

function Options.SetAdvertiseChannel(v)
  if v ~= "General" and v ~= "Off" then v = "Trade" end
  if type(CraftBoardDB) == "table" then CraftBoardDB.advertiseChannel = v end
  if NS.UI and NS.UI.Refresh then NS.UI.Refresh() end
end

-- Trade -> General -> Off -> Trade; returns the new choice.
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

-- The checkboxes by section, in panel order: { variable, label, get, set, tooltip, default };
-- "advertise" marks where the advertise channel control goes, nested = indented under the one
-- before it (and off while that one is off).
local SECTIONS = {
  { L["Sharing"], {
    { "CRAFTBOARD_REALM_CHANNEL", L["Share recipes on the realm channel"], GetRealmChannel, SetRealmChannel, REALM_TIP },
    { "CRAFTBOARD_GUILD_SHARE", L["Share recipes with my guild"], GetGuildShare, SetGuildShare, GUILD_TIP, guild = true },
    { "CRAFTBOARD_AUTO_BUSY", L["Busy in dungeons and raids"], GetAutoBusy, SetAutoBusy, AUTO_BUSY_TIP },
    { "CRAFTBOARD_BACK_ONLINE", L["Tell me when a requester comes online"], GetBackOnline, SetBackOnline, BACK_ONLINE_TIP },
    "advertise",
  } },
  { L["Chat"], {
    { "CRAFTBOARD_CHAT_WATCH", L["Watch chat for crafting requests"], GetChatWatch, SetChatWatch, CHAT_TIP },
    { "CRAFTBOARD_CHAT_WATCH_GUILD", L["Include guild chat"], GetChatGuild, SetChatGuild, CHAT_GUILD_TIP, default = false, nested = true },
  } },
  { L["Crafting notices"], {
    { "CRAFTBOARD_COOLDOWN_NOTICE", L["Tell me when a crafting cooldown is ready"], GetCooldownNotice, SetCooldownNotice, COOLDOWN_NOTICE_TIP },
    { "CRAFTBOARD_TRAINER_NOTICE", L["Tell me when I can train a new rank"], GetTrainerNotice, SetTrainerNotice, TRAINER_NOTICE_TIP },
  } },
  { L["Tooltips"], {
    { "CRAFTBOARD_REAGENT_TOOLTIPS", L["Show reagent info in item tooltips"], GetReagentTips, SetReagentTips, REAGENT_TIPS_TIP },
    { "CRAFTBOARD_RECIPE_TOOLTIPS", L["Show recipe info in item tooltips"], GetRecipeTips, SetRecipeTips, RECIPE_TIPS_TIP },
    { "CRAFTBOARD_GROUP_TOOLTIPS", L["Show group crafters in tooltips"], GetGroupTips, SetGroupTips, GROUP_TIPS_TIP },
  } },
  { L["Window"], {
    { "CRAFTBOARD_EMBED", L["Open CraftBoard inside the Professions window"], GetEmbed, SetEmbed, EMBED_TIP },
    { "CRAFTBOARD_MINIMAP_BUTTON", L["Show minimap button"], GetMinimap, SetMinimap, MINIMAP_TIP },
    { "CRAFTBOARD_GAMEPAD", L["Gamepad controls"], GetGamepad, SetGamepad, GAMEPAD_TIP },
  } },
}

-- Modern: vertical layout ------------------------------------------------------

local function HasVerticalAPI()
  local S = Settings
  return type(S) == "table" and S.RegisterVerticalLayoutCategory and S.RegisterAddOnSetting
    and S.RegisterProxySetting and S.RegisterAddOnCategory and (S.CreateCheckbox or S.CreateCheckBox)
    and CreateSettingsButtonInitializer and true or false
end

-- A section header where the client has them (else the checkboxes just follow each other).
local function AddHeader(layout, text)
  if type(CreateSettingsListSectionHeaderInitializer) ~= "function" then return end
  local ok, init = pcall(CreateSettingsListSectionHeaderInitializer, text)
  if ok and init then layout:AddInitializer(init) end
end

local function AddAdvertise(S, category, layout)
  -- A dropdown where the API has one, else a button that cycles.
  local dropdown = S.CreateDropdown and S.CreateControlTextContainer and pcall(function()
    local str = S.VarType and S.VarType.String or "string"
    local adv = S.RegisterProxySetting(category, "CRAFTBOARD_ADVERTISE_CHANNEL", str,
      L["Advertise channel"], "Trade", Options.AdvertiseChannel, Options.SetAdvertiseChannel)
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
end

local function RegisterVertical()
  local S = Settings
  local bool = S.VarType and S.VarType.Boolean or "boolean"
  local createCheckbox = S.CreateCheckbox or S.CreateCheckBox
  local category, layout = S.RegisterVerticalLayoutCategory(CATEGORY_NAME)

  for _, section in ipairs(SECTIONS) do
    AddHeader(layout, section[1])
    local prev
    for _, o in ipairs(section[2]) do
      if o == "advertise" then
        AddAdvertise(S, category, layout)
      else
        local default = o.default ~= false
        local setting
        if o.guild then
          -- Stored straight on CraftBoardDB.guildShare; turning it on announces me to the guild.
          setting = S.RegisterAddOnSetting(category, o[1], "guildShare", CraftBoardDB, bool, o[2], default)
          if S.SetOnValueChangedCallback then
            -- The value is already saved when this runs (and the callback's arguments differ
            -- between clients): read it back.
            pcall(S.SetOnValueChangedCallback, o[1], function()
              if NS.Comm and NS.Comm.SetGuildShare then
                NS.Comm.SetGuildShare(not (type(CraftBoardDB) == "table" and CraftBoardDB.guildShare == false))
              end
            end)
          end
        else
          setting = S.RegisterProxySetting(category, o[1], bool, o[2], default, o[3], o[4])
        end
        local init = createCheckbox(category, setting, o[5])
        -- Nested under the previous checkbox, which enables it.
        if o.nested and prev and type(init) == "table" and init.SetParentInitializer then
          local parentGet = prev.get
          pcall(init.SetParentInitializer, init, prev.init, function() return parentGet() end)
        end
        prev = { init = init, get = o[3] }
      end
    end
  end

  AddHeader(layout, L["Data and help"])
  layout:AddInitializer(CreateSettingsButtonInitializer(L["Forget other players' data"], L["Forget"], ConfirmForget,
    FORGET_TIP, true))
  layout:AddInitializer(CreateSettingsButtonInitializer(L["Show tips again"], L["Reset"], ResetTips, TIPS_TIP, true))
  layout:AddInitializer(CreateSettingsButtonInitializer(L["Show welcome"], L["Show"], ShowWelcome, WELCOME_TIP, true))

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

local ROW, HEADER = 24, 26   -- px per checkbox / per section header

local function BuildPanel()
  local p = CreateFrame("Frame", PANEL_NAME)
  p.name = CATEGORY_NAME
  p:Hide()

  local title = p:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText(CATEGORY_NAME)

  local y = -44
  local checks, syncs = {}, {}
  local function Header(text)
    local h = p:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    h:SetPoint("TOPLEFT", 18, y - 6)
    h:SetText(text)
    y = y - HEADER
  end
  local function Button(text, width, x, tip, onClick)
    local b = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetPoint("TOPLEFT", x, y - 2)
    b:SetText(text)
    b.label, b.tip = text, tip
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", ShowTip)
    b:SetScript("OnLeave", HideTip)
    return b
  end
  local function Check(o, indent)
    local cb = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
    cb:SetSize(ROW, ROW)
    cb:SetPoint("TOPLEFT", 16 + indent, y)
    local text = cb.Text or cb.text
    if type(text) ~= "table" then
      text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
      text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    end
    text:SetText(o[2])
    cb.cbText = text
    cb.label, cb.tip, cb.get = o[2], o[5], o[3]
    local set = o[4]
    cb:SetScript("OnClick", function(self)
      set(self:GetChecked() and true or false)
      for i = 1, #syncs do syncs[i]() end
    end)
    cb:SetScript("OnEnter", ShowTip)
    cb:SetScript("OnLeave", HideTip)
    checks[#checks + 1] = cb
    y = y - ROW
    return cb
  end

  local syncAdvertise
  for _, section in ipairs(SECTIONS) do
    Header(section[1])
    local prev
    for _, o in ipairs(section[2]) do
      if o == "advertise" then
        local advertise = Button("", 220, 20, ADVERTISE_TIP, function()
          CycleAdvertise()
          syncAdvertise()
        end)
        advertise.label = L["Advertise channel"]
        syncAdvertise = function()
          advertise:SetText(format(L["Advertise channel: %s"], ADVERTISE_LABEL[Options.AdvertiseChannel()]))
        end
        syncAdvertise()
        y = y - 28
      else
        local cb = Check(o, o.nested and 18 or 0)
        -- Nested: only clickable while the checkbox above it is on.
        if o.nested and prev then
          local parentGet = prev.get
          syncs[#syncs + 1] = function()
            local on = parentGet() and true or false
            cb:SetEnabled(on)
            if cb.cbText and cb.cbText.SetAlpha then cb.cbText:SetAlpha(on and 1 or 0.5) end
          end
        end
        prev = cb
      end
    end
  end

  Header(L["Data and help"])
  Button(L["Forget other players' data"], 200, 20, FORGET_TIP, ConfirmForget)
  Button(L["Show tips again"], 150, 228, TIPS_TIP, ResetTips)
  Button(L["Show welcome"], 150, 386, WELCOME_TIP, ShowWelcome)

  p:SetScript("OnShow", function()
    for i = 1, #checks do checks[i]:SetChecked(checks[i].get()) end
    for i = 1, #syncs do syncs[i]() end
    if syncAdvertise then syncAdvertise() end
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
