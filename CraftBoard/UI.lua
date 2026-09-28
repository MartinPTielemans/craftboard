-- CraftBoard UI: one movable, resizable window laid out like Blizzard's Professions crafting
-- page on this client (docs/professionsframe-dump.txt is the ground truth): the metal portrait
-- frame with a quiet board status line under the title, the recipe list column on the left
-- (search box + Filter dropdown over the summary-list background, gold collapsible category
-- bars, 20 px recipe rows), the recipe card on the right (round output icon, reagent slots,
-- crafters), the red Create-style button row under the card, and side tabs on the right edge
-- for Find / Requests (small top tabs instead when embedded in the Professions window).
-- Plain frames only: no ScrollBox/DataProvider, no external UI libs, no shipped textures.
-- Every row and button is created once (lists pool their visible rows); refreshes only
-- re-fill them. Every Blizzard template and atlas is checked before use, with a plain fallback.
local ADDON, NS = ...

local UI = {}
NS.UI = UI

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local format = string.format
local L = NS.L

-- Geometry from the dump (ProfessionsFrame and its CraftingPage), in px from the frame edges.
local WIDTH, HEIGHT = 673, 594          -- ProfessionsFrame default size
local LEFT_FRAC = 0.45                  -- share of any extra width that goes to the list
local G = {
  listX = 5, listY = -72, listB = 5,    -- RecipeList: TOPLEFT 5,-72, BOTTOMLEFT 0,5
  listW = 304,                          -- RecipeList width at the default size
  formGap = 2, formR = 2, formB = 38,   -- SchematicForm: TOPLEFT->RecipeList.TOPRIGHT 2,0, 360x484
  statusX = 110, statusY = -40, statusW = 453, statusH = 18, -- where CraftingPage.RankBar sits
  minW = WIDTH, minH = HEIGHT,          -- never smaller than Blizzard's window
  maxW = 1400, maxH = 1000,
  scrollbarW = 22,                      -- room for the legacy UIPanelScrollFrameTemplate bar
  minibarW = 8,                         -- MinimalScrollBar (minimal-scrollbar-*) width
}
local LEFT_W = G.listW
-- Recipe list rows. ScrollBox elements are 1 px apart; a category is a 25 px bar, a 1 px
-- top padding and, after its last recipe, a 10 px bottom padding; recipes are 20 px.
local ROW = {
  headerBar = 25, recipeBar = 20,
  cat = 26,                             -- collapsed category (bar + spacing)
  catOpen = 28,                         -- + 1 px top padding + spacing
  recipe = 21,
  recipeLast = 32,                      -- + 10 px bottom padding + spacing
  prof = 26,                            -- profession header (All professions view)
  indent = 10,                          -- recipe rows start 10 px right of their category bar
  labelX = 21,                          -- recipe label: SkillUps (-9, 26 wide) + 4
}
local SUBROW_H = 18                     -- crafter rows
local REAGENT_H = 50                    -- reagent slot frame (39 px slot + name)
local ICON_SIZE = 47                    -- SchematicForm.OutputIcon
local TEX = {
  question = "Interface\\Icons\\INV_Misc_QuestionMark",
  ready = "Interface\\RaidFrame\\ReadyCheck-Ready",
  portrait = "Interface\\AddOns\\CraftBoard\\Media\\icon",
  listHighlight = "Interface\\Buttons\\UI-Listbox-Highlight2",
  slotHighlight = "Interface\\Buttons\\ButtonHilight-Square",
  roundMask = "Interface\\CharacterFrame\\TempPortraitAlphaMask",
  tabs = { "Interface\\Icons\\INV_Misc_Spyglass_03", "Interface\\Icons\\INV_Scroll_03",
    "Interface\\Icons\\INV_Misc_Note_01" },
}
-- Atlases, all taken from the dump; each is checked with GetAtlasInfo before use.
local A = {
  frameBg = "Profession-Background-Overview", pageBg = "Profession-Background-Template2",
  listBg = "Professions-background-summarylist",
  searchL = "common-search-border-left", searchM = "common-search-border-middle",
  searchR = "common-search-border-right", searchIcon = "common-search-magnifyingglass",
  searchClear = "common-search-clearbutton", dropdown = "common-dropdown-b-button",
  header = "common-button-list-collapseExpand", minus = "common-button-list-minus",
  plus = { "common-button-list-plus", "Professions-recipe-header-expand" },
  selected = "Professions_Recipe_Active", hover = "Professions_Recipe_Hover",
  card = "Profession-background-card-%s", cardBorder = "common-insideframe",
  ring = "auctionhouse-itemicon-border-white",
  slotBg = "Professions-Slot-bg", slotFrame = "Professions-Slot-Frame",
  red = "128-RedButton", redHL = "128-RedButton-Highlight",
  square = "common-button-tertiary-square-normal", squarePushed = "common-button-tertiary-square-pressed",
  chat = "common-icon-chatlink",
  sidetab = "common-sidetab", sidetabMask = "common-sidetab-mask",
  sidetabSel = "common-sidetab-selected", sidetabHover = "common-sidetab-hover",
}
-- Font objects from the dump (first existing name wins; see Font()).
local FONTS = {
  row = { "GameFontHighlight_NoShadow", "GameFontHighlight" },        -- recipe label, reagent name
  header = { "Game15Font_Shadow", "GameFontNormalMed3", "GameFontNormal" }, -- category bar
  title = { "GameFontHighlightMed2", "GameFontHighlightMedium", "GameFontHighlight" }, -- OutputText
  desc = { "GameFontHighlightSmall2", "GameFontHighlightSmall" },     -- Description
  section = { "GameFontNormalSmall", "GameFontNormal" },              -- "Reagents:"
}
local DOT = " \194\183 "                -- " · "
local EN_DASH = "\226\128\147"
local GREEN, GREY = "|cff40ff40", "|cff9d9d9d"
local MUTED = { 0.62, 0.62, 0.62 }
local GOLD_RGB = { 1, 0.82, 0 }
local GOLD_HEX = "|cffffd100"
local ONLINE_RGB = { 0.25, 1, 0.25 }
local C = {
  label = { 0.89, 0.86, 0.84 },         -- recipe label / count colour (GameFontHighlight_NoShadow)
  countHex = "|cffe3dbd6",              -- the label colour as a code, for the " [n]" count
  short = { 0.627, 0.627, 0.627 },      -- reagent short: "|cffa0a0a02/5 Light Leather|r"
  ring = { 0.62, 0.5, 0.32 },           -- plain ring tint when the ring atlas is missing
}

local EMPTY_RECIPES = L["Open a profession window to record your recipes."]
local EMPTY_PEERS = L["No one on the board yet \226\128\148 CraftBoard users in your guild and on your realm appear here."]

local frame                    -- standalone window, created on first show
local host                     -- frame the content (pages, status line, side tabs) is in right now:
                               -- the standalone window or Embed.lua's page in ProfessionsFrame
local hostOpts = {}            -- [host frame] = options given to UI.BuildContent
local tabs, panels = {}, {}
local topTabs = {}             -- Find / Requests as small top tabs, for hosts with opts.topTabs
local activeTab = 1
local selectedID               -- recipeID selected in Find
local dirty = true
local owner = {}               -- callback owner; CallbackHandler refuses NS itself
local find, reqs, plan = {}, {}, {}
local statusLine               -- board status under the title ("2 crafters online · 1 open request")
local portraitNow
local MODERN = false           -- portrait frame template in use
local sideTabs = false         -- common-sidetab tabs on the right edge (else bottom tabs)

-- Helpers ---------------------------------------------------------------

local function UIDB()
  if type(CraftBoardDB) ~= "table" then return nil end
  if type(CraftBoardDB.ui) ~= "table" then CraftBoardDB.ui = {} end
  return CraftBoardDB.ui
end

local function Collapsed()
  local db = UIDB()
  if not db then return {} end
  if type(db.collapsed) ~= "table" then db.collapsed = {} end
  return db.collapsed
end
local function Short(name)
  if type(name) ~= "string" then return "?" end
  if Ambiguate then return Ambiguate(name, "none") end
  return name:match("^[^%-]+") or name
end

local function ItemIcon(itemID)
  if type(itemID) ~= "number" then return nil end
  if C_Item and C_Item.GetItemIconByID then
    local t = C_Item.GetItemIconByID(itemID)
    if t then return t end
  end
  if GetItemIcon then return GetItemIcon(itemID) end
  return nil
end

local function SpellIcon(spellID)
  if type(spellID) ~= "number" then return nil end
  if C_Spell and C_Spell.GetSpellTexture then
    local t = C_Spell.GetSpellTexture(spellID)
    if t then return t end
  end
  if GetSpellTexture then return GetSpellTexture(spellID) end
  return nil
end

-- Recipe IDs are spell IDs: enchants without an output item fall back to the spell icon.
local function RecipeIcon(recipeID, itemID)
  return ItemIcon(itemID) or SpellIcon(recipeID) or TEX.question
end

local function ItemName(itemID)
  local n = NS.Inventory and NS.Inventory.ItemName and NS.Inventory.ItemName(itemID)
  return n or format(L["Item %d"], tonumber(itemID) or 0)
end

-- GetItemInfo, multi-return or table-shaped: returns link, quality (either may be nil).
local function ItemInfo(itemID)
  if type(itemID) ~= "number" then return nil, nil end
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not getInfo then return nil, nil end
  local ok, a, b, c = pcall(getInfo, itemID)
  if not ok or a == nil then return nil, nil end
  if type(a) == "table" then
    return a.itemLink or a.hyperlink or a.link, a.itemQuality or a.quality
  end
  return b, c
end

local function ItemLink(itemID)
  return (ItemInfo(itemID))
end

local function ItemQuality(itemID)
  if type(itemID) ~= "number" then return nil end
  if C_Item and C_Item.GetItemQualityByID then
    local ok, q = pcall(C_Item.GetItemQualityByID, itemID)
    if ok and type(q) == "number" then return q end
  end
  local _, q = ItemInfo(itemID)
  return type(q) == "number" and q or nil
end

-- r, g, b for an item quality; white when unknown (no item, or not cached yet).
local function QualityRGB(q)
  if type(q) == "number" then
    if C_Item and C_Item.GetItemQualityColor then
      local ok, r, g, b = pcall(C_Item.GetItemQualityColor, q)
      if ok and type(r) == "number" then return r, g, b end
    end
    if GetItemQualityColor then
      local ok, r, g, b = pcall(GetItemQualityColor, q)
      if ok and type(r) == "number" then return r, g, b end
    end
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if type(c) == "table" and c.r then return c.r, c.g, c.b end
  end
  return 1, 1, 1
end

-- Name colour for a recipe row: the output item's quality colour for uncommon and better,
-- else Blizzard's recipe label colour. Enchants (no item) and uncached items use the label
-- colour; asking for the name queues the load, and ITEM_NAMES_UPDATED then refreshes the
-- visible tab, which re-fills the rows in colour.
local function NameRGB(itemID)
  local q = ItemQuality(itemID)
  if q == nil and type(itemID) == "number" and NS.Inventory and NS.Inventory.ItemName then
    NS.Inventory.ItemName(itemID)
  end
  if type(q) ~= "number" or q == 1 then return C.label[1], C.label[2], C.label[3] end
  return QualityRGB(q)
end


local function ShowTooltip(anchor, itemID, recipeID)
  if not GameTooltip then return end
  -- Anchor to the host's right edge (past the side tabs) so the tooltip never covers the
  -- recipe page.
  if host and host.GetRight then
    GameTooltip:SetOwner(host, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    GameTooltip:SetPoint("TOPLEFT", host, "TOPRIGHT", sideTabs and 58 or 4, -30)
  else
    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
  end
  local ok
  if type(itemID) == "number" then
    if GameTooltip.SetItemByID then
      ok = pcall(GameTooltip.SetItemByID, GameTooltip, itemID)
    else
      ok = pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. itemID)
    end
  elseif type(recipeID) == "number" and GameTooltip.SetSpellByID then
    ok = pcall(GameTooltip.SetSpellByID, GameTooltip, recipeID)
  end
  if ok then GameTooltip:Show() else GameTooltip:Hide() end
end

local function TextTooltip(anchor, title, body)
  if not GameTooltip or not title then return end
  GameTooltip:SetOwner(anchor, "ANCHOR_TOP")
  GameTooltip:SetText(title)
  if body then GameTooltip:AddLine(body, 1, 1, 1, true) end
  GameTooltip:Show()
end

local function HideTooltip()
  if GameTooltip then GameTooltip:Hide() end
end

local function Age(t)
  local d = max(0, (time() - (t or time())))
  if d < 60 then return L["now"] end
  if d < 3600 then return format(L["%dm"], floor(d / 60)) end
  return format(L["%dh"], floor(d / 3600))
end

-- Calls fn once, `delay` seconds after the last trigger.
local function Debouncer(delay, fn)
  local token = 0
  return function()
    token = token + 1
    local mine = token
    if C_Timer and C_Timer.After then
      C_Timer.After(delay, function()
        if mine == token then fn() end
      end)
    else
      fn()
    end
  end
end

local function HasTemplate(name)
  if C_XMLUtil and C_XMLUtil.GetTemplateInfo then
    return C_XMLUtil.GetTemplateInfo(name) ~= nil
  end
  return true
end

-- First existing font object name, so a missing one never errors.
local function Font(...)
  for i = 1, select("#", ...) do
    local n = select(i, ...)
    if _G[n] then return n end
  end
  return "GameFontNormal"
end

local function Label(parent, text, font)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
  fs:SetJustifyH("LEFT")
  if fs.SetWordWrap then fs:SetWordWrap(false) end
  if fs.SetMaxLines then fs:SetMaxLines(1) end
  if text then fs:SetText(text) end
  return fs
end

-- Calm centred line for an empty detail pane; wraps inside the pane.
local function Placeholder(parent, text)
  local fs = Label(parent, text, "GameFontDisable")
  fs:SetPoint("LEFT", 12, 0)
  fs:SetPoint("RIGHT", -12, 0)
  fs:SetJustifyH("CENTER")
  if fs.SetMaxLines then fs:SetMaxLines(3) end
  if fs.SetWordWrap then fs:SetWordWrap(true) end
  return fs
end

local function Muted(fs)
  fs:SetTextColor(MUTED[1], MUTED[2], MUTED[3])
  return fs
end

local function StringWidth(fs)
  if fs.GetUnboundedStringWidth then return fs:GetUnboundedStringWidth() or 0 end
  return fs:GetStringWidth() or 0
end

local function PanelButton(parent, text, width, height)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width or 80, height or 20)
  b:SetText(text)
  if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
  return b
end

local function EditBox(name, parent, width, maxLetters, numeric)
  local e = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
  e:SetSize(width, 20)
  e:SetAutoFocus(false)
  if maxLetters then e:SetMaxLetters(maxLetters) end
  if numeric then e:SetNumeric(true) end
  e:SetScript("OnEscapePressed", e.ClearFocus)
  e:SetScript("OnEnterPressed", e.ClearFocus)
  return e
end

local function ReadQty(box)
  local n = tonumber(box and box:GetText() or "") or 1
  return min(1000, max(1, floor(n)))
end


local function HasAtlas(name)
  if not (C_Texture and C_Texture.GetAtlasInfo) then return false end
  local ok, info = pcall(C_Texture.GetAtlasInfo, name)
  return ok and info ~= nil
end



-- Icon trimmed of its baked-in edge, on a 1 px dark backdrop (icon.border).
local function BorderedIcon(parent, size)
  local icon = parent:CreateTexture(nil, "ARTWORK")
  icon:SetSize(size, size)
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  local border = parent:CreateTexture(nil, "BORDER")
  border:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
  border:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
  border:SetColorTexture(0, 0, 0, 0.85)
  icon.border = border
  return icon
end

-- Chat helpers (never protected): insert an item link, open a pre-filled whisper.
local function InsertLink(link)
  if type(link) ~= "string" then return false end
  local insert = ChatEdit_InsertLink or (ChatFrameUtil and ChatFrameUtil.InsertLink)
  if not insert then return false end
  local ok, done = pcall(insert, link)
  return ok and done and true or false
end

local function RequestText(itemID, qty)
  local label = ItemLink(itemID) or ItemName(itemID)
  return format(L["[CraftBoard] Could you craft %dx %s for me? I have/can get the mats."], qty, label)
end

-- Opens the chat box in whisper mode to `name` with the request template typed in, so it is
-- one Enter away (like clicking a player name in chat). Falls back to sending directly.
-- text: typed in instead of the request template (itemID/qty then unused).
local function OpenWhisper(name, itemID, qty, text)
  local tell = ChatFrame_SendTell or (ChatFrameUtil and ChatFrameUtil.SendTell)
  local active = ChatEdit_GetActiveWindow or (ChatFrameUtil and ChatFrameUtil.GetActiveWindow)
  if tell and active and (itemID or text) then
    local ok = pcall(tell, Short(name))
    local box = ok and active()
    if box and box.Insert then
      box:Insert(text or RequestText(itemID, qty))
      return true
    end
  end
  if text and NS.Comm and NS.Comm.Whisper and NS.Comm.Whisper(name, text) then return true end
  if itemID and NS.Comm and NS.Comm.Request and NS.Comm.Request(itemID, qty, name) then return true end
  NS.Print(format(L["Could not whisper %s."], Short(name)))
  return false
end

-- Dark bordered panel: InsetFrameTemplate when present, else a dark fill with a 1 px edge.
local function NewInset(parent)
  if HasTemplate("InsetFrameTemplate") then
    local ok, inset = pcall(CreateFrame, "Frame", nil, parent, "InsetFrameTemplate")
    if ok and inset then return inset end
  end
  local inset = CreateFrame("Frame", nil, parent)
  local bg = inset:CreateTexture(nil, "BACKGROUND", nil, -5)
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.45)
  for _, side in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
    local edge = inset:CreateTexture(nil, "BORDER")
    edge:SetPoint(side[1])
    edge:SetPoint(side[2])
    if side[1] == "TOPLEFT" and side[2] == "BOTTOMLEFT" or side[1] == "TOPRIGHT" then edge:SetWidth(1) else edge:SetHeight(1) end
    edge:SetColorTexture(0.35, 0.3, 0.2, 0.8)
  end
  return inset
end


-- Quantity box: Blizzard's NumericInputSpinnerTemplate (the "< 1 >" box of the Create row)
-- when present, else a plain numeric edit box. Returns the box and whether it is a spinner.
local function QtyBox(name, parent)
  if HasTemplate("NumericInputSpinnerTemplate") then
    local ok, e = pcall(CreateFrame, "EditBox", name, parent, "NumericInputSpinnerTemplate")
    if ok and e then
      if e.SetMinMaxValues then pcall(e.SetMinMaxValues, e, 1, 999) end
      if e.SetValue then pcall(e.SetValue, e, 1) end
      if (e:GetText() or "") == "" then e:SetText("1") end
      return e, true
    end
  end
  local e = EditBox(name, parent, 36, 4, true)
  e:SetText("1")
  return e, false
end

-- Filter button, like the Professions list's "Filter" dropdown. entries() returns
-- { kind = "radio" | "check" | "divider", text =, get = fn -> bool, set = fn, tip = } lists;
-- isDefault() tells whether the filters are at their defaults, reset() restores them.
-- Uses WowStyle1FilterDropdownTemplate + SetupMenu, else a plain button opening
-- MenuUtil.CreateContextMenu, else a plain button: click cycles the radio entries and
-- right-click toggles the first check entry.
local NewFilterButton
do
local function MenuGenerator(entries)
  return function(_, root)
    for _, e in ipairs(entries()) do
      local desc
      if e.kind == "radio" and root.CreateRadio then
        desc = root:CreateRadio(e.text, e.get, e.set)
      elseif e.kind == "check" and root.CreateCheckbox then
        desc = root:CreateCheckbox(e.text, e.get, e.set)
      elseif e.kind == "divider" and root.CreateDivider then
        root:CreateDivider()
      end
      if desc and e.tip and desc.SetTooltip then
        desc:SetTooltip(function(tooltip)
          tooltip:SetText(e.text)
          tooltip:AddLine(e.tip, 1, 1, 1, true)
        end)
      end
    end
  end
end

function NewFilterButton(parent, entries, isDefault, reset)
  if HasTemplate("WowStyle1FilterDropdownTemplate") then
    local ok, dd = pcall(CreateFrame, "DropdownButton", nil, parent, "WowStyle1FilterDropdownTemplate")
    if ok and dd and dd.SetupMenu and pcall(dd.SetupMenu, dd, MenuGenerator(entries)) then
      if dd.SetIsDefaultCallback then pcall(dd.SetIsDefaultCallback, dd, isDefault) end
      if dd.SetDefaultCallback then pcall(dd.SetDefaultCallback, dd, reset) end
      dd.cbMode = "dropdown"
      return dd
    elseif ok and dd then
      dd:Hide()
    end
  end
  local b = PanelButton(parent, L["Filter"], 93, 22)
  if b.RegisterForClicks then b:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
  if MenuUtil and MenuUtil.CreateContextMenu then
    b.cbMode = "menu"
    b:SetScript("OnClick", function(self)
      pcall(MenuUtil.CreateContextMenu, self, MenuGenerator(entries))
    end)
    return b
  end
  b.cbMode = "cycle"
  b:SetScript("OnClick", function(_, button)
    local list = entries()
    if button == "RightButton" then
      for _, e in ipairs(list) do
        if e.kind == "check" then e.set() break end
      end
      return
    end
    local radios, cur = {}, 0
    for _, e in ipairs(list) do
      if e.kind == "radio" then
        radios[#radios + 1] = e
        if e.get() then cur = #radios end
      end
    end
    if #radios > 0 then radios[cur % #radios + 1].set() end
  end)
  b:SetScript("OnEnter", function(self)
    local body
    for _, e in ipairs(entries()) do
      if e.kind == "radio" and e.get() then body = e.text end
      if e.kind == "check" then
        body = (body and body .. "\n" or "") .. format(L["Right-click: %s"], e.text)
      end
    end
    TextTooltip(self, L["Filter"], body)
  end)
  b:SetScript("OnLeave", HideTooltip)
  return b
end
end

-- After a filter change: the dropdown's reset "x", or the cycling button's label.
local function SyncFilterButton(b, entries)
  if not b then return end
  if b.cbMode == "dropdown" then
    if b.ValidateResetState then pcall(b.ValidateResetState, b) end
  elseif b.cbMode == "cycle" then
    local label = L["Filter"]
    for _, e in ipairs(entries()) do
      if e.kind == "radio" and e.get() then label = e.text end
    end
    b:SetText(label)
  end
end

-- Professions: portrait icon and recipe page background --------------------

local SetDetailBackground
do
-- Enum.Profession keys by skill line, for Blizzard's "Professions-Recipe-Background-<Kit>".
local PROF_KITS = {
  [129] = "FirstAid", [164] = "Blacksmithing", [165] = "Leatherworking", [171] = "Alchemy",
  [182] = "Herbalism", [185] = "Cooking", [186] = "Mining", [197] = "Tailoring",
  [202] = "Engineering", [333] = "Enchanting", [356] = "Fishing", [393] = "Skinning",
  [755] = "Jewelcrafting", [773] = "Inscription",
}

local function ProfKit(profID)
  if type(profID) ~= "number" then return nil end
  if PROF_KITS[profID] then return PROF_KITS[profID] end
  local T = C_TradeSkillUI
  if T and T.GetProfessionInfoBySkillLineID and Enum and type(Enum.Profession) == "table" then
    local ok, info = pcall(T.GetProfessionInfoBySkillLineID, profID)
    if ok and type(info) == "table" and info.profession ~= nil then
      for k, v in pairs(Enum.Profession) do
        if v == info.profession then return k end
      end
    end
  end
  return nil
end

local function BackgroundAtlas(profID)
  local kit = ProfKit(profID)
  if kit then
    for _, fmt in ipairs({ "Professions-Recipe-Background-%s", "Professions-Background-%s" }) do
      local name = format(fmt, kit)
      if HasAtlas(name) then return name end
    end
  end
  if HasAtlas("Professions-Recipe-Background") then return "Professions-Recipe-Background" end
  return nil
end

-- Recipe card background, like SchematicForm.Background ("Profession-background-card-
-- leatherworking"): the profession's card atlas at full alpha. Without the card atlases (or
-- the card border) the detail inset gets the older page background at low alpha.
local function CardAtlas(profID)
  local kit = ProfKit(profID)
  if not kit then return nil end
  local name = format(A.card, strlower(kit))
  if HasAtlas(name) then return name end
  return nil
end

function SetDetailBackground(t, profID)
  if not t.bg then return end
  local atlas, alpha
  if t.cardStyle then
    atlas, alpha = CardAtlas(profID), 1
  end
  if not atlas then atlas, alpha = BackgroundAtlas(profID), 0.45 end
  if atlas == t.bgAtlas and t.bgSet then return end
  t.bgAtlas, t.bgSet = atlas, true
  if atlas then
    t.bg:SetAtlas(atlas, false)
    t.bg:SetAlpha(alpha)
    t.bg:Show()
  else
    t.bg:Hide()
  end
end
end

-- Profession icon: Blizzard's standard icon for the Classic professions (the client doesn't
-- always hand one over: First Aid came back blank), else stored by the scan on one of my chars,
-- else asked from the client.
local PROF_ICONS = {
  [129] = "Interface\\Icons\\Spell_Holy_SealOfSacrifice", [164] = "Interface\\Icons\\Trade_BlackSmithing",
  [165] = "Interface\\Icons\\Trade_LeatherWorking", [171] = "Interface\\Icons\\Trade_Alchemy",
  [182] = "Interface\\Icons\\Trade_Herbalism", [185] = "Interface\\Icons\\INV_Misc_Food_15",
  [186] = "Interface\\Icons\\Trade_Mining", [197] = "Interface\\Icons\\Trade_Tailoring",
  [202] = "Interface\\Icons\\Trade_Engineering", [333] = "Interface\\Icons\\Trade_Engraving",
  [356] = "Interface\\Icons\\Trade_Fishing", [393] = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01",
}
local function ProfIcon(profID)
  if profID == nil then return nil end
  if PROF_ICONS[profID] then return PROF_ICONS[profID] end
  if type(CraftBoardDB) == "table" and type(CraftBoardDB.chars) == "table" then
    local function iconOf(c)
      local p = type(c) == "table" and type(c.profs) == "table" and c.profs[profID]
      return type(p) == "table" and p.icon or nil
    end
    local t = NS.Me and iconOf(CraftBoardDB.chars[NS.Me])
    if t then return t end
    for _, c in pairs(CraftBoardDB.chars) do
      t = iconOf(c)
      if t then return t end
    end
  end
  return NS.Recipes and NS.Recipes.ProfessionIcon and NS.Recipes.ProfessionIcon(profID) or nil
end

-- Item description for the recipe page: Blizzard's recipe description for my recipes, else
-- the item tooltip's "Use:" line, else its flavour text. nil when none.
local function ItemDescription(recipeID, itemID)
  local T = C_TradeSkillUI
  if T and T.GetRecipeDescription and type(recipeID) == "number"
    and NS.Recipes and NS.Recipes.Record and NS.Recipes.Record(recipeID) then
    local ok, d = pcall(T.GetRecipeDescription, recipeID, {})
    if ok and type(d) == "string" and d ~= "" then return d end
  end
  if type(itemID) ~= "number" or not (C_TooltipInfo and C_TooltipInfo.GetItemByID) then return nil end
  local ok, data = pcall(C_TooltipInfo.GetItemByID, itemID)
  if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
  local use, flavor
  local useP = type(ITEM_SPELL_TRIGGER_ONUSE) == "string" and ITEM_SPELL_TRIGGER_ONUSE or "Use:"
  local equipP = type(ITEM_SPELL_TRIGGER_ONEQUIP) == "string" and ITEM_SPELL_TRIGGER_ONEQUIP or "Equip:"
  for i = 2, #data.lines do
    local line = data.lines[i]
    if type(line) == "table" then
      if line.leftText == nil and TooltipUtil and TooltipUtil.SurfaceArgs then pcall(TooltipUtil.SurfaceArgs, line) end
      local t = line.leftText
      if type(t) == "string" and t ~= "" then
        if not use and (t:sub(1, #useP) == useP or t:sub(1, #equipP) == equipP) then use = t end
        if not flavor and t:sub(1, 1) == "\"" then flavor = t end
      end
    end
  end
  return use or flavor
end

-- Virtual list --------------------------------------------------------------
-- Client widgets ------------------------------------------------------------------
-- Rebuilt from the dump's regions so they look like the Professions window's own.

local function FontOf(list)
  for _, n in ipairs(list) do
    if _G[n] then return n end
  end
  return "GameFontNormal"
end

local function HasAtlases(...)
  for i = 1, select("#", ...) do
    if not HasAtlas((select(i, ...))) then return false end
  end
  return true
end

-- First existing atlas of a name or a list of candidate names.
local function FirstAtlas(names)
  if type(names) == "string" then return HasAtlas(names) and names or nil end
  for _, n in ipairs(names) do
    if HasAtlas(n) then return n end
  end
  return nil
end

-- Atlas at its natural size (dump: single-anchored regions), optionally forced to the size
-- the dump reports.
local function SetAtlasSized(tex, atlas, w, h)
  tex:SetAtlas(atlas, true)
  if w then tex:SetSize(w, h) end
end

-- Search-style edit box border (RecipeList.SearchBox, CreateMultipleInputBox): 8x20 left and
-- right caps at LEFT -5,0 / RIGHT 0,0, the middle between them, all BACKGROUND. Reuses the
-- template's Left/Middle/Right textures when it has them, unless `extra` (the quantity box
-- keeps its own border and gets this one on top, as in the dump). Returns true when styled.
local function StyleSearchBorder(box, extra)
  if not HasAtlases(A.searchL, A.searchM, A.searchR) then return false end
  local l = not extra and box.Left or box:CreateTexture(nil, "BACKGROUND")
  local r = not extra and box.Right or box:CreateTexture(nil, "BACKGROUND")
  local m = not extra and (box.Middle or box.Mid) or box:CreateTexture(nil, "BACKGROUND")
  if extra then
    box.cbBorder = { l, r, m }
  else
    box.Left, box.Right = l, r
    if not box.Mid then box.Middle = m end
  end
  for _, t in ipairs({ l, r, m }) do
    t:ClearAllPoints()
    if t.SetTexCoord then t:SetTexCoord(0, 1, 0, 1) end
    if t.SetDrawLayer then t:SetDrawLayer("BACKGROUND") end
    t:Show()
  end
  l:SetAtlas(A.searchL, false)
  l:SetSize(8, 20)
  l:SetPoint("LEFT", box, "LEFT", -5, 0)
  r:SetAtlas(A.searchR, false)
  r:SetSize(8, 20)
  r:SetPoint("RIGHT", box, "RIGHT", 0, 0)
  m:SetAtlas(A.searchM, false)
  m:SetHeight(20)
  m:SetPoint("LEFT", l, "RIGHT", 0, 0)
  m:SetPoint("RIGHT", r, "LEFT", 0, 0)
  return true
end

-- Grey hint inside an edit box while it is empty (the search box's "Search" Instructions:
-- GameFontDisableSmall at TOPLEFT 16,0 / BOTTOMRIGHT -20,0).
local function Hint(box, text, x)
  local hint = box:CreateFontString(nil, "ARTWORK", Font("GameFontDisableSmall", "GameFontDisable"))
  hint:SetPoint("TOPLEFT", box, "TOPLEFT", x or 16, 0)
  hint:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -20, 0)
  hint:SetJustifyH("LEFT")
  hint:SetText(text)
  local function sync()
    hint:SetShown((box:GetText() or "") == "" and not (box.HasFocus and box:HasFocus()))
  end
  box:HookScript("OnTextChanged", sync)
  box:HookScript("OnEditFocusGained", sync)
  box:HookScript("OnEditFocusLost", sync)
  box.cbHint = hint
  return hint
end

local RedButton
do
-- Red three-slice button (CraftingPage.CreateButton): 128-RedButton-Left/Right and
-- _128-RedButton-Center, each scaled to the button height (ThreeSliceButton), with the
-- -Pressed / -Disabled variants, 128-RedButton-Highlight (ADD) and GameFontNormal /
-- GameFontHighlight / GameFontDisable text. Falls back to UIPanelButtonTemplate.
local function RedSlices(state)
  local sfx = state ~= "" and ("-" .. state) or ""
  local l, r, c = A.red .. "-Left" .. sfx, A.red .. "-Right" .. sfx, "_" .. A.red .. "-Center" .. sfx
  if HasAtlases(l, r, c) then return l, r, c end
  return A.red .. "-Left", A.red .. "-Right", "_" .. A.red .. "-Center"
end

local function AtlasWidthFor(atlas, h)
  local info = C_Texture.GetAtlasInfo(atlas)
  if type(info) ~= "table" or not info.width or not info.height or info.height <= 0 then return h end
  return info.width * h / info.height
end

local function UpdateRedButton(b)
  local state = ""
  if not b:IsEnabled() then state = "Disabled" elseif b.cbDown then state = "Pressed" end
  if state == b.cbState then return end
  b.cbState = state
  local l, r, c = RedSlices(state)
  local h = b.cbH
  b.cbL:SetAtlas(l, false)
  b.cbL:SetSize(AtlasWidthFor(l, h), h)
  b.cbR:SetAtlas(r, false)
  b.cbR:SetSize(AtlasWidthFor(r, h), h)
  b.cbC:SetAtlas(c, false)
end

function RedButton(parent, text, width, height)
  height = height or 28
  if not HasAtlases(A.red .. "-Left", A.red .. "-Right", "_" .. A.red .. "-Center", A.redHL) then
    return PanelButton(parent, text, width, min(height, 22))
  end
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(width, height)
  b.cbH = height
  b.cbL = b:CreateTexture(nil, "BACKGROUND")
  b.cbL:SetPoint("TOPLEFT")
  b.cbR = b:CreateTexture(nil, "BACKGROUND")
  b.cbR:SetPoint("TOPRIGHT")
  b.cbC = b:CreateTexture(nil, "BACKGROUND")
  b.cbC:SetPoint("TOPLEFT", b.cbL, "TOPRIGHT")
  b.cbC:SetPoint("BOTTOMRIGHT", b.cbR, "BOTTOMLEFT")
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAtlas(A.redHL, false)
  hl:SetAllPoints()
  hl:SetBlendMode("ADD")
  b:SetNormalFontObject(Font("GameFontNormal"))
  b:SetHighlightFontObject(Font("GameFontHighlight", "GameFontNormal"))
  b:SetDisabledFontObject(Font("GameFontDisable", "GameFontNormal"))
  b:SetText(text)
  if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
  b:HookScript("OnMouseDown", function(self) if self:IsEnabled() then self.cbDown = true UpdateRedButton(self) end end)
  b:HookScript("OnMouseUp", function(self) self.cbDown = false UpdateRedButton(self) end)
  b:HookScript("OnEnable", UpdateRedButton)
  b:HookScript("OnDisable", function(self) self.cbDown = false UpdateRedButton(self) end)
  -- SetEnabled does not always fire OnEnable/OnDisable on the frame's first show.
  local setEnabled = b.SetEnabled
  b.SetEnabled = function(self, on)
    setEnabled(self, on)
    UpdateRedButton(self)
  end
  UpdateRedButton(b)
  b.cbRed = true
  return b
end
end

-- Widens a text button to fit its label (translations run longer than English), never below minW.
local function FitButton(b, minW)
  local fs = b and b.GetFontString and b:GetFontString()
  if not fs then return end
  local w = ceil(StringWidth(fs)) + (b.cbRed and 32 or 24)
  b:SetWidth(max(minW or 0, w))
end

-- 23x23 tertiary square button with an icon (CraftingPage.LinkButton:
-- common-button-tertiary-square-normal + common-icon-chatlink 25x25), used for Whisper; with
-- iconFile, that icon (trimmed, 17x17) instead of the chat-link atlas (Advertise). Falls back
-- to a text button `fallbackW` (default 82) px wide.
local function SquareButton(parent, fallbackText, iconFile, fallbackW)
  if not (HasAtlas(A.square) and (iconFile or HasAtlas(A.chat))) then
    return PanelButton(parent, fallbackText, fallbackW or 82, 22)
  end
  local function art(t, size)
    if iconFile then
      t:SetTexture(iconFile)
      t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      t:SetSize(size - 8, size - 8)
    else
      t:SetAtlas(A.chat, false)
      t:SetSize(size, size)
    end
  end
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(23, 23)
  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetAtlas(A.square, false)
  bg:SetAllPoints()
  local icon = b:CreateTexture(nil, "ARTWORK")
  art(icon, 25)
  icon:SetPoint("CENTER")
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  art(hl, 25)
  hl:SetPoint("CENTER")
  hl:SetBlendMode("ADD")
  hl:SetAlpha(0.4)
  if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
  local pushed = HasAtlas(A.squarePushed) and A.squarePushed or A.square
  b:HookScript("OnMouseDown", function(self)
    if not self:IsEnabled() then return end
    bg:SetAtlas(pushed, false)
    icon:SetPoint("CENTER", 1, -1)
  end)
  b:HookScript("OnMouseUp", function()
    bg:SetAtlas(A.square, false)
    icon:SetPoint("CENTER", 0, 0)
  end)
  local setEnabled = b.SetEnabled
  b.SetEnabled = function(self, on)
    setEnabled(self, on)
    if icon.SetDesaturated then icon:SetDesaturated(not on) end
    icon:SetAlpha(on and 1 or 0.5)
  end
  b.cbSquare = true
  return b
end

-- Virtual list --------------------------------------------------------------
-- A plain ScrollFrame whose child is sized for every item; only the visible rows exist and
-- are re-anchored on scroll. Rows may differ in height (opts.heightOf(item), default
-- rowHeight): item tops are summed once per SetItems. opts: bar (scrollbar, default true),
-- inline (empty text top-left instead of centered), stripes (default true), barGap (px
-- between rows and bar, default 5), padTop / padRight (ScrollTarget insets), indentOf(item)
-- (row x offset), emptyWidth (centred empty text width). The bar is a retail MinimalScrollBar
-- (minimal-scrollbar-*) wired by ScrollUtil when both exist, else the legacy
-- UIPanelScrollFrameTemplate.
local List = {}
List.__index = List

local function NewList(name, parent, rowHeight, makeRow, fillRow, opts)
  opts = opts or {}
  local self = setmetatable({ rowHeight = rowHeight, items = {}, tops = {}, total = 0, rows = {},
    makeRow = makeRow, fillRow = fillRow, heightOf = opts.heightOf, stripes = opts.stripes ~= false,
    padTop = opts.padTop or 0, padRight = opts.padRight or 0, indentOf = opts.indentOf }, List)
  local box = CreateFrame("Frame", nil, parent)
  self.box = box

  local scroll, bar, barW, legacy
  if opts.bar ~= false then
    -- ScrollUtil sets the frame's OnVerticalScroll / OnScrollRangeChanged scripts, so it runs
    -- before the HookScript calls below. MinimalScrollBar is an EventFrame template: created
    -- as a plain "Frame" its CallbackRegistry OnLoad never runs and every scroll then errors
    -- in CallbackRegistry (executingEvents is nil). If it cannot be created or wired, the
    -- legacy UIPanelScrollFrameTemplate below takes over.
    if ScrollUtil and ScrollUtil.InitScrollFrameWithScrollBar and HasTemplate("MinimalScrollBar") then
      local ok, b = pcall(CreateFrame, "EventFrame", nil, box, "MinimalScrollBar")
      if ok and b then
        scroll = CreateFrame("ScrollFrame", name, box)
        if pcall(ScrollUtil.InitScrollFrameWithScrollBar, scroll, b) then
          -- RecipeList.ScrollBar: 8 px wide, TOPLEFT/BOTTOMLEFT -> ScrollBox right edge.
          local gap = opts.barGap or 5
          local inset = opts.barGap and 0 or 1
          bar, barW = b, G.minibarW + gap
          bar:SetWidth(G.minibarW)
          bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", gap, -inset)
          bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", gap, inset)
        else
          b:Hide()
          scroll:Hide()
          scroll = nil
        end
      end
    end
    if not scroll and HasTemplate("UIPanelScrollFrameTemplate") then
      local ok, f = pcall(CreateFrame, "ScrollFrame", name, box, "UIPanelScrollFrameTemplate")
      if ok and f then
        scroll, barW, legacy = f, G.scrollbarW, true
        scroll.scrollBarHideable = true
        bar = scroll.ScrollBar or (name and _G[name .. "ScrollBar"])
      end
    end
  end
  if not scroll then scroll = CreateFrame("ScrollFrame", name, box) end
  self.scroll, self.bar, self.barW = scroll, bar, barW or 0
  self.barShown = bar ~= nil
  scroll:SetPoint("TOPLEFT")
  scroll:SetPoint("BOTTOMRIGHT", bar and -self.barW or 0, 0)
  -- Wheel: three rows a step (the legacy template brings its own handler).
  if not legacy then
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(s, delta)
      local range = max(0, self.total - (s:GetHeight() or 0))
      s:SetVerticalScroll(min(range, max(0, (s:GetVerticalScroll() or 0) - delta * rowHeight * 3)))
      self:Render()
    end)
  end

  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(1, 1)
  scroll:SetScrollChild(child)
  self.child = child

  scroll:HookScript("OnVerticalScroll", function() self:Render() end)
  scroll:HookScript("OnSizeChanged", function(s, w)
    child:SetWidth(max(1, (w or s:GetWidth() or 1) - self.padRight))
    self:Render()
  end)

  self.empty = Label(box, nil, "GameFontDisable")
  if opts.emptyWidth then
    -- RecipeList.NoResultsText: GameFontNormal, 200 px wide, TOP 0,-60.
    self.empty:SetFontObject(Font("GameFontNormal"))
    self.empty:SetPoint("TOP", box, "TOP", 0, -60)
    self.empty:SetWidth(opts.emptyWidth)
    self.empty:SetJustifyH("CENTER")
    if self.empty.SetMaxLines then self.empty:SetMaxLines(5) end
    if self.empty.SetWordWrap then self.empty:SetWordWrap(true) end
  elseif opts.inline then
    self.empty:SetFontObject("GameFontDisableSmall")
    self.empty:SetPoint("TOPLEFT", 2, -3)
    self.empty:SetPoint("TOPRIGHT", -2, -3)
  else
    self.empty:SetPoint("TOPLEFT", 8, -14)
    self.empty:SetPoint("TOPRIGHT", -8, -14)
    self.empty:SetJustifyH("CENTER")
    if self.empty.SetMaxLines then self.empty:SetMaxLines(3) end
    if self.empty.SetWordWrap then self.empty:SetWordWrap(true) end
  end
  return self
end

function List:HeightAt(i)
  local hf = self.heightOf
  return hf and hf(self.items[i]) or self.rowHeight
end

function List:SetItems(items, emptyText, keepScroll)
  self.items = items or {}
  local tops, y = {}, self.padTop
  for i = 1, #self.items do
    tops[i] = y
    y = y + self:HeightAt(i)
  end
  self.tops, self.total = tops, y
  if not keepScroll then self.scroll:SetVerticalScroll(0) end
  self.empty:SetText(emptyText or "")
  self.empty:SetShown(#self.items == 0 and emptyText ~= nil)
  self:Render()
end

-- Hide the scrollbar (and give its width back to the rows) when everything fits.
function List:UpdateBar(need)
  if not self.bar or need == self.barShown then return end
  self.barShown = need
  self.scroll:SetPoint("BOTTOMRIGHT", need and -self.barW or 0, 0)
  self.bar:SetShown(need)
end

function List:Render()
  -- Setting the scroll below re-enters through OnVerticalScroll (and the bar's callback).
  if self.rendering then return end
  self.rendering = true
  local items, tops, total = self.items, self.tops, self.total
  local n = #items
  local h = self.scroll:GetHeight() or 0
  if h <= 0 then h = self.rowHeight * 10 end
  self:UpdateBar(total > h + 0.5)
  self.child:SetWidth(max(1, (self.scroll:GetWidth() or 1) - self.padRight))
  self.child:SetHeight(max(1, total))

  local maxScroll = max(0, total - h)
  local offset = self.scroll:GetVerticalScroll() or 0
  if offset > maxScroll then
    offset = maxScroll
    self.scroll:SetVerticalScroll(maxScroll)
  end

  -- Last item whose top is at or above the offset (binary search), then down the viewport.
  local lo, hi = 1, n
  while lo < hi do
    local mid = floor((lo + hi + 1) / 2)
    if tops[mid] <= offset then lo = mid else hi = mid - 1 end
  end
  local slot, idx = 0, lo
  while idx <= n and tops[idx] < offset + h do
    slot = slot + 1
    local row = self.rows[slot]
    if not row then
      row = self.makeRow(self.child, self.rowHeight)
      self.rows[slot] = row
    end
    row:ClearAllPoints()
    local x = self.indentOf and self.indentOf(items[idx]) or 0
    row:SetPoint("TOPLEFT", self.child, "TOPLEFT", x, -tops[idx])
    row:SetPoint("TOPRIGHT", self.child, "TOPRIGHT", 0, -tops[idx])
    row:SetHeight(self:HeightAt(idx))
    row.index = idx
    if row.stripe then row.stripe:SetShown(self.stripes and idx % 2 == 0) end
    self.fillRow(row, items[idx], idx)
    row:Show()
    idx = idx + 1
  end
  for i = slot + 1, #self.rows do self.rows[i]:Hide() end
  self.rendering = false
end

-- Scroll just enough for item idx to be fully visible.
function List:ScrollTo(idx)
  local h = self.scroll:GetHeight() or 0
  if h <= 0 or not idx or not self.tops[idx] then return end
  local top = self.tops[idx]
  local bottom = top + self:HeightAt(idx)
  local offset = self.scroll:GetVerticalScroll() or 0
  if top < offset then
    self.scroll:SetVerticalScroll(top)
  elseif bottom > offset + h then
    self.scroll:SetVerticalScroll(bottom - h)
  end
  self:Render()
end

-- Row base: button with a hover highlight, a selection tint and a very faint stripe on even
-- rows. blizzard=true uses the Professions list's selected / hover atlases when present.

-- Row base (crafter rows): a button with the recipe list's hover / selected overlays when
-- those atlases exist, else a gold tint and the list-box highlight; optional faint stripe.
local function RowBase(parent, rowH)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(rowH)
  local stripe = row:CreateTexture(nil, "BACKGROUND", nil, -1)
  stripe:SetAllPoints()
  stripe:SetColorTexture(1, 1, 1, 0.025)
  stripe:Hide()
  row.stripe = stripe
  local sel = row:CreateTexture(nil, "BACKGROUND")
  sel:SetAllPoints()
  if HasAtlas(A.selected) then
    sel:SetAtlas(A.selected, false)
  else
    sel:SetColorTexture(1, 0.82, 0, 0.14)
  end
  sel:Hide()
  row.sel = sel
  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  if HasAtlas(A.hover) then
    hl:SetAtlas(A.hover, false)
    hl:SetAlpha(0.5)
  elseif hl:SetTexture(TEX.listHighlight) then
    hl:SetBlendMode("ADD")
    hl:SetVertexColor(1, 1, 1, 0.5)
  else
    hl:SetColorTexture(1, 1, 1, 0.08)
  end
  row.hl = hl
  row:SetScript("OnLeave", HideTooltip)
  return row
end

local function ShowParts(parts, on)
  for i = 1, #parts do parts[i]:SetShown(on) end
end

-- Grouped recipe list ----------------------------------------------------------------
-- One pooled row type for the three kinds of list element:
--  * category (kind "cat"): the 25 px common-button-list-collapseExpand bar (its own atlas at
--    0.4 ADD as highlight), gold Game15Font_Shadow label at LEFT 8, and the collapse toggle
--    (common-button-list-minus 13x4, centred in a 20x20 button at RIGHT -6);
--  * profession (kind "prof", All professions view): the same bar with the profession icon
--    and a recipe count;
--  * recipe: 20 px row, GameFontHighlight_NoShadow label at x 21 with the craftable count
--    " [n]" after it, Professions_Recipe_Active (267x19, OVERLAY) when selected and
--    Professions_Recipe_Hover (309x21, alpha 0.5, HIGHLIGHT) on hover, both centred 1 px low.
-- The row is sized to its slot (bar + the 1 px ScrollBox spacing and paddings); the hit rect
-- covers the bar only.
local function GroupRowFactory(onSelect, onToggle)
  return function(parent)
    local row = CreateFrame("Button", nil, parent)
    local midY = -(ROW.recipeBar / 2) - 1

    -- Recipe parts.
    local sel = row:CreateTexture(nil, "OVERLAY")
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    if HasAtlases(A.selected, A.hover) then
      sel:SetAtlas(A.selected, false)
      sel:SetPoint("LEFT", row, "TOPLEFT", -3, midY)
      sel:SetPoint("RIGHT", row, "TOPRIGHT", 3, midY)
      sel:SetHeight(19)
      hl:SetAtlas(A.hover, false)
      hl:SetPoint("LEFT", row, "TOPLEFT", -24, midY)
      hl:SetPoint("RIGHT", row, "TOPRIGHT", 24, midY)
      hl:SetHeight(21)
      hl:SetAlpha(0.5)
    else
      sel:SetDrawLayer("BACKGROUND")
      sel:SetColorTexture(1, 0.82, 0, 0.14)
      sel:SetPoint("TOPLEFT")
      sel:SetPoint("TOPRIGHT")
      sel:SetHeight(ROW.recipeBar)
      hl:SetPoint("TOPLEFT")
      hl:SetPoint("TOPRIGHT")
      hl:SetHeight(ROW.recipeBar)
      if hl:SetTexture(TEX.listHighlight) then
        hl:SetBlendMode("ADD")
        hl:SetVertexColor(1, 1, 1, 0.5)
      else
        hl:SetColorTexture(1, 1, 1, 0.08)
      end
    end
    sel:Hide()
    row.sel, row.hl = sel, hl
    row.status = Muted(Label(row, nil, "GameFontHighlightSmall"))
    row.status:SetPoint("RIGHT", row, "TOPRIGHT", -4, -ROW.recipeBar / 2)
    row.status:SetJustifyH("RIGHT")        -- no width: sized to its text, the name takes the rest
    row.name = Label(row, nil, FontOf(FONTS.row))
    row.name:SetPoint("LEFT", row, "TOPLEFT", ROW.labelX, -ROW.recipeBar / 2)
    row.name:SetPoint("RIGHT", row.status, "LEFT", -6, 0)
    row.recipeParts = { row.name, row.status, hl }

    -- Header bar.
    local bar = row:CreateTexture(nil, "ARTWORK")
    bar:SetPoint("TOPLEFT")
    bar:SetPoint("TOPRIGHT")
    bar:SetHeight(ROW.headerBar)
    local barHL = row:CreateTexture(nil, "HIGHLIGHT")
    barHL:SetAllPoints(bar)
    row.headerParts = { bar, barHL }
    if HasAtlas(A.header) then
      bar:SetAtlas(A.header, false)
      barHL:SetAtlas(A.header, false)
      barHL:SetBlendMode("ADD")
      barHL:SetAlpha(0.4)
    else
      bar:SetColorTexture(0.12, 0.09, 0.03, 0.9)
      barHL:SetColorTexture(1, 1, 1, 0.06)
      local line = row:CreateTexture(nil, "ARTWORK", nil, 1)
      line:SetColorTexture(GOLD_RGB[1], GOLD_RGB[2], GOLD_RGB[3], 0.7)
      line:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT")
      line:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT")
      line:SetHeight(1)
      row.headerParts[#row.headerParts + 1] = line
    end
    row.bar = bar
    row.header = Label(row, nil, FontOf(FONTS.header))
    row.header:SetPoint("RIGHT", bar, "RIGHT", -30, 0)
    local plus = FirstAtlas(A.plus)
    if HasAtlas(A.minus) and plus then
      row.toggle = row:CreateTexture(nil, "OVERLAY")
      row.toggle:SetPoint("CENTER", bar, "RIGHT", -16, 0)
      row.plusAtlas = plus
    else
      row.toggle = Label(row, nil, "GameFontNormalLarge")
      row.toggle:SetJustifyH("CENTER")
      row.toggle:SetPoint("CENTER", bar, "RIGHT", -16, 0)
    end
    row.headerParts[#row.headerParts + 1] = row.header
    row.headerParts[#row.headerParts + 1] = row.toggle

    -- Profession header extras: icon and recipe count.
    row.profIcon = BorderedIcon(row, 18)
    row.profIcon:SetPoint("LEFT", bar, "LEFT", 6, 0)
    row.count = Muted(Label(row, nil, "GameFontHighlightSmall"))
    row.count:SetPoint("RIGHT", bar, "RIGHT", -30, 0)
    row.count:SetJustifyH("RIGHT")
    row.profParts = { row.profIcon, row.profIcon.border, row.count }

    row:SetScript("OnEnter", function(self)
      local it = self.item
      if it and not it.kind then ShowTooltip(self, it.outputItemID, it.recipeID) end
    end)
    row:SetScript("OnLeave", HideTooltip)
    row:SetScript("OnClick", function(self)
      local it = self.item
      if not it then return end
      if it.kind then onToggle(it) else onSelect(it) end
    end)
    return row
  end
end

local function GroupHeight(it)
  if it.kind == "prof" then return ROW.prof end
  if it.kind == "cat" then return it.collapsed and ROW.cat or ROW.catOpen end
  return it.gap and ROW.recipeLast or ROW.recipe
end

-- Tree indent: categories under a profession header and recipes under their category.
local function GroupIndent(it)
  return (it.depth or 0) * ROW.indent
end

local function GroupFill(fillEntry)
  return function(row, it)
    row.item = it
    local kind = it.kind
    local slot = GroupHeight(it)
    if row.SetHitRectInsets then
      row:SetHitRectInsets(0, 0, 0, max(0, slot - (kind and ROW.headerBar or ROW.recipeBar)))
    end
    ShowParts(row.recipeParts, kind == nil)
    ShowParts(row.headerParts, kind ~= nil)
    ShowParts(row.profParts, kind == "prof")
    if kind == nil then
      row.entry = it
      fillEntry(row, it)
      return
    end
    row.entry = nil
    row.sel:Hide()
    row.header:ClearAllPoints()
    row.header:SetPoint("RIGHT", row.bar, "RIGHT", kind == "prof" and -60 or -30, 0)
    if kind == "prof" then
      local icon = ProfIcon(it.prof)
      row.profIcon:SetTexture(icon or TEX.question)
      row.profIcon:SetShown(icon ~= nil)
      row.profIcon.border:SetShown(icon ~= nil)
      row.header:SetPoint("LEFT", row.bar, "LEFT", icon and 30 or 8, 0)
      row.count:SetText(it.count or "")
    else
      row.header:SetPoint("LEFT", row.bar, "LEFT", 8, 0)
    end
    row.header:SetText(it.name)
    row.header:SetTextColor(GOLD_RGB[1], GOLD_RGB[2], GOLD_RGB[3])
    if row.plusAtlas then
      SetAtlasSized(row.toggle, it.collapsed and row.plusAtlas or A.minus)
    else
      row.toggle:SetText(it.collapsed and "+" or EN_DASH)
      row.toggle:SetTextColor(GOLD_RGB[1], GOLD_RGB[2], GOLD_RGB[3])
    end
  end
end

-- " [n]": how many I can craft right now, after the recipe name (the list's Count text).
local function CountText(n)
  return C.countHex .. format(" [%d]", n or 0) .. "|r"
end

-- Recipe page header ------------------------------------------------------
-- SchematicForm's output: a 47x47 button at TOPLEFT 28,-28 holding the 53x53 icon (trimmed,
-- round CircleMask 49x49), the 68x68 auctionhouse-itemicon-border-white ring tinted by
-- quality (OVERLAY) and the same ring at 66x66, ADD, alpha 0.2 as highlight. OutputText
-- (GameFontHighlightMed2, quality coloured) at LEFT->icon.RIGHT 14,17; OutputSubText
-- (GameFontNormal) 5 px under it for "Profession · Rank"; Description (GameFontHighlightSmall2)
-- at TOPLEFT->icon.BOTTOMLEFT -1,-12. Without mask support the icon is a square bordered one.

local NewHeader, FillHeader
do
local TITLE_Y = -(28 + ICON_SIZE / 2 - 17)   -- OutputText's vertical centre from the form top

local function FitHeader(h)
  local t = h.title
  t:SetFontObject(FontOf(FONTS.title))
  if t.SetMaxLines then t:SetMaxLines(1) end
  if t.SetWordWrap then t:SetWordWrap(false) end
  local avail = t:GetWidth() or 0
  local wrap = avail > 0 and StringWidth(t) > avail
  if wrap then
    t:SetFontObject(Font("GameFontHighlight"))
    if t.SetWordWrap then t:SetWordWrap(true) end
    if t.SetMaxLines then t:SetMaxLines(2) end
  end
  h.sub:SetShown(not wrap and (h.sub:GetText() or "") ~= "")
  -- SetFontObject resets the colour to the font's own: re-apply the item quality colour.
  if h.rgb then t:SetTextColor(h.rgb[1], h.rgb[2], h.rgb[3]) end
end

local function RoundMask(holder, target, inset)
  local mask = holder.CreateMaskTexture and holder:CreateMaskTexture()
  if not (mask and target.AddMaskTexture) then return nil end
  mask:SetTexture(TEX.roundMask, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  mask:SetPoint("TOPLEFT", target, "TOPLEFT", inset, -inset)
  mask:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", -inset, inset)
  target:AddMaskTexture(mask)
  return mask
end

function NewHeader(parent)
  local h = {}
  local holder = CreateFrame("Button", nil, parent)
  holder:SetSize(ICON_SIZE, ICON_SIZE)
  holder:SetPoint("TOPLEFT", 28, -28)
  holder:SetScript("OnEnter", function(self)
    if h.recipeID or h.itemID then ShowTooltip(self, h.itemID, h.recipeID) end
  end)
  holder:SetScript("OnLeave", HideTooltip)
  -- Like shift-clicking the output icon: drop the item link into an open chat box.
  holder:SetScript("OnClick", function() InsertLink(ItemLink(h.itemID)) end)
  h.holder = holder

  local icon = holder:CreateTexture(nil, "BORDER")
  icon:SetSize(53, 53)
  icon:SetPoint("CENTER")
  icon:SetTexCoord(0.078125, 0.921875, 0.078125, 0.921875)
  h.icon = icon
  if RoundMask(holder, icon, 2) then
    h.round = true
    if HasAtlas(A.ring) then
      local ring = holder:CreateTexture(nil, "OVERLAY")
      ring:SetAtlas(A.ring, false)
      ring:SetSize(68, 68)
      ring:SetPoint("CENTER")
      h.ring, h.ringAtlas = ring, true
      local hl = holder:CreateTexture(nil, "HIGHLIGHT")
      hl:SetAtlas(A.ring, false)
      hl:SetSize(66, 66)
      hl:SetPoint("CENTER")
      hl:SetBlendMode("ADD")
      hl:SetAlpha(0.2)
    else
      local disc = holder:CreateTexture(nil, "BACKGROUND")
      disc:SetSize(ICON_SIZE + 4, ICON_SIZE + 4)
      disc:SetPoint("CENTER")
      disc:SetColorTexture(C.ring[1], C.ring[2], C.ring[3], 1)
      RoundMask(holder, disc, 0)
      h.ring = disc
    end
  else
    icon:SetSize(40, 40)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local border = holder:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0, 0, 0, 0.85)
    icon.border = border
  end

  h.title = Label(parent, nil, FontOf(FONTS.title))
  h.title:SetPoint("LEFT", holder, "RIGHT", 14, 17)
  h.title:SetPoint("RIGHT", parent, "TOPRIGHT", -20, TITLE_Y)
  h.sub = Label(parent, nil, Font("GameFontNormal"))
  h.sub:SetPoint("TOPLEFT", h.title, "BOTTOMLEFT", 0, -5)
  h.sub:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
  h.desc = Label(parent, nil, FontOf(FONTS.desc))
  h.desc:SetPoint("TOPLEFT", holder, "BOTTOMLEFT", -1, -12)
  h.desc:SetPoint("RIGHT", parent, "RIGHT", -28, 0)
  if h.desc.SetWordWrap then h.desc:SetWordWrap(true) end
  if h.desc.SetMaxLines then h.desc:SetMaxLines(7) end
  parent:HookScript("OnSizeChanged", function() FitHeader(h) end)
  return h
end

function FillHeader(h, recipeID, itemID, name, sub, desc)
  h.recipeID, h.itemID = recipeID, itemID
  h.icon:SetTexture(RecipeIcon(recipeID, itemID))
  local itemName = itemID and NS.Inventory and NS.Inventory.ItemName and NS.Inventory.ItemName(itemID)
  h.title:SetText(itemName or name or "")
  local q = ItemQuality(itemID)
  local r, g, b = QualityRGB(q)
  h.rgb = { r, g, b }
  h.sub:SetText(sub or "")
  h.hasDesc = type(desc) == "string" and desc ~= ""
  h.desc:SetText(h.hasDesc and desc or "")
  h.desc:SetShown(h.hasDesc)
  if h.ring and h.ring.SetVertexColor then
    -- The white ring atlas takes the quality colour (white for common, as in the dump); the
    -- plain disc stays bronze below uncommon.
    if h.ringAtlas or (type(q) == "number" and q >= 2) then
      h.ring:SetVertexColor(r, g, b)
    else
      h.ring:SetVertexColor(C.ring[1], C.ring[2], C.ring[3])
    end
  end
  FitHeader(h)
end
end

-- Anchor a section label ("Reagents:", 20 px tall) under the header: 20 px under the
-- description (SchematicForm.Reagents: TOPLEFT->Description.BOTTOMLEFT 0,-20), else under
-- the icon.
local function AnchorBelowHeader(h, fs)
  fs:ClearAllPoints()
  if h.hasDesc then
    fs:SetPoint("TOPLEFT", h.desc, "BOTTOMLEFT", 0, -20)
  else
    fs:SetPoint("TOPLEFT", h.holder, "BOTTOMLEFT", -1, -12)
  end
end

-- Section label: GameFontNormalSmall gold in a 20 px line (Reagents.Label 180x20).
local function SectionLabel(parent, text)
  local fs = Label(parent, text, FontOf(FONTS.section))
  fs:SetHeight(20)
  fs:SetWidth(180)
  if fs.SetJustifyV then fs:SetJustifyV("MIDDLE") end
  fs:SetTextColor(GOLD_RGB[1], GOLD_RGB[2], GOLD_RGB[3])
  return fs
end

-- Detail rows ---------------------------------------------------------------

-- Crafter: name green when online, grey when offline or busy ("Bob (busy)", not clickable);
-- me and my alts marked.
local function CrafterRow(parent, rowH)
  local row = RowBase(parent, rowH)
  row.state = Muted(Label(row, nil, "GameFontHighlightSmall"))
  row.state:SetPoint("RIGHT", -4, 0)
  row.state:SetJustifyH("RIGHT")
  row.name = Label(row, nil, FontOf(FONTS.row))
  row.name:SetPoint("LEFT", 4, 0)
  row.name:SetPoint("RIGHT", row.state, "LEFT", -6, 0)
  row:SetScript("OnEnter", function(self)
    local c = self.crafter
    if c and c.busy then
      TextTooltip(self, Short(c.name), L["Busy: not taking whispers from the board right now."])
    elseif c and not c.mine then
      TextTooltip(self, Short(c.name), find.itemID and L["Click to whisper a request."] or nil)
    else
      return
    end
    local crafted = NS.Trade and NS.Trade.CraftedText(c.name)
    if crafted and GameTooltip then
      GameTooltip:AddLine(crafted, MUTED[1], MUTED[2], MUTED[3], true)
      GameTooltip:Show()
    end
  end)
  row:SetScript("OnClick", function(self)
    local c = self.crafter
    if not c or c.mine or c.busy then return end
    find.crafter = c.name
    find.crafters:Render()
    UI.UpdateWhisper()
    if find.itemID then OpenWhisper(c.name, find.itemID, ReadQty(find.qty)) end
  end)
  return row
end

local function FillCrafterRow(row, c)
  row.crafter = c
  row.name:SetText(c.busy and format(L["%s (busy)"], Short(c.name)) or Short(c.name))
  if c.online and not c.busy then
    row.name:SetTextColor(ONLINE_RGB[1], ONLINE_RGB[2], ONLINE_RGB[3])
  else
    row.name:SetTextColor(MUTED[1], MUTED[2], MUTED[3])
  end
  local state
  if c.mine then
    state = "|cffffd100" .. (c.name == NS.Me and L["you"] or L["alt"]) .. "|r"
  elseif c.online and not c.busy then
    state = GREEN .. L["online"] .. "|r"
  elseif c.online then
    state = L["online"]
  else
    state = L["offline"]
  end
  -- Cooldown crafts (transmutes, Mooncloth): ready, or how long until it is.
  local left = find.entry and NS.Cooldowns and NS.Cooldowns.Remaining(c.name, find.entry.recipeID)
  if left then
    state = state .. DOT .. (left <= 0 and (GREEN .. L["ready"] .. "|r") or format(L["cooldown %s"], NS.Cooldowns.Text(left)))
  end
  row.state:SetText(state)
  -- Busy rows keep the mouse for their tooltip; OnClick ignores them.
  row:EnableMouse(not c.mine)
  row.sel:SetShown(not c.mine and not c.busy and c.name == find.crafter)
end

-- Reagent slot, like SchematicForm.Reagents: a 39x39 slot (Professions-Slot-bg behind the
-- icon, Professions-Slot-Frame 48x48 over it at -5,4 / 4,-5, square ADD highlight) and the
-- "have/need Name" text (GameFontHighlight_NoShadow, 108x36, at LEFT 46), white when there
-- is enough and grey (a0a0a0) when short. Without the slot atlases: a 36 px bordered icon.
local function ReagentRow(parent, rowH)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(rowH)
  local slotted = HasAtlases(A.slotBg, A.slotFrame)
  local slot = CreateFrame("Button", nil, row)
  slot:SetSize(39, 39)
  slot:SetPoint("LEFT", 1, 0)
  slot:EnableMouse(false)            -- the row handles the mouse
  if slotted then
    local bg = slot:CreateTexture(nil, "BACKGROUND")
    bg:SetAtlas(A.slotBg, false)
    bg:SetAllPoints()
    row.icon = slot:CreateTexture(nil, "ARTWORK")
    row.icon:SetAllPoints()
    local frameTex = slot:CreateTexture(nil, "OVERLAY")
    frameTex:SetAtlas(A.slotFrame, false)
    frameTex:SetPoint("TOPLEFT", row.icon, "TOPLEFT", -5, 4)
    frameTex:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", 4, -5)
  else
    row.icon = BorderedIcon(slot, 36)
    row.icon:SetPoint("CENTER")
  end
  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints(slot)
  if hl:SetTexture(TEX.slotHighlight) then hl:SetBlendMode("ADD") else hl:SetColorTexture(1, 1, 1, 0.12) end
  row.slot = slot
  row.name = Label(row, nil, FontOf(FONTS.row))
  row.name:SetPoint("LEFT", row, "LEFT", 47, 0)
  row.name:SetSize(108, 36)
  if row.name.SetWordWrap then row.name:SetWordWrap(true) end
  if row.name.SetMaxLines then row.name:SetMaxLines(3) end
  row:SetScript("OnEnter", function(self)
    ShowTooltip(self, self.itemID)
    if self.makers and GameTooltip and GameTooltip:IsShown() then
      GameTooltip:AddLine(self.makers, GOLD_RGB[1], GOLD_RGB[2], GOLD_RGB[3], true)
      GameTooltip:Show()
    end
  end)
  row:SetScript("OnLeave", HideTooltip)
  -- Like a shift-click: drop the item link into an open chat box (handy for asking guild).
  row:SetScript("OnClick", function(self) InsertLink(ItemLink(self.itemID)) end)
  return row
end

-- reagent: {itemID=, need=, have=}
local function FillReagentRow(row, r)
  row.itemID = r.itemID
  row.makers = r.makers
  row.icon:SetTexture(ItemIcon(r.itemID) or TEX.question)
  local text = format(L["%d/%d %s"], r.have, r.need, ItemName(r.itemID))
  -- What my other characters carry ("+12 on alts"), in grey, when it would help.
  local alt = r.have < r.need and NS.Inventory and NS.Inventory.AltText and NS.Inventory.AltText(r.itemID, r.alts)
  if alt then text = text .. "\n" .. GREY .. alt .. "|r" end
  row.name:SetText(text)
  if r.have >= r.need then
    row.name:SetTextColor(1, 1, 1)
  else
    row.name:SetTextColor(C.short[1], C.short[2], C.short[3])
  end
end
-- Data --------------------------------------------------------------------

local function PeerCounts()
  local peers = NS.Comm and NS.Comm.Peers and NS.Comm.Peers() or {}
  local total, online = 0, 0
  for _, p in pairs(peers) do
    total = total + 1
    if p.online then online = online + 1 end
  end
  return total, online
end

-- Profession names from every char of mine and every peer: [profID] = name.
local function ProfNames()
  local out = {}
  if type(CraftBoardDB) ~= "table" then return out end
  local function take(profs, isPeer)
    if type(profs) ~= "table" then return end
    for id, p in pairs(profs) do
      if type(p) == "table" and out[id] == nil and not p.gone then
        local n = p.name or (not isPeer and p[1]) or nil
        if type(n) == "string" and n ~= "" then out[id] = n end
      end
    end
  end
  -- Current char first, so its locale's names win.
  local chars = type(CraftBoardDB.chars) == "table" and CraftBoardDB.chars or {}
  if NS.Me and type(chars[NS.Me]) == "table" then take(chars[NS.Me].profs) end
  for _, c in pairs(chars) do
    if type(c) == "table" then take(c.profs) end
  end
  if NS.Comm and NS.Comm.Peers then
    for _, p in pairs(NS.Comm.Peers()) do take(p.profs, true) end
  end
  return out
end

local function ProfName(names, profID)
  if profID ~= nil and names[profID] then return names[profID] end
  if type(profID) == "string" then return profID end
  return L["Other"]
end

local ProfLine
do
-- Rank title for a skill cap, as the Professions window shows it under a profession.
local RANKS = {
  { 75, L["Apprentice"] }, { 150, L["Journeyman"] }, { 225, L["Expert"] },
  { 300, L["Artisan"] }, { 375, L["Master"] },
}
local function RankTitle(cap)
  if type(cap) ~= "number" or cap <= 0 then return nil end
  for _, r in ipairs(RANKS) do
    if cap <= r[1] then return r[2] end
  end
  return L["Grand Master"]
end

-- My rank in a profession: the current char's, else my best alt's. Profs are stored
-- positionally { name, rank, max } (named keys accepted too).
local function MyProfRank(profID)
  if profID == nil or type(CraftBoardDB) ~= "table" or type(CraftBoardDB.chars) ~= "table" then return nil end
  local function capOf(c)
    local p = type(c) == "table" and type(c.profs) == "table" and c.profs[profID]
    if type(p) ~= "table" then return nil end
    local m = p.max or p[3]
    return type(m) == "number" and m or nil
  end
  local best = NS.Me and capOf(CraftBoardDB.chars[NS.Me])
  if not best then
    for _, c in pairs(CraftBoardDB.chars) do
      local m = capOf(c)
      if m and (not best or m > best) then best = m end
    end
  end
  return RankTitle(best)
end

-- "Leatherworking · Journeyman" (rank only when one of my chars has the profession).
function ProfLine(names, profID)
  local line = ProfName(names, profID)
  local rank = MyProfRank(profID)
  if rank then line = line .. DOT .. rank end
  return line
end
end

-- Profession of a recipe: my stored record, else the shared catalogue (filled from peers).
local function ProfOf(recipeID)
  local rec = NS.Recipes and NS.Recipes.Record and NS.Recipes.Record(recipeID)
  if rec and rec.p ~= nil then return rec.p end
  local cat = type(CraftBoardDB) == "table" and CraftBoardDB.recipeNames
  local e = type(cat) == "table" and cat[recipeID]
  return type(e) == "table" and e.p or nil
end

-- Output item for a recipe: search entry, own record, then the shared name catalogue.
local function OutputOf(recipeID, entry)
  if entry and entry.outputItemID then return entry.outputItemID end
  if not recipeID then return nil end
  local rec = NS.Recipes and NS.Recipes.Record and NS.Recipes.Record(recipeID)
  if rec and rec.o then return rec.o end
  local cat = type(CraftBoardDB) == "table" and CraftBoardDB.recipeNames
  local e = type(cat) == "table" and cat[recipeID]
  return type(e) == "table" and e.o or nil
end

local function MyRecipeCount()
  local seen, n = {}, 0
  if type(CraftBoardDB) ~= "table" or type(CraftBoardDB.chars) ~= "table" then return 0 end
  for _, c in pairs(CraftBoardDB.chars) do
    if type(c) == "table" and type(c.recipes) == "table" then
      for id in pairs(c.recipes) do
        if not seen[id] then seen[id], n = true, n + 1 end
      end
    end
  end
  return n
end

-- Find: universe ----------------------------------------------------------
-- Everything on the board (Recipes.Search("")), annotated once per data change so typing
-- only filters: lower-cased names, profession, who knows it, whether I can craft it now.

local universe, universeByID, universeProfs = {}, {}, {}
-- [output itemID] = who on the board makes it, over every recipe that does:
-- { me =, alt =, peersN =, crafters = { crafter, ... } (each player once) }
local universeByItem = {}

local function BuildUniverse()
  local R, I = NS.Recipes, NS.Inventory
  local all = R and R.Search and R.Search("") or {}
  local names = ProfNames()
  local myRecipes = R and R.Mine and R.Mine() or {}
  local profCount = {}
  universe, universeByID, universeByItem = {}, {}, {}
  for _, e in ipairs(all) do
    local out = OutputOf(e.recipeID, e)
    local itemName = out and I and I.ItemName and I.ItemName(out)
    local name = e.name
    -- Search fell back to the generic "Recipe <id>" label: the output item name reads better.
    if itemName and name == format(L["Recipe %d"], e.recipeID) then name = itemName end
    local u = {
      recipeID = e.recipeID, name = name, outputItemID = out, crafters = e.crafters or {},
      lname = strlower(name or ""), litem = itemName and strlower(itemName) or nil,
      prof = ProfOf(e.recipeID), group = R and R.GroupOf and R.GroupOf(e.recipeID, out) or L["Other"], me = false, alt = nil, onlineN = 0, onlineName = nil,
      peersN = 0, peerName = nil, ready = false, times = 0,
    }
    for _, c in ipairs(u.crafters) do
      if c.mine then
        if c.name == NS.Me then
          u.me = true
        elseif not u.alt then
          -- An alt only counts when it can supply this realm and faction (linked orders, "Alt").
          local chars = type(CraftBoardDB) == "table" and type(CraftBoardDB.chars) == "table" and CraftBoardDB.chars or {}
          local reachable = NS.Inventory and NS.Inventory.Reachable
          if not reachable or reachable(c.name, chars[c.name]) then u.alt = Short(c.name) end
        end
      else
        u.peersN = u.peersN + 1
        u.peerName = u.peerName or Short(c.name)
        if c.online then
          u.onlineN = u.onlineN + 1
          u.onlineName = u.onlineName or Short(c.name)
        end
      end
    end
    local rec = myRecipes[e.recipeID]
    if u.me and rec and I and I.CanCraft then
      local cc = I.CanCraft(rec)
      u.ready, u.times = cc.ready and true or false, cc.times or 0
    end
    if u.prof ~= nil then profCount[u.prof] = (profCount[u.prof] or 0) + 1 end
    universe[#universe + 1] = u
    universeByID[u.recipeID] = u
    if out then
      local m = universeByItem[out]
      if not m then
        m = { me = false, alt = nil, peersN = 0, crafters = {}, seen = {} }
        universeByItem[out] = m
      end
      m.me = m.me or u.me
      m.alt = m.alt or u.alt
      for _, c in ipairs(u.crafters) do
        if type(c.name) == "string" and not m.seen[c.name] then
          m.seen[c.name] = true
          m.crafters[#m.crafters + 1] = c
          if not c.mine then m.peersN = m.peersN + 1 end
        end
      end
    end
  end
  universeProfs = {}
  for id in pairs(profCount) do
    universeProfs[#universeProfs + 1] = { id = id, name = ProfName(names, id) }
  end
  table.sort(universeProfs, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return tostring(a.id) < tostring(b.id)
  end)
  find.profNames = names
  find.universeDirty = false
end

local function Tokens(text)
  local out = {}
  for w in strlower(text):gmatch("%S+") do out[#out + 1] = w end
  return out
end

local function Matches(u, tokens)
  for i = 1, #tokens do
    local t = tokens[i]
    if not (u.lname:find(t, 1, true) or (u.litem and u.litem:find(t, 1, true))) then return false end
  end
  return true
end

local function ReadyThenName(a, b)
  if a.ready ~= b.ready then return a.ready end
  if a.name ~= b.name then return a.name < b.name end
  return a.recipeID < b.recipeID
end

local function StatusOrder(a, b)
  if a.ready ~= b.ready then return a.ready end
  if (a.onlineN > 0) ~= (b.onlineN > 0) then return a.onlineN > 0 end
  if a.name ~= b.name then return a.name < b.name end
  return a.recipeID < b.recipeID
end
-- "" (only I know it) / "you" / "Alt" / "Bob" / "3 online" / "2 known", then a check if I can
-- craft it right now.
local function StatusText(u)
  if u.me then
    if not u.alt and u.peersN == 0 then return "" end
    return L["you"]
  end
  if u.alt then return u.alt end
  if u.onlineN == 1 then return u.onlineName end
  if u.onlineN > 1 then return format(L["%d online"], u.onlineN) end
  if u.peersN == 1 then return GREY .. u.peerName .. "|r" end
  if u.peersN > 1 then return GREY .. format(L["%d known"], u.peersN) .. "|r" end
  return ""
end

-- Intermediates (multi-crafter chains) -------------------------------------------
-- A reagent that is itself crafted: who on the board makes it. "Made by Bob, Carl (+2)" for
-- the reagent slot's tooltip; LinkedItem: what other players make for the slot and none of my
-- characters does.

local Chain = {}

function Chain.MakersText(itemID)
  local u = universeByItem[itemID]
  if not u then return nil end
  local names = {}
  if u.me then names[#names + 1] = L["you"] end
  if u.alt then names[#names + 1] = u.alt end
  for _, c in ipairs(u.crafters) do
    if #names >= 3 then break end
    if not c.mine then names[#names + 1] = Short(c.name) end
  end
  if #names == 0 then return nil end
  local more = (u.me and 1 or 0) + (u.alt and 1 or 0) + u.peersN - #names
  local text = format(L["Crafters: %s"], table.concat(names, ", "))
  if more > 0 then text = text .. format(" (+%d)", more) end
  return text
end

-- What a linked order for a short reagent slot asks for: of the tiers the slot accepts (r.alts;
-- its own item first), the first other players make, when none of my characters makes any of
-- them. nil: no linked order.
function Chain.LinkedItem(r)
  local ids = { r.itemID }
  for _, id in ipairs(type(r.alts) == "table" and r.alts or {}) do
    if id ~= r.itemID then ids[#ids + 1] = id end
  end
  local pick
  for _, id in ipairs(ids) do
    local u = universeByItem[id]
    if u and (u.me or u.alt) then return nil end
    if not pick and u and u.peersN > 0 then pick = id end
  end
  return pick
end

-- Short reagents of a craft that other players make and my characters don't:
-- { {itemID=, qty=}, ... } (the linked orders a request for it splits into).
function Chain.LinkedNeeds(missing)
  local out = {}
  for _, r in ipairs(missing or {}) do
    local id = Chain.LinkedItem(r)
    if id then out[#out + 1] = { itemID = id, qty = r.need - r.have } end
  end
  return out
end

function Chain.AnnotateMakers(reagents)
  for _, r in ipairs(reagents or {}) do r.makers = Chain.MakersText(r.itemID) end
  return reagents
end

-- "Elixir of Lesser Defense, 2x Coarse Thread"
function Chain.NeedsText(needs)
  local parts = {}
  for i, n in ipairs(needs) do
    parts[i] = (n.qty > 1 and format(L["%dx"], n.qty) .. " " or "") .. ItemName(n.itemID)
  end
  return table.concat(parts, ", ")
end

-- Grouping ------------------------------------------------------------------
-- entries (already in display order within a group) -> list items: with byProf, profession
-- headers (sorted by name) each holding category headers; else category headers only.
-- Categories sort by name, "Other" last. Collapsed groups (CraftBoardDB.ui.collapsed[name])
-- keep their header only; expandAll (while searching) opens every group that has a match.
-- Returns items and nav: the visible recipes in order, each with .idx (its item index).

local function CatLess(a, b)
  local oa, ob = a == L["Other"], b == L["Other"]
  if oa ~= ob then return ob end
  return a < b
end

local function Grouped(entries, byProf, expandAll, names)
  local collapsed = expandAll and {} or Collapsed()
  local profs, profOrder = {}, {}
  for _, e in ipairs(entries) do
    local pk = byProf and (e.prof ~= nil and e.prof or "?") or 1
    local pg = profs[pk]
    if not pg then
      pg = { prof = e.prof, name = ProfName(names or {}, e.prof), cats = {}, order = {}, n = 0 }
      profs[pk] = pg
      profOrder[#profOrder + 1] = pk
    end
    local cname = e.group or L["Other"]
    local cg = pg.cats[cname]
    if not cg then
      cg = {}
      pg.cats[cname] = cg
      pg.order[#pg.order + 1] = cname
    end
    cg[#cg + 1] = e
    pg.n = pg.n + 1
  end
  table.sort(profOrder, function(a, b)
    if profs[a].name ~= profs[b].name then return profs[a].name < profs[b].name end
    return tostring(a) < tostring(b)
  end)

  local items, nav = {}, {}
  for _, pk in ipairs(profOrder) do
    local pg = profs[pk]
    local depth, open = 0, true
    if byProf then
      open = not collapsed[pg.name]
      items[#items + 1] = { kind = "prof", name = pg.name, prof = pg.prof, count = pg.n, depth = 0, collapsed = not open }
      depth = 1
    end
    if open then
      table.sort(pg.order, CatLess)
      for _, cname in ipairs(pg.order) do
        local list = pg.cats[cname]
        local catOpen = not collapsed[cname]
        items[#items + 1] = { kind = "cat", name = cname, count = #list, depth = depth, collapsed = not catOpen }
        if catOpen then
          for i, e in ipairs(list) do
            e.depth = depth + 1
            e.gap = i == #list        -- the category's 10 px bottom padding follows it
            items[#items + 1] = e
            e.idx = #items
            nav[#nav + 1] = e
          end
        end
      end
    end
  end
  return items, nav
end

-- Collapse / expand a group header (not while searching: every group is open then).
local function ToggleGroup(t, it)
  if t.searching then return end
  local c = Collapsed()
  if c[it.name] then c[it.name] = nil else c[it.name] = true end
  t.refilter(true)
end

-- The profession filter (CraftBoardDB.ui.findProf) is honoured only while that profession is
-- in the list.
local function ValidProf(profList, id)
  if id == nil then return nil end
  for _, pr in ipairs(profList or {}) do
    if pr.id == id then return id end
  end
  return nil
end

local function SetProf(id)
  local db = UIDB()
  if db then db.findProf = id end
  UI.FilterFind(false)
end

local SetPortrait   -- Window section

-- Portrait: the selected profession's icon, else CraftBoard's own. Standalone window only:
-- Blizzard's portrait on ProfessionsFrame is never touched.
local function UpdatePortrait(profID)
  if not (frame and MODERN and host == frame) then return end
  local tex = (profID ~= nil and ProfIcon(profID)) or TEX.portrait
  if tex == portraitNow then return end
  portraitNow = tex
  SetPortrait(frame, tex)
end


-- Search box --------------------------------------------------------------------
-- RecipeList.SearchBox: SearchBoxTemplate at TOPLEFT 13,-8 of the list, 20 px tall, its
-- right edge 4 px left of the Filter button; common-search-border-* border, the 10x10
-- magnifying glass (grey 0.6) at LEFT 1,-1, text (10 pt) and the "Search" hint 16 px in.
-- Keys for the list t: Enter picks the arrowed or first visible entry, arrows move the
-- selection through the visible entries (t.results), Escape clears the text first and then
-- closes the standalone window (inside ProfessionsFrame it only lets go of the keyboard, so the
-- next Escape closes Blizzard's window the usual way). t.keyOf / t.selectedKey / t.selectKey map entries to the selection
-- (default: Find's recipe IDs).
local function NewSearchBox(name, parent, t)
  local keyOf = t.keyOf or function(u) return u.recipeID end
  local current = t.selectedKey or function() return selectedID end
  local selectKey = t.selectKey or function(key) UI.PickRecipe(key) end
  local box
  if HasTemplate("SearchBoxTemplate") then
    local ok, e = pcall(CreateFrame, "EditBox", name, parent, "SearchBoxTemplate")
    if ok then box = e end
  end
  if not box then
    box = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
  end
  box:SetHeight(20)
  box:SetAutoFocus(false)
  StyleSearchBorder(box)
  local icon = box.searchIcon or box.SearchIcon
  if icon and HasAtlas(A.searchIcon) then
    icon:SetAtlas(A.searchIcon, false)
    icon:SetSize(10, 10)
    icon:ClearAllPoints()
    icon:SetPoint("LEFT", box, "LEFT", 1, -1)
    icon:SetVertexColor(0.6, 0.6, 0.6, 1)
  end
  local clear = box.clearButton or box.ClearButton
  local clearTex = clear and (clear.texture or clear.Icon)
  if clearTex and HasAtlas(A.searchClear) then
    clearTex:SetAtlas(A.searchClear, false)
    clearTex:SetSize(10, 10)
    clearTex:ClearAllPoints()
    clearTex:SetPoint("TOPLEFT", clear, "TOPLEFT", 3, -3)
    clearTex:SetAlpha(0.5)
  end
  box:SetFontObject(Font("GameFontHighlightSmall"))
  if box.SetTextInsets then box:SetTextInsets(16, 20, 0, 0) end
  -- Soft hint while empty: the template's own instructions text, else our own label.
  local hint = box.Instructions
  if hint then
    hint:SetFontObject(Font("GameFontDisableSmall", "GameFontDisable"))
    hint:ClearAllPoints()
    hint:SetPoint("TOPLEFT", box, "TOPLEFT", 16, 0)
    hint:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -20, 0)
  else
    hint = Label(box, nil, "GameFontDisableSmall")
    hint:SetPoint("LEFT", 16, 0)
    box.cbHint = hint
  end
  hint:SetText(L["Search"])

  box:SetScript("OnEnterPressed", function(self)
    local list = t.results or {}
    local pick = (t.arrowed and current()) or (list[1] and keyOf(list[1]))
    if pick then selectKey(pick) end
    self:ClearFocus()
  end)
  box:SetScript("OnEscapePressed", function(self)
    if (self:GetText() or "") ~= "" then
      self:SetText("")
    else
      self:ClearFocus()
      if frame and host == frame then frame:Hide() end
    end
  end)
  box:SetScript("OnArrowPressed", function(_, key)
    local list = t.results or {}
    if #list == 0 then return end
    local idx, cur = 0, current()
    for i, u in ipairs(list) do
      if keyOf(u) == cur then idx = i break end
    end
    if key == "DOWN" then
      idx = min(#list, idx + 1)
    elseif key == "UP" then
      idx = max(1, idx - 1)
    else
      return
    end
    t.arrowed = true
    selectKey(keyOf(list[idx]))
    t.list:ScrollTo(list[idx].idx)
  end)
  box:HookScript("OnTextChanged", function(self)
    if self.cbHint then self.cbHint:SetShown((self:GetText() or "") == "") end
    t.arrowed = false
    t.refilter(false)
  end)
  return box
end

-- Framed area: the given background atlas (else none) under the common-insideframe border
-- (SchematicForm). Without the border atlas: an InsetFrameTemplate child. Returns the
-- background texture (nil in the inset case) and whether the atlas style is in use.
local function Framed(f, bgAtlas)
  if not HasAtlas(A.cardBorder) then
    local inset = NewInset(f)
    inset:SetAllPoints()
    f.cbInset = inset
    local bg = inset:CreateTexture(nil, "BACKGROUND", nil, 1)
    bg:SetPoint("TOPLEFT", 3, -3)
    bg:SetPoint("BOTTOMRIGHT", -3, 3)
    bg:Hide()
    return bg, false
  end
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  if bgAtlas and HasAtlas(bgAtlas) then bg:SetAtlas(bgAtlas, false) else bg:Hide() end
  local border = f:CreateTexture(nil, "BORDER")
  border:SetAtlas(A.cardBorder, false)
  border:SetAllPoints()
  return bg, true
end

-- Left: RecipeList (TOPLEFT 5,-72 to the bottom, 304 px at the default size) on
-- Professions-background-summarylist, with the search box and the Filter dropdown
-- (89x18 at TOPRIGHT -8,-9) at its top and the ScrollBox at 8,-35 / -20,5 (MinimalScrollBar
-- in the 8 px right of it; rows 5 px in from the top and right). Right: SchematicForm
-- (TOPLEFT->list.TOPRIGHT 2,0 down to 38 px above the frame bottom) with the profession
-- card background under common-insideframe. Returns the form.
local function ListColumn(p, t)
  local left = CreateFrame("Frame", nil, p)
  left:SetPoint("TOPLEFT", p, "TOPLEFT", G.listX, G.listY)
  left:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", G.listX, G.listB)
  left:SetWidth(LEFT_W)
  t.left = left
  if HasAtlas(A.listBg) then
    local bg = left:CreateTexture(nil, "BACKGROUND")
    bg:SetAtlas(A.listBg, false)
    bg:SetAllPoints()
    t.listBg = bg
  else
    local inset = NewInset(left)
    inset:SetPoint("TOPLEFT", 0, -30)
    inset:SetPoint("BOTTOMRIGHT")
    t.listInset = inset
  end
  return left
end

local function CardForm(p, t, left)
  local form = CreateFrame("Frame", nil, p)
  form:SetPoint("TOPLEFT", left, "TOPRIGHT", G.formGap, 0)
  form:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -G.formR, G.formB)
  t.form = form
  t.bg, t.cardStyle = Framed(form, nil)
  return form
end

-- The recipe list's grouped rows under the search box: ScrollBox at 8,-35 / -20,5 (rows 5 px
-- in from the top and right, MinimalScrollBar in the 8 px right of them).
local function GroupList(t, left, listName, makeRow, fill)
  t.list = NewList(listName, left, ROW.recipe, makeRow, fill, { heightOf = GroupHeight,
    indentOf = GroupIndent, stripes = false, padTop = 5, padRight = 5, barGap = 0, emptyWidth = 200 })
  t.list.box:SetPoint("TOPLEFT", left, "TOPLEFT", 8, -35)
  t.list.box:SetPoint("BOTTOMRIGHT", left, "BOTTOMRIGHT", min(-4, -20 + t.list.barW), 5)
  return t.list
end

-- The Filter dropdown at the list column's top right (89x18 at TOPRIGHT -8,-9).
local function AddFilter(t, left, entries, isDefault, reset)
  t.filterEntries = entries
  t.filter = NewFilterButton(left, entries, isDefault, reset)
  t.filter:SetPoint("TOPRIGHT", left, "TOPRIGHT", -8, -9)
  if t.filter.cbMode == "dropdown" then
    t.filter:SetSize(89, 18)
    local bg = t.filter.Background
    if bg and HasAtlas(A.dropdown) then
      bg:SetAtlas(A.dropdown, false)
      bg:ClearAllPoints()
      bg:SetPoint("TOPLEFT", t.filter, "TOPLEFT", -4, 4)
      bg:SetPoint("BOTTOMRIGHT", t.filter, "BOTTOMRIGHT", 4, -4)
    end
    if t.filter.Text then t.filter.Text:SetFontObject(Font("GameFontNormal")) end
  end
  return t.filter
end

local function BuildColumns(p, t, listName, fillEntry, entries, isDefault, reset)
  local left = ListColumn(p, t)
  AddFilter(t, left, entries, isDefault, reset)
  t.search = NewSearchBox("CraftBoardSearchBox", left, t)
  t.search:SetPoint("TOPLEFT", left, "TOPLEFT", 13, -8)
  t.search:SetPoint("RIGHT", t.filter, "LEFT", -4, 0)

  GroupList(t, left, listName,
    GroupRowFactory(function(it) UI.PickRecipe(it.recipeID) end, function(it) ToggleGroup(t, it) end),
    GroupFill(fillEntry))
  return CardForm(p, t, left)
end

-- Button row under the recipe card (CreateAllButton / CreateMultipleInputBox / CreateButton):
-- from the card's left edge to the frame's right edge, buttons 7 px above the frame bottom.
local function NewBar(p, form)
  local bar = CreateFrame("Frame", nil, p)
  bar:SetPoint("TOPLEFT", form, "BOTTOMLEFT", 0, 0)
  bar:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", 0, 0)
  return bar
end

-- Quantity: NumericInputSpinnerTemplate (31x20, the "< 1 >" of the Create row) with the
-- common-search-border-* border; the decrement arrow sits 6 px left of it, the increment
-- right after it. Returns the box and the width of the decrement arrow + gap.
local function BarQty(bar, name)
  local box, spinner = QtyBox(name, bar)
  box:SetSize(31, 20)
  if spinner then StyleSearchBorder(box, true) end
  box:HookScript("OnEnter", function(self) TextTooltip(self, L["Quantity"]) end)
  box:HookScript("OnLeave", HideTooltip)
  return box, spinner and 29 or 0, spinner and 23 or 0
end

-- Note field: an edit box in the search box style with a grey "Note" hint.
local function NoteBox(name, parent)
  local e = EditBox(name, parent, 90, 60)
  e:SetHeight(20)
  if StyleSearchBorder(e) and e.SetTextInsets then e:SetTextInsets(2, 4, 0, 0) end
  e:SetFontObject(Font("GameFontHighlightSmall"))
  Hint(e, L["Note"], 2)
  return e
end
local function ProfEntries(t)
  return function()
    local e = { { kind = "radio", text = L["All professions"],
      get = function() return t.prof == nil end, set = function() SetProf(nil) end } }
    for _, pr in ipairs(t.profs or {}) do
      e[#e + 1] = { kind = "radio", text = pr.name,
        get = function() return t.prof == pr.id end, set = function() SetProf(pr.id) end }
    end
    return e
  end
end

-- Find tab ------------------------------------------------------------------

-- "Missing: 3 Light Leather, 1 Coarse Thread" under the reagent slots of a recipe one of my
-- chars knows, only while something is short: the description font in grey with a gold
-- label. Each item name is a hyperlink; clicking it drops the item link into an open chat
-- box, hovering shows the item. Without hyperlink support a click inserts every short item.
local function NewMissingLine(parent)
  local line = CreateFrame("Frame", nil, parent)
  line:SetHeight(14)
  line:EnableMouse(true)
  line.text = Label(line, nil, FontOf(FONTS.desc))
  line.text:SetPoint("TOPLEFT", 0, 0)
  line.text:SetPoint("RIGHT", 0, 0)
  line.text:SetTextColor(C.short[1], C.short[2], C.short[3])
  if line.text.SetWordWrap then line.text:SetWordWrap(true) end
  if line.text.SetMaxLines then line.text:SetMaxLines(2) end
  local function itemOf(link)
    return tonumber(type(link) == "string" and link:match("^item:(%d+)") or nil)
  end
  if line.SetHyperlinksEnabled then
    line:SetHyperlinksEnabled(true)
    line:SetScript("OnHyperlinkClick", function(_, link) InsertLink(ItemLink(itemOf(link))) end)
    line:SetScript("OnHyperlinkEnter", function(self, link) ShowTooltip(self, itemOf(link)) end)
    line:SetScript("OnHyperlinkLeave", HideTooltip)
  else
    line:SetScript("OnMouseUp", function(self)
      for _, r in ipairs(self.missing or {}) do InsertLink(ItemLink(r.itemID)) end
    end)
  end
  line:Hide()
  return line
end

-- missing: Inventory.CanCraft's short reagents ({itemID=, need=, have=}); empty hides it.
local function FillMissingLine(line, missing)
  line.missing = missing
  if not missing or #missing == 0 then
    line.text:SetText("")
    line:Hide()
    return false
  end
  local parts = {}
  for i, r in ipairs(missing) do
    parts[i] = format("|Hitem:%d|h%s|h", r.itemID, format(L["%d %s"], r.need - r.have, ItemName(r.itemID)))
  end
  line.text:SetText(GOLD_HEX .. L["Missing:"] .. "|r " .. table.concat(parts, ", "))
  local h = line.text.GetStringHeight and line.text:GetStringHeight()
  line:SetHeight(max(14, type(h) == "number" and h or 14))
  line:Show()
  return true
end

local function FillFindEntry(row, u)
  row.name:SetText(u.ready and (u.name .. CountText(u.times)) or u.name)
  row.name:SetTextColor(NameRGB(u.outputItemID))
  row.status:SetText(StatusText(u))
  row.sel:SetShown(u.recipeID == selectedID)
end

-- Advertise ------------------------------------------------------------------
-- One plain "LF crafter" line in a public channel (Options: General / Trade / Off) for players
-- without CraftBoard. Only ever sent from the button's click (a hardware event), at most once
-- a minute; never automatically.
local ADVERTISE_ICON = "Interface\\Icons\\Ability_Warrior_BattleShout"
local Advertise, AdvertiseChoice, AdvertiseText, ChannelLabel
do
local ADVERTISE_GAP = 60
local CHANNELS = { General = L["General"], Trade = L["Trade"], Off = L["Off"] }
local lastAdvertise

function ChannelLabel(choice)
  return CHANNELS[choice] or choice
end

function AdvertiseChoice()
  if NS.Options and NS.Options.AdvertiseChannel then return NS.Options.AdvertiseChannel() end
  local v = type(CraftBoardDB) == "table" and CraftBoardDB.advertiseChannel
  if v == "General" or v == "Off" then return v end
  return "Trade"
end

-- Joined channel id for "General" / "Trade" ("General - Orgrimmar", "Trade - City"), or nil.
local function PublicChannelId(choice)
  local bases = { strlower(ChannelLabel(choice)), strlower(choice) }
  local function matches(n)
    if type(n) ~= "string" then return false end
    n = strlower(n)
    for _, b in ipairs(bases) do
      if n == b or n:sub(1, #b + 1) == b .. " " then return true end
    end
    return false
  end
  if GetChannelList then
    -- id, name, disabled triples; pack with the count (disabled may be nil).
    local list = (function(...) return { n = select("#", ...), ... } end)(GetChannelList())
    for i = 1, list.n, 3 do
      local id, n, disabled = list[i], list[i + 1], list[i + 2]
      if type(id) == "number" and id > 0 and not disabled and matches(n) then return id end
    end
  end
  if GetChannelName then
    local ok, id = pcall(GetChannelName, ChannelLabel(choice))
    if ok and type(id) == "number" and id > 0 then return id end
  end
  return nil
end

function AdvertiseText(itemID, qty)
  return format(L["LF crafter: %dx %s \226\128\148 whisper me (CraftBoard)"], qty,
    ItemLink(itemID) or ItemName(itemID))
end

local function Now()
  return (GetTime and GetTime()) or time()
end

function Advertise(itemID, qty)
  if not itemID then return false end
  local choice = AdvertiseChoice()
  if choice == "Off" then
    NS.Print(L["Advertising is off in the CraftBoard settings."])
    return false
  end
  local now = Now()
  if lastAdvertise and now - lastAdvertise < ADVERTISE_GAP then
    local wait = ceil(ADVERTISE_GAP - (now - lastAdvertise))
    NS.Print(format(wait == 1 and L["Please wait %d second before advertising again."] or L["Please wait %d seconds before advertising again."], wait))
    return false
  end
  local id = PublicChannelId(choice)
  if not id then
    NS.Print(format(L["You are not in the %s channel here."], ChannelLabel(choice)))
    return false
  end
  local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
  if not (send and pcall(send, AdvertiseText(itemID, qty), "CHANNEL", nil, id)) then
    NS.Print(format(L["Could not post in %s."], ChannelLabel(choice)))
    return false
  end
  lastAdvertise = now
  return true
end
end

function UI.UpdateAdvertise()
  if not find.advertise then return end
  find.advertise:SetEnabled(find.itemID ~= nil and AdvertiseChoice() ~= "Off")
end

local function BuildFind(p)
  find.refilter = function(keep) UI.FilterFind(keep) end
  local d = BuildColumns(p, find, "CraftBoardFindScroll", FillFindEntry, ProfEntries(find),
    function() return find.prof == nil end, function() SetProf(nil) end)

  find.none = Placeholder(d, L["Select a recipe to see who can craft it."])
  local body = CreateFrame("Frame", nil, d)
  body:SetAllPoints()
  find.body = body
  find.header = NewHeader(body)

  find.reagLabel = SectionLabel(body, L["Reagents:"])
  find.reagLabel:SetPoint("TOPLEFT", find.header.holder, "BOTTOMLEFT", -1, -12)
  -- The minimal scroll bar only shows when a recipe has more reagents than fit.
  find.reagents = NewList("CraftBoardReagentsScroll", body, REAGENT_H, ReagentRow, FillReagentRow, { inline = true, stripes = false })
  find.reagents.box:SetPoint("TOPLEFT", find.reagLabel, "TOPLEFT", 1, -20)
  find.reagents.box:SetPoint("RIGHT", body, "RIGHT", -20, 0)
  find.reagents.box:SetHeight(REAGENT_H)

  find.missing = NewMissingLine(body)
  find.missing:SetPoint("TOPLEFT", find.reagents.box, "BOTTOMLEFT", 0, -4)
  find.missing:SetPoint("RIGHT", body, "RIGHT", -20, 0)

  find.crafterLabel = SectionLabel(body, L["Crafters:"])
  find.crafterLabel:SetPoint("TOPLEFT", find.reagents.box, "BOTTOMLEFT", -1, -12)
  find.crafters = NewList("CraftBoardCraftersScroll", body, SUBROW_H, CrafterRow, FillCrafterRow, { inline = true })
  find.crafters.box:SetPoint("TOPLEFT", find.crafterLabel, "TOPLEFT", 0, -20)
  find.crafters.box:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -12, 10)

  -- Button row, like the Create row: note where "Create All" is, the "< 1 >" quantity,
  -- Whisper (tertiary square with the chat icon) and Post request (red, where "Create" is).
  local bar = NewBar(p, d)
  find.bar = bar

  find.post = RedButton(bar, L["Post request"], 112, 28)
  find.post:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -9, 7)
  find.post:SetScript("OnClick", function()
    local itemID = find.itemID
    if not (itemID and NS.Comm and NS.Comm.PostRequest) then return end
    local qty = ReadQty(find.qty)
    -- The request and its linked orders go up together or not at all.
    local linked = find.linked or {}
    for _, n in ipairs(linked) do
      if n.qty > 1000 then
        NS.Print(format(L["%s would need %d; one request can ask for 1000 at most. Post fewer."], ItemName(n.itemID), n.qty))
        return
      end
    end
    local slots = NS.Comm.OpenSlots and NS.Comm.OpenSlots()
    if slots and slots < 1 + #linked then
      NS.Print(format(L["That takes %d open requests and you have room for %d. Retract one first."], 1 + #linked, slots))
      return
    end
    local id = NS.Comm.PostRequest(itemID, qty, find.note:GetText())
    if id then
      find.note:SetText("")
      find.note:ClearFocus()
      NS.Print(format(L["Posted request: %dx %s"], qty, ItemName(itemID)))
      -- Intermediates other players make go up as linked orders, one per crafter's part.
      for _, n in ipairs(find.linked or {}) do
        if NS.Comm.PostRequest(n.itemID, n.qty, "", id) then
          NS.Print(format(L["Posted linked order: %dx %s"], n.qty, ItemName(n.itemID)))
        end
      end
    end
  end)
  find.post:SetScript("OnEnter", function(self)
    if self:IsEnabled() then
      TextTooltip(self, L["Post an open request to the board"], L["Guild and realm-channel CraftBoard users see it for 24h."])
      if find.linked and #find.linked > 0 and GameTooltip then
        GameTooltip:AddLine(format(L["Also posts linked orders for: %s"], Chain.NeedsText(find.linked)), GOLD_RGB[1], GOLD_RGB[2], GOLD_RGB[3], true)
        GameTooltip:Show()
      end
    else
      TextTooltip(self, L["This recipe makes no item to request"])
    end
  end)
  find.post:SetScript("OnLeave", HideTooltip)

  find.advertise = SquareButton(bar, L["Advertise"], ADVERTISE_ICON, 70)
  find.advertise.cbKind = "advertise"
  find.advertise:SetPoint("RIGHT", find.post, "LEFT", find.advertise.cbSquare and -6 or -4, 0)
  find.advertise:SetScript("OnClick", function()
    Advertise(find.itemID, ReadQty(find.qty))
  end)
  find.advertise:SetScript("OnEnter", function(self)
    local choice = AdvertiseChoice()
    if choice == "Off" then
      TextTooltip(self, L["Announce in chat"], L["Advertising is off in the CraftBoard settings."])
    elseif not find.itemID then
      TextTooltip(self, L["This recipe makes no item to request"])
    else
      TextTooltip(self, L["Announce in chat"], format(L["Posts once in %s: %s"], ChannelLabel(choice),
        AdvertiseText(find.itemID, ReadQty(find.qty))))
    end
  end)
  find.advertise:SetScript("OnLeave", HideTooltip)

  find.whisper = SquareButton(bar, L["Whisper"])
  find.whisper.cbKind = "whisper"
  find.whisper:SetPoint("RIGHT", find.advertise, "LEFT", -4, 0)
  -- Like every other whisper in CraftBoard: the chat box opens with the text typed in, and the
  -- player sends it.
  find.whisper:SetScript("OnClick", function()
    local name, itemID = find.whisperTo, find.itemID
    if name and itemID then OpenWhisper(name, itemID, ReadQty(find.qty)) end
  end)
  find.whisper:SetScript("OnEnter", function(self)
    if self:IsEnabled() then
      TextTooltip(self, format(L["Whisper %s"], Short(find.whisperTo)),
        format(L["Opens the chat box with: %s"], RequestText(find.itemID, ReadQty(find.qty))))
    elseif not find.itemID then
      TextTooltip(self, L["This recipe makes no item to request"])
    elseif find.whisperBusy then
      TextTooltip(self, format(L["%s is busy"], Short(find.whisperBusy)), L["Busy: not taking whispers from the board right now."])
    else
      TextTooltip(self, L["Only your own characters know this recipe."])
    end
  end)
  find.whisper:SetScript("OnLeave", HideTooltip)

  local decW, incW
  find.qty, decW, incW = BarQty(bar, "CraftBoardFindQty")
  find.qty:SetPoint("RIGHT", find.whisper, "LEFT", -(incW + 8), 0)
  find.qty:HookScript("OnTextChanged", Debouncer(0.2, function() UI.RefreshDetail() end))

  find.note = NoteBox("CraftBoardFindNote", bar)
  find.note:SetPoint("LEFT", bar, "TOPLEFT", 5, -(G.formB - 7 - 14))
  find.note:SetPoint("RIGHT", find.qty, "LEFT", -(decW + 10), 0)
  find.note:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
    if find.post:IsEnabled() then find.post:Click() end
  end)
end

-- Whisper target: the chosen crafter if still listed, else the first other player who isn't
-- busy (the list is sorted online first). Disabled when the chosen crafter has gone busy, or
-- when everyone else who knows it is busy (find.whisperBusy: who, for the tooltip).
function UI.UpdateWhisper()
  if not find.whisper then return end
  local e = find.entry
  local target, chosen, firstBusy
  for _, c in ipairs(e and e.crafters or {}) do
    if not c.mine then
      if c.busy then
        firstBusy = firstBusy or c.name
      elseif not target then
        target = c.name
      end
      if c.name == find.crafter then chosen = c end
    end
  end
  find.whisperBusy = nil
  if chosen and chosen.busy then
    target, find.whisperBusy = nil, chosen.name
  elseif chosen then
    target = chosen.name
  elseif not target then
    find.whisperBusy = firstBusy
  end
  find.whisperTo = target
  find.whisper:SetEnabled(target ~= nil and find.itemID ~= nil)
end

local function SelectedEntry()
  if not selectedID then return nil end
  return universeByID[selectedID]
end

-- Reagent slots shown without scrolling: what fits above the crafters label and a few
-- crafter rows.
local function ReagentRows(body, n)
  local h = body:GetHeight() or 0
  local fit = h > 0 and floor((h - 240) / REAGENT_H) or 4
  return min(max(1, n), max(2, fit))
end

function UI.RefreshDetail()
  if not find.body then return end
  local e = SelectedEntry()
  find.entry = e
  if not e then
    find.itemID = nil
    find.body:Hide()
    find.none:Show()
    find.post:SetEnabled(false)
    find.whisper:SetEnabled(false)
    UI.UpdateAdvertise()
    SetDetailBackground(find, nil)
    return
  end
  find.none:Hide()
  find.body:Show()

  local itemID = OutputOf(e.recipeID, e)
  find.itemID = itemID
  FillHeader(find.header, e.recipeID, itemID, e.name, ProfLine(find.profNames or {}, e.prof),
    ItemDescription(e.recipeID, itemID))
  AnchorBelowHeader(find.header, find.reagLabel)
  SetDetailBackground(find, e.prof)

  local qty = ReadQty(find.qty)
  local rec = NS.Recipes and NS.Recipes.Record and NS.Recipes.Record(e.recipeID)
  local reagents, missing, emptyText = {}, nil, nil
  if rec and type(rec.r) == "table" and #rec.r > 0 and NS.Inventory and NS.Inventory.CanCraft then
    local cc = NS.Inventory.CanCraft(rec, qty)
    reagents, missing = Chain.AnnotateMakers(cc.reagents), cc.missing
  elseif rec then
    emptyText = L["No reagents recorded."]
  else
    emptyText = L["Reagents unknown: none of your characters knows this recipe."]
  end
  -- Only the current character's own recipe: an alt's shortages aren't in these bags.
  local own = NS.Recipes and NS.Recipes.Mine and NS.Recipes.Mine()[e.recipeID]
  find.linked = own and Chain.LinkedNeeds(missing) or {}
  find.reagents.box:SetHeight(#reagents > 0 and REAGENT_H * ReagentRows(find.body, #reagents) or SUBROW_H)
  find.reagents:SetItems(reagents, emptyText, true)
  -- Records only exist for my chars' recipes, so a peer-only recipe never shows the line.
  local short = FillMissingLine(find.missing, missing)
  find.crafterLabel:ClearAllPoints()
  if short then
    find.crafterLabel:SetPoint("TOPLEFT", find.missing, "BOTTOMLEFT", -1, -8)
  else
    find.crafterLabel:SetPoint("TOPLEFT", find.reagents.box, "BOTTOMLEFT", -1, -12)
  end
  find.crafters:SetItems(e.crafters, L["No known crafters."], true)

  find.post:SetEnabled(itemID ~= nil)
  UI.UpdateAdvertise()
  UI.UpdateWhisper()
end

-- Select a recipe in the Find list.
function UI.SelectRecipe(recipeID)
  if selectedID ~= recipeID then find.crafter = nil end
  selectedID = recipeID
  if find.list then find.list:Render() end
  UI.RefreshDetail()
end

-- The player picked a recipe (click or keyboard), as opposed to the automatic first pick.
function UI.PickRecipe(recipeID)
  UI.SelectRecipe(recipeID)
  if NS.Onboarding then NS.Onboarding.Check("selected") end
end

-- Filter the cached universe by text and profession and group it. Called on every
-- keystroke. A selection the filter hides is replaced by the first visible recipe, so the
-- recipe page is never empty while the list has something (like the Professions window).
function UI.FilterFind(keepScroll)
  if not find.list then return end
  local db = UIDB()
  find.prof = ValidProf(find.profs, db and db.findProf)
  local text = strtrim(find.search:GetText() or "")
  local searching = #text >= 2
  find.searching = searching
  local prof = find.prof
  local candidates = {}
  for _, u in ipairs(universe) do
    if prof == nil or u.prof == prof then candidates[#candidates + 1] = u end
  end

  local results = {}
  if searching then
    local tokens = Tokens(text)
    local first = tokens[1] or ""
    for _, u in ipairs(candidates) do
      if Matches(u, tokens) then results[#results + 1] = u end
    end
    -- Names starting with the first word come first, then ready / online / name.
    table.sort(results, function(a, b)
      local pa = a.lname:sub(1, #first) == first
      local pb = b.lname:sub(1, #first) == first
      if pa ~= pb then return pa end
      return StatusOrder(a, b)
    end)
  else
    -- Every tradeable recipe on the board (all my chars and peers); within a group what I
    -- can craft right now first, then by name.
    for i = 1, #candidates do results[i] = candidates[i] end
    table.sort(results, ReadyThenName)
  end

  local visible = false
  for i = 1, #results do
    if results[i].recipeID == selectedID then visible = true break end
  end
  if selectedID and not visible then
    selectedID, find.crafter = nil, nil
  end

  local items, nav = Grouped(results, prof == nil, searching, find.profNames)
  find.results = nav

  local emptyText
  if #results == 0 then
    if #universe == 0 then
      emptyText = EMPTY_RECIPES
    elseif searching then
      emptyText = format(L["No known crafter for \"%s\"."], text)
    end
  end
  find.list:SetItems(items, emptyText, keepScroll)
  SyncFilterButton(find.filter, find.filterEntries)
  if activeTab == 1 then UpdatePortrait(prof) end
  local pick = not selectedID and (nav[1] or results[1])
  if pick then
    UI.SelectRecipe(pick.recipeID)
  else
    UI.RefreshDetail()
  end
end

function UI.RefreshFind(keepScroll)
  if not find.list then return end
  BuildUniverse()
  find.profs = universeProfs
  UI.FilterFind(keepScroll)
end

-- Requests tab --------------------------------------------------------------
-- The same two panels as Find, so it reads as the same window. The list on the left (search box
-- and Filter over the summary-list background) has gold group bars:
--   "Requests you can craft"  board requests and chat asks one of my characters can make (online
--                             players first, ready ones first);
--   "My queue"                crafts I said I'd make, with an "All reagents" row summing the queue;
--   "Open requests"           other board requests;
--   "Seen in chat"            other chat asks (hidden, with Open requests, by "Only what I can craft");
--   "My requests"             my own requests, and my alts'.
-- Rows lead with what is wanted (item icon, quality-coloured name, "3x" when more than one) and end
-- with a muted "Bob · 8m" (first names only; the card has the full name). A ready check sits where
-- the recipe label's skill-up mark is (grey when only an alt knows it). Requests whose author is
-- offline and chat asks older than 10 minutes are dimmed. Right-click opens the row's actions.
-- The card says whether I can make it and what is missing, with reagent slots (have/need),
-- linked orders and "crafted for you" counts; the Create row holds the actions, the main one red.
-- Refreshes wait while the mouse is over the list, so rows never move under a click.

local BuildRequests
do
local R = {}                   -- this section's helpers (kept off the file's local list)
local OLD_AGE = 10 * 60        -- chat asks older than this are dimmed
local OFFER_GAP = 10 * 60      -- Offer stays "Offered" this long after a click
local QUEUE_ICON = "Interface\\Icons\\INV_Misc_Bag_10"

-- First name only, for rows ("Aleksandria Brightwater" leaves no room for the item).
function R.First(name)
  local s = Short(name)
  return s:match("^(%S+)") or s
end

-- My character playing now wrote it.
function R.IsMyPost(post)
  return NS.SamePlayer(post.from, NS.Me)
end

-- One of my other characters wrote it: its key, else nil.
function R.AltOf(name)
  local chars = type(CraftBoardDB) == "table" and type(CraftBoardDB.chars) == "table" and CraftBoardDB.chars or {}
  for key in pairs(chars) do
    if key ~= NS.Me and NS.SamePlayer(key, name) then return key end
  end
  return nil
end

-- "just now" / "8m ago" / "2h ago"
function R.AgoText(t)
  if time() - (t or time()) < 60 then return L["just now"] end
  return format(L["%s ago"], Age(t))
end

function R.Online(name)
  if NS.Comm and NS.Comm.IsOnline then return NS.Comm.IsOnline(name) and true or false end
  local p = NS.Comm and NS.Comm.Peers and NS.Comm.Peers()[name]
  return p and p.online and true or false
end

-- What I know about each craftable item: { rec=, recipeID=, prof=, current=, char= } from my
-- chars' records (the current char first, current = true), else { recipeID=, prof= } from the
-- shared recipe catalogue (for the card background only). Cached until recipes change. multi:
-- the current character knows several recipes for it (R.KnowFor picks one per request).
function R.RecipesByOutput()
  if R.byOut and not R.byOutDirty then return R.byOut end
  local out = {}
  local db = type(CraftBoardDB) == "table" and CraftBoardDB or {}
  local chars = type(db.chars) == "table" and db.chars or {}
  local function take(c, current, key)
    if type(c) ~= "table" or type(c.recipes) ~= "table" then return end
    for id, rec in pairs(c.recipes) do
      if type(rec) == "table" and type(rec.o) == "number" then
        local k = out[rec.o]
        if not k then
          out[rec.o] = { rec = rec, recipeID = id, prof = rec.p, current = current, char = key }
        elseif current and k.current then
          k.multi = true
        end
      end
    end
  end
  if NS.Me then take(chars[NS.Me], true, NS.Me) end
  -- Only alts on this realm and faction: another's crafts can't reach the requester.
  local reachable = NS.Inventory and NS.Inventory.Reachable
  for key, c in pairs(chars) do
    if key ~= NS.Me and (not reachable or reachable(key, c)) then take(c, false, key) end
  end
  if type(db.recipeNames) == "table" then
    for id, e in pairs(db.recipeNames) do
      if type(e) == "table" and type(e.o) == "number" and not out[e.o] then
        out[e.o] = { recipeID = id, prof = e.p }
      end
    end
  end
  R.byOut, R.byOutDirty = out, false
  return out
end

-- The recipe a request for qty items uses on this character: know itself, or (several of my
-- recipes make the item) the one the bags allow, else the lowest recipe ID.
function R.KnowFor(know, itemID, qty)
  if not (know and know.multi and NS.Inventory and NS.Inventory.RecipeToUse) then return know end
  local id, rec = NS.Inventory.RecipeToUse(itemID, qty)
  if not id or id == know.recipeID then return know end
  return { rec = rec, recipeID = id, prof = rec.p, current = true, char = know.char, multi = true }
end

function R.Collapsed()
  local db = UIDB()
  if not db then return {} end
  if type(db.reqCollapsed) ~= "table" then db.reqCollapsed = {} end
  return db.reqCollapsed
end

function R.OnlyCan()
  local db = UIDB()
  return db and db.reqOnlyCan == true or false
end

-- Collapse / expand a group (not while searching).
function R.ToggleGroup(it)
  if reqs.searching then return end
  local c = R.Collapsed()
  if c[it.key] then c[it.key] = nil else c[it.key] = true end
  UI.FilterRequests(true)
end

-- Seconds since I offered on a post, or nil.
function R.OfferedAgo(e)
  local db = type(CraftBoardDB) == "table" and CraftBoardDB
  local t = e and e.post and db and type(db.offered) == "table" and db.offered[e.post.id]
  return type(t) == "number" and time() - t or nil
end

-- Actions ---------------------------------------------------------------------
-- Each one is a click by the player (the Create row, the row menu or the gamepad's A button).

-- Opens the chat box in whisper mode to `name` (like clicking a player name in chat).
function R.OpenTell(name)
  local tell = ChatFrame_SendTell or (ChatFrameUtil and ChatFrameUtil.SendTell)
  if tell and type(name) == "string" and pcall(tell, Short(name)) then return true end
  NS.Print(format(L["Could not whisper %s."], Short(name)))
  return false
end

function R.OfferText(item)
  return format(L["[CraftBoard] I can craft %s for you."], ItemLink(item) or ItemName(item))
end

-- Offer: sends the whisper right away (it only ever goes to a request I can craft), once per
-- OFFER_GAP whichever way it is asked for (button, menu, gamepad).
function R.Offer(e)
  if not (e and e.post and not e.mine and e.can) then return end
  local ago = R.OfferedAgo(e)
  if ago and ago < OFFER_GAP then return end
  if NS.Comm and NS.Comm.Whisper and NS.Comm.Whisper(e.post.from, R.OfferText(e.post.item)) then
    if NS.Comm.MarkOffered then NS.Comm.MarkOffered(e.post.id) end
    UI.RefreshRequestDetail()
    -- An offered request stops counting: recount for the tab, embedded tab and broker badges.
    reqs.countDirty = true
    if UI.RequestCount then UI.RequestCount() end
    UI.UpdateBadge()
  else
    NS.Print(format(L["Could not whisper %s."], Short(e.post.from)))
  end
end

-- Whisper: opens the chat box, typed in when I can craft it, empty otherwise.
function R.WhisperPost(e)
  if not (e and e.post and not e.mine) then return end
  if e.can then
    OpenWhisper(e.post.from, nil, nil, R.OfferText(e.post.item))
  else
    R.OpenTell(e.post.from)
  end
end

function R.WhisperChat(e)
  if not (e and e.chat) then return end
  local s = e.seen
  local item = s.itemID or (e.rec and e.rec.o)
  local text = item and R.OfferText(item) or L["[CraftBoard] I can craft that for you."]
  OpenWhisper(s.from, nil, nil, text)
end

function R.WhisperQueue(e)
  if e and e.queue and e.queue.who then R.OpenTell(e.queue.who) end
end

-- The craft a request would queue on the current character: recipeID, item, qty, who, mats.
function R.QueueTarget(e)
  if not e then return nil end
  if e.post and not e.mine and e.know and e.know.current then
    return e.know.recipeID, e.post.item, e.post.qty or 1, e.post.from, false
  end
  if e.chat and not e.seen.links and e.seen.recipeID and e.seen.current then
    return e.useRecipeID or e.seen.recipeID, e.rec and e.rec.o or nil, e.seen.qty or 1, e.seen.from, e.seen.mats
  end
  return nil
end

function R.CanQueue(e)
  return R.QueueTarget(e) ~= nil and NS.Queue ~= nil and not NS.Queue.Has(e.id) and not NS.Queue.IsFull()
end

function R.AddToQueue(e)
  local recipeID, item, qty, who, mats = R.QueueTarget(e)
  if not (recipeID and NS.Queue) then return end
  local x, why = NS.Queue.Add({ recipeID = recipeID, item = item, qty = qty, who = who, src = e.id, mats = mats })
  if x then
    NS.Print(format(L["Queued: %s for %s"], e.name, Short(who)))
  elseif why == "full" then
    NS.Print(L["Your queue is full. Finish or remove a craft first."])
  end
end

function R.HideChat(e)
  if not (e and e.chat and NS.ChatWatch and NS.ChatWatch.Hide) then return end
  NS.ChatWatch.Hide(e.seen.from)
  if reqs.selected == e.id then reqs.selected = nil end
  UI.RefreshRequests(true, true)
end

function R.Retract(e)
  if not (e and e.mine and NS.Comm and NS.Comm.Retract) then return end
  NS.Comm.Retract(e.id)
  UI.Refresh()
end

function R.Done(e)
  if not (e and e.queue and NS.Queue) then return end
  NS.Queue.Remove(e.queue.id)
end

-- Craft (a queued craft) or Craft next (the queue): when the only problem is a closed profession
-- window, the button opens it instead.
function R.CraftState(e)
  if not (e and NS.Craft) then return false, nil, nil end
  if e.queueTotal then
    local x, n, openProf = NS.Craft.NextQueued()
    if x then
      local name = (x.item and ItemName(x.item)) or format(L["Recipe %d"], x.recipeID)
      return true, format(L["Next: %dx %s"], n, name) .. (x.who and (" " .. format(L["for %s"], Short(x.who))) or ""), nil
    end
    if openProf then return false, nil, openProf end
    return false, L["Nothing in your queue can be crafted right now."], nil
  end
  if not (e.queue and e.rec) or e.rec.e then return false, nil, nil end
  if NS.Queue.CraftsLeft(e.queue, e.rec) == 0 then
    return false, e.queue.who and format(L["Made: hand it to %s in a trade."], Short(e.queue.who)) or L["All made."], nil
  end
  local ok, why, _, openProf = NS.Craft.CanCraft(e.queue.recipeID)
  return ok, why, openProf
end

function R.Craft(e)
  if not (e and NS.Craft) then return end
  local ok, _, openProf = R.CraftState(e)
  if not ok and openProf then
    if not NS.Craft.Open(openProf) then NS.Print(format(L["Open your %s window to craft."], NS.ProfessionName(openProf) or "")) end
    return
  end
  if e.queueTotal then
    NS.Craft.Next()
  elseif e.queue then
    NS.Craft.Do(e.queue.recipeID, NS.Queue.CraftsLeft(e.queue, e.rec))
  end
end

-- Post the linked orders for the missing intermediates of a request I can craft (reqs.linkNeeds),
-- each tied to that request, when there are enough free request slots for all of them.
function R.PostLinked(e)
  if not (e and e.post and NS.Comm and NS.Comm.PostRequest) then return end
  local needs = reqs.linkNeeds or {}
  for _, n in ipairs(needs) do
    if n.qty > 1000 then
      NS.Print(format(L["%s would need %d; one request can ask for 1000 at most. Post fewer."], ItemName(n.itemID), n.qty))
      return
    end
  end
  local slots = NS.Comm.OpenSlots and NS.Comm.OpenSlots()
  if slots and slots < #needs then
    NS.Print(format(L["That takes %d open requests and you have room for %d. Retract one first."], #needs, slots))
    return
  end
  for _, n in ipairs(needs) do
    if NS.Comm.PostRequest(n.itemID, n.qty, "", e.post.id) then
      NS.Print(format(L["Posted linked order: %dx %s"], n.qty, ItemName(n.itemID)))
    end
  end
  UI.Refresh()
end

-- { {text=, fn=, safe=}, ... } for a row's menu, main action first. safe: fine for the gamepad's
-- A button (never retracts, removes or hides anything).
function R.Actions(e)
  local out = {}
  local function add(text, fn, safe) out[#out + 1] = { text = text, fn = function() fn(e) end, safe = safe } end
  if not e or e.kind or e.placeholder then return out end
  if e.chat then
    add(format(L["Whisper %s"], Short(e.seen.from)), R.WhisperChat, true)
    if R.CanQueue(e) then add(L["Queue"], R.AddToQueue, true) end
    add(L["Hide"], R.HideChat)
  elseif e.queueTotal then
    add(L["Craft next"], R.Craft, true)
  elseif e.queue then
    if e.rec and not e.rec.e then add(L["Craft"], R.Craft, true) end
    if e.queue.who then add(format(L["Whisper %s"], Short(e.queue.who)), R.WhisperQueue, true) end
    add(L["Done"], R.Done)
  elseif e.mine then
    -- An alt's request can only be retracted on that alt (its author sends the retraction).
    if not e.altPost then add(L["Retract"], R.Retract) end
  elseif e.post then
    local ago = R.OfferedAgo(e)
    if e.can and e.online and not (ago and ago < OFFER_GAP) then add(L["Offer"], R.Offer, true) end
    add(format(L["Whisper %s"], Short(e.post.from)), R.WhisperPost, true)
    if R.CanQueue(e) then add(L["Queue"], R.AddToQueue, true) end
  end
  return out
end

function R.ShowMenu(owner, e)
  local actions = R.Actions(e)
  if #actions == 0 then return end
  -- Without the menu API the right-click does nothing (the card's buttons do the same things).
  if MenuUtil and MenuUtil.CreateContextMenu then
    reqs.menuOpen = true
    pcall(MenuUtil.CreateContextMenu, owner, function(_, root)
      if root.CreateTitle then root:CreateTitle(e.name) end
      for _, a in ipairs(actions) do root:CreateButton(a.text, a.fn) end
    end)
  end
end

-- Rows --------------------------------------------------------------------------

-- Find's grouped row plus the ready check in the 21 px before the label, a 14 px item icon (its
-- slot always kept, so names line up), a right-click menu and a tooltip per kind.
function R.RowFactory()
  local base = GroupRowFactory(function(it) if it.id then UI.SelectRequest(it.id) end end, R.ToggleGroup)
  return function(parent)
    local row = base(parent)
    row:SetScript("OnEnter", function(self)
      local it = self.item
      if not it or it.kind or it.placeholder then return end
      if it.chat then
        TextTooltip(self, Short(it.seen.from), it.seen.text)
        if GameTooltip and it.knownOn then
          GameTooltip:AddLine(format(L["Known by %s."], Short(it.knownOn)), MUTED[1], MUTED[2], MUTED[3])
        end
      elseif it.queueTotal then
        TextTooltip(self, L["All reagents"], L["What the whole queue still needs, against your bags and bank."])
      else
        ShowTooltip(self, it.outputItemID, it.recipeID)
        local who = it.post and not it.mine and it.post.from or (it.queue and it.queue.who)
        if who and GameTooltip and GameTooltip:IsShown() then
          GameTooltip:AddLine(format(it.queue and L["for %s"] or L["Requested by %s"], Short(who)), MUTED[1], MUTED[2], MUTED[3])
        end
      end
      if GameTooltip and GameTooltip:IsShown() and MenuUtil and MenuUtil.CreateContextMenu and #R.Actions(it) > 0 then
        GameTooltip:AddLine(L["Right-click for actions"], MUTED[1], MUTED[2], MUTED[3])
        GameTooltip:Show()
      end
    end)
    if row.RegisterForClicks then row:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
    local click = row:GetScript("OnClick")
    row:SetScript("OnClick", function(self, button)
      local it = self.item
      if button == "RightButton" then
        if it and not it.kind and not it.placeholder then
          if it.id then UI.SelectRequest(it.id) end
          R.ShowMenu(self, it)
        end
        return
      end
      click(self, button)
    end)
    local check = row:CreateTexture(nil, "OVERLAY")
    check:SetSize(12, 12)
    check:SetTexture(TEX.ready)
    check:SetPoint("CENTER", row, "TOPLEFT", floor(ROW.labelX / 2), -ROW.recipeBar / 2)
    check:Hide()
    row.check = check
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(14, 14)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon:SetPoint("LEFT", row, "TOPLEFT", ROW.labelX, -ROW.recipeBar / 2)
    row.icon = icon
    row.recipeParts[#row.recipeParts + 1] = check
    row.recipeParts[#row.recipeParts + 1] = icon
    return row
  end
end

function R.FillEntry(row, e)
  row.name:ClearAllPoints()
  row.name:SetPoint("LEFT", row, "TOPLEFT", ROW.labelX + (e.placeholder and 0 or 18), -ROW.recipeBar / 2)
  row.name:SetPoint("RIGHT", row.status, "LEFT", -6, 0)
  if e.placeholder then
    row.icon:Hide()
    row.name:SetText(e.name)
    row.name:SetTextColor(MUTED[1], MUTED[2], MUTED[3])
    row.status:SetText("")
    row.check:Hide()
    row.sel:Hide()
    row.name:SetAlpha(1)
    return
  end
  row.icon:SetTexture(e.icon or TEX.question)
  row.icon:Show()
  row.name:SetText(e.label)
  if e.outputItemID then
    row.name:SetTextColor(NameRGB(e.outputItemID))
  elseif e.queueTotal then
    row.name:SetTextColor(GOLD_RGB[1], GOLD_RGB[2], GOLD_RGB[3])
  else
    row.name:SetTextColor(C.label[1], C.label[2], C.label[3])
  end
  row.status:SetText(e.status or "")
  local alpha = e.dim and 0.55 or 1
  row.name:SetAlpha(alpha)
  row.icon:SetAlpha(alpha)
  local alt = e.readyAlt and not e.ready
  row.check:SetShown(e.ready or alt)
  if row.check.SetDesaturated then row.check:SetDesaturated(alt) end
  row.check:SetAlpha(alt and 0.6 or 1)
  row.sel:SetShown(e.id ~= nil and e.id == reqs.selected)
end

-- Card ----------------------------------------------------------------------------

-- Stack the card's variable parts under the header: info lines, the missing line, the linked
-- orders button, then the reagents label (the slots and the quantity line hang off it).
function R.Stack()
  local prev
  for _, f in ipairs({ reqs.info, reqs.missing, reqs.linkBtn, reqs.reagLabel }) do
    if f:IsShown() then
      f:ClearAllPoints()
      if prev then
        f:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, f == reqs.reagLabel and -8 or -6)
      else
        AnchorBelowHeader(reqs.header, f)
      end
      if f ~= reqs.linkBtn and f ~= reqs.reagLabel then f:SetPoint("RIGHT", reqs.body, "RIGHT", -20, 0) end
      prev = f
    end
  end
end

-- Reagent slots shown without scrolling: what fits between the reagents label and the bottom of
-- the card, leaving room for the quantity line. Falls back to an estimate before the first layout.
function R.ReagentRows(n)
  local top, bottom = reqs.reagLabel:GetTop(), reqs.body:GetBottom()
  local fit
  if type(top) == "number" and type(bottom) == "number" and top > bottom then
    fit = floor((top - bottom - 20 - 44) / REAGENT_H)
  else
    local h = reqs.body:GetHeight() or 0
    fit = h > 0 and floor((h - 150 - (reqs.info:IsShown() and reqs.info:GetHeight() or 0) - 40) / REAGENT_H) or 4
  end
  return min(max(1, n), max(1, fit))
end

-- Info lines (one per string, nil skipped) in the description font. When the header's title
-- wrapped and hid its "who · when" line, that line leads the info instead.
function R.SetInfo(lines)
  local text = {}
  local sub = reqs.header.sub
  if not sub:IsShown() and (sub:GetText() or "") ~= "" then text[1] = GOLD_HEX .. sub:GetText() .. "|r" end
  for i = 1, #lines do
    if lines[i] then text[#text + 1] = lines[i] end
  end
  reqs.info:SetText(table.concat(text, "\n"))
  reqs.info:SetShown(#text > 0)
  if #text > 0 then
    local h = reqs.info.GetStringHeight and reqs.info:GetStringHeight()
    reqs.info:SetHeight(max(12, type(h) == "number" and h or 12 * #text))
  end
end

function R.SetReagents(reagents, emptyText, show)
  reqs.reagLabel:SetShown(show)
  reqs.reagents.box:SetShown(show)
  R.Stack()
  reqs.reagents.box:SetHeight(#reagents > 0 and REAGENT_H * R.ReagentRows(#reagents) or SUBROW_H)
  reqs.reagents:SetItems(reagents, emptyText, true)
end

-- The Create row for entry e. The main action is red, where Blizzard's Create sits; the
-- secondary ones line up left of it: whisper square, then panel buttons, then Hide.
function R.Buttons(e)
  local mine, chat = e and e.mine, e and e.chat
  local post = e and e.post and not e.mine
  local queueEntry, queueTotal = e and e.queue, e and e.queueTotal
  for _, b in ipairs({ reqs.offer, reqs.retract, reqs.chatWhisper, reqs.craft, reqs.whisper, reqs.queueBtn,
    reqs.done, reqs.chatHide }) do b:Hide() end
  if not e then return end

  -- Red: Offer / Whisper (a request I can't craft opens the chat box) / Retract / Craft.
  local red
  if mine then
    red = reqs.retract
    red:SetEnabled(not e.altPost)
    reqs.retractWhy = e.altPost and format(L["Posted by %s: log in on %s to retract it."], Short(e.post.from), Short(e.post.from)) or nil
  elseif post then
    local ago = R.OfferedAgo(e)
    if e.can and e.online then
      red = reqs.offer
      local offered = ago and ago < OFFER_GAP
      red:SetText(offered and L["Offered"] or L["Offer"])
      red:SetEnabled(not offered)
    else
      red = reqs.chatWhisper
      red:SetEnabled(e.online)
    end
    reqs.offlineWhy = not e.online and format(L["%s is offline. You'll get a chat line when they're back."], Short(e.post.from)) or nil
  elseif chat then
    red = reqs.chatWhisper
    red:SetEnabled(true)
  elseif queueEntry or queueTotal then
    red = reqs.craft
    local ok, why, openProf = R.CraftState(e)
    reqs.craftWhy = why
    if not ok and openProf then
      red:SetText(format(L["Open %s"], NS.ProfessionName(openProf) or L["Profession"]))
      red:SetEnabled(true)
    else
      red:SetText(queueTotal and L["Craft next"] or (NS.Craft and NS.Craft.IsCrafting() and L["Crafting..."] or L["Craft"]))
      red:SetEnabled(ok and true or false)
    end
    if queueEntry and (not e.rec or e.rec.e) then red = nil end   -- enchants: no Craft here
  end
  if red then
    FitButton(red, 112)
    red:Show()
  end

  -- Left of it, right to left.
  local anchor = red
  local function place(b, gap)
    b:ClearAllPoints()
    if anchor then
      b:SetPoint("RIGHT", anchor, "LEFT", gap or -6, 0)
    else
      b:SetPoint("BOTTOMRIGHT", reqs.bar, "BOTTOMRIGHT", -9, 10)
    end
    b:Show()
    anchor = b
  end
  if post and e.can and e.online then
    place(reqs.whisper, reqs.whisper.cbSquare and -6 or -4)
    reqs.whisper:SetEnabled(true)
  elseif queueEntry and e.queue.who then
    place(reqs.whisper, reqs.whisper.cbSquare and -6 or -4)
    reqs.whisper:SetEnabled(true)
  end
  if queueEntry then
    place(reqs.done)
    FitButton(reqs.done, 70)
  end
  local target = R.QueueTarget(e)
  if (post or chat) and (target or (NS.Queue and NS.Queue.Has(e.id))) then
    local queued = NS.Queue and NS.Queue.Has(e.id)
    reqs.queueBtn:SetText(queued and L["Queued"] or L["Queue"])
    reqs.queueBtn:SetEnabled(not queued and not (NS.Queue and NS.Queue.IsFull()))
    FitButton(reqs.queueBtn, 70)
    place(reqs.queueBtn)
  end
  if chat then place(reqs.chatHide) end
end

-- "You know this recipe" / "Known by Alt" / grey "not known".
function R.KnowLine(current, knownOn)
  if current then return GREEN .. L["You know this recipe."] .. "|r" end
  if knownOn then return format(L["Known by %s."], Short(knownOn)) end
  return GREY .. L["None of your characters knows this recipe."] .. "|r"
end

function R.PostDetail(e)
  local post, know = e.post, e.know
  local mine = e.mine
  local sub = (mine and not e.altPost) and L["Requested by you"] or format(L["Requested by %s"], Short(post.from))
  if not mine and not e.online then sub = sub .. DOT .. L["offline"] end
  local children, parent = {}, nil
  if NS.Comm and NS.Comm.Linked then children, parent = NS.Comm.Linked(post.id) end
  -- A linked order's note only repeats what the card says about its request.
  local note = not parent and type(post.note) == "string" and post.note ~= "" and ("\"" .. post.note .. "\"") or nil
  FillHeader(reqs.header, know and know.recipeID, post.item, e.name, sub .. DOT .. R.AgoText(post.t), note)
  SetDetailBackground(reqs, know and know.prof)

  local qty = post.qty or 1
  local rec = know and know.rec
  local current = rec and know.current
  local reagents, missing = {}, nil
  if rec and type(rec.r) == "table" and #rec.r > 0 and NS.Inventory and NS.Inventory.CanCraft then
    local cc = NS.Inventory.CanCraft(rec, qty)
    reagents, missing = Chain.AnnotateMakers(cc.reagents or {}), cc.missing
  end

  local lines = {}
  if not mine then
    lines[#lines + 1] = R.KnowLine(current, rec and not current and know.char or nil)
    if rec and not current and know.char then lines[#lines + 1] = format(L["Craft it on %s."], Short(know.char)) end
  end
  if parent then
    lines[#lines + 1] = format(L["Linked order for %s (%s)."], ItemName(parent.item), Short(parent.from))
  end
  local linked = {}
  for _, c in ipairs(children) do
    linked[c.item] = true
    lines[#lines + 1] = format(L["Linked: %dx %s (%s)"], c.qty or 1, ItemName(c.item), Short(c.from))
  end
  local ago = R.OfferedAgo(e)
  if ago then lines[#lines + 1] = format(L["You offered %s."], R.AgoText(time() - ago)) end
  lines[#lines + 1] = not mine and NS.Trade and NS.Trade.CraftedText(post.from) or nil
  R.SetInfo(lines)

  -- Intermediates other players make, not yet posted as linked orders. Only for the current
  -- character's own recipe: an alt's shortages aren't in these bags (and its Missing line isn't
  -- shown either).
  local needs = {}
  for _, n in ipairs(current and Chain.LinkedNeeds(missing) or {}) do
    if not linked[n.itemID] then needs[#needs + 1] = n end
  end
  reqs.linkNeeds = needs
  reqs.linkBtn:SetShown(#needs > 0)
  FitButton(reqs.linkBtn, 150)
  FillMissingLine(reqs.missing, current and missing or nil)
  R.SetReagents(reagents, L["No reagents recorded."], rec ~= nil)
  reqs.qtyLine:SetText(qty > 1 and format(L["Requested quantity: %d"], qty) or "")
end

-- Card for a "Seen in chat" entry: item (else profession) as title, "Bob (Trade) · 3m ago", the
-- chat line quoted when it says more than the title, what I know about it, whether they bring the
-- reagents, what I'm missing, how often they asked. Lines linking several items list them and
-- say how many I know; reagents and Queue are left out for those.
function R.ChatDetail(e)
  local s, rec = e.seen, e.rec
  local itemID = s.itemID or (rec and type(rec.o) == "number" and rec.o) or nil
  local profName = e.profName
  local title, desc
  local lines = {}
  if s.links then
    title = profName or L["Crafting request"]
    local shown, n, known = {}, #s.links, 0
    for i = 1, n do
      if NS.ChatWatch.Resolve and NS.ChatWatch.Resolve(s.links[i]) then known = known + 1 end
      if i <= 6 then shown[i] = "\194\183 " .. s.links[i] end
    end
    if n > 6 then shown[#shown + 1] = format(L["and %d more"], n - 6) end
    desc = table.concat(shown, "\n")
    itemID = nil
    lines[1] = known > 0 and (GREEN .. format(L["You know %d of these %d."], known, n) .. "|r")
      or (GREY .. L["None of your characters knows these recipes."] .. "|r")
  else
    title = s.itemName or profName or L["Crafting request"]
    if NS.ChatWatch.AddsDetail and NS.ChatWatch.AddsDetail(s) then desc = "\"" .. (s.text or "") .. "\"" end
    if s.recipeID or s.itemName then
      lines[1] = R.KnowLine(s.recipeID and s.current, s.knownOn)
      if s.knownOn then lines[2] = format(L["Craft it on %s."], Short(s.knownOn)) end
    elseif profName then
      -- Asked by profession only: whether I have it, not whether I know a recipe.
      lines[1] = NS.ChatWatch.CanHelp(s) and (GREEN .. format(L["You have %s."], profName) .. "|r")
        or (GREY .. format(L["You don't have %s."], profName) .. "|r")
    end
  end
  FillHeader(reqs.header, not s.links and s.recipeID or nil, itemID, title,
    format(L["%s (%s)"], Short(s.from), s.channel or "") .. DOT .. R.AgoText(s.t), desc)
  if (s.links or not (s.recipeID or itemID)) and ProfIcon(s.profID) then reqs.header.icon:SetTexture(ProfIcon(s.profID)) end
  SetDetailBackground(reqs, rec and rec.p or s.profID)

  local cc = not s.links and rec and type(rec.r) == "table" and #rec.r > 0 and NS.Inventory
    and NS.Inventory.CanCraft(rec, s.qty or 1) or nil
  if s.mats then
    lines[#lines + 1] = GREEN .. L["They bring the reagents."] .. "|r"
  elseif cc and cc.ready and s.current and NS.Inventory.CanCraft(rec, s.qty or 1, true).ready then
    lines[#lines + 1] = GREEN .. L["You have the reagents."] .. "|r"
  end
  if (s.asks or 1) > 1 then
    lines[#lines + 1] = format(L["Asked %d times, first %s."], s.asks, R.AgoText(s.first or s.t))
  end
  lines[#lines + 1] = NS.Trade and NS.Trade.CraftedText(s.from) or nil
  R.SetInfo(lines)
  reqs.linkNeeds = nil
  reqs.linkBtn:Hide()
  -- With their own reagents, or on an alt, what this character is short of doesn't matter.
  FillMissingLine(reqs.missing, not s.mats and s.current and cc and cc.missing or nil)
  R.SetReagents(cc and Chain.AnnotateMakers(cc.reagents) or {}, nil, cc ~= nil)
  reqs.qtyLine:SetText((s.qty or 1) > 1 and format(L["Requested quantity: %d"], s.qty) or "")
end

-- A queued craft: for whom, progress, reagents for what is still to make; or the queue's sum.
function R.QueueDetail(e)
  reqs.linkNeeds = nil
  reqs.linkBtn:Hide()
  reqs.qtyLine:SetText("")
  if e.queueTotal then
    FillHeader(reqs.header, nil, nil, L["My queue"], e.status)
    reqs.header.icon:SetTexture(QUEUE_ICON)
    SetDetailBackground(reqs, nil)
    local lines = {}
    for i, q in ipairs(e.list) do
      if i > 6 then
        lines[#lines + 1] = format(L["and %d more"], #e.list - 6)
        break
      end
      lines[i] = "\194\183 " .. q.label .. (q.queue.who and (DOT .. Short(q.queue.who)) or "")
    end
    local _, next = R.CraftState(e)
    if next then lines[#lines + 1] = next end
    R.SetInfo(lines)
    local totals = NS.Queue and NS.Queue.Totals() or {}
    local missing = {}
    for _, r in ipairs(totals) do
      if r.have < r.need then missing[#missing + 1] = r end
    end
    FillMissingLine(reqs.missing, missing)
    R.SetReagents(Chain.AnnotateMakers(totals), L["Nothing left to make."], true)
    return
  end
  local x, rec = e.queue, e.rec
  local sub = x.who and format(L["for %s"], Short(x.who)) or L["Planned"]
  FillHeader(reqs.header, x.recipeID, x.item, e.name, sub .. DOT .. format(L["queued %s"], R.AgoText(x.t)))
  SetDetailBackground(reqs, rec and rec.p)
  local made, total = 0, 0
  if rec then made, total = NS.Queue.Progress(x, rec) end
  local left = rec and NS.Queue.CraftsLeft(x, rec) or 0
  local lines = {}
  if rec and rec.e then
    lines[1] = x.who and format(L["Open a trade with %s and put their item in \"Will not be traded\": CraftBoard shows an enchant button there."], Short(x.who))
      or L["Enchant from the Enchanting window: Create asks for the item."]
  elseif left == 0 then
    lines[1] = GREEN .. (x.who and format(L["Made: hand it to %s in a trade."], Short(x.who)) or L["All made."]) .. "|r"
  elseif made > 0 then
    lines[1] = format(L["Made %d of %d."], made, total)
  end
  if x.mats then lines[#lines + 1] = L["They bring the reagents."] end
  lines[#lines + 1] = x.who and NS.Trade and NS.Trade.CraftedText(x.who) or nil
  R.SetInfo(lines)
  local cc = rec and left > 0 and NS.Inventory.CanCraft(rec, left * max(1, rec.y or 1)) or nil
  FillMissingLine(reqs.missing, cc and not x.mats and cc.missing or nil)
  R.SetReagents(cc and Chain.AnnotateMakers(cc.reagents) or {}, L["Nothing left to make."], true)
  reqs.qtyLine:SetText(x.qty > 1 and format(L["Quantity: %d"], x.qty) or "")
end

function R.Detail(e)
  reqs.entry = e
  R.Buttons(e)
  if not e then
    reqs.body:Hide()
    reqs.none:SetText(reqs.noneText or "")
    reqs.none:Show()
    SetDetailBackground(reqs, nil)
    return
  end
  reqs.none:Hide()
  reqs.body:Show()
  if e.chat then
    R.ChatDetail(e)
  elseif e.queue or e.queueTotal then
    R.QueueDetail(e)
  else
    R.PostDetail(e)
  end
end

-- Build ---------------------------------------------------------------------------

function BuildRequests(p)
  reqs.keyOf = function(e) return e.id end
  reqs.selectedKey = function() return reqs.selected end
  reqs.selectKey = function(id) UI.SelectRequest(id) end
  reqs.refilter = function(keep) UI.FilterRequests(keep) end

  local left = ListColumn(p, reqs)
  AddFilter(reqs, left, function()
    return { { kind = "check", text = L["Only what I can craft"],
      tip = L["Hides requests none of your characters can craft."],
      get = R.OnlyCan,
      set = function()
        local db = UIDB()
        if db then db.reqOnlyCan = not R.OnlyCan() or nil end
        UI.FilterRequests(false)
      end } }
  end, function() return not R.OnlyCan() end, function()
    local db = UIDB()
    if db then db.reqOnlyCan = nil end
    UI.FilterRequests(false)
  end)
  reqs.search = NewSearchBox("CraftBoardRequestsSearchBox", left, reqs)
  reqs.search:SetPoint("TOPLEFT", left, "TOPLEFT", 13, -8)
  reqs.search:SetPoint("RIGHT", reqs.filter, "LEFT", -4, 0)
  GroupList(reqs, left, "CraftBoardRequestsScroll", R.RowFactory(), GroupFill(R.FillEntry))
  -- Nothing on the list: the list's empty text and a grey line under it.
  local sub = Label(reqs.list.box, nil, Font("GameFontDisableSmall", "GameFontDisable"))
  sub:SetPoint("TOP", reqs.list.empty, "BOTTOM", 0, -6)
  sub:SetWidth(220)
  sub:SetJustifyH("CENTER")
  if sub.SetWordWrap then sub:SetWordWrap(true) end
  if sub.SetMaxLines then sub:SetMaxLines(4) end
  sub:Hide()
  reqs.emptySub = sub

  local d = CardForm(p, reqs, left)
  reqs.none = Placeholder(d, "")
  local body = CreateFrame("Frame", nil, d)
  body:SetAllPoints()
  reqs.body = body
  reqs.header = NewHeader(body)
  reqs.header.desc:SetTextColor(C.short[1], C.short[2], C.short[3])

  reqs.info = Label(body, nil, FontOf(FONTS.desc))
  if reqs.info.SetWordWrap then reqs.info:SetWordWrap(true) end
  if reqs.info.SetMaxLines then reqs.info:SetMaxLines(9) end
  if reqs.info.SetJustifyV then reqs.info:SetJustifyV("TOP") end
  reqs.missing = NewMissingLine(body)
  reqs.linkBtn = PanelButton(body, L["Post linked orders"], 150, 22)
  reqs.linkBtn:SetScript("OnClick", function() R.PostLinked(reqs.entry) end)
  reqs.linkBtn:SetScript("OnEnter", function(self)
    TextTooltip(self, L["Post linked orders"],
      format(L["Posts requests for %s, which other players make, linked to this request. Retracting it retracts them too."],
        Chain.NeedsText(reqs.linkNeeds or {})))
  end)
  reqs.linkBtn:SetScript("OnLeave", HideTooltip)
  reqs.linkBtn:Hide()

  reqs.reagLabel = SectionLabel(body, L["Reagents:"])
  reqs.reagents = NewList("CraftBoardRequestReagentsScroll", body, REAGENT_H, ReagentRow, FillReagentRow,
    { inline = true, stripes = false })
  reqs.reagents.box:SetPoint("TOPLEFT", reqs.reagLabel, "TOPLEFT", 1, -20)
  reqs.reagents.box:SetPoint("RIGHT", body, "RIGHT", -20, 0)
  reqs.reagents.box:SetHeight(REAGENT_H)
  reqs.qtyLine = SectionLabel(body, nil)
  reqs.qtyLine:SetWidth(300)
  reqs.qtyLine:SetPoint("TOPLEFT", reqs.reagents.box, "BOTTOMLEFT", -1, -12)

  -- Create row: one red button where Create is, secondary buttons to its left (R.Buttons).
  local bar = NewBar(p, d)
  reqs.bar = bar
  local function red(text, fn, tip)
    local b = RedButton(bar, text, 112, 28)
    b:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -9, 7)
    b:SetScript("OnClick", function() fn(reqs.entry) end)
    b:SetScript("OnEnter", function(self)
      local title, body = tip(reqs.entry, self)
      if title then TextTooltip(self, title, body) end
    end)
    b:SetScript("OnLeave", HideTooltip)
    b:Hide()
    return b
  end
  reqs.offer = red(L["Offer"], R.Offer, function(e, self)
    if not (e and e.post) then return end
    if not self:IsEnabled() then
      return L["Offered"], L["You offered on this request a few minutes ago."]
    end
    return format(L["Offer to %s"], Short(e.post.from)), format(L["Sends this whisper now: %s"], R.OfferText(e.post.item))
  end)
  reqs.retract = red(L["Retract"], R.Retract, function(_, self)
    if not self:IsEnabled() then return L["Retract"], reqs.retractWhy end
    return L["Retract"], L["Takes the request off the board for everyone, with its linked orders."]
  end)
  reqs.chatWhisper = red(L["Whisper"], function(e)
    if e and e.chat then R.WhisperChat(e) else R.WhisperPost(e) end
  end, function(e, self)
    if not e then return end
    if not self:IsEnabled() then return format(L["Whisper %s"], Short(e.post and e.post.from or "")), reqs.offlineWhy end
    if e.chat then
      local item = e.seen.itemID or (e.rec and e.rec.o)
      return format(L["Whisper %s"], Short(e.seen.from)),
        format(L["Opens the chat box with: %s"], item and R.OfferText(item) or L["[CraftBoard] I can craft that for you."])
    end
    return format(L["Whisper %s"], Short(e.post.from)), L["Opens the chat box."]
  end)
  reqs.craft = red(L["Craft"], R.Craft, function(e, self)
    if not e then return end
    local ok, why, openProf = R.CraftState(e)
    if not ok and openProf then
      return self:GetText(), L["Opens the profession window. Click again to craft."]
    end
    if ok and e.queueTotal then
      return L["Craft next"], (why and (why .. "\n") or "") .. L["Crafts the next queued craft you have reagents for. Click again for the one after."]
    elseif ok then
      return L["Craft"], L["Crafts the rest of this queued craft, as many as your reagents allow. Moving cancels the rest."]
    end
    return self:GetText(), reqs.craftWhy
  end)

  reqs.done = PanelButton(bar, L["Done"], 70, 22)
  reqs.done:SetScript("OnClick", function() R.Done(reqs.entry) end)
  reqs.done:SetScript("OnEnter", function(self)
    TextTooltip(self, L["Done"], L["Takes the craft off your queue. A trade that hands it over does this by itself."])
  end)
  reqs.done:SetScript("OnLeave", HideTooltip)
  reqs.done:Hide()

  reqs.whisper = SquareButton(bar, L["Whisper"])
  reqs.whisper.cbKind = "whisper"
  reqs.whisper:SetScript("OnClick", function()
    local e = reqs.entry
    if e and e.queue then R.WhisperQueue(e) else R.WhisperPost(e) end
  end)
  reqs.whisper:SetScript("OnEnter", function(self)
    local e = reqs.entry
    local who = e and (e.queue and e.queue.who or (e.post and not e.mine and e.post.from))
    if who then TextTooltip(self, format(L["Whisper %s"], Short(who)), L["Opens the chat box."]) end
  end)
  reqs.whisper:SetScript("OnLeave", HideTooltip)

  reqs.queueBtn = PanelButton(bar, L["Queue"], 70, 22)
  reqs.queueBtn:SetScript("OnClick", function() R.AddToQueue(reqs.entry) end)
  reqs.queueBtn:SetScript("OnEnter", function(self)
    local e = reqs.entry
    if NS.Queue and e and NS.Queue.Has(e.id) then
      TextTooltip(self, L["Queued"], L["This request is in your queue."])
    elseif NS.Queue and NS.Queue.IsFull() then
      TextTooltip(self, L["Queue"], L["Your queue is full. Finish or remove a craft first."])
    else
      TextTooltip(self, L["Queue"], L["Adds the craft to your queue, where the reagents of everything queued are summed up."])
    end
  end)
  reqs.queueBtn:SetScript("OnLeave", HideTooltip)
  reqs.queueBtn:Hide()

  reqs.chatHide = CreateFrame("Button", nil, bar)
  reqs.chatHide:SetNormalFontObject(Font("GameFontNormal"))
  reqs.chatHide:SetHighlightFontObject(Font("GameFontHighlight"))
  reqs.chatHide:SetText(L["Hide"])
  reqs.chatHide.fs = reqs.chatHide:GetFontString()
  reqs.chatHide:SetSize(max(40, (reqs.chatHide.fs and StringWidth(reqs.chatHide.fs) or 24) + 16), 28)
  reqs.chatHide:SetScript("OnClick", function() R.HideChat(reqs.entry) end)
  reqs.chatHide:SetScript("OnEnter", function(self)
    local e = reqs.entry
    TextTooltip(self, L["Hide"], e and e.chat and format(L["Hides this ask. It comes back if %s asks for something else."], Short(e.seen.from)))
  end)
  reqs.chatHide:SetScript("OnLeave", HideTooltip)
  reqs.chatHide:Hide()
end

function UI.RefreshRequestDetail()
  if not reqs.body then return end
  R.Detail(reqs.selected and reqs.byID and reqs.byID[reqs.selected] or nil)
end

function UI.SelectRequest(id)
  reqs.selected = id
  if reqs.list then reqs.list:Render() end
  UI.RefreshRequestDetail()
end

-- The Requests tab's main action for the selected entry (gamepad A): the first safe one, never
-- Retract / Done / Hide.
function UI.RequestPrimary()
  for _, a in ipairs(R.Actions(reqs.entry)) do
    if a.safe then a.fn() return end
  end
end

-- Only the Craft / Craft next button, when bags, casts or the profession window change.
function UI.RefreshRequestButtons()
  if reqs.body and reqs.entry and (reqs.entry.queue or reqs.entry.queueTotal) then R.Buttons(reqs.entry) end
end

-- Group and filter ---------------------------------------------------------------

local function NewestFirst(a, b)
  if (a.t or 0) ~= (b.t or 0) then return (a.t or 0) > (b.t or 0) end
  return tostring(a.id) < tostring(b.id)
end

-- Online authors first, then ready ones, then newest.
local function CanOrder(a, b)
  local ao, bo = a.online ~= false, b.online ~= false
  if ao ~= bo then return ao end
  if (a.ready or false) ~= (b.ready or false) then return a.ready end
  return NewestFirst(a, b)
end

local function OnlineNewest(a, b)
  local ao, bo = a.online ~= false, b.online ~= false
  if ao ~= bo then return ao end
  return NewestFirst(a, b)
end

-- Filter the annotated entries by text (item, requester, chat line) and group them. A selection
-- the filter hides is replaced by the first visible entry.
function UI.FilterRequests(keepScroll)
  if not reqs.list then return end
  local all = reqs.all or {}
  local text = strtrim(reqs.search:GetText() or "")
  local searching = #text >= 2
  reqs.searching = searching
  local onlyCan = R.OnlyCan()
  local results = {}
  local tokens = searching and Tokens(text) or {}
  for _, e in ipairs(all) do
    local ok = true
    for i = 1, #tokens do
      local t = tokens[i]
      if not (e.lname:find(t, 1, true) or e.lfrom:find(t, 1, true)) then ok = false break end
    end
    if ok then results[#results + 1] = e end
  end

  local groups = {
    { key = "can", name = L["Requests you can craft"], list = {}, sort = CanOrder },
    { key = "queue", name = L["My queue"], list = {} },
    { key = "open", name = L["Open requests"], list = {}, sort = OnlineNewest, hide = onlyCan },
    { key = "chat", name = L["Seen in chat"], list = {}, sort = NewestFirst, hide = onlyCan },
    { key = "mine", name = L["My requests"], list = {}, sort = NewestFirst },
  }
  local anyChat = false
  for _, e in ipairs(results) do
    local g
    if e.queue or e.queueTotal then g = groups[2]
    elseif e.mine then g = groups[5]
    elseif e.can then g = groups[1]
    elseif e.chat then g = groups[4]
    else g = groups[3] end
    if e.chat then anyChat = true end
    g.list[#g.list + 1] = e
  end
  -- "Seen in chat" shows while empty (with a hint) only when nothing at all came from chat.
  groups[4].always = reqs.chatOn and not searching and not anyChat and not onlyCan
  -- A selection in a group the filter hides (not merely collapsed) is let go.
  local visible = false
  for _, g in ipairs(groups) do
    if not g.hide then
      for _, e in ipairs(g.list) do
        if e.id == reqs.selected then visible = true break end
      end
    end
  end
  if not visible then reqs.selected = nil end
  local collapsed = searching and {} or R.Collapsed()
  local items, nav = {}, {}
  for _, g in ipairs(groups) do
    if not g.hide and (#g.list > 0 or g.always) then
      if g.sort then table.sort(g.list, g.sort) end
      local open = not collapsed[g.key]
      items[#items + 1] = { kind = "cat", key = g.key, name = g.name, count = #g.list, depth = 0, collapsed = not open }
      if open and #g.list == 0 then
        items[#items + 1] = { placeholder = true, name = L["No crafting requests seen in chat yet."], depth = 1, gap = true }
      elseif open then
        for i, e in ipairs(g.list) do
          e.depth, e.gap = 1, i == #g.list
          items[#items + 1] = e
          e.idx = #items
          nav[#nav + 1] = e
        end
      end
    end
  end
  reqs.results = nav

  local emptyText, subText
  if #nav == 0 then
    if searching then
      emptyText = format(L["No request matches \"%s\"."], text)
    elseif onlyCan and #all > 0 then
      emptyText = L["Nothing you can craft right now."]
    elseif #items == 0 or (#items == 2 and groups[4].always) then
      emptyText = L["No requests yet"]
      subText = PeerCounts() == 0
        and L["Requests from CraftBoard users and crafting asks seen in Trade show up here. Ask your guild to install CraftBoard, or post your own from Find."]
        or L["Requests from CraftBoard users and crafting asks seen in Trade show up here. Post your own from Find."]
    end
  end
  reqs.noneText = #nav == 0 and (subText and "" or L["Select a request to see its details."])
    or L["Select a request to see its details."]
  if #items > 0 and not emptyText then subText = nil end
  reqs.emptySub:SetText(subText or "")
  reqs.emptySub:SetShown(subText ~= nil and #items == 0)
  reqs.list:SetItems(items, #items == 0 and emptyText or nil, keepScroll)
  if #items > 0 and emptyText and subText then
    -- Only the empty "Seen in chat" bar is listed: say it under the bar instead.
    reqs.noneText = subText
  end
  SyncFilterButton(reqs.filter, reqs.filterEntries)
  local pick = not reqs.selected and nav[1]
  if pick then
    UI.SelectRequest(pick.id)
  else
    UI.RefreshRequestDetail()
  end
end

-- Annotated entries for every board request, chat ask and queued craft: all (list), byID, and the
-- number of other players' requests I can craft (the tab's count: online authors, known recipes,
-- not queued or offered yet).
local function Annotate()
  local posts = NS.Comm and NS.Comm.Requests and NS.Comm.Requests() or {}
  local byOut = R.RecipesByOutput()
  local canCraft = NS.Inventory and NS.Inventory.CanCraft
  local all, byID, count = {}, {}, 0
  local now = time()
  local Q = NS.Queue
  local function add(e)
    all[#all + 1] = e
    byID[e.id] = e
    if e.counts and not (Q and Q.Has(e.id)) and not R.OfferedAgo(e) then count = count + 1 end
  end
  local postedBy = {}      -- [player .. ":" .. item]: a board request, so the same chat ask isn't listed twice
  for _, post in ipairs(posts) do
    if type(post) == "table" and type(post.item) == "number" and post.id ~= nil then
      local qty = post.qty or 1
      local know = R.KnowFor(byOut[post.item], post.item, qty)
      local name = ItemName(post.item)
      local mine = R.IsMyPost(post)
      -- Queued from their chat ask before they posted it (the chat row is left out below as a
      -- duplicate): the queued craft belongs to the post now.
      if not mine and Q and Q.Adopt then Q.Adopt(post.from, post.item, post.id) end
      local alt = not mine and R.AltOf(post.from)
      local online = mine or alt or R.Online(post.from)
      local e = {
        post = post, id = post.id, outputItemID = post.item, mine = mine or alt and true or false, altPost = alt and true or nil,
        know = know, t = post.t, name = name, lname = strlower(name), lfrom = strlower(Short(post.from)), ready = false,
        label = qty > 1 and (format(L["%dx"], qty) .. " " .. name) or name, icon = ItemIcon(post.item),
        online = online, can = know ~= nil and know.rec ~= nil, dim = not online,
      }
      if mine then
        e.status = Age(post.t)
      elseif alt then
        e.status = R.First(post.from) .. DOT .. Age(post.t)
      else
        e.status = R.First(post.from) .. DOT .. (online and Age(post.t) or L["offline"])
      end
      -- Ready: the current char knows it and has the reagents for the whole request; grey
      -- check: only an alt knows it.
      if e.can and know.current and canCraft then
        e.ready = canCraft(know.rec, qty, true).ready and true or false
      elseif e.can then
        e.readyAlt = true
      end
      e.counts = e.can and not e.mine and online
      postedBy[strlower(post.from) .. ":" .. post.item] = true
      add(e)
    end
  end
  -- Chat lines (ChatWatch.lua): id "chat:Name-Realm:<ask>". can = I have the profession, or any
  -- of my characters knows the recipe; ready = that, and (for a known recipe) this character
  -- carries the reagents or knows it; readyAlt (grey check) = only an alt knows it.
  local CW = NS.ChatWatch
  reqs.chatOn = CW and CW.Enabled and CW.Enabled() or false
  local mineRecipes = NS.Recipes and NS.Recipes.Mine and NS.Recipes.Mine() or {}
  for _, s in ipairs(reqs.chatOn and CW.Seen() or {}) do
    local rec = s.recipeID and NS.Recipes and NS.Recipes.Record and NS.Recipes.Record(s.recipeID) or nil
    local out = s.itemID or (rec and type(rec.o) == "number" and rec.o) or nil
    -- Several of my recipes make it: the one this ask's quantity can be crafted with.
    local useID = s.recipeID
    if s.current and not s.links and out and byOut[out] and byOut[out].multi then
      local k = R.KnowFor(byOut[out], out, s.qty or 1)
      if k and k.recipeID ~= s.recipeID then useID, rec = k.recipeID, k.rec end
    end
    local dup = out and postedBy[strlower(s.from) .. ":" .. out]
    if not dup then
      local profName = CW.ProfName and CW.ProfName(s) or s.prof
      local title = s.itemName or profName or L["Crafting request"]
      local label
      if s.links then
        label = s.links[1] .. " +" .. (#s.links - 1)
      else
        -- Profession-only asks read alike ("Enchanting" x3): add what the line is about.
        local topic = not s.itemName and CW.Topic and CW.Topic(s)
        label = topic and (title .. DOT .. topic) or title
      end
      local e = {
        -- The ask is part of the id, so a new ask from the same player isn't taken for a queued one.
        chat = true, seen = s, id = "chat:" .. s.from .. ":" .. (s.itemName or s.prof or ""), useRecipeID = useID,
        ready = CW.CanHelp(s) and true or false, rec = rec, profName = profName,
        name = title, label = (s.qty or 1) > 1 and (format(L["%dx"], s.qty) .. " " .. label) or label,
        lname = strlower(title .. " " .. (s.text or "")), lfrom = strlower(Short(s.from)),
        knownOn = s.knownOn, t = s.t, outputItemID = not s.links and out or nil,
        icon = (not s.links and ItemIcon(out)) or (s.recipeID and SpellIcon(s.recipeID)) or ProfIcon(s.profID),
        status = R.First(s.from) .. DOT .. Age(s.t), dim = now - (s.t or now) > OLD_AGE,
      }
      if not e.ready and s.knownOn then
        if rec and type(rec.r) == "table" and #rec.r > 0 and canCraft and canCraft(rec, s.qty or 1, true).ready then
          e.ready = true
        else
          e.readyAlt = true
        end
      end
      e.can = e.ready or e.readyAlt or false
      -- Asked again with another quantity ("LF 5x" after "LF 1x"), or they said they bring the
      -- reagents (or no longer do): the queued craft follows.
      local x = Q and Q.Get and Q.Get(e.id)
      if x and x.who then
        if s.qty and not x.madeItems then Q.SetQty(x, s.qty) end
        if Q.SetMats then Q.SetMats(x, s.mats) end
      end
      -- The count leaves out profession-only asks ("LF ench"): only asks for a recipe I know.
      e.counts = e.can and s.recipeID ~= nil and not e.dim
      add(e)
    end
  end
  -- My queue, with the reagent sum first once there is more than one craft in it.
  local queued, crafts = {}, 0
  for _, x in ipairs(Q and Q.Entries() or {}) do
    local rec = mineRecipes[x.recipeID]
    local name = (x.item and ItemName(x.item)) or (rec and rec.n) or format(L["Recipe %d"], x.recipeID)
    local made, total = 0, 0
    if rec then made, total = Q.Progress(x, rec) end
    local left = rec and Q.CraftsLeft(x, rec) or 0
    crafts = crafts + left
    local status
    if left == 0 and total > 0 then
      status = L["made"] .. (x.who and (DOT .. R.First(x.who)) or "")
    elseif made > 0 then
      status = format(L["%d/%d"], made, total) .. (x.who and (DOT .. R.First(x.who)) or "")
    else
      status = x.who and R.First(x.who) or L["planned"]
    end
    local e = {
      queue = x, id = "queue:" .. x.id, rec = rec, recipeID = x.recipeID, outputItemID = x.item, t = x.t,
      name = name, label = x.qty > 1 and (format(L["%dx"], x.qty) .. " " .. name) or name,
      icon = RecipeIcon(x.recipeID, x.item), status = status,
      lname = strlower(name), lfrom = strlower(x.who and Short(x.who) or ""),
      -- Craftable now: the bags, as the Craft button counts them (the card plans with the bank too).
      ready = left == 0 or (rec and canCraft and canCraft(rec, left * max(1, rec.y or 1), true).ready) or false,
    }
    queued[#queued + 1] = e
  end
  if #queued > 1 then
    local ready = true
    for _, r in ipairs(Q.Totals()) do
      if r.have < r.need then ready = false break end
    end
    add({ queueTotal = true, id = "queue:total", list = queued, name = L["All reagents"], label = L["All reagents"],
      icon = QUEUE_ICON, status = format(crafts == 1 and L["%d craft"] or L["%d crafts"], crafts),
      lname = strlower(L["All reagents"]), lfrom = "", ready = ready, t = math.huge })
  end
  for _, e in ipairs(queued) do add(e) end
  return all, byID, count
end

-- Refreshes wait while the mouse is over the list (or its menu is open) so rows don't move
-- under a click; they catch up half a second after it leaves.
function R.Busy()
  if reqs.menuOpen and Menu and Menu.GetManager then
    local ok, open = pcall(function() return Menu.GetManager():GetOpenMenu() end)
    if ok and open then return true end
  end
  reqs.menuOpen = nil
  return reqs.list and reqs.list.box.IsMouseOver and reqs.list.box:IsMouseOver() and true or false
end

function R.Flush()
  reqs.flushQueued = nil
  if not reqs.pending then return end
  if R.Busy() then
    reqs.flushQueued = true
    C_Timer.After(0.5, R.Flush)
    return
  end
  reqs.pending = nil
  UI.RefreshRequests(true, true)
end

-- Rebuild the annotated entries and refresh the list. force: refresh even under the mouse (the
-- player's own action).
function UI.RefreshRequests(keepScroll, force)
  if not reqs.list then return end
  if keepScroll and not force and R.Busy() then
    reqs.pending = true
    if not reqs.flushQueued and C_Timer and C_Timer.After then
      reqs.flushQueued = true
      C_Timer.After(0.5, R.Flush)
    end
    -- The card may still need its buttons updated (bags, casts).
    UI.RefreshRequestButtons()
    return
  end
  reqs.pending = nil
  -- Linked orders and reagent tooltips need to know who on the board makes what.
  if find.universeDirty ~= false then BuildUniverse() end
  local all, byID, count = Annotate()
  reqs.all, reqs.byID, reqs.count = all, byID, count
  reqs.countDirty = false
  UI.FilterRequests(keepScroll)
end

-- Other players' requests I can craft, for the tab's count (recounted only after a change).
function UI.RequestCount()
  if reqs.countDirty == false and reqs.count then return reqs.count end
  local _, _, count = Annotate()
  reqs.count, reqs.countDirty = count, false
  return count
end

-- Cached lookups go stale with these.
if NS.RegisterCallback then
  local function universe() find.universeDirty = true end
  for _, ev in ipairs({ "RECIPES_UPDATED", "PEERS_UPDATED", "IGNORE_UPDATED", "ITEM_NAMES_UPDATED" }) do
    NS.RegisterCallback(find, ev, universe)
  end
  local function recipes() R.byOutDirty = true; reqs.countDirty = true end
  local function count() reqs.countDirty = true end
  for _, ev in ipairs({ "RECIPES_UPDATED", "PEERS_UPDATED" }) do NS.RegisterCallback(R, ev, recipes) end
  for _, ev in ipairs({ "POSTS_UPDATED", "CHAT_SEEN_UPDATED", "INVENTORY_UPDATED", "QUEUE_UPDATED", "IGNORE_UPDATED",
    "ITEM_NAMES_UPDATED" }) do
    NS.RegisterCallback(R, ev, count)
  end
end
end
-- Plan tab ------------------------------------------------------------------------
-- Leveling the current character's professions. The list has a bar per profession ("Leather-
-- working 87/150 (+12)", the open one first) and under it the learned recipes by skill-up color,
-- as Blizzard's list marks them (Professions-Icon-Skill-High / -Medium / -Low before the name):
-- orange (every craft gives a point), yellow (most do), green (some do), gray (none; collapsed
-- until opened). A "Best next" row leads each profession: the recipe that gets the most skill out
-- of what is in the bags. Colors are the profession window's, saved at each scan; when the skill
-- has moved since, the card says so. Professions without recipes still get their bar (gathering,
-- or never opened). The card says what the recipe does for the skill, when the next rank can be
-- trained, and the reagents for the planned crafts (with counts on alts); the Create row has the
-- crafts spinner, Queue (adds the crafts to the queue) and Craft (red; like Blizzard's Create it
-- needs that profession's window open — when it isn't, the button opens it). A picked recipe
-- stays picked even when a filter hides it, so Craft never switches recipes on its own.

local BuildPlan
do
local P = {}
local TSC = type(TradeSkillTypeColor) == "table" and TradeSkillTypeColor or {}
local function RGB(c, r, g, b)
  if type(c) == "table" and type(c.r) == "number" then return { c.r, c.g, c.b } end
  return { r, g, b }
end
local DIFF = {
  [0] = { key = "orange", name = L["Always skill up"], rgb = RGB(TSC.optimal, 1, 0.5, 0.25), per = 1,
          icon = "Professions-Icon-Skill-High" },
  [1] = { key = "yellow", name = L["Usually skill up"], rgb = RGB(TSC.medium, 1, 1, 0), per = 0.75,
          icon = "Professions-Icon-Skill-Medium", line = L["About 3 in 4 crafts give a point, fewer as it nears green."] },
  [2] = { key = "green", name = L["Sometimes skill up"], rgb = RGB(TSC.easy, 0.25, 0.75, 0.25), per = 0.25,
          icon = "Professions-Icon-Skill-Low", line = L["About 1 in 4 crafts give a point; it turns gray soon."] },
  [3] = { key = "gray", name = L["No skill up"], rgb = RGB(TSC.trivial, 0.5, 0.5, 0.5), per = 0,
          line = L["No skill points from this any more."] },
}
local UNKNOWN = { key = "unknown", name = L["Color not seen yet"], rgb = C.label,
  line = L["Open the profession window to see its skill-up color."] }
local ORDER = { 0, 1, 2, 3, "unknown" }
local GATHERING = { [182] = true, [186] = true, [393] = true, [356] = true }   -- Herbalism, Mining, Skinning, Fishing
local YELLOW_CAP, GREEN_CAP, MAX_PLAN = 10, 5, 200

local function DiffOf(rec)
  return DIFF[type(rec) == "table" and rec.d] or UNKNOWN
end

-- Skill points one craft gives while the color holds (orange: the recipe's skill-ups, else 1).
local function PerCraft(rec, diff)
  if diff == DIFF[0] and type(rec.su) == "number" and rec.su > 1 then return rec.su end
  return diff.per
end

-- The current character's professions: { profID=, name=, rank=, max=, icon=, sr=, fresh= }, the
-- one whose window is open first. Professions come from the profession book (Skills) and from
-- recorded recipes, so a profession never opened or a gathering one still gets its bar.
function P.Profs()
  local c = type(CraftBoardDB) == "table" and NS.Me and type(CraftBoardDB.chars) == "table" and CraftBoardDB.chars[NS.Me]
  local stored = type(c) == "table" and type(c.profs) == "table" and c.profs or {}
  local byID = {}
  local function add(id, name, rank, maxRank, icon)
    if id == nil or byID[id] then return end
    local s = type(stored[id]) == "table" and stored[id] or {}
    if s.gone then return end
    byID[id] = { profID = id, name = name or s.name or s[1] or L["Other"], rank = rank or s.rank or s[2],
      max = maxRank or s.max or s[3], icon = icon or s.icon, sr = s.sr, fresh = s.newRecipes }
  end
  if NS.Skills and NS.Skills.Ranks then
    for _, r in ipairs(NS.Skills.Ranks()) do add(r.profID, r.name, r.rank, r.max, r.icon) end
  end
  for id in pairs(stored) do add(id) end
  for _, rec in pairs(NS.Recipes and NS.Recipes.Mine and NS.Recipes.Mine() or {}) do
    if type(rec) == "table" then add(rec.p) end
  end
  local open = NS.Craft and NS.Craft.OpenProfession and NS.Craft.OpenProfession()
  local out = {}
  for _, pr in pairs(byID) do out[#out + 1] = pr end
  table.sort(out, function(a, b)
    if (a.profID == open) ~= (b.profID == open) then return a.profID == open end
    return tostring(a.name) < tostring(b.name)
  end)
  return out
end

-- The next skill that matters: the next rank's threshold, else the cap; nil at the cap.
function P.Milestone(pr)
  if NS.Skills and NS.Skills.Milestone then
    local m = NS.Skills.Milestone(pr.profID)
    if m ~= nil then return m end
  end
  local rank, maxRank = pr.rank, pr.max
  if type(rank) ~= "number" or type(maxRank) ~= "number" then return nil end
  for _, at in ipairs({ 50, 125, 200 }) do
    if rank < at and at <= maxRank then return at end
  end
  return rank < maxRank and maxRank or nil
end

-- Crafts to reach the milestone with this recipe, if it stayed this color (orange: exact).
function P.CraftsTo(pr, rec, diff)
  local milestone = P.Milestone(pr)
  local per = PerCraft(rec, diff)
  if not (milestone and type(pr.rank) == "number" and per and per > 0) or milestone <= pr.rank then return nil, milestone end
  return math.ceil((milestone - pr.rank) / per), milestone
end

-- Crafts a newly picked recipe plans: to the milestone for orange, a handful for yellow/green,
-- one for cooldown crafts and at the cap.
function P.DefaultCrafts(e)
  local rec, pr = e.rec, e.prof
  if NS.Cooldowns and NS.Cooldowns.Is and NS.Cooldowns.Is(e.recipeID, rec) then return 1 end
  local crafts = P.CraftsTo(pr, rec, e.diff)
  if not crafts then return 1 end
  if e.diff == DIFF[1] then crafts = min(crafts, YELLOW_CAP) end
  if e.diff == DIFF[2] then crafts = min(crafts, GREEN_CAP) end
  return min(MAX_PLAN, max(1, crafts))
end

function P.Collapsed()
  local db = UIDB()
  if not db then return {} end
  if type(db.planCollapsed) ~= "table" then db.planCollapsed = {} end
  return db.planCollapsed
end

-- Gray groups start collapsed: a stored false means opened.
function P.IsCollapsed(key, gray)
  local v = P.Collapsed()[key]
  if v == nil then return gray end
  return v
end

function P.ToggleGroup(it)
  if plan.searching then return end
  P.Collapsed()[it.key] = not P.IsCollapsed(it.key, it.gray)
  UI.FilterPlan(true)
end

function P.Option(key)
  local db = UIDB()
  return db and db[key] == true or false
end

-- Recipes of the current character, bucketed by profession, rebuilt only when recipes, skills or
-- item names change (typing only filters): plan.recipes[profID] = { entry, ... }.
function P.Index()
  if plan.recipes and not plan.dirty then return plan.recipes end
  local byProf = {}
  local mine = NS.Recipes and NS.Recipes.Mine and NS.Recipes.Mine() or {}
  for id, rec in pairs(mine) do
    if type(rec) == "table" and rec.p ~= nil then
      local name = rec.n or (NS.Recipes.NameOf and NS.Recipes.NameOf(id)) or format(L["Recipe %d"], id)
      local list = byProf[rec.p] or {}
      byProf[rec.p] = list
      list[#list + 1] = { recipeID = id, rec = rec, name = name, lname = strlower(name), diff = DiffOf(rec) }
    end
  end
  plan.recipes, plan.dirty = byProf, false
  return byProf
end

-- "Best next": among recipes that still give points and that the bags allow now, points per
-- craft, then how many crafts that covers, then fewest reagents per point. None when nothing is
-- craftable (it would promise a craft the button can't make). No prices involved.
function P.Best(list, pr)
  local best, bestKey
  for _, e in ipairs(list) do
    local per = e.ready and e.diff.per and e.diff.per > 0 and PerCraft(e.rec, e.diff) or nil
    if per then
      local mats = 0
      for _, r in ipairs(type(e.rec.r) == "table" and e.rec.r or {}) do mats = mats + (r[2] or 0) end
      local crafts = P.CraftsTo(pr, e.rec, e.diff) or 1
      local key = { per, min(e.times or 0, crafts), -(mats / per) }
      local better = not bestKey
      if bestKey then
        for i = 1, #key do
          if key[i] ~= bestKey[i] then better = key[i] > bestKey[i] break end
        end
      end
      if better then best, bestKey = e, key end
    end
  end
  return best
end

function P.RowFactory()
  local base = GroupRowFactory(function(it) if it.recipeID then UI.SelectPlan(it.recipeID, true, it.best) end end, P.ToggleGroup)
  return function(parent)
    local row = base(parent)
    local skill = row:CreateTexture(nil, "OVERLAY")
    skill:SetPoint("CENTER", row, "TOPLEFT", floor(ROW.labelX / 2), -ROW.recipeBar / 2)
    skill:Hide()
    row.skill = skill
    row.recipeParts[#row.recipeParts + 1] = skill
    row:SetScript("OnEnter", function(self)
      local it = self.item
      if it and it.recipeID and not it.kind then ShowTooltip(self, it.rec.o, it.recipeID) end
    end)
    return row
  end
end

function P.FillEntry(row, e)
  if e.placeholder then
    row.skill:Hide()
    row.name:SetText(e.name)
    row.name:SetTextColor(MUTED[1], MUTED[2], MUTED[3])
    row.status:SetText("")
    row.sel:Hide()
    return
  end
  local atlas = e.diff.icon and HasAtlas(e.diff.icon) and e.diff.icon
  if atlas then SetAtlasSized(row.skill, atlas) end
  row.skill:SetShown(atlas and true or false)
  local label = e.best and format(L["Best next: %s"], e.name) or e.name
  row.name:SetText(e.ready and (label .. CountText(e.times)) or label)
  -- Blizzard's list keeps names neutral beside the skill-up mark; without the marks, the name
  -- takes the color.
  local rgb = (atlas or e.diff == UNKNOWN) and C.label or e.diff.rgb
  row.name:SetTextColor(rgb[1], rgb[2], rgb[3])
  row.status:SetText(e.status or "")
  -- The Best next row and the recipe's own row light up separately: whichever was picked.
  row.sel:SetShown(e.recipeID == plan.selected and (e.best and true or false) == (plan.bestSelected and true or false))
end

-- Card ----------------------------------------------------------------------------

-- The red button: Craft, "Open <profession>" when its window is closed, "Crafting..." while a
-- batch runs. Also re-run on its own when bags, casts or the profession window change.
function P.Buttons()
  local e = plan.entry
  if not e then
    plan.craft:SetText(L["Craft"])
    plan.craft:SetEnabled(false)
    plan.queue:SetEnabled(false)
    return
  end
  local ok, why, _, openProf = false, nil, nil, nil
  if NS.Craft then ok, why, _, openProf = NS.Craft.CanCraft(e.recipeID) end
  plan.craftWhy, plan.openProf = why, (not ok) and openProf or nil
  if plan.openProf then
    plan.craft:SetText(format(L["Open %s"], NS.ProfessionName(openProf) or e.prof.name))
    plan.craft:SetEnabled(true)
  else
    plan.craft:SetText(NS.Craft and NS.Craft.IsCrafting() and L["Crafting..."] or L["Craft"])
    plan.craft:SetEnabled(ok and true or false)
  end
  FitButton(plan.craft, 112)
  plan.queue:SetEnabled(true)
end

function P.Detail()
  local e = plan.selected and plan.byID and plan.byID[plan.selected] or nil
  plan.entry = e
  P.Buttons()
  if not e then
    plan.body:Hide()
    plan.none:SetText(plan.noneText or "")
    plan.none:Show()
    SetDetailBackground(plan, nil)
    return
  end
  plan.none:Hide()
  plan.body:Show()
  local rec, pr = e.rec, e.prof
  local sub = pr.rank and pr.max and format(L["%s %d/%d"], pr.name, pr.rank, pr.max) or pr.name
  FillHeader(plan.header, e.recipeID, rec.o, e.name, sub, nil)
  SetDetailBackground(plan, rec.p)

  local lines = {}
  if plan.hidden then lines[#lines + 1] = GREY .. L["Hidden by your filter."] .. "|r" end
  if plan.bestSelected then lines[#lines + 1] = GOLD_HEX .. L["The best skill-up you can make from your bags."] .. "|r" end
  local atCap = type(pr.rank) == "number" and type(pr.max) == "number" and pr.rank >= pr.max
  local nextRank = NS.Skills and NS.Skills.NextRank and NS.Skills.NextRank(rec.p)
  if atCap and pr.max < 300 then
    lines[#lines + 1] = format(L["At the cap (%d): no skill points until you learn the next rank."], pr.max)
  elseif atCap then
    lines[#lines + 1] = format(L["%s is maxed out."], pr.name)
  elseif e.diff == DIFF[0] then
    lines[#lines + 1] = L["Every craft gives a skill point while it stays orange."]
    local crafts, milestone = P.CraftsTo(pr, rec, e.diff)
    if crafts then
      lines[#lines + 1] = format(crafts == 1 and L["%d craft to reach %d."] or L["Up to %d crafts to reach %d."], crafts, milestone)
    end
  else
    lines[#lines + 1] = e.diff.line
  end
  if rec.e then lines[#lines + 1] = L["Enchant from the Enchanting window: Create asks for the item."] end
  if nextRank then
    local where = nextRank.source == "book" and L["from a book"] or nextRank.source == "quest" and L["by quest"]
      or L["at a trainer"]
    if nextRank.ready then
      lines[#lines + 1] = GREEN .. format(L["Next rank: %s, %s, now."], nextRank.title, where) .. "|r"
    elseif nextRank.level and UnitLevel and (UnitLevel("player") or 0) < nextRank.level then
      lines[#lines + 1] = format(L["Next rank: %s at skill %d and level %d, %s."], nextRank.title, nextRank.at, nextRank.level, where)
    else
      lines[#lines + 1] = format(L["Next rank: %s at skill %d, %s."], nextRank.title, nextRank.at, where)
    end
  end
  if type(pr.sr) == "number" and type(pr.rank) == "number" and pr.sr ~= pr.rank then
    lines[#lines + 1] = GREY .. format(L["Colors are from skill %d: open %s to update them."], pr.sr, pr.name) .. "|r"
  end
  if pr.fresh then
    lines[#lines + 1] = GREY .. format(L["New recipes learned: open %s to add them."], pr.name) .. "|r"
  end
  plan.info:SetText(table.concat(lines, "\n"))
  local h = plan.info.GetStringHeight and plan.info:GetStringHeight()
  plan.info:SetHeight(max(12, type(h) == "number" and h or 12 * #lines))

  -- Reagents for the planned crafts (the spinner), with what my alts carry.
  local n = ReadQty(plan.qty)
  local items = n * max(1, rec.y or 1)
  local cc = NS.Inventory and NS.Inventory.CanCraft and NS.Inventory.CanCraft(rec, items) or { reagents = {}, missing = {} }
  local short = FillMissingLine(plan.missing, cc.missing)
  plan.reagLabel:ClearAllPoints()
  plan.reagLabel:SetPoint("TOPLEFT", short and plan.missing or plan.info, "BOTTOMLEFT", 0, -8)
  local reagents = Chain.AnnotateMakers(cc.reagents or {})
  local top, bottom = plan.reagLabel:GetTop(), plan.body:GetBottom()
  local fit = (type(top) == "number" and type(bottom) == "number" and top > bottom)
    and floor((top - bottom - 24) / REAGENT_H)
    or floor(((plan.body:GetHeight() or 0) - 190 - plan.info:GetHeight()) / REAGENT_H)
  plan.reagents.box:SetHeight(#reagents > 0 and REAGENT_H * min(max(1, #reagents), max(1, fit)) or SUBROW_H)
  plan.reagents:SetItems(reagents, L["No reagents recorded."], true)
end

-- picked: the player chose it (click, keys, pad); viaBest: through the Best next row (the same
-- recipe as its own row; remembered so only the clicked row lights up).
function UI.SelectPlan(id, picked, viaBest)
  local changed = plan.selected ~= id
  plan.selected = id
  plan.bestSelected = viaBest and true or false
  if picked then plan.userPicked = true end
  if plan.list then plan.list:Render() end
  local e = id and plan.byID and plan.byID[id]
  if changed and e and plan.qty then
    local n = P.DefaultCrafts(e)
    if plan.qty.SetValue then pcall(plan.qty.SetValue, plan.qty, n) end
    plan.qty:SetText(tostring(n))
  end
  P.Detail()
end

-- Only the buttons (bags, casts, the profession window changed).
function UI.RefreshPlanButtons()
  if plan.body and plan.entry then P.Buttons() end
end

-- Build ---------------------------------------------------------------------------

function BuildPlan(p)
  plan.keyOf = function(e) return e.recipeID end
  plan.selectedKey = function() return plan.selected end
  plan.selectKey = function(id) UI.SelectPlan(id, true, false) end
  plan.refilter = function(keep) UI.FilterPlan(keep) end

  local left = ListColumn(p, plan)
  local function flag(key)
    return function() local db = UIDB() if db then db[key] = not P.Option(key) or nil end UI.FilterPlan(false) end
  end
  AddFilter(plan, left, function()
    return {
      { kind = "check", text = L["Only what I can craft"], get = function() return P.Option("planReady") end, set = flag("planReady") },
      { kind = "check", text = L["Hide gray recipes"], get = function() return P.Option("planNoGrey") end, set = flag("planNoGrey") },
    }
  end, function() return not (P.Option("planReady") or P.Option("planNoGrey")) end, function()
    local db = UIDB()
    if db then db.planReady, db.planNoGrey = nil, nil end
    UI.FilterPlan(false)
  end)
  plan.search = NewSearchBox("CraftBoardPlanSearchBox", left, plan)
  plan.search:SetPoint("TOPLEFT", left, "TOPLEFT", 13, -8)
  plan.search:SetPoint("RIGHT", plan.filter, "LEFT", -4, 0)
  GroupList(plan, left, "CraftBoardPlanScroll", P.RowFactory(), GroupFill(P.FillEntry))

  local d = CardForm(p, plan, left)
  plan.none = Placeholder(d, "")
  local body = CreateFrame("Frame", nil, d)
  body:SetAllPoints()
  plan.body = body
  plan.header = NewHeader(body)
  plan.info = Label(body, nil, FontOf(FONTS.desc))
  if plan.info.SetWordWrap then plan.info:SetWordWrap(true) end
  if plan.info.SetMaxLines then plan.info:SetMaxLines(8) end
  if plan.info.SetJustifyV then plan.info:SetJustifyV("TOP") end
  plan.info:SetPoint("TOPLEFT", plan.header.holder, "BOTTOMLEFT", -1, -12)
  plan.info:SetPoint("RIGHT", body, "RIGHT", -20, 0)
  plan.missing = NewMissingLine(body)
  plan.missing:SetPoint("TOPLEFT", plan.info, "BOTTOMLEFT", 0, -6)
  plan.missing:SetPoint("RIGHT", body, "RIGHT", -20, 0)
  plan.reagLabel = SectionLabel(body, L["Reagents:"])
  plan.reagents = NewList("CraftBoardPlanReagentsScroll", body, REAGENT_H, ReagentRow, FillReagentRow,
    { inline = true, stripes = false })
  plan.reagents.box:SetPoint("TOPLEFT", plan.reagLabel, "TOPLEFT", 1, -20)
  plan.reagents.box:SetPoint("RIGHT", body, "RIGHT", -20, 0)

  -- Create row: crafts spinner, Queue, Craft (red, where Create is).
  local bar = NewBar(p, d)
  plan.bar = bar
  plan.craft = RedButton(bar, L["Craft"], 112, 28)
  plan.craft:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -9, 7)
  plan.craft:SetScript("OnClick", function()
    local e = plan.entry
    if not (e and NS.Craft) then return end
    if plan.openProf then
      if not NS.Craft.Open(plan.openProf) then NS.Print(plan.craftWhy or "") end
      return
    end
    NS.Craft.Do(e.recipeID, ReadQty(plan.qty))
    P.Buttons()
  end)
  plan.craft:SetScript("OnEnter", function(self)
    if plan.openProf then
      TextTooltip(self, self:GetText(), L["Opens the profession window. Click again to craft."])
    elseif self:IsEnabled() then
      TextTooltip(self, L["Craft"], L["Crafts the planned number, as many as the reagents in your bags allow. Moving cancels the rest."])
    else
      TextTooltip(self, self:GetText(), plan.craftWhy)
    end
  end)
  plan.craft:SetScript("OnLeave", HideTooltip)

  plan.queue = PanelButton(bar, L["Queue"], 70, 22)
  FitButton(plan.queue, 70)
  plan.queue:SetPoint("RIGHT", plan.craft, "LEFT", -6, 0)
  plan.queue:SetScript("OnClick", function()
    local e = plan.entry
    if not (e and NS.Queue) then return end
    local n = ReadQty(plan.qty)
    local items = n * max(1, e.rec.y or 1)
    -- One planned entry per recipe: queuing again adds to it.
    local x, isNew = NS.Queue.Add({ recipeID = e.recipeID, item = e.rec.o, qty = items, src = "plan:" .. e.recipeID })
    if x and not isNew then NS.Queue.Grow(x, items) end
    if x then
      NS.Print(format(L["Queued: %dx %s"], items, e.name))
    elseif isNew == "full" then
      NS.Print(L["Your queue is full. Finish or remove a craft first."])
    end
  end)
  plan.queue:SetScript("OnEnter", function(self)
    TextTooltip(self, L["Queue"], L["Adds the planned crafts to your queue on the Requests tab, where Craft next and Buy missing reagents work through them."])
  end)
  plan.queue:SetScript("OnLeave", HideTooltip)

  local decW, incW
  plan.qty, decW, incW = BarQty(bar, "CraftBoardPlanQty")
  plan.qty:SetPoint("RIGHT", plan.queue, "LEFT", -(incW + 8), 0)
  plan.qty:HookScript("OnTextChanged", Debouncer(0.2, function() P.Detail() end))
  plan.qtyLabel = Muted(Label(bar, L["Crafts"], Font("GameFontHighlightSmall")))
  plan.qtyLabel:SetPoint("RIGHT", plan.qty, "LEFT", -(decW + 6), 0)
end

-- Filter and group ---------------------------------------------------------------

function UI.FilterPlan(keepScroll)
  if not plan.list then return end
  local text = strtrim(plan.search:GetText() or "")
  local searching = #text >= 2
  plan.searching = searching
  local tokens = searching and Tokens(text) or {}
  local onlyReady, noGray = P.Option("planReady"), P.Option("planNoGrey")
  local index = P.Index()
  local canCraft = NS.Inventory and NS.Inventory.CanCraft
  local items, nav, byID = {}, {}, {}
  local profs = P.Profs()
  local anyRecipes = false
  for _, pr in ipairs(profs) do
    local list = index[pr.profID] or {}
    if #list > 0 then anyRecipes = true end
    local groups, count = {}, 0
    local pkey = "prof:" .. tostring(pr.profID)
    local pOpen = searching or not P.IsCollapsed(pkey, false)
    for _, e in ipairs(list) do
      e.prof, e.best = pr, nil
      byID[e.recipeID] = e
      local ok = true
      for i = 1, #tokens do
        if not e.lname:find(tokens[i], 1, true) then ok = false break end
      end
      if ok and noGray and e.diff == DIFF[3] then ok = false end
      local key = pr.profID .. ":" .. e.diff.key
      local open = pOpen and (searching or not P.IsCollapsed(key, e.diff == DIFF[3]))
      -- Bags are only counted for rows that can show, or when the filter needs them.
      if ok and (open or onlyReady or e.diff ~= DIFF[3]) and canCraft then
        -- Ready means craftable now: the bags, not the bank (planning elsewhere counts both).
        local cc = canCraft(e.rec, nil, true)
        e.ready, e.times = cc.ready and true or false, cc.times or 0
      else
        e.ready, e.times = false, 0
      end
      if ok and onlyReady and not e.ready then ok = false end
      if ok then
        groups[e.diff.key] = groups[e.diff.key] or {}
        table.insert(groups[e.diff.key], e)
        count = count + 1
      end
    end
    local gain = NS.Skills and NS.Skills.SessionGain and NS.Skills.SessionGain(pr.profID) or 0
    -- The name on the bar; the rank goes in the right-hand slot (a long name plus "111/150" and a
    -- recipe count don't fit in one bar).
    local label = pr.name
    if gain > 0 then label = label .. " " .. format(L["(+%d)"], gain) end
    local rankText = pr.rank and pr.max and format(L["%d/%d"], pr.rank, pr.max) or count
    -- Professions with nothing to show while searching or filtering stay out of the way.
    if count > 0 or not (searching or onlyReady) then
      items[#items + 1] = { kind = "prof", key = pkey, name = label, prof = pr.profID, count = rankText, depth = 0, collapsed = not pOpen }
    end
    if pOpen and count == 0 and not (searching or onlyReady) then
      local why = GATHERING[pr.profID] and L["Gathering: nothing to craft."]
        or format(L["Open %s once to plan it."], pr.name)
      items[#items + 1] = { placeholder = true, name = why, depth = 1, gap = true }
    elseif pOpen and count > 0 then
      -- Best next leads the profession, as its own row.
      local all = {}
      for _, d in ipairs(ORDER) do
        for _, e in ipairs(groups[(DIFF[d] or UNKNOWN).key] or {}) do all[#all + 1] = e end
      end
      local best = not searching and P.Best(all, pr)
      if best then
        local copy = setmetatable({ best = true, depth = 1, gap = true }, { __index = best })
        items[#items + 1] = copy
        copy.idx = #items
        nav[#nav + 1] = copy
      end
      for _, d in ipairs(ORDER) do
        local diff = DIFF[d] or UNKNOWN
        local glist = groups[diff.key]
        if glist then
          table.sort(glist, function(a, b)
            if a.ready ~= b.ready then return a.ready end
            return a.name < b.name
          end)
          local key = pr.profID .. ":" .. diff.key
          local open = searching or not P.IsCollapsed(key, d == 3)
          items[#items + 1] = { kind = "cat", key = key, gray = d == 3, name = diff.name, count = #glist, depth = 1, collapsed = not open }
          if open then
            for i, e in ipairs(glist) do
              e.depth, e.gap = 2, i == #glist
              items[#items + 1] = e
              e.idx = #items
              nav[#nav + 1] = e
            end
          end
        end
      end
    end
  end
  plan.results, plan.byID = nav, byID
  -- A recipe the player picked stays picked while a filter hides it (the card says so); an
  -- automatic pick moves with the list.
  local visible = false
  for _, e in ipairs(nav) do
    if e.recipeID == plan.selected then visible = true break end
  end
  plan.hidden = plan.selected and not visible and byID[plan.selected] ~= nil and plan.userPicked or false
  if plan.selected and not visible and not plan.hidden then plan.selected = nil end
  local emptyText
  if #items == 0 then
    if #profs == 0 then
      emptyText = L["No professions yet. Learn one from a trainer in any capital city."]
    elseif searching then
      emptyText = format(L["No recipe matches \"%s\"."], text)
    elseif onlyReady then
      emptyText = L["Nothing you can craft right now."]
    end
  end
  plan.noneText = anyRecipes and L["Select a recipe to plan it."] or EMPTY_RECIPES
  plan.list:SetItems(items, emptyText, keepScroll)
  SyncFilterButton(plan.filter, plan.filterEntries)
  local pick = not plan.selected and nav[1]
  if pick then UI.SelectPlan(pick.recipeID, false, pick.best) else P.Detail() end
end

function UI.RefreshPlan(keepScroll)
  UI.FilterPlan(keepScroll)
end

-- The spinner counts down as planned crafts are made; recipe data changes rebuild the index.
NS.Register("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
  if issecretvalue and (issecretvalue(unit) or issecretvalue(spellID)) then return end
  if unit ~= "player" or spellID ~= plan.selected or not plan.qty then return end
  local n = ReadQty(plan.qty)
  if n > 1 then
    if plan.qty.SetValue then pcall(plan.qty.SetValue, plan.qty, n - 1) end
    plan.qty:SetText(tostring(n - 1))
  end
end)
if NS.RegisterCallback then
  local function dirty() plan.dirty = true end
  for _, ev in ipairs({ "RECIPES_UPDATED", "SKILLS_UPDATED", "ITEM_NAMES_UPDATED" }) do
    NS.RegisterCallback(plan, ev, dirty)
  end
end
end
-- Window --------------------------------------------------------------------

local function SavePosition(f)
  local db = UIDB()
  if not db then return end
  local point, _, relPoint, x, y = f:GetPoint(1)
  db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end

local function RestorePosition(f)
  local db = UIDB()
  f:ClearAllPoints()
  if db and db.point then
    f:SetPoint(db.point, UIParent, db.relPoint or db.point, db.x or 0, db.y or 0)
  else
    f:SetPoint("CENTER")
  end
  -- A size saved by the older, smaller layout counts as unset: open at the new default.
  local w = db and tonumber(db.w) or WIDTH
  local h = db and tonumber(db.h) or HEIGHT
  if w < G.minW then w = WIDTH end
  if h < G.minH then h = HEIGHT end
  f:SetSize(min(G.maxW, w), min(G.maxH, h))
end


-- Status line -------------------------------------------------------------------
-- Where CraftingPage.RankBar sits (453x18 at TOPLEFT 110,-40), with no bar art: one quiet
-- left-aligned GameFontHighlightSmall line in grey about the board ("2 crafters online ·
-- 1 open request", " · realm channel off" when the realm channel is disabled). The older
-- "61 recipes · 0 peers · channel ok" summary is the portrait's tooltip.
-- At its right end, the Available / Busy toggle (b.busy): gold "Available", grey "Busy";
-- a click flips manual busy (Comm.ToggleBusy). It is a child of the line, so it moves with it.
local function NewStatusLine(f)
  local b = CreateFrame("Frame", nil, f)
  b:SetSize(G.statusW, G.statusH)
  b:SetPoint("TOPLEFT", f, "TOPLEFT", G.statusX, G.statusY)
  local t = CreateFrame("Button", nil, b)
  t:SetHeight(G.statusH)
  t:SetPoint("RIGHT", b, "RIGHT", 0, 0)
  t.label = Label(t, nil, Font("GameFontNormalSmall"))
  t.label:SetPoint("CENTER", t, "CENTER", 0, 0)
  local hl = t:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.08)
  function t.cbSync()
    local cm = NS.Comm
    local busy = cm and cm.IsBusy and cm.IsBusy() or false
    t.label:SetText(busy and L["Busy"] or L["Available"])
    local c = busy and MUTED or GOLD_RGB
    t.label:SetTextColor(c[1], c[2], c[3])
    t:SetWidth(ceil(StringWidth(t.label)) + 10)
  end
  local function tip(self)
    local cm = NS.Comm
    local busy, manual = false, false
    if cm and cm.BusyState then busy, manual = cm.BusyState() end
    if manual then
      TextTooltip(self, L["Busy"], L["Other CraftBoard users see you as busy and can't whisper you from the board. Click to become available."])
    elseif busy then
      TextTooltip(self, L["Busy"], L["Busy automatically while you are in a dungeon or raid. You can turn this off in the CraftBoard settings."])
    else
      TextTooltip(self, L["Available"], L["Click to mark yourself busy: other CraftBoard users see you grayed out and can't whisper you from the board."])
    end
  end
  t:SetScript("OnClick", function(self)
    if NS.Comm and NS.Comm.ToggleBusy then NS.Comm.ToggleBusy(true) end
    self.cbSync()
    tip(self)
  end)
  t:SetScript("OnEnter", tip)
  t:SetScript("OnLeave", HideTooltip)
  t.cbSync()
  b.busy = t
  b.text = Muted(Label(b, nil, Font("GameFontHighlightSmall")))
  b.text:SetPoint("LEFT", b, "LEFT", 0, 0)
  b.text:SetPoint("RIGHT", t, "LEFT", -8, 0)
  -- The whole line, and the summary the standalone portrait shows, on hover (the embedded page
  -- has no portrait, and the line may be cut short).
  b:EnableMouse(true)
  b:SetScript("OnEnter", function(self)
    -- BoardLine / SummaryLine are defined below this function: go through their public names.
    TextTooltip(self, UI.StatusText(), UI.SummaryText())
  end)
  b:SetScript("OnLeave", HideTooltip)
  return b
end

-- "2 crafters online · 1 open request", or the invite line when no one else is on the board.
local function BoardLine()
  local total, online = PeerCounts()
  local line
  if total == 0 then
    line = L["No other crafters yet \194\183 ask your guild to install CraftBoard"]
  else
    local open = #(NS.Comm and NS.Comm.Requests and NS.Comm.Requests() or {})
    line = format(online == 1 and L["%d crafter online"] or L["%d crafters online"], online)
      .. DOT .. format(open == 1 and L["%d open request"] or L["%d open requests"], open)
  end
  if type(CraftBoardDB) == "table" and CraftBoardDB.realmChannel == false then
    line = line .. DOT .. L["realm channel off"]
  end
  return line
end

-- "61 recipes · 0 peers · channel ok" (portrait tooltip)
local function SummaryLine()
  local st = NS.Comm and NS.Comm.Status and NS.Comm.Status()
  local n = MyRecipeCount()
  local parts = { format(n == 1 and L["%d recipe"] or L["%d recipes"], n) }
  if st then
    local users = st.peers or 0
    parts[#parts + 1] = format(users == 1 and L["%d other CraftBoard user"] or L["%d other CraftBoard users"], users)
    parts[#parts + 1] = st.channel and L["realm channel on"] or L["realm channel off"]
  end
  return table.concat(parts, DOT)
end

-- The window's board status line, for the minimap button tooltip.
function UI.StatusText()
  return BoardLine()
end

-- "61 recipes · 3 other CraftBoard users · realm channel on" (portrait / status line tooltip).
function UI.SummaryText()
  return SummaryLine()
end

function UI.RefreshStatus()
  if statusLine then
    statusLine.text:SetText(BoardLine())
    if statusLine.busy then statusLine.busy.cbSync() end
  end
end

-- Invisible hit area over the portrait for the summary tooltip; drags still move the window.
local function PortraitTooltip(f)
  local pc = f.PortraitContainer
  local hit = CreateFrame("Frame", nil, f)
  if pc then
    hit:SetAllPoints(pc)
  else
    hit:SetSize(60, 60)
    hit:SetPoint("TOPLEFT", f, "TOPLEFT", -5, 7)
  end
  hit:SetFrameLevel((f:GetFrameLevel() or 0) + 10)
  hit:EnableMouse(true)
  hit:RegisterForDrag("LeftButton")
  hit:SetScript("OnDragStart", function() f:StartMoving() end)
  hit:SetScript("OnDragStop", function()
    local stop = f:GetScript("OnDragStop")
    if stop then stop(f) else f:StopMovingOrSizing() end
  end)
  hit:SetScript("OnEnter", function(self) TextTooltip(self, "CraftBoard", SummaryLine()) end)
  hit:SetScript("OnLeave", HideTooltip)
  f.cbPortraitHit = hit
end

-- Width of the list column for a window `w` px wide: Blizzard's 304 at the default width,
-- plus LEFT_FRAC of any extra width; the card follows it (anchored to the column's right).
local function SplitWidth(w)
  return G.listW + floor(max(0, (w or WIDTH) - WIDTH) * LEFT_FRAC)
end

local splitDone = false
local function LayoutSplit(w)
  local left = SplitWidth(w)
  if splitDone and left == LEFT_W then return end
  splitDone, LEFT_W = true, left
  if find.left then find.left:SetWidth(left) end
  if reqs.left then reqs.left:SetWidth(left) end
  if plan.left then plan.left:SetWidth(left) end
end

local REFRESH = {
  function(keep) UI.RefreshFind(keep) end,
  function(keep) UI.RefreshRequests(keep) end,
  function(keep) UI.RefreshPlan(keep) end,
}

-- No search box ever takes the keyboard on its own: like Blizzard's profession search, it does
-- when clicked, so chat commands typed with the window open still work.

local TAB_NAMES = { L["Find"], L["Requests"], L["Plan"] }

local function SelectTab(i)
  activeTab = i
  local db = UIDB()
  if db then db.tab = i end
  for j, tab in ipairs(tabs) do
    panels[j]:SetShown(j == i)
    if tab.cbSelected then
      tab.cbSelected:SetShown(j == i)
    elseif tab.isPanelTab then
      if j == i then
        if PanelTemplates_SelectTab then PanelTemplates_SelectTab(tab) end
      elseif PanelTemplates_DeselectTab then
        PanelTemplates_DeselectTab(tab)
      end
    elseif j == i then
      tab:LockHighlight()
    else
      tab:UnlockHighlight()
    end
  end
  for j, tab in ipairs(topTabs) do tab.cbSetSelected(j == i) end
  if i ~= 1 and find.search then find.search:ClearFocus() end
  if i ~= 2 and reqs.search then reqs.search:ClearFocus() end
  if i ~= 3 and plan.search then plan.search:ClearFocus() end
  if i ~= 1 then UpdatePortrait(nil) end
  -- Keep the list where it was, with the selection in view.
  REFRESH[i](true)
  local t = ({ find, reqs, plan })[i]
  if t and t.list and t.results then
    local cur = t.selectedKey and t.selectedKey() or selectedID
    local keyOf = t.keyOf or function(u) return u.recipeID end
    for _, u in ipairs(t.results) do
      if keyOf(u) == cur and u.idx then t.list:ScrollTo(u.idx) break end
    end
  end
  UI.RefreshStatus()
  if UI.UpdateBadge then UI.UpdateBadge() end
end

-- Puts text in Find's search box (/cb find <text>).
function UI.Search(text)
  if find.search and type(text) == "string" then find.search:SetText(text) end
end

-- Opens CraftBoard on tab i (1 Find, 2 Requests, 3 Plan), wherever it lives.
function UI.ShowTab(i)
  if not TAB_NAMES[i] then return end
  activeTab = i
  local db = UIDB()
  if db then db.tab = i end
  if UI.IsShown() then SelectTab(i) else UI.Show() end
end


local BuildTabs, SideTab
do
-- Side tab, like ProfessionsOverviewTab / ProfessionsNTab: 55x55, common-sidetab (55x60)
-- behind a 50x50 icon at CENTER -4,0 (texcoords 0.031..0.969, masked by common-sidetab-mask),
-- common-sidetab-selected over it when selected (tab.cbSelected) and common-sidetab-hover as
-- highlight. The first hangs off the host's TOPRIGHT at 0,-60 (or where the host's placeTabs
-- puts it), the others 2 px below each other. Also Embed.lua's tab on ProfessionsFrame.
function SideTab(parent, name, iconFile, label)
  local tab = CreateFrame("Button", name, parent)
  tab:SetSize(55, 55)
  local bg = tab:CreateTexture(nil, "BACKGROUND")
  SetAtlasSized(bg, A.sidetab, 55, 60)
  bg:SetPoint("CENTER")
  local icon = tab:CreateTexture(nil, "ARTWORK")
  icon:SetSize(50, 50)
  icon:SetPoint("CENTER", -4, 0)
  icon:SetTexture(iconFile)
  icon:SetTexCoord(0.03125, 0.96875, 0.03125, 0.96875)
  local mask = HasAtlas(A.sidetabMask) and tab.CreateMaskTexture and tab:CreateMaskTexture()
  if mask and icon.AddMaskTexture then
    mask:SetAtlas(A.sidetabMask, false)
    mask:SetSize(55, 60)
    mask:SetPoint("CENTER")
    icon:AddMaskTexture(mask)
  else
    icon:SetSize(40, 40)
    icon:SetPoint("CENTER", -3, 0)
  end
  local selected = tab:CreateTexture(nil, "OVERLAY")
  SetAtlasSized(selected, A.sidetabSel, 55, 60)
  selected:SetPoint("CENTER")
  selected:Hide()
  tab.cbSelected = selected
  local hl = tab:CreateTexture(nil, "HIGHLIGHT")
  SetAtlasSized(hl, A.sidetabHover, 55, 60)
  hl:SetPoint("CENTER")
  tab:SetScript("OnEnter", function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(label)
    GameTooltip:Show()
  end)
  tab:SetScript("OnLeave", HideTooltip)
  tab.text = label
  tab.cbIcon = icon
  return tab
end

-- Side tabs when the common-sidetab atlases exist, else PanelTabButtonTemplate tabs under the
-- frame (else plain buttons). The first tab is placed by PlaceTabs.
function BuildTabs(f)
  sideTabs = HasAtlases(A.sidetab, A.sidetabSel, A.sidetabHover)
  local usePanel = not sideTabs and HasTemplate("PanelTabButtonTemplate")
  for i, label in ipairs(TAB_NAMES) do
    local tab
    if sideTabs then
      tab = SideTab(f, "CraftBoardFrameTab" .. i, TEX.tabs[i], label)
      if i > 1 then
        tab:SetPoint("TOPLEFT", tabs[i - 1], "BOTTOMLEFT", 0, -2)
      end
    elseif usePanel then
      local ok, t = pcall(CreateFrame, "Button", "CraftBoardFrameTab" .. i, f, "PanelTabButtonTemplate")
      if ok and t then
        tab = t
        tab.isPanelTab = true
        if tab.Text then tab.Text:SetText(label) else tab:SetText(label) end
        if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tab, 0) end
        if i > 1 then tab:SetPoint("LEFT", tabs[i - 1], "RIGHT", 3, 0) end
        tab.cbKind = "panel"
      else
        usePanel = false
      end
    end
    if not tab then
      tab = PanelButton(f, label, 90, 22)
      if i > 1 then tab:SetPoint("LEFT", tabs[i - 1], "RIGHT", 2, 0) end
      tab.cbKind = "plain"
    end
    tab:SetID(i)
    tab:SetScript("OnClick", function(self)
      if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB) end
      SelectTab(self:GetID())
    end)
    tabs[i] = tab
  end
end

end

-- Top tabs, for a host inside another window (Embed.lua's page in ProfessionsFrame, where side
-- tabs would sit in Blizzard's column and read as more professions): two flat text tabs at the
-- left of the status line row, above the search box. Selected: gold label on a faint gold tint
-- with a gold underline; otherwise a grey label. Template-free.
local ArrangeTabs
do
-- Start at the rank bar's x (110) so the row clears the portrait, like Blizzard's own header.
local TOPTAB_X, TOPTAB_H, TOPTAB_GAP, TOPTAB_PAD = 110, 20, 2, 8
local STATUS_GAP = 12                   -- status line starts this far right of the last top tab

-- Blizzard's standard panel tab (the gold tab shape used across the game) when the template
-- exists; otherwise a flat text tab with a gold underline.
local function TopTab(parent, i, label)
  if HasTemplate("PanelTabButtonTemplate") then
    local ok, b = pcall(CreateFrame, "Button", "CraftBoardTopTab" .. i, parent, "PanelTabButtonTemplate")
    if ok and b and b.SetText then
      b:SetText(label)
      if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, b, 0) end
      function b.cbSetSelected(on)
        if on then
          if PanelTemplates_SelectTab then PanelTemplates_SelectTab(b) end
        elseif PanelTemplates_DeselectTab then
          PanelTemplates_DeselectTab(b)
        end
      end
      b.text = label
      b:SetID(i)
      b:SetScript("OnClick", function(self)
        if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB) end
        SelectTab(self:GetID())
      end)
      return b
    end
  end
  local b = CreateFrame("Button", "CraftBoardTopTab" .. i, parent)
  b:SetHeight(TOPTAB_H)
  local tint = b:CreateTexture(nil, "BACKGROUND")
  tint:SetAllPoints()
  tint:SetColorTexture(GOLD_RGB[1], GOLD_RGB[2], GOLD_RGB[3], 0.12)
  local line = b:CreateTexture(nil, "ARTWORK")
  line:SetHeight(1)
  line:SetPoint("BOTTOMLEFT")
  line:SetPoint("BOTTOMRIGHT")
  line:SetColorTexture(GOLD_RGB[1], GOLD_RGB[2], GOLD_RGB[3], 0.8)
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.08)
  local fs = Label(b, label, Font("GameFontNormal"))
  fs:SetPoint("CENTER", 0, 0)
  b:SetWidth(ceil(StringWidth(fs)) + 2 * TOPTAB_PAD)
  function b.cbSetSelected(on)
    tint:SetShown(on)
    line:SetShown(on)
    local c = on and GOLD_RGB or MUTED
    fs:SetTextColor(c[1], c[2], c[3])
  end
  b.text, b.cbLabel = label, fs
  b:SetID(i)
  b:SetScript("OnClick", function(self)
    if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB) end
    SelectTab(self:GetID())
  end)
  return b
end

-- Side tabs, or (opts.topTabs) the top tabs, for host h; the status line where the RankBar
-- sits, or right of the top tabs when they reach into that spot.
function ArrangeTabs(h)
  local top = hostOpts[h] and hostOpts[h].topTabs and true or false
  for _, t in ipairs(tabs) do t:SetShown(not top) end
  if top and not topTabs[1] then
    UI.badgeCount = nil     -- new tab controls: the next UpdateBadge must label them
    for i, label in ipairs(TAB_NAMES) do topTabs[i] = TopTab(h, i, label) end
  end
  local right = 0
  for i, t in ipairs(topTabs) do
    if t:GetParent() ~= h then t:SetParent(h) end
    t:ClearAllPoints()
    if i == 1 then
      local th = t:GetHeight() or TOPTAB_H
      t:SetPoint("TOPLEFT", h, "TOPLEFT", TOPTAB_X, G.statusY + (th - G.statusH) / 2)
      right = TOPTAB_X
    else
      t:SetPoint("LEFT", topTabs[i - 1], "RIGHT", TOPTAB_GAP, 0)
      right = right + TOPTAB_GAP
    end
    right = right + (t:GetWidth() or 0)
    t.cbSetSelected(i == activeTab)
    t:SetShown(top)
  end
  local x = top and max(G.statusX, right + STATUS_GAP) or G.statusX
  statusLine:ClearAllPoints()
  statusLine:SetPoint("TOPLEFT", h, "TOPLEFT", x, G.statusY)
  -- With top tabs the line may reach the page's right edge (our page covers Blizzard's header
  -- buttons there); standalone it keeps the rank bar's width.
  local right = top and ((h:GetWidth() or WIDTH) - 16) or (G.statusX + G.statusW)
  statusLine:SetWidth(max(80, right - x))
  -- With top tabs the status reads as a separate, right-aligned note rather than a run-on
  -- of the tab row; standalone keeps Blizzard's left-aligned rank-bar spot.
  statusLine.text:SetJustifyH(top and "RIGHT" or "LEFT")
end

end

-- Requests count and gamepad ----------------------------------------------------------
do
-- "Requests (2)": other players' requests I can craft. Top tabs carry it in their label; side
-- tabs get a small number in the icon's corner.
function UI.UpdateBadge()
  if not tabs[2] then return end
  -- The Requests tab just counted while it is the one showing.
  local n = activeTab == 2 and reqs.count or (UI.RequestCount and UI.RequestCount()) or 0
  if n == UI.badgeCount then return end
  UI.badgeCount = n
  -- Embed.lua's CraftBoard tab and the minimap button show the same count.
  NS.Fire("BADGE_UPDATED", n)
  local label = n > 0 and format(L["%s (%d)"], TAB_NAMES[2], n) or TAB_NAMES[2]
  local side = tabs[2]
  if side.cbIcon then
    if not side.cbBadge then
      side.cbBadge = side:CreateFontString(nil, "OVERLAY", Font("NumberFontNormal", "GameFontHighlightSmall"))
      side.cbBadge:SetPoint("BOTTOMRIGHT", side, "BOTTOMRIGHT", -9, 7)
    end
    side.cbBadge:SetText(n > 0 and n or "")
  elseif side.SetText then
    side:SetText(label)
    if side.isPanelTab and PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, side, 0) end
  end
  local top = topTabs[2]
  if top then
    if top.cbLabel then
      top.cbLabel:SetText(label)
      top:SetWidth(ceil(StringWidth(top.cbLabel)) + 16)
    else
      top:SetText(label)
      if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, top, 0) end
    end
    if host and hostOpts[host] and hostOpts[host].topTabs then ArrangeTabs(host) end
  end
end

-- Gamepad (C_GamePad enabled and the "gamepad" option on): D-pad up / down steps through the
-- visible list, A does the selected row's main action (Find: whisper, else post; Requests: the
-- red button's), B closes, the shoulder buttons switch tabs. Other buttons pass through.
-- Off in combat (the pad belongs to the fight) and inside Blizzard's Professions window, which
-- has gamepad navigation of its own.
local function GamepadOn()
  if not (C_GamePad and C_GamePad.IsEnabled and C_GamePad.IsEnabled()) then return false end
  if InCombatLockdown and InCombatLockdown() then return false end
  if host and hostOpts[host] and hostOpts[host].topTabs then return false end
  return not (type(CraftBoardDB) == "table" and CraftBoardDB.gamepad == false)
end

local function Step(t, down)
  local list = t.results or {}
  if #list == 0 then return end
  local keyOf = t.keyOf or function(u) return u.recipeID end
  local cur = t.selectedKey and t.selectedKey() or selectedID
  local idx = 0
  for i, u in ipairs(list) do
    if keyOf(u) == cur then idx = i break end
  end
  idx = down and min(#list, idx + 1) or max(1, idx - 1)
  local key = keyOf(list[idx])
  if t.selectKey then t.selectKey(key) else UI.PickRecipe(key) end
  if t.list then t.list:ScrollTo(list[idx].idx) end
end

local function OnPad(self, button)
  local handled = true
  if button == "PADDUP" or button == "PADDDOWN" then
    Step(({ find, reqs, plan })[activeTab] or find, button == "PADDDOWN")
  elseif button == "PAD1" then
    if activeTab == 2 then
      UI.RequestPrimary()
    elseif activeTab == 3 then
      if plan.craft and plan.craft:IsEnabled() then plan.craft:Click() end
    elseif find.whisper and find.whisper:IsEnabled() then
      -- Opens the chat box; posting a request stays a mouse click.
      find.whisper:Click()
    end
  elseif button == "PAD2" then
    UI.Hide()
  elseif button == "PADLSHOULDER" or button == "PADRSHOULDER" then
    local d = button == "PADLSHOULDER" and -1 or 1
    SelectTab((activeTab - 1 + d) % #TAB_NAMES + 1)
  else
    handled = false
  end
  -- Let every button we don't use reach the game (keyboard propagation covers the gamepad on
  -- clients without a separate gamepad call).
  if not (InCombatLockdown and InCombatLockdown()) then
    local propagate = self.SetPropagateGamePadInput or self.SetPropagateKeyboardInput
    if propagate then pcall(propagate, self, not handled) end
  end
end

function UI.SetupGamepad()
  local on = GamepadOn()
  for _, p in ipairs(panels) do
    if p.EnableGamePadButton then
      if not p.cbPad then
        p.cbPad = true
        p:SetScript("OnGamePadButtonDown", OnPad)
      end
      pcall(p.EnableGamePadButton, p, on)
      -- Nothing held back while off (the last handled press may have left propagation off).
      local propagate = p.SetPropagateGamePadInput or p.SetPropagateKeyboardInput
      if not on and propagate and not (InCombatLockdown and InCombatLockdown()) then pcall(propagate, p, true) end
    end
  end
end

-- PLAYER_REGEN_DISABLED fires just before the lockdown: let go of the pad while it still can.
NS.Register("PLAYER_REGEN_DISABLED", function()
  for _, p in ipairs(panels) do
    if p.EnableGamePadButton then
      pcall(p.EnableGamePadButton, p, false)
      local propagate = p.SetPropagateGamePadInput or p.SetPropagateKeyboardInput
      if propagate then pcall(propagate, p, true) end
    end
  end
end)
NS.Register("PLAYER_REGEN_ENABLED", function() if panels[1] then UI.SetupGamepad() end end)
end

-- First tab's anchor on host h: the host's placeTabs(tab1, sideTabs) when given (returning false
-- or failing means "use the default"), else side tabs off its TOPRIGHT at 0,-60 and bottom tabs
-- under its bottom-left corner.
local function PlaceTabs(h)
  local tab = tabs[1]
  if not tab then return end
  tab:ClearAllPoints()
  local opts = hostOpts[h]
  if opts and opts.placeTabs then
    local ok, placed = pcall(opts.placeTabs, tab, sideTabs)
    if ok and placed ~= false then return end
    tab:ClearAllPoints()
  end
  if sideTabs then
    tab:SetPoint("TOPLEFT", h, "TOPRIGHT", 0, -60)
  elseif tab.cbKind == "panel" then
    tab:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 11, 2)
  else
    tab:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 8, 0)
  end
end

-- Resize grip in the bottom-right corner (Blizzard's window has none; ours can grow).
local function BuildResizeGrip(f)
  if not f.SetResizable then return end
  f:SetResizable(true)
  if f.SetResizeBounds then
    f:SetResizeBounds(G.minW, G.minH, G.maxW, G.maxH)
  else
    if f.SetMinResize then f:SetMinResize(G.minW, G.minH) end
    if f.SetMaxResize then f:SetMaxResize(G.maxW, G.maxH) end
  end
  local grip = CreateFrame("Button", nil, f)
  grip:SetSize(12, 12)
  grip:SetPoint("BOTTOMRIGHT", -1, 1)
  grip:SetFrameLevel((f:GetFrameLevel() or 0) + 20)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
  grip:SetScript("OnMouseUp", function()
    f:StopMovingOrSizing()
    if f.SetUserPlaced then f:SetUserPlaced(false) end
    local db = UIDB()
    if db then db.w, db.h = floor((f:GetWidth() or WIDTH) + 0.5), floor((f:GetHeight() or HEIGHT) + 0.5) end
    SavePosition(f)
    -- Reagent slots and card lines are fitted to the size: fit them again.
    UI.Refresh()
  end)
end

-- The window: Blizzard's portrait frame like ProfessionsFrame (PortraitFrameTemplate, else
-- ButtonFrameTemplate without its inset and button bar), else BasicFrameTemplateWithInset.
-- Returns the frame and whether it is the portrait (modern) style.
local function NewWindow(name)
  name = name or "CraftBoardFrame"
  for _, tmpl in ipairs({ "PortraitFrameTemplate", "ButtonFrameTemplate" }) do
    if HasTemplate(tmpl) then
      local ok, f = pcall(CreateFrame, "Frame", name, UIParent, tmpl)
      if ok and f then return f, true end
    end
  end
  return CreateFrame("Frame", name, UIParent, "BasicFrameTemplateWithInset"), false
end

SetPortrait = function(f, texture)
  if f.SetPortraitToAsset and pcall(f.SetPortraitToAsset, f, texture) then return end
  local tex = (f.PortraitContainer and f.PortraitContainer.portrait) or f.portrait
  if not tex and f.GetPortrait then
    local ok, t = pcall(f.GetPortrait, f)
    if ok then tex = t end
  end
  if not tex then return end
  if not (SetPortraitToTexture and pcall(SetPortraitToTexture, tex, texture)) then
    tex:SetTexture(texture)
  end
end

local function SetWindowTitle(f, text)
  if f.SetTitle and pcall(f.SetTitle, f, text) then return end
  local title = (f.TitleContainer and f.TitleContainer.TitleText) or f.TitleText
  if not title then
    title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if f.TitleBg then
      title:SetPoint("CENTER", f.TitleBg, "CENTER", 0, 0)
    else
      title:SetPoint("TOP", 0, -5)
    end
  end
  title:SetText(text)
end

-- ProfessionsFrame chrome: the metal nine-slice of PortraitFrameTemplate
-- (UI-Frame-PortraitMetal-CornerTopLeft, UI-Frame-Metal-* corners and edges; re-applied
-- when the template carries another layout), ProfessionsFrameBg as
-- Profession-Background-Overview at 2,-21 / -2,2 with the CraftingPage's
-- Profession-Background-Template2 over it at 3,-21 (665x570 at the default size), no
-- TopTileStreaks, no inset, no button bar. noPage skips the CraftingPage layer (small windows).
local function SetupChrome(f, noPage)
  if f.Inset then f.Inset:Hide() end
  if ButtonFrameTemplate_HideButtonBar and f.Inset then pcall(ButtonFrameTemplate_HideButtonBar, f) end
  if f.TopTileStreaks then f.TopTileStreaks:Hide() end
  local ns = f.NineSlice
  local corner = ns and ns.TopLeftCorner
  if corner and corner.GetAtlas and corner:GetAtlas() ~= "UI-Frame-PortraitMetal-CornerTopLeft"
    and NineSliceUtil and NineSliceUtil.ApplyLayoutByName and HasAtlas("UI-Frame-PortraitMetal-CornerTopLeft") then
    pcall(NineSliceUtil.ApplyLayoutByName, ns, "PortraitFrameTemplate")
  end
  if HasAtlas(A.frameBg) then
    local bg = f.Bg or (f.GetName and f:GetName() and _G[f:GetName() .. "Bg"])
    if not (bg and bg.SetAtlas) then bg = f:CreateTexture(nil, "BACKGROUND", nil, -6) end
    -- The template's Bg is a tiled rock texture: untile it before it takes the atlas.
    if bg.SetHorizTile then bg:SetHorizTile(false) end
    if bg.SetVertTile then bg:SetVertTile(false) end
    bg:SetAtlas(A.frameBg, false)
    bg:ClearAllPoints()
    bg:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -21)
    bg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    f.cbBg = bg
  end
  if not noPage and HasAtlas(A.pageBg) then
    local page = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    page:SetAtlas(A.pageBg, false)
    page:SetPoint("TOPLEFT", f, "TOPLEFT", 3, -21)
    page:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -5, 3)
    f.cbPageBg = page
  end
end

-- Content -------------------------------------------------------------------------
-- The Find / Requests pages, the status line and the Find / Requests tabs are built once, into
-- the first host that shows them, and move (SetParent + re-anchor) to whichever host shows
-- next: the standalone window or Embed.lua's page inside ProfessionsFrame. Only one host holds
-- them at a time; showing one hides the other. Every region inside uses the dump's
-- frame-relative offsets, so any 673x594-or-larger host gets the CraftingPage layout.

local function OnContentShown()
  dirty = false
  SelectTab(activeTab)
  UI.SetupGamepad()
  if NS.Onboarding then NS.Onboarding.Check("shown") end
end

local function OnContentHidden()
  HideTooltip()
  for _, box in ipairs({ find.search, reqs.search, plan.search, find.note, find.qty, plan.qty }) do
    if box and box.ClearFocus then box:ClearFocus() end
  end
  if reqs.search then reqs.search:ClearFocus() end
end

-- Builds the pages, status line and tabs into h (first time only).
local function BuildParts(h)
  host = h
  LEFT_W = SplitWidth(h:GetWidth())
  -- Pages cover the whole host, like CraftingPage.
  for i = 1, #TAB_NAMES do
    local p = CreateFrame("Frame", nil, h)
    p:SetAllPoints()
    p:Hide()
    panels[i] = p
  end
  statusLine = NewStatusLine(h)

  BuildFind(panels[1])
  BuildRequests(panels[2])
  BuildPlan(panels[3])
  BuildTabs(h)
  PlaceTabs(h)
  ArrangeTabs(h)
  splitDone = false
  LayoutSplit(h:GetWidth())

  local db = UIDB()
  if db then
    -- Saved by the old three-tab window (Find / Mine / Requests): Mine opens Find, Requests
    -- stays. Since 1.0 the third tab is Plan (tabLayout 3).
    if db.tabLayout ~= 3 then
      if db.tabs ~= 2 then
        if db.tab == 3 then db.tab = 2 elseif db.tab == 2 then db.tab = 1 end
        db.showAll = nil
      end
      db.tabs, db.tabLayout = nil, 3
    end
    if type(db.tab) == "number" and TAB_NAMES[db.tab] then
      activeTab = db.tab
    elseif MyRecipeCount() > 0 and PeerCounts() == 0 then
      -- First open with recipes recorded but nobody else on the board yet: Plan is the tab that
      -- is useful alone.
      activeTab = 3
    end
  end
end

-- Moves the content into h (building it on first use); hides the host it leaves.
local function Attach(h)
  if host == h then return end
  if not panels[1] then
    BuildParts(h)
    return
  end
  local old = host
  host = h
  local level = (h.GetFrameLevel and h:GetFrameLevel() or 0) + 1
  local strata = h.GetFrameStrata and h:GetFrameStrata()
  local function move(f)
    f:SetParent(h)
    if strata and f.SetFrameStrata then f:SetFrameStrata(strata) end
    if f.SetFrameLevel then f:SetFrameLevel(level) end
  end
  for _, p in ipairs(panels) do
    move(p)
    p:ClearAllPoints()
    p:SetAllPoints(h)
  end
  move(statusLine)
  for _, tab in ipairs(tabs) do move(tab) end
  for _, tab in ipairs(topTabs) do move(tab) end
  PlaceTabs(h)
  ArrangeTabs(h)
  splitDone = false
  LayoutSplit(h:GetWidth())
  if old and old ~= h and old:IsShown() then old:Hide() end
end

-- Registers h as a host for the content and returns its controller:
--   ctl:Show()           show h with the content in it (built on first show)
--   ctl:Hide()           hide h
--   ctl:IsShown()        the content is in h and h is visible
--   ctl:Refresh()        refresh the visible tab
--   ctl:SelectTab(i)     1 = Find, 2 = Requests (moves the content into h first)
--   ctl:TipAnchors()     Onboarding's anchors while the content is in h, else nil
-- opts.placeTabs(tab1, isSideTab): anchors the first Find / Requests tab for this host (the
-- default hangs side tabs off the host's TOPRIGHT at 0,-60). opts.topTabs: no side tabs in this
-- host; Find / Requests are small top tabs left of the status line instead (see TopTab).
-- h's OnShow moves the content in.
function UI.BuildContent(h, opts)
  if not h then return nil end
  if not hostOpts[h] then
    hostOpts[h] = opts or {}
    -- Hooks, not SetScript: the portrait templates may have their own show/hide handlers.
    h:HookScript("OnShow", function()
      Attach(h)
      OnContentShown()
    end)
    h:HookScript("OnHide", function()
      if host == h then OnContentHidden() end
    end)
    h:HookScript("OnSizeChanged", function(_, w)
      if host == h then LayoutSplit(w) end
    end)
  elseif opts then
    hostOpts[h] = opts
  end
  local ctl = { host = h }
  function ctl.Show()
    if h:IsShown() then
      Attach(h)
    else
      h:Show()
    end
  end
  function ctl.Hide() h:Hide() end
  function ctl.IsShown() return host == h and h:IsVisible() and true or false end
  function ctl.Refresh() UI.Refresh() end
  function ctl.SelectTab(i)
    if not TAB_NAMES[i] then return end
    Attach(h)
    SelectTab(i)
  end
  function ctl.TipAnchors()
    if host ~= h then return nil end
    return UI.TipAnchors()
  end
  return ctl
end

-- Standalone window -------------------------------------------------------------

local windowCtl

local function Create()
  local f, modern = NewWindow()
  frame, MODERN = f, modern
  f:Hide()
  f:SetSize(WIDTH, HEIGHT)
  -- MEDIUM, like Blizzard's panels, so the trade and merchant windows (and CraftBoard's buttons
  -- on them) are never under it; SetToplevel still raises it on click.
  f:SetFrameStrata("MEDIUM")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if self.SetUserPlaced then self:SetUserPlaced(false) end
    SavePosition(self)
  end)
  RestorePosition(f)

  SetWindowTitle(f, "CraftBoard")
  if modern then
    SetPortrait(f, TEX.portrait)
    portraitNow = TEX.portrait
    SetupChrome(f)
    PortraitTooltip(f)
  end
  BuildResizeGrip(f)
  -- The Professions window's own sounds (the embedded page gets Blizzard's).
  f:HookScript("OnShow", function()
    if PlaySound and SOUNDKIT and SOUNDKIT.UI_PROFESSIONS_WINDOW_OPEN then PlaySound(SOUNDKIT.UI_PROFESSIONS_WINDOW_OPEN) end
  end)
  f:HookScript("OnHide", function()
    if PlaySound and SOUNDKIT and SOUNDKIT.UI_PROFESSIONS_WINDOW_CLOSE then PlaySound(SOUNDKIT.UI_PROFESSIONS_WINDOW_CLOSE) end
  end)
  if UISpecialFrames then tinsert(UISpecialFrames, "CraftBoardFrame") end
  windowCtl = UI.BuildContent(f)
  -- Build now (hidden) so the window's parts exist before its first show, as before.
  if not panels[1] then BuildParts(f) end
end

-- Refresh the visible tab (keeps scroll position); marks dirty while hidden.
function UI.Refresh()
  if not (host and host:IsVisible()) then
    dirty = true
    return
  end
  dirty = false
  REFRESH[activeTab](true)
  UI.RefreshStatus()
  UI.UpdateBadge()
end

local scheduleRefresh = Debouncer(0.3, UI.Refresh)
-- Item names arrive in bursts on first open, each asking for more: refresh once they settle.
local scheduleNames = Debouncer(1, UI.Refresh)

-- Craft / Craft next buttons only: bags, casts, combat and the profession window change them.
local refreshCraftButtons = Debouncer(0.2, function()
  if not UI.IsShown() then return end
  if UI.RefreshPlanButtons then UI.RefreshPlanButtons() end
  if UI.RefreshRequestButtons then UI.RefreshRequestButtons() end
end)
for _, ev in ipairs({ "TRADE_SKILL_LIST_UPDATE", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }) do
  NS.Register(ev, refreshCraftButtons)
end
-- Opening or closing a profession window re-sorts Plan (the open profession first) as well.
NS.Register("TRADE_SKILL_SHOW", function() scheduleRefresh() end)
NS.Register("TRADE_SKILL_CLOSE", function() scheduleRefresh() end)

-- Once a minute while the window is up: cooldown times on crafter rows count down (Find: only
-- the few visible rows are re-filled), request ages and dimming move on (Requests), and the
-- status line follows players coming and going. Shown or not, the request count behind the
-- badges is taken again: requests age out without an event (chat asks stop counting after ten
-- minutes, posts expire after a day).
local lastOnline
if C_Timer and C_Timer.NewTicker then
  C_Timer.NewTicker(60, function()
    if not (UI.IsShown() and activeTab == 2) then
      reqs.countDirty = true
      if UI.RequestCount then UI.RequestCount() end
      if UI.UpdateBadge then UI.UpdateBadge() end
    end
    if not UI.IsShown() then return end
    local _, online = PeerCounts()
    if online ~= lastOnline then
      lastOnline = online
      UI.RefreshStatus()
    end
    if activeTab == 1 and find.entry and find.crafters then
      find.crafters:Render()
    elseif activeTab == 2 then
      UI.RefreshRequests(true)
      -- The recount that refresh made reaches the tab labels, the embedded tab and the broker.
      UI.UpdateBadge()
    end
  end)
end

if NS.RegisterCallback then
  for _, ev in ipairs({ "RECIPES_UPDATED", "PEERS_UPDATED", "INVENTORY_UPDATED", "POSTS_UPDATED",
    "CHAT_SEEN_UPDATED", "BUSY_UPDATED", "QUEUE_UPDATED", "COOLDOWNS_UPDATED", "CRAFTED_UPDATED", "IGNORE_UPDATED",
    "SKILLS_UPDATED" }) do
    NS.RegisterCallback(owner, ev, scheduleRefresh)
  end
  NS.RegisterCallback(owner, "ITEM_NAMES_UPDATED", scheduleNames)
  NS.RegisterCallback(owner, "CRAFT_UPDATED", refreshCraftButtons)
  NS.RegisterCallback(owner, "OPTIONS_UPDATED", function() if panels[1] then UI.SetupGamepad() end end)
end

-- Public ------------------------------------------------------------------------
-- Show / Toggle open CraftBoard where it lives: as a tab of Blizzard's Professions window when
-- Embed.lua can (see Embed.Open), else the standalone window.

-- The standalone window, whatever the embedding.
function UI.ShowWindow()
  if not frame then Create() end
  windowCtl.Show()
end

function UI.Window()
  return frame
end

-- CraftBoard is on screen (standalone or inside ProfessionsFrame).
function UI.IsShown()
  return host ~= nil and host:IsVisible() and true or false
end

function UI.Show()
  local E = NS.Embed
  if E and E.Open and E.Open() then return end
  UI.ShowWindow()
end

function UI.Hide()
  if frame and frame:IsShown() then frame:Hide() end
  local E = NS.Embed
  if E and E.Close and host and host ~= frame then E.Close() end
end

function UI.Toggle()
  if UI.IsShown() then UI.Hide() else UI.Show() end
end

-- Anchors for the first-run tips (Onboarding.lua), from whichever host holds the content; nil
-- until it has been built. embedded: the host is the page inside ProfessionsFrame.
function UI.TipAnchors()
  if not (host and panels[1]) then return nil end
  return {
    frame = host, shown = host:IsVisible() and true or false, findTab = activeTab == 1,
    findPanel = panels[1], list = find.list and find.list.box, status = statusLine, post = find.post,
    embedded = host ~= frame,
    -- The Plan tab's own tab (side tab standalone, top tab embedded) and whether it is showing.
    planTab = (hostOpts[host] and hostOpts[host].topTabs) and topTabs[3] or tabs[3],
    planShown = activeTab == 3, planPanel = panels[3],
  }
end

function UI.IsDirty()
  return dirty
end

-- The window's building blocks, for other CraftBoard windows (Welcome.lua, Embed.lua): the same
-- portrait frame, chrome, buttons, side tab and slot atlases, each with the fallbacks above.
UI.Kit = {
  NewWindow = NewWindow,            -- (globalName) -> frame, modern
  SetPortrait = SetPortrait,        -- (frame, texture)
  SetTitle = SetWindowTitle,        -- (frame, text)
  SetupChrome = SetupChrome,        -- (frame, noPage)
  RedButton = RedButton,            -- (parent, text, width, height)
  PanelButton = PanelButton,        -- (parent, text, width, height)
  SideTab = SideTab,                -- (parent, globalName, iconFile, tooltip) -> tab (.cbSelected)
  HasAtlas = HasAtlas,
  HasAtlases = HasAtlases,
  Font = Font,
  slotBg = A.slotBg, slotFrame = A.slotFrame,
  atlas = { frameBg = A.frameBg, pageBg = A.pageBg, sidetab = A.sidetab, sidetabMask = A.sidetabMask,
    sidetabSel = A.sidetabSel, sidetabHover = A.sidetabHover },
  portrait = TEX.portrait,
}
