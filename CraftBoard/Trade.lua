-- CraftBoard Trade: what happens in the trade window.
--  * "Crafted for you" counts, private: CraftBoardDB.crafted["Name-Realm"] = { m = trades where I
--    handed them a craft (one queued for them, or an item this character made in the last day)
--    or enchanted their item, t = trades where they did that for me, last = time }. Trades with
--    my own characters don't count. Read from the trade window as it completes (the read taken
--    when both sides accepted, else the last one); never sent anywhere.
--  * A finished trade takes the delivered craft off my queue (Queue.Delivered).
--  * One-click enchant: when the trade partner asked for an enchant my current character knows
--    (a queued craft or a "Seen in chat" ask), a secure button under the trade window casts it
--    on the item in their "Will not be traded" slot. It is the player's click, like a macro:
--    nothing is cast on its own. With my Enchanting window open the click crafts the recipe and
--    targets their slot; otherwise it runs "/cast" + "/click" on the slot. The button belongs to
--    UIParent at a spot read from the trade window when it opens (never anchored to it, so the
--    trade window stays an ordinary frame), and is set up, shown and hidden out of combat only.
local ADDON, NS = ...

local Trade = {}
NS.Trade = Trade

local L = NS.L
local format = string.format
local TSUI = C_TradeSkillUI

local SLOTS = 6                    -- tradeable slots; 7 is "Will not be traded" (enchants)
local ENCHANT_SLOT = 7
local ENCHANT_TARGET = "TradeRecipientItem7ItemButton"
local MIN_WIDTH, MAX_WIDTH = 120, 320

local session = 0                  -- counts trade windows, so a late timer can't clear a newer one
local partner                      -- "Name-Realm" while the trade window is open
local snap                         -- last read of both sides
local accepted                     -- the read taken when both sides had accepted
local pendingEnchant               -- recipeID the enchant button last cast in this trade

local function InCombat()
  return InCombatLockdown and InCombatLockdown() or false
end

local function Shown()
  return TradeFrame and TradeFrame.IsShown and TradeFrame:IsShown() or false
end

local function ItemIDOf(link)
  if type(link) ~= "string" or (issecretvalue and issecretvalue(link)) then return nil end
  return tonumber(link:match("item:(%d+)"))
end

local function SlotLink(fn, i)
  if not fn then return nil end
  local ok, link = pcall(fn, i)
  return ok and link or nil
end

-- The enchantment string of a slot 7 info call; the return order differs between clients
-- (classic: name, texture, count, quality, enchantment; modern adds isUsable before it).
local function EnchantOf(fn)
  if not fn then return nil end
  local r = { pcall(fn, ENCHANT_SLOT) }
  if not r[1] then return nil end
  for i = 6, #r do
    local v = r[i]
    if type(v) == "string" and not (issecretvalue and issecretvalue(v)) and v ~= "" then return v end
  end
  return nil
end

local function Count(fn, i)
  if not fn then return 1 end
  local ok, _, _, n = pcall(fn, i)
  return ok and type(n) == "number" and n > 0 and n or 1
end

-- Both sides of the open trade window (nil while it isn't shown: its slots read empty then).
local function Read()
  if not Shown() then return nil end
  local s = { gave = {}, got = {} }
  for i = 1, SLOTS do
    local mine = ItemIDOf(SlotLink(GetTradePlayerItemLink, i))
    if mine then s.gave[#s.gave + 1] = { item = mine, n = Count(GetTradePlayerItemInfo, i) } end
    local theirs = ItemIDOf(SlotLink(GetTradeTargetItemLink, i))
    if theirs then s.got[#s.got + 1] = { item = theirs, n = Count(GetTradeTargetItemInfo, i) } end
  end
  s.enchantGiven = EnchantOf(GetTradeTargetItemInfo)     -- I enchant their item
  s.enchantGot = EnchantOf(GetTradePlayerItemInfo)       -- they enchant mine
  return s
end

local function Mine()
  return NS.Recipes and NS.Recipes.Mine and NS.Recipes.Mine() or {}
end

-- My current character's enchant recipe by the name shown in the trade window: an exact name
-- first, then (unless exactOnly) one name containing the other.
local function MyEnchant(name, exactOnly)
  if type(name) ~= "string" then return nil end
  local lname = strlower(name)
  local loose
  for id, rec in pairs(Mine()) do
    local n = type(rec) == "table" and rec.e and type(rec.n) == "string" and strlower(rec.n)
    if n == lname then return id end
    if n and not loose and not exactOnly and (n:find(lname, 1, true) or lname:find(n, 1, true)) then loose = id end
  end
  return loose
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

-- I have a request of my own on the board for item.
local function IAsked(item)
  local posts = type(CraftBoardDB) == "table" and type(CraftBoardDB.posts) == "table" and CraftBoardDB.posts or {}
  for _, p in pairs(posts) do
    if type(p) == "table" and p.mine and p.item == item then return true end
  end
  return false
end

-- The trade partner is one of my own characters.
local function MyCharacter(full)
  return NS.MyCharKey and NS.MyCharKey(full) ~= nil or false
end

local function Crafted()
  if type(CraftBoardDB) ~= "table" then return nil end
  if type(CraftBoardDB.crafted) ~= "table" then CraftBoardDB.crafted = {} end
  return CraftBoardDB.crafted
end

-- Items my queue still holds for a player.
local function QueuedFor(who)
  local n = 0
  for _, x in ipairs(NS.Queue and NS.Queue.Entries and NS.Queue.Entries() or {}) do
    if x.who and NS.SamePlayer(x.who, who) then n = n + (tonumber(x.qty) or 0) end
  end
  return n
end

-- Queue.Delivered, and whether it matched a queued craft for them (their queue got shorter).
local function Deliver(who, item, recipeID, count)
  if not (NS.Queue and NS.Queue.Delivered) then return false end
  local before = QueuedFor(who)
  NS.Queue.Delivered(who, item, recipeID, count)
  return QueuedFor(who) < before
end

local function Completed()
  local who, s = partner, accepted or snap
  if not (who and s) then return end
  if MyCharacter(who) then return end
  local byMe, forMe = false, s.enchantGot ~= nil
  -- Handing over an item counts as crafting for them only when it was queued for them or made
  -- on this character lately (not just any item one of my characters could make).
  local madeRecently = NS.Craft and NS.Craft.MadeRecently
  for _, g in ipairs(s.gave) do
    local delivered = Deliver(who, g.item, nil, g.n)
    if delivered or (madeRecently and madeRecently(g.item)) then byMe = true end
  end
  if s.enchantGiven then
    byMe = true
    -- An exact name match wins; else the enchant the button cast; else a looser name match.
    local id = MyEnchant(s.enchantGiven, true) or pendingEnchant or MyEnchant(s.enchantGiven)
    if id then Deliver(who, nil, id, 1) end
  end
  -- Getting an item counts as them crafting for me only when I asked for it on the board and
  -- they make it (not any bar or potion a crafter hands over).
  for _, g in ipairs(s.got) do
    if IAsked(g.item) and PeerMakes(who, g.item) then forMe = true end
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
local tradeSkillOpen = false       -- a profession window is open (TRADE_SKILL_SHOW .. _CLOSE)

-- Enchant recipe of my current character that the partner asked for: queued for them first,
-- then their "Seen in chat" ask. Returns recipeID, name.
-- Only when exactly one enchant is wanted: with two (say, two weapon enchants queued) the
-- button can't know which one this item is for, so it stays hidden rather than cast the wrong one.
local function WantedEnchant(who)
  local mine = Mine()
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
    -- A line linking several items names no single enchant.
    if s.current and not s.links and NS.SamePlayer(s.from, who) then take(s.recipeID) end
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

local function SpellIcon(recipeID)
  if C_Spell and C_Spell.GetSpellTexture then
    local ok, t = pcall(C_Spell.GetSpellTexture, recipeID)
    if ok and (type(t) == "number" or type(t) == "string") then return t end
  end
  if GetSpellTexture then
    local ok, t = pcall(GetSpellTexture, recipeID)
    if ok and (type(t) == "number" or type(t) == "string") then return t end
  end
  return nil
end

local function Call(fn, ...)
  if not fn then return nil end
  local ok, v = pcall(fn, ...)
  return ok and v or nil
end

-- My Enchanting window is open and can craft rec right now: my own profession (not a linked,
-- guild or NPC view: Craft.OpenProfession checks those), ready, and the recipe's profession.
local function CraftWindowFor(rec)
  if not (tradeSkillOpen and TSUI and TSUI.CraftRecipe and type(rec) == "table" and rec.p) then return false end
  local open = NS.Craft and NS.Craft.OpenProfession and NS.Craft.OpenProfession()
  return open ~= nil and open == rec.p
end

-- Why the button is disabled, or nil when their slot 7 holds an item without an enchant yet.
-- The enchant's reagents in my bags (what the cast can use), or nil when unknown.
local function BagCheck(recipeID)
  local rec = recipeID and Mine()[recipeID]
  return rec and NS.Inventory and NS.Inventory.CanCraft and NS.Inventory.CanCraft(rec, nil, true) or nil
end

local function WaitReason(recipeID)
  if not ItemIDOf(SlotLink(GetTradeTargetItemLink, ENCHANT_SLOT)) then
    return L["Waiting for their item in \"Will not be traded\"."]
  end
  if EnchantOf(GetTradeTargetItemInfo) then return L["Enchant applied \226\128\148 accept the trade."] end
  -- The client refuses the cast without them: the button waits (the tooltip lists what's short).
  local cc = BagCheck(recipeID)
  if cc and not cc.ready then return L["Missing reagents in your bags."] end
  -- A rod or other tool the enchant needs (known while the Enchanting window is open).
  local tool = recipeID and NS.Craft and NS.Craft.MissingTool and NS.Craft.MissingTool(recipeID)
  if tool then return format(L["Requires %s."], tool) end
  return nil
end

local function ShowTooltip(self)
  if not GameTooltip then return end
  GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
  GameTooltip:SetText(self.cbName or L["Enchant"])
  if self.cbWhy then GameTooltip:AddLine(self.cbWhy, 1, 0.82, 0, true) end
  GameTooltip:AddLine(L["Casts the enchant on the item in their \"Will not be traded\" slot. Both of you still accept the trade."], 1, 1, 1, true)
  local cc = BagCheck(self.cbRecipe)
  if cc and #cc.missing > 0 then
    local parts = {}
    for _, r in ipairs(cc.missing) do
      local name = NS.Inventory.ItemName and NS.Inventory.ItemName(r.itemID) or (NS.ItemLabel and NS.ItemLabel(r.itemID)) or tostring(r.itemID)
      parts[#parts + 1] = format(L["%d/%d %s"], r.have, r.need, name)
    end
    GameTooltip:AddLine(L["Missing:"] .. " " .. table.concat(parts, ", "), 1, 0.3, 0.3, true)
  end
  if self.cbMode == "macro" then
    GameTooltip:AddLine(L["If nothing happens, open your Enchanting window and click again."], 0.6, 0.6, 0.6, true)
  end
  GameTooltip:Show()
end

-- Mouse clicks act on one edge only, so the cast can't run twice: key down when the client acts
-- on key down (ActionButtonUseKeyDown; a secure button registered for up only never fires there),
-- else key up.
local function RegisterClicks(b)
  local get = (C_CVar and C_CVar.GetCVarBool) or GetCVarBool
  local down = get and Call(get, "ActionButtonUseKeyDown") and true or false
  b:RegisterForClicks(down and "AnyDown" or "AnyUp")
end

-- How the click casts recipeID (out of combat only): with my Enchanting window open, no secure
-- action and the craft in PostClick; else a "/cast" macro that clicks their slot after.
local function SetMode(b, recipeID)
  local rec = Mine()[recipeID]
  b.cbRecipe = recipeID
  if CraftWindowFor(rec) then
    b:SetAttribute("type", nil)
    b:SetAttribute("macrotext", nil)
    b.cbMode = "craft"
    return true
  end
  local spell = SpellName(recipeID, rec and rec.n)
  if not spell then return false end
  local macro = "/cast " .. spell
  if _G[ENCHANT_TARGET] then macro = macro .. "\n/click " .. ENCHANT_TARGET end
  b:SetAttribute("type", "macro")
  b:SetAttribute("macrotext", macro)
  b.cbMode = "macro"
  return true
end

local function Button()
  if button then return button end
  if not (CreateFrame and UIParent and TradeFrame) then return nil end
  local ok, b = pcall(CreateFrame, "Button", "CraftBoardTradeEnchant", UIParent,
    "SecureActionButtonTemplate,UIPanelButtonTemplate")
  if not ok or not b then return nil end
  b:SetSize(MIN_WIDTH, 24)
  b:Hide()
  -- The tooltip says why while the button is disabled.
  if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
  b:SetScript("OnEnter", ShowTooltip)
  b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  b:SetScript("PreClick", function(self)
    -- The profession window may have opened or closed since the last update: pick the way now.
    if not InCombat() and self.cbRecipe then SetMode(self, self.cbRecipe) end
    pendingEnchant = self.cbRecipe
  end)
  b:SetScript("PostClick", function(self)
    if self.cbMode ~= "craft" or not (self.cbRecipe and TSUI and TSUI.CraftRecipe) then return end
    if not pcall(TSUI.CraftRecipe, self.cbRecipe, 1) then return end
    if SpellIsTargeting and Call(SpellIsTargeting) and ClickTargetTradeButton then
      pcall(ClickTargetTradeButton, ENCHANT_SLOT)
    end
  end)
  button = b
  return b
end

local function HideButton()
  if button and not InCombat() then button:Hide() end
end

-- Under the trade window's bottom left corner, in UIParent coordinates (the two may be scaled
-- differently). False when the trade window has no position yet.
local function Place(b)
  local left, bottom = Call(TradeFrame.GetLeft, TradeFrame), Call(TradeFrame.GetBottom, TradeFrame)
  if not (left and bottom) then return false end
  local scale = (Call(TradeFrame.GetEffectiveScale, TradeFrame) or 1) / (Call(b.GetEffectiveScale, b) or 1)
  b:ClearAllPoints()
  b:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * scale + 4, bottom * scale - 2)
  local strata = Call(TradeFrame.GetFrameStrata, TradeFrame)
  if strata then b:SetFrameStrata(strata) end
  return true
end

-- Label: the spell's own name with its icon; width from the text.
local function SetLabel(b, recipeID)
  local rec = Mine()[recipeID]
  local spell = SpellName(recipeID, rec and rec.n) or L["Enchant"]
  local icon = SpellIcon(recipeID)
  b.cbName = spell
  b:SetText(icon and format("|T%s:16:16:0:0|t %s", tostring(icon), spell) or spell)
  local fs = b.GetFontString and b:GetFontString()
  local w = fs and fs.GetStringWidth and tonumber(fs:GetStringWidth()) or 0
  b:SetWidth(math.min(MAX_WIDTH, math.max(MIN_WIDTH, w + 24)))
end

function Trade.UpdateButton()
  if InCombat() then return end
  local b = Button()
  if not b then return end
  local id = nil
  if partner and Shown() then id = WantedEnchant(partner) end
  if not id or not Place(b) or not SetMode(b, id) then
    b:Hide()
    return
  end
  RegisterClicks(b)
  SetLabel(b, id)
  local why = WaitReason(id)
  b.cbWhy = why
  b:SetEnabled(why == nil)
  b:Show()
  if GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(b) then ShowTooltip(b) end
end

-- Events --------------------------------------------------------------------------

local function PartnerName()
  return NS.UnitFullName("NPC")
end

local function Accepted(v)
  return v == 1 or v == true
end

NS.Register("TRADE_SHOW", function()
  session = session + 1
  partner, snap, accepted, pendingEnchant = PartnerName(), nil, nil, nil
  Trade.UpdateButton()
  -- Blizzard positions the trade window as it shows it: place the button again a frame later.
  local s = session
  if C_Timer and C_Timer.After then
    C_Timer.After(0, function()
      if session == s and partner then Trade.UpdateButton() end
    end)
  end
end)
for _, ev in ipairs({ "TRADE_PLAYER_ITEM_CHANGED", "TRADE_TARGET_ITEM_CHANGED" }) do
  NS.Register(ev, function()
    if not partner then return end
    snap = Read() or snap
    Trade.UpdateButton()
  end)
end
NS.Register("TRADE_ACCEPT_UPDATE", function(_, playerAccepted, targetAccepted)
  if not (partner and Shown()) then return end
  snap = Read() or snap
  if issecretvalue and (issecretvalue(playerAccepted) or issecretvalue(targetAccepted)) then return end
  if Accepted(playerAccepted) and Accepted(targetAccepted) then
    -- Frozen: the window may read empty by the time the completion message arrives.
    accepted = snap
  elseif not Accepted(playerAccepted) then
    -- Accept was reset (something changed after an attempt): the frozen read is stale.
    accepted = nil
  end
end)
NS.Register("UI_INFO_MESSAGE", function(_, ...)
  if not (ERR_TRADE_COMPLETE and partner) then return end
  for i = 1, select("#", ...) do
    if issecretvalue and issecretvalue((select(i, ...))) then return end
    if select(i, ...) == ERR_TRADE_COMPLETE then
      Completed()
      snap, accepted, pendingEnchant = nil, nil, nil
      return
    end
  end
end)
NS.Register("TRADE_CLOSED", function()
  HideButton()
  local s = session
  local function clear()
    -- A new trade window since (or this one still open): leave it alone.
    if session ~= s or Shown() then return end
    partner, snap, accepted, pendingEnchant = nil, nil, nil, nil
  end
  if C_Timer and C_Timer.After then C_Timer.After(0.5, clear) else clear() end
end)
-- Hidden as combat starts (still allowed in this event); set up again after it.
NS.Register("PLAYER_REGEN_DISABLED", HideButton)
NS.Register("PLAYER_REGEN_ENABLED", function()
  if partner and Shown() then
    Trade.UpdateButton()
  else
    -- The trade closed during combat, when the button couldn't be hidden: hide it now.
    HideButton()
  end
end)
NS.Register("TRADE_SKILL_SHOW", function()
  tradeSkillOpen = true
  if partner then Trade.UpdateButton() end
end)
NS.Register("TRADE_SKILL_CLOSE", function()
  tradeSkillOpen = false
  if partner then Trade.UpdateButton() end
end)
NS.Register("TRADE_SKILL_LIST_UPDATE", function()
  if partner then Trade.UpdateButton() end
end)
if NS.RegisterCallback then
  for _, ev in ipairs({ "QUEUE_UPDATED", "CHAT_SEEN_UPDATED", "INVENTORY_UPDATED" }) do
    NS.RegisterCallback(Trade, ev, function() if partner then Trade.UpdateButton() end end)
  end
end
