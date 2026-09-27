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

-- {ready=bool, reagents={ {itemID=,need=,have=} }, missing={ same, only short ones }, times=max crafts}
function Inventory.CanCraft(recipe, times)
  times = times or 1
  local rec = ResolveRecord(recipe)
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

-- Let the UI refresh have/need when bags change.
local bagPending = false
NS.Register("BAG_UPDATE_DELAYED", function()
  if bagPending then return end
  if C_Timer and C_Timer.After then
    bagPending = true
    C_Timer.After(0.3, function()
      bagPending = false
      NS.Fire("INVENTORY_UPDATED")
    end)
  else
    NS.Fire("INVENTORY_UPDATED")
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
-- list { {record=, qty=}, ... } -> { {itemID=, need=, have=, alts=}, ... } in first-seen order.
function Inventory.Totals(list)
  local need, order, alts = {}, {}, {}
  for _, e in ipairs(list or {}) do
    local rec, qty = e.record, e.qty or 1
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
