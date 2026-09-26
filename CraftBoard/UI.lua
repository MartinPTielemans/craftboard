-- CraftBoard UI: one movable, resizable window with three tabs (Find, Mine, Requests).
-- Plain frames only: no ScrollBox/DataProvider, no external UI libs. Every row, chip and
-- button is created once (lists pool their visible rows); refreshes only re-fill them.
local ADDON, NS = ...

local UI = {}
NS.UI = UI

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local format = string.format
local L = NS.L

local WIDTH, HEIGHT = 560, 420          -- default and minimum size
local MAX_W, MAX_H = 1000, 800
-- List / detail split: the list gets LEFT_FRAC of the panel width (321 of 536 px at the
-- default 560 wide window, detail 205), recomputed on resize. LEFT_W is the current value.
local LEFT_FRAC = 0.6
local PANEL_PAD = 24                    -- window width minus panel width (content insets, both styles)
local LEFT_W = floor((WIDTH - PANEL_PAD) * LEFT_FRAC)
local SCROLLBAR_W = 22                  -- room for the legacy UIPanelScrollFrameTemplate bar
local MINIBAR_W = 14                    -- room for a MinimalScrollBar
-- Window chrome, per frame style (offsets from the window's top-left corner). The portrait
-- frame puts the search / chip band beside the portrait, above the dark inset; the legacy
-- BasicFrameTemplateWithInset keeps the band at the top of its inset.
local STYLE = {
  modern = { contentL = 11, contentTop = 26, contentR = 13, contentB = 10, insetTop = 60,
    bandMid = 16, bandX = 50, tabX = 11, tabGap = 3, grip = 6 },
  legacy = { contentL = 12, contentTop = 30, contentR = 12, contentB = 8,
    bandMid = 12, bandX = 0, tabX = 10, tabGap = 4, grip = 4 },
}
-- Set by Create() from STYLE before any tab is built.
local MODERN = false
local TOPBAR_H = 26                     -- panel top to the lists (the search / chip band)
local TOPBAR_X = 0                      -- band left offset (clears the portrait)
local BAND_MID = 12                     -- panel top to the band's vertical centre
local ROW_H, SUBROW_H = 24, 18          -- main list rows; reagent / crafter rows
local HEADER_ICON = 40
local FOOTER_H = 16
local SEARCH_W = 186
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local READY_TEX = "Interface\\RaidFrame\\ReadyCheck-Ready"
local PORTRAIT_TEX = "Interface\\Icons\\INV_Misc_Note_01"
local HIGHLIGHT_TEX = "Interface\\Buttons\\UI-Listbox-Highlight2"
local DIVIDER_ATLAS = "Options_HorizontalDivider"
local DOT = " \194\183 "                -- " · "
local GREEN, RED, GREY = "|cff40ff40", "|cffff4040", "|cff9d9d9d"
local MUTED = { 0.62, 0.62, 0.62 }
local GOLD_RGB = { 1, 0.82, 0 }

local EMPTY_RECIPES = L["Open a profession window to record your recipes."]
local EMPTY_PEERS = L["No one on the board yet \226\128\148 guildmates who install CraftBoard appear here."]

local frame                    -- main window, created on first show
local tabs, panels = {}, {}
local activeTab = 1
local selectedID               -- recipeID selected in Find (shared with Mine)
local dirty = true
local owner = {}               -- callback owner; CallbackHandler refuses NS itself
local find, mine, reqs = {}, {}, {}
local footer

-- Helpers ---------------------------------------------------------------

local function UIDB()
  if type(CraftBoardDB) ~= "table" then return nil end
  if type(CraftBoardDB.ui) ~= "table" then CraftBoardDB.ui = {} end
  return CraftBoardDB.ui
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
  GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
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

-- Gold section header with a thin rule under it, like the Professions window's group
-- headers. Callers anchor the label's TOPLEFT and hang content off the returned rule.
local function SectionHeader(parent, text)
  local fs = Label(parent, text, "GameFontNormal")
  local rule = HRule(parent)
  rule:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -3)
  rule:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
  return fs, rule
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

-- Virtual list --------------------------------------------------------------
-- A plain ScrollFrame whose child is sized for every item; only the visible rows exist and
-- are re-anchored on scroll. opts: bar (scrollbar, default true), inline (empty text
-- top-left instead of centered). The bar is a retail MinimalScrollBar wired by ScrollUtil
-- when both exist, else the legacy UIPanelScrollFrameTemplate.
local List = {}
List.__index = List

local function NewList(name, parent, rowHeight, makeRow, fillRow, opts)
  opts = opts or {}
  local self = setmetatable({ rowHeight = rowHeight, items = {}, rows = {}, makeRow = makeRow, fillRow = fillRow }, List)
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
      local range = max(0, #self.items * rowHeight - (s:GetHeight() or 0))
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

function List:SetItems(items, emptyText, keepScroll)
  self.items = items or {}
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
  local rowH = self.rowHeight
  local total = #self.items
  local h = self.scroll:GetHeight() or 0
  if h <= 0 then h = rowH * 10 end
  self:UpdateBar(total * rowH > h + 0.5)
  self.child:SetWidth(max(1, self.scroll:GetWidth() or 1))
  self.child:SetHeight(max(1, total * rowH))

  local maxScroll = max(0, total * rowH - h)
  local offset = self.scroll:GetVerticalScroll() or 0
  if offset > maxScroll then
    offset = maxScroll
    self.scroll:SetVerticalScroll(maxScroll)
  end

  local first = floor(offset / rowH) + 1
  local visible = ceil(h / rowH) + 1
  for i = 1, visible do
    local idx = first + i - 1
    local row = self.rows[i]
    if idx <= total then
      if not row then
        row = self.makeRow(self.child, rowH)
        self.rows[i] = row
      end
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", self.child, "TOPLEFT", 0, -(idx - 1) * rowH)
      row:SetPoint("TOPRIGHT", self.child, "TOPRIGHT", 0, -(idx - 1) * rowH)
      row:SetHeight(rowH)
      row.index = idx
      if row.stripe then row.stripe:SetShown(idx % 2 == 0) end
      self.fillRow(row, self.items[idx], idx)
      row:Show()
    elseif row then
      row:Hide()
    end
  end
  for i = visible + 1, #self.rows do self.rows[i]:Hide() end
  self.rendering = false
end

-- Scroll just enough for item idx to be fully visible.
function List:ScrollTo(idx)
  local rowH = self.rowHeight
  local h = self.scroll:GetHeight() or 0
  if h <= 0 or not idx then return end
  local top, bottom = (idx - 1) * rowH, idx * rowH
  local offset = self.scroll:GetVerticalScroll() or 0
  if top < offset then
    self.scroll:SetVerticalScroll(top)
  elseif bottom > offset + h then
    self.scroll:SetVerticalScroll(bottom - h)
  end
  self:Render()
end

-- Row base: button with the standard list-box hover highlight, a soft gold selection tint
-- and a very faint stripe on even rows.
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
  sel:SetColorTexture(1, 0.82, 0, 0.14)
  sel:Hide()
  row.sel = sel
  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  if hl:SetTexture(HIGHLIGHT_TEX) then
    hl:SetBlendMode("ADD")
    hl:SetVertexColor(1, 1, 1, 0.5)
  else
    hl:SetColorTexture(1, 1, 1, 0.08)
  end
  row:SetScript("OnLeave", HideTooltip)
  return row
end

local function IconRow(parent, rowH, iconSize)
  local row = RowBase(parent, rowH)
  row.icon = BorderedIcon(row, iconSize)
  row.icon:SetPoint("LEFT", 4, 0)
  return row
end

-- Chips: small flat toggle buttons (gold text + underline when active). Template-free.
local function NewChip(parent)
  local b = CreateFrame("Button", nil, parent)
  b:SetHeight(20)
  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(1, 0.82, 0, 0.10)
  b.bg = bg
  local line = b:CreateTexture(nil, "ARTWORK")
  line:SetHeight(1)
  line:SetPoint("BOTTOMLEFT")
  line:SetPoint("BOTTOMRIGHT")
  line:SetColorTexture(1, 0.82, 0, 0.8)
  b.line = line
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.08)
  b.label = Label(b, nil, "GameFontHighlightSmall")
  b.label:SetPoint("LEFT", 6, 0)
  b.label:SetPoint("RIGHT", -6, 0)
  b.label:SetJustifyH("CENTER")
  b:SetScript("OnLeave", HideTooltip)
  return b
end

local function SetChipActive(chip, on)
  chip.active = on and true or false
  chip.bg:SetShown(chip.active)
  chip.line:SetShown(chip.active)
  if chip.active then
    chip.label:SetTextColor(GOLD_RGB[1], GOLD_RGB[2], GOLD_RGB[3])
  else
    chip.label:SetTextColor(MUTED[1], MUTED[2], MUTED[3])
  end
end

-- Lay out chips left to right within `avail` px; wide labels shrink (truncated with "...").
local function LayoutChips(chips, count, avail, gap)
  local nat = {}
  local total = 0
  for i = 1, count do
    nat[i] = ceil(StringWidth(chips[i].label)) + 16
    total = total + nat[i]
  end
  local budget = avail - gap * (count - 1)
  local cap
  if total > budget then
    -- Fair share: narrow chips keep their width, the rest split what is left.
    local order = {}
    for i = 1, count do order[i] = i end
    table.sort(order, function(a, b) return nat[a] < nat[b] end)
    local left, n = budget, count
    cap = floor(budget / count)
    for _, i in ipairs(order) do
      if nat[i] <= left / n then
        left, n = left - nat[i], n - 1
      else
        cap = max(28, floor(left / n))
        break
      end
    end
  end
  local x = 0
  for i = 1, count do
    local w = cap and min(nat[i], cap) or nat[i]
    chips[i]:SetWidth(w)
    chips[i]:ClearAllPoints()
    chips[i]:SetPoint("LEFT", chips.anchor, "LEFT", x, 0)
    chips[i]:Show()
    x = x + w + gap
  end
  for i = count + 1, #chips do chips[i]:Hide() end
end

-- A title too long for the (narrow) detail pane drops to a smaller font on up to two lines;
-- the profession sub line gives way to it. Re-run when the pane is resized.
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

-- Item header, like the Professions recipe header: bordered 40 px icon, quality-coloured
-- name, muted "Profession · Rank" line under it.
local function NewHeader(parent)
  local h = {}
  h.icon = BorderedIcon(parent, HEADER_ICON)
  h.icon:SetPoint("TOPLEFT", 1, -1)
  local hit = CreateFrame("Frame", nil, parent)
  hit:SetAllPoints(h.icon)
  hit:EnableMouse(true)
  hit:SetScript("OnEnter", function(self)
    if h.recipeID then ShowTooltip(self, h.itemID, h.recipeID) end
  end)
  hit:SetScript("OnLeave", HideTooltip)
  h.title = Label(parent, nil, Font("GameFontNormalMed3", "GameFontNormalLarge"))
  h.title:SetPoint("TOPLEFT", HEADER_ICON + 10, -4)
  h.title:SetPoint("TOPRIGHT", -2, -4)
  h.sub = Muted(Label(parent, nil, "GameFontHighlightSmall"))
  h.sub:SetPoint("BOTTOMLEFT", parent, "TOPLEFT", HEADER_ICON + 10, -38)
  h.sub:SetPoint("BOTTOMRIGHT", parent, "TOPRIGHT", -2, -38)
  parent:HookScript("OnSizeChanged", function() FitHeader(h) end)
  return h
end

local function FillHeader(h, recipeID, itemID, name, sub)
  h.recipeID, h.itemID = recipeID, itemID
  h.icon:SetTexture(RecipeIcon(recipeID, itemID))
  local itemName = itemID and NS.Inventory and NS.Inventory.ItemName and NS.Inventory.ItemName(itemID)
  h.title:SetText(itemName or name or "")
  local r, g, b = NameRGB(itemID)
  h.rgb = { r, g, b }
  h.sub:SetText(sub or "")
  FitHeader(h)
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
      prof = ProfOf(e.recipeID), me = false, alt = nil, onlineN = 0, onlineName = nil,
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

-- Find tab ------------------------------------------------------------------

local function FindRow(parent, rowH)
  local row = IconRow(parent, rowH, 20)
  row.check = row:CreateTexture(nil, "ARTWORK")
  row.check:SetSize(14, 14)
  row.check:SetPoint("RIGHT", -4, 0)
  row.check:SetTexture(READY_TEX)
  row.status = Muted(Label(row, nil, "GameFontHighlightSmall"))
  row.status:SetPoint("RIGHT", -22, 0)       -- no width: sized to its text, name takes the rest
  row.status:SetJustifyH("RIGHT")
  row.name = Label(row, nil, "GameFontHighlight")
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
  row.name:SetPoint("RIGHT", row.status, "LEFT", -6, 0)
  row:SetScript("OnEnter", function(self)
    if self.entry then ShowTooltip(self, self.entry.outputItemID, self.entry.recipeID) end
  end)
  row:SetScript("OnClick", function(self)
    if not self.entry then return end
    UI.SelectRecipe(self.entry.recipeID)
  end)
  return row
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

local function FillFindRow(row, u)
  row.entry = u
  row.icon:SetTexture(RecipeIcon(u.recipeID, u.outputItemID))
  row.name:SetText(u.name)
  row.name:SetTextColor(NameRGB(u.outputItemID))
  row.status:SetText(StatusText(u))
  row.check:SetShown(u.ready)
  row.sel:SetShown(u.recipeID == selectedID)
end

local function CrafterRow(parent, rowH)
  local row = RowBase(parent, rowH)
  row.state = Muted(Label(row, nil, "GameFontHighlightSmall"))
  row.state:SetPoint("RIGHT", -4, 0)
  row.state:SetJustifyH("RIGHT")
  row.name = Label(row, nil, "GameFontHighlightSmall")
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
  if c.mine then
    row.name:SetText(Short(c.name))
    row.name:SetTextColor(GOLD_RGB[1], GOLD_RGB[2], GOLD_RGB[3])
    row.state:SetText(c.name == NS.Me and L["you"] or L["alt"])
  elseif c.online then
    row.name:SetText(Short(c.name))
    row.name:SetTextColor(1, 1, 1)
    row.state:SetText(GREEN .. L["online"] .. "|r")
  else
    row.name:SetText(Short(c.name))
    row.name:SetTextColor(MUTED[1], MUTED[2], MUTED[3])
    row.state:SetText(L["offline"])
  end
  row:EnableMouse(not c.mine)
  row.sel:SetShown(not c.mine and c.name == find.crafter)
end

local function ReagentRow(parent, rowH)
  local row = IconRow(parent, rowH, 16)
  row.count = Label(row, nil, "GameFontHighlightSmall")
  row.count:SetPoint("RIGHT", -4, 0)
  row.count:SetJustifyH("RIGHT")
  row.name = Label(row, nil, "GameFontHighlightSmall")
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
  row.name:SetPoint("RIGHT", row.count, "LEFT", -6, 0)
  row:SetScript("OnEnter", function(self) ShowTooltip(self, self.itemID) end)
  -- Like a shift-click: drop the item link into an open chat box (handy for asking guild).
  row:SetScript("OnClick", function(self) InsertLink(ItemLink(self.itemID)) end)
  return row
end

-- reagent: {itemID=, need=, have=}
local function FillReagentRow(row, r)
  row.itemID = r.itemID
  row.icon:SetTexture(ItemIcon(r.itemID) or QUESTION)
  row.name:SetText(ItemName(r.itemID))
  local color = (r.have >= r.need) and GREEN or RED
  row.count:SetText(color .. r.have .. "/" .. r.need .. "|r")
end

local function BuildFindSearch(p)
  local box
  if HasTemplate("SearchBoxTemplate") then
    local ok, e = pcall(CreateFrame, "EditBox", "CraftBoardSearchBox", p, "SearchBoxTemplate")
    if ok then box = e end
  end
  if not box then
    box = CreateFrame("EditBox", "CraftBoardSearchBox", p, "InputBoxTemplate")
  end
  box:SetSize(SEARCH_W, 20)
  box:SetPoint("LEFT", p, "TOPLEFT", TOPBAR_X + 6, -BAND_MID)
  box:SetAutoFocus(false)
  -- Soft hint while empty: the template's own instructions text, else our own label.
  local hint = box.Instructions
  if not hint then
    hint = Label(box, nil, "GameFontDisableSmall")
    hint:SetPoint("LEFT", 2, 0)
    box.cbHint = hint
  end
  hint:SetText(L["Type to search"])

  box:SetScript("OnEnterPressed", function(self)
    local list = find.results or {}
    local pick = (find.arrowed and selectedID) or (list[1] and list[1].recipeID)
    if pick then UI.SelectRecipe(pick) end
    self:ClearFocus()
  end)
  -- Escape clears the text first; on an empty box it closes the window.
  box:SetScript("OnEscapePressed", function(self)
    if (self:GetText() or "") ~= "" then
      self:SetText("")
    else
      self:ClearFocus()
      if frame then frame:Hide() end
    end
  end)
  box:SetScript("OnArrowPressed", function(_, key)
    local list = find.results or {}
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
    find.arrowed = true
    UI.SelectRecipe(list[idx].recipeID)
    find.list:ScrollTo(idx)
  end)
  box:HookScript("OnTextChanged", function(self)
    if self.cbHint then self.cbHint:SetShown((self:GetText() or "") == "") end
    find.arrowed = false
    UI.FilterFind(false, true)
  end)
  find.search = box
end

local function BuildFindChips(p)
  -- Same vertical centre as the search box; chips are centred on the anchor.
  local anchor = CreateFrame("Frame", nil, p)
  anchor:SetPoint("LEFT", p, "TOPLEFT", TOPBAR_X + SEARCH_W + 20, -BAND_MID)
  anchor:SetPoint("RIGHT", p, "TOPRIGHT", 0, -BAND_MID)
  anchor:SetHeight(20)
  find.chips = { anchor = anchor }
  anchor:SetScript("OnSizeChanged", function() UI.LayoutFindChips() end)
end

-- One chip per profession present on the board ("All" first); hidden with < 2 professions.
function UI.LayoutFindChips()
  local chips = find.chips
  if not chips then return end
  local db = UIDB()
  local current = db and db.findProf
  local defs = {}
  if #universeProfs >= 2 then
    defs[1] = { id = nil, name = L["All"] }
    for _, pr in ipairs(universeProfs) do defs[#defs + 1] = pr end
  end
  local valid = false
  for _, d in ipairs(defs) do
    if d.id ~= nil and d.id == current then valid = true end
  end
  if not valid then current = nil end
  for i, d in ipairs(defs) do
    local chip = chips[i]
    if not chip then
      chip = NewChip(chips.anchor)
      chip:SetScript("OnClick", function(self)
        local u = UIDB()
        if u then u.findProf = self.profID end
        find.prof = self.profID
        UI.LayoutFindChips()
        UI.FilterFind(false)
      end)
      chip:SetScript("OnEnter", function(self)
        if self.label:IsTruncated() then TextTooltip(self, self.fullName) end
      end)
      chips[i] = chip
    end
    chip.profID, chip.fullName = d.id, d.name
    chip.label:SetText(d.name)
    SetChipActive(chip, d.id == current)
  end
  find.prof = current
  LayoutChips(chips, #defs, max(60, chips.anchor:GetWidth() or 0), 4)
end

local function BuildFindDetail(p)
  local d = CreateFrame("Frame", nil, p)
  d:SetPoint("TOPLEFT", LEFT_W + 10, -TOPBAR_H)
  d:SetPoint("BOTTOMRIGHT")
  find.detail = d

  local divider = Divider(p)
  divider:SetWidth(1)
  divider:SetPoint("TOPLEFT", LEFT_W + 4, -TOPBAR_H)
  divider:SetPoint("BOTTOMLEFT", LEFT_W + 4, 0)
  find.divider = divider

  find.none = Placeholder(d, L["Select a recipe to see who can craft it."])

  local body = CreateFrame("Frame", nil, d)
  body:SetAllPoints()
  find.body = body

  find.header = NewHeader(body)

  local rh, rrule = SectionHeader(body, L["Reagents"])
  rh:SetPoint("TOPLEFT", 0, -(HEADER_ICON + 10))
  find.reagents = NewList("CraftBoardReagentsScroll", body, SUBROW_H, ReagentRow, FillReagentRow, { bar = false, inline = true })
  find.reagents.box:SetPoint("TOPLEFT", rrule, "BOTTOMLEFT", 0, -4)
  find.reagents.box:SetPoint("TOPRIGHT", rrule, "BOTTOMRIGHT", 0, -4)
  find.reagents.box:SetHeight(SUBROW_H)

  local ch, crule = SectionHeader(body, L["Crafters"])
  ch:SetPoint("TOPLEFT", find.reagents.box, "BOTTOMLEFT", 0, -10)
  find.crafters = NewList("CraftBoardCraftersScroll", body, SUBROW_H, CrafterRow, FillCrafterRow, { inline = true })
  find.crafters.box:SetPoint("TOPLEFT", crule, "BOTTOMLEFT", 0, -4)
  find.crafters.box:SetPoint("BOTTOMRIGHT", 0, 56)

  -- Action area, anchored to the bottom: note + qty row, then Whisper + Post request.
  -- Fits the 205 px detail pane of a default-size window (note box ~95 px).
  local sep = Divider(body)
  sep:SetHeight(1)
  sep:SetPoint("BOTTOMLEFT", 0, 52)
  sep:SetPoint("BOTTOMRIGHT", 0, 52)

  find.qty = EditBox("CraftBoardFindQty", body, 32, 4, true)
  find.qty:SetPoint("RIGHT", body, "BOTTOMRIGHT", -4, 38)
  find.qty:SetText("1")
  local qtyLabel = Muted(Label(body, L["Qty"], "GameFontHighlightSmall"))
  qtyLabel:SetPoint("RIGHT", find.qty, "LEFT", -10, 0)

  local noteLabel = Muted(Label(body, L["Note"], "GameFontHighlightSmall"))
  noteLabel:SetPoint("LEFT", body, "BOTTOMLEFT", 0, 38)
  find.note = EditBox("CraftBoardFindNote", body, 90, 60)
  find.note:SetPoint("LEFT", noteLabel, "RIGHT", 10, 0)
  find.note:SetPoint("RIGHT", qtyLabel, "LEFT", -12, 0)
  find.note:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
    if find.post:IsEnabled() then find.post:Click() end
  end)

  find.qty:HookScript("OnTextChanged", Debouncer(0.2, function() UI.RefreshDetail() end))

  find.post = PanelButton(body, L["Post request"], 104, 22)
  find.post:SetPoint("BOTTOMRIGHT", 0, 2)
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

  find.whisper = PanelButton(body, L["Whisper"], 76, 22)
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
end

local function BuildFind(p)
  BuildFindSearch(p)
  BuildFindChips(p)
  find.list = NewList("CraftBoardFindScroll", p, ROW_H, FindRow, FillFindRow)
  find.list.box:SetPoint("TOPLEFT", 0, -TOPBAR_H)
  find.list.box:SetPoint("BOTTOMLEFT", 0, 0)
  find.list.box:SetWidth(LEFT_W)
  BuildFindDetail(p)
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

function UI.RefreshDetail()
  if not find.body then return end
  local e = SelectedEntry()
  find.entry = e
  if not e then
    find.itemID = nil
    find.body:Hide()
    find.none:Show()
    return
  end
  find.none:Hide()
  find.body:Show()

  local itemID = OutputOf(e.recipeID, e)
  find.itemID = itemID
  FillHeader(find.header, e.recipeID, itemID, e.name, ProfLine(find.profNames or {}, e.prof))

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
  find.reagents.box:SetHeight(SUBROW_H * min(5, max(1, #reagents)))
  find.reagents:SetItems(reagents, emptyText, true)
  find.crafters:SetItems(e.crafters, L["No known crafters."], true)

  find.post:SetEnabled(itemID ~= nil)
  UI.UpdateWhisper()
end

function UI.SelectRecipe(recipeID)
  if selectedID ~= recipeID then find.crafter = nil end
  selectedID = recipeID
  if find.list then find.list:Render() end
  UI.RefreshDetail()
end

-- Filter the cached universe by text and profession. Called on every keystroke (typed=true).
-- A selection the filter hides is cleared; while searching, typing selects the top hit when
-- nothing is selected. Browsing (empty box, chips) never picks a row by itself.
function UI.FilterFind(keepScroll, typed)
  if not find.list then return end
  local text = strtrim(find.search:GetText() or "")
  local searching = #text >= 2
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
    -- Default view: every tradeable recipe on the board (all my chars and peers), what I
    -- can craft right now first so the checks cluster at the top, then by name.
    for i = 1, #candidates do results[i] = candidates[i] end
    table.sort(results, ReadyThenName)
  end
  find.results = results

  local visible = false
  for i = 1, #results do
    if results[i].recipeID == selectedID then visible = true break end
  end
  if selectedID and not visible then
    selectedID, find.crafter = nil, nil
  end

  local emptyText
  if #results == 0 then
    if #universe == 0 then
      emptyText = EMPTY_RECIPES
    elseif searching then
      emptyText = format(L["No known crafter for \"%s\"."], text)
    end
  end
  find.list:SetItems(results, emptyText, keepScroll)
  if typed and searching and not selectedID and results[1] then
    UI.SelectRecipe(results[1].recipeID)
  else
    UI.RefreshDetail()
  end
end

function UI.RefreshFind(keepScroll)
  if not find.list then return end
  BuildUniverse()
  UI.LayoutFindChips()
  UI.FilterFind(keepScroll)
end

-- Mine tab ------------------------------------------------------------------

local function MineRow(parent, rowH)
  local row = IconRow(parent, rowH, 20)
  row.count = Label(row, nil, "GameFontHighlightSmall")
  row.count:SetPoint("RIGHT", -4, 0)
  row.count:SetJustifyH("RIGHT")
  row.name = Label(row, nil, "GameFontHighlight")
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
  row.name:SetPoint("RIGHT", row.count, "LEFT", -6, 0)
  -- Profession group header: gold label over a thin rule.
  row.header = Label(row, nil, "GameFontNormal")
  row.header:SetPoint("BOTTOMLEFT", 2, 5)
  row.headerCount = Muted(Label(row, nil, "GameFontHighlightSmall"))
  row.headerCount:SetPoint("BOTTOMRIGHT", -4, 5)
  row.rule = HRule(row)
  row.rule:SetPoint("BOTTOMLEFT", 0, 1)
  row.rule:SetPoint("BOTTOMRIGHT", 0, 1)
  row:SetScript("OnEnter", function(self)
    local it = self.item
    if it and not it.header then ShowTooltip(self, it.outputItemID, it.recipeID) end
  end)
  row:SetScript("OnClick", function(self)
    local it = self.item
    if not it or it.header then return end
    selectedID = it.recipeID
    find.crafter = nil
    mine.list:Render()
    UI.RefreshShopping()
  end)
  return row
end

local function FillMineRow(row, it)
  row.item = it
  local isHeader = it.header ~= nil
  row.header:SetShown(isHeader)
  row.headerCount:SetShown(isHeader)
  row.rule:SetShown(isHeader)
  row.icon:SetShown(not isHeader)
  row.icon.border:SetShown(not isHeader)
  row.name:SetShown(not isHeader)
  row.count:SetShown(not isHeader)
  row:EnableMouse(not isHeader)
  if isHeader then
    row.header:SetText(it.header)
    row.headerCount:SetText(it.count)
    row.sel:Hide()
    row.stripe:Hide()
    return
  end
  row.icon:SetTexture(RecipeIcon(it.recipeID, it.outputItemID))
  row.name:SetText(it.name)
  row.name:SetTextColor(NameRGB(it.outputItemID))
  if it.ready then
    row.count:SetText(GREEN .. format(L["x%d"], it.times or 1) .. "|r")
  else
    row.count:SetText(RED .. format(L["%d short"], it.missing) .. "|r")
  end
  row.sel:SetShown(it.recipeID == selectedID)
end

local function BuildMine(p)
  local chips = { anchor = CreateFrame("Frame", nil, p) }
  chips.anchor:SetPoint("LEFT", p, "TOPLEFT", TOPBAR_X + 4, -BAND_MID)
  chips.anchor:SetSize(LEFT_W, 20)
  mine.chips = chips
  local chip = NewChip(chips.anchor)
  chip.label:SetText(L["Short on"])
  chips[1] = chip
  chip:SetScript("OnClick", function(self)
    local db = UIDB()
    if db then db.showAll = not self.active end
    UI.RefreshMine()
  end)
  chip:SetScript("OnEnter", function(self)
    TextTooltip(self, L["Short on"], L["Also list recipes you're missing reagents for."])
  end)
  mine.chip = chip
  LayoutChips(chips, 1, LEFT_W, 4)

  mine.list = NewList("CraftBoardMineScroll", p, ROW_H, MineRow, FillMineRow)
  mine.list.box:SetPoint("TOPLEFT", 0, -TOPBAR_H)
  mine.list.box:SetPoint("BOTTOMLEFT", 0, 0)
  mine.list.box:SetWidth(LEFT_W)

  local divider = Divider(p)
  divider:SetWidth(1)
  divider:SetPoint("TOPLEFT", LEFT_W + 4, -TOPBAR_H)
  divider:SetPoint("BOTTOMLEFT", LEFT_W + 4, 0)
  mine.divider = divider

  local d = CreateFrame("Frame", nil, p)
  d:SetPoint("TOPLEFT", LEFT_W + 10, -TOPBAR_H)
  d:SetPoint("BOTTOMRIGHT")
  mine.detail = d

  mine.none = Placeholder(d, L["Select a recipe to see what you're short on."])
  local body = CreateFrame("Frame", nil, d)
  body:SetAllPoints()
  mine.body = body

  mine.header = NewHeader(body)

  local sh, srule = SectionHeader(body, L["Shopping list"])
  sh:SetPoint("TOPLEFT", 0, -(HEADER_ICON + 10))
  mine.shop = NewList("CraftBoardShopScroll", body, SUBROW_H, ReagentRow, FillReagentRow, { inline = true })
  mine.shop.box:SetPoint("TOPLEFT", srule, "BOTTOMLEFT", 0, -4)
  mine.shop.box:SetPoint("BOTTOMRIGHT", 0, 30)

  local sep = Divider(body)
  sep:SetHeight(1)
  sep:SetPoint("BOTTOMLEFT", 0, 28)
  sep:SetPoint("BOTTOMRIGHT", 0, 28)

  local qtyLabel = Muted(Label(body, L["Qty"], "GameFontHighlightSmall"))
  qtyLabel:SetPoint("BOTTOMLEFT", 0, 7)
  mine.qty = EditBox("CraftBoardMineQty", body, 32, 4, true)
  mine.qty:SetPoint("LEFT", qtyLabel, "RIGHT", 10, 0)
  mine.qty:SetText("1")
  mine.qty:HookScript("OnTextChanged", Debouncer(0.2, function() UI.RefreshShopping() end))

  mine.shopStatus = Muted(Label(body, nil, "GameFontHighlightSmall"))
  mine.shopStatus:SetPoint("BOTTOMRIGHT", -2, 8)
  mine.shopStatus:SetPoint("LEFT", mine.qty, "RIGHT", 8, 0)
  mine.shopStatus:SetJustifyH("RIGHT")
end

function UI.RefreshShopping()
  if not mine.shop then return end
  local R = NS.Recipes
  local rec = selectedID and R and R.Mine and R.Mine()[selectedID]
  if not rec then
    mine.body:Hide()
    mine.none:Show()
    return
  end
  mine.none:Hide()
  mine.body:Show()
  local name = rec.n or (R.NameOf and R.NameOf(selectedID)) or format(L["Recipe %d"], selectedID)
  FillHeader(mine.header, selectedID, rec.o, name, ProfLine(ProfNames(), rec.p))
  local qty = ReadQty(mine.qty)
  local list = {}
  if NS.Inventory and NS.Inventory.ShoppingList then
    list = NS.Inventory.ShoppingList({ { selectedID, qty } })
  end
  if #list == 0 then
    mine.shop:SetItems({}, format(L["You have everything for %dx."], qty))
    mine.shopStatus:SetText("")
  else
    mine.shop:SetItems(list, nil, true)
    mine.shopStatus:SetText(RED .. format(L["%d reagent(s) short"], #list) .. "|r")
  end
end

function UI.RefreshMine(keepScroll)
  if not mine.list then return end
  local R, I = NS.Recipes, NS.Inventory
  local db = UIDB()
  local showAll = db and db.showAll or false
  SetChipActive(mine.chip, showAll)

  local entries = {}
  for recipeID, rec in pairs(R and R.Mine and R.Mine() or {}) do
    local cc = I and I.CanCraft and I.CanCraft(rec) or { ready = false, missing = {}, times = 0 }
    if showAll or cc.ready then
      entries[#entries + 1] = {
        recipeID = recipeID, outputItemID = rec.o, p = rec.p,
        name = rec.n or (R.NameOf and R.NameOf(recipeID)) or format(L["Recipe %d"], recipeID),
        ready = cc.ready, times = cc.times, missing = #cc.missing,
      }
    end
  end

  -- Group by profession (sorted by name), craftable first within a group, then name.
  local names = ProfNames()
  local groups, order = {}, {}
  for _, e in ipairs(entries) do
    local key = e.p ~= nil and e.p or "?"
    if not groups[key] then
      groups[key] = { name = ProfName(names, e.p), list = {} }
      order[#order + 1] = key
    end
    local g = groups[key].list
    g[#g + 1] = e
  end
  table.sort(order, function(a, b)
    if groups[a].name ~= groups[b].name then return groups[a].name < groups[b].name end
    return tostring(a) < tostring(b)
  end)
  local items = {}
  for _, key in ipairs(order) do
    local g = groups[key]
    table.sort(g.list, function(a, b)
      if a.ready ~= b.ready then return a.ready end
      if a.name ~= b.name then return a.name < b.name end
      return a.recipeID < b.recipeID
    end)
    items[#items + 1] = { header = g.name, count = #g.list }
    for _, e in ipairs(g.list) do items[#items + 1] = e end
  end

  local hasRecipes = R and R.Mine and next(R.Mine()) ~= nil
  local emptyText
  if not hasRecipes then
    emptyText = EMPTY_RECIPES
  elseif #items == 0 then
    emptyText = L["Nothing craftable from your bags and bank right now."]
  end
  mine.list:SetItems(items, emptyText, keepScroll)
  UI.RefreshShopping()
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

local function BuildRequests(p)
  reqs.list = NewList("CraftBoardRequestsScroll", p, 44, RequestRow, FillRequestRow)
  -- Inside the inset under the (empty) band on the portrait frame; full height otherwise.
  reqs.list.box:SetPoint("TOPLEFT", 0, MODERN and -TOPBAR_H or 0)
  reqs.list.box:SetPoint("BOTTOMRIGHT")
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
  local w = db and tonumber(db.w) or WIDTH
  local h = db and tonumber(db.h) or HEIGHT
  f:SetSize(min(MAX_W, max(WIDTH, w)), min(MAX_H, max(HEIGHT, h)))
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

-- Re-anchor list, divider and detail of Find and Mine for a window `w` px wide.
local splitDone = false
local function LayoutSplit(w)
  local left = floor((max(WIDTH, w or WIDTH) - PANEL_PAD) * LEFT_FRAC)
  if splitDone and left == LEFT_W then return end
  splitDone, LEFT_W = true, left
  for _, t in ipairs({ find, mine }) do
    if t.list then t.list.box:SetWidth(left) end
    if t.divider then
      t.divider:ClearAllPoints()
      t.divider:SetPoint("TOPLEFT", left + 4, -TOPBAR_H)
      t.divider:SetPoint("BOTTOMLEFT", left + 4, 0)
    end
    if t.detail then
      t.detail:ClearAllPoints()
      t.detail:SetPoint("TOPLEFT", left + 10, -TOPBAR_H)
      t.detail:SetPoint("BOTTOMRIGHT")
    end
  end
  if mine.chips then
    mine.chips.anchor:SetWidth(left)
    LayoutChips(mine.chips, 1, left, 4)
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
    f:SetResizeBounds(WIDTH, HEIGHT, MAX_W, MAX_H)
  else
    if f.SetMinResize then f:SetMinResize(WIDTH, HEIGHT) end
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

local function SetPortrait(f)
  if f.SetPortraitToAsset and pcall(f.SetPortraitToAsset, f, PORTRAIT_TEX) then return end
  local tex = (f.PortraitContainer and f.PortraitContainer.portrait) or f.portrait
  if not tex and f.GetPortrait then
    local ok, t = pcall(f.GetPortrait, f)
    if ok then tex = t end
  end
  if not tex then return end
  if not (SetPortraitToTexture and pcall(SetPortraitToTexture, tex, PORTRAIT_TEX)) then
    tex:SetTexture(PORTRAIT_TEX)
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

-- Dark inset under the search band, down to the bottom edge (the button bar is hidden).
local function SetupInset(f, style)
  if f.Inset and ButtonFrameTemplate_HideButtonBar then pcall(ButtonFrameTemplate_HideButtonBar, f) end
  local inset = f.Inset
  if not inset and HasTemplate("InsetFrameTemplate") then
    local ok, i = pcall(CreateFrame, "Frame", nil, f, "InsetFrameTemplate")
    if ok and i then inset = i end
  end
  if not inset then
    inset = CreateFrame("Frame", nil, f)
    local bg = inset:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.45)
  end
  inset:ClearAllPoints()
  inset:SetPoint("TOPLEFT", 4, -style.insetTop)
  inset:SetPoint("BOTTOMRIGHT", -6, 4)
  return inset
end

local function Create()
  local f, modern = NewWindow()
  frame, MODERN = f, modern
  local style = modern and STYLE.modern or STYLE.legacy
  TOPBAR_X, BAND_MID = style.bandX, style.bandMid
  -- Lists start just inside the inset on the portrait frame.
  TOPBAR_H = modern and (style.insetTop - style.contentTop + 4) or 26
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
  local inset
  if modern then
    SetPortrait(f)
    inset = SetupInset(f, style)
  end

  local content = CreateFrame("Frame", nil, f)
  -- Above the inset (a sibling), set before any child exists so they all stack on top.
  if inset then content:SetFrameLevel((inset:GetFrameLevel() or 0) + 2) end
  content:SetPoint("TOPLEFT", style.contentL, -style.contentTop)
  content:SetPoint("BOTTOMRIGHT", -style.contentR, style.contentB)
  for i = 1, #TAB_NAMES do
    local p = CreateFrame("Frame", nil, content)
    p:SetPoint("TOPLEFT")
    p:SetPoint("BOTTOMRIGHT", 0, FOOTER_H)
    p:Hide()
    panels[i] = p
  end
  footer = Muted(Label(content, nil, "GameFontHighlightSmall"))
  footer:SetPoint("BOTTOMLEFT", 2, 2)
  footer:SetPoint("BOTTOMRIGHT", -20, 2)

  BuildFind(panels[1])
  BuildMine(panels[2])
  BuildRequests(panels[3])
  BuildTabs(f, style)
  BuildResizeGrip(f, style)
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
  end)

  local db = UIDB()
  if db and type(db.tab) == "number" and TAB_NAMES[db.tab] then activeTab = db.tab end
  find.prof = db and db.findProf
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
