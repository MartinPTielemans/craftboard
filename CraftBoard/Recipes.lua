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

local function ReadRecipe(recipeID, info, profID, prev)
  local rec = { p = profID, n = info.name, r = {} }
  local _, isEnchant = AcceptType(info.recipeType)
  if isEnchant then rec.e = true end

  local schem = TSUI.GetRecipeSchematic and TSUI.GetRecipeSchematic(recipeID, false)
  if type(schem) == "table" then
    rec.o = schem.outputItemID
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
  for _, recipeID in ipairs(ids) do
    local info = type(recipeID) == "number" and TSUI.GetRecipeInfo(recipeID)
    if type(info) == "table" and info.learned then
      learnedIDs[#learnedIDs + 1] = recipeID
      learnedInfo[#learnedInfo + 1] = info
      s1 = (s1 + recipeID) % 2147483647
      s2 = (s2 + (recipeID % 1000003) * (recipeID % 999983)) % 2147483647
    end
  end
  local sig = #learnedIDs .. ":" .. s1 .. ":" .. s2

  local changed = false
  local prof = { profName, rank, maxRank }
  if not ProfsEqual(c.profs[profID], prof) then
    c.profs[profID] = prof
    changed = true
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

local function crafterLess(a, b)
  if a.online ~= b.online then return a.online end
  if a.mine ~= b.mine then return a.mine end
  return a.name < b.name
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

  -- My own Bind-on-Pickup recipes stay listed (bop=true) so I can see them; they are
  -- never shared with peers (see Recipes.Shareable).
  local myNames, bop = {}, {}
  for _, ch in ipairs(Recipes.AllMyChars()) do
    myNames[ch.name] = true
    for recipeID, rec in pairs(ch.recipes) do
      add(recipeID, { name = ch.name, mine = true, online = ch.isMe, sameRealm = ch.sameRealm })
      if not Recipes.IsTradeable(rec) then bop[recipeID] = true end
    end
  end

  local peers = NS.Comm and NS.Comm.Peers and NS.Comm.Peers()
  if type(peers) == "table" then
    for name, p in pairs(peers) do
      if type(p) == "table" and type(p.recipes) == "table" and not myNames[name] then
        for recipeID in pairs(p.recipes) do
          if type(recipeID) == "number" then
            add(recipeID, { name = name, mine = false, online = p.online and true or false, sameRealm = true })
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
        bop = bop[recipeID] or nil,
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
function Recipes.Hash()
  local ids = {}
  for recipeID in pairs(Recipes.Shareable()) do ids[#ids + 1] = recipeID end
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
