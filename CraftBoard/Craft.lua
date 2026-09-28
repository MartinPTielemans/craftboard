-- CraftBoard Craft: crafting from CraftBoard's own buttons (the Plan tab's Craft, the queue's Craft
-- next). It only works the way the profession window's Create button does: the recipe's
-- profession window is open on my own character, the recipe is learned there, I'm out of combat,
-- and every craft is a click (C_TradeSkillUI.CraftRecipe from the button's OnClick). Enchants
-- need a target item, so they are cast from the trade window instead (Trade.lua).
-- A successful cast counts toward the queue (Queue.Crafted).
local ADDON, NS = ...

local Craft = {}
NS.Craft = Craft

local L = NS.L
local format = string.format
local TSUI = C_TradeSkillUI

local function MyRecord(recipeID)
  local mine = NS.Recipes and NS.Recipes.Mine and NS.Recipes.Mine() or {}
  return mine[recipeID]
end

-- Skill line of the profession window that is open on my own character, or nil.
local function OpenProfession()
  if not TSUI then return nil end
  if TSUI.IsTradeSkillLinked and TSUI.IsTradeSkillLinked() then return nil end
  if TSUI.IsTradeSkillGuild and TSUI.IsTradeSkillGuild() then return nil end
  if TSUI.IsNPCCrafting and TSUI.IsNPCCrafting() then return nil end
  if TSUI.IsTradeSkillReady and not TSUI.IsTradeSkillReady() then return nil end
  if TSUI.GetBaseProfessionInfo then
    local ok, info = pcall(TSUI.GetBaseProfessionInfo)
    if ok and type(info) == "table" and info.professionID and info.professionID ~= 0 then return info.professionID end
  end
  return nil
end

-- ok, reason (localized, for the button's tooltip), times (crafts my bags allow).
function Craft.CanCraft(recipeID)
  local rec = MyRecord(recipeID)
  if not rec then return false, L["Your current character doesn't know this recipe."], 0 end
  if rec.e then return false, L["Enchants are cast on an item: use the trade window."], 0 end
  if not (TSUI and TSUI.CraftRecipe) then return false, L["Crafting isn't available on this client."], 0 end
  if InCombatLockdown and InCombatLockdown() then return false, L["Can't craft in combat."], 0 end
  local open = OpenProfession()
  if not open or open ~= rec.p then
    local name = rec.p and NS.ProfessionName and NS.ProfessionName(rec.p)
    return false, name and format(L["Open your %s window to craft."], name) or L["Open the profession window to craft."], 0
  end
  local cc = NS.Inventory and NS.Inventory.CanCraft and NS.Inventory.CanCraft(rec) or { ready = false, times = 0 }
  if not cc.ready then return false, L["Missing reagents."], 0 end
  return true, nil, cc.times or 1
end

-- Crafts recipeID `count` times (capped by what my bags allow). A click handler only.
function Craft.Do(recipeID, count)
  local ok, why, times = Craft.CanCraft(recipeID)
  if not ok then
    if why then NS.Print(why) end
    return false
  end
  count = math.max(1, math.min(count or 1, times or 1))
  local done = pcall(TSUI.CraftRecipe, recipeID, count)
  if not done then NS.Print(L["The client refused to craft that."]) end
  return done
end

-- First queued craft I can make right now: entry, crafts (how many of it), or nil.
function Craft.NextQueued()
  for _, x in ipairs(NS.Queue and NS.Queue.Entries() or {}) do
    local rec = MyRecord(x.recipeID)
    local left = NS.Queue.CraftsLeft(x, rec)
    if left > 0 then
      local ok, _, times = Craft.CanCraft(x.recipeID)
      if ok then return x, math.min(left, times) end
    end
  end
  return nil
end

-- Queue's Craft next: the first queued craft that can be made now, as many as it still needs.
function Craft.Next()
  local x, n = Craft.NextQueued()
  if not x then
    NS.Print(L["Nothing in your queue can be crafted right now."])
    return false
  end
  return Craft.Do(x.recipeID, n)
end

-- Every successful cast of one of my recipes counts toward the queue.
NS.Register("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
  if issecretvalue and (issecretvalue(unit) or issecretvalue(spellID)) then return end
  if unit ~= "player" or type(spellID) ~= "number" then return end
  local rec = MyRecord(spellID)
  if rec and not rec.e and NS.Queue and NS.Queue.Crafted then NS.Queue.Crafted(spellID, rec) end
end)
