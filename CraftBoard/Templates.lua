-- CraftBoard Templates: the player's own wording for the whispers CraftBoard types in for them.
--   request: asking a crafter (Find's Whisper, the board's whisper to a crafter)
--   offer:   offering to craft a request (Requests' Offer and Whisper)
-- CraftBoardDB.templates[kind] = text with {item} and {qty} (nil: the built-in text). Every
-- whisper is still one click (or Enter) by the player; this only changes what it says.
-- /cb texts and the settings' "Whisper texts" button open a small editor.
local ADDON, NS = ...

local Templates = {}
NS.Templates = Templates

local L = NS.L
local format = string.format

local MAX_LEN = 200     -- typed text; a whisper holds 255 bytes, item links take the rest
local KINDS = { "request", "offer" }

local function Saved(kind)
  local t = type(CraftBoardDB) == "table" and type(CraftBoardDB.templates) == "table" and CraftBoardDB.templates[kind]
  return type(t) == "string" and t ~= "" and t or nil
end

local MAX_WHISPER = 255   -- bytes in one chat message

-- s cut to at most n bytes on a UTF-8 character boundary.
local function CutBytes(s, n)
  if #s <= n then return s end
  local i = n
  while i > 0 and (s:byte(i + 1) or 0) >= 128 and (s:byte(i + 1) or 0) < 192 do i = i - 1 end
  return s:sub(1, i)
end

local function Expand(text, item, qty)
  item = tostring(item or ""):gsub("%%", "%%%%")
  return (text:gsub("{item}", item):gsub("{qty}", tostring(qty or 1)))
end

-- {item} and {qty} filled in (a % in the player's text stays a %), within one chat message:
-- too long with the item's link, the plain "[Name]" goes in instead, then the text is cut.
local function Fill(text, item, qty)
  local out = Expand(text, item, qty)
  if #out <= MAX_WHISPER then return out end
  out = Expand(text, NS.StripCodes(tostring(item or "")), qty)
  return CutBytes(out, MAX_WHISPER)
end
Templates.Fill = Fill

-- The text a whisper starts with. item: a link or a name.
function Templates.Request(item, qty)
  local t = Saved("request")
  if t then return Fill(t, item, qty) end
  return format(L["[CraftBoard] Could you craft %dx %s for me? I have/can get the mats."], qty or 1, item)
end

-- builtin: the text without an own template, when it isn't the item one (a profession ask).
function Templates.Offer(item, qty, builtin)
  local t = Saved("offer")
  if t then return Fill(t, item, qty) end
  return builtin or format(L["[CraftBoard] I can craft %s for you."], item)
end

-- The default wording as a template ("{item}", "{qty}" where the built-in text has them).
local function DefaultTemplate(kind)
  if kind == "request" then
    -- 7777 marks where the quantity goes, whatever the translation puts around it.
    return (format(L["[CraftBoard] Could you craft %dx %s for me? I have/can get the mats."], 7777, "{item}"):gsub("7777", "{qty}", 1))
  end
  return format(L["[CraftBoard] I can craft %s for you."], "{item}")
end
Templates.Default = DefaultTemplate

-- Saves the player's text; "" or the default wording goes back to the built-in text.
function Templates.Set(kind, text)
  if type(CraftBoardDB) ~= "table" then return end
  if type(CraftBoardDB.templates) ~= "table" then CraftBoardDB.templates = {} end
  text = type(text) == "string" and NS.StripCodes(text):gsub("[%c|]", ""):gsub("^%s+", ""):gsub("%s+$", "") or ""
  text = CutBytes(text, MAX_LEN)
  if text == "" or text == DefaultTemplate(kind) then text = nil end
  CraftBoardDB.templates[kind] = text
end

function Templates.Get(kind)
  return Saved(kind) or DefaultTemplate(kind)
end

-- Editor ------------------------------------------------------------------------

local editor

local function Build()
  local f = CreateFrame("Frame", "CraftBoardTemplatesFrame", UIParent, "BasicFrameTemplateWithInset")
  f:SetSize(520, 250)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:Hide()
  if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "CraftBoardTemplatesFrame") end
  local title = f.TitleText or f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  if not f.TitleText then title:SetPoint("TOP", 0, -5) end
  title:SetText(L["CraftBoard whisper texts"])

  local help = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  help:SetPoint("TOPLEFT", 18, -34)
  help:SetPoint("RIGHT", -18, 0)
  help:SetJustifyH("LEFT")
  help:SetText(L["{item} becomes the item's link and {qty} the quantity. CraftBoard still only types the whisper in for you: nothing is sent without your click."])

  f.boxes = {}
  local y = -76
  local labels = { request = L["Asking a crafter"], offer = L["Offering to craft"] }
  for _, kind in ipairs(KINDS) do
    local label = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetPoint("TOPLEFT", 18, y)
    label:SetText(labels[kind])
    local box = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    box:SetAutoFocus(false)
    box:SetSize(470, 22)
    box:SetPoint("TOPLEFT", 24, y - 16)
    box:SetMaxLetters(MAX_LEN)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    f.boxes[kind] = box
    y = y - 58
  end

  local save = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  save:SetSize(110, 22)
  save:SetPoint("BOTTOMRIGHT", -16, 14)
  save:SetText(L["Save"])
  save:SetScript("OnClick", function()
    for kind, box in pairs(f.boxes) do Templates.Set(kind, box:GetText()) end
    NS.Print(L["Whisper texts saved."])
    f:Hide()
  end)
  local reset = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  reset:SetSize(130, 22)
  reset:SetPoint("RIGHT", save, "LEFT", -8, 0)
  reset:SetText(L["Use the defaults"])
  reset:SetScript("OnClick", function()
    for kind, box in pairs(f.boxes) do box:SetText(DefaultTemplate(kind)) end
  end)
  f:SetScript("OnShow", function()
    for kind, box in pairs(f.boxes) do
      box:SetText(Templates.Get(kind))
      if box.SetCursorPosition then box:SetCursorPosition(0) end
    end
  end)
  return f
end

function Templates.Show()
  if InCombatLockdown and InCombatLockdown() then return end
  if not editor then
    local ok, f = pcall(Build)
    if not ok then
      NS.Print(tostring(f))
      return
    end
    editor = f
  end
  editor:Show()
end
