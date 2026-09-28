-- CraftBoard Skills: my current character's profession ranks without opening the profession
-- window, and trainer reminders. Ranks are read from the profession book (GetProfessions /
-- GetProfessionInfo) on login, SKILL_LINES_CHANGED and skill-up chat lines, into
-- CraftBoardDB.chars[Me].profs[profID] = { name, rank, max } (positional, like Recipes.Scan;
-- .icon local). Classic ranks: Apprentice 75, Journeyman 150, Expert 225, Artisan 300; the next
-- one can be learned 25 points before the cap, some only from a character level. One quiet chat
-- line per character, profession and rank (CraftBoardDB.chars[Me].trainSeen[profID] = tier, or
-- -tier once the level-gated line was said). Option CraftBoardDB.trainerNotice (default on).
local ADDON, NS = ...

local Skills = {}
NS.Skills = Skills

local L = NS.L
local format = string.format

-- The rank a cap leads to: title, the skill it can be learned at, the character level it needs.
-- Secondary professions (Cooking, First Aid, Fishing) use the same thresholds.
local NEXT = {
  [75] = { tier = 2, title = "Journeyman", at = 50, level = 10 },
  [150] = { tier = 3, title = "Expert", at = 125, level = 20 },
  [225] = { tier = 4, title = "Artisan", at = 200, level = 35 },
}
local TITLE = { Journeyman = L["Journeyman"], Expert = L["Expert"], Artisan = L["Artisan"] }

local function MyChar()
  local db = type(CraftBoardDB) == "table" and CraftBoardDB
  local c = db and NS.Me and type(db.chars) == "table" and db.chars[NS.Me]
  return type(c) == "table" and c or nil
end

local function PlayerLevel()
  if not UnitLevel then return nil end
  local ok, lvl = pcall(UnitLevel, "player")
  if ok and type(lvl) == "number" and not (issecretvalue and issecretvalue(lvl)) then return lvl end
  return nil
end

-- Profession book: list of { profID=, name=, rank=, max=, icon= }, or nil when the client can't
-- tell (no API, or nothing returned at all).
local function ReadBook()
  if not (GetProfessions and GetProfessionInfo) then return nil end
  local ok, a, b, c, d, e, f = pcall(GetProfessions)
  if not ok then return nil end
  local out, any = {}, false
  for _, index in pairs({ a, b, c, d, e, f }) do
    if type(index) == "number" then
      any = true
      local ok2, name, icon, rank, max, _, _, skillLine = pcall(GetProfessionInfo, index)
      if ok2 and type(name) == "string" and name ~= "" and type(skillLine) == "number" and skillLine > 0
        and type(rank) == "number" and type(max) == "number" then
        out[#out + 1] = { profID = skillLine, name = name, rank = rank, max = max, icon = icon }
      end
    end
  end
  return any and out or nil
end

-- Store the book's ranks on my character. Returns true when a rank or cap changed (then
-- SKILLS_UPDATED and RECIPES_UPDATED fire; peers get the new ranks with the next hello).
function Skills.Update()
  local c = MyChar()
  local book = c and ReadBook()
  if not book then return false end
  c.profs = type(c.profs) == "table" and c.profs or {}
  local changed = false
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
    if e[1] == nil then e[1] = p.name end
    if e.icon == nil and p.icon then e.icon = p.icon end
  end
  if changed then
    NS.Fire("SKILLS_UPDATED")
    NS.Fire("RECIPES_UPDATED")
  end
  return changed
end

-- The next rank of one of my current character's professions: { title=, at=, level=, ready= }
-- (ready: skill and level are both there), or nil at Artisan or when the cap isn't a Classic one.
function Skills.NextRank(profID)
  local c = MyChar()
  local e = c and type(c.profs) == "table" and c.profs[profID]
  if type(e) ~= "table" or type(e[2]) ~= "number" or type(e[3]) ~= "number" then return nil end
  local n = NEXT[e[3]]
  if not n then return nil end
  local lvl = PlayerLevel()
  local levelOk = not lvl or lvl >= n.level
  return { title = TITLE[n.title], at = n.at, level = n.level, tier = n.tier,
    ready = e[2] >= n.at and levelOk, levelOk = levelOk, skillOk = e[2] >= n.at }
end

-- My current character's professions: { {profID=, name=, rank=, max=, icon=}, ... } by name.
function Skills.Ranks()
  local c = MyChar()
  local out = {}
  for id, e in pairs(c and type(c.profs) == "table" and c.profs or {}) do
    if type(e) == "table" and type(e[1]) == "string" then
      out[#out + 1] = { profID = id, name = e[1], rank = e[2], max = e[3], icon = e.icon }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
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
    local n = Skills.NextRank(p.profID)
    if n and n.skillOk then
      local seen = c.trainSeen[p.profID]
      if n.ready and seen ~= n.tier then
        c.trainSeen[p.profID] = n.tier
        -- Cooking, First Aid and Fishing learn Expert and Artisan from a book or quest, not a trainer.
        local secondary = (p.profID == 185 or p.profID == 129 or p.profID == 356) and n.tier and n.tier >= 3
        NS.Print(format(secondary and L["You can learn %s %s now (from a book or quest)."]
          or L["You can train %s %s at a trainer now."], n.title, p.name))
      elseif not n.levelOk and seen ~= n.tier and seen ~= -n.tier then
        c.trainSeen[p.profID] = -n.tier
        NS.Print(format(L["At level %d you can train %s %s."], n.level, n.title, p.name))
      end
    end
  end
end

-- Events --------------------------------------------------------------------------

local pending = false
local function Soon(delay)
  if pending then return end
  pending = true
  C_Timer.After(delay or 2, function()
    pending = false
    Skills.Update()
    Skills.Remind()
  end)
end

NS.Register("PLAYER_LOGIN", function() Soon(6) end)
NS.Register("SKILL_LINES_CHANGED", function() Soon(2) end)
NS.Register("CHAT_MSG_SKILL", function() Soon(2) end)
NS.Register("PLAYER_LEVEL_UP", function() Soon(2) end)
