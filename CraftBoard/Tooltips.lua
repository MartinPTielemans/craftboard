-- CraftBoard Tooltips: in a party or raid, item tooltips name the group members (CraftBoard
-- users) who can craft that item, and a group member's unit tooltip lists their professions.
-- Option "groupTooltips" (default on). A reagent's tooltip also says how many of my recipes use
-- it, what my queue needs of it and which of my other characters hold it (option
-- "reagentTooltips"), and a recipe item (Pattern:, Plans:, ...) says which of my other characters
-- know it, can learn it, or still need skill for it (option "recipeTooltips"). Only GameTooltip
-- and ItemRefTooltip get lines (not comparison, embedded or scanning tooltips). Post-hooks only
-- (TooltipDataProcessor, else OnTooltipSetItem / OnTooltipSetUnit); nothing on Blizzard's
-- tooltips is replaced.
local ADDON, NS = ...

local Tooltips = {}
NS.Tooltips = Tooltips

local L = NS.L
local format = string.format
local LINE_RGB = { 0.25, 0.8, 1 }

local byItem, byPeer = nil, nil   -- [itemID] = { "Bob", ... }; [group member full name] = peer

local function On()
  return not (type(CraftBoardDB) == "table" and CraftBoardDB.groupTooltips == false)
end

-- The peer record of a group member: its own key first, else any key naming the same player.
local function PeerOf(peers, full)
  local p = peers[full]
  if type(p) == "table" then return p end
  for name, q in pairs(peers) do
    if type(q) == "table" and NS.SamePlayer(name, full) then return q end
  end
  return nil
end

local function Rebuild()
  byItem, byPeer = {}, {}
  local members = NS.GroupMembers and NS.GroupMembers() or {}
  if #members == 0 then return end
  local peers = NS.Comm and NS.Comm.Peers and NS.Comm.Peers() or {}
  local cat = type(CraftBoardDB) == "table" and type(CraftBoardDB.recipeNames) == "table" and CraftBoardDB.recipeNames or {}
  for _, m in ipairs(members) do
    local p = PeerOf(peers, m)
    if p then
      byPeer[m] = p
      local short = NS.ShortName(m)
      for id in pairs(type(p.recipes) == "table" and p.recipes or {}) do
        local e = cat[id]
        local out = type(e) == "table" and e.o
        if type(out) == "number" then
          local list = byItem[out] or {}
          byItem[out] = list
          if list[#list] ~= short then list[#list + 1] = short end
        end
      end
    end
  end
end

local function Dirty() byItem, byPeer = nil, nil end

local function AddItemLine(tt, itemID)
  if not (On() and tt and tt.AddLine and type(itemID) == "number") then return end
  if not (IsInGroup and IsInGroup()) then return end
  if not byItem then Rebuild() end
  local list = byItem[itemID]
  if not list or #list == 0 then return end
  tt:AddLine(format(L["Group crafters: %s"], table.concat(list, ", ")), LINE_RGB[1], LINE_RGB[2], LINE_RGB[3], true)
end

local function AddUnitLine(tt, unit)
  if not (On() and tt and tt.AddLine and unit and UnitName and UnitIsPlayer and UnitIsPlayer(unit)) then return end
  if not ((UnitInParty and UnitInParty(unit)) or (UnitInRaid and UnitInRaid(unit))) then return end
  if not byPeer then Rebuild() end
  local full = NS.UnitFullName(unit)
  if not full then return end
  local p = PeerOf(byPeer, full)
  if not p then return end
  local parts = {}
  for _, pr in pairs(type(p.profs) == "table" and p.profs or {}) do
    if type(pr) == "table" and type(pr.name) == "string" then
      parts[#parts + 1] = pr.rank and format("%s %d", pr.name, pr.rank) or pr.name
    end
  end
  if #parts == 0 then return end
  table.sort(parts)
  tt:AddLine(format(L["Professions: %s"], table.concat(parts, ", ")), LINE_RGB[1], LINE_RGB[2], LINE_RGB[3], true)
end

-- My own characters ------------------------------------------------------------
-- Everything below reads CraftBoardDB.chars only (my characters on this account), never peers.

local GREEN = { 0.25, 1, 0.25 }
local GREY = { 0.6, 0.6, 0.6 }
local ORANGE = { 1, 0.6, 0.2 }
local WHITE = { 1, 1, 1 }
local MAX_ALTS = 4        -- alt rows before "and N more"
local MAX_NAMES = 4       -- names on one recipe line before "and N more"

local function OptionOn(key)
  return not (type(CraftBoardDB) == "table" and CraftBoardDB[key] == false)
end

local function Chars()
  return type(CraftBoardDB) == "table" and type(CraftBoardDB.chars) == "table" and CraftBoardDB.chars or {}
end

local function Plain(s)
  if type(s) ~= "string" or (issecretvalue and issecretvalue(s)) then return nil end
  return NS.StripCodes(s)
end

local function Line(out, text, rgb)
  out[#out + 1] = { text = text, r = rgb[1], g = rgb[2], b = rgb[3] }
end

-- "A, B, C, D, and 2 more".
local function Names(list)
  local shown = {}
  for i = 1, math.min(MAX_NAMES, #list) do shown[i] = list[i] end
  if #list > MAX_NAMES then shown[#shown + 1] = format(L["and %d more"], #list - MAX_NAMES) end
  return table.concat(shown, ", ")
end

local function ClassRGB(class)
  local colors = type(class) == "string" and RAID_CLASS_COLORS
  local c = type(colors) == "table" and colors[class]
  if type(c) == "table" and type(c.r) == "number" and type(c.g) == "number" and type(c.b) == "number" then
    return { c.r, c.g, c.b }
  end
  return WHITE
end

-- [itemID] = number of distinct recipes (over all my characters) with it in a reagent slot.
local usedIn = nil

local function BuildUsedIn()
  local seen = {}   -- [itemID] = { [recipeID] = true }
  for _, c in pairs(Chars()) do
    for recipeID, rec in pairs(type(c) == "table" and type(c.recipes) == "table" and c.recipes or {}) do
      for _, reg in ipairs(type(rec) == "table" and type(rec.r) == "table" and rec.r or {}) do
        if type(reg) == "table" then
          -- reg.alts: the slot's other quality tiers (saved recipe data), not alt characters.
          local ids = { reg[1] }
          for _, id in ipairs(type(reg.alts) == "table" and reg.alts or {}) do ids[#ids + 1] = id end
          for _, id in ipairs(ids) do
            if type(id) == "number" then
              seen[id] = seen[id] or {}
              seen[id][recipeID] = true
            end
          end
        end
      end
    end
  end
  usedIn = {}
  for id, set in pairs(seen) do
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    usedIn[id] = n
  end
end

-- Queue totals, cached until the queue, the bags or the recipes change.
local queueRows = nil

-- The queue's reagent rows that take itemID (its own, or one of the quality tiers in row.alts):
-- one row usually, several when slots accept overlapping tiers.
local function QueueRows(itemID)
  if not queueRows then
    queueRows = NS.Queue and NS.Queue.Totals and NS.Queue.Totals() or {}
  end
  local out = {}
  for _, row in ipairs(queueRows) do
    local takes = row.itemID == itemID
    for _, id in ipairs(not takes and type(row.alts) == "table" and row.alts or {}) do
      if id == itemID then takes = true break end
    end
    if takes then out[#out + 1] = row end
  end
  return out
end

local function ReagentLines(itemID, out)
  if not usedIn then BuildUsedIn() end
  local n = usedIn[itemID]
  if n and n > 0 then Line(out, format(L["Used in %d of your recipes"], n), LINE_RGB) end
  local rows = QueueRows(itemID)
  if #rows == 1 and (rows[1].need or 0) > 0 then
    local have = rows[1].have or 0
    Line(out, format(L["Your queue needs %d (you have %d)"], rows[1].need, have), have >= rows[1].need and GREEN or ORANGE)
  elseif #rows > 1 then
    -- Several slots take it: what they need together, and what they were given (green only when
    -- every one of them is covered).
    local need, have = 0, 0
    for _, r in ipairs(rows) do
      need, have = need + (r.need or 0), have + math.min(r.have or 0, r.need or 0)
    end
    if need > 0 then Line(out, format(L["Your queue needs %d (you have %d)"], need, have), have >= need and GREEN or ORANGE) end
  end
  local Inv = NS.Inventory
  if not (Inv and Inv.AltCounts and Inv.IsReagentLike and Inv.IsReagentLike(itemID)) then return end
  -- Queued reagent slots that take several quality tiers: alts' holdings of any of them, as the
  -- queue line above counts.
  local tiers, seenID = {}, { [itemID] = true }
  local function tier(id)
    if type(id) == "number" and not seenID[id] then tiers[#tiers + 1], seenID[id] = id, true end
  end
  for _, r in ipairs(rows) do
    tier(r.itemID)
    for _, id in ipairs(type(r.alts) == "table" and r.alts or {}) do tier(id) end
  end
  local total, list = Inv.AltCounts(itemID, tiers)
  if total <= 0 then return end
  Line(out, format(L["+%d on alts"], total), LINE_RGB)
  for i = 1, math.min(MAX_ALTS, #list) do
    local rgb = ClassRGB(list[i].class)
    out[#out + 1] = { text = "  " .. NS.ShortName(list[i].name), r = rgb[1], g = rgb[2], b = rgb[3],
      right = tostring(list[i].n), rr = WHITE[1], rg = WHITE[2], rb = WHITE[3] }
  end
  if #list > MAX_ALTS then Line(out, "  " .. format(L["and %d more"], #list - MAX_ALTS), GREY) end
end

-- Recipe items -----------------------------------------------------------------

local function IsRecipeItem(itemID)
  local recipeClass = Enum and Enum.ItemClass and Enum.ItemClass.Recipe
  if type(recipeClass) ~= "number" then recipeClass = 9 end
  local class = NS.Inventory and NS.Inventory.ItemClass and NS.Inventory.ItemClass(itemID)
  return class == recipeClass
end

-- A client format string ("Requires %s (%d)", also "%1$s") as an anchored Lua pattern; the
-- second return lists which capture holds which argument (positional formats may reorder).
local function FormatToPattern(fmt)
  if type(fmt) ~= "string" or fmt == "" then return nil end
  local out, order, i, arg = { "^" }, {}, 1, 0
  while i <= #fmt do
    local c = fmt:sub(i, i)
    if c == "%" then
      local pos, kind, stop = fmt:match("^%%(%d*)%$?([sd])()", i)
      if kind then
        arg = arg + 1
        order[#order + 1] = tonumber(pos) or arg
        out[#out + 1] = kind == "s" and "(.+)" or "(%d+)"
        i = stop
      elseif fmt:sub(i + 1, i + 1) == "%" then
        out[#out + 1] = "%%"
        i = i + 2
      else
        return nil
      end
    else
      out[#out + 1] = c:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0")
      i = i + 1
    end
  end
  out[#out + 1] = "$"
  return table.concat(out), order
end

local minSkillPattern, minSkillOrder = nil, nil
local repPattern, levelPattern, reqPattern, usePrefix = nil, nil, nil, nil

-- A tooltip line's left text: a data line ({leftText=}, or older clients' unsurfaced
-- {args={ {field=, stringVal=} }}) or a plain string.
local function LeftText(line)
  if type(line) ~= "table" then return Plain(line) end
  if line.leftText ~= nil then return Plain(line.leftText) end
  for _, a in ipairs(type(line.args) == "table" and line.args or {}) do
    if type(a) == "table" and a.field == "leftText" then return Plain(a.stringVal) end
  end
  return nil
end

-- "Requires Leatherworking (100)" among the tooltip's lines -> "Leatherworking", 100.
-- lines: tooltip data lines ({leftText=}) or plain strings.
local function RequiredSkill(lines)
  if minSkillPattern == nil then
    minSkillPattern, minSkillOrder = FormatToPattern(ITEM_MIN_SKILL or "Requires %s (%d)")
    minSkillPattern = minSkillPattern or false
  end
  if not minSkillPattern or type(lines) ~= "table" then return nil end
  for _, line in ipairs(lines) do
    local text = LeftText(line)
    if text then
      local a, b = text:match(minSkillPattern)
      if a then
        local args = {}
        args[minSkillOrder[1] or 1], args[minSkillOrder[2] or 2] = a, b
        local rank = tonumber(args[2])
        if args[1] and rank then return args[1], rank end
      end
    end
  end
  return nil
end

-- A recipe item's own requirements, beyond its profession skill, read from the lines before its
-- "Use: Teaches you ..." (the crafted item's tooltip follows, with that item's requirements):
-- { level = 40 (or nil), rep = true (or nil), other = { "Gnomish Engineer", ... } }.
local function OtherRequirements(lines)
  if repPattern == nil then
    repPattern = type(ITEM_REQ_REPUTATION) == "string" and FormatToPattern(ITEM_REQ_REPUTATION) or false
    levelPattern = FormatToPattern(type(ITEM_MIN_LEVEL) == "string" and ITEM_MIN_LEVEL or "Requires Level %d") or false
    reqPattern = FormatToPattern(type(ITEM_REQ_SKILL) == "string" and ITEM_REQ_SKILL or "Requires %s") or false
    usePrefix = type(ITEM_SPELL_TRIGGER_ONUSE) == "string" and ITEM_SPELL_TRIGGER_ONUSE or "Use:"
  end
  local out = { other = {} }
  if type(lines) ~= "table" then return out end
  if minSkillPattern == nil then RequiredSkill(nil) end
  for i, line in ipairs(lines) do
    local text = LeftText(line)
    if text and i > 1 then
      if text:sub(1, #usePrefix) == usePrefix then break end
      if minSkillPattern and text:match(minSkillPattern) then
        -- the profession skill: checked per character
      elseif repPattern and text:match(repPattern) then
        out.rep = true
      elseif levelPattern and text:match(levelPattern) then
        out.level = out.level or tonumber(text:match(levelPattern))
      elseif reqPattern then
        local what = text:match(reqPattern)
        if what then out.other[#out.other + 1] = what end
      end
    end
  end
  return out
end

-- Names compared loosely: lower case, punctuation dropped, spaces collapsed, so a recipe item's
-- "Transmute Arcanite" (from "Recipe: Transmute Arcanite") matches the spell "Transmute: Arcanite".
local function Norm(s)
  if type(s) ~= "string" or (issecretvalue and issecretvalue(s)) then return nil end
  s = s:lower():gsub("%p", " "):gsub("%s+", " ")
  s = s:match("^%s*(.-)%s*$")
  return s ~= "" and s or nil
end

-- [normalized recipe or output item name] / [recipeID] = { [charKey] = true } over my characters.
local knownBy, knownByID = nil, nil

local function BuildKnownBy()
  knownBy, knownByID = {}, {}
  local itemName = NS.Inventory and NS.Inventory.ItemName
  local function note(map, k, key)
    if k == nil then return end
    map[k] = map[k] or {}
    map[k][key] = true
  end
  for key, c in pairs(Chars()) do
    for recipeID, rec in pairs(type(c) == "table" and type(c.recipes) == "table" and c.recipes or {}) do
      if type(rec) == "table" then
        note(knownByID, recipeID, key)
        note(knownBy, Norm(rec.n), key)
        note(knownBy, Norm(type(rec.o) == "number" and itemName and itemName(rec.o) or nil), key)
      end
    end
  end
end

-- The spell a recipe item teaches, when the client names it: name, spellID.
local function ItemSpell(itemID)
  local get = (C_Item and C_Item.GetItemSpell) or GetItemSpell
  if not get then return nil end
  local ok, name, spellID = pcall(get, itemID)
  if not ok or (issecretvalue and (issecretvalue(name) or issecretvalue(spellID))) then return nil end
  return type(name) == "string" and name or nil, type(spellID) == "number" and spellID or nil
end

local function ProfRank(c, profName)
  local want = profName:lower()
  for _, pr in pairs(type(c) == "table" and type(c.profs) == "table" and c.profs or {}) do
    if type(pr) == "table" and not pr.gone and type(pr[1]) == "string" and pr[1]:lower() == want then
      return tonumber(pr[2]) or 0
    end
  end
  return nil
end

-- Up to three lines over my other reachable characters (Blizzard already tells the current one
-- "Already known" or its requirement): Known by (grey), Can learn (green), Needs more skill (orange).
local function RecipeLines(itemID, lines, out)
  local name = NS.Inventory and NS.Inventory.ItemName and NS.Inventory.ItemName(itemID)
  if not name and type(lines) == "table" and lines[1] then
    name = LeftText(lines[1])
  end
  local spellName, spellID = ItemSpell(itemID)
  local taught = type(name) == "string" and name:match("^.-:%s*(.+)$")
  if not (spellName or spellID or taught) then return end
  if not knownBy then BuildKnownBy() end
  local known = {}
  local function merge(set)
    for key in pairs(set or {}) do known[key] = true end
  end
  if spellID then merge(knownByID[spellID]) end
  local k1, k2 = Norm(spellName), Norm(taught)
  if k1 then merge(knownBy[k1]) end
  if k2 then merge(knownBy[k2]) end
  local profName, required = RequiredSkill(lines)
  local reqs = profName and OtherRequirements(lines) or { other = {} }
  local reachable = NS.Inventory and NS.Inventory.Reachable
  local knownList, learn, short, low = {}, {}, {}, {}
  local levelUnknown = false
  for key, c in pairs(Chars()) do
    if key ~= NS.Me and type(c) == "table" and (not reachable or reachable(key, c)) then
      local who = NS.ShortName(key)
      if known[key] then
        knownList[#knownList + 1] = who
      elseif profName then
        local rank = ProfRank(c, profName)
        local level = tonumber(c.level)
        if rank and rank >= required and reqs.level and level and level < reqs.level then
          low[#low + 1] = who
        elseif rank and rank >= required then
          learn[#learn + 1] = who
          if reqs.level and not level then levelUnknown = true end
        elseif rank then
          short[#short + 1] = { name = who, rank = rank }
        end
      end
    end
  end
  table.sort(knownList)
  table.sort(learn)
  table.sort(low)
  table.sort(short, function(a, b)
    if a.rank ~= b.rank then return a.rank > b.rank end
    return a.name < b.name
  end)
  if #knownList > 0 then Line(out, format(L["Known by: %s"], Names(knownList)), GREY) end
  if #learn > 0 then
    -- What the saved data can't tell for an alt (reputation, a specialization, a level not yet
    -- recorded) is named rather than assumed.
    local needs = {}
    for _, what in ipairs(reqs.other) do needs[#needs + 1] = what end
    if reqs.rep then needs[#needs + 1] = L["reputation"] end
    if levelUnknown then needs[#needs + 1] = format(L["level %d"], reqs.level) end
    if #needs > 0 then
      Line(out, format(L["Can learn: %s (needs %s)"], Names(learn), table.concat(needs, ", ")), GREEN)
    else
      Line(out, format(L["Can learn: %s"], Names(learn)), GREEN)
    end
  end
  if #low > 0 then Line(out, format(L["Needs level %d: %s"], reqs.level, Names(low)), ORANGE) end
  if #short > 0 then
    local parts = {}
    for i, s in ipairs(short) do parts[i] = format("%s (%d/%d)", s.name, s.rank, required) end
    Line(out, format(L["Needs more skill: %s"], Names(parts)), ORANGE)
  end
end

-- Lines to add to an item tooltip: { {text=, r=, g=, b=, right=?, rr=, rg=, rb=}, ... } (possibly
-- empty; right= makes a double line). lines: the tooltip's own text (data lines or strings), used
-- to read a recipe item's skill and reputation requirements. A recipe item's lines come first.
function Tooltips.ItemLines(itemID, lines)
  local out = {}
  if type(itemID) ~= "number" then return out end
  if OptionOn("recipeTooltips") and IsRecipeItem(itemID) then RecipeLines(itemID, lines, out) end
  if OptionOn("reagentTooltips") then ReagentLines(itemID, out) end
  return out
end

-- Left-hand text of a tooltip without data lines (OnTooltipSetItem fallback).
local function TextLines(tt)
  local out = {}
  local name = tt and tt.GetName and tt:GetName()
  if not (name and tt.NumLines) then return out end
  for i = 1, tt:NumLines() or 0 do
    local fs = _G[name .. "TextLeft" .. i]
    local text = fs and fs.GetText and fs:GetText()
    if type(text) == "string" and not (issecretvalue and issecretvalue(text)) then out[#out + 1] = text end
  end
  return out
end

local function AddMyLines(tt, itemID, lines)
  if not (tt and tt.AddLine and type(itemID) == "number") then return end
  local ok, add = pcall(Tooltips.ItemLines, itemID, lines)
  if not ok then return end
  for _, l in ipairs(add) do
    if l.right and tt.AddDoubleLine then
      tt:AddDoubleLine(l.text, l.right, l.r, l.g, l.b, l.rr, l.rg, l.rb)
    else
      tt:AddLine(l.text, l.r, l.g, l.b, true)
    end
  end
end

-- Only the tooltips a player reads: the mouseover one and a clicked link's. Comparison
-- (ShoppingTooltip1/2), embedded and other addons' scanning tooltips are different frames.
local function Mine(tt)
  return tt ~= nil and ((GameTooltip and tt == GameTooltip) or (ItemRefTooltip and tt == ItemRefTooltip)) or false
end

local function MineDirty() usedIn, knownBy, knownByID, queueRows = nil, nil, nil, nil end
local function QueueDirty() queueRows = nil end
Tooltips.FormatToPattern = FormatToPattern
Tooltips.OtherRequirements = OtherRequirements

local hooked = false
local function Hook()
  if hooked then return end
  hooked = true
  local TDP = TooltipDataProcessor
  local T = Enum and Enum.TooltipDataType
  if TDP and TDP.AddTooltipPostCall and T and T.Item then
    TDP.AddTooltipPostCall(T.Item, function(tt, data)
      if not Mine(tt) then return end
      if type(data) == "table" and (not issecretvalue or not issecretvalue(data.id)) then
        AddItemLine(tt, data.id)
        AddMyLines(tt, data.id, data.lines)
      end
    end)
    if T.Unit then
      TDP.AddTooltipPostCall(T.Unit, function(tt)
        if tt ~= GameTooltip or not tt.GetUnit then return end
        local ok, _, unit = pcall(tt.GetUnit, tt)
        if ok and (not issecretvalue or not issecretvalue(unit)) then AddUnitLine(tt, unit) end
      end)
    end
    return
  end
  local function OnItem(tt)
    local ok, _, link = pcall(tt.GetItem, tt)
    if not ok or (issecretvalue and issecretvalue(link)) then return end
    local itemID = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
    AddItemLine(tt, itemID)
    AddMyLines(tt, itemID, TextLines(tt))
  end
  for _, tt in ipairs({ GameTooltip or false, ItemRefTooltip or false }) do
    if tt and tt.HookScript then pcall(tt.HookScript, tt, "OnTooltipSetItem", OnItem) end
  end
  if GameTooltip and GameTooltip.HookScript then
    pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit", function(tt)
      local ok, _, unit = pcall(tt.GetUnit, tt)
      if ok and (not issecretvalue or not issecretvalue(unit)) then AddUnitLine(tt, unit) end
    end)
  end
end

NS.Register("PLAYER_LOGIN", Hook)
NS.Register("GROUP_ROSTER_UPDATE", Dirty)
if NS.RegisterCallback then
  NS.RegisterCallback(Tooltips, "PEERS_UPDATED", Dirty)
  NS.RegisterCallback(Tooltips, "IGNORE_UPDATED", Dirty)
  NS.RegisterCallback(Tooltips, "RECIPES_UPDATED", MineDirty)
  NS.RegisterCallback(Tooltips, "ITEM_NAMES_UPDATED", function() knownBy, knownByID = nil, nil end)
  NS.RegisterCallback(Tooltips, "QUEUE_UPDATED", QueueDirty)
  NS.RegisterCallback(Tooltips, "INVENTORY_UPDATED", QueueDirty)
end
