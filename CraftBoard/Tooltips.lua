-- CraftBoard Tooltips: in a party or raid, item tooltips name the group members (CraftBoard
-- users) who can craft that item, and a group member's unit tooltip lists their professions.
-- Option "groupTooltips" (default on). Post-hooks only (TooltipDataProcessor, else
-- OnTooltipSetItem / OnTooltipSetUnit); nothing on Blizzard's tooltips is replaced.
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
  local name, realm = UnitName(unit)
  local full = NS.FullName(name, realm)
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

local hooked = false
local function Hook()
  if hooked then return end
  hooked = true
  local TDP = TooltipDataProcessor
  local T = Enum and Enum.TooltipDataType
  if TDP and TDP.AddTooltipPostCall and T and T.Item then
    TDP.AddTooltipPostCall(T.Item, function(tt, data)
      if type(data) == "table" and (not issecretvalue or not issecretvalue(data.id)) then AddItemLine(tt, data.id) end
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
      AddItemLine(tt, type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil)
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
end
