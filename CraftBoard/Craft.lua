-- CraftBoard Craft: crafting from CraftBoard's own buttons (the Plan tab's Craft, the queue's Craft
-- next). It only works the way the profession window's Create button does: the recipe's
-- profession window is open on my own character, the recipe is learned there, I'm out of combat,
-- the craft isn't on cooldown, any required tool (anvil, forge...) is at hand, and every craft is a
-- click (C_TradeSkillUI.CraftRecipe from the button's OnClick). How many I can make comes from the
-- open window itself (reagents in my bags, as Blizzard counts them), not from bags + bank.
-- Enchants need a target item: they are cast from the profession window or the trade window
-- (Trade.lua). A successful cast counts toward the queue (Queue.Crafted) and is remembered for a
-- day (Craft.MadeRecently). While a batch is being crafted, Craft.IsCrafting() is true and the
-- buttons say so; CRAFT_UPDATED fires as it starts, advances and ends.
local ADDON, NS = ...

local Craft = {}
NS.Craft = Craft

local L = NS.L
local format, max, min = string.format, math.max, math.min
local TSUI = C_TradeSkillUI

local batch                 -- { recipeID=, left=, t= } while one of my batches is being crafted

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
Craft.OpenProfession = OpenProfession

-- Seconds left on a recipe's cooldown as the open window reports it (0 when ready or unknown).
local function CooldownLeft(recipeID)
  if not (TSUI and TSUI.GetRecipeCooldown) then return 0 end
  local ok, cd = pcall(TSUI.GetRecipeCooldown, recipeID)
  return ok and type(cd) == "number" and cd > 0 and cd or 0
end

-- The first required tool / place (anvil, forge, totem) that isn't met, or nil.
local function MissingTool(recipeID)
  if not (TSUI and TSUI.GetRecipeRequirements) then return nil end
  local ok, reqs = pcall(TSUI.GetRecipeRequirements, recipeID)
  if not ok or type(reqs) ~= "table" then return nil end
  for _, r in ipairs(reqs) do
    if type(r) == "table" and r.met == false and type(r.name) == "string" then return r.name end
  end
  return nil
end

Craft.MissingTool = MissingTool

-- How many times the open window says it can be made (reagents in bags), or nil if it won't say.
local function Available(recipeID)
  if not (TSUI and TSUI.GetRecipeInfo) then return nil end
  local ok, info = pcall(TSUI.GetRecipeInfo, recipeID)
  local n = ok and type(info) == "table" and info.numAvailable
  return type(n) == "number" and n or nil
end

-- One of my trade-skill casts is running right now, or a batch I started is still going.
function Craft.IsCrafting()
  if UnitCastingInfo then
    local ok, name, _, _, _, _, isTradeSkill = pcall(UnitCastingInfo, "player")
    if ok and name and isTradeSkill then return true end
  end
  return batch ~= nil and batch.left > 0 and time() - batch.t < 6
end

-- ok, reason (localized, for the button's tooltip), times (crafts my bags allow now), openProf
-- (the profession to open when the only problem is that its window is closed).
function Craft.CanCraft(recipeID)
  local rec = MyRecord(recipeID)
  if not rec then return false, L["Your current character doesn't know this recipe."], 0 end
  if rec.e then return false, L["Enchants ask for an item: use Create in the Enchanting window, or the trade window."], 0 end
  if not (TSUI and TSUI.CraftRecipe) then return false, L["Crafting isn't available on this client."], 0 end
  if InCombatLockdown and InCombatLockdown() then return false, L["Can't craft in combat."], 0 end
  if Craft.IsCrafting() then return false, L["Crafting..."], 0 end
  local open = OpenProfession()
  if not open or open ~= rec.p then
    local name = rec.p and NS.ProfessionName and NS.ProfessionName(rec.p)
    return false, name and format(L["Open your %s window to craft."], name) or L["Open the profession window to craft."], 0, rec.p
  end
  local cd = CooldownLeft(recipeID)
  if cd > 0 then
    local text = NS.Cooldowns and NS.Cooldowns.Text and NS.Cooldowns.Text(cd) or ""
    return false, format(L["On cooldown: %s left."], text), 0
  end
  local tool = MissingTool(recipeID)
  if tool then return false, format(L["Requires %s."], tool), 0 end
  local times = Available(recipeID)
  if times == nil then
    -- No count from the window: my bags (and reagent bank), never the rest of the bank.
    local cc = NS.Inventory and NS.Inventory.CanCraft and NS.Inventory.CanCraft(rec, nil, true) or { ready = false, times = 0 }
    times = cc.ready and (cc.times or 1) or 0
  end
  if times < 1 then return false, L["Missing reagents in your bags."], 0 end
  -- A cooldown craft is one cast at a time.
  if NS.Cooldowns and NS.Cooldowns.Is and NS.Cooldowns.Is(recipeID, rec) then times = 1 end
  return true, nil, times
end

-- Crafts recipeID `count` times (capped by what my bags allow). A click handler only.
function Craft.Do(recipeID, count)
  local ok, why, times = Craft.CanCraft(recipeID)
  if not ok then
    if why then NS.Print(why) end
    return false
  end
  count = max(1, min(count or 1, times or 1))
  local done = pcall(TSUI.CraftRecipe, recipeID, count)
  if not done then
    NS.Print(L["The client refused to craft that."])
    return false
  end
  batch = { recipeID = recipeID, left = count, t = time() }
  NS.Fire("CRAFT_UPDATED")
  return true
end

-- Opens a profession's window from a click (the card's "Open Leatherworking"). true if asked.
function Craft.Open(profID)
  if not (TSUI and TSUI.OpenTradeSkill and profID) then return false end
  if InCombatLockdown and InCombatLockdown() then return false end
  local ok = pcall(TSUI.OpenTradeSkill, profID)
  return ok
end

-- First queued craft I can make right now: entry, crafts (how many of it), or nil, and the
-- profession whose window would let some queued craft be made (when none can be now).
function Craft.NextQueued()
  local openProf
  for _, x in ipairs(NS.Queue and NS.Queue.Entries() or {}) do
    local rec = MyRecord(x.recipeID)
    local left = rec and NS.Queue.CraftsLeft(x, rec) or 0
    if left > 0 then
      local ok, _, times, prof = Craft.CanCraft(x.recipeID)
      if ok then return x, min(left, times) end
      openProf = openProf or prof
    end
  end
  return nil, nil, openProf
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

-- What this character crafted lately: chars[Me].made[itemID] = time of the last craft (kept a
-- day). Trade.lua counts a handed-over item as "crafted for" someone only when it was made here.
local MADE_TTL = 86400

local function Made()
  local db = type(CraftBoardDB) == "table" and CraftBoardDB
  local c = db and NS.Me and type(db.chars) == "table" and db.chars[NS.Me]
  if type(c) ~= "table" then return nil end
  if type(c.made) ~= "table" then c.made = {} end
  return c.made
end

-- I crafted itemID on this character within `seconds` (default a day).
function Craft.MadeRecently(itemID, seconds)
  local made = Made()
  local t = made and made[itemID]
  return type(t) == "number" and time() - t <= (seconds or MADE_TTL) or false
end

-- Events --------------------------------------------------------------------------

local function Mine(unit, spellID)
  if issecretvalue and (issecretvalue(unit) or issecretvalue(spellID)) then return nil end
  if unit ~= "player" or type(spellID) ~= "number" then return nil end
  return MyRecord(spellID)
end

-- Recipes with a varying yield (rec.yMax): the count in my bags before a cast, then what it
-- really made once the items land, beyond the minimum the queue was credited with.
local yieldBefore, yieldCheck = {}, nil

local function BagCount(itemID)
  if C_Item and C_Item.GetItemCount then
    local ok, n = pcall(C_Item.GetItemCount, itemID, false)
    if ok and type(n) == "number" then return n end
  end
  if GetItemCount then
    local ok, n = pcall(GetItemCount, itemID)
    if ok and type(n) == "number" then return n end
  end
  return nil
end

-- Every successful cast of one of my recipes counts toward the queue and is remembered.
NS.Register("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
  local rec = Mine(unit, spellID)
  if not rec then return end
  -- An enchant cast goes onto someone's item: it only counts toward planned (leveling) entries;
  -- entries for a player are done by the trade that applies it.
  if rec.e then
    if NS.Queue and NS.Queue.Crafted then NS.Queue.Crafted(spellID, rec, true) end
    NS.Fire("CRAFT_UPDATED")
    return
  end
  local made = Made()
  if made and type(rec.o) == "number" then
    local now = time()
    made[rec.o] = now
    for id, t in pairs(made) do
      if type(t) ~= "number" or now - t > MADE_TTL then made[id] = nil end
    end
  end
  if batch and batch.recipeID == spellID then
    batch.left, batch.t = batch.left - 1, time()
    if batch.left <= 0 then batch = nil end
  end
  if NS.Queue and NS.Queue.Crafted then NS.Queue.Crafted(spellID, rec) end
  -- A varying yield: the queue got the minimum; the bags say what came out (next bag update).
  if rec.yMax and yieldBefore[spellID] then
    yieldCheck = { recipeID = spellID, rec = rec, before = yieldBefore[spellID] }
    yieldBefore[spellID] = nil
  end
  NS.Fire("CRAFT_UPDATED")
end)

NS.Register("UNIT_SPELLCAST_START", function(_, unit, _, spellID)
  local rec = Mine(unit, spellID)
  if rec then
    if batch then batch.t = time() end
    if rec.yMax and type(rec.o) == "number" then yieldBefore[spellID] = BagCount(rec.o) end
    NS.Fire("CRAFT_UPDATED")
  end
end)

NS.Register("BAG_UPDATE_DELAYED", function()
  local c = yieldCheck
  if not c then return end
  yieldCheck = nil
  local now = BagCount(c.rec.o)
  if not (now and c.before) then return end
  local extra = (now - c.before) - math.max(1, c.rec.y or 1)
  if extra > 0 and NS.Queue and NS.Queue.Crafted then NS.Queue.Crafted(c.recipeID, c.rec, nil, extra) end
end)

-- Moving, jumping or acting ends a batch early.
for _, ev in ipairs({ "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED" }) do
  NS.Register(ev, function(_, unit, _, spellID)
    if Mine(unit, spellID) then
      batch = nil
      NS.Fire("CRAFT_UPDATED")
    end
  end)
end
