-- CraftBoard Queue: crafts I said I'd make, per character (CraftBoardDB.chars[Me].queue), with
-- the reagents of the whole queue summed against my bags. Entries come from the Requests tab
-- ("Queue" on a board request or a chat ask) and go away with "Done", or by themselves when a
-- trade hands the crafted item (or the enchant) to the player it was for. Local only.
local ADDON, NS = ...

local Queue = {}
NS.Queue = Queue

local MAX = 30

local function List()
  local db = type(CraftBoardDB) == "table" and CraftBoardDB
  local c = db and NS.Me and type(db.chars) == "table" and db.chars[NS.Me]
  if type(c) ~= "table" then return nil end
  if type(c.queue) ~= "table" then c.queue = {} end
  return c.queue
end

local counter = 0

-- entry: { recipeID=, item= (output, nil for enchants), qty=, who="Name-Realm", src= (the
-- request's list id, so the same request isn't queued twice) }. Returns the stored entry, or
-- nil (no character yet, full, or already queued: then the existing one).
function Queue.Add(e)
  local q = List()
  if not (q and type(e) == "table" and type(e.recipeID) == "number") then return nil end
  for _, x in ipairs(q) do
    if e.src and x.src == e.src then return x end
  end
  if #q >= MAX then return nil end
  counter = counter + 1
  local entry = {
    id = time() .. ":" .. counter, recipeID = e.recipeID, item = e.item,
    qty = math.max(1, math.min(1000, math.floor(tonumber(e.qty) or 1))),
    who = e.who, src = e.src, t = time(),
  }
  q[#q + 1] = entry
  NS.Fire("QUEUE_UPDATED")
  return entry
end

function Queue.Remove(id)
  local q = List()
  if not q then return false end
  for i, x in ipairs(q) do
    if x.id == id then
      table.remove(q, i)
      NS.Fire("QUEUE_UPDATED")
      return true
    end
  end
  return false
end

-- Oldest first. Entries whose recipe the character no longer knows are dropped.
function Queue.Entries()
  local q = List()
  if not q then return {} end
  local mine = NS.Recipes and NS.Recipes.Mine and NS.Recipes.Mine() or {}
  for i = #q, 1, -1 do
    if not mine[q[i].recipeID] then table.remove(q, i) end
  end
  return q
end

function Queue.Has(src)
  for _, x in ipairs(Queue.Entries()) do
    if x.src == src then return true end
  end
  return false
end

-- Reagents for the whole queue: { {itemID=, need=, have=}, ... } (Inventory.Totals).
function Queue.Totals()
  local mine = NS.Recipes and NS.Recipes.Mine and NS.Recipes.Mine() or {}
  local list = {}
  for _, x in ipairs(Queue.Entries()) do
    list[#list + 1] = { record = mine[x.recipeID], qty = x.qty }
  end
  return NS.Inventory and NS.Inventory.Totals and NS.Inventory.Totals(list) or {}
end

-- A trade handed `count` of item (or the enchant recipeID) to who: take it off their entry.
function Queue.Delivered(who, item, recipeID, count)
  local q = List()
  if not q then return end
  count = count or 1
  local changed = false
  local i = 1
  while i <= #q and count > 0 do
    local x = q[i]
    if x.who and NS.SamePlayer(x.who, who)
      and ((item and x.item == item) or (recipeID and x.recipeID == recipeID)) then
      -- A delivery bigger than this row carries over to their next row for the same craft.
      local take = math.min(count, x.qty)
      x.qty, count, changed = x.qty - take, count - take, true
      if x.qty <= 0 then table.remove(q, i) else i = i + 1 end
    else
      i = i + 1
    end
  end
  if changed then NS.Fire("QUEUE_UPDATED") end
end
