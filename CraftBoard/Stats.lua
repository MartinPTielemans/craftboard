-- CraftBoard Stats: private crafting history, never sent anywhere.
--   Lifetime crafts per recipe on each character: CraftBoardDB.chars[Me].crafts[recipeID] = n
--   (not .made: Craft.lua keeps recent-craft times there)
--   (every successful cast of one of my recipes, enchants included).
--   This session: crafts per recipe and the skill gained (Skills.SessionGain).
--   Milestones (option milestoneNotice, default on): one gold chat line, with a sound, when a
--   profession learns a new rank or is maxed out, and the first time a character crafts an item
--   of rare quality or better.
-- /cb stats prints the session and the most-crafted recipes.
local ADDON, NS = ...

local Stats = {}
NS.Stats = Stats

local L = NS.L
local format = string.format

local session = {}        -- [recipeID] = crafts this session
local sessionTotal = 0
local ranks = {}          -- [profID] = { rank, max } as last seen (nil until the first read)

local function MyChar()
  if not NS.Me and NS.UpdateIdentity then NS.UpdateIdentity() end
  local c = type(CraftBoardDB) == "table" and type(CraftBoardDB.chars) == "table" and NS.Me and CraftBoardDB.chars[NS.Me]
  return type(c) == "table" and c or nil
end

local function NoticeOn()
  return not (type(CraftBoardDB) == "table" and CraftBoardDB.milestoneNotice == false)
end

local function Flourish(text)
  NS.Print("|cffffd100" .. text .. "|r")
  if PlaySound and type(SOUNDKIT) == "table" then
    local kit = SOUNDKIT.UI_PROFESSIONS_NEW_RECIPE_LEARNED_TOAST or SOUNDKIT.IG_QUEST_LIST_COMPLETE
    if kit then pcall(PlaySound, kit) end
  end
end

local function Quality(itemID)
  if type(itemID) ~= "number" then return nil end
  if C_Item and C_Item.GetItemQualityByID then
    local ok, q = pcall(C_Item.GetItemQualityByID, itemID)
    if ok and type(q) == "number" then return q end
  end
  return nil
end

-- Lifetime crafts of a recipe on my current character (0 when never).
function Stats.Made(recipeID)
  local c = MyChar()
  local made = c and type(c.crafts) == "table" and c.crafts
  return made and made[recipeID] or 0
end

function Stats.SessionMade(recipeID)
  return session[recipeID] or 0
end

-- A successful cast of one of my recipes.
function Stats.Crafted(recipeID, rec)
  local c = MyChar()
  if not (c and type(recipeID) == "number") then return end
  if type(c.crafts) ~= "table" then c.crafts = {} end
  local before = c.crafts[recipeID] or 0
  c.crafts[recipeID] = before + 1
  session[recipeID] = (session[recipeID] or 0) + 1
  sessionTotal = sessionTotal + 1
  -- A first rare (or better) craft of this recipe on this character.
  local out = type(rec) == "table" and rec.o
  if before == 0 and type(out) == "number" then
    local function check()
      local q = Quality(out)
      if q and q >= 3 and NoticeOn() then
        local label = NS.ItemLabel and NS.ItemLabel(out) or format(L["Item %d"], out)
        Flourish(format(L["First time: you crafted %s!"], label))
      end
      return q ~= nil
    end
    -- The item may not be cached yet: ask for it and look again once it has had time to load.
    if not check() and C_Timer and C_Timer.After then
      if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, out) end
      C_Timer.After(2, check)
    end
  end
  NS.Fire("STATS_UPDATED")
end

NS.Register("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
  if issecretvalue and (issecretvalue(unit) or issecretvalue(spellID)) then return end
  if unit ~= "player" or type(spellID) ~= "number" then return end
  local mine = NS.Recipes and NS.Recipes.Mine and NS.Recipes.Mine()
  local rec = type(mine) == "table" and mine[spellID]
  if type(rec) == "table" then Stats.Crafted(spellID, rec) end
end)

-- Ranks: a higher cap is a new rank learned; the top cap reached is maxed out. The first read
-- after login only sets the baseline.
function Stats.CheckRanks()
  local list = NS.Skills and NS.Skills.Ranks and NS.Skills.Ranks() or {}
  for _, r in ipairs(list) do
    local was = ranks[r.profID]
    if type(r.rank) == "number" and type(r.max) == "number" then
      if was and NoticeOn() then
        if r.max > was[2] then
          Flourish(format(L["New rank: %s can now go up to %d."], r.name, r.max))
        elseif r.rank >= r.max and was[1] < was[2] and r.max >= 300 then
          Flourish(format(L["%s maxed out at %d!"], r.name, r.max))
        end
      end
      ranks[r.profID] = { r.rank, r.max }
    end
  end
end

if NS.RegisterCallback then
  NS.RegisterCallback(Stats, "SKILLS_UPDATED", function() Stats.CheckRanks() end)
end
-- The baseline, once the profession book has been read after login.
NS.Register("PLAYER_LOGIN", function()
  if C_Timer and C_Timer.After then C_Timer.After(8, Stats.CheckRanks) end
end)

-- /cb stats
function Stats.Print()
  local parts = {}
  for _, r in ipairs(NS.Skills and NS.Skills.Ranks and NS.Skills.Ranks() or {}) do
    local gain = NS.Skills.SessionGain and NS.Skills.SessionGain(r.profID) or 0
    if gain and gain > 0 then parts[#parts + 1] = format(L["%s +%d"], r.name, gain) end
  end
  NS.Print(format(L["This session: %d crafts%s."], sessionTotal,
    #parts > 0 and (", " .. table.concat(parts, ", ")) or ""))
  local c = MyChar()
  local list = {}
  for id, n in pairs(c and type(c.crafts) == "table" and c.crafts or {}) do
    if type(id) == "number" and type(n) == "number" then list[#list + 1] = { id = id, n = n } end
  end
  if #list == 0 then return end
  table.sort(list, function(a, b)
    if a.n ~= b.n then return a.n > b.n end
    return a.id < b.id
  end)
  local total = 0
  for _, e in ipairs(list) do total = total + e.n end
  NS.Print(format(L["Crafted on this character: %d. Most made:"], total))
  for i = 1, math.min(5, #list) do
    local rec = NS.Recipes.Mine()[list[i].id]
    local name = type(rec) == "table" and rec.n or (NS.Recipes.NameOf and NS.Recipes.NameOf(list[i].id)) or tostring(list[i].id)
    NS.Print(format("  %dx %s", list[i].n, name))
  end
end

-- Demand ------------------------------------------------------------------------------
-- How often items are asked for around me: new board requests and crafting asks in public chat.
-- CraftBoardDB.demand[itemID] = { [day] = asks } for the last DEMAND_DAYS days. Only counts are
-- saved, never who asked; one ask per player, item and day counts (remembered for the session).
local DEMAND_DAYS = 14
local MAX_DEMAND = 500
local counted = {}        -- [player .. item .. day] = true (this session)

local function Today(t) return math.floor((t or time()) / 86400) end

local function DemandDB()
  if type(CraftBoardDB) ~= "table" then return nil end
  if type(CraftBoardDB.demand) ~= "table" then CraftBoardDB.demand = {} end
  return CraftBoardDB.demand
end

-- Drops days older than DEMAND_DAYS, and items nobody asked for since.
function Stats.PruneDemand()
  local d = DemandDB()
  if not d then return end
  local cutoff, n = Today() - DEMAND_DAYS, 0
  for id, days in pairs(d) do
    if type(days) == "table" then
      for day in pairs(days) do
        if type(day) ~= "number" or day <= cutoff then days[day] = nil end
      end
    end
    if type(days) ~= "table" or next(days) == nil then d[id] = nil else n = n + 1 end
  end
  return n
end

function Stats.NoteDemand(itemID, who)
  if type(itemID) ~= "number" or type(who) ~= "string" then return end
  if NS.IsMe and NS.IsMe(who) then return end
  local d = DemandDB()
  if not d then return end
  local day = Today()
  local key = who .. "\t" .. itemID .. "\t" .. day
  if counted[key] then return end
  counted[key] = true
  if not d[itemID] then
    local n = 0
    for _ in pairs(d) do n = n + 1 end
    if n >= MAX_DEMAND and (Stats.PruneDemand() or 0) >= MAX_DEMAND then return end
    d[itemID] = {}
  end
  d[itemID][day] = (d[itemID][day] or 0) + 1
end

-- Asks for an item within the last `days` days (7 by default).
function Stats.Demand(itemID, days)
  local d = DemandDB()
  local e = d and d[itemID]
  if type(e) ~= "table" then return 0 end
  local from, n = Today() - (days or 7), 0
  for day, c in pairs(e) do
    if type(day) == "number" and day > from and type(c) == "number" then n = n + c end
  end
  return n
end

-- The most-asked items: { {itemID=, n=}, ... }, at least `atLeast` asks, most first.
function Stats.TopDemand(limit, days, atLeast)
  local d = DemandDB()
  local out = {}
  for id in pairs(d or {}) do
    local n = Stats.Demand(id, days)
    if n >= (atLeast or 1) then out[#out + 1] = { itemID = id, n = n } end
  end
  table.sort(out, function(a, b)
    if a.n ~= b.n then return a.n > b.n end
    return a.itemID < b.itemID
  end)
  for i = #out, (limit or #out) + 1, -1 do out[i] = nil end
  return out
end

-- /cb demand: the most-asked items this week, and who on the board makes them.
function Stats.PrintDemand()
  local top = Stats.TopDemand(10, 7)
  if #top == 0 then
    NS.Print(L["Nothing asked for yet this week. CraftBoard counts board requests and crafting asks it sees in chat."])
    return
  end
  NS.Print(L["Most asked for this week:"])
  -- Distinct crafters per item (one who knows two recipes for it counts once).
  local byItem, seenBy = {}, {}
  for _, e in ipairs(NS.Recipes and NS.Recipes.Search and NS.Recipes.Search("") or {}) do
    local out = e.outputItemID
    if out then
      seenBy[out] = seenBy[out] or {}
      for _, c in ipairs(e.crafters or {}) do
        if type(c.name) == "string" and not seenBy[out][c.name] then
          seenBy[out][c.name] = true
          byItem[out] = (byItem[out] or 0) + 1
        end
      end
    end
  end
  for _, e in ipairs(top) do
    local label = NS.ItemLabel and NS.ItemLabel(e.itemID) or format(L["Item %d"], e.itemID)
    local makers = byItem[e.itemID]
    NS.Print(format("  %s: %s", label, makers and makers > 0
      and format(L["%d asks, %d crafters known"], e.n, makers)
      or format(L["%d asks, no crafter known"], e.n)))
  end
end

NS.Register("PLAYER_LOGIN", function() Stats.PruneDemand() end)
