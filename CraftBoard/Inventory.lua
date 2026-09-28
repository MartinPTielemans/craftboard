-- CraftBoard Inventory: reagent counts, craftability, shopping lists, cached item names.
local ADDON, NS = ...

local Inventory = {}
NS.Inventory = Inventory

local L = NS.L

-- Bags + bank + reagent bank.
function Inventory.Count(itemID)
  if type(itemID) ~= "number" then return 0 end
  if C_Item and C_Item.GetItemCount then
    return C_Item.GetItemCount(itemID, true, false, true) or 0
  elseif GetItemCount then
    return GetItemCount(itemID, true) or 0
  end
  return 0
end

-- A reagent slot may accept several items (quality tiers): have = sum over all of them.
-- alts is the optional list stored on a reagent entry ({ itemID, qty, alts = {...} }).
function Inventory.SlotCount(itemID, alts)
  local n = Inventory.Count(itemID)
  if type(alts) == "table" then
    for _, id in ipairs(alts) do
      if id ~= itemID then n = n + Inventory.Count(id) end
    end
  end
  return n
end

-- Accepts a recipe record ({r={ {itemID,qty},... }}) or a recipeID.
local function ResolveRecord(recipe)
  if type(recipe) == "number" then
    return NS.Recipes and NS.Recipes.Record and NS.Recipes.Record(recipe)
  end
  if type(recipe) == "table" then return recipe end
  return nil
end

-- Crafts needed for `count` items of a record's output (recipes may yield several per craft).
function Inventory.CraftsFor(rec, count)
  local y = type(rec) == "table" and tonumber(rec.y) or 1
  return math.ceil((count or 1) / math.max(1, y or 1))
end

-- count: how many of the output item are wanted (default 1), turned into crafts by the yield.
-- {ready=bool, reagents={ {itemID=,need=,have=} }, missing={ same, only short ones }, times=max crafts}
function Inventory.CanCraft(recipe, count)
  local rec = ResolveRecord(recipe)
  local times = Inventory.CraftsFor(rec, count)
  local result = { ready = false, reagents = {}, missing = {}, times = 0 }
  if not rec or type(rec.r) ~= "table" then return result end
  local maxTimes
  for _, reg in ipairs(rec.r) do
    local itemID, qty = reg[1], reg[2]
    if itemID and qty and qty > 0 then
      local have = Inventory.SlotCount(itemID, reg.alts)
      local row = { itemID = itemID, need = qty * times, have = have, alts = reg.alts }
      result.reagents[#result.reagents + 1] = row
      if have < row.need then result.missing[#result.missing + 1] = row end
      local t = math.floor(have / qty)
      if not maxTimes or t < maxTimes then maxTimes = t end
    end
  end
  result.ready = #result.missing == 0
  -- A recipe with no basic reagents has no count limit; report 1 so it's "craftable".
  result.times = maxTimes or 1
  return result
end

-- list: { {recipeID, qty}, ... } (also accepts {recipeID=,qty=} or bare recipeIDs).
-- Returns aggregated shortages: { {itemID=, need=, have=, short=}, ... }, plus unknown recipeIDs.
function Inventory.ShoppingList(list)
  local need, order, unknown, alts = {}, {}, {}, {}
  for _, e in ipairs(list or {}) do
    local recipeID, qty
    if type(e) == "number" then
      recipeID, qty = e, 1
    elseif type(e) == "table" then
      recipeID = e.recipeID or e[1]
      qty = e.qty or e[2] or 1
    end
    local rec = recipeID and ResolveRecord(recipeID)
    if rec and type(rec.r) == "table" then
      for _, reg in ipairs(rec.r) do
        local itemID, n = reg[1], reg[2]
        if itemID and n then
          if not need[itemID] then order[#order + 1] = itemID end
          need[itemID] = (need[itemID] or 0) + n * qty
          if type(reg.alts) == "table" and not alts[itemID] then alts[itemID] = reg.alts end
        end
      end
    elseif recipeID then
      unknown[#unknown + 1] = recipeID
    end
  end
  local out = {}
  for _, itemID in ipairs(order) do
    local have = Inventory.SlotCount(itemID, alts[itemID])
    if have < need[itemID] then
      out[#out + 1] = { itemID = itemID, need = need[itemID], have = have, short = need[itemID] - have }
    end
  end
  return out, unknown
end

-- My current char's recipes that I can craft right now:
-- { {recipeID=, name=, outputItemID=, times=, record=}, ... } sorted by name.
function Inventory.Craftable()
  local out = {}
  local mine = NS.Recipes and NS.Recipes.Mine and NS.Recipes.Mine() or {}
  for recipeID, rec in pairs(mine) do
    local cc = Inventory.CanCraft(rec)
    if cc.ready then
      out[#out + 1] = {
        recipeID = recipeID,
        name = rec.n or (NS.Recipes and NS.Recipes.NameOf and NS.Recipes.NameOf(recipeID)) or string.format(L["Recipe %d"], recipeID),
        outputItemID = rec.o,
        times = cc.times,
        record = rec,
      }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- Item names. Returns the name or nil; on nil a load is requested and ITEM_NAMES_UPDATED fires
-- (coalesced) once names arrive.
local requested = {}
local firePending = false

local function FireNamesUpdated()
  if firePending then return end
  if C_Timer and C_Timer.After then
    firePending = true
    C_Timer.After(0.2, function()
      firePending = false
      NS.Fire("ITEM_NAMES_UPDATED")
    end)
  else
    NS.Fire("ITEM_NAMES_UPDATED")
  end
end

local function CachedName(itemID)
  if C_Item then
    if C_Item.GetItemNameByID then
      local n = C_Item.GetItemNameByID(itemID)
      if n then return n end
    end
    if C_Item.GetItemInfo then
      local n = C_Item.GetItemInfo(itemID)
      if n then return n end
    end
  end
  if GetItemInfo then return (GetItemInfo(itemID)) end
  return nil
end

function Inventory.ItemName(itemID)
  if type(itemID) ~= "number" then return nil end
  local name = CachedName(itemID)
  if name then return name end
  if requested[itemID] then return nil end
  requested[itemID] = true
  if C_Item and C_Item.DoesItemExistByID and not C_Item.DoesItemExistByID(itemID) then
    return nil
  end
  if Item and Item.CreateFromItemID then
    pcall(function()
      local item = Item:CreateFromItemID(itemID)
      item:ContinueOnItemLoad(function()
        FireNamesUpdated()
      end)
    end)
  elseif C_Item and C_Item.RequestLoadItemDataByID then
    C_Item.RequestLoadItemDataByID(itemID)
  end
  return nil
end

-- Retry failed lookups when the client reports item data arriving (fallback path).
NS.Register("GET_ITEM_INFO_RECEIVED", function(_, itemID, success)
  if itemID and requested[itemID] and success then FireNamesUpdated() end
end)

-- Per-character item counts, so tooltips and reagent slots can say what my alts hold:
-- CraftBoardDB.chars[Me].items = { [itemID] = bags + bank }, chars[Me].bank = last known bank
-- counts. The bank is only readable while it is open, so a bags rescan keeps the saved bank part.
local function NumSlots(bag)
  local f = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
  if not f then return 0 end
  local ok, n = pcall(f, bag)
  return ok and tonumber(n) or 0
end

-- itemID, stack count of one slot, or nil when empty.
local function SlotItem(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
    if ok and type(info) == "table" and type(info.itemID) == "number" then
      return info.itemID, tonumber(info.stackCount) or 1
    end
    return nil
  end
  if GetContainerItemInfo then
    local ok, _, count, _, _, _, _, link, _, _, id = pcall(GetContainerItemInfo, bag, slot)
    if not ok then return nil end
    id = type(id) == "number" and id or (type(link) == "string" and tonumber(link:match("item:(%d+)")))
    if id then return id, tonumber(count) or 1 end
  end
  return nil
end

local function AddContainer(counts, bag)
  if type(bag) ~= "number" then return end
  for slot = 1, NumSlots(bag) do
    local id, n = SlotItem(bag, slot)
    if id then counts[id] = (counts[id] or 0) + n end
  end
end

local function BagIDs()
  local ids = {}
  for bag = 0, NUM_BAG_SLOTS or 4 do ids[#ids + 1] = bag end
  local BI = Enum and Enum.BagIndex
  if BI and BI.ReagentBag then ids[#ids + 1] = BI.ReagentBag end
  return ids
end

-- The bank container, the bank bags, and a mainline client's character bank tabs if it has them.
local function BankIDs()
  local BI = Enum and Enum.BagIndex
  local ids = {}
  local main = (BI and BI.Bank) or BANK_CONTAINER or -1
  ids[#ids + 1] = main
  local first = (NUM_BAG_SLOTS or 4) + 1
  for bag = first, first + (NUM_BANKBAGSLOTS or 7) - 1 do ids[#ids + 1] = bag end
  if BI and BI.CharacterBankTab_1 then
    for i = 1, 6 do
      local tab = BI["CharacterBankTab_" .. i]
      if type(tab) == "number" then ids[#ids + 1] = tab end
    end
  end
  return ids
end

local bankOpen = false

local function MyRecord()
  local db = type(CraftBoardDB) == "table" and CraftBoardDB
  if not (db and NS.Me and type(db.chars) == "table") then return nil end
  local c = db.chars[NS.Me]
  return type(c) == "table" and c or nil
end

local function SameCounts(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do if b[k] ~= v then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

-- Rescan bags (and the bank while it's open) into chars[Me].items. True when the counts changed.
local function RecordItems()
  local c = MyRecord()
  if not c then return false end
  local changed = false
  if bankOpen then
    local bank = {}
    for _, bag in ipairs(BankIDs()) do AddContainer(bank, bag) end
    if not SameCounts(bank, c.bank) then c.bank, changed = bank, true end
  end
  local items = {}
  for _, bag in ipairs(BagIDs()) do AddContainer(items, bag) end
  for id, n in pairs(type(c.bank) == "table" and c.bank or {}) do
    if type(id) == "number" and type(n) == "number" then items[id] = (items[id] or 0) + n end
  end
  if not SameCounts(items, c.items) then c.items, changed = items, true end
  return changed
end

-- My OTHER characters holding itemID: total, { {name="Name-Realm", n=}, ... } (most first).
function Inventory.AltCounts(itemID)
  local list, total = {}, 0
  local chars = type(CraftBoardDB) == "table" and type(CraftBoardDB.chars) == "table" and CraftBoardDB.chars
  if type(itemID) ~= "number" or not chars then return 0, list end
  for key, c in pairs(chars) do
    local n = key ~= NS.Me and type(c) == "table" and type(c.items) == "table" and tonumber(c.items[itemID]) or 0
    if n > 0 then
      list[#list + 1] = { name = key, n = n }
      total = total + n
    end
  end
  table.sort(list, function(a, b)
    if a.n ~= b.n then return a.n > b.n end
    return a.name < b.name
  end)
  return total, list
end

-- "+12 on alts" for a reagent slot, or nil.
function Inventory.AltText(itemID)
  local total = Inventory.AltCounts(itemID)
  if total <= 0 then return nil end
  return string.format(L["+%d on alts"], total)
end

-- Let the UI refresh have/need when bags change (and record the new counts first).
local bagPending = false
local function BagsChanged()
  bagPending = false
  pcall(RecordItems)
  NS.Fire("INVENTORY_UPDATED")
end

NS.Register("BAG_UPDATE_DELAYED", function()
  if bagPending then return end
  if C_Timer and C_Timer.After then
    bagPending = true
    C_Timer.After(0.3, BagsChanged)
  else
    BagsChanged()
  end
end)

local bankPending = false
local function BankChanged()
  bankPending = false
  local ok, changed = pcall(RecordItems)
  if ok and changed then NS.Fire("INVENTORY_UPDATED") end
end

local function BankSoon()
  if bankPending then return end
  if C_Timer and C_Timer.After then
    bankPending = true
    C_Timer.After(0.3, BankChanged)
  else
    BankChanged()
  end
end

NS.Register("BANKFRAME_OPENED", function()
  bankOpen = true
  BankSoon()
end)
NS.Register("PLAYERBANKSLOTS_CHANGED", function()
  if bankOpen then BankSoon() end
end)
-- Rescan once more on close (the bank is still readable in this event), then stop.
NS.Register("BANKFRAME_CLOSED", function()
  if not bankOpen then return end
  local ok, changed = pcall(RecordItems)
  bankOpen = false
  if ok and changed then NS.Fire("INVENTORY_UPDATED") end
end)

NS.Register("PLAYER_LOGIN", function()
  if C_Timer and C_Timer.After then
    C_Timer.After(3, BankChanged)
  else
    BankChanged()
  end
end)

-- Item link when cached, else the name, else "item <id>" (chat lines and notices).
function Inventory.ItemLabel(itemID)
  if type(itemID) ~= "number" then return "?" end
  local link
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if getInfo then
    local ok, a, b = pcall(getInfo, itemID)
    if ok and type(a) == "table" then link = a.itemLink or a.hyperlink or a.link
    elseif ok then link = b end
  end
  return link or Inventory.ItemName(itemID) or string.format(L["item %d"], itemID)
end
NS.ItemLabel = Inventory.ItemLabel

-- My recipe (any character, the current one first) making itemID:
-- recipeID, record, charKey, current. nil when none of my characters knows one.
function Inventory.MyRecipeFor(itemID)
  if type(itemID) ~= "number" or type(CraftBoardDB) ~= "table" or type(CraftBoardDB.chars) ~= "table" then return nil end
  local function find(c)
    if type(c) ~= "table" or type(c.recipes) ~= "table" then return nil end
    for id, rec in pairs(c.recipes) do
      if type(rec) == "table" and rec.o == itemID then return id, rec end
    end
  end
  if NS.Me then
    local id, rec = find(CraftBoardDB.chars[NS.Me])
    if id then return id, rec, NS.Me, true end
  end
  for key, c in pairs(CraftBoardDB.chars) do
    if key ~= NS.Me then
      local id, rec = find(c)
      if id then return id, rec, key, false end
    end
  end
  return nil
end

function NS.CanCraftItem(itemID)
  return Inventory.MyRecipeFor(itemID) ~= nil
end

-- Every reagent of a craft list with have/need, needs summed over the list:
-- list { {record=, qty= (output items)}, ... } -> { {itemID=, need=, have=, alts=}, ... } in first-seen order.
function Inventory.Totals(list)
  local need, order, alts = {}, {}, {}
  for _, e in ipairs(list or {}) do
    local rec = e.record
    local qty = Inventory.CraftsFor(rec, e.qty)
    if type(rec) == "table" and type(rec.r) == "table" then
      for _, reg in ipairs(rec.r) do
        local itemID, n = reg[1], reg[2]
        if itemID and n then
          if not need[itemID] then order[#order + 1] = itemID end
          need[itemID] = (need[itemID] or 0) + n * qty
          if type(reg.alts) == "table" and not alts[itemID] then alts[itemID] = reg.alts end
        end
      end
    end
  end
  local out = {}
  for _, itemID in ipairs(order) do
    out[#out + 1] = { itemID = itemID, need = need[itemID], have = Inventory.SlotCount(itemID, alts[itemID]),
      alts = alts[itemID] }
  end
  return out
end
