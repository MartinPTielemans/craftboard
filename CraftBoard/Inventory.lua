-- CraftBoard Inventory: reagent counts, craftability, shopping lists, cached item names.
local ADDON, NS = ...

local Inventory = {}
NS.Inventory = Inventory

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
      local have = Inventory.Count(itemID)
      local row = { itemID = itemID, need = qty * times, have = have }
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
  local need, order, unknown = {}, {}, {}
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
        end
      end
    elseif recipeID then
      unknown[#unknown + 1] = recipeID
    end
  end
  local out = {}
  for _, itemID in ipairs(order) do
    local have = Inventory.Count(itemID)
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
        name = rec.n or (NS.Recipes and NS.Recipes.NameOf and NS.Recipes.NameOf(recipeID)) or ("Recipe " .. recipeID),
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
