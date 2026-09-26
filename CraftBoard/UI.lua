-- CraftBoard UI: one movable window with three tabs (Find, Mine, Requests).
-- Plain frames only: no ScrollBox/DataProvider, no external UI libs.
local ADDON, NS = ...

local UI = {}
NS.UI = UI

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local format = string.format
local L = NS.L

local WIDTH, HEIGHT = 560, 420
local LEFT_W = 262             -- left column incl. scrollbar
local SCROLLBAR_W = 22
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local DOT = " \194\183 "       -- " · "
local GREEN, RED, GREY, GOLD = "|cff40ff40", "|cffff4040", "|cff9d9d9d", "|cffffd100"

local EMPTY_RECIPES = L["Open a profession window to record your recipes."]
local BOP_NOTE = L["Bind on Pickup, can't be crafted for others."]
local EMPTY_PEERS = L["No one on the board yet \226\128\148 guildmates who install CraftBoard appear here."]

local frame                    -- main window, created on first show
local tabs, panels = {}, {}
local activeTab = 1
local selectedID               -- recipeID selected in Find (shared with Mine)
local dirty = true
local owner = {}               -- callback owner; CallbackHandler refuses NS itself
local find, mine, reqs = {}, {}, {}

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

local function ItemLink(itemID)
  local link
  if C_Item and C_Item.GetItemInfo then
    link = select(2, C_Item.GetItemInfo(itemID))
  elseif GetItemInfo then
    link = select(2, GetItemInfo(itemID))
  end
  return link or ItemName(itemID)
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

local function Label(parent, text, font)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
  fs:SetJustifyH("LEFT")
  if fs.SetWordWrap then fs:SetWordWrap(false) end
  if text then fs:SetText(text) end
  return fs
end

local function PanelButton(parent, text, width, height)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width or 80, height or 20)
  b:SetText(text)
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

-- Virtual list: a plain ScrollFrame whose child is sized for every item; only the visible
-- rows exist and are re-anchored on scroll.
local List = {}
List.__index = List

local function NewList(name, parent, rowHeight, makeRow, fillRow)
  local self = setmetatable({ rowHeight = rowHeight, items = {}, rows = {}, makeRow = makeRow, fillRow = fillRow }, List)
  local box = CreateFrame("Frame", nil, parent)
  self.box = box

  local scroll
  if HasTemplate("UIPanelScrollFrameTemplate") then
    local ok, f = pcall(CreateFrame, "ScrollFrame", name, box, "UIPanelScrollFrameTemplate")
    if ok then scroll = f end
  end
  if scroll then
    scroll:SetPoint("TOPLEFT")
    scroll:SetPoint("BOTTOMRIGHT", -SCROLLBAR_W, 0)
  else
    scroll = CreateFrame("ScrollFrame", name, box)
    scroll:SetAllPoints()
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(s, delta)
      local range = s:GetVerticalScrollRange() or 0
      s:SetVerticalScroll(min(range, max(0, s:GetVerticalScroll() - delta * rowHeight * 3)))
    end)
  end
  self.scroll = scroll

  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(1, 1)
  scroll:SetScrollChild(child)
  self.child = child

  scroll:HookScript("OnVerticalScroll", function() self:Render() end)
  scroll:HookScript("OnSizeChanged", function(s, w)
    child:SetWidth(max(1, w or s:GetWidth()))
    self:Render()
  end)

  self.empty = Label(box, nil, "GameFontDisable")
  self.empty:SetPoint("TOPLEFT", 8, -12)
  self.empty:SetPoint("RIGHT", -8, 0)
  self.empty:SetJustifyH("CENTER")
  if self.empty.SetWordWrap then self.empty:SetWordWrap(true) end
  return self
end

function List:SetItems(items, emptyText, keepScroll)
  self.items = items or {}
  if not keepScroll then self.scroll:SetVerticalScroll(0) end
  self.empty:SetText(emptyText or "")
  self.empty:SetShown(#self.items == 0 and emptyText ~= nil)
  self:Render()
end

function List:Render()
  local rowH = self.rowHeight
  local total = #self.items
  local h = self.scroll:GetHeight() or 0
  if h <= 0 then h = rowH * 10 end
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
      row:SetPoint("RIGHT", self.child, "RIGHT")
      row:SetHeight(rowH)
      row.index = idx
      self.fillRow(row, self.items[idx], idx)
      row:Show()
    elseif row then
      row:Hide()
    end
  end
  for i = visible + 1, #self.rows do self.rows[i]:Hide() end
end

-- Row base: button with hover highlight and a selection wash.
local function RowBase(parent, rowH)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(rowH)
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  local sel = row:CreateTexture(nil, "BACKGROUND")
  sel:SetAllPoints()
  sel:SetColorTexture(1, 0.82, 0, 0.18)
  sel:Hide()
  row.sel = sel
  row:SetScript("OnLeave", HideTooltip)
  return row
end

local function IconRow(parent, rowH, iconSize)
  local row = RowBase(parent, rowH)
  local icon = row:CreateTexture(nil, "ARTWORK")
  icon:SetSize(iconSize, iconSize)
  icon:SetPoint("LEFT", 2, 0)
  row.icon = icon
  return row
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

local function HaveAnyRecipes()
  if type(CraftBoardDB) ~= "table" or type(CraftBoardDB.chars) ~= "table" then return false end
  for _, c in pairs(CraftBoardDB.chars) do
    if type(c) == "table" and type(c.recipes) == "table" and next(c.recipes) then return true end
  end
  return false
end

-- "you (Alt) · 2 online · 5 known"
local function CrafterSummary(entry)
  local you, alts, online = false, {}, 0
  for _, c in ipairs(entry.crafters or {}) do
    if c.mine then
      if c.name == NS.Me then you = true else alts[#alts + 1] = Short(c.name) end
    elseif c.online then
      online = online + 1
    end
  end
  local parts = {}
  local mineText
  if you then mineText = L["you"] end
  if #alts > 0 then
    local a = table.concat(alts, ", ")
    mineText = mineText and (mineText .. " (" .. a .. ")") or a
  end
  if mineText then parts[#parts + 1] = GOLD .. mineText .. "|r" end
  if online > 0 then parts[#parts + 1] = GREEN .. format(L["%d online"], online) .. "|r" end
  parts[#parts + 1] = format(L["%d known"], #(entry.crafters or {}))
  if entry.bop then parts[#parts + 1] = GREY .. L["BoP"] .. "|r" end
  return table.concat(parts, DOT)
end

local function ProfName(profID)
  local c = type(CraftBoardDB) == "table" and NS.Me and CraftBoardDB.chars and CraftBoardDB.chars[NS.Me]
  local p = c and c.profs and c.profs[profID]
  if type(p) == "table" then
    local n = p.name or p[1]
    if n then return n end
  end
  if type(profID) == "string" then return profID end
  return L["Other"]
end

-- The selected recipe's Search entry: from the current results, else a full lookup.
local function SelectedEntry()
  if not selectedID then return nil end
  for _, r in ipairs(find.results or {}) do
    if r.recipeID == selectedID then return r end
  end
  if NS.Recipes and NS.Recipes.Search then
    for _, r in ipairs(NS.Recipes.Search("")) do
      if r.recipeID == selectedID then return r end
    end
  end
  return nil
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

-- Find tab ------------------------------------------------------------------

local function FindRow(parent, rowH)
  local row = IconRow(parent, rowH, 24)
  row.name = Label(row, nil, "GameFontHighlight")
  row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 5, 0)
  row.name:SetPoint("RIGHT", -2, 0)
  row.sub = Label(row, nil, "GameFontHighlightSmall")
  row.sub:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 5, 0)
  row.sub:SetPoint("RIGHT", -2, 0)
  row:SetScript("OnEnter", function(self)
    if self.entry then ShowTooltip(self, self.entry.outputItemID, self.entry.recipeID) end
  end)
  row:SetScript("OnClick", function(self)
    if not self.entry then return end
    selectedID = self.entry.recipeID
    find.list:Render()
    UI.RefreshDetail()
  end)
  return row
end

local function FillFindRow(row, entry)
  row.entry = entry
  row.icon:SetTexture(RecipeIcon(entry.recipeID, entry.outputItemID))
  local name = entry.name
  -- Search fell back to the generic "Recipe <id>" label: the output item name reads better.
  if entry.outputItemID and name == format(L["Recipe %d"], entry.recipeID) then name = ItemName(entry.outputItemID) end
  row.name:SetText(name)
  row.sub:SetText(CrafterSummary(entry))
  row.sel:SetShown(entry.recipeID == selectedID)
end

local function CrafterRow(parent, rowH)
  local row = RowBase(parent, rowH)
  row.whisper = PanelButton(row, L["Whisper"], 64, 18)
  row.whisper:SetPoint("RIGHT", -2, 0)
  row.whisper:SetScript("OnClick", function(self)
    local c, itemID = row.crafter, find.itemID
    if not (c and itemID and NS.Comm and NS.Comm.Request) then return end
    if not NS.Comm.Request(itemID, ReadQty(find.qty), c.name) then
      NS.Print(format(L["Could not whisper %s."], Short(c.name)))
    end
  end)
  row.name = Label(row, nil, "GameFontHighlightSmall")
  row.name:SetPoint("LEFT", 4, 0)
  row.name:SetPoint("RIGHT", row.whisper, "LEFT", -4, 0)
  return row
end

local function FillCrafterRow(row, c)
  row.crafter = c
  local text
  if c.mine then
    text = GOLD .. format(c.name == NS.Me and L["%s (you)"] or L["%s (alt)"], Short(c.name)) .. "|r"
  elseif c.online then
    text = GREEN .. Short(c.name) .. "|r  " .. GREY .. L["online"] .. "|r"
  else
    text = GREY .. Short(c.name) .. "  " .. L["offline"] .. "|r"
  end
  row.name:SetText(text)
  row.whisper:SetShown(not c.mine)
  row.whisper:SetEnabled(find.itemID ~= nil and not find.bop)
end

local function ReagentRow(parent, rowH)
  local row = IconRow(parent, rowH, 16)
  row.count = Label(row, nil, "GameFontHighlightSmall")
  row.count:SetPoint("RIGHT", -4, 0)
  row.count:SetJustifyH("RIGHT")
  row.name = Label(row, nil, "GameFontHighlightSmall")
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
  row.name:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
  row:SetScript("OnEnter", function(self) ShowTooltip(self, self.itemID) end)
  return row
end

-- reagent: {itemID=, need=, have=, short=?}
local function FillReagentRow(row, r)
  row.itemID = r.itemID
  row.icon:SetTexture(ItemIcon(r.itemID) or QUESTION)
  row.name:SetText(ItemName(r.itemID))
  local color = (r.have >= r.need) and GREEN or RED
  row.count:SetText(color .. r.have .. "/" .. r.need .. "|r")
end

local function BuildFind(p)
  -- Search box
  local box
  if HasTemplate("SearchBoxTemplate") then
    local ok, e = pcall(CreateFrame, "EditBox", "CraftBoardSearchBox", p, "SearchBoxTemplate")
    if ok then box = e end
  end
  if not box then
    box = CreateFrame("EditBox", "CraftBoardSearchBox", p, "InputBoxTemplate")
    box:SetScript("OnEscapePressed", box.ClearFocus)
  end
  box:SetSize(LEFT_W - 12, 20)
  box:SetPoint("TOPLEFT", 8, -2)
  box:SetAutoFocus(false)
  box:SetScript("OnEnterPressed", box.ClearFocus)
  local research = Debouncer(0.2, function() UI.RefreshFind(false) end)
  box:HookScript("OnTextChanged", research)
  find.search = box

  -- Results
  find.list = NewList("CraftBoardFindScroll", p, 32, FindRow, FillFindRow)
  find.list.box:SetPoint("TOPLEFT", 0, -28)
  find.list.box:SetPoint("BOTTOMLEFT", 0, 28)
  find.list.box:SetWidth(LEFT_W)

  find.status = Label(p, nil, "GameFontDisableSmall")
  find.status:SetPoint("BOTTOMLEFT", 2, 3)
  find.status:SetWidth(LEFT_W)
  find.status:SetWordWrap(true)

  -- Detail panel
  local d = CreateFrame("Frame", nil, p)
  d:SetPoint("TOPLEFT", LEFT_W + 10, 0)
  d:SetPoint("BOTTOMRIGHT")
  find.detail = d

  local divider = p:CreateTexture(nil, "ARTWORK")
  divider:SetColorTexture(1, 1, 1, 0.12)
  divider:SetWidth(1)
  divider:SetPoint("TOPLEFT", LEFT_W + 4, 0)
  divider:SetPoint("BOTTOMLEFT", LEFT_W + 4, 0)

  find.none = Label(d, L["Select a recipe to see who can craft it."], "GameFontDisable")
  find.none:SetPoint("CENTER")

  local body = CreateFrame("Frame", nil, d)
  body:SetAllPoints()
  find.body = body

  find.icon = body:CreateTexture(nil, "ARTWORK")
  find.icon:SetSize(32, 32)
  find.icon:SetPoint("TOPLEFT", 0, -2)
  local iconHit = CreateFrame("Frame", nil, body)
  iconHit:SetAllPoints(find.icon)
  iconHit:EnableMouse(true)
  iconHit:SetScript("OnEnter", function(self)
    if selectedID then ShowTooltip(self, find.itemID, selectedID) end
  end)
  iconHit:SetScript("OnLeave", HideTooltip)

  find.title = Label(body, nil, "GameFontNormal")
  find.title:SetPoint("TOPLEFT", find.icon, "TOPRIGHT", 6, -1)
  find.title:SetPoint("RIGHT")

  local qtyLabel = Label(body, L["Qty"], "GameFontHighlightSmall")
  qtyLabel:SetPoint("BOTTOMLEFT", find.icon, "BOTTOMRIGHT", 6, 2)
  find.qty = EditBox("CraftBoardFindQty", body, 36, 4, true)
  find.qty:SetPoint("LEFT", qtyLabel, "RIGHT", 10, 0)
  find.qty:SetText("1")
  find.qty:HookScript("OnTextChanged", Debouncer(0.2, function() UI.RefreshDetail() end))

  local ch = Label(body, L["Crafters"], "GameFontNormalSmall")
  ch:SetPoint("TOPLEFT", 0, -42)
  find.crafters = NewList("CraftBoardCraftersScroll", body, 20, CrafterRow, FillCrafterRow)
  find.crafters.box:SetPoint("TOPLEFT", 0, -56)
  find.crafters.box:SetPoint("RIGHT")
  find.crafters.box:SetHeight(104)

  local rh = Label(body, L["Reagents"], "GameFontNormalSmall")
  rh:SetPoint("TOPLEFT", 0, -166)
  find.reagents = NewList("CraftBoardReagentsScroll", body, 20, ReagentRow, FillReagentRow)
  find.reagents.box:SetPoint("TOPLEFT", 0, -180)
  find.reagents.box:SetPoint("RIGHT")
  find.reagents.box:SetHeight(100)

  local noteLabel = Label(body, L["Note"], "GameFontHighlightSmall")
  noteLabel:SetPoint("BOTTOMLEFT", 0, 34)
  find.note = EditBox("CraftBoardFindNote", body, 200, 60)
  find.note:SetPoint("LEFT", noteLabel, "RIGHT", 10, 0)
  find.note:SetPoint("RIGHT", -4, 0)

  find.post = PanelButton(body, L["Post request"], 110, 22)
  find.post:SetPoint("BOTTOMRIGHT", 0, 2)
  if find.post.SetMotionScriptsWhileDisabled then find.post:SetMotionScriptsWhileDisabled(true) end
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
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    if self:IsEnabled() then
      GameTooltip:SetText(L["Post an open request to the board"])
      GameTooltip:AddLine(L["Guild and realm-channel CraftBoard users see it for 24h."], 1, 1, 1, true)
    elseif find.bop then
      GameTooltip:SetText(BOP_NOTE)
    else
      GameTooltip:SetText(L["This recipe makes no item to request"])
    end
    GameTooltip:Show()
  end)
  find.post:SetScript("OnLeave", HideTooltip)

  find.hint = Label(body, nil, "GameFontDisableSmall")
  find.hint:SetPoint("BOTTOMLEFT", 0, 8)
  find.hint:SetPoint("RIGHT", find.post, "LEFT", -6, 0)
  if find.hint.SetWordWrap then find.hint:SetWordWrap(true) end
end

function UI.RefreshDetail()
  if not find.body then return end
  local e = SelectedEntry()
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
  find.bop = e.bop and true or false
  find.icon:SetTexture(RecipeIcon(e.recipeID, itemID))
  find.title:SetText(e.name)
  find.crafters:SetItems(e.crafters, L["No known crafters."], true)

  local qty = ReadQty(find.qty)
  local rec = NS.Recipes and NS.Recipes.Record and NS.Recipes.Record(e.recipeID)
  if rec and type(rec.r) == "table" and #rec.r > 0 and NS.Inventory and NS.Inventory.CanCraft then
    local cc = NS.Inventory.CanCraft(rec, qty)
    find.reagents:SetItems(cc.reagents, nil, true)
  elseif rec then
    find.reagents:SetItems({}, L["No reagents recorded."])
  else
    find.reagents:SetItems({}, L["Reagents unknown (peer recipe)."])
  end

  find.post:SetEnabled(itemID ~= nil and not find.bop)
  if find.bop then
    find.hint:SetText(GOLD .. BOP_NOTE .. "|r")
  else
    find.hint:SetText(itemID and "" or L["No item output"])
  end
end

function UI.RefreshFind(keepScroll)
  if not find.list then return end
  local text = find.search:GetText() or ""
  local results = NS.Recipes and NS.Recipes.Search and NS.Recipes.Search(text) or {}
  find.results = results

  local emptyText
  if #results == 0 then
    local needle = strtrim(text)
    if needle ~= "" and (HaveAnyRecipes() or PeerCounts() > 0) then
      emptyText = format(L["No known crafter for \"%s\"."], needle)
    else
      emptyText = EMPTY_RECIPES
    end
  end
  find.list:SetItems(results, emptyText, keepScroll)

  local total, online = PeerCounts()
  if total == 0 then
    find.status:SetText(EMPTY_PEERS)
  else
    find.status:SetText(format(L["%d recipes"], #results) .. DOT .. format(L["%d peers"], total) .. DOT
      .. format(L["%d online"], online))
  end
  UI.RefreshDetail()
end

-- Mine tab ------------------------------------------------------------------

local function MineRow(parent, rowH)
  local row = IconRow(parent, rowH, 18)
  row.count = Label(row, nil, "GameFontHighlightSmall")
  row.count:SetPoint("RIGHT", -4, 0)
  row.count:SetJustifyH("RIGHT")
  row.name = Label(row, nil, "GameFontHighlightSmall")
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
  row.name:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
  row.header = Label(row, nil, "GameFontNormal")
  row.header:SetPoint("LEFT", 2, 0)
  row:SetScript("OnEnter", function(self)
    local it = self.item
    if it and not it.header then ShowTooltip(self, it.outputItemID, it.recipeID) end
  end)
  row:SetScript("OnClick", function(self)
    local it = self.item
    if not it or it.header then return end
    selectedID = it.recipeID
    mine.list:Render()
    UI.RefreshShopping()
  end)
  return row
end

local function FillMineRow(row, it)
  row.item = it
  if it.header then
    row.header:SetText(it.header)
    row.header:Show()
    row.icon:Hide(); row.name:Hide(); row.count:Hide(); row.sel:Hide()
    row:EnableMouse(false)
    return
  end
  row:EnableMouse(true)
  row.header:Hide()
  row.icon:Show(); row.name:Show(); row.count:Show()
  row.icon:SetTexture(RecipeIcon(it.recipeID, it.outputItemID))
  row.name:SetText(it.name)
  if it.ready then
    row.count:SetText(GREEN .. format(L["x%d"], it.times or 1) .. "|r")
  else
    row.count:SetText(RED .. format(L["%d short"], it.missing) .. "|r")
  end
  row.sel:SetShown(it.recipeID == selectedID)
end

local function BuildMine(p)
  local cb = CreateFrame("CheckButton", "CraftBoardShowAll", p, "UICheckButtonTemplate")
  cb:SetSize(24, 24)
  cb:SetPoint("TOPLEFT", 0, 0)
  local cbText = cb.Text or cb.text or _G["CraftBoardShowAllText"]
  if cbText then
    cbText:SetFontObject("GameFontHighlightSmall")
    cbText:SetText(L["Show recipes I'm short on"])
  end
  cb:SetScript("OnClick", function(self)
    local db = UIDB()
    if db then db.showAll = self:GetChecked() and true or false end
    UI.RefreshMine()
  end)
  mine.showAll = cb

  mine.list = NewList("CraftBoardMineScroll", p, 22, MineRow, FillMineRow)
  mine.list.box:SetPoint("TOPLEFT", 0, -28)
  mine.list.box:SetPoint("BOTTOMLEFT", 0, 28)
  mine.list.box:SetWidth(LEFT_W)

  mine.status = Label(p, nil, "GameFontDisableSmall")
  mine.status:SetPoint("BOTTOMLEFT", 2, 3)
  mine.status:SetWidth(LEFT_W)
  mine.status:SetWordWrap(true)

  local divider = p:CreateTexture(nil, "ARTWORK")
  divider:SetColorTexture(1, 1, 1, 0.12)
  divider:SetWidth(1)
  divider:SetPoint("TOPLEFT", LEFT_W + 4, 0)
  divider:SetPoint("BOTTOMLEFT", LEFT_W + 4, 0)

  local d = CreateFrame("Frame", nil, p)
  d:SetPoint("TOPLEFT", LEFT_W + 10, 0)
  d:SetPoint("BOTTOMRIGHT")

  mine.icon = d:CreateTexture(nil, "ARTWORK")
  mine.icon:SetSize(32, 32)
  mine.icon:SetPoint("TOPLEFT", 0, -2)
  mine.title = Label(d, nil, "GameFontNormal")
  mine.title:SetPoint("TOPLEFT", mine.icon, "TOPRIGHT", 6, -1)
  mine.title:SetPoint("RIGHT")

  local qtyLabel = Label(d, L["Qty"], "GameFontHighlightSmall")
  qtyLabel:SetPoint("BOTTOMLEFT", mine.icon, "BOTTOMRIGHT", 6, 2)
  mine.qty = EditBox("CraftBoardMineQty", d, 36, 4, true)
  mine.qty:SetPoint("LEFT", qtyLabel, "RIGHT", 10, 0)
  mine.qty:SetText("1")
  mine.qty:HookScript("OnTextChanged", Debouncer(0.2, function() UI.RefreshShopping() end))

  local sh = Label(d, L["Shopping list"], "GameFontNormalSmall")
  sh:SetPoint("TOPLEFT", 0, -42)
  mine.shop = NewList("CraftBoardShopScroll", d, 20, ReagentRow, FillReagentRow)
  mine.shop.box:SetPoint("TOPLEFT", 0, -56)
  mine.shop.box:SetPoint("BOTTOMRIGHT", 0, 22)

  mine.shopStatus = Label(d, nil, "GameFontHighlightSmall")
  mine.shopStatus:SetPoint("BOTTOMLEFT", 0, 4)
  mine.shopStatus:SetPoint("RIGHT")
end

function UI.RefreshShopping()
  if not mine.shop then return end
  local R = NS.Recipes
  local rec = selectedID and R and R.Record and R.Record(selectedID)
  if not selectedID then
    mine.icon:SetTexture(nil)
    mine.title:SetText("")
    mine.shop:SetItems({}, L["Select a recipe to see what you're short on."])
    mine.shopStatus:SetText("")
    return
  end
  local name = (R and R.NameOf and R.NameOf(selectedID)) or format(L["Recipe %d"], selectedID)
  local itemID = OutputOf(selectedID)
  mine.icon:SetTexture(RecipeIcon(selectedID, itemID))
  mine.title:SetText(name)
  if not rec then
    mine.shop:SetItems({}, L["Not one of your recipes \226\128\148 reagents unknown."])
    mine.shopStatus:SetText("")
    return
  end
  local qty = ReadQty(mine.qty)
  local list, unknown = {}, {}
  if NS.Inventory and NS.Inventory.ShoppingList then
    list, unknown = NS.Inventory.ShoppingList({ { selectedID, qty } })
  end
  if #list == 0 then
    mine.shop:SetItems({}, format(L["You have everything for %dx."], qty))
    mine.shopStatus:SetText("")
  else
    mine.shop:SetItems(list, nil, true)
    mine.shopStatus:SetText(format(L["%s for %dx"], RED .. format(L["%d reagent(s) short"], #list) .. "|r", qty))
  end
end

function UI.RefreshMine(keepScroll)
  if not mine.list then return end
  local R, I = NS.Recipes, NS.Inventory
  local db = UIDB()
  local showAll = db and db.showAll or false
  mine.showAll:SetChecked(showAll)

  local entries = {}
  if showAll and I and I.CanCraft then
    for recipeID, rec in pairs(R and R.Mine and R.Mine() or {}) do
      local cc = I.CanCraft(rec)
      entries[#entries + 1] = {
        recipeID = recipeID, outputItemID = rec.o, p = rec.p,
        name = rec.n or R.NameOf(recipeID) or format(L["Recipe %d"], recipeID),
        ready = cc.ready, times = cc.times, missing = #cc.missing,
      }
    end
  else
    for _, c in ipairs(I and I.Craftable and I.Craftable() or {}) do
      entries[#entries + 1] = {
        recipeID = c.recipeID, outputItemID = c.outputItemID, p = c.record and c.record.p,
        name = c.name, ready = true, times = c.times, missing = 0,
      }
    end
  end

  -- Group by profession (sorted by profession name, then craftable first, then name).
  local groups, order = {}, {}
  for _, e in ipairs(entries) do
    local key = e.p or "?"
    if not groups[key] then
      groups[key] = { name = ProfName(e.p), list = {} }
      order[#order + 1] = key
    end
    local g = groups[key].list
    g[#g + 1] = e
  end
  table.sort(order, function(a, b) return groups[a].name < groups[b].name end)
  local items = {}
  for _, key in ipairs(order) do
    local g = groups[key]
    table.sort(g.list, function(a, b)
      if a.ready ~= b.ready then return a.ready end
      return a.name < b.name
    end)
    items[#items + 1] = { header = g.name }
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
  mine.status:SetText(#entries > 0 and format(showAll and L["%d recipes"] or L["%d craftable now"], #entries) or "")
  UI.RefreshShopping()
end

-- Requests tab --------------------------------------------------------------

local function IsMyPost(post)
  return post.mine or (NS.Me and post.from == NS.Me)
end

local function RequestRow(parent, rowH)
  local row = IconRow(parent, rowH, 28)
  row.action = PanelButton(row, L["Whisper"], 72, 20)
  row.action:SetPoint("RIGHT", -2, 0)
  row.action:SetScript("OnClick", function()
    local post = row.post
    if not post then return end
    if IsMyPost(post) then
      if NS.Comm and NS.Comm.Retract then NS.Comm.Retract(post.id) end
      UI.Refresh()
    else
      local msg = format(L["[CraftBoard] I can craft %s for you."], ItemLink(post.item))
      if not (NS.Comm and NS.Comm.Whisper and NS.Comm.Whisper(post.from, msg)) then
        NS.Print(format(L["Could not whisper %s."], Short(post.from)))
      end
    end
  end)
  row.who = Label(row, nil, "GameFontHighlightSmall")
  row.who:SetPoint("RIGHT", row.action, "LEFT", -8, 0)
  row.who:SetJustifyH("RIGHT")
  row.name = Label(row, nil, "GameFontHighlight")
  row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -1)
  row.name:SetPoint("RIGHT", row.who, "LEFT", -8, 0)
  row.note = Label(row, nil, "GameFontDisableSmall")
  row.note:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, 1)
  row.note:SetPoint("RIGHT", row.who, "LEFT", -8, 0)
  row:SetScript("OnEnter", function(self)
    if self.post then ShowTooltip(self, self.post.item) end
  end)
  return row
end

local function FillRequestRow(row, post)
  row.post = post
  row.icon:SetTexture(ItemIcon(post.item) or QUESTION)
  row.name:SetText(ItemName(post.item) .. "  " .. GREY .. format(L["x%d"], post.qty or 1) .. "|r")
  row.note:SetText(post.note ~= "" and post.note or "")
  local mineP = IsMyPost(post)
  row.who:SetText((mineP and (GOLD .. L["you"] .. "|r") or Short(post.from)) .. DOT .. Age(post.t))
  row.action:SetText(mineP and L["Retract"] or L["Whisper"])
end

local function BuildRequests(p)
  reqs.list = NewList("CraftBoardRequestsScroll", p, 36, RequestRow, FillRequestRow)
  reqs.list.box:SetPoint("TOPLEFT")
  reqs.list.box:SetPoint("BOTTOMRIGHT", 0, 18)
  reqs.status = Label(p, nil, "GameFontDisableSmall")
  reqs.status:SetPoint("BOTTOMLEFT", 2, 3)
  reqs.status:SetPoint("RIGHT")
end

function UI.RefreshRequests(keepScroll)
  if not reqs.list then return end
  local posts = NS.Comm and NS.Comm.Requests and NS.Comm.Requests() or {}
  local total = PeerCounts()
  local emptyText
  if #posts == 0 then
    emptyText = total == 0 and EMPTY_PEERS or L["No open requests. Post one from the Find tab."]
  end
  reqs.list:SetItems(posts, emptyText, keepScroll)
  reqs.status:SetText(#posts > 0 and format(L["%d open request(s), newest first"], #posts) or "")
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
end

local REFRESH = {
  function(keep) UI.RefreshFind(keep) end,
  function(keep) UI.RefreshMine(keep) end,
  function(keep) UI.RefreshRequests(keep) end,
}

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
  REFRESH[i](false)
end

local TAB_NAMES = { L["Find"], L["Mine"], L["Requests"] }

local function BuildTabs(f)
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
          tab:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 10, 2)
        else
          tab:SetPoint("LEFT", tabs[i - 1], "RIGHT", 4, 0)
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
    tab:SetScript("OnClick", function(self) SelectTab(self:GetID()) end)
    tabs[i] = tab
  end
end

local function Create()
  local f = CreateFrame("Frame", "CraftBoardFrame", UIParent, "BasicFrameTemplateWithInset")
  frame = f
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

  local title = f.TitleText
  if not title then
    title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    if f.TitleBg then
      title:SetPoint("CENTER", f.TitleBg, "CENTER", 0, 0)
    else
      title:SetPoint("TOP", 0, -5)
    end
  end
  title:SetText("CraftBoard")

  local content = CreateFrame("Frame", nil, f)
  content:SetPoint("TOPLEFT", 12, -30)
  content:SetPoint("BOTTOMRIGHT", -12, 10)
  for i = 1, #TAB_NAMES do
    local p = CreateFrame("Frame", nil, content)
    p:SetAllPoints()
    p:Hide()
    panels[i] = p
  end
  BuildFind(panels[1])
  BuildMine(panels[2])
  BuildRequests(panels[3])
  BuildTabs(f)

  if UISpecialFrames then tinsert(UISpecialFrames, "CraftBoardFrame") end

  f:SetScript("OnShow", function()
    dirty = false
    SelectTab(activeTab)
  end)
  f:SetScript("OnHide", function()
    HideTooltip()
    if find.search then find.search:ClearFocus() end
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
