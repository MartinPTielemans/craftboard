-- CraftBoard Skills: my current character's profession ranks without opening the profession
-- window, trainer reminders, and what the trainer has left to teach. Ranks are read from the
-- profession book (GetProfessions / GetProfessionInfo) on login, SKILL_LINES_CHANGED and skill-up
-- chat lines, into CraftBoardDB.chars[Me].profs[profID] = { name, rank, max } (positional, like
-- Recipes.Scan; .icon local). A primary profession that has left the book (unlearned) keeps its
-- entry with .gone = true and loses its recipes; Cooking, First Aid and Fishing are never
-- dropped (the book may leave them out).
-- Classic ranks (RANKS): Apprentice 75, Journeyman 150, Expert 225, Artisan 300; the next one can
-- be learned 25 points before the cap and from a character level. Primary professions train
-- every rank; the secondary ones learn Expert from a book and Artisan from a quest (at 225).
-- One quiet chat line per character, profession and rank (CraftBoardDB.chars[Me].trainSeen
-- [profID] = tier, or -tier once the level-gated line was said).
-- Trainer window (TRAINER_SHOW / TRAINER_UPDATE): chars[Me].trainer[profID] = { t=, available=
-- (recipes I can learn there now), next= (the lowest skill that unlocks more), said= (the next
-- already announced) }; one line once my rank reaches next. Only what the trainer's filter shows
-- is counted. Option CraftBoardDB.trainerNotice (default on) for all of these lines.
local ADDON, NS = ...

local Skills = {}
NS.Skills = Skills

local L = NS.L
local format = string.format

-- The rank a cap leads to: tier, title, the skill and character level it needs, and where it
-- is learned (trainer / book / quest).
local RANKS = {
  primary = {
    [75] = { tier = 2, title = "Journeyman", at = 50, level = 10, source = "trainer" },
    [150] = { tier = 3, title = "Expert", at = 125, level = 20, source = "trainer" },
    [225] = { tier = 4, title = "Artisan", at = 200, level = 35, source = "trainer" },
  },
  secondary = {
    [75] = { tier = 2, title = "Journeyman", at = 50, level = 10, source = "trainer" },
    [150] = { tier = 3, title = "Expert", at = 125, level = 20, source = "book" },
    [225] = { tier = 4, title = "Artisan", at = 225, level = 35, source = "quest" },
  },
}
local TITLE = { Journeyman = L["Journeyman"], Expert = L["Expert"], Artisan = L["Artisan"] }
local SECONDARY = { [185] = true, [129] = true, [356] = true }   -- Cooking, First Aid, Fishing
-- Classic primary professions' skill lines: Alchemy, Blacksmithing, Enchanting, Engineering,
-- Herbalism, Leatherworking, Mining, Skinning, Tailoring. Only these (and ones the book listed
-- in a primary slot this session) are dropped when they leave the book: a crafting window the
-- book never lists (Poisons) is not a profession that was unlearned.
local PRIMARY = { [171] = true, [164] = true, [333] = true, [202] = true, [182] = true,
  [165] = true, [186] = true, [393] = true, [197] = true }

-- Reminder lines by where the rank is learned; arguments are the rank title, then the
-- profession ("Expert", "Cooking"). Translations may reorder them with positional arguments
-- (%2$s ... %1$s).
local READY_TEXT = {
  trainer = L["You can train %s %s at a trainer now."],
  book = L["You can learn %s %s from a book now."],
  quest = L["You can do the %s %s quest now."],
}
local LEVEL_TEXT = {
  trainer = L["At level %d you can train %s %s."],
  book = L["At level %d you can learn %s %s from a book."],
  quest = L["At level %d you can do the %s %s quest."],
}

-- This session only (not saved).
local startRank = {}   -- [profID] = rank at the first book read (Skills.SessionGain)
local slotKind = {}    -- [profID] = "primary" / "secondary": the book slot it was read from
local suspect = {}     -- [profID] = true: a primary missing from the last complete book read
local Soon             -- (Events, below)

local function MyChar()
  local db = type(CraftBoardDB) == "table" and CraftBoardDB
  local c = db and NS.Me and type(db.chars) == "table" and db.chars[NS.Me]
  return type(c) == "table" and c or nil
end

-- My current character's record of a profession, or nil (unknown or unlearned).
local function Entry(profID)
  local c = MyChar()
  local e = c and type(c.profs) == "table" and c.profs[profID]
  if type(e) ~= "table" or e.gone then return nil end
  return e
end

local function PlayerLevel()
  if not UnitLevel then return nil end
  local ok, lvl = pcall(UnitLevel, "player")
  if ok and type(lvl) == "number" and not (issecretvalue and issecretvalue(lvl)) then return lvl end
  return nil
end

local function IsSecret(v)
  return issecretvalue and issecretvalue(v) and true or false
end

local function IsSecondary(profID)
  return SECONDARY[profID] or slotKind[profID] == "secondary" or false
end

-- Profession book: list of { profID=, name=, rank=, max=, icon=, primary= }, or nil when the
-- client can't tell (no API, or nothing returned at all). Second value: every slot GetProfessions
-- returned was read (the list can be trusted to be complete). GetProfessions' first two slots
-- are the primary professions.
local loginAt                    -- GetTime() at PLAYER_LOGIN
NS.Register("PLAYER_LOGIN", function() loginAt = GetTime and GetTime() or nil end)

local function ReadBook()
  if not (GetProfessions and GetProfessionInfo) then return nil end
  local ok, a, b, c, d, e, f = pcall(GetProfessions)
  if not ok then return nil end
  local slots = { a, b, c, d, e, f }
  local out, any, complete = {}, false, true
  for slot = 1, 6 do
    local index = slots[slot]
    if IsSecret(index) then
      complete = false
    elseif type(index) == "number" then
      any = true
      local ok2, name, icon, rank, max, _, _, skillLine = pcall(GetProfessionInfo, index)
      if ok2 and type(name) == "string" and name ~= "" and type(skillLine) == "number" and skillLine > 0
        and type(rank) == "number" and type(max) == "number"
        and not (IsSecret(name) or IsSecret(rank) or IsSecret(max) or IsSecret(skillLine)) then
        out[#out + 1] = { profID = skillLine, name = name, rank = rank, max = max, icon = icon, primary = slot <= 2 }
      else
        complete = false
      end
    elseif index ~= nil then
      complete = false
    end
  end
  -- No slot at all: nothing learned, or a book still loading at login. Past the first half
  -- minute it is a real (and complete) answer, so unlearning the last profession is noticed;
  -- Update's second read a few seconds later still has to agree before anything is dropped.
  if not any then
    if not (GetTime and loginAt and GetTime() - loginAt > 30) then
      -- Asked again once the half minute is over: a character whose last profession was dropped
      -- while CraftBoard was off would otherwise keep it (every login reads this early).
      if Soon and GetTime and loginAt then Soon(31 - (GetTime() - loginAt)) end
      return nil
    end
    return out, true
  end
  return out, complete
end

-- Primary professions on record that a complete book read did not list: present[key] for the
-- entries it matched, names[name] for every name it had.
local function Missing(c, present, names)
  local out = {}
  for key, e in pairs(c.profs) do
    if type(e) == "table" and not e.gone and not present[key] and not IsSecondary(key)
      and not (type(e[1]) == "string" and names[e[1]])
      and (PRIMARY[key] or slotKind[key] == "primary") then
      out[#out + 1] = key
    end
  end
  return out
end

-- An unlearned profession: marked gone, its recipes and trainer notes dropped.
local function Drop(c, key)
  c.profs[key].gone = true
  if type(c.recipes) == "table" then
    for id, rec in pairs(c.recipes) do
      if type(rec) == "table" and rec.p == key then c.recipes[id] = nil end
    end
  end
  if type(c.trainer) == "table" then c.trainer[key] = nil end
  if type(c.trainSeen) == "table" then c.trainSeen[key] = nil end
  -- Its cooldowns (and their notices) go with its recipes.
  local cdGone = false
  for _, t in ipairs({ c.cd, c.cdSeen }) do
    if type(t) == "table" then
      for id in pairs(t) do
        if not (type(c.recipes) == "table" and c.recipes[id]) then t[id], cdGone = nil, true end
      end
    end
  end
  if cdGone then NS.Fire("COOLDOWNS_UPDATED") end
end

-- Store the book's ranks on my character. Returns true when a rank or cap changed, or an
-- unlearned profession was dropped (then SKILLS_UPDATED and RECIPES_UPDATED fire; peers get
-- the new ranks with the next hello).
function Skills.Update()
  local c = MyChar()
  if not c then return false end
  local book, complete = ReadBook()
  if not book then return false end
  c.profs = type(c.profs) == "table" and c.profs or {}
  local changed, present, names = false, {}, {}
  for _, p in ipairs(book) do
    local key = p.profID
    -- A profession recorded under another key with the same name (a client whose profession
    -- window uses different IDs) is updated there instead of being listed twice.
    if c.profs[key] == nil then
      for k, v in pairs(c.profs) do
        if type(v) == "table" and v[1] == p.name then key = k break end
      end
    end
    local e = c.profs[key]
    if type(e) ~= "table" then
      e = { p.name }
      c.profs[key] = e
    end
    if e[2] ~= p.rank or e[3] ~= p.max then
      e[2], e[3], changed = p.rank, p.max, true
    end
    if e.gone then e.gone, changed = nil, true end   -- learned again
    -- The book's name wins: the client's language may have changed since it was stored.
    if e[1] ~= p.name then e[1], changed = p.name, true end
    if e.icon == nil and p.icon then e.icon = p.icon end
    present[key], names[p.name] = true, true
    slotKind[key] = p.primary and "primary" or "secondary"
    if startRank[key] == nil then startRank[key] = p.rank end
  end

  -- Unlearned primaries: only from complete reads, and only once a second complete read a few
  -- seconds later still misses them (a book that is still filling in at login drops nothing).
  local dropped = false
  if complete then
    local again = {}
    for _, key in ipairs(Missing(c, present, names)) do
      if suspect[key] then
        Drop(c, key)
        dropped = true
      else
        again[key] = true
      end
    end
    suspect = again
    if next(again) ~= nil and Soon then Soon(5) end
  end

  if changed or dropped then
    NS.Fire("SKILLS_UPDATED")
    NS.Fire("RECIPES_UPDATED")
  end
  return changed or dropped
end

-- The next rank of one of my current character's professions: { title=, at=, level=, tier=,
-- source= ("trainer" / "book" / "quest"), ready=, skillOk=, levelOk= } (ready: skill and level
-- are both there), or nil at Artisan or when the cap isn't a Classic one.
function Skills.NextRank(profID)
  local e = Entry(profID)
  if not e or type(e[2]) ~= "number" or type(e[3]) ~= "number" then return nil end
  local n = RANKS[IsSecondary(profID) and "secondary" or "primary"][e[3]]
  if not n then return nil end
  local lvl = PlayerLevel()
  local levelOk = not lvl or lvl >= n.level
  local skillOk = e[2] >= n.at
  return { title = TITLE[n.title], at = n.at, level = n.level, tier = n.tier, source = n.source,
    ready = skillOk and levelOk, skillOk = skillOk, levelOk = levelOk }
end

-- The next skill that matters for a profession: where the next rank can be learned, else the
-- cap; nil at the cap (or unknown).
function Skills.Milestone(profID)
  local e = Entry(profID)
  if not e or type(e[2]) ~= "number" or type(e[3]) ~= "number" then return nil end
  local n = Skills.NextRank(profID)
  if n and e[2] < n.at then return n.at end
  if e[2] < e[3] then return e[3] end
  return nil
end

-- At the cap of a rank that isn't the last one (no skill-ups until the next rank is learned).
function Skills.AtCap(profID)
  local e = Entry(profID)
  if not e or type(e[2]) ~= "number" or type(e[3]) ~= "number" then return false end
  return e[2] >= e[3] and e[3] < 300
end

-- Skill gained in a profession since the first read this session (0 when none), or nil.
function Skills.SessionGain(profID)
  local e = Entry(profID)
  local start = startRank[profID]
  if not e or type(e[2]) ~= "number" or type(start) ~= "number" then return nil end
  return math.max(0, e[2] - start)
end

-- What the profession's trainer had for me at the last visit: { t=, available=, next= }, or nil.
function Skills.Trainer(profID)
  local c = MyChar()
  local t = c and type(c.trainer) == "table" and c.trainer[profID]
  if type(t) ~= "table" or not Entry(profID) then return nil end
  return t
end

-- The reminder line for a rank that can be learned now (NextRank(profID).ready).
function Skills.ReadyText(name, n)
  return format(READY_TEXT[n.source] or READY_TEXT.trainer, n.title, name)
end

-- My current character's professions: { {profID=, name=, rank=, max=, icon=}, ... } by name.
-- Unlearned ones are left out.
function Skills.Ranks()
  local c = MyChar()
  local out = {}
  for id, e in pairs(c and type(c.profs) == "table" and c.profs or {}) do
    if type(e) == "table" and type(e[1]) == "string" and not e.gone then
      out[#out + 1] = { profID = id, name = e[1], rank = e[2], max = e[3], icon = e.icon }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- Specializations ---------------------------------------------------------------
-- Classic specializations by spell ID (the spell the specialization teaches) and the profession
-- they belong to. Names come from the client (localized); the English ones are a fallback.
Skills.SPECS = {
  [10656] = { prof = 165, name = "Dragonscale Leatherworking" },
  [10658] = { prof = 165, name = "Elemental Leatherworking" },
  [10660] = { prof = 165, name = "Tribal Leatherworking" },
  [20219] = { prof = 202, name = "Gnomish Engineer" },
  [20222] = { prof = 202, name = "Goblin Engineer" },
  [9788] = { prof = 164, name = "Armorsmith" },
  [9787] = { prof = 164, name = "Weaponsmith" },
  [17039] = { prof = 164, name = "Master Swordsmith" },
  [17040] = { prof = 164, name = "Master Hammersmith" },
  [17041] = { prof = 164, name = "Master Axesmith" },
}

local function Knows(spellID)
  for _, fn in ipairs({ IsPlayerSpell, IsSpellKnown }) do
    if type(fn) == "function" then
      local ok, yes = pcall(fn, spellID)
      if ok and yes and not IsSecret(yes) then return true end
    end
  end
  return false
end

function Skills.SpecName(spellID)
  local name
  if C_Spell and C_Spell.GetSpellName then
    local ok, n = pcall(C_Spell.GetSpellName, spellID)
    if ok and type(n) == "string" and not IsSecret(n) then name = n end
  end
  local s = Skills.SPECS[spellID]
  return name or (s and s.name) or tostring(spellID)
end

-- My current character's specializations: chars[Me].specs = { [spellID] = true } (nil: none),
-- read from the spellbook. Fires SKILLS_UPDATED on a change.
function Skills.ReadSpecs()
  local c = MyChar()
  if not c then return end
  local found, n = {}, 0
  for id in pairs(Skills.SPECS) do
    if Knows(id) then found[id], n = true, n + 1 end
  end
  local old = type(c.specs) == "table" and c.specs or {}
  local changed = false
  for id in pairs(Skills.SPECS) do
    if (old[id] or false) ~= (found[id] or false) then changed = true end
  end
  c.specs = n > 0 and found or nil
  if changed then NS.Fire("SKILLS_UPDATED") end
end

-- Spell IDs of a set of specializations ({ [spellID] = true }), sorted.
function Skills.SpecList(set)
  local out = {}
  for id in pairs(type(set) == "table" and set or {}) do
    if Skills.SPECS[id] then out[#out + 1] = id end
  end
  table.sort(out)
  return out
end

-- "Dragonscale Leatherworking" for profID among set, or nil.
-- A master smith also knows Weaponsmith: the master specialization (the higher spell ID) wins.
function Skills.SpecFor(set, profID)
  local best
  for _, id in ipairs(Skills.SpecList(set)) do
    if Skills.SPECS[id].prof == profID then best = id end
  end
  return best and Skills.SpecName(best) or nil
end

-- Trainer reminders ------------------------------------------------------------

local function NoticeOn()
  return not (type(CraftBoardDB) == "table" and CraftBoardDB.trainerNotice == false)
end

function Skills.Remind()
  local c = MyChar()
  if not (c and NoticeOn()) then return end
  c.trainSeen = type(c.trainSeen) == "table" and c.trainSeen or {}
  for _, p in ipairs(Skills.Ranks()) do
    local said = false
    local n = Skills.NextRank(p.profID)
    if n and n.skillOk then
      local seen = c.trainSeen[p.profID]
      if n.ready and seen ~= n.tier then
        c.trainSeen[p.profID] = n.tier
        NS.Print(Skills.ReadyText(p.name, n))
        said = true
      elseif not n.levelOk and seen ~= n.tier and seen ~= -n.tier then
        c.trainSeen[p.profID] = -n.tier
        NS.Print(format(LEVEL_TEXT[n.source] or LEVEL_TEXT.trainer, n.level, n.title, p.name))
        said = true
      end
    end
    -- Recipes the trainer wanted more skill for: once per threshold, and not on top of a rank
    -- line for the same profession (that one sends me to the trainer already).
    local t = type(c.trainer) == "table" and c.trainer[p.profID]
    if type(t) == "table" and type(t.next) == "number" and type(p.rank) == "number"
      and p.rank >= t.next and t.said ~= t.next then
      t.said = t.next
      if not said then NS.Print(format(L["New recipes to learn at your %s trainer."], p.name)) end
    end
  end
end

-- Trainer window ----------------------------------------------------------------
-- Services of a profession trainer, matched to my professions by the skill they require:
-- how many I can learn now, and the lowest skill an unavailable one asks for.

local function ReadTrainer()
  local c = MyChar()
  if not (c and type(c.profs) == "table" and GetNumTrainerServices and GetTrainerServiceInfo
    and GetTrainerServiceSkillReq) then return end
  if IsTradeskillTrainer then
    local ok, yes = pcall(IsTradeskillTrainer)
    if ok and not yes then return end
  end
  local ok, count = pcall(GetNumTrainerServices)
  if not ok or type(count) ~= "number" or IsSecret(count) or count <= 0 then return end
  local byName = {}
  for key, e in pairs(c.profs) do
    if type(e) == "table" and type(e[1]) == "string" and not e.gone then byName[e[1]] = key end
  end
  local found, listed = {}, {}
  for i = 1, math.min(count, 500) do
    local okI, _, _, category = pcall(GetTrainerServiceInfo, i)
    local okR, skill, need, hasReq = pcall(GetTrainerServiceSkillReq, i)
    local key = okI and okR and type(skill) == "string" and not IsSecret(skill) and byName[skill]
    if key then listed[key] = true end
    if key and (category == "available" or category == "unavailable") then
      local f = found[key] or { available = 0 }
      found[key] = f
      local rank = c.profs[key][2]
      if category == "available" then
        f.available = f.available + 1
      elseif type(need) == "number" and not IsSecret(need) and not hasReq
        and (type(rank) ~= "number" or need > rank) and (not f.next or need < f.next) then
        f.next = need
      end
    end
  end
  -- A profession this trainer teaches with every service already learned: nothing is waiting,
  -- so its old snapshot (and "new recipes" reminder) goes.
  for key in pairs(listed) do
    if not found[key] then found[key] = { available = 0 } end
  end
  if next(found) == nil then return end
  c.trainer = type(c.trainer) == "table" and c.trainer or {}
  for key, f in pairs(found) do
    local old = c.trainer[key]
    c.trainer[key] = { t = time(), available = f.available, next = f.next,
      said = type(old) == "table" and old.said or nil }
  end
  NS.Fire("SKILLS_UPDATED")
end

-- Events --------------------------------------------------------------------------

local pending = false
function Soon(delay)
  if pending then return end
  pending = true
  C_Timer.After(delay or 2, function()
    pending = false
    Skills.Update()
    Skills.Remind()
  end)
end

local trainerPending = false
local function TrainerSoon()
  if trainerPending then return end
  trainerPending = true
  C_Timer.After(0.5, function()
    trainerPending = false
    ReadTrainer()
  end)
end

NS.Register("PLAYER_LOGIN", function()
  Soon(6)
  C_Timer.After(7, Skills.ReadSpecs)
end)
-- SPELLS_CHANGED comes in bursts: one read after it settles.
local specsPending = false
local function SpecsSoon()
  if specsPending then return end
  specsPending = true
  C_Timer.After(2, function()
    specsPending = false
    Skills.ReadSpecs()
  end)
end
pcall(NS.Register, "LEARNED_SPELL_IN_TAB", SpecsSoon)
pcall(NS.Register, "SPELLS_CHANGED", SpecsSoon)
NS.Register("SKILL_LINES_CHANGED", function() Soon(2) end)
NS.Register("CHAT_MSG_SKILL", function() Soon(2) end)
NS.Register("PLAYER_LEVEL_UP", function() Soon(2) end)
NS.Register("TRAINER_SHOW", TrainerSoon)
-- After learning there (and filter changes); a client without the event just reads on show.
pcall(NS.Register, "TRAINER_UPDATE", TrainerSoon)
