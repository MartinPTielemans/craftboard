-- CraftBoard Marks: what the player marks for themselves, all local and account-wide.
--   Pinned recipes: CraftBoardDB.pinned[recipeID] = time. A "Pinned" group leads Find and each
--   profession in Plan.
--   Wishlist: CraftBoardDB.wish[itemID] = { t=, n=name }. Items wanted (a crafted item, or the
--   recipe item that teaches it). When someone links a wished item in public chat (or a recipe
--   item whose name ends in a wished item's name, "Pattern: Runecloth Bag"), one quiet chat line,
--   at most once per item and player every WISH_GAP. Nothing is sent.
-- Fires MARKS_UPDATED on any change.
local ADDON, NS = ...

local Marks = {}
NS.Marks = Marks

local L = NS.L
local format = string.format

local WISH_GAP = 10 * 60
local MAX_WISH = 100

local function DB()
  if type(CraftBoardDB) ~= "table" then return nil end
  if type(CraftBoardDB.pinned) ~= "table" then CraftBoardDB.pinned = {} end
  if type(CraftBoardDB.wish) ~= "table" then CraftBoardDB.wish = {} end
  return CraftBoardDB
end

-- Pinned ------------------------------------------------------------------------

function Marks.IsPinned(recipeID)
  local db = DB()
  return db ~= nil and recipeID ~= nil and db.pinned[recipeID] ~= nil
end

function Marks.SetPinned(recipeID, on)
  local db = DB()
  if not (db and type(recipeID) == "number") then return end
  db.pinned[recipeID] = on and (db.pinned[recipeID] or time()) or nil
  NS.Fire("MARKS_UPDATED")
end

function Marks.TogglePin(recipeID)
  Marks.SetPinned(recipeID, not Marks.IsPinned(recipeID))
end

function Marks.AnyPinned()
  local db = DB()
  return db ~= nil and next(db.pinned) ~= nil
end

-- Wishlist ----------------------------------------------------------------------

local function ItemName(itemID)
  local name = NS.Inventory and NS.Inventory.ItemName and NS.Inventory.ItemName(itemID)
  return type(name) == "string" and name or nil
end

function Marks.IsWished(itemID)
  local db = DB()
  return db ~= nil and itemID ~= nil and db.wish[itemID] ~= nil
end

-- Returns false when the list is full.
function Marks.SetWished(itemID, on)
  local db = DB()
  if not (db and type(itemID) == "number") then return false end
  if on then
    if not db.wish[itemID] then
      local n = 0
      for _ in pairs(db.wish) do n = n + 1 end
      if n >= MAX_WISH then return false end
    end
    local e = type(db.wish[itemID]) == "table" and db.wish[itemID] or { t = time() }
    e.n = ItemName(itemID) or e.n
    db.wish[itemID] = e
  else
    db.wish[itemID] = nil
  end
  NS.Fire("MARKS_UPDATED")
  return true
end

function Marks.ToggleWish(itemID)
  local on = not Marks.IsWished(itemID)
  if not Marks.SetWished(itemID, on) then
    NS.Print(format(L["Your wishlist is full (%d items). Remove one first."], MAX_WISH))
    return nil
  end
  return on
end

-- { {itemID=, name=, t=}, ... } by name.
function Marks.WishList()
  local db = DB()
  local out = {}
  for id, e in pairs(db and db.wish or {}) do
    if type(id) == "number" then
      local name = ItemName(id) or (type(e) == "table" and e.n) or format(L["Item %d"], id)
      out[#out + 1] = { itemID = id, name = name, t = type(e) == "table" and e.t or 0 }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- The wished item a chat line's link is about: its own ID, else a recipe item ("Pattern: X",
-- "Formula: Enchant X") whose name, after the colon, is a wished item's name.
local byName, byNameDirty = nil, true
local function WishedByName()
  if byName and not byNameDirty then return byName end
  byName, byNameDirty = {}, false
  local db = DB()
  for id, e in pairs(db and db.wish or {}) do
    local name = ItemName(id) or (type(e) == "table" and e.n)
    if type(name) == "string" and name ~= "" then byName[strlower(name)] = id end
  end
  return byName
end

function Marks.WishedIn(text)
  local db = DB()
  if not (db and next(db.wish) and type(text) == "string") then return nil end
  for idText, name in text:gmatch("|Hitem:(%d+)[^|]*|h%[(.-)%]|h") do
    local id = tonumber(idText)
    if id and db.wish[id] then return id, id end
    local after = name:match("^[^:]+:%s*(.+)$")
    local wished = after and WishedByName()[strlower(NS.StripCodes(after))]
    if wished then return wished, id end
  end
  return nil
end

local alerted = {}   -- [itemID .. sender] = time of the last line

-- A chat line from someone: say so when it links something on the wishlist.
function Marks.CheckChat(text, sender, channel)
  if type(CraftBoardDB) == "table" and CraftBoardDB.wishNotice == false then return end
  if type(sender) ~= "string" or sender == "" then return end
  local full = NS.FullName and NS.FullName(sender) or sender
  if not full or (NS.IsMe and NS.IsMe(full)) or (NS.IsIgnored and NS.IsIgnored(full)) then return end
  local wished, linked = Marks.WishedIn(text)
  if not wished then return end
  local key = wished .. "\t" .. full
  local now = time()
  if alerted[key] and now - alerted[key] < WISH_GAP then return end
  alerted[key] = now
  local label = NS.ItemLabel and NS.ItemLabel(linked) or format(L["Item %d"], linked)
  local who = format("|Hplayer:%s|h[%s]|h", full, NS.ShortName and NS.ShortName(full) or full)
  if type(channel) == "string" and channel ~= "" then
    NS.Print(format(L["Wishlist: %s linked %s in %s."], who, label, channel))
  else
    NS.Print(format(L["Wishlist: %s linked %s."], who, label))
  end
end

local function Secret(...)
  if not issecretvalue then return false end
  for i = 1, select("#", ...) do
    if issecretvalue((select(i, ...))) then return true end
  end
  return false
end

-- "1. Trade - City" -> "Trade" (the base name before " - ").
local function ChannelLabel(name)
  if type(name) ~= "string" then return nil end
  name = name:gsub("^%d+%.%s*", "")
  return name:match("^(.-)%s+%-%s+") or name
end

NS.Register("CHAT_MSG_CHANNEL", function(_, text, sender, _, channelName, _, _, _, _, baseName)
  if Secret(text, sender) then return end
  Marks.CheckChat(text, sender, ChannelLabel(baseName ~= "" and baseName or channelName))
end)
for event, label in pairs({ CHAT_MSG_SAY = "SAY", CHAT_MSG_YELL = "YELL", CHAT_MSG_GUILD = "GUILD" }) do
  NS.Register(event, function(_, text, sender)
    if Secret(text, sender) then return end
    local name = _G[label]
    Marks.CheckChat(text, sender, type(name) == "string" and name or nil)
  end)
end

if NS.RegisterCallback then
  NS.RegisterCallback(Marks, "MARKS_UPDATED", function() byNameDirty = true end)
  NS.RegisterCallback(Marks, "ITEM_NAMES_UPDATED", function() byNameDirty = true end)
end

-- /cb wish: the wishlist in chat.
function Marks.PrintWishes()
  local list = Marks.WishList()
  if #list == 0 then
    NS.Print(L["Your wishlist is empty. Right-click a recipe in Find to add its item."])
    return
  end
  NS.Print(format(L["Wishlist (%d):"], #list))
  for _, e in ipairs(list) do
    NS.Print("  " .. (NS.ItemLabel and NS.ItemLabel(e.itemID) or e.name))
  end
end
