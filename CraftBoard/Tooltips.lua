-- CraftBoard Tooltips: in a party or raid, item tooltips name the group members (CraftBoard
-- users) who can craft that item, and a group member's unit tooltip lists their professions.
-- Option "groupTooltips" (default on). Any item tooltip also says how many of my recipes use
-- it as a reagent, what my queue needs of it and which alts hold it (option "reagentTooltips"),
-- and a recipe item (Pattern:, Plans:, ...) says which of my characters know it, can learn it,
-- or still need skill for it (option "recipeTooltips"). Post-hooks only (TooltipDataProcessor,
-- else OnTooltipSetItem / OnTooltipSetUnit); nothing on Blizzard's tooltips is replaced.
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

local function Rebuild()
  byItem, byPeer = {}, {}
  local members = NS.GroupMembers and NS.GroupMembers() or {}
  if #members == 0 then return end
  local peers = NS.Comm and NS.Comm.Peers and NS.Comm.Peers() or {}
  local cat = type(CraftBoardDB) == "table" and type(CraftBoardDB.recipeNames) == "table" and CraftBoardDB.recipeNames or {}
  for _, m in ipairs(members) do
    for name, p in pairs(peers) do
      if NS.SamePlayer(name, m) then
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
        break
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
  local p
  for key, peer in pairs(byPeer) do
    if NS.SamePlayer(key, full) then p = peer break end
  end
  if not p then return end
  local parts = {}
  for _, pr in pairs(type(p.profs) == "table" and p.profs or {}) do
    if type(pr) == "table" and type(pr.name) == "string" then
      parts[#parts + 1] = pr.rank and format("%s %d", pr.name, pr.rank) or pr.name
    end
  end
  if #parts == 0 then return end
  table.sort(parts)
  tt:AddLine(format(L["CraftBoard: %s"], table.concat(parts, ", ")), LINE_RGB[1], LINE_RGB[2], LINE_RGB[3], true)
end

-- My own characters ------------------------------------------------------------
-- Everything below reads CraftBoardDB.chars only (my characters on this account), never peers.

local GREEN = { 0.25, 1, 0.25 }
local GREY = { 0.6, 0.6, 0.6 }
local MAX_RECIPE_LINES = 5

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

-- [itemID] = number of distinct recipes (over all my characters) with it in a reagent slot.
local usedIn = nil

local function BuildUsedIn()
  local seen = {}   -- [itemID] = { [recipeID] = true }
  for _, c in pairs(Chars()) do
    for recipeID, rec in pairs(type(c) == "table" and type(c.recipes) == "table" and c.recipes or {}) do
      for _, reg in ipairs(type(rec) == "table" and type(rec.r) == "table" and rec.r or {}) do
        if type(reg) == "table" then
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

local function QueueRow(itemID)
  if not queueRows then
    queueRows = NS.Queue and NS.Queue.Totals and NS.Queue.Totals() or {}
  end
  for _, row in ipairs(queueRows) do
    if row.itemID == itemID then return row end
    for _, id in ipairs(type(row.alts) == "table" and row.alts or {}) do
      if id == itemID then return row end
    end
  end
  return nil
end

local function ReagentLines(itemID, out)
  if not usedIn then BuildUsedIn() end
  local n = usedIn[itemID]
  if n and n > 0 then
    out[#out + 1] = { text = format(L["Used in %d of your recipes"], n), r = LINE_RGB[1], g = LINE_RGB[2], b = LINE_RGB[3] }
  end
  local row = QueueRow(itemID)
  if row and (row.need or 0) > 0 then
    out[#out + 1] = { text = format(L["Your queue needs %d (you have %d)"], row.need, row.have or 0),
      r = LINE_RGB[1], g = LINE_RGB[2], b = LINE_RGB[3] }
  end
  local total, list = 0, {}
  if NS.Inventory and NS.Inventory.AltCounts then total, list = NS.Inventory.AltCounts(itemID) end
  if total > 0 then
    local parts = {}
    for i = 1, math.min(3, #list) do parts[#parts + 1] = format("%s %d", NS.ShortName(list[i].name), list[i].n) end
    out[#out + 1] = { text = format(L["On alts: %s"], table.concat(parts, ", ")), r = LINE_RGB[1], g = LINE_RGB[2], b = LINE_RGB[3] }
  end
end

-- Recipe items -----------------------------------------------------------------

local function IsRecipeItem(itemID)
  local classID
  if C_Item and C_Item.GetItemInfoInstant then
    local ok, _, _, _, _, _, c = pcall(C_Item.GetItemInfoInstant, itemID)
    if ok then classID = c end
  elseif GetItemInfoInstant then
    local ok, _, _, _, _, _, c = pcall(GetItemInfoInstant, itemID)
    if ok then classID = c end
  end
  if classID == nil then
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if getInfo then
      local ok, _, _, _, _, _, _, _, _, _, _, _, c = pcall(getInfo, itemID)
      if ok then classID = c end
    end
  end
  local recipeClass = Enum and Enum.ItemClass and Enum.ItemClass.Recipe or 9
  return classID == recipeClass
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

-- [lower-case recipe or output item name] = { [charKey] = true } over my characters.
local knownBy = nil

local function BuildKnownBy()
  knownBy = {}
  local itemName = NS.Inventory and NS.Inventory.ItemName
  for key, c in pairs(Chars()) do
    for _, rec in pairs(type(c) == "table" and type(c.recipes) == "table" and c.recipes or {}) do
      if type(rec) == "table" then
        local names = { rec.n, type(rec.o) == "number" and itemName and itemName(rec.o) or nil }
        for i = 1, 2 do
          local n = names[i]
          if type(n) == "string" and n ~= "" then
            n = n:lower()
            knownBy[n] = knownBy[n] or {}
            knownBy[n][key] = true
          end
        end
      end
    end
  end
end

local function ProfRank(c, profName)
  local want = profName:lower()
  for _, pr in pairs(type(c) == "table" and type(c.profs) == "table" and c.profs or {}) do
    if type(pr) == "table" and type(pr[1]) == "string" and pr[1]:lower() == want then
      return tonumber(pr[2]) or 0
    end
  end
  return nil
end

local function RecipeLines(itemID, lines, out)
  if not IsRecipeItem(itemID) then return end
  local name = NS.Inventory and NS.Inventory.ItemName and NS.Inventory.ItemName(itemID)
  if not name and type(lines) == "table" and lines[1] then
    name = LeftText(lines[1])
  end
  local taught = type(name) == "string" and name:match("^.-:%s*(.+)$")
  if not taught then return end
  taught = taught:lower()
  if not knownBy then BuildKnownBy() end
  local known = knownBy[taught] or {}
  local profName, required = RequiredSkill(lines)
  local rows = {}
  for key, c in pairs(Chars()) do
    local short = NS.ShortName(key)
    if known[key] then
      rows[#rows + 1] = { order = 1, name = short, text = format(L["Known by %s"], short), rgb = GREEN }
    elseif profName then
      local rank = ProfRank(c, profName)
      if rank and rank >= required then
        rows[#rows + 1] = { order = 2, name = short, text = format(L["Learnable by %s"], short), rgb = GREEN }
      elseif rank then
        rows[#rows + 1] = { order = 3, name = short, text = format(L["%s needs %d"], short, required), rgb = GREY }
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.name < b.name
  end)
  for i = 1, math.min(MAX_RECIPE_LINES, #rows) do
    local r = rows[i]
    out[#out + 1] = { text = r.text, r = r.rgb[1], g = r.rgb[2], b = r.rgb[3] }
  end
end

-- Lines to add to an item tooltip: { {text=, r=, g=, b=}, ... } (possibly empty). lines: the
-- tooltip's own text (data lines or strings), used to read a recipe item's skill requirement.
function Tooltips.ItemLines(itemID, lines)
  local out = {}
  if type(itemID) ~= "number" then return out end
  if OptionOn("reagentTooltips") then ReagentLines(itemID, out) end
  if OptionOn("recipeTooltips") then RecipeLines(itemID, lines, out) end
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
  for _, l in ipairs(add) do tt:AddLine(l.text, l.r, l.g, l.b, true) end
end

local function MineDirty() usedIn, knownBy, queueRows = nil, nil, nil end
local function QueueDirty() queueRows = nil end
Tooltips.FormatToPattern = FormatToPattern

local hooked = false
local function Hook()
  if hooked then return end
  hooked = true
  local TDP = TooltipDataProcessor
  local T = Enum and Enum.TooltipDataType
  if TDP and TDP.AddTooltipPostCall and T and T.Item then
    TDP.AddTooltipPostCall(T.Item, function(tt, data)
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
  if GameTooltip and GameTooltip.HookScript then
    pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetItem", function(tt)
      local _, link = tt:GetItem()
      local itemID = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
      AddItemLine(tt, itemID)
      AddMyLines(tt, itemID, TextLines(tt))
    end)
    pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit", function(tt)
      local _, unit = tt:GetUnit()
      AddUnitLine(tt, unit)
    end)
  end
end

NS.Register("PLAYER_LOGIN", Hook)
NS.Register("GROUP_ROSTER_UPDATE", Dirty)
if NS.RegisterCallback then
  NS.RegisterCallback(Tooltips, "PEERS_UPDATED", Dirty)
  NS.RegisterCallback(Tooltips, "IGNORE_UPDATED", Dirty)
  NS.RegisterCallback(Tooltips, "RECIPES_UPDATED", MineDirty)
  NS.RegisterCallback(Tooltips, "ITEM_NAMES_UPDATED", function() knownBy = nil end)
  NS.RegisterCallback(Tooltips, "QUEUE_UPDATED", QueueDirty)
  NS.RegisterCallback(Tooltips, "INVENTORY_UPDATED", QueueDirty)
end
