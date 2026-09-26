-- CraftBoard Recipes: scan learned recipes from the open profession window; search across my chars + peers.
local ADDON, NS = ...

local Recipes = {}
NS.Recipes = Recipes

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
  if not RT or recipeType == nil then return true, false end
  if recipeType == RT.Item then return true, false end
  if RT.Enchant and recipeType == RT.Enchant then return true, true end
  return false, false
end

local function ReadRecipe(recipeID, info, profID)
  local rec = { p = profID, n = info.name, r = {} }
  local _, isEnchant = AcceptType(info.recipeType)
  if isEnchant then rec.e = true end

  local schem = TSUI.GetRecipeSchematic and TSUI.GetRecipeSchematic(recipeID, false)
  if type(schem) == "table" then
    rec.o = schem.outputItemID
    if not rec.n then rec.n = schem.name end
    if type(schem.reagentSlotSchematics) == "table" then
      for _, slot in ipairs(schem.reagentSlotSchematics) do
        if slot.reagentType == BASIC and type(slot.reagents) == "table" and slot.reagents[1] then
          local itemID = slot.reagents[1].itemID
          local qty = slot.quantityRequired
          if itemID and qty and qty > 0 then
            rec.r[#rec.r + 1] = { itemID, qty }
          end
        end
      end
    end
  end
  if not rec.o and TSUI.GetRecipeOutputItemData then
    local ok, out = pcall(TSUI.GetRecipeOutputItemData, recipeID)
    if ok and type(out) == "table" then rec.o = out.itemID end
  end
  return rec
end

local function ProfsEqual(a, b)
  return a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

-- Scan the open profession. Returns number of learned recipes stored, or nil, reason.
function Recipes.Scan()
  if not TSUI or not TSUI.GetAllRecipeIDs or not TSUI.GetRecipeInfo then
    return nil, "profession API unavailable"
  end
  if IsViewingOther() then return nil, "viewing someone else's profession" end
  if TSUI.IsTradeSkillReady and not TSUI.IsTradeSkillReady() then return nil, "profession data not ready" end
  if TSUI.IsDataSourceChanging and TSUI.IsDataSourceChanging() then return nil, "profession data loading" end
  local c = MyChar()
  if not c then return nil, "character not known yet" end
  local profID, profName, rank, maxRank = OpenProfession()
  if not profID then return nil, "no profession window open" end

  local before = Recipes.Hash()
  local changed = false

  local ids = TSUI.GetAllRecipeIDs() or {}
  local found = {}
  local count = 0
  for _, recipeID in ipairs(ids) do
    local info = TSUI.GetRecipeInfo(recipeID)
    if type(info) == "table" and info.learned then
      local ok = AcceptType(info.recipeType)
      if ok then
        local rec = ReadRecipe(recipeID, info, profID)
        c.recipes[recipeID] = rec
        found[recipeID] = true
        count = count + 1
        Recipes.LearnName(recipeID, rec.n, rec.o)
      end
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

  local prof = { profName, rank, maxRank }
  if not ProfsEqual(c.profs[profID], prof) then
    c.profs[profID] = prof
    changed = true
  end
  c.scanned = time and time() or nil

  if changed or Recipes.Hash() ~= before then
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

  local myNames = {}
  for _, ch in ipairs(Recipes.AllMyChars()) do
    myNames[ch.name] = true
    for recipeID in pairs(ch.recipes) do
      add(recipeID, { name = ch.name, mine = true, online = ch.isMe, sameRealm = ch.sameRealm })
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
        name = name or ("Recipe " .. recipeID),
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

-- Deterministic cheap hash of my current char's recipe ID set: "count:polyhash".
function Recipes.Hash()
  local ids = {}
  for recipeID in pairs(Recipes.Mine()) do
    if type(recipeID) == "number" then ids[#ids + 1] = recipeID end
  end
  table.sort(ids)
  local h = 0
  for i = 1, #ids do
    h = (h * 31 + ids[i]) % 2147483647
  end
  return #ids .. ":" .. h
end
