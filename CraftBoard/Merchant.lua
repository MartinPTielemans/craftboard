-- CraftBoard Merchant: at a vendor, a "Buy missing reagents" button under the merchant window
-- (Merchant tab only, not Buyback) buys what my craft queue still lacks from that vendor:
-- NS.Queue.Totals(true) rows with have < need, leaving out crafts whose player brings the
-- reagents. Only gold-priced items (no currency / item costs), within the vendor's stock, my money
-- and my free bag space, rounded up to the vendor's bundle size. Nothing is bought without a click
-- on the button; the chat line afterwards says what actually arrived in my bags.
local ADDON, NS = ...

local Merchant = {}
NS.Merchant = Merchant

local L = NS.L
local format = string.format
local GREY = { 0.6, 0.6, 0.6 }
local MAX_NAMES = 5

local button = nil
local open = false
-- The last click: pending[itemID] = items bought that haven't reached my bags yet (taken off the
-- shortfall, and the button stays disabled while any are left); purchase = { rows = { {itemID=,
-- count=, before= (my count before buying), cost=} }, money= (before), reported= }.
local pending = {}
local purchase = nil

-- Price, bundle size (items per purchase), stock (purchases left, -1 = unlimited), and whether
-- the item costs anything but gold. Handles the multi-return API and a table-returning one.
local function ItemInfo(index)
  if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
    local ok, info = pcall(C_MerchantFrame.GetItemInfo, index)
    if ok and type(info) == "table" then
      return tonumber(info.price) or 0, tonumber(info.stackCount) or 1, tonumber(info.numAvailable) or -1,
        info.isPurchasable ~= false, info.hasExtendedCost or info.extendedCost or false
    end
  end
  if GetMerchantItemInfo then
    local ok, name, _, price, stackCount, numAvailable, isPurchasable, _, extendedCost = pcall(GetMerchantItemInfo, index)
    if ok and name then
      return tonumber(price) or 0, tonumber(stackCount) or 1, tonumber(numAvailable) or -1,
        isPurchasable ~= false, extendedCost or false
    end
  end
  return nil
end

local function ItemID(index)
  if GetMerchantItemID then
    local ok, id = pcall(GetMerchantItemID, index)
    if ok and type(id) == "number" then return id end
  end
  if GetMerchantItemLink then
    local ok, link = pcall(GetMerchantItemLink, index)
    if ok and type(link) == "string" then return tonumber(link:match("item:(%d+)")) end
  end
  return nil
end

-- Most items one BuyMerchantItem call takes for a vendor row.
local function MaxStack(index)
  if GetMerchantItemMaxStack and index then
    local ok, n = pcall(GetMerchantItemMaxStack, index)
    n = ok and tonumber(n)
    if n and n > 0 then return n end
  end
  return 20
end

-- Items per bag slot (the item's stack size).
local function StackSize(itemID, index)
  if C_Item and C_Item.GetItemMaxStackSizeByID then
    local ok, n = pcall(C_Item.GetItemMaxStackSizeByID, itemID)
    n = ok and tonumber(n)
    if n and n > 0 then return n end
  end
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if getInfo then
    local ok, _, _, _, _, _, _, _, n = pcall(getInfo, itemID)
    n = ok and tonumber(n)
    if n and n > 0 then return n end
  end
  return MaxStack(index)
end

local function Count(itemID)
  return NS.Inventory and NS.Inventory.Count and NS.Inventory.Count(itemID) or 0
end

local function Money()
  return GetMoney and tonumber(GetMoney()) or 0
end

local function MoneyText(copper)
  if GetMoneyString then
    local ok, s = pcall(GetMoneyString, copper, true)
    if ok and type(s) == "string" then return s end
  end
  if GetCoinTextureString then
    local ok, s = pcall(GetCoinTextureString, copper)
    if ok and type(s) == "string" then return s end
  end
  return format("%dg %ds %dc", math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

-- Room in my bags: free slots of the general-purpose bags (bag family 0), and room left on partial
-- stacks of the items in `want` ({ [itemID] = true }): free, { [itemID] = items }. free is nil
-- when the client can't tell (then bag space doesn't limit the plan).
local function BagRoom(want)
  local freeFn = (C_Container and C_Container.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
  if not freeFn then return nil, {} end
  local slotsFn = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
  local infoFn = C_Container and C_Container.GetContainerItemInfo
  local free, room, known, special = 0, {}, false, {}
  -- The reagent bag (mainline-type clients) holds exactly what this buys: its free slots and
  -- partial stacks count as well.
  local bags = {}
  for bag = 0, tonumber(NUM_BAG_SLOTS) or 4 do bags[#bags + 1] = bag end
  local reagentBag = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag
  if type(reagentBag) == "number" and reagentBag > (tonumber(NUM_BAG_SLOTS) or 4) then bags[#bags + 1] = reagentBag end
  for _, bag in ipairs(bags) do
    local ok, n, family = pcall(freeFn, bag)
    n = ok and tonumber(n)
    if n then
      known = true
      family = tonumber(family) or 0
      if family == 0 or bag == reagentBag then
        free = free + n
      elseif n > 0 then
        -- A profession bag (herbs, enchanting, mining...): only for items of its family.
        special[#special + 1] = { family = family, n = n }
      end
    end
    local ok2, slots = false, nil
    if slotsFn then ok2, slots = pcall(slotsFn, bag) end
    for slot = 1, ok2 and tonumber(slots) or 0 do
      local ok3, info = false, nil
      if infoFn then ok3, info = pcall(infoFn, bag, slot) end
      local id = ok3 and type(info) == "table" and info.itemID
      if type(id) == "number" and want[id] then
        local left = StackSize(id) - (tonumber(info.stackCount) or 1)
        if left > 0 then room[id] = (room[id] or 0) + left end
      end
    end
  end
  if not known then return nil, {}, {} end
  return free, room, special
end

-- What one click buys: plan { {index=, itemID=, count= (items), stack= (items per purchase), cost=}, ... },
-- total cost, info { notSold = {itemIDs short but not sold here for gold}, poor = {itemIDs I
-- can't afford all of}, full = true when bag space cut the plan }. Items bought a moment ago
-- that haven't arrived yet count as had.
function Merchant.Plan()
  local plan, total = {}, 0
  local info = { notSold = {}, poor = {}, full = false }
  local rows = NS.Queue and NS.Queue.Totals and NS.Queue.Totals(true) or {}
  local short, order = {}, {}
  for _, row in ipairs(rows) do
    local id = row.itemID
    local need, have = tonumber(row.need) or 0, tonumber(row.have) or 0
    local want = type(id) == "number" and need - have - (pending[id] or 0) or 0
    if want > 0 and not short[id] then
      short[id] = want
      order[#order + 1] = id
    end
  end
  if #order == 0 or not GetMerchantNumItems then return plan, total, info end
  local money = Money()
  local free, room, special = BagRoom(short)
  local band = bit and bit.band
  local familyOf = (C_Item and C_Item.GetItemFamily) or GetItemFamily
  -- Free slots of the profession bags this item may go in (they are used first).
  local function SpecialFor(itemID)
    local out = {}
    if not (band and familyOf) then return out end
    local ok, fam = pcall(familyOf, itemID)
    fam = ok and tonumber(fam) or 0
    if fam == 0 then return out end
    for _, b in ipairs(special or {}) do
      if b.n > 0 and band(fam, b.family) ~= 0 then out[#out + 1] = b end
    end
    return out
  end
  local listed = {}
  for index = 1, tonumber(GetMerchantNumItems()) or 0 do
    local itemID = ItemID(index)
    local want = itemID and not listed[itemID] and short[itemID]
    if want then
      local price, stack, avail, purchasable, extended = ItemInfo(index)
      if price and price > 0 and purchasable and not extended then
        listed[itemID] = true
        stack = math.max(1, stack)
        local bundles = math.ceil(want / stack)
        if avail >= 0 then bundles = math.min(bundles, avail) end
        local afford = math.floor((money - total) / price)
        if afford < bundles then
          bundles = math.max(0, afford)
          info.poor[#info.poor + 1] = itemID
        end
        local size = StackSize(itemID, index)
        local bags = free and SpecialFor(itemID) or {}
        if free then
          local slots = free
          for _, b in ipairs(bags) do slots = slots + b.n end
          local fits = math.floor(((room[itemID] or 0) + slots * size) / stack)
          if fits < bundles then
            bundles = math.max(0, fits)
            info.full = true
          end
        end
        if bundles > 0 then
          local count = bundles * stack
          if free then
            local need = math.ceil(math.max(0, count - (room[itemID] or 0)) / size)
            for _, b in ipairs(bags) do
              local take = math.min(b.n, need)
              b.n, need = b.n - take, need - take
            end
            free = free - need
          end
          plan[#plan + 1] = { index = index, itemID = itemID, count = count, stack = stack, cost = bundles * price }
          total = total + bundles * price
        end
      end
    end
  end
  for _, id in ipairs(order) do
    if not listed[id] then info.notSold[#info.notSold + 1] = id end
  end
  return plan, total, info
end

local function Label(e)
  return format(L["%dx %s"], e.count, NS.ItemLabel and NS.ItemLabel(e.itemID) or tostring(e.itemID))
end

-- Plain item names for a grey line: "A, B, and 2 more".
local function NameList(ids)
  local out = {}
  for i = 1, math.min(MAX_NAMES, #ids) do
    local id = ids[i]
    out[i] = NS.Inventory and NS.Inventory.ItemName and NS.Inventory.ItemName(id)
      or (NS.ItemLabel and NS.ItemLabel(id)) or tostring(id)
  end
  if #ids > MAX_NAMES then out[#out + 1] = format(L["and %d more"], #ids - MAX_NAMES) end
  return table.concat(out, ", ")
end

local function ShowTooltip(self)
  if not GameTooltip then return end
  local plan, total, info = Merchant.Plan()
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine(L["Buy missing reagents"])
  for _, e in ipairs(plan) do GameTooltip:AddLine(Label(e), 1, 1, 1) end
  if total > 0 then GameTooltip:AddLine(format(L["Total: %s"], MoneyText(total)), 1, 0.82, 0) end
  if info.full then GameTooltip:AddLine(L["Not enough bag space for all of it."], GREY[1], GREY[2], GREY[3], true) end
  if #info.poor > 0 then
    GameTooltip:AddLine(format(L["Can't afford: %s"], NameList(info.poor)), GREY[1], GREY[2], GREY[3], true)
  end
  if #info.notSold > 0 then
    GameTooltip:AddLine(format(L["Not sold here: %s"], NameList(info.notSold)), GREY[1], GREY[2], GREY[3], true)
  end
  GameTooltip:Show()
end

-- The Merchant tab is showing (not Buyback).
local function OnMerchantTab()
  if not MerchantFrame then return false end
  local tab = MerchantFrame.selectedTab
  return tab == nil or tab == 1
end

local function Refresh()
  if not button then return end
  if not (open and OnMerchantTab()) then
    button:Hide()
    return
  end
  local ok, plan = pcall(Merchant.Plan)
  if ok and #plan > 0 then
    button:Show()
    button:SetEnabled(next(pending) == nil)
  else
    button:Hide()
  end
  if button:IsShown() and GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(button) then ShowTooltip(button) end
end

local function SafeRefresh()
  local ok, err = pcall(Refresh)
  if not ok then
    local eh = geterrorhandler and geterrorhandler()
    if eh then eh(err) end
  end
end

-- One chat line for the last click: what arrived and what it cost, or that nothing came.
local function Report(p)
  if p.reported then return end
  p.reported = true
  local parts, planned = {}, 0
  for _, e in ipairs(p.rows) do
    local got = math.min(e.count, Count(e.itemID) - e.before)
    if got > 0 then
      parts[#parts + 1] = Label({ itemID = e.itemID, count = got })
      planned = planned + math.floor(e.cost * got / e.count)
    end
  end
  if #parts == 0 then
    NS.Print(L["Your bags are full."])
    return
  end
  local spent = p.money - Money()
  NS.Print(format(L["Bought %s (%s)."], table.concat(parts, ", "), MoneyText(spent > 0 and spent or planned)))
end

-- After a bag change (or at the deadline): items that arrived leave `pending`; the chat line goes
-- out once everything is in, or at the deadline with whatever made it.
local function CheckArrival(p, deadline)
  if not p or p ~= purchase then return end
  local waiting = false
  for _, e in ipairs(p.rows) do
    if pending[e.itemID] then
      local got = Count(e.itemID) - e.before
      if got >= e.count then
        pending[e.itemID] = nil
      else
        pending[e.itemID] = e.count - math.max(0, got)
        waiting = true
      end
    end
  end
  if not waiting or deadline then Report(p) end
  SafeRefresh()
end

-- Buy the plan, in chunks the vendor accepts: each BuyMerchantItem call takes a number of items
-- that is a multiple of the bundle size and no more than the item's max stack.
local function Buy()
  if next(pending) then return end
  local plan = Merchant.Plan()
  if #plan == 0 or not BuyMerchantItem then return end
  local p = { rows = {}, money = Money() }
  for _, e in ipairs(plan) do
    local before = Count(e.itemID)
    local chunk = math.max(e.stack, math.floor(MaxStack(e.index) / e.stack) * e.stack)
    local left = e.count
    while left > 0 do
      local n = math.min(chunk, left)
      if not pcall(BuyMerchantItem, e.index, n) then break end
      left = left - n
    end
    local bought = e.count - left
    if bought > 0 then
      p.rows[#p.rows + 1] = { itemID = e.itemID, count = bought, before = before, cost = math.floor(e.cost * bought / e.count) }
      pending[e.itemID] = bought
    end
  end
  if #p.rows == 0 then return end
  purchase = p
  if C_Timer and C_Timer.After then
    C_Timer.After(3, function() CheckArrival(p, true) end)
    -- Stop waiting after a while either way, so the button can't stay disabled.
    C_Timer.After(5, function()
      if purchase ~= p then return end
      purchase = nil
      for id in pairs(pending) do pending[id] = nil end
      SafeRefresh()
    end)
  else
    CheckArrival(p, true)
  end
end

-- Width from the label: at least 120, text plus padding.
local function FitWidth(b)
  local fs = b.GetFontString and b:GetFontString()
  local w = fs and fs.GetStringWidth and tonumber(fs:GetStringWidth()) or 0
  b:SetWidth(math.max(120, w + 24))
end

local function Create()
  if button or not (CreateFrame and MerchantFrame) then return end
  button = CreateFrame("Button", "CraftBoardMerchantBuy", MerchantFrame, "UIPanelButtonTemplate")
  button:SetHeight(22)
  -- Right edge, below the frame: Blizzard's Merchant / Buyback tabs hang off the bottom left.
  button:SetPoint("TOPRIGHT", MerchantFrame, "BOTTOMRIGHT", -4, -2)
  button:SetText(L["Buy missing reagents"])
  FitWidth(button)
  button:Hide()
  if button.SetMotionScriptsWhileDisabled then button:SetMotionScriptsWhileDisabled(true) end
  button:SetScript("OnEnter", ShowTooltip)
  button:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  button:SetScript("OnClick", function(self)
    if next(pending) then return end
    self:SetEnabled(false)
    local ok, err = pcall(Buy)
    if not ok then
      local eh = geterrorhandler and geterrorhandler()
      if eh then eh(err) end
    end
    SafeRefresh()
  end)
  -- Post-hooks: the Merchant / Buyback tabs and Blizzard's own redraw of the window.
  for i = 1, 2 do
    local tab = _G["MerchantFrameTab" .. i]
    if tab and tab.HookScript then pcall(tab.HookScript, tab, "OnClick", SafeRefresh) end
  end
  if hooksecurefunc and type(MerchantFrame_Update) == "function" then
    pcall(hooksecurefunc, "MerchantFrame_Update", SafeRefresh)
  end
end

NS.Register("MERCHANT_SHOW", function()
  open = true
  Create()
  Refresh()
end)
NS.Register("MERCHANT_UPDATE", function()
  if open then Refresh() end
end)
NS.Register("MERCHANT_CLOSED", function()
  open = false
  if button then button:Hide() end
end)
NS.Register("BAG_UPDATE_DELAYED", function()
  if purchase then CheckArrival(purchase, false) end
end)
if NS.RegisterCallback then
  NS.RegisterCallback(Merchant, "QUEUE_UPDATED", function() if open then Refresh() end end)
  NS.RegisterCallback(Merchant, "INVENTORY_UPDATED", function() if open then Refresh() end end)
end
