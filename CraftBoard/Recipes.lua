-- CraftBoard Recipes: scan learned recipes from the open profession window; search across my chars + peers.
local ADDON, NS = ...

local Recipes = {}
NS.Recipes = Recipes

local L = NS.L

local TSUI = C_TradeSkillUI

local function MyChar()
  if not CraftBoardDB then return nil end
  if not NS.Me and NS.UpdateIdentity then NS.UpdateIdentity() end
  if not NS.Me then return nil end
  local c = CraftBoardDB.chars[NS.Me]
  if type(c) ~= "table" then
    c = {}
    CraftBoardDB.chars[NS.Me] = c
  end
  c.recipes = c.recipes or {}
  c.profs = c.profs or {}
  return c
end

local function Catalogue()
  if not CraftBoardDB then return nil end
  CraftBoardDB.recipeNames = CraftBoardDB.recipeNames or {}
  return CraftBoardDB.recipeNames
end

-- Record a recipe name/output in the shared catalogue (also for Comm to call with received data).
function Recipes.LearnName(recipeID, name, outputItemID)
  local cat = Catalogue()
  if not cat or type(recipeID) ~= "number" then return end
  local e = cat[recipeID]
  if not e then
    e = {}
    cat[recipeID] = e
  end
  if type(name) == "string" and name ~= "" then e.n = name end
  if type(outputItemID) == "number" then e.o = outputItemID end
end

-- Blizzard recipe categories ("Cloaks", "Reagents", ...). CraftBoardDB.categories[categoryID] =
-- display name; records and catalogue entries keep the categoryID (field c). Local only: the
-- shared protocol never carries categories.
local function Categories()
  if not CraftBoardDB then return nil end
  if type(CraftBoardDB.categories) ~= "table" then CraftBoardDB.categories = {} end
  return CraftBoardDB.categories
end

local catResolved = {}   -- [categoryID] = true once looked up this session

-- Leaf name of a category; walks parentCategoryID when a level has no name. Also stores the
-- parents' names. Returns the name or nil.
local function ResolveCategory(categoryID)
  local cats = Categories()
  if not cats or type(categoryID) ~= "number" then return nil end
  if catResolved[categoryID] then return cats[categoryID] end
  catResolved[categoryID] = true
  if not (TSUI and TSUI.GetCategoryInfo) then return cats[categoryID] end
  local id, leaf, depth = categoryID, nil, 0
  while type(id) == "number" and id ~= 0 and depth < 6 do
    local ok, info = pcall(TSUI.GetCategoryInfo, id)
    if not ok or type(info) ~= "table" then break end
    local n = info.name
    if type(n) == "string" and n ~= "" then
      cats[id] = n
      if not leaf then leaf = n end
    end
    id, depth = info.parentCategoryID, depth + 1
  end
  if leaf then cats[categoryID] = leaf end
  return cats[categoryID]
end

-- Remember a recipe's category on the catalogue entry (known or not, so peers' recipes in a
-- profession I have also get Blizzard's grouping). Returns true when something changed.
local function NoteCategory(recipeID, categoryID, name)
  if type(recipeID) ~= "number" or type(categoryID) ~= "number" then return false end
  ResolveCategory(categoryID)
  local cat = Catalogue()
  if not cat then return false end
  local e = cat[recipeID]
  if not e then
    e = {}
    cat[recipeID] = e
    if type(name) == "string" and name ~= "" then e.n = name end
  end
  if e.c == categoryID then return false end
  e.c = categoryID
  return true
end

-- Profession name for a skill line, from my characters' records (current character first), or nil.
function NS.ProfessionName(profID)
  local db = type(CraftBoardDB) == "table" and CraftBoardDB
  if not (db and type(db.chars) == "table" and profID ~= nil) then return nil end
  local function nameOf(c)
    local p = type(c) == "table" and type(c.profs) == "table" and c.profs[profID]
    local n = type(p) == "table" and (p.name or p[1])
    return type(n) == "string" and n ~= "" and n or nil
  end
  local n = NS.Me and nameOf(db.chars[NS.Me])
  if n then return n end
  for _, c in pairs(db.chars) do
    n = nameOf(c)
    if n then return n end
  end
  return nil
end

-- Profession icon (file ID / path) for a skill line, or nil.
function Recipes.ProfessionIcon(profID)
  if type(profID) ~= "number" then return nil end
  if TSUI and TSUI.GetTradeSkillTexture then
    local ok, tex = pcall(TSUI.GetTradeSkillTexture, profID)
    if ok and tex and tex ~= 0 and tex ~= "" then return tex end
  end
  return nil
end

local function IsViewingOther()
  if not TSUI then return false end
  if TSUI.IsTradeSkillLinked and TSUI.IsTradeSkillLinked() then return true end
  if TSUI.IsTradeSkillGuild and TSUI.IsTradeSkillGuild() then return true end
  if TSUI.IsNPCCrafting and TSUI.IsNPCCrafting() then return true end
  return false
end

-- Returns profID, name, rank, max for the open profession, or nil.
local function OpenProfession()
  if TSUI and TSUI.GetBaseProfessionInfo then
    local info = TSUI.GetBaseProfessionInfo()
    if type(info) == "table" and info.professionID and info.professionID ~= 0 then
      return info.professionID, info.professionName, info.skillLevel, info.maxSkillLevel
    end
  end
  -- Older modern API: tradeSkillID, name, rank, maxRank
  local getLine = (TSUI and TSUI.GetTradeSkillLine) or GetTradeSkillLine
  if getLine then
    local id, name, rank, maxRank = getLine()
    if type(id) == "number" and id ~= 0 then
      return id, name, rank, maxRank
    elseif type(id) == "string" then
      -- Classic-style global returns name, rank, max (no ID); key by name.
      return id, id, name, rank
    end
  end
  return nil
end

local RT = Enum and Enum.TradeskillRecipeType
local BASIC = (Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic) or 1

-- Item and Enchant recipes are kept (enchants usually have no output item; flagged e=true).
local function AcceptType(recipeType)
  -- Unknown enum shape (e.g. no .Item on this client): accept rather than record nothing.
  if not RT or recipeType == nil or RT.Item == nil then return true, false end
  if recipeType == RT.Item then return true, false end
  if RT.Enchant and recipeType == RT.Enchant then return true, true end
  return false, false
end

-- Bind types that make the output impossible to hand to another player.
local BIND_ON_PICKUP, BIND_QUEST = 1, 4

local function IsBound(b)
  return b == BIND_ON_PICKUP or b == BIND_QUEST
end

-- The 14th return of GetItemInfo (skipping the first) is bindType.
local function FirstAndBind(ok, first, ...)
  if not ok then return nil, nil end
  return first, (select(13, ...))
end

-- Bind type of an item from the client cache, or nil while it isn't cached.
-- Handles both the multi-return and a table-returning C_Item.GetItemInfo.
local function CachedBindType(itemID)
  if type(itemID) ~= "number" then return nil end
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not getInfo then return nil end
  local first, bind = FirstAndBind(pcall(getInfo, itemID))
  if first == nil then return nil end
  if type(first) == "table" then bind = first.bindType end
  if type(bind) ~= "number" then return nil end
  return bind
end

-- Async resolution of unknown bind types. Loaded binds are applied to every stored record
-- in one pass, and RECIPES_UPDATED fires once per batch (debounced).
local bindWanted = {}      -- [itemID] = true once a load was requested this session
local bindLoaded = {}      -- [itemID] = bindType, waiting for the flush
local bindDirty = false    -- a record gained a bound type outside the flush
local flushToken = 0

local function ApplyLoadedBinds()
  local changed = bindDirty
  bindDirty = false
  if next(bindLoaded) and CraftBoardDB and type(CraftBoardDB.chars) == "table" then
    for _, c in pairs(CraftBoardDB.chars) do
      if type(c) == "table" and type(c.recipes) == "table" then
        for _, rec in pairs(c.recipes) do
          if type(rec) == "table" and rec.b == nil and not rec.e and rec.o and bindLoaded[rec.o] ~= nil then
            rec.b = bindLoaded[rec.o]
            changed = true
          end
        end
      end
    end
  end
  bindLoaded = {}
  if changed then NS.Fire("RECIPES_UPDATED") end
end

local function ScheduleBindFlush()
  if not (C_Timer and C_Timer.After) then
    ApplyLoadedBinds()
    return
  end
  flushToken = flushToken + 1
  local mine = flushToken
  C_Timer.After(0.5, function()
    if mine == flushToken then ApplyLoadedBinds() end
  end)
end

local function OnBindLoaded(itemID)
  local b = CachedBindType(itemID)
  if b ~= nil then
    bindLoaded[itemID] = b
    ScheduleBindFlush()
  end
end

local function RequestBind(itemID)
  if type(itemID) ~= "number" or bindWanted[itemID] then return end
  bindWanted[itemID] = true
  if C_Item and C_Item.DoesItemExistByID then
    local ok, exists = pcall(C_Item.DoesItemExistByID, itemID)
    if ok and exists == false then return end
  end
  if Item and Item.CreateFromItemID then
    local ok = pcall(function()
      local item = Item:CreateFromItemID(itemID)
      item:ContinueOnItemLoad(function() OnBindLoaded(itemID) end)
    end)
    if ok then return end
  end
  if C_Item and C_Item.RequestLoadItemDataByID then
    pcall(C_Item.RequestLoadItemDataByID, itemID)
  end
end

-- Fallback path for clients without the Item mixin.
NS.Register("GET_ITEM_INFO_RECEIVED", function(_, itemID, success)
  if itemID and bindWanted[itemID] and success then OnBindLoaded(itemID) end
end)

-- tradeable, unknown. Enchants and recipes without an output item are always tradeable.
-- An unknown bind type counts as tradeable (flagged unknown) and a load is requested.
function Recipes.IsTradeable(rec)
  if type(rec) ~= "table" then return true, true end
  if rec.e or type(rec.o) ~= "number" then return true, false end
  local b = rec.b
  if b == nil then
    b = CachedBindType(rec.o)
    if b == nil then
      RequestBind(rec.o)
      return true, true
    end
    rec.b = b
    if IsBound(b) then
      -- The shared set just shrank: let Comm/UI know.
      bindDirty = true
      ScheduleBindFlush()
    end
  end
  return not IsBound(b), false
end

-- Skill-up colour of a learned recipe from GetRecipeInfo: 0 orange (always), 1 yellow (usually),
-- 2 green (rarely), 3 grey (never) - Enum.TradeskillRelativeDifficulty's order. nil if unknown.
local function Difficulty(info)
  local d = type(info) == "table" and info.relativeDifficulty
  if type(d) == "number" and d >= 0 and d <= 3 then return d end
  return nil
end

-- Skill points one craft gives (GetRecipeInfo's numSkillUps), stored only when more than one.
local function SkillUps(info)
  local n = type(info) == "table" and info.numSkillUps
  if type(n) == "number" and n > 1 and n < 100 then return math.floor(n) end
  return nil
end

local function ReadRecipe(recipeID, info, profID, prev)
  local rec = { p = profID, n = info.name, r = {}, d = Difficulty(info), su = SkillUps(info) }
  if type(info.categoryID) == "number" then rec.c = info.categoryID end
  local _, isEnchant = AcceptType(info.recipeType)
  if isEnchant then rec.e = true end

  local schem = TSUI.GetRecipeSchematic and TSUI.GetRecipeSchematic(recipeID, false)
  if type(schem) == "table" then
    rec.o = schem.outputItemID
    -- Items per craft (arrows, bullets...); only stored when more than one.
    local y = tonumber(schem.quantityMin)
    if y and y > 1 then rec.y = math.floor(y) end
    -- Some recipes make a varying number (quantityMin..quantityMax): planning counts the minimum,
    -- and Craft credits the queue with what a cast really made (rec.yMax marks those recipes).
    local yMax = tonumber(schem.quantityMax)
    if yMax and yMax > (y or 1) then rec.yMax = math.floor(yMax) end
    if not rec.n then rec.n = schem.name end
    if type(schem.reagentSlotSchematics) == "table" then
      for _, slot in ipairs(schem.reagentSlotSchematics) do
        -- Schematics without reagentType (older shape) only list basic reagents.
        if (slot.reagentType == nil or slot.reagentType == BASIC) and type(slot.reagents) == "table" then
          -- A slot may accept several items (quality tiers): first one is the key, the rest
          -- go to .alts (only when present, so the stored shape stays { itemID, qty }).
          local qty = slot.quantityRequired
          local first, alts, seen = nil, nil, {}
          for _, rg in ipairs(slot.reagents) do
            local id = type(rg) == "table" and rg.itemID
            if type(id) == "number" and not seen[id] then
              seen[id] = true
              if not first then
                first = id
              else
                alts = alts or {}
                alts[#alts + 1] = id
              end
            end
          end
          if first and qty and qty > 0 then
            local entry = { first, qty }
            if alts then entry.alts = alts end
            rec.r[#rec.r + 1] = entry
          end
        end
      end
    end
  end
  -- A cooldown seen running once (Cooldowns.FromTradeSkill) stays known across rescans.
  if prev and prev.cdr then rec.cdr = true end
  if not rec.o and TSUI.GetRecipeOutputItemData then
    local ok, out = pcall(TSUI.GetRecipeOutputItemData, recipeID)
    if ok and type(out) == "table" then rec.o = out.itemID end
  end
  if rec.o and not rec.e then
    rec.b = CachedBindType(rec.o)
    if rec.b == nil then
      if prev and prev.o == rec.o then rec.b = prev.b end
      if rec.b == nil then RequestBind(rec.o) end
    end
  end
  return rec
end

local function ProfsEqual(a, b)
  return a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

-- Hash helpers ("count:polyhash" over sorted IDs).
local function IdHash(ids)
  table.sort(ids)
  local h = 0
  for i = 1, #ids do
    h = (h * 31 + ids[i]) % 2147483647
  end
  return #ids .. ":" .. h
end

-- Every stored recipe of my current char, tradeable or not (Scan's change detection).
local function FullHash()
  local ids = {}
  for recipeID in pairs(Recipes.Mine()) do
    if type(recipeID) == "number" then ids[#ids + 1] = recipeID end
  end
  return IdHash(ids)
end

-- Learned-ID signature per profession at the last full scan (session only), so repeated
-- TRADE_SKILL_LIST_UPDATEs don't re-read every schematic.
local lastSig = {}
local lastCount = {}

-- Scan the open profession. Returns number of learned recipes stored, or nil, reason.
-- Skips the per-recipe read when the learned set is unchanged, unless force is set.
-- Reasons are localized for display, except "unchanged" (a status code, never printed).
function Recipes.Scan(force)
  if not TSUI or not TSUI.GetAllRecipeIDs or not TSUI.GetRecipeInfo then
    return nil, L["profession API unavailable"]
  end
  if IsViewingOther() then return nil, L["viewing someone else's profession"] end
  if TSUI.IsTradeSkillReady and not TSUI.IsTradeSkillReady() then return nil, L["profession data not ready"] end
  if TSUI.IsDataSourceChanging and TSUI.IsDataSourceChanging() then return nil, L["profession data loading"] end
  local c = MyChar()
  if not c then return nil, L["character not known yet"] end
  local profID, profName, rank, maxRank = OpenProfession()
  if not profID then return nil, L["no profession window open"] end

  -- Cheap pass: learned IDs, count and an order-independent hash of them.
  local ids = TSUI.GetAllRecipeIDs() or {}
  local learnedIDs, learnedInfo = {}, {}
  local s1, s2 = 0, 0
  local catChanged = false
  for _, recipeID in ipairs(ids) do
    local info = type(recipeID) == "number" and TSUI.GetRecipeInfo(recipeID)
    if type(info) == "table" and type(info.categoryID) == "number" then
      if NoteCategory(recipeID, info.categoryID, info.name) then catChanged = true end
      local old = c.recipes[recipeID]
      if info.learned and type(old) == "table" and old.c ~= info.categoryID then
        old.c = info.categoryID
        catChanged = true
      end
    end
    if type(info) == "table" and info.learned then
      -- Colours (and the skill points they give) move with the skill while the learned set
      -- stays the same: keep them current.
      local old = c.recipes[recipeID]
      local d = Difficulty(info)
      if type(old) == "table" and d ~= nil and old.d ~= d then
        old.d = d
        catChanged = true
      end
      local su = SkillUps(info)
      if type(old) == "table" and old.su ~= su then
        old.su = su
        catChanged = true
      end
      learnedIDs[#learnedIDs + 1] = recipeID
      learnedInfo[#learnedInfo + 1] = info
      s1 = (s1 + recipeID) % 2147483647
      s2 = (s2 + (recipeID % 1000003) * (recipeID % 999983)) % 2147483647
    end
  end
  local sig = #learnedIDs .. ":" .. s1 .. ":" .. s2

  local changed = catChanged
  local prof = { profName, rank, maxRank }
  -- Updated in place: the local-only fields below (and Skills.lua's) stay.
  local p = c.profs[profID]
  if type(p) ~= "table" then
    c.profs[profID] = prof
    p = prof
    changed = true
  elseif not ProfsEqual(p, prof) then
    p[1], p[2], p[3] = profName, rank, maxRank
    changed = true
  end
  -- Icon for the UI portrait; local only (Comm sends name/rank/max).
  local icon = Recipes.ProfessionIcon(profID)
  if icon then p.icon = icon end
  if #learnedIDs > 0 then
    -- The rank the colours (rec.d) were just read at (local only, never sent), and the
    -- recipes this profession learned since its last scan are in now.
    if type(rank) == "number" then p.sr = rank end
    if p.newRecipes then
      p.newRecipes = nil
      changed = true
    end
  end

  if not force and #learnedIDs > 0 and lastSig[profID] == sig then
    if changed then NS.Fire("RECIPES_UPDATED") end
    return lastCount[profID] or 0, "unchanged"
  end

  local before, beforeFull = Recipes.Hash(), FullHash()
  local found = {}
  local count = 0
  for i = 1, #learnedIDs do
    local recipeID, info = learnedIDs[i], learnedInfo[i]
    local ok = AcceptType(info.recipeType)
    if ok then
      local rec = ReadRecipe(recipeID, info, profID, c.recipes[recipeID])
      c.recipes[recipeID] = rec
      found[recipeID] = true
      count = count + 1
      Recipes.LearnName(recipeID, rec.n, rec.o)
    end
  end

  -- Drop this profession's recipes that are no longer learned (only on a non-empty scan,
  -- so a half-loaded list can't wipe the table).
  if count > 0 then
    for recipeID, rec in pairs(c.recipes) do
      if rec.p == profID and not found[recipeID] then
        c.recipes[recipeID] = nil
      end
    end
  end
  if #learnedIDs > 0 then
    lastSig[profID] = sig
    lastCount[profID] = count
  end
  c.scanned = time and time() or nil

  if changed or FullHash() ~= beforeFull or Recipes.Hash() ~= before then
    NS.Fire("RECIPES_UPDATED")
  end
  return count
end

-- Debounced auto-scan while a profession window is open.
local pending = false
local function QueueScan()
  if pending then return end
  if C_Timer and C_Timer.After then
    pending = true
    C_Timer.After(0.5, function()
      pending = false
      Recipes.Scan()
    end)
  else
    Recipes.Scan()
  end
end
NS.Register("TRADE_SKILL_SHOW", QueueScan)
NS.Register("TRADE_SKILL_LIST_UPDATE", QueueScan)

-- Skill line(s) a newly learned recipe may belong to: the client's answer (the line and its
-- parent profession), then what my records or the catalogue say. Empty when nothing tells.
local function LinesOfRecipe(recipeID)
  local out = {}
  if TSUI and TSUI.GetTradeSkillLineForRecipe then
    local ok, line, _, parent = pcall(TSUI.GetTradeSkillLineForRecipe, recipeID)
    if ok then
      if type(parent) == "number" then out[#out + 1] = parent end
      if type(line) == "number" then out[#out + 1] = line end
    end
  end
  if TSUI and TSUI.GetProfessionInfoByRecipeID then
    local ok, info = pcall(TSUI.GetProfessionInfoByRecipeID, recipeID)
    if ok and type(info) == "table" then
      if type(info.parentProfessionID) == "number" then out[#out + 1] = info.parentProfessionID end
      if type(info.professionID) == "number" then out[#out + 1] = info.professionID end
    end
  end
  local rec = Recipes.Record(recipeID)
  if type(rec) == "table" and rec.p ~= nil then out[#out + 1] = rec.p end
  local cat = Catalogue()
  local e = cat and cat[recipeID]
  if type(e) == "table" and e.p ~= nil then out[#out + 1] = e.p end
  return out
end

-- A recipe learned (trainer, recipe item): its profession's record is behind until the next
-- scan. c.profs[profID].newRecipes = true (every profession when the recipe's can't be told)
-- until then, and that scan reads every recipe again.
-- Where recipes are learned, shared with the recipe lists (5th field): 1 = a trainer, else the
-- item ID of the recipe item that taught it. Recorded when I learn one: a trainer window open
-- (or just closed), or a recipe item used in the seconds before. Kept in the catalogue (s), the
-- first source heard winning. Nothing at all when it can't be told (a quest, a client that hid
-- the item use).
local SRC_TRAINER = 1
Recipes.SRC_TRAINER = SRC_TRAINER
local trainerShownAt, trainerClosedAt = nil, nil
local closeEvent = false   -- the client has TRAINER_CLOSED
local lastUse = nil    -- { id = itemID, t = time, n = count in the bags then }

-- How many of an item the bags hold (nil when the client can't tell).
function Recipes.BagCount(itemID)
  local get = C_Item and C_Item.GetItemCount or GetItemCount
  if not get then return nil end
  local ok, n = pcall(get, itemID, false)
  return ok and type(n) == "number" and not (issecretvalue and issecretvalue(n)) and n or nil
end

function Recipes.SourceOf(recipeID)
  local cat = Catalogue()
  local e = cat and cat[recipeID]
  return e and type(e.s) == "number" and e.s or nil
end

function Recipes.SetSource(recipeID, src)
  local cat = Catalogue()
  if not (cat and type(recipeID) == "number" and type(src) == "number" and src >= 1) then return end
  local e = cat[recipeID]
  if type(e) ~= "table" then e = {}; cat[recipeID] = e end
  if e.s == nil then
    e.s = src
    return true    -- newly known (callers refresh what shows sources)
  end
  return false
end

local function IsRecipeItem(itemID)
  local get = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
  if not get then return false end
  local ok, _, _, _, _, _, classID = pcall(get, itemID)
  return ok and classID == 9
end

function Recipes.GuessSource(now)
  now = now or time()
  -- A recipe item used just now wins (it may have been used right after leaving a trainer).
  -- Only a use that went through: the recipe item is gone from the bags (a known or
  -- unlearnable recipe stays where it was).
  if lastUse and now - lastUse.t <= 10 and IsRecipeItem(lastUse.id) and lastUse.n
    and (Recipes.BagCount(lastUse.id) or lastUse.n) < lastUse.n then
    return lastUse.id
  end
  -- Still open: shown and not closed since (a client without the close event: shown within the
  -- last few minutes), or closed a moment ago.
  local open = trainerShownAt and (trainerClosedAt and trainerClosedAt < trainerShownAt
    or not trainerClosedAt and (closeEvent and true or now - trainerShownAt <= 300))
  if trainerShownAt and (open or (trainerClosedAt and now - trainerClosedAt <= 3)) then
    return SRC_TRAINER
  end
  return nil
end

NS.Register("TRAINER_SHOW", function() trainerShownAt = time() end)
closeEvent = pcall(NS.Register, "TRAINER_CLOSED", function() trainerClosedAt = time() end)
-- The item a recipe is learned from: noted when a bag item is used (observing only).
if hooksecurefunc and C_Container and C_Container.UseContainerItem then
  pcall(hooksecurefunc, C_Container, "UseContainerItem", function(bag, slot)
    local get = C_Container.GetContainerItemID
    local ok, id = pcall(get, bag, slot)
    -- With how many there were: the item is only used up once the recipe is learned.
    if ok and type(id) == "number" and not (issecretvalue and issecretvalue(id)) then
      lastUse = { id = id, t = time(), n = Recipes.BagCount(id) }
    end
  end)
end

local function OnRecipeLearned(recipeID)
  local c = MyChar()
  if not c or type(recipeID) ~= "number" then return end
  if issecretvalue and issecretvalue(recipeID) then return end
  local src = Recipes.GuessSource()
  if src then Recipes.SetSource(recipeID, src) end
  -- One recipe item teaches one recipe: the next one learned isn't put down to it as well.
  if src and src ~= SRC_TRAINER then lastUse = nil end
  local marked = false
  for _, id in ipairs(LinesOfRecipe(recipeID)) do
    local p = c.profs[id]
    if type(p) == "table" then
      p.newRecipes, lastSig[id], marked = true, nil, true
      break
    end
  end
  if not marked then
    for id, p in pairs(c.profs) do
      if type(p) == "table" and not p.gone then p.newRecipes, lastSig[id] = true, nil end
    end
  end
  NS.Fire("RECIPES_UPDATED")
end

-- NEW_RECIPE_LEARNED may not exist on every client: registered on a frame of our own, pcall'd
-- (NS.Register would raise for an unknown event).
do
  local f = CreateFrame and CreateFrame("Frame")
  if f and pcall(f.RegisterEvent, f, "NEW_RECIPE_LEARNED") then
    f:SetScript("OnEvent", function(_, event, recipeID)
      if event ~= "NEW_RECIPE_LEARNED" then return end
      local ok, err = pcall(OnRecipeLearned, recipeID)
      if not ok and NS.debug and NS.Print then NS.Print("recipe learned: " .. tostring(err)) end
    end)
  end
end

function Recipes.Mine()
  local c = MyChar()
  return c and c.recipes or {}
end

-- List of my characters: { {name="Name-Realm", sameRealm=bool, isMe=bool, recipes=, profs=}, ... }
function Recipes.AllMyChars()
  local out = {}
  if not CraftBoardDB or type(CraftBoardDB.chars) ~= "table" then return out end
  for key, c in pairs(CraftBoardDB.chars) do
    if type(c) == "table" then
      local realm = key:match("^[^%-]+%-(.+)$")
      out[#out + 1] = {
        name = key,
        sameRealm = realm ~= nil and realm == NS.Realm,
        isMe = key == NS.Me,
        recipes = c.recipes or {},
        profs = c.profs or {},
      }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- Recipe IDs are spell IDs, so the spell name is a usable fallback.
function Recipes.NameOf(recipeID)
  local cat = Catalogue()
  local e = cat and cat[recipeID]
  if e and e.n then return e.n end
  local name
  if TSUI and TSUI.GetRecipeInfo then
    local ok, info = pcall(TSUI.GetRecipeInfo, recipeID)
    if ok and type(info) == "table" then name = info.name end
  end
  if not name and C_Spell and C_Spell.GetSpellName then
    name = C_Spell.GetSpellName(recipeID)
  end
  if not name and GetSpellInfo then
    name = GetSpellInfo(recipeID)
  end
  if name then Recipes.LearnName(recipeID, name) end
  return name
end

local function OutputOf(recipeID)
  local cat = Catalogue()
  local e = cat and cat[recipeID]
  return e and e.o
end

-- Find a stored record (with reagents) for a recipe on any of my chars; current char first.
function Recipes.Record(recipeID)
  local mine = Recipes.Mine()
  if mine[recipeID] then return mine[recipeID] end
  if CraftBoardDB and CraftBoardDB.chars then
    for _, c in pairs(CraftBoardDB.chars) do
      if type(c) == "table" and c.recipes and c.recipes[recipeID] then
        return c.recipes[recipeID]
      end
    end
  end
  return nil
end

-- Blizzard category name of a recipe (from a scan on any of my chars, or seen in one of my
-- profession windows), or nil.
function Recipes.CategoryOf(recipeID)
  local cats = type(CraftBoardDB) == "table" and CraftBoardDB.categories
  if type(cats) ~= "table" then return nil end
  local rec = Recipes.Record(recipeID)
  local id = type(rec) == "table" and rec.c or nil
  if id == nil then
    local cat = Catalogue()
    local e = cat and cat[recipeID]
    id = type(e) == "table" and e.c or nil
  end
  local n = id ~= nil and cats[id]
  if type(n) == "string" and n ~= "" then return n end
  return nil
end

-- Group names for items whose recipe has no Blizzard category (peers' recipes).
local SLOT_GROUPS = {
  INVTYPE_CLOAK = L["Cloaks"], INVTYPE_HEAD = L["Helmets"], INVTYPE_CHEST = L["Chest"],
  INVTYPE_ROBE = L["Chest"], INVTYPE_LEGS = L["Pants"], INVTYPE_FEET = L["Boots"],
  INVTYPE_HAND = L["Gloves"], INVTYPE_WRIST = L["Bracers"], INVTYPE_WAIST = L["Belts"],
  INVTYPE_SHOULDER = L["Shoulders"], INVTYPE_BAG = L["Bags"], INVTYPE_QUIVER = L["Bags"],
}

-- itemType, itemSubType, equipLoc from the cache (multi-return or table-shaped GetItemInfo).
local function ItemKind(itemID)
  if type(itemID) ~= "number" then return nil end
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not getInfo then return nil end
  local ok, first, _, _, _, _, itemType, subType, _, equipLoc = pcall(getInfo, itemID)
  if not ok or first == nil then return nil end
  if type(first) == "table" then
    return first.itemType, first.itemSubType, first.itemEquipLoc or first.equipLoc
  end
  return itemType, subType, equipLoc
end

-- Group from the output item: equip slot, else item sub type, else nil.
function Recipes.ItemGroup(itemID)
  local _, subType, equipLoc = ItemKind(itemID)
  if type(equipLoc) == "string" and SLOT_GROUPS[equipLoc] then return SLOT_GROUPS[equipLoc] end
  if type(subType) == "string" and subType ~= "" then return subType end
  return nil
end

-- List group of a recipe: Blizzard's category when known, else from the output item, else "Other".
function Recipes.GroupOf(recipeID, itemID)
  return Recipes.CategoryOf(recipeID) or Recipes.ItemGroup(itemID or OutputOf(recipeID)) or L["Other"]
end

-- Fairness rule: online crafters first (busy ones after the available ones), then my own
-- characters; within a group the order is shuffled once per session so no name is always at
-- the top. Nothing else ranks a crafter.
local sessionSalt = math.random(1, 1e6)
-- Memoized per name for the session: sorting every recipe's crafters was Search's main cost.
local shuffleKeys = {}
local function shuffleKey(name)
  local h = shuffleKeys[name]
  if h then return h end
  h = sessionSalt
  for i = 1, #name do h = (h * 31 + name:byte(i)) % 2147483647 end
  shuffleKeys[name] = h
  return h
end
local function crafterLess(a, b)
  if a.online ~= b.online then return a.online end
  if (a.busy or false) ~= (b.busy or false) then return not a.busy end
  if a.mine ~= b.mine then return a.mine end
  return shuffleKey(a.name) < shuffleKey(b.name)
end

-- Case-insensitive substring search on recipe or output item name. Empty text matches all.
function Recipes.Search(text)
  local needle = strlower(strtrim(text or ""))
  local byID = {}

  local function add(recipeID, crafter)
    local entry = byID[recipeID]
    if not entry then
      entry = { recipeID = recipeID, crafters = {}, seen = {} }
      byID[recipeID] = entry
    end
    if not entry.seen[crafter.name] then
      entry.seen[crafter.name] = true
      entry.crafters[#entry.crafters + 1] = crafter
    end
  end

  -- Find is about what can be made for someone else, so Bind-on-Pickup outputs are
  -- left out entirely (they still show on the Mine tab and are never shared with peers).
  -- My characters count only where their crafts can reach someone here: this realm and faction.
  local myNames = {}
  local chars = type(CraftBoardDB) == "table" and type(CraftBoardDB.chars) == "table" and CraftBoardDB.chars or {}
  local reachable = NS.Inventory and NS.Inventory.Reachable
  for _, ch in ipairs(Recipes.AllMyChars()) do
    myNames[ch.name] = true
    if ch.isMe or not reachable or reachable(ch.name, chars[ch.name]) then
      for recipeID, rec in pairs(ch.recipes) do
        if Recipes.IsTradeable(rec) then
          add(recipeID, { name = ch.name, mine = true, online = ch.isMe, sameRealm = ch.sameRealm })
        end
      end
    end
  end

  local peers = NS.Comm and NS.Comm.Peers and NS.Comm.Peers()
  if type(peers) == "table" then
    for name, p in pairs(peers) do
      if type(p) == "table" and type(p.recipes) == "table" and not myNames[name] then
        for recipeID in pairs(p.recipes) do
          if type(recipeID) == "number" then
            add(recipeID, { name = name, mine = false, online = p.online and true or false, sameRealm = true,
              busy = p.busy and true or false })
          end
        end
      end
    end
  end

  local results = {}
  for recipeID, entry in pairs(byID) do
    local name = Recipes.NameOf(recipeID)
    local out = OutputOf(recipeID)
    local match = needle == ""
    if not match and name and strlower(name):find(needle, 1, true) then match = true end
    if not match and out and NS.Inventory and NS.Inventory.ItemName then
      local itemName = NS.Inventory.ItemName(out)
      if itemName and strlower(itemName):find(needle, 1, true) then match = true end
    end
    if match then
      table.sort(entry.crafters, crafterLess)
      local anyOnline = false
      for i = 1, #entry.crafters do
        if entry.crafters[i].online then anyOnline = true end
      end
      results[#results + 1] = {
        recipeID = recipeID,
        name = name or string.format(L["Recipe %d"], recipeID),
        outputItemID = out,
        crafters = entry.crafters,
        online = anyOnline,
      }
    end
  end

  table.sort(results, function(a, b)
    if a.online ~= b.online then return a.online end
    if a.name ~= b.name then return a.name < b.name end
    return a.recipeID < b.recipeID
  end)
  return results
end

-- My current char's recipes that can be crafted for someone else (what peers get to see).
function Recipes.Shareable()
  local out = {}
  for recipeID, rec in pairs(Recipes.Mine()) do
    if type(recipeID) == "number" and Recipes.IsTradeable(rec) then out[recipeID] = rec end
  end
  return out
end

-- Deterministic cheap hash of my current char's shareable recipe ID set: "count:polyhash".
-- The count equals the number of entries Comm sends (hello n / R list).
-- max: only the first max recipe IDs (in order), the ones a recipe list can carry: a list and
-- the hash it is stored under always cover the same recipes.
function Recipes.Hash(max)
  local ids = {}
  for recipeID in pairs(Recipes.Shareable()) do ids[#ids + 1] = recipeID end
  if max and #ids > max then
    table.sort(ids)
    for k = #ids, max + 1, -1 do ids[k] = nil end
  end
  return IdHash(ids)
end

-- Resolve bind types for every stored record (all my chars) so the first hello and the
-- Find tab already know what is Bind on Pickup.
function Recipes.ResolveBinds()
  if not CraftBoardDB or type(CraftBoardDB.chars) ~= "table" then return end
  for _, c in pairs(CraftBoardDB.chars) do
    if type(c) == "table" and type(c.recipes) == "table" then
      for _, rec in pairs(c.recipes) do Recipes.IsTradeable(rec) end
    end
  end
end
NS.Register("PLAYER_LOGIN", function() Recipes.ResolveBinds() end)
