-- CraftBoard Cooldowns: crafts with a cooldown (transmutes, Mooncloth...) on my characters, and
-- the ones peers announce. My characters: CraftBoardDB.chars[key].cd = { [recipeID] = ready-at
-- time (0 = ready) }, read from the spell cooldown on login, after a cast and on cooldown updates
-- (not in combat), and from the profession window while it is open. The current character's
-- cooldown crafts are cached (rebuilt after RECIPES_UPDATED) so those reads don't walk every
-- recipe. The current character's entries go out in the hello (seconds until ready, so peers'
-- clocks don't matter); peers' are kept by Comm (Comm.PeerCooldowns, else CraftBoardDB.peers
-- [name].cd).
-- Transmutes on one character that are ready, or end within a minute of each other, share a
-- cooldown: they are one group (Cooldowns.Group), shown as one line under the client's word
-- for "Transmute" in /cb cd, the notices and the minimap tooltip.
-- Ready notice: one quiet chat line when a cooldown on one of my characters runs out (checked
-- every minute and on updates; ones that ran out while offline in one line after login), said
-- once per cooldown (chars[key].cdSeen[recipeID] = the ready-at time announced). Option
-- CraftBoardDB.cooldownNotice (default on).
local ADDON, NS = ...

local Cooldowns = {}
NS.Cooldowns = Cooldowns

local L = NS.L
local format, floor, max, abs = string.format, math.floor, math.max, math.abs
local TSUI = C_TradeSkillUI
local TOGETHER = 60   -- s: transmutes whose cooldowns end this close share one line

-- Crafts known to have a cooldown even while it is ready (so the ready state is shared too).
-- Any recipe whose cooldown was once seen running is remembered on its record (cdr = true).
local MOONCLOTH = 18560
local KNOWN = {
  [MOONCLOTH] = true,
  [17187] = true,   -- Transmute: Arcanite
  [11479] = true,   -- Transmute: Iron to Gold
  [11480] = true,   -- Transmute: Mithril to Truesilver
  [17559] = true, [17560] = true, [17561] = true, [17562] = true,   -- elemental transmutes
  [17563] = true, [17564] = true, [17565] = true, [17566] = true,
  [25146] = true,   -- Transmute: Elemental Fire
}

local mine, mineDirty = {}, true   -- current character's cooldown crafts: { [recipeID] = true }

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
  if prefix then
    transmutePrefix = prefix
    mineDirty = true   -- localized transmutes may have been missed before
  end
  return prefix or "Transmute"
end

local function MyChar()
  local db = type(CraftBoardDB) == "table" and CraftBoardDB
  local c = db and NS.Me and type(db.chars) == "table" and db.chars[NS.Me]
  return type(c) == "table" and c or nil
end

local function InCombat()
  return InCombatLockdown and InCombatLockdown() and true or false
end

local function IsTransmuteName(name)
  if type(name) ~= "string" then return false end
  local prefix = TransmutePrefix()
  return name:sub(1, #prefix) == prefix or name:find("^Transmute") ~= nil
end

-- A recipe with a cooldown: known list, remembered on the record, or a transmute.
function Cooldowns.Is(recipeID, rec)
  if KNOWN[recipeID] then return true end
  if type(rec) == "table" then
    if rec.cdr then return true end
    if IsTransmuteName(rec.n) then return true end
  end
  return false
end

-- The current character's cooldown crafts, rebuilt when marked stale. nil without a character.
local function MySet()
  local c = MyChar()
  if not (c and type(c.recipes) == "table") then return nil end
  if mineDirty then
    mine, mineDirty = {}, false
    for id, rec in pairs(c.recipes) do
      if type(id) == "number" and Cooldowns.Is(id, rec) then mine[id] = true end
    end
  end
  return mine
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
  if issecretvalue and (issecretvalue(start) or issecretvalue(duration)) then return nil end
  if type(start) ~= "number" or type(duration) ~= "number" or not GetTime then return nil end
  if start <= 0 or duration <= 2 then return 0 end
  return max(0, start + duration - GetTime())
end

local skipped = false   -- an update was skipped in combat: read again once it ends

-- Re-read every cooldown craft of the current character. Returns true when something changed.
function Cooldowns.Update()
  if InCombat() then
    skipped = true
    return false
  end
  local c = MyChar()
  local set = MySet()
  if not set then return false end
  c.cd = type(c.cd) == "table" and c.cd or {}
  local now, changed = time(), false
  for id in pairs(set) do
    local left = SpellRemaining(id)
    if left then
      local at = left > 0 and now + floor(left) or 0
      -- A cooldown that ran out keeps its ready-at time (in the past, so still "ready"
      -- everywhere) for the ready notice; 0 only when none was known.
      local old = c.cd[id]
      if at == 0 and type(old) == "number" and old > 0 and old <= now + 60 then at = old end
      -- Tolerate a minute of drift so repeated reads don't count as changes.
      if not c.cd[id] or abs((c.cd[id] or 0) - at) > 60 then
        c.cd[id] = at
        changed = true
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
  -- Another's recipes (a linked, guild or NPC view) say nothing about my cooldowns.
  if (TSUI.IsTradeSkillLinked and TSUI.IsTradeSkillLinked()) or (TSUI.IsTradeSkillGuild and TSUI.IsTradeSkillGuild())
    or (TSUI.IsNPCCrafting and TSUI.IsNPCCrafting()) then
    return
  end
  local marked = false
  for id, rec in pairs(c.recipes) do
    if type(rec) == "table" and not rec.cdr then
      local ok, cd = pcall(TSUI.GetRecipeCooldown, id)
      if ok and type(cd) == "number" and cd > 0 then
        rec.cdr, marked = true, true
      end
    end
  end
  if marked then mineDirty = true end
  if Cooldowns.Update() == false and marked then NS.Fire("COOLDOWNS_UPDATED") end
end

local function RecipeName(c, id)
  local rec = type(c.recipes) == "table" and c.recipes[id]
  return type(rec) == "table" and rec.n or (NS.Recipes and NS.Recipes.NameOf and NS.Recipes.NameOf(id)) or tostring(id)
end

-- Groups a list of { key=, recipeID=, name=, at= } (character by character, as Ready sorts it):
-- transmutes on one character that are both ready, or both running and ending within a minute
-- of each other, are one group. Returns { {key=, name=, at=, ids={recipeID, ...}}, ... } in the
-- list's order; name is the transmute word for a group of several, at its earliest ready-at.
function Cooldowns.Group(list, now)
  now = now or time()
  local out = {}
  for _, r in ipairs(list) do
    local at = type(r.at) == "number" and r.at or 0
    local g
    if IsTransmuteName(r.name) or (KNOWN[r.recipeID] and r.recipeID ~= MOONCLOTH) then
      local ready = at <= now
      for _, o in ipairs(out) do
        if o.transmute and o.key == r.key and (o.at <= now) == ready and (ready or abs(o.at - at) <= TOGETHER) then
          g = o
          break
        end
      end
      if g then
        g.ids[#g.ids + 1] = r.recipeID
        g.name = TransmutePrefix()
        if at < g.at then g.at = at end
      else
        out[#out + 1] = { key = r.key, name = r.name, at = at, ids = { r.recipeID }, transmute = true }
      end
    else
      out[#out + 1] = { key = r.key, name = r.name, at = at, ids = { r.recipeID } }
    end
  end
  return out
end

-- For the hello: { [recipeID] = seconds until ready } for the current character, at most n
-- groups: every recipe of a group goes out (peers show each transmute's state), but a group
-- counts once, so shared transmutes don't crowd out other cooldowns.
-- An empty table (not nil) when there is nothing to report, so peers clear what they had.
function Cooldowns.ForHello(n)
  local c = MyChar()
  if not c then return nil end
  if type(c.cd) ~= "table" then return {} end
  local now, list = time(), {}
  for id, at in pairs(c.cd) do
    if type(id) == "number" and type(at) == "number" then
      list[#list + 1] = { key = NS.Me, recipeID = id, name = RecipeName(c, id), at = at }
    end
  end
  table.sort(list, function(a, b)
    if a.at ~= b.at then return a.at < b.at end
    return a.recipeID < b.recipeID
  end)
  local out, count = {}, 0
  for i, g in ipairs(Cooldowns.Group(list, now)) do
    if i > n then break end
    for _, id in ipairs(g.ids) do
      out[id] = max(0, c.cd[id] - now)
      count = count + 1
    end
  end
  return out
end

-- Seconds until the crafter's cooldown for recipeID is ready (0 = ready), or nil when unknown
-- (not a cooldown craft, or a peer on an older version).
function Cooldowns.Remaining(name, recipeID)
  local db = type(CraftBoardDB) == "table" and CraftBoardDB
  local c = db and type(db.chars) == "table" and db.chars[name]
  local cd
  if type(c) == "table" then
    cd = c.cd
  elseif NS.Comm and NS.Comm.PeerCooldowns then
    cd = NS.Comm.PeerCooldowns(name)
  else
    local p = db and type(db.peers) == "table" and db.peers[name]
    cd = type(p) == "table" and p.cd
  end
  local at = type(cd) == "table" and cd[recipeID]
  if type(at) ~= "number" then return nil end
  return max(0, at - time())
end

-- "ready" / "4h" / "2d" for a remaining time.
function Cooldowns.Text(left)
  if not left then return nil end
  if left <= 0 then return L["ready"] end
  if left < 3600 then return format(L["%dm"], max(1, floor(left / 60))) end
  if left < 2 * 86400 then return format(L["%dh"], floor(left / 3600)) end
  return format(L["%dd"], floor(left / 86400))
end

-- Every cooldown on my characters (onlyReady: the ones that have run out): { {key=, recipeID=,
-- name=, at=}, ... }, sorted by character then recipe name. at is 0 when the ready time isn't
-- known.
local function Collect(onlyReady)
  local db = type(CraftBoardDB) == "table" and CraftBoardDB
  local chars = db and type(db.chars) == "table" and db.chars or {}
  local out, now = {}, time()
  for key, c in pairs(chars) do
    if type(c) == "table" and type(c.cd) == "table" then
      for id, at in pairs(c.cd) do
        if type(at) == "number" and (not onlyReady or at <= now) then
          out[#out + 1] = { key = key, recipeID = id, name = RecipeName(c, id), at = at }
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.key ~= b.key then return a.key < b.key end
    return tostring(a.name) < tostring(b.name)
  end)
  return out
end

-- /cb cd: every cooldown craft on my characters, one line per group.
function Cooldowns.Print()
  local now, any = time(), false
  for _, g in ipairs(Cooldowns.Group(Collect(false), now)) do
    any = true
    NS.Print(format(L["%s: %s \226\128\148 %s"], NS.ShortName(g.key), tostring(g.name), Cooldowns.Text(max(0, g.at - now))))
  end
  if not any then NS.Print(L["No crafting cooldowns recorded. Open the profession window once."]) end
end

-- Ready notice ----------------------------------------------------------------------

-- Cooldowns on my characters that have run out: { {key=, recipeID=, name=, at=}, ... }, sorted
-- by character then recipe name. at is 0 when the ready time isn't known.
function Cooldowns.Ready()
  return Collect(true)
end

-- The same, grouped (Cooldowns.Group): { {key=, name=, at=, ids=}, ... }.
function Cooldowns.ReadyGroups()
  return Cooldowns.Group(Collect(true))
end

local function NoticeOn()
  return not (type(CraftBoardDB) == "table" and CraftBoardDB.cooldownNotice == false)
end

-- Cooldowns that ran out since they were last announced; each is marked as announced.
local function Unannounced()
  local out = {}
  if not (type(CraftBoardDB) == "table" and type(CraftBoardDB.chars) == "table") then return out end
  for _, r in ipairs(Cooldowns.Ready()) do
    local c = CraftBoardDB.chars[r.key]
    if r.at > 0 then
      c.cdSeen = type(c.cdSeen) == "table" and c.cdSeen or {}
      if c.cdSeen[r.recipeID] ~= r.at then
        c.cdSeen[r.recipeID] = r.at
        out[#out + 1] = r
      end
    end
  end
  -- Forget announcements for cooldowns that are gone or running again.
  for _, c in pairs(CraftBoardDB.chars) do
    if type(c) == "table" and type(c.cdSeen) == "table" then
      for id, at in pairs(c.cdSeen) do
        if type(c.cd) ~= "table" or c.cd[id] ~= at then c.cdSeen[id] = nil end
      end
    end
  end
  return out
end

local loggedIn = false   -- updates before the login line don't announce one by one

-- combined: one "Ready: ..." line when several groups ran out at once (after login).
function Cooldowns.Notice(combined)
  if not (loggedIn and NoticeOn()) then return end
  local groups = Cooldowns.Group(Unannounced())
  if #groups == 0 then return end
  if combined and #groups > 1 then
    local parts = {}
    for i, g in ipairs(groups) do parts[i] = tostring(g.name) .. " (" .. NS.ShortName(g.key) .. ")" end
    NS.Print(format(L["Ready: %s"], table.concat(parts, ", ")))
    return
  end
  for _, g in ipairs(groups) do
    NS.Print(format(L["%s is ready on %s."], tostring(g.name), NS.ShortName(g.key)))
  end
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

-- The profession window fires TRADE_SKILL_LIST_UPDATE in bursts: one read a second after the
-- last of them starts.
local tradePending = false
local function TradeSkillSoon()
  if tradePending then return end
  tradePending = true
  C_Timer.After(1, function()
    tradePending = false
    Cooldowns.FromTradeSkill()
  end)
end

NS.Register("PLAYER_LOGIN", function()
  Soon(5)
  -- Cooldowns that ran out while I was offline: one line once login chatter has settled, then
  -- every minute (a cooldown needs no event to run out).
  C_Timer.After(8, function()
    loggedIn = true
    Cooldowns.Notice(true)
    if C_Timer.NewTicker then C_Timer.NewTicker(60, function() Cooldowns.Notice(false) end) end
  end)
end)
if NS.RegisterCallback then
  NS.RegisterCallback(Cooldowns, "COOLDOWNS_UPDATED", function() Cooldowns.Notice(false) end)
  NS.RegisterCallback(Cooldowns, "RECIPES_UPDATED", function() mineDirty = true end)
end
-- Fires constantly in combat and for every spell: only read when I have a cooldown craft, and
-- once combat is over.
NS.Register("SPELL_UPDATE_COOLDOWN", function()
  local set = MySet()
  if not (set and next(set) ~= nil) then return end
  if InCombat() then
    skipped = true
    return
  end
  Soon(2)
end)
NS.Register("PLAYER_REGEN_ENABLED", function()
  if skipped then
    skipped = false
    Soon(2)
  end
end)
NS.Register("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
  if issecretvalue and (issecretvalue(unit) or issecretvalue(spellID)) then return end
  if unit ~= "player" or type(spellID) ~= "number" then return end
  local set = MySet()
  if set and set[spellID] then Soon(1) end
end)
NS.Register("TRADE_SKILL_LIST_UPDATE", TradeSkillSoon)
