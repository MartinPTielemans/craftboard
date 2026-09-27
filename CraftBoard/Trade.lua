-- CraftBoard Trade: what happens in the trade window.
--  * "Crafted for you" counts, private: CraftBoardDB.crafted["Name-Realm"] = { m = trades where I
--    handed them something I craft (or enchanted their item), t = trades where they did that for
--    me, last = time }. Read from the trade window as it completes; never sent anywhere.
--  * A finished trade takes the delivered craft off my queue (Queue.Delivered).
--  * One-click enchant: when the trade partner asked for an enchant my current character knows
--    (a queued craft or a "Seen in chat" ask), a secure button under the trade window casts it
--    on the item in their "Will not be traded" slot. It is the player's click, like a macro:
--    nothing is cast on its own. Set up out of combat only.
local ADDON, NS = ...

local Trade = {}
NS.Trade = Trade

local L = NS.L
local format = string.format

local SLOTS = 6                    -- tradeable slots; 7 is "Will not be traded" (enchants)
local ENCHANT_SLOT = 7
local ENCHANT_TARGET = "TradeRecipientItem7ItemButton"

local partner                      -- "Name-Realm" while the trade window is open
local snap                         -- last read of both sides

local function ItemIDOf(link)
  return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

-- The enchantment string of a slot 7 info call; the return order differs between clients
-- (classic: name, texture, count, quality, enchantment; modern adds isUsable before it).
local function EnchantOf(fn)
  if not fn then return nil end
  local r = { pcall(fn, ENCHANT_SLOT) }
  if not r[1] then return nil end
  for i = 6, #r do
    if type(r[i]) == "string" and r[i] ~= "" then return r[i] end
  end
  return nil
end

local function Count(fn, i)
  if not fn then return 1 end
  local ok, _, _, n = pcall(fn, i)
  return ok and type(n) == "number" and n > 0 and n or 1
end

local function Read()
  local s = { gave = {}, got = {} }
  for i = 1, SLOTS do
    local mine = GetTradePlayerItemLink and ItemIDOf(GetTradePlayerItemLink(i))
    if mine then s.gave[#s.gave + 1] = { item = mine, n = Count(GetTradePlayerItemInfo, i) } end
    local theirs = GetTradeTargetItemLink and ItemIDOf(GetTradeTargetItemLink(i))
    if theirs then s.got[#s.got + 1] = { item = theirs, n = Count(GetTradeTargetItemInfo, i) } end
  end
  s.enchantGiven = EnchantOf(GetTradeTargetItemInfo)     -- I enchant their item
  s.enchantGot = EnchantOf(GetTradePlayerItemInfo)       -- they enchant mine
  return s
end

-- My current character's enchant recipe by the name shown in the trade window.
local function MyEnchant(name)
  if type(name) ~= "string" then return nil end
  local lname = strlower(name)
  for id, rec in pairs(NS.Recipes and NS.Recipes.Mine and NS.Recipes.Mine() or {}) do
    local n = type(rec) == "table" and rec.e and type(rec.n) == "string" and strlower(rec.n)
    if n and (n == lname or n:find(lname, 1, true) or lname:find(n, 1, true)) then return id end
  end
  return nil
end

-- The peer (by stored key) knows a recipe making item.
local function PeerMakes(full, item)
  local peers = NS.Comm and NS.Comm.Peers and NS.Comm.Peers() or {}
  local cat = type(CraftBoardDB) == "table" and CraftBoardDB.recipeNames or {}
  for name, p in pairs(peers) do
    if NS.SamePlayer(name, full) and type(p.recipes) == "table" then
      for id in pairs(p.recipes) do
        local e = cat[id]
        if type(e) == "table" and e.o == item then return true end
      end
    end
  end
  return false
end

local function Crafted()
  if type(CraftBoardDB) ~= "table" then return nil end
  if type(CraftBoardDB.crafted) ~= "table" then CraftBoardDB.crafted = {} end
  return CraftBoardDB.crafted
end

local function Completed()
  local who, s = partner, snap
  if not (who and s) then return end
  local byMe, forMe = false, s.enchantGot ~= nil
  -- Only what this character crafts: handing over an item an alt could make isn't crafting.
  local mine = NS.Inventory and NS.Inventory.MyRecipeFor
  for _, g in ipairs(s.gave) do
    if mine and select(4, mine(g.item)) then
      byMe = true
      if NS.Queue then NS.Queue.Delivered(who, g.item, nil, g.n) end
    end
  end
  if s.enchantGiven then
    byMe = true
    local id = MyEnchant(s.enchantGiven)
    if id and NS.Queue then NS.Queue.Delivered(who, nil, id, 1) end
  end
  for _, g in ipairs(s.got) do
    if PeerMakes(who, g.item) then forMe = true end
  end
  if not (byMe or forMe) then return end
  local db = Crafted()
  if not db then return end
  local e = type(db[who]) == "table" and db[who] or {}
  db[who] = e
  if byMe then e.m = (e.m or 0) + 1 end
  if forMe then e.t = (e.t or 0) + 1 end
  e.last = time()
  NS.Fire("CRAFTED_UPDATED")
end

-- mine, theirs: trades where I crafted for them / they crafted for me.
function Trade.CraftedCounts(full)
  local db = Crafted()
  if not (db and type(full) == "string") then return 0, 0 end
  for name, e in pairs(db) do
    if type(e) == "table" and NS.SamePlayer(name, full) then return e.m or 0, e.t or 0 end
  end
  return 0, 0
end

-- "You crafted for Bob 3 times · Bob crafted for you once", or nil.
function Trade.CraftedText(full)
  local m, t = Trade.CraftedCounts(full)
  local who = NS.ShortName(full)
  local parts = {}
  if m > 0 then parts[#parts + 1] = format(m == 1 and L["You crafted for %s once"] or L["You crafted for %s %d times"], who, m) end
  if t > 0 then parts[#parts + 1] = format(t == 1 and L["%s crafted for you once"] or L["%s crafted for you %d times"], who, t) end
  if #parts == 0 then return nil end
  return table.concat(parts, " \194\183 ")
end

-- One-click enchant --------------------------------------------------------------

local button

-- Enchant recipe of my current character that the partner asked for: queued for them first,
-- then their "Seen in chat" ask. Returns recipeID, name.
-- Only when exactly one enchant is wanted: with two (say, two weapon enchants queued) the
-- button can't know which one this item is for, so it stays hidden rather than cast the wrong one.
local function WantedEnchant(who)
  local mine = NS.Recipes and NS.Recipes.Mine and NS.Recipes.Mine() or {}
  local found, name, n = nil, nil, 0
  local function take(id)
    local rec = id and mine[id]
    if rec and rec.e and id ~= found then
      found, name, n = id, rec.n, n + 1
    end
  end
  for _, x in ipairs(NS.Queue and NS.Queue.Entries() or {}) do
    if x.who and NS.SamePlayer(x.who, who) then take(x.recipeID) end
  end
  for _, s in ipairs(NS.ChatWatch and NS.ChatWatch.Seen() or {}) do
    if s.current and NS.SamePlayer(s.from, who) then take(s.recipeID) end
  end
  if n ~= 1 then return nil end
  return found, name
end

local function SpellName(recipeID, fallback)
  if C_Spell and C_Spell.GetSpellName then
    local ok, n = pcall(C_Spell.GetSpellName, recipeID)
    if ok and type(n) == "string" then return n end
  end
  if GetSpellInfo then
    local ok, n = pcall(GetSpellInfo, recipeID)
    if ok and type(n) == "string" then return n end
  end
  return fallback
end

local function Button()
  if button or not TradeFrame then return button end
  local ok, b = pcall(CreateFrame, "Button", "CraftBoardTradeEnchant", TradeFrame,
    "SecureActionButtonTemplate,UIPanelButtonTemplate")
  if not ok or not b then return nil end
  b:SetSize(220, 24)
  b:SetPoint("TOPLEFT", TradeFrame, "BOTTOMLEFT", 4, -2)
  b:RegisterForClicks("AnyUp", "AnyDown")
  b:SetAttribute("type", "macro")
  b:SetScript("OnEnter", function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText(self.cbName or L["Enchant"])
    GameTooltip:AddLine(L["Casts the enchant on the item in their \"Will not be traded\" slot. Both of you still accept the trade."], 1, 1, 1, true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  b:Hide()
  button = b
  return b
end

function Trade.UpdateButton()
  if InCombatLockdown and InCombatLockdown() then return end
  local b = Button()
  if not b then return end
  local id, name = nil, nil
  if partner and TradeFrame and TradeFrame:IsShown() then id, name = WantedEnchant(partner) end
  if not id then
    b:Hide()
    return
  end
  local spell = SpellName(id, name)
  local macro = "/cast " .. spell
  if _G[ENCHANT_TARGET] then macro = macro .. "\n/click " .. ENCHANT_TARGET end
  b:SetAttribute("macrotext", macro)
  b.cbName = spell
  b:SetText(format(L["Enchant: %s"], (spell:gsub("^Enchant%s+", ""))))
  b:Show()
end

-- Events --------------------------------------------------------------------------

local function PartnerName()
  return NS.UnitFullName("NPC")
end

NS.Register("TRADE_SHOW", function()
  partner, snap = PartnerName(), nil
  Trade.UpdateButton()
end)
for _, ev in ipairs({ "TRADE_PLAYER_ITEM_CHANGED", "TRADE_TARGET_ITEM_CHANGED", "TRADE_ACCEPT_UPDATE" }) do
  NS.Register(ev, function()
    if partner then snap = Read() end
  end)
end
NS.Register("UI_INFO_MESSAGE", function(_, ...)
  if not (ERR_TRADE_COMPLETE and partner) then return end
  for i = 1, select("#", ...) do
    if issecretvalue and issecretvalue((select(i, ...))) then return end
    if select(i, ...) == ERR_TRADE_COMPLETE then
      Completed()
      snap = nil
      return
    end
  end
end)
NS.Register("TRADE_CLOSED", function()
  C_Timer.After(0.5, function()
    partner, snap = nil, nil
    Trade.UpdateButton()
  end)
end)
if NS.RegisterCallback then
  for _, ev in ipairs({ "QUEUE_UPDATED", "CHAT_SEEN_UPDATED" }) do
    NS.RegisterCallback(Trade, ev, function() if partner then Trade.UpdateButton() end end)
  end
end
