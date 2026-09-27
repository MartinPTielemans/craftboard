-- CraftBoard Cooldowns: crafts with a cooldown (transmutes, Mooncloth...) on my characters, and
-- the ones peers announce. My characters: CraftBoardDB.chars[key].cd = { [recipeID] = ready-at
-- time (0 = ready) }, read from the spell cooldown on login, after a cast and on cooldown updates,
-- and from the profession window while it is open. The current character's entries go out in
-- the hello (seconds until ready, so peers' clocks don't matter); peers' land in Comm.Peers().cd.
local ADDON, NS = ...

local Cooldowns = {}
NS.Cooldowns = Cooldowns

local L = NS.L
local format, floor, max = string.format, math.floor, math.max
local TSUI = C_TradeSkillUI

-- Crafts known to have a cooldown even while it is ready (so the ready state is shared too).
-- Any recipe whose cooldown was once seen running is remembered on its record (cdr = true).
local KNOWN = {
  [18560] = true,   -- Mooncloth
  [17187] = true,   -- Transmute: Arcanite
  [11479] = true,   -- Transmute: Iron to Gold
  [11480] = true,   -- Transmute: Mithril to Truesilver
  [17559] = true, [17560] = true, [17561] = true, [17562] = true,   -- elemental transmutes
  [17563] = true, [17564] = true, [17565] = true, [17566] = true,
  [25146] = true,   -- Transmute: Elemental Fire
}

-- The client's own word for "Transmute", from Transmute: Arcanite's localized name (the part
-- before the colon), so other transmutes are recognised on any client language.
local transmutePrefix
local function TransmutePrefix()
  if transmutePrefix ~= nil then return transmutePrefix end
  local name
  if C_Spell and C_Spell.GetSpellName then
    local ok, n = pcall(C_Spell.GetSpellName, 17187)
    if ok then name = n end
  elseif GetSpellInfo then
    local ok, n = pcall(GetSpellInfo, 17187)
    if ok then name = n end
  end
  local prefix = type(name) == "string" and name:match("^([^:]+):")
  if prefix then transmutePrefix = prefix end
  return prefix or "Transmute"
end

local function MyChar()
  local db = type(CraftBoardDB) == "table" and CraftBoardDB
  local c = db and NS.Me and type(db.chars) == "table" and db.chars[NS.Me]
  return type(c) == "table" and c or nil
end

-- A recipe with a cooldown: known list, remembered on the record, or a transmute.
function Cooldowns.Is(recipeID, rec)
  if KNOWN[recipeID] then return true end
  if type(rec) == "table" then
    if rec.cdr then return true end
    if type(rec.n) == "string" then
      local prefix = TransmutePrefix()
      if rec.n:sub(1, #prefix) == prefix or rec.n:find("^Transmute") then return true end
    end
  end
  return false
end

-- Seconds left on a spell's cooldown (0 when ready), ignoring the global cooldown; nil if the
-- client can't tell.
local function SpellRemaining(spellID)
  local start, duration
  if C_Spell and C_Spell.GetSpellCooldown then
    local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
    if ok and type(info) == "table" then start, duration = info.startTime, info.duration end
  elseif GetSpellCooldown then
    local ok, s, d = pcall(GetSpellCooldown, spellID)
    if ok then start, duration = s, d end
  end
  if type(start) ~= "number" or type(duration) ~= "number" or not GetTime then return nil end
  if start <= 0 or duration <= 2 then return 0 end
  return max(0, start + duration - GetTime())
end

-- Re-read every cooldown craft of the current character. Returns true when something changed.
function Cooldowns.Update()
  local c = MyChar()
  if not (c and type(c.recipes) == "table") then return false end
  c.cd = type(c.cd) == "table" and c.cd or {}
  local now, changed = time(), false
  for id, rec in pairs(c.recipes) do
    if type(id) == "number" and Cooldowns.Is(id, rec) then
      local left = SpellRemaining(id)
      if left then
        local at = left > 0 and now + floor(left) or 0
        -- Tolerate a minute of drift so repeated reads don't count as changes.
        if not c.cd[id] or math.abs((c.cd[id] or 0) - at) > 60 then
          c.cd[id] = at
          changed = true
        end
      end
    end
  end
  for id in pairs(c.cd) do
    if not c.recipes[id] then c.cd[id], changed = nil, true end
  end
  if changed then NS.Fire("COOLDOWNS_UPDATED") end
  return changed
end

-- While my profession window is open: the recipe API knows every cooldown; one that is running
-- marks its recipe as a cooldown craft for good.
function Cooldowns.FromTradeSkill()
  local c = MyChar()
  if not (c and type(c.recipes) == "table" and TSUI and TSUI.GetRecipeCooldown) then return end
  if TSUI.IsTradeSkillLinked and TSUI.IsTradeSkillLinked() then return end
  local marked = false
  for id, rec in pairs(c.recipes) do
    if type(rec) == "table" then
      local ok, cd = pcall(TSUI.GetRecipeCooldown, id)
      if ok and type(cd) == "number" and cd > 0 and not rec.cdr then
        rec.cdr, marked = true, true
      end
    end
  end
  if Cooldowns.Update() == false and marked then NS.Fire("COOLDOWNS_UPDATED") end
end

-- For the hello: { [recipeID] = seconds until ready } for the current character, at most n.
function Cooldowns.ForHello(n)
  local c = MyChar()
  if not (c and type(c.cd) == "table") then return nil end
  local out, count, now = {}, 0, time()
  for id, at in pairs(c.cd) do
    if count >= n then break end
    out[id] = max(0, (at or 0) - now)
    count = count + 1
  end
  return count > 0 and out or nil
end

-- Seconds until the crafter's cooldown for recipeID is ready (0 = ready), or nil when unknown
-- (not a cooldown craft, or a peer on an older version).
function Cooldowns.Remaining(name, recipeID)
  local now = time()
  local db = type(CraftBoardDB) == "table" and CraftBoardDB
  local c = db and type(db.chars) == "table" and db.chars[name]
  if type(c) == "table" then
    local at = type(c.cd) == "table" and c.cd[recipeID]
    if at == nil then return nil end
    return max(0, at - now)
  end
  local peers = NS.Comm and NS.Comm.Peers and NS.Comm.Peers()
  local p = peers and peers[name]
  local at = p and type(p.cd) == "table" and p.cd[recipeID]
  if at == nil then return nil end
  return max(0, at - now)
end

-- "ready" / "4h" / "2d" for a remaining time.
function Cooldowns.Text(left)
  if not left then return nil end
  if left <= 0 then return L["ready"] end
  if left < 3600 then return format(L["%dm"], max(1, floor(left / 60))) end
  if left < 2 * 86400 then return format(L["%dh"], floor(left / 3600)) end
  return format(L["%dd"], floor(left / 86400))
end

-- /cb cd: every cooldown craft on my characters.
function Cooldowns.Print()
  local db = type(CraftBoardDB) == "table" and CraftBoardDB
  local chars = db and type(db.chars) == "table" and db.chars or {}
  local keys = {}
  for key in pairs(chars) do keys[#keys + 1] = key end
  table.sort(keys)
  local any = false
  for _, key in ipairs(keys) do
    local c = chars[key]
    if type(c) == "table" and type(c.cd) == "table" then
      for id, at in pairs(c.cd) do
        any = true
        local rec = type(c.recipes) == "table" and c.recipes[id]
        local name = type(rec) == "table" and rec.n or (NS.Recipes and NS.Recipes.NameOf(id)) or tostring(id)
        NS.Print(format(L["%s: %s \226\128\148 %s"], NS.ShortName(key), name, Cooldowns.Text(max(0, at - time()))))
      end
    end
  end
  if not any then NS.Print(L["No crafting cooldowns recorded. Open the profession window once."]) end
end

-- Events --------------------------------------------------------------------------

local pending = false
local function Soon(delay)
  if pending then return end
  pending = true
  C_Timer.After(delay or 2, function()
    pending = false
    Cooldowns.Update()
  end)
end

NS.Register("PLAYER_LOGIN", function() Soon(5) end)
NS.Register("SPELL_UPDATE_COOLDOWN", function() Soon(2) end)
NS.Register("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
  if issecretvalue and (issecretvalue(unit) or issecretvalue(spellID)) then return end
  if unit ~= "player" or type(spellID) ~= "number" then return end
  local c = MyChar()
  local rec = c and type(c.recipes) == "table" and c.recipes[spellID]
  if rec and Cooldowns.Is(spellID, rec) then Soon(1) end
end)
NS.Register("TRADE_SKILL_LIST_UPDATE", function()
  C_Timer.After(1, Cooldowns.FromTradeSkill)
end)
