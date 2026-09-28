-- CraftBoard Inventory: reagent counts, craftability, cached item names, and what my other
-- characters hold.
local ADDON, NS = ...

local Inventory = {}
NS.Inventory = Inventory

local L = NS.L

-- Bags + bank + reagent bank.
-- bagsOnly: what a craft can use right now (the bags and reagent bag), not the bank.
function Inventory.Count(itemID, bagsOnly)
  if type(itemID) ~= "number" then return 0 end
  if C_Item and C_Item.GetItemCount then
    return C_Item.GetItemCount(itemID, not bagsOnly, false, not bagsOnly) or 0
  elseif GetItemCount then
    return GetItemCount(itemID, not bagsOnly) or 0
  end
  return 0
end

-- A reagent slot may accept several items (quality tiers): have = sum over all of them.
-- alts is the optional list stored on a reagent entry ({ itemID, qty, alts = {...} }). The name is
-- saved recipe data: here "alts" means the slot's other quality tiers, never alt characters.
function Inventory.SlotCount(itemID, alts, bagsOnly)
  local n = Inventory.Count(itemID, bagsOnly)
  if type(alts) == "table" then
    for _, id in ipairs(alts) do
      if id ~= itemID then n = n + Inventory.Count(id, bagsOnly) end
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
-- bagsOnly: count the bags only (can it be crafted right now), not the bank (planning).
function Inventory.CanCraft(recipe, count, bagsOnly)
  local rec = ResolveRecord(recipe)
  local times = Inventory.CraftsFor(rec, count)
  local result = { ready = false, reagents = {}, missing = {}, times = 0 }
  if not rec or type(rec.r) ~= "table" then return result end
  local maxTimes
  for _, reg in ipairs(rec.r) do
    local itemID, qty = reg[1], reg[2]
    if itemID and qty and qty > 0 then
      local have = Inventory.SlotCount(itemID, reg.alts, bagsOnly)
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

-- Reagent-like items ---------------------------------------------------------------
-- Only these are remembered per character and get alt counts on tooltips: items my characters'
-- recipes use, items in my queue, and anything the client files as Trade Goods, Reagent or Recipe.

local function Chars()
  return type(CraftBoardDB) == "table" and type(CraftBoardDB.chars) == "table" and CraftBoardDB.chars or {}
end

local function ClassNum(key, default)
  local v = Enum and Enum.ItemClass and Enum.ItemClass[key]
  return type(v) == "number" and v or default
end
local REAGENT_CLASSES = { [ClassNum("Reagent", 5)] = true, [ClassNum("Tradegoods", 7)] = true, [ClassNum("Recipe", 9)] = true }

-- Item class of an item (the client's item table answers without a cache), or nil.
local classOf = {}
function Inventory.ItemClass(itemID)
  if type(itemID) ~= "number" then return nil end
  if classOf[itemID] then return classOf[itemID] end
  local class
  local instant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if instant then
    local ok, _, _, _, _, _, c = pcall(instant, itemID)
    if ok and type(c) == "number" then class = c end
  end
  if class == nil then
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if getInfo then
      local ok, _, _, _, _, _, _, _, _, _, _, _, c = pcall(getInfo, itemID)
      if ok and type(c) == "number" then class = c end
    end
  end
  classOf[itemID] = class
  return class
end

-- [itemID] = true for every item in a reagent slot of any of my characters' recipes (quality
-- tiers included). Cached until the recipes change.
local reagentSet = nil
function Inventory.ReagentSet()
  if reagentSet then return reagentSet end
  local set = {}
  for _, c in pairs(Chars()) do
    for _, rec in pairs(type(c) == "table" and type(c.recipes) == "table" and c.recipes or {}) do
      for _, reg in ipairs(type(rec) == "table" and type(rec.r) == "table" and rec.r or {}) do
        if type(reg) == "table" then
          if type(reg[1]) == "number" then set[reg[1]] = true end
          for _, id in ipairs(type(reg.alts) == "table" and reg.alts or {}) do
            if type(id) == "number" then set[id] = true end
          end
        end
      end
    end
  end
  reagentSet = set
  return set
end

-- [itemID] = true for the items my queue makes (its reagents are in ReagentSet already).
local queueSet = nil
local function QueueSet()
  if queueSet then return queueSet end
  local set = {}
  for _, x in ipairs(NS.Queue and NS.Queue.Entries and NS.Queue.Entries() or {}) do
    if type(x.item) == "number" then set[x.item] = true end
  end
  queueSet = set
  return set
end

function Inventory.IsReagentLike(itemID)
  if type(itemID) ~= "number" then return false end
  if Inventory.ReagentSet()[itemID] or QueueSet()[itemID] then return true end
  local class = Inventory.ItemClass(itemID)
  return class ~= nil and REAGENT_CLASSES[class] == true
end

-- My characters ------------------------------------------------------------------
-- A character of mine things can be mailed or handed to from here: same realm and faction (a
-- faction older saves didn't record counts as the same).
function Inventory.Reachable(key, c)
  if type(key) ~= "string" then return false end
  local realm = key:match("%-([^%-]+)$")
  if NS.Realm and realm ~= NS.Realm then return false end
  local faction = type(c) == "table" and c.faction or nil
  return faction == nil or faction == NS.Faction
end

-- Per-character item counts, so tooltips and reagent slots can say what my alts hold:
-- CraftBoardDB.chars[key].bags / .bank = { [itemID] = count } (reagent-like items only), with
-- .bagsAt / .bankAt the time of the scan. The bank is only readable while it is open, so a bags
-- rescan keeps the saved bank part; a character's count is bags + bank. Older saves kept one
-- .items table (bags + bank, next to .bank): it is read as the total until that character logs
-- in and its bags are scanned, then dropped.
local function Held(c, itemID)
  if type(c) ~= "table" then return 0 end
  if type(c.bags) == "table" then
    local bank = type(c.bank) == "table" and tonumber(c.bank[itemID]) or 0
    return (tonumber(c.bags[itemID]) or 0) + bank
  end
  return type(c.items) == "table" and tonumber(c.items[itemID]) or 0
end

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

-- My bags (backpack, equipped bags, the reagent bag if the client has one): list, set.
local function BagIDs()
  local ids, set = {}, {}
  local function add(bag)
    if type(bag) == "number" and not set[bag] then
      set[bag] = true
      ids[#ids + 1] = bag
    end
  end
  for bag = 0, tonumber(NUM_BAG_SLOTS) or 4 do add(bag) end
  local BI = Enum and Enum.BagIndex
  if BI then add(BI.ReagentBag) end
  return ids, set
end

-- The bank container, the bank bags (Enum.BagIndex.BankBag_1..7 when the client names them,
-- else the numbers after my equipped bags), the reagent bank, and a mainline client's character
-- bank tabs if it has them. Never a bag already in `skip` (my bags).
local function BankIDs(skip)
  local BI = Enum and Enum.BagIndex
  local ids, set = {}, {}
  local function add(bag)
    if type(bag) == "number" and not set[bag] and not (skip and skip[bag]) then
      set[bag] = true
      ids[#ids + 1] = bag
    end
  end
  add((BI and type(BI.Bank) == "number" and BI.Bank) or tonumber(BANK_CONTAINER) or -1)
  if BI and type(BI.BankBag_1) == "number" then
    for i = 1, 7 do add(BI["BankBag_" .. i]) end
  else
    local first = (tonumber(NUM_TOTAL_EQUIPPED_BAG_SLOTS) or tonumber(NUM_BAG_SLOTS) or 4) + 1
    for bag = first, first + (tonumber(NUM_BANKBAGSLOTS) or 7) - 1 do add(bag) end
  end
  if BI then add(BI.Reagentbank) end
  if BI and type(BI.CharacterBankTab_1) == "number" then
    for i = 1, 6 do add(BI["CharacterBankTab_" .. i]) end
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

-- The reagent-like part of a scan (what gets saved).
local function Keep(all)
  local out = {}
  for id, n in pairs(all) do
    if Inventory.IsReagentLike(id) then out[id] = n end
  end
  return out
end

-- Full counts of the last scans this session (not saved): the change test covers every item, so
-- have/need on any recipe card refreshes, while only reagent-like items are saved.
local lastBags, lastBank = nil, nil

-- Rescan bags (and the bank while it's open) into chars[Me].bags / .bank. True when any count
-- changed since the last scan.
local function RecordItems()
  local c = MyRecord()
  if not c then return false end
  local changed = false
  local now = time and time() or nil
  local bagList, bagSet = BagIDs()
  if bankOpen then
    local all = {}
    for _, bag in ipairs(BankIDs(bagSet)) do AddContainer(all, bag) end
    if not SameCounts(all, lastBank) then changed = true end
    lastBank = all
    c.bank, c.bankAt = Keep(all), now
  end
  local all = {}
  for _, bag in ipairs(bagList) do AddContainer(all, bag) end
  if not SameCounts(all, lastBags) then changed = true end
  lastBags = all
  c.bags, c.bagsAt = Keep(all), now
  -- Older saves: drop the combined table, and keep only the reagent-like part of the old bank.
  if c.items ~= nil then
    c.items = nil
    if type(c.bank) == "table" and not bankOpen then c.bank = Keep(c.bank) end
  end
  return changed
end

-- Bank count of an item from the client's cache (it knows the bank after login without the bank
-- being open): all copies minus the ones in my bags.
local function CachedBankCount(itemID)
  local ok, all, bags
  if C_Item and C_Item.GetItemCount then
    ok, all = pcall(C_Item.GetItemCount, itemID, true, false, true)
    if ok then ok, bags = pcall(C_Item.GetItemCount, itemID, false, false, false) end
  elseif GetItemCount then
    ok, all = pcall(GetItemCount, itemID, true)
    if ok then ok, bags = pcall(GetItemCount, itemID) end
  end
  if not ok then return 0 end
  return math.max(0, (tonumber(all) or 0) - (tonumber(bags) or 0))
end

-- At login: the saved bank counts of my recipes' reagents, from the client's cache. Only counts
-- above zero are taken (zero may just mean "not loaded"). True when a count changed.
local function RefreshBankFromCache()
  local c = MyRecord()
  if not c then return false end
  local bank = type(c.bank) == "table" and c.bank or {}
  local changed = false
  for id in pairs(Inventory.ReagentSet()) do
    local n = CachedBankCount(id)
    if n > 0 and bank[id] ~= n then
      bank[id] = n
      changed = true
    end
  end
  c.bank = bank
  return changed
end

-- My OTHER characters (reachable ones) holding itemID: total,
-- { {name="Name-Realm", n=, class="WARRIOR"?}, ... } (most first).
-- tiers: the other items the same reagent slot accepts (quality tiers); their counts add up, as
-- in SlotCount.
function Inventory.AltCounts(itemID, tiers)
  local list, total = {}, 0
  if type(itemID) ~= "number" then return 0, list end
  for key, c in pairs(Chars()) do
    if key ~= NS.Me and type(c) == "table" and Inventory.Reachable(key, c) then
      local n = Held(c, itemID)
      for _, id in ipairs(type(tiers) == "table" and tiers or {}) do
        if id ~= itemID then n = n + Held(c, id) end
      end
      if n > 0 then
        list[#list + 1] = { name = key, n = n, class = type(c.class) == "string" and c.class or nil }
        total = total + n
      end
    end
  end
  table.sort(list, function(a, b)
    if a.n ~= b.n then return a.n > b.n end
    return a.name < b.name
  end)
  return total, list
end

-- "+12 on alts" for a reagent slot, or nil.
function Inventory.AltText(itemID, tiers)
  local total = Inventory.AltCounts(itemID, tiers)
  if total <= 0 then return nil end
  return string.format(L["+%d on alts"], total)
end

-- Let the UI refresh have/need when bags change (and record the new counts first). Nothing fires
-- when a bag event left every count as it was (durability, cooldowns, locks).
local bagPending = false
local function BagsChanged()
  bagPending = false
  local ok, changed = pcall(RecordItems)
  if not ok or changed then NS.Fire("INVENTORY_UPDATED") end
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

local function LoginScan()
  local ok, changed = pcall(RecordItems)
  local ok2, bankChanged = pcall(RefreshBankFromCache)
  if (ok and changed) or (ok2 and bankChanged) then NS.Fire("INVENTORY_UPDATED") end
end

NS.Register("PLAYER_LOGIN", function()
  if C_Timer and C_Timer.After then
    C_Timer.After(3, LoginScan)
  else
    LoginScan()
  end
end)

if NS.RegisterCallback then
  NS.RegisterCallback(Inventory, "RECIPES_UPDATED", function() reagentSet = nil end)
  NS.RegisterCallback(Inventory, "QUEUE_UPDATED", function() queueSet = nil end)
end

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
  return link or Inventory.ItemName(itemID) or string.format(L["Item %d"], itemID)
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
  -- Alts only on this realm and faction (what they craft can reach the other player).
  for key, c in pairs(CraftBoardDB.chars) do
    if key ~= NS.Me and Inventory.Reachable(key, c) then
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
-- (alts: the reagent slot's other quality tiers, as in SlotCount.)
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
