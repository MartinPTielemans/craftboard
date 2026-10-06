-- CraftBoard Stats: private crafting history, never sent anywhere.
--   Lifetime crafts per recipe on each character: CraftBoardDB.chars[Me].made[recipeID] = n
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
  local made = c and type(c.made) == "table" and c.made
  return made and made[recipeID] or 0
end

function Stats.SessionMade(recipeID)
  return session[recipeID] or 0
end

-- A successful cast of one of my recipes.
function Stats.Crafted(recipeID, rec)
  local c = MyChar()
  if not (c and type(recipeID) == "number") then return end
  if type(c.made) ~= "table" then c.made = {} end
  local before = c.made[recipeID] or 0
  c.made[recipeID] = before + 1
  session[recipeID] = (session[recipeID] or 0) + 1
  sessionTotal = sessionTotal + 1
  -- A first rare (or better) craft of this recipe on this character.
  local out = type(rec) == "table" and rec.o
  local q = Quality(out)
  if before == 0 and q and q >= 3 and NoticeOn() then
    local label = NS.ItemLabel and NS.ItemLabel(out) or format(L["Item %d"], out)
    Flourish(format(L["First time: you crafted %s!"], label))
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
  for id, n in pairs(c and type(c.made) == "table" and c.made or {}) do
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
