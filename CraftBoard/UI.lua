-- CraftBoard UI: one movable, resizable window with three tabs (Find, Mine, Requests), laid
-- out like Blizzard's Professions crafting page: a left column (search box + Filter dropdown
-- over a bordered inset holding the recipe list, grouped under gold collapsible headers), a
-- right inset with the recipe page (round icon, name, description, reagent boxes, crafters)
-- and the frame's bottom button bar for the actions.
-- Plain frames only: no ScrollBox/DataProvider, no external UI libs. Every row and button is
-- created once (lists pool their visible rows); refreshes only re-fill them. Every Blizzard
-- template and atlas is checked before use, with a plain fallback.
local ADDON, NS = ...

local UI = {}
NS.UI = UI

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local format = string.format
local L = NS.L

local WIDTH, HEIGHT = 760, 520          -- default size
local MIN_W, MIN_H = 640, 460
local MAX_W, MAX_H = 1200, 900
-- The list column gets LEFT_FRAC of the column area (334 of 744 px at the default width);
-- the detail inset takes the rest. LEFT_W is the current value (LayoutSplit).
local LEFT_FRAC = 0.45
local COL_GAP = 6                       -- list column to detail inset
local SEARCH_ROW = 28                   -- search box + Filter row above the list inset
local SCROLLBAR_W = 22                  -- room for the legacy UIPanelScrollFrameTemplate bar
local MINIBAR_W = 14                    -- room for a MinimalScrollBar
-- Window chrome per frame style (offsets from the window edges). col*: the column area under
-- the portrait band; band*: the status line beside the portrait (where Blizzard shows the
-- rank bar); bar*: the bottom button bar row.
local STYLE = {
  modern = { colL = 8, colR = 8, colTop = 62, colB = 28, bandMid = 42, bandX = 64,
    barL = 12, barR = 28, barB = 4, tabX = 11, tabGap = 3, grip = 6 },
  legacy = { colL = 10, colR = 10, colTop = 52, colB = 34, bandMid = 38, bandX = 14,
    barL = 14, barR = 28, barB = 8, tabX = 10, tabGap = 4, grip = 4 },
}
local STY = STYLE.legacy                -- set by Create()
local MODERN = false
local LEFT_W = floor((WIDTH - 16) * LEFT_FRAC)
local RECIPE_H, CAT_H, PROF_H = 20, 29, 30   -- grouped list rows (Blizzard: 20 / 25 + gap)
local INDENT = 10                            -- per tree level, like the Professions list
local SUBROW_H = 18                          -- crafter rows
local REAGENT_H = 40                         -- reagent boxes (36 px icon)
local REQUEST_H = 44
local ICON_SIZE = 46                         -- recipe page icon (CircularGiantItemButton)
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local READY_TEX = "Interface\\RaidFrame\\ReadyCheck-Ready"
local PORTRAIT_TEX = "Interface\\Icons\\INV_Misc_Note_01"
local HIGHLIGHT_TEX = "Interface\\Buttons\\UI-Listbox-Highlight2"
local ROUND_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
-- Blizzard atlases (Blizzard_ProfessionsTemplates); each is checked with GetAtlasInfo.
local DIVIDER_ATLAS = "Options_HorizontalDivider"
local HEADER_L, HEADER_M, HEADER_R = "Professions-recipe-header-left", "Professions-recipe-header-middle", "Professions-recipe-header-right"
local COLLAPSE_ATLAS, EXPAND_ATLAS = "Professions-recipe-header-collapse", "Professions-recipe-header-expand"
local SELECTED_ATLAS, HOVER_ATLAS = "Professions_Recipe_Active", "Professions_Recipe_Hover"
local LIST_BG_ATLAS = "Professions-background-summarylist"
local RING_ATLAS = "auctionhouse-itemicon-border-white"
local MASK_ATLAS = "CircleMaskScalable"
local DOT = " \194\183 "                -- " · "
local EN_DASH = "\226\128\147"
local GREEN, RED, GREY = "|cff40ff40", "|cffff4040", "|cff9d9d9d"
local MUTED = { 0.62, 0.62, 0.62 }
local GOLD_RGB = { 1, 0.82, 0 }
local ONLINE_RGB = { 0.25, 1, 0.25 }
local SHORT_RGB = { 1, 0.25, 0.25 }
local RING_RGB = { 0.62, 0.5, 0.32 }    -- ring tint for common items (and the plain ring)

local EMPTY_RECIPES = L["Open a profession window to record your recipes."]
local EMPTY_PEERS = L["No one on the board yet \226\128\148 guildmates who install CraftBoard appear here."]

local frame                    -- main window, created on first show
local tabs, panels = {}, {}
local activeTab = 1
local selectedID               -- recipeID selected in Find / Mine (shared)
local dirty = true
local owner = {}               -- callback owner; CallbackHandler refuses NS itself
local find, mine, reqs = {}, {}, {}
local footer
local portraitNow

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
  return ItemIcon(itemID) or SpellIcon(recipeID) or QUESTION
end

local function ItemName(itemID)
  local n = NS.Inventory and NS.Inventory.ItemName and NS.Inventory.ItemName(itemID)
  return n or format(L["Item %s"], tostring(itemID))
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

-- Name colour for a recipe's output item. Enchants (no item) stay white; an uncached item is
-- white until it loads: asking for its name queues the load, and ITEM_NAMES_UPDATED then
-- refreshes the visible tab, which re-fills the rows in colour.
local function NameRGB(itemID)
  local q = ItemQuality(itemID)
  if q == nil and type(itemID) == "number" and NS.Inventory and NS.Inventory.ItemName then
    NS.Inventory.ItemName(itemID)
  end
  return QualityRGB(q)
end

local function QualityHex(q)
  if type(q) ~= "number" then return "|cffffffff" end
  local r, g, b = QualityRGB(q)
  return format("|cff%02x%02x%02x", floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5))
end

local function ShowTooltip(anchor, itemID, recipeID)
  if not GameTooltip then return end
  -- Anchor to the window's right edge so the tooltip never covers the recipe page.
  if frame and frame.GetRight then
    GameTooltip:SetOwner(frame, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    GameTooltip:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, -30)
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

local function Divider(parent)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetColorTexture(1, 1, 1, 0.10)
  return t
end

local function HasAtlas(name)
  if not (C_Texture and C_Texture.GetAtlasInfo) then return false end
  local ok, info = pcall(C_Texture.GetAtlasInfo, name)
  return ok and info ~= nil
end

-- Thin horizontal rule: Blizzard's settings divider when that atlas exists, else a faint line.
local function HRule(parent)
  local t = parent:CreateTexture(nil, "ARTWORK")
  if HasAtlas(DIVIDER_ATLAS) then
    t:SetAtlas(DIVIDER_ATLAS, false)
  else
    t:SetColorTexture(1, 1, 1, 0.12)
  end
  t:SetHeight(1)
  return t
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
local function OpenWhisper(name, itemID, qty)
  local tell = ChatFrame_SendTell or (ChatFrameUtil and ChatFrameUtil.SendTell)
  local active = ChatEdit_GetActiveWindow or (ChatFrameUtil and ChatFrameUtil.GetActiveWindow)
  if tell and active and itemID then
    local ok = pcall(tell, Short(name))
    local box = ok and active()
    if box and box.Insert then
      box:Insert(RequestText(itemID, qty))
      return true
    end
  end
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

-- Full-size decorative texture on an inset (above its own background).
local function InsetArt(inset, atlas, alpha)
  if not HasAtlas(atlas) then return nil end
  local t = inset:CreateTexture(nil, "BACKGROUND", nil, 1)
  t:SetPoint("TOPLEFT", 3, -3)
  t:SetPoint("BOTTOMRIGHT", -3, 3)
  t:SetAtlas(atlas, false)
  t:SetAlpha(alpha or 1)
  return t
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

local function NewFilterButton(parent, entries, isDefault, reset)
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

-- Decorative page background of a detail inset (t.bg), per profession, at low alpha.
local function SetDetailBackground(t, profID)
  if not t.bg then return end
  local atlas = BackgroundAtlas(profID)
  if atlas == t.bgAtlas and t.bgSet then return end
  t.bgAtlas, t.bgSet = atlas, true
  if atlas then
    t.bg:SetAtlas(atlas, false)
    t.bg:SetAlpha(0.45)
    t.bg:Show()
  else
    t.bg:Hide()
  end
end

-- Profession icon: stored by the scan on one of my chars, else asked from the client.
local function ProfIcon(profID)
  if profID == nil then return nil end
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
-- A plain ScrollFrame whose child is sized for every item; only the visible rows exist and
-- are re-anchored on scroll. Rows may differ in height (opts.heightOf(item), default
-- rowHeight): item tops are summed once per SetItems. opts: bar (scrollbar, default true),
-- inline (empty text top-left instead of centered), stripes (default true). The bar is a
-- retail MinimalScrollBar wired by ScrollUtil when both exist, else the legacy
-- UIPanelScrollFrameTemplate.
local List = {}
List.__index = List

local function NewList(name, parent, rowHeight, makeRow, fillRow, opts)
  opts = opts or {}
  local self = setmetatable({ rowHeight = rowHeight, items = {}, tops = {}, total = 0, rows = {},
    makeRow = makeRow, fillRow = fillRow, heightOf = opts.heightOf, stripes = opts.stripes ~= false }, List)
  local box = CreateFrame("Frame", nil, parent)
  self.box = box

  local scroll, bar, barW, legacy
  if opts.bar ~= false then
    -- ScrollUtil sets the frame's OnVerticalScroll / OnScrollRangeChanged scripts, so it runs
    -- before the HookScript calls below.
    if ScrollUtil and ScrollUtil.InitScrollFrameWithScrollBar and HasTemplate("MinimalScrollBar") then
      local ok, b = pcall(CreateFrame, "Frame", nil, box, "MinimalScrollBar")
      if ok and b then
        scroll = CreateFrame("ScrollFrame", name, box)
        if pcall(ScrollUtil.InitScrollFrameWithScrollBar, scroll, b) then
          bar, barW = b, MINIBAR_W
          bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 5, -1)
          bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 5, 1)
        else
          b:Hide()               -- keep the plain frame; the wheel still scrolls it
        end
      end
    end
    if not scroll and HasTemplate("UIPanelScrollFrameTemplate") then
      local ok, f = pcall(CreateFrame, "ScrollFrame", name, box, "UIPanelScrollFrameTemplate")
      if ok and f then
        scroll, barW, legacy = f, SCROLLBAR_W, true
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
    child:SetWidth(max(1, w or s:GetWidth() or 1))
    self:Render()
  end)

  self.empty = Label(box, nil, "GameFontDisable")
  if opts.inline then
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
  local tops, y = {}, 0
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
  self.child:SetWidth(max(1, self.scroll:GetWidth() or 1))
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
    row:SetPoint("TOPLEFT", self.child, "TOPLEFT", 0, -tops[idx])
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
local function RowBase(parent, rowH, blizzard)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(rowH)
  local stripe = row:CreateTexture(nil, "BACKGROUND", nil, -1)
  stripe:SetAllPoints()
  stripe:SetColorTexture(1, 1, 1, 0.025)
  stripe:Hide()
  row.stripe = stripe
  local sel = row:CreateTexture(nil, "BACKGROUND")
  sel:SetAllPoints()
  if blizzard and HasAtlas(SELECTED_ATLAS) then
    sel:SetAtlas(SELECTED_ATLAS, false)
  else
    sel:SetColorTexture(1, 0.82, 0, 0.14)
  end
  sel:Hide()
  row.sel = sel
  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  local hlAlpha = 1
  if blizzard and HasAtlas(HOVER_ATLAS) then
    hl:SetAtlas(HOVER_ATLAS, false)
    hlAlpha = 0.5
  elseif hl:SetTexture(HIGHLIGHT_TEX) then
    hl:SetBlendMode("ADD")
    hl:SetVertexColor(1, 1, 1, 0.5)
  else
    hl:SetColorTexture(1, 1, 1, 0.08)
  end
  row.hl = hl
  row.hlAlpha = hlAlpha
  hl:SetAlpha(hlAlpha)
  row:SetScript("OnLeave", HideTooltip)
  return row
end

local function ShowParts(parts, on)
  for i = 1, #parts do parts[i]:SetShown(on) end
end

-- Grouped recipe list row: a recipe (icon, name, right-aligned status, check) or a group
-- header. Category headers use the Professions list's header bar (gold label, collapse
-- toggle on the right); profession headers (the "All professions" view) a large gold label
-- with the profession icon over a rule. One pooled row type serves all three.
local function GroupRowFactory(onSelect, onToggle)
  return function(parent, rowH)
    local row = RowBase(parent, rowH, true)
    -- Recipe parts.
    row.icon = BorderedIcon(row, 16)
    row.check = row:CreateTexture(nil, "ARTWORK")
    row.check:SetSize(14, 14)
    row.check:SetPoint("RIGHT", -4, 0)
    row.check:SetTexture(READY_TEX)
    row.status = Muted(Label(row, nil, "GameFontHighlightSmall"))
    row.status:SetPoint("RIGHT", -22, 0)       -- no width: sized to its text, name takes the rest
    row.status:SetJustifyH("RIGHT")
    row.name = Label(row, nil, "GameFontHighlight")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
    row.name:SetPoint("RIGHT", row.status, "LEFT", -6, 0)
    row.recipeParts = { row.icon, row.icon.border, row.name, row.status }

    -- Category header bar, bottom-aligned 25 px like ProfessionsRecipeListCategoryTemplate.
    row.catParts = {}
    if HasAtlas(HEADER_L) and HasAtlas(HEADER_M) and HasAtlas(HEADER_R) then
      local l = row:CreateTexture(nil, "BACKGROUND", nil, 1)
      l:SetAtlas(HEADER_L, true)
      local r = row:CreateTexture(nil, "BACKGROUND", nil, 1)
      r:SetAtlas(HEADER_R, true)
      r:SetPoint("RIGHT", row, "BOTTOMRIGHT", 0, 14)
      local m = row:CreateTexture(nil, "BACKGROUND", nil, 1)
      m:SetAtlas(HEADER_M, false)
      m:SetPoint("TOPLEFT", l, "TOPRIGHT")
      m:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT")
      row.barLeft = l
      row.catParts = { l, m, r }
    else
      local bg = row:CreateTexture(nil, "BACKGROUND", nil, 1)
      bg:SetColorTexture(0.12, 0.09, 0.03, 0.9)
      bg:SetPoint("BOTTOMRIGHT", 0, 2)
      bg:SetHeight(23)
      local line = row:CreateTexture(nil, "BACKGROUND", nil, 2)
      line:SetColorTexture(GOLD_RGB[1], GOLD_RGB[2], GOLD_RGB[3], 0.7)
      line:SetPoint("BOTTOMLEFT", bg, "BOTTOMLEFT")
      line:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT")
      line:SetHeight(1)
      row.barLeft = bg
      row.catParts = { bg, line }
    end

    -- Profession header: icon, large label, count, rule.
    row.profIcon = BorderedIcon(row, 18)
    row.count = Muted(Label(row, nil, "GameFontHighlightSmall"))
    row.count:SetPoint("RIGHT", row, "BOTTOMRIGHT", -30, 13)
    row.count:SetJustifyH("RIGHT")
    row.rule = HRule(row)
    row.rule:SetPoint("BOTTOMRIGHT", 0, 1)
    row.profParts = { row.profIcon, row.profIcon.border, row.count, row.rule }

    -- Shared by both headers: gold label and the collapse toggle.
    row.header = Label(row, nil, "GameFontNormal")
    if HasAtlas(COLLAPSE_ATLAS) and HasAtlas(EXPAND_ATLAS) then
      row.toggle = row:CreateTexture(nil, "ARTWORK")
      row.toggleAtlas = true
    else
      row.toggleAtlas = false
      row.toggle = Label(row, nil, "GameFontNormalLarge")
      row.toggle:SetJustifyH("CENTER")
    end
    row.toggle:SetPoint("RIGHT", row, "BOTTOMRIGHT", -10, 13)
    row.headerParts = { row.header, row.toggle }

    row:SetScript("OnEnter", function(self)
      local it = self.item
      if it and not it.kind then ShowTooltip(self, it.outputItemID, it.recipeID) end
    end)
    row:SetScript("OnClick", function(self)
      local it = self.item
      if not it then return end
      if it.kind then onToggle(it) else onSelect(it) end
    end)
    return row
  end
end

local function GroupFill(fillEntry)
  return function(row, it)
    row.item = it
    local kind = it.kind
    local x = (it.depth or 0) * INDENT
    ShowParts(row.recipeParts, kind == nil)
    ShowParts(row.catParts, kind == "cat")
    ShowParts(row.profParts, kind == "prof")
    ShowParts(row.headerParts, kind ~= nil)
    if kind == nil then
      row.entry = it
      row.hl:SetAlpha(row.hlAlpha)
      row.icon:ClearAllPoints()
      row.icon:SetPoint("LEFT", x + 6, 0)
      fillEntry(row, it)
      return
    end
    row.entry = nil
    row.check:Hide()
    row.sel:Hide()
    row.hl:SetAlpha(0.35)
    row.header:ClearAllPoints()
    if kind == "cat" then
      row.barLeft:ClearAllPoints()
      if row.catParts[3] then
        row.barLeft:SetPoint("LEFT", row, "BOTTOMLEFT", x, 14)
      else
        row.barLeft:SetPoint("BOTTOMLEFT", x, 2)
      end
      row.header:SetFontObject("GameFontNormal")
      row.header:SetPoint("LEFT", row, "BOTTOMLEFT", x + 10, 14)
    else
      row.profIcon:ClearAllPoints()
      row.profIcon:SetPoint("LEFT", row, "BOTTOMLEFT", x + 3, 13)
      local icon = ProfIcon(it.prof)
      row.profIcon:SetTexture(icon or QUESTION)
      row.profIcon:SetShown(icon ~= nil)
      row.profIcon.border:SetShown(icon ~= nil)
      row.header:SetFontObject(Font("GameFontNormalLarge", "GameFontNormal"))
      row.header:SetPoint("LEFT", row, "BOTTOMLEFT", x + (icon and 27 or 3), 13)
      row.count:SetText(it.count or "")
      row.rule:ClearAllPoints()
      row.rule:SetPoint("BOTTOMLEFT", x, 1)
      row.rule:SetPoint("BOTTOMRIGHT", 0, 1)
    end
    row.header:SetPoint("RIGHT", row, "BOTTOMRIGHT", kind == "prof" and -60 or -30, 13)
    row.header:SetText(it.name)
    row.header:SetTextColor(GOLD_RGB[1], GOLD_RGB[2], GOLD_RGB[3])
    if row.toggleAtlas then
      row.toggle:SetAtlas(it.collapsed and EXPAND_ATLAS or COLLAPSE_ATLAS, true)
    else
      row.toggle:SetText(it.collapsed and "+" or EN_DASH)
      row.toggle:SetTextColor(GOLD_RGB[1], GOLD_RGB[2], GOLD_RGB[3])
    end
  end
end

local function GroupHeight(it)
  if it.kind == "prof" then return PROF_H end
  if it.kind == "cat" then return CAT_H end
  return RECIPE_H
end

-- Recipe page header ------------------------------------------------------
-- Like the Professions recipe page: a round 46 px icon in a ring (Blizzard's
-- CircularGiantItemButton: round mask + the quality-tinted auction house ring; a masked
-- bronze disc when that atlas is missing), the quality-coloured name beside it, a muted
-- "Profession · Rank" line under the name and the item's description under the icon.
-- Without mask support the icon is the square 40 px bordered one.

local function FitHeader(h)
  local t = h.title
  t:SetFontObject(Font("GameFontNormalMed3", "GameFontNormalLarge"))
  if t.SetMaxLines then t:SetMaxLines(1) end
  if t.SetWordWrap then t:SetWordWrap(false) end
  local avail = t:GetWidth() or 0
  local wrap = avail > 0 and StringWidth(t) > avail
  if wrap then
    t:SetFontObject("GameFontNormal")
    if t.SetWordWrap then t:SetWordWrap(true) end
    if t.SetMaxLines then t:SetMaxLines(2) end
  end
  h.sub:SetShown(not wrap)
  -- SetFontObject resets the colour to the font's own: re-apply the item quality colour.
  if h.rgb then t:SetTextColor(h.rgb[1], h.rgb[2], h.rgb[3]) end
end

local function RoundMask(holder, target, inset)
  local mask = holder.CreateMaskTexture and holder:CreateMaskTexture()
  if not (mask and target.AddMaskTexture) then return nil end
  if HasAtlas(MASK_ATLAS) then
    mask:SetAtlas(MASK_ATLAS, false)
  else
    mask:SetTexture(ROUND_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  end
  mask:SetPoint("TOPLEFT", target, "TOPLEFT", inset, -inset)
  mask:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", -inset, inset)
  target:AddMaskTexture(mask)
  return mask
end

local function NewHeader(parent)
  local h = {}
  local holder = CreateFrame("Frame", nil, parent)
  holder:SetSize(ICON_SIZE + 8, ICON_SIZE + 8)
  holder:SetPoint("TOPLEFT", 0, 0)
  holder:EnableMouse(true)
  holder:SetScript("OnEnter", function(self)
    if h.recipeID then ShowTooltip(self, h.itemID, h.recipeID) end
  end)
  holder:SetScript("OnLeave", HideTooltip)
  h.holder = holder

  local icon = holder:CreateTexture(nil, "ARTWORK")
  icon:SetSize(ICON_SIZE, ICON_SIZE)
  icon:SetPoint("CENTER")
  icon:SetTexCoord(0.078125, 0.921875, 0.078125, 0.921875)
  h.icon = icon
  if RoundMask(holder, icon, 2) then
    h.round = true
    if HasAtlas(RING_ATLAS) then
      local ring = holder:CreateTexture(nil, "OVERLAY")
      ring:SetAtlas(RING_ATLAS, false)
      ring:SetSize(ICON_SIZE + 22, ICON_SIZE + 22)
      ring:SetPoint("CENTER")
      h.ring = ring
    else
      local disc = holder:CreateTexture(nil, "BORDER")
      disc:SetSize(ICON_SIZE + 2, ICON_SIZE + 2)
      disc:SetPoint("CENTER")
      disc:SetColorTexture(RING_RGB[1], RING_RGB[2], RING_RGB[3], 1)
      RoundMask(holder, disc, 0)
      h.ring = disc
    end
  else
    icon:SetSize(40, 40)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local border = holder:CreateTexture(nil, "BORDER")
    border:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0, 0, 0, 0.85)
    icon.border = border
  end

  local textX = ICON_SIZE + 16
  h.title = Label(parent, nil, Font("GameFontNormalMed3", "GameFontNormalLarge"))
  h.title:SetPoint("TOPLEFT", textX, -9)
  h.title:SetPoint("TOPRIGHT", -2, -9)
  h.sub = Muted(Label(parent, nil, "GameFontHighlightSmall"))
  h.sub:SetPoint("TOPLEFT", textX, -32)
  h.sub:SetPoint("TOPRIGHT", -2, -32)
  h.desc = Label(parent, nil, "GameFontHighlight")
  h.desc:SetPoint("TOPLEFT", holder, "BOTTOMLEFT", 0, -6)
  h.desc:SetPoint("RIGHT", parent, "RIGHT", -2, 0)
  if h.desc.SetWordWrap then h.desc:SetWordWrap(true) end
  if h.desc.SetMaxLines then h.desc:SetMaxLines(3) end
  parent:HookScript("OnSizeChanged", function() FitHeader(h) end)
  return h
end

local function FillHeader(h, recipeID, itemID, name, sub, desc)
  h.recipeID, h.itemID = recipeID, itemID
  h.icon:SetTexture(RecipeIcon(recipeID, itemID))
  local itemName = itemID and NS.Inventory and NS.Inventory.ItemName and NS.Inventory.ItemName(itemID)
  h.title:SetText(itemName or name or "")
  local r, g, b = NameRGB(itemID)
  h.rgb = { r, g, b }
  h.sub:SetText(sub or "")
  h.hasDesc = type(desc) == "string" and desc ~= ""
  h.desc:SetText(h.hasDesc and desc or "")
  h.desc:SetShown(h.hasDesc)
  if h.ring and h.ring.SetVertexColor then
    local q = ItemQuality(itemID)
    if type(q) == "number" and q >= 2 then
      h.ring:SetVertexColor(QualityRGB(q))
    else
      h.ring:SetVertexColor(RING_RGB[1], RING_RGB[2], RING_RGB[3])
    end
  end
  FitHeader(h)
end

-- Anchor a section label ("Reagents:") under the header: under the description when there
-- is one, else under the icon.
local function AnchorBelowHeader(h, fs)
  fs:ClearAllPoints()
  if h.hasDesc then
    fs:SetPoint("TOPLEFT", h.desc, "BOTTOMLEFT", 0, -12)
  else
    fs:SetPoint("TOPLEFT", h.holder, "BOTTOMLEFT", 0, -8)
  end
end

-- Detail rows ---------------------------------------------------------------

-- Crafter: name green when online, grey when offline; me and my alts marked.
local function CrafterRow(parent, rowH)
  local row = RowBase(parent, rowH)
  row.state = Muted(Label(row, nil, "GameFontHighlightSmall"))
  row.state:SetPoint("RIGHT", -4, 0)
  row.state:SetJustifyH("RIGHT")
  row.name = Label(row, nil, "GameFontHighlight")
  row.name:SetPoint("LEFT", 4, 0)
  row.name:SetPoint("RIGHT", row.state, "LEFT", -6, 0)
  row:SetScript("OnEnter", function(self)
    local c = self.crafter
    if c and not c.mine then
      TextTooltip(self, Short(c.name), find.itemID and L["Click to whisper a request."] or nil)
    end
  end)
  row:SetScript("OnClick", function(self)
    local c = self.crafter
    if not c or c.mine then return end
    find.crafter = c.name
    find.crafters:Render()
    UI.UpdateWhisper()
    if find.itemID then OpenWhisper(c.name, find.itemID, ReadQty(find.qty)) end
  end)
  return row
end

local function FillCrafterRow(row, c)
  row.crafter = c
  row.name:SetText(Short(c.name))
  if c.online then
    row.name:SetTextColor(ONLINE_RGB[1], ONLINE_RGB[2], ONLINE_RGB[3])
  else
    row.name:SetTextColor(MUTED[1], MUTED[2], MUTED[3])
  end
  if c.mine then
    row.state:SetText("|cffffd100" .. (c.name == NS.Me and L["you"] or L["alt"]) .. "|r")
  elseif c.online then
    row.state:SetText(GREEN .. L["online"] .. "|r")
  else
    row.state:SetText(L["offline"])
  end
  row:EnableMouse(not c.mine)
  row.sel:SetShown(not c.mine and c.name == find.crafter)
end

-- Reagent box, like the recipe page's reagent slots: 36 px icon, "have/need Name" beside it,
-- red when short, white when enough.
local function ReagentRow(parent, rowH)
  local row = RowBase(parent, rowH)
  row.icon = BorderedIcon(row, 36)
  row.icon:SetPoint("LEFT", 2, 0)
  row.name = Label(row, nil, "GameFontHighlight")
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
  row.name:SetPoint("RIGHT", -4, 0)
  row:SetScript("OnEnter", function(self) ShowTooltip(self, self.itemID) end)
  -- Like a shift-click: drop the item link into an open chat box (handy for asking guild).
  row:SetScript("OnClick", function(self) InsertLink(ItemLink(self.itemID)) end)
  return row
end

-- reagent: {itemID=, need=, have=}
local function FillReagentRow(row, r)
  row.itemID = r.itemID
  row.icon:SetTexture(ItemIcon(r.itemID) or QUESTION)
  row.name:SetText(format(L["%d/%d %s"], r.have, r.need, ItemName(r.itemID)))
  if r.have >= r.need then
    row.name:SetTextColor(1, 1, 1)
  else
    row.name:SetTextColor(SHORT_RGB[1], SHORT_RGB[2], SHORT_RGB[3])
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
      if type(p) == "table" and out[id] == nil then
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
local function ProfLine(names, profID)
  local line = ProfName(names, profID)
  local rank = MyProfRank(profID)
  if rank then line = line .. DOT .. rank end
  return line
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

local function BuildUniverse()
  local R, I = NS.Recipes, NS.Inventory
  local all = R and R.Search and R.Search("") or {}
  local names = ProfNames()
  local myRecipes = R and R.Mine and R.Mine() or {}
  local profCount = {}
  universe, universeByID = {}, {}
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
        if c.name == NS.Me then u.me = true elseif not u.alt then u.alt = Short(c.name) end
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
          for _, e in ipairs(list) do
            e.depth = depth + 1
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

-- The profession filter is shared by Find and Mine (CraftBoardDB.ui.findProf); each tab only
-- honours it when that profession is in its list.
local function ValidProf(profList, id)
  if id == nil then return nil end
  for _, pr in ipairs(profList or {}) do
    if pr.id == id then return id end
  end
  return nil
end

local function SortedProfs(profCount, names)
  local out = {}
  for id in pairs(profCount) do out[#out + 1] = { id = id, name = ProfName(names, id) } end
  table.sort(out, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return tostring(a.id) < tostring(b.id)
  end)
  return out
end

local function SetProf(id)
  local db = UIDB()
  if db then db.findProf = id end
  if activeTab == 2 then UI.FilterMine(false) else UI.FilterFind(false) end
end

local SetPortrait   -- Window section

-- Portrait: the selected profession's icon, else CraftBoard's own.
local function UpdatePortrait(profID)
  if not (frame and MODERN) then return end
  local tex = (profID ~= nil and ProfIcon(profID)) or PORTRAIT_TEX
  if tex == portraitNow then return end
  portraitNow = tex
  SetPortrait(frame, tex)
end

-- Search box --------------------------------------------------------------------
-- Top-left of a list column, like the Professions list. Shared keys for Find and Mine (t):
-- Enter picks the arrowed or first visible recipe, arrows move the selection through the
-- visible recipes (t.results), Escape clears the text first and then closes the window.
local function NewSearchBox(name, parent, t)
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
  -- Soft hint while empty: the template's own instructions text, else our own label.
  local hint = box.Instructions
  if not hint then
    hint = Label(box, nil, "GameFontDisableSmall")
    hint:SetPoint("LEFT", 2, 0)
    box.cbHint = hint
  end
  hint:SetText(L["Search"])

  box:SetScript("OnEnterPressed", function(self)
    local list = t.results or {}
    local pick = (t.arrowed and selectedID) or (list[1] and list[1].recipeID)
    if pick then UI.SelectRecipe(pick) end
    self:ClearFocus()
  end)
  box:SetScript("OnEscapePressed", function(self)
    if (self:GetText() or "") ~= "" then
      self:SetText("")
    else
      self:ClearFocus()
      if frame then frame:Hide() end
    end
  end)
  box:SetScript("OnArrowPressed", function(_, key)
    local list = t.results or {}
    if #list == 0 then return end
    local idx = 0
    for i, u in ipairs(list) do
      if u.recipeID == selectedID then idx = i break end
    end
    if key == "DOWN" then
      idx = min(#list, idx + 1)
    elseif key == "UP" then
      idx = max(1, idx - 1)
    else
      return
    end
    t.arrowed = true
    UI.SelectRecipe(list[idx].recipeID)
    t.list:ScrollTo(list[idx].idx)
  end)
  box:HookScript("OnTextChanged", function(self)
    if self.cbHint then self.cbHint:SetShown((self:GetText() or "") == "") end
    t.arrowed = false
    t.refilter(false)
  end)
  return box
end

-- Left column: search box + Filter button over the list inset. Right: the detail inset with
-- its page background. Returns the detail content frame.
local function BuildColumns(p, t, listName, fillEntry, entries, isDefault, reset)
  local left = CreateFrame("Frame", nil, p)
  left:SetPoint("TOPLEFT")
  left:SetPoint("BOTTOMLEFT")
  left:SetWidth(LEFT_W)
  t.left = left

  t.filterEntries = entries
  t.filter = NewFilterButton(left, entries, isDefault, reset)
  t.filter:SetPoint("TOPRIGHT", left, "TOPRIGHT", -4, -4)
  t.search = NewSearchBox(listName == "CraftBoardFindScroll" and "CraftBoardSearchBox" or "CraftBoardMineSearchBox", left, t)
  t.search:SetPoint("TOPLEFT", left, "TOPLEFT", 10, -4)
  t.search:SetPoint("RIGHT", t.filter, "LEFT", -8, 0)

  local inset = NewInset(left)
  inset:SetPoint("TOPLEFT", 0, -SEARCH_ROW)
  inset:SetPoint("BOTTOMRIGHT")
  t.listInset = inset
  InsetArt(inset, LIST_BG_ATLAS, 1)
  t.list = NewList(listName, inset, RECIPE_H,
    GroupRowFactory(function(it) UI.SelectRecipe(it.recipeID) end, function(it) ToggleGroup(t, it) end),
    GroupFill(fillEntry), { heightOf = GroupHeight, stripes = false })
  t.list.box:SetPoint("TOPLEFT", 4, -4)
  t.list.box:SetPoint("BOTTOMRIGHT", -4, 4)

  local dInset = NewInset(p)
  dInset:SetPoint("TOPLEFT", left, "TOPRIGHT", COL_GAP, 0)
  dInset:SetPoint("BOTTOMRIGHT")
  t.detailInset = dInset
  t.bg = dInset:CreateTexture(nil, "BACKGROUND", nil, 1)
  t.bg:SetPoint("TOPLEFT", 3, -3)
  t.bg:SetPoint("BOTTOMRIGHT", -3, 3)
  t.bg:Hide()
  local d = CreateFrame("Frame", nil, dInset)
  d:SetPoint("TOPLEFT", 14, -12)
  d:SetPoint("BOTTOMRIGHT", -12, 10)
  t.detail = d
  return d
end

-- Bottom button bar row (the frame's own bar on the portrait frame): a strip along the
-- window's bottom edge, shown with its tab.
local function NewBar(p)
  local bar = CreateFrame("Frame", nil, p)
  bar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", STY.barL, STY.barB)
  bar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -STY.barR, STY.barB)
  bar:SetHeight(22)
  -- Without the portrait frame's own button bar, a rule marks the action row.
  if not (MODERN and ButtonFrameTemplate_ShowButtonBar) then
    local rule = HRule(bar)
    rule:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", 0, 3)
    rule:SetPoint("BOTTOMRIGHT", bar, "TOPRIGHT", 0, 3)
  end
  return bar
end

-- "Qty" label + quantity box at the bar's left edge; returns the box and the x to continue at.
local function BarQty(bar, name)
  local label = Muted(Label(bar, L["Qty"], "GameFontHighlightSmall"))
  label:SetPoint("LEFT", 0, 0)
  local box, spinner = QtyBox(name, bar)
  -- The spinner's arrow buttons sit outside its edit box.
  box:SetPoint("LEFT", label, "RIGHT", spinner and 30 or 10, 0)
  return box, spinner and 30 or 12
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

local function FillFindEntry(row, u)
  row.icon:SetTexture(RecipeIcon(u.recipeID, u.outputItemID))
  row.name:SetText(u.name)
  row.name:SetTextColor(NameRGB(u.outputItemID))
  row.status:SetText(StatusText(u))
  row.check:SetShown(u.ready)
  row.sel:SetShown(u.recipeID == selectedID)
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

  find.reagLabel = Label(body, L["Reagents:"], Font("GameFontNormalSmall", "GameFontNormal"))
  find.reagLabel:SetPoint("TOPLEFT", find.header.holder, "BOTTOMLEFT", 0, -8)
  find.reagents = NewList("CraftBoardReagentsScroll", body, REAGENT_H, ReagentRow, FillReagentRow, { bar = false, inline = true, stripes = false })
  find.reagents.box:SetPoint("TOPLEFT", find.reagLabel, "BOTTOMLEFT", 0, -6)
  find.reagents.box:SetPoint("RIGHT", body, "RIGHT", 0, 0)
  find.reagents.box:SetHeight(REAGENT_H)

  find.crafterLabel = Label(body, L["Crafters:"], Font("GameFontNormalSmall", "GameFontNormal"))
  find.crafterLabel:SetPoint("TOPLEFT", find.reagents.box, "BOTTOMLEFT", 0, -10)
  find.crafters = NewList("CraftBoardCraftersScroll", body, SUBROW_H, CrafterRow, FillCrafterRow, { inline = true })
  find.crafters.box:SetPoint("TOPLEFT", find.crafterLabel, "BOTTOMLEFT", 0, -4)
  find.crafters.box:SetPoint("BOTTOMRIGHT")

  -- Bottom bar, like the recipe page's "Create All / < 1 > / Create" row: qty on the left,
  -- note in the middle, Whisper and Post request on the right.
  local bar = NewBar(p)
  find.bar = bar
  local qtyGap
  find.qty, qtyGap = BarQty(bar, "CraftBoardFindQty")
  find.qty:HookScript("OnTextChanged", Debouncer(0.2, function() UI.RefreshDetail() end))

  find.post = PanelButton(bar, L["Post request"], 112, 22)
  find.post:SetPoint("RIGHT", 0, 0)
  find.post:SetScript("OnClick", function()
    local itemID = find.itemID
    if not (itemID and NS.Comm and NS.Comm.PostRequest) then return end
    local qty = ReadQty(find.qty)
    if NS.Comm.PostRequest(itemID, qty, find.note:GetText()) then
      find.note:SetText("")
      find.note:ClearFocus()
      NS.Print(format(L["Posted request: %dx %s"], qty, ItemName(itemID)))
    end
  end)
  find.post:SetScript("OnEnter", function(self)
    if self:IsEnabled() then
      TextTooltip(self, L["Post an open request to the board"], L["Guild and realm-channel CraftBoard users see it for 24h."])
    else
      TextTooltip(self, L["This recipe makes no item to request"])
    end
  end)
  find.post:SetScript("OnLeave", HideTooltip)

  find.whisper = PanelButton(bar, L["Whisper"], 82, 22)
  find.whisper:SetPoint("RIGHT", find.post, "LEFT", -4, 0)
  find.whisper:SetScript("OnClick", function()
    local name, itemID = find.whisperTo, find.itemID
    if not (name and itemID and NS.Comm and NS.Comm.Request) then return end
    if not NS.Comm.Request(itemID, ReadQty(find.qty), name) then
      NS.Print(format(L["Could not whisper %s."], Short(name)))
    end
  end)
  find.whisper:SetScript("OnEnter", function(self)
    if self:IsEnabled() then
      TextTooltip(self, format(L["Whisper %s"], Short(find.whisperTo)), RequestText(find.itemID, ReadQty(find.qty)))
    elseif not find.itemID then
      TextTooltip(self, L["This recipe makes no item to request"])
    else
      TextTooltip(self, L["Only you and your alts know this recipe."])
    end
  end)
  find.whisper:SetScript("OnLeave", HideTooltip)

  local noteLabel = Muted(Label(bar, L["Note"], "GameFontHighlightSmall"))
  noteLabel:SetPoint("LEFT", find.qty, "RIGHT", qtyGap, 0)
  find.note = EditBox("CraftBoardFindNote", bar, 90, 60)
  find.note:SetPoint("LEFT", noteLabel, "RIGHT", 10, 0)
  find.note:SetPoint("RIGHT", find.whisper, "LEFT", -12, 0)
  find.note:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
    if find.post:IsEnabled() then find.post:Click() end
  end)
end

-- Whisper target: the chosen crafter if still listed, else the first other player (the list
-- is sorted online first).
function UI.UpdateWhisper()
  if not find.whisper then return end
  local e = find.entry
  local target, chosenOk
  for _, c in ipairs(e and e.crafters or {}) do
    if not c.mine then
      if not target then target = c.name end
      if c.name == find.crafter then chosenOk = true end
    end
  end
  if chosenOk then target = find.crafter end
  find.whisperTo = target
  find.whisper:SetEnabled(target ~= nil and find.itemID ~= nil)
end

local function SelectedEntry()
  if not selectedID then return nil end
  return universeByID[selectedID]
end

-- Reagent boxes shown without scrolling: what fits above a few crafter rows.
local function ReagentRows(body, n)
  local h = body:GetHeight() or 0
  local fit = h > 0 and floor((h - 190) / REAGENT_H) or 4
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
  local reagents, emptyText = {}, nil
  if rec and type(rec.r) == "table" and #rec.r > 0 and NS.Inventory and NS.Inventory.CanCraft then
    reagents = NS.Inventory.CanCraft(rec, qty).reagents
  elseif rec then
    emptyText = L["No reagents recorded."]
  else
    emptyText = L["Reagents unknown (peer recipe)."]
  end
  find.reagents.box:SetHeight(#reagents > 0 and REAGENT_H * ReagentRows(find.body, #reagents) or SUBROW_H)
  find.reagents:SetItems(reagents, emptyText, true)
  find.crafters:SetItems(e.crafters, L["No known crafters."], true)

  find.post:SetEnabled(itemID ~= nil)
  UI.UpdateWhisper()
end

-- Select a recipe on the visible tab (Find and Mine share the selection).
function UI.SelectRecipe(recipeID)
  if selectedID ~= recipeID then find.crafter = nil end
  selectedID = recipeID
  if activeTab == 2 then
    if mine.list then mine.list:Render() end
    UI.RefreshShopping()
  else
    if find.list then find.list:Render() end
    UI.RefreshDetail()
  end
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

-- Mine tab ------------------------------------------------------------------

local function FillMineEntry(row, it)
  row.icon:SetTexture(RecipeIcon(it.recipeID, it.outputItemID))
  row.name:SetText(it.name)
  row.name:SetTextColor(NameRGB(it.outputItemID))
  if it.ready then
    row.status:SetText(GREEN .. format(L["x%d"], it.times or 1) .. "|r")
  else
    row.status:SetText(RED .. format(L["%d short"], it.missing) .. "|r")
  end
  row.check:Hide()
  row.sel:SetShown(it.recipeID == selectedID)
end

local function MineEntries()
  local radios = ProfEntries(mine)
  return function()
    local e = radios()
    e[#e + 1] = { kind = "divider" }
    e[#e + 1] = { kind = "check", text = L["Short on"], tip = L["Also list recipes you're missing reagents for."],
      get = function()
        local db = UIDB()
        return db and db.showAll or false
      end,
      set = function()
        local db = UIDB()
        if db then db.showAll = not db.showAll end
        UI.FilterMine(false)
      end }
    return e
  end
end

local function BuildMine(p)
  mine.refilter = function(keep) UI.FilterMine(keep) end
  local d = BuildColumns(p, mine, "CraftBoardMineScroll", FillMineEntry, MineEntries(),
    function()
      local db = UIDB()
      return mine.prof == nil and not (db and db.showAll)
    end,
    function()
      local db = UIDB()
      if db then db.showAll = false end
      SetProf(nil)
    end)

  mine.none = Placeholder(d, L["Select a recipe to see what you're short on."])
  local body = CreateFrame("Frame", nil, d)
  body:SetAllPoints()
  mine.body = body
  mine.header = NewHeader(body)

  mine.reagLabel = Label(body, L["Reagents:"], Font("GameFontNormalSmall", "GameFontNormal"))
  mine.reagLabel:SetPoint("TOPLEFT", mine.header.holder, "BOTTOMLEFT", 0, -8)
  mine.shop = NewList("CraftBoardShopScroll", body, REAGENT_H, ReagentRow, FillReagentRow, { inline = true, stripes = false })
  mine.shop.box:SetPoint("TOPLEFT", mine.reagLabel, "BOTTOMLEFT", 0, -6)
  mine.shop.box:SetPoint("BOTTOMRIGHT")

  local bar = NewBar(p)
  mine.bar = bar
  mine.qty = BarQty(bar, "CraftBoardMineQty")
  mine.qty:HookScript("OnTextChanged", Debouncer(0.2, function() UI.RefreshShopping() end))
  mine.shopStatus = Muted(Label(bar, nil, "GameFontHighlightSmall"))
  mine.shopStatus:SetPoint("RIGHT", 0, 0)
  mine.shopStatus:SetPoint("LEFT", mine.qty, "RIGHT", 36, 0)
  mine.shopStatus:SetJustifyH("RIGHT")
end

-- Mine detail: the recipe page with every reagent's have/need for the chosen quantity.
function UI.RefreshShopping()
  if not mine.shop then return end
  local R, I = NS.Recipes, NS.Inventory
  local rec = selectedID and R and R.Mine and R.Mine()[selectedID]
  if not rec then
    mine.body:Hide()
    mine.none:Show()
    mine.shopStatus:SetText("")
    SetDetailBackground(mine, nil)
    return
  end
  mine.none:Hide()
  mine.body:Show()
  local name = rec.n or (R.NameOf and R.NameOf(selectedID)) or format(L["Recipe %d"], selectedID)
  FillHeader(mine.header, selectedID, rec.o, name, ProfLine(ProfNames(), rec.p), ItemDescription(selectedID, rec.o))
  AnchorBelowHeader(mine.header, mine.reagLabel)
  SetDetailBackground(mine, rec.p)
  local qty = ReadQty(mine.qty)
  local cc = I and I.CanCraft and I.CanCraft(rec, qty) or { reagents = {}, missing = {} }
  mine.shop:SetItems(cc.reagents, L["No reagents recorded."], true)
  if #cc.missing > 0 then
    mine.shopStatus:SetText(RED .. format(L["%d reagent(s) short"], #cc.missing) .. "|r")
  else
    mine.shopStatus:SetText(GREEN .. format(L["You have everything for %dx."], qty) .. "|r")
  end
end

-- Filter my recipes (ready only unless "Short on"), by profession and text; group them.
function UI.FilterMine(keepScroll)
  if not mine.list then return end
  local db = UIDB()
  local showAll = db and db.showAll or false
  mine.prof = ValidProf(mine.profs, db and db.findProf)
  local text = strtrim(mine.search:GetText() or "")
  local searching = #text >= 2
  mine.searching = searching
  local tokens = searching and Tokens(text) or nil
  local results = {}
  for _, e in ipairs(mine.all or {}) do
    if (showAll or e.ready) and (mine.prof == nil or e.prof == mine.prof) and (not tokens or Matches(e, tokens)) then
      results[#results + 1] = e
    end
  end
  table.sort(results, ReadyThenName)

  local visible = false
  for i = 1, #results do
    if results[i].recipeID == selectedID then visible = true break end
  end
  local items, nav = Grouped(results, mine.prof == nil, searching, mine.profNames)
  mine.results = nav

  local emptyText
  if not (mine.all and #mine.all > 0) then
    emptyText = EMPTY_RECIPES
  elseif #results == 0 then
    emptyText = searching and format(L["No recipe matches \"%s\"."], text) or L["Nothing craftable from your bags and bank right now."]
  end
  mine.list:SetItems(items, emptyText, keepScroll)
  SyncFilterButton(mine.filter, mine.filterEntries)
  if activeTab == 2 then UpdatePortrait(mine.prof) end
  local pick = not visible and (nav[1] or results[1])
  if pick then
    selectedID, find.crafter = pick.recipeID, nil
    mine.list:Render()
  end
  UI.RefreshShopping()
end

-- Rebuild my recipe entries (craftability, names, groups), then filter.
function UI.RefreshMine(keepScroll)
  if not mine.list then return end
  local R, I = NS.Recipes, NS.Inventory
  local names = ProfNames()
  local all, profCount = {}, {}
  for recipeID, rec in pairs(R and R.Mine and R.Mine() or {}) do
    local cc = I and I.CanCraft and I.CanCraft(rec) or { ready = false, missing = {}, times = 0 }
    local name = rec.n or (R.NameOf and R.NameOf(recipeID)) or format(L["Recipe %d"], recipeID)
    local itemName = rec.o and I and I.ItemName and I.ItemName(rec.o)
    all[#all + 1] = {
      recipeID = recipeID, outputItemID = rec.o, prof = rec.p, name = name,
      lname = strlower(name), litem = itemName and strlower(itemName) or nil,
      group = R.GroupOf and R.GroupOf(recipeID, rec.o) or L["Other"],
      ready = cc.ready, times = cc.times, missing = #cc.missing,
    }
    if rec.p ~= nil then profCount[rec.p] = true end
  end
  mine.all, mine.profNames = all, names
  mine.profs = SortedProfs(profCount, names)
  UI.FilterMine(keepScroll)
end

-- Requests tab --------------------------------------------------------------

local function IsMyPost(post)
  return post.mine or (NS.Me and post.from == NS.Me)
end

local function RequestRow(parent, rowH)
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(rowH)
  row:EnableMouse(true)
  local card = row:CreateTexture(nil, "BACKGROUND")
  card:SetPoint("TOPLEFT", 0, -2)
  card:SetPoint("BOTTOMRIGHT", 0, 2)
  card:SetColorTexture(1, 1, 1, 0.045)
  row.icon = BorderedIcon(row, 28)
  row.icon:SetPoint("LEFT", 6, 0)

  row.action = PanelButton(row, L["Offer"], 76, 20)
  row.action:SetPoint("RIGHT", -6, 0)
  row.action:SetScript("OnClick", function()
    local post = row.post
    if not post then return end
    if IsMyPost(post) then
      if NS.Comm and NS.Comm.Retract then NS.Comm.Retract(post.id) end
      UI.Refresh()
    else
      local msg = format(L["[CraftBoard] I can craft %s for you."], ItemLink(post.item) or ItemName(post.item))
      if not (NS.Comm and NS.Comm.Whisper and NS.Comm.Whisper(post.from, msg)) then
        NS.Print(format(L["Could not whisper %s."], Short(post.from)))
      end
    end
  end)
  row.action:SetScript("OnEnter", function(self)
    local post = row.post
    if post and not IsMyPost(post) then
      TextTooltip(self, format(L["Whisper %s"], Short(post.from)),
        format(L["[CraftBoard] I can craft %s for you."], ItemName(post.item)))
    end
  end)
  row.action:SetScript("OnLeave", HideTooltip)

  -- Icon spans x 6..34; title and note sit in two lines beside it, age top-right.
  row.age = Muted(Label(row, nil, "GameFontHighlightSmall"))
  row.age:SetPoint("TOPRIGHT", -92, -9)
  row.age:SetJustifyH("RIGHT")
  row.check = row:CreateTexture(nil, "ARTWORK")
  row.check:SetSize(12, 12)
  row.check:SetTexture(READY_TEX)
  row.check:SetPoint("RIGHT", row.age, "LEFT", -4, 0)
  row.title = Label(row, nil, "GameFontHighlight")
  row.title:SetPoint("TOPLEFT", 42, -9)
  row.title:SetPoint("TOPRIGHT", -146, -9)
  row.note = Muted(Label(row, nil, "GameFontHighlightSmall"))
  row.note:SetPoint("BOTTOMLEFT", 42, 9)
  row.note:SetPoint("BOTTOMRIGHT", -92, 9)
  row:SetScript("OnEnter", function(self)
    if self.post then ShowTooltip(self, self.post.item) end
  end)
  row:SetScript("OnLeave", HideTooltip)
  row:SetScript("OnMouseUp", function(self)
    if self.post then InsertLink(ItemLink(self.post.item)) end
  end)
  return row
end

local function FillRequestRow(row, post)
  row.post = post
  row.icon:SetTexture(ItemIcon(post.item) or QUESTION)
  local item = QualityHex(ItemQuality(post.item)) .. ItemName(post.item) .. "|r"
  local mineP = IsMyPost(post)
  if mineP then
    row.title:SetText(format(L["You want %dx %s"], post.qty or 1, item))
  else
    row.title:SetText(format(L["%s wants %dx %s"], Short(post.from), post.qty or 1, item))
  end
  local note = type(post.note) == "string" and post.note or ""
  row.note:SetText(note ~= "" and ("\"" .. note .. "\"") or "")
  row.age:SetText(Age(post.t))
  row.check:SetShown(not mineP and reqs.canMake and reqs.canMake[post.item] or false)
  row.action:SetText(mineP and L["Retract"] or L["Offer"])
end

-- One inset over the whole column area (the bar row stays empty on this tab).
local function BuildRequests(p)
  local inset = NewInset(p)
  inset:SetAllPoints()
  reqs.inset = inset
  reqs.list = NewList("CraftBoardRequestsScroll", inset, REQUEST_H, RequestRow, FillRequestRow)
  reqs.list.box:SetPoint("TOPLEFT", 6, -6)
  reqs.list.box:SetPoint("BOTTOMRIGHT", -6, 6)
end

function UI.RefreshRequests(keepScroll)
  if not reqs.list then return end
  local posts = NS.Comm and NS.Comm.Requests and NS.Comm.Requests() or {}
  -- Items my current char can make: marked with a check on other players' requests.
  local canMake = {}
  for _, rec in pairs(NS.Recipes and NS.Recipes.Mine and NS.Recipes.Mine() or {}) do
    if type(rec) == "table" and rec.o then canMake[rec.o] = true end
  end
  reqs.canMake = canMake
  local emptyText
  if #posts == 0 then
    emptyText = PeerCounts() == 0 and EMPTY_PEERS or L["No open requests. Post one from the Find tab."]
  end
  reqs.list:SetItems(posts, emptyText, keepScroll)
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
  if w < MIN_W then w = WIDTH end
  if h < MIN_H then h = HEIGHT end
  f:SetSize(min(MAX_W, w), min(MAX_H, h))
end

-- "61 recipes · 0 peers · channel ok"
function UI.RefreshFooter()
  if not footer then return end
  local st = NS.Comm and NS.Comm.Status and NS.Comm.Status()
  local parts = { format(L["%d recipes"], MyRecipeCount()) }
  if st then
    parts[#parts + 1] = format(L["%d peers"], st.peers or 0)
    parts[#parts + 1] = st.channel and L["channel ok"] or L["channel off"]
  end
  footer:SetText(table.concat(parts, DOT))
end

-- List column width for a window `w` px wide; the detail inset follows it (anchored to the
-- column's right edge).
local function SplitWidth(w)
  return floor((max(MIN_W, w or WIDTH) - STY.colL - STY.colR) * LEFT_FRAC)
end

local splitDone = false
local function LayoutSplit(w)
  local left = SplitWidth(w)
  if splitDone and left == LEFT_W then return end
  splitDone, LEFT_W = true, left
  for _, t in ipairs({ find, mine }) do
    if t.left then t.left:SetWidth(left) end
  end
end

local REFRESH = {
  function(keep) UI.RefreshFind(keep) end,
  function(keep) UI.RefreshMine(keep) end,
  function(keep) UI.RefreshRequests(keep) end,
}

local function FocusSearch()
  if activeTab ~= 1 or not find.search then return end
  find.search:SetFocus()
  -- The chat box that ran /cb may still take focus back this frame: try again next frame.
  if C_Timer and C_Timer.After then
    C_Timer.After(0, function()
      if frame and frame:IsShown() and activeTab == 1 then find.search:SetFocus() end
    end)
  end
end

local function SelectTab(i)
  activeTab = i
  local db = UIDB()
  if db then db.tab = i end
  for j, tab in ipairs(tabs) do
    panels[j]:SetShown(j == i)
    if tab.isPanelTab then
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
  if i ~= 1 and find.search then find.search:ClearFocus() end
  if i ~= 2 and mine.search then mine.search:ClearFocus() end
  if i == 3 then UpdatePortrait(nil) end
  REFRESH[i](false)
  UI.RefreshFooter()
end

local TAB_NAMES = { L["Find"], L["Mine"], L["Requests"] }

local function BuildTabs(f, style)
  local usePanel = HasTemplate("PanelTabButtonTemplate")
  for i, label in ipairs(TAB_NAMES) do
    local tab
    if usePanel then
      local ok, t = pcall(CreateFrame, "Button", "CraftBoardFrameTab" .. i, f, "PanelTabButtonTemplate")
      if ok and t then
        tab = t
        tab.isPanelTab = true
        if tab.Text then tab.Text:SetText(label) else tab:SetText(label) end
        if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tab, 0) end
        if i == 1 then
          tab:SetPoint("TOPLEFT", f, "BOTTOMLEFT", style.tabX, 2)
        else
          tab:SetPoint("LEFT", tabs[i - 1], "RIGHT", style.tabGap, 0)
        end
      else
        usePanel = false
      end
    end
    if not tab then
      tab = PanelButton(f, label, 90, 22)
      if i == 1 then
        tab:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 8, 0)
      else
        tab:SetPoint("LEFT", tabs[i - 1], "RIGHT", 2, 0)
      end
    end
    tab:SetID(i)
    tab:SetScript("OnClick", function(self)
      SelectTab(self:GetID())
      if self:GetID() == 1 then FocusSearch() end
    end)
    tabs[i] = tab
  end
end

local function BuildResizeGrip(f, style)
  if not f.SetResizable then return end
  f:SetResizable(true)
  if f.SetResizeBounds then
    f:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
  else
    if f.SetMinResize then f:SetMinResize(MIN_W, MIN_H) end
    if f.SetMaxResize then f:SetMaxResize(MAX_W, MAX_H) end
  end
  local grip = CreateFrame("Button", nil, f)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -style.grip, style.grip)
  grip:SetFrameLevel((f:GetFrameLevel() or 0) + 10)
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
  end)
end

-- The window: Blizzard's portrait frame like the Professions window (ButtonFrameTemplate,
-- else PortraitFrameTemplate), else the older BasicFrameTemplateWithInset.
-- Returns the frame and whether it is the portrait (modern) style.
local function NewWindow()
  for _, tmpl in ipairs({ "ButtonFrameTemplate", "PortraitFrameTemplate" }) do
    if HasTemplate(tmpl) then
      local ok, f = pcall(CreateFrame, "Frame", "CraftBoardFrame", UIParent, tmpl)
      if ok and f then return f, true end
    end
  end
  return CreateFrame("Frame", "CraftBoardFrame", UIParent, "BasicFrameTemplateWithInset"), false
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
    title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    if f.TitleBg then
      title:SetPoint("CENTER", f.TitleBg, "CENTER", 0, 0)
    else
      title:SetPoint("TOP", 0, -5)
    end
  end
  title:SetText(text)
end

-- Portrait frame: the template's single inset is replaced by our two column insets; its
-- bottom button bar stays (ButtonFrameTemplate_ShowButtonBar) for the action row.
local function SetupChrome(f)
  if f.Inset then f.Inset:Hide() end
  if ButtonFrameTemplate_ShowButtonBar then pcall(ButtonFrameTemplate_ShowButtonBar, f) end
end

local function Create()
  local f, modern = NewWindow()
  frame, MODERN = f, modern
  STY = modern and STYLE.modern or STYLE.legacy
  LEFT_W = SplitWidth(WIDTH)
  f:Hide()
  f:SetSize(WIDTH, HEIGHT)
  f:SetFrameStrata("HIGH")
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
    SetPortrait(f, PORTRAIT_TEX)
    portraitNow = PORTRAIT_TEX
    SetupChrome(f)
  end

  local content = CreateFrame("Frame", nil, f)
  content:SetPoint("TOPLEFT", STY.colL, -STY.colTop)
  content:SetPoint("BOTTOMRIGHT", -STY.colR, STY.colB)
  for i = 1, #TAB_NAMES do
    local p = CreateFrame("Frame", nil, content)
    p:SetAllPoints()
    p:Hide()
    panels[i] = p
  end
  -- Status line in the band beside the portrait (where Blizzard shows the rank bar).
  footer = Muted(Label(content, nil, "GameFontHighlightSmall"))
  footer:SetPoint("LEFT", f, "TOPLEFT", STY.bandX, -STY.bandMid)
  footer:SetPoint("RIGHT", f, "TOPRIGHT", -30, -STY.bandMid)

  BuildFind(panels[1])
  BuildMine(panels[2])
  BuildRequests(panels[3])
  BuildTabs(f, STY)
  BuildResizeGrip(f, STY)
  LayoutSplit(f:GetWidth())
  f:HookScript("OnSizeChanged", function(_, w) LayoutSplit(w) end)

  if UISpecialFrames then tinsert(UISpecialFrames, "CraftBoardFrame") end

  -- Hooks, not SetScript: the portrait templates may have their own show/hide handlers.
  f:HookScript("OnShow", function()
    dirty = false
    SelectTab(activeTab)
    FocusSearch()
  end)
  f:HookScript("OnHide", function()
    HideTooltip()
    if find.search then find.search:ClearFocus() end
    if mine.search then mine.search:ClearFocus() end
  end)

  local db = UIDB()
  if db and type(db.tab) == "number" and TAB_NAMES[db.tab] then activeTab = db.tab end
end

-- Refresh the visible tab (keeps scroll position); marks dirty while hidden.
function UI.Refresh()
  if not (frame and frame:IsShown()) then
    dirty = true
    return
  end
  dirty = false
  REFRESH[activeTab](true)
  UI.RefreshFooter()
end

local scheduleRefresh = Debouncer(0.3, UI.Refresh)

if NS.RegisterCallback then
  for _, ev in ipairs({ "RECIPES_UPDATED", "PEERS_UPDATED", "ITEM_NAMES_UPDATED", "INVENTORY_UPDATED", "POSTS_UPDATED" }) do
    NS.RegisterCallback(owner, ev, scheduleRefresh)
  end
end

-- Public ------------------------------------------------------------------------

function UI.Show()
  if not frame then Create() end
  frame:Show()
end

function UI.Hide()
  if frame then frame:Hide() end
end

function UI.Toggle()
  if frame and frame:IsShown() then UI.Hide() else UI.Show() end
end

function UI.IsDirty()
  return dirty
end
