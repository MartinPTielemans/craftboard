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

-- entry: { recipeID=, item= (output, nil for enchants), qty= (items), who="Name-Realm", src= (the
-- request's list id, so the same request isn't queued twice), mats=true (they bring the
-- reagents) }. Returns the stored entry and whether it is new; nil, "full" when the queue has
-- MAX entries; nil when there is no character yet.
function Queue.Add(e)
  local q = List()
  if not (q and type(e) == "table" and type(e.recipeID) == "number") then return nil end
  for _, x in ipairs(q) do
    if e.src and x.src == e.src then return x, false end
  end
  if #q >= MAX then return nil, "full" end
  counter = counter + 1
  local entry = {
    id = time() .. ":" .. counter, recipeID = e.recipeID, item = e.item,
    qty = Queue.ClampQty(e.recipeID, e.qty),
    who = e.who, src = e.src, t = time(),
    mats = e.mats and true or nil,     -- the player it's for brings the reagents
  }
  q[#q + 1] = entry
  NS.Fire("QUEUE_UPDATED")
  return entry, true
end

-- An entry's item count, whole and within 1000 crafts' worth (yield-aware: 20 crafts of a
-- 200-arrow recipe are 4000 items).
function Queue.ClampQty(recipeID, qty)
  local rec = NS.Recipes and NS.Recipes.Mine and NS.Recipes.Mine()[recipeID]
  local y = type(rec) == "table" and math.max(1, rec.y or 1) or 1
  return math.max(1, math.min(1000 * y, math.floor(tonumber(qty) or 1)))
end

-- Adds items to an existing entry (planning more of the same craft).
function Queue.Grow(x, qty)
  if type(x) ~= "table" then return end
  x.qty = Queue.ClampQty(x.recipeID, (x.qty or 0) + (tonumber(qty) or 0))
  NS.Fire("QUEUE_UPDATED")
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
-- Reagents for what the queue still has to make: crafts already made (waiting for their trade)
-- need nothing more. buyable: leave out entries whose player brings the reagents (Buy missing).
function Queue.Totals(buyable)
  local mine = NS.Recipes and NS.Recipes.Mine and NS.Recipes.Mine() or {}
  local list = {}
  for _, x in ipairs(Queue.Entries()) do
    local rec = mine[x.recipeID]
    local left = rec and Queue.CraftsLeft(x, rec) or 0
    if left > 0 and not (buyable and x.mats) then
      list[#list + 1] = { record = rec, qty = left * math.max(1, rec.y or 1) }
    end
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
      -- What was handed over was made already: those crafts no longer count as made-and-waiting.
      if x.made then
        local rec = NS.Recipes and NS.Recipes.Mine and NS.Recipes.Mine()[x.recipeID]
        local crafts = NS.Inventory and NS.Inventory.CraftsFor and NS.Inventory.CraftsFor(rec, take) or take
        x.made = math.max(0, x.made - crafts)
      end
      if x.qty <= 0 then table.remove(q, i) else i = i + 1 end
    else
      i = i + 1
    end
  end
  if changed then NS.Fire("QUEUE_UPDATED") end
end

-- Crafts an entry still needs: its item count over the recipe's yield, minus crafts already made
-- for it (made counts crafts; an entry for someone stays until the trade hands it over).
function Queue.CraftsLeft(x, rec)
  local total = NS.Inventory and NS.Inventory.CraftsFor and NS.Inventory.CraftsFor(rec, x.qty) or x.qty
  return math.max(0, total - (x.made or 0))
end

-- One craft of recipeID was made: it goes to the oldest entry still needing it. Entries for
-- nobody (planned crafts from the Plan tab) are done when fully made; entries for a player
-- wait for the trade (Queue.Delivered).
-- plannedOnly: only entries for nobody (enchant casts, which trades complete for players).
function Queue.Crafted(recipeID, rec, plannedOnly)
  local q = List()
  if not q then return end
  for i, x in ipairs(q) do
    if x.recipeID == recipeID and Queue.CraftsLeft(x, rec) > 0 and not (plannedOnly and x.who) then
      x.made = (x.made or 0) + 1
      if not x.who and Queue.CraftsLeft(x, rec) == 0 then table.remove(q, i) end
      NS.Fire("QUEUE_UPDATED")
      return
    end
  end
end
