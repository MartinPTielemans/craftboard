-- CraftBoard Merchant: at a vendor, a "Buy missing mats" button under the merchant window buys
-- what my craft queue still lacks (NS.Queue.Totals rows with have < need) from that vendor.
-- Only gold-priced items (no currency / item costs), within the vendor's stock and my money,
-- rounded up to the vendor's bundle size. Nothing is bought without a click on the button.
local ADDON, NS = ...

local Merchant = {}
NS.Merchant = Merchant

local L = NS.L
local format = string.format

local button = nil
local open = false
local cooling = false   -- the button is disabled for a moment after a click

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

local function MaxStack(index)
  if GetMerchantItemMaxStack then
    local ok, n = pcall(GetMerchantItemMaxStack, index)
    if ok and tonumber(n) and n > 0 then return n end
  end
  return 20
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

-- What one click buys: { {index=, itemID=, count= (items), stack= (items per purchase), cost=}, ... },
-- total cost. Rows are skipped when the vendor doesn't sell the item for gold; the plan stops
-- short of spending more than I have.
function Merchant.Plan()
  local plan, total = {}, 0
  local rows = NS.Queue and NS.Queue.Totals and NS.Queue.Totals() or {}
  local short = {}
  for _, row in ipairs(rows) do
    local need, have = tonumber(row.need) or 0, tonumber(row.have) or 0
    if type(row.itemID) == "number" and have < need then short[row.itemID] = need - have end
  end
  if not next(short) or not GetMerchantNumItems then return plan, total end
  local money = Money()
  local done = {}
  for index = 1, GetMerchantNumItems() or 0 do
    local itemID = ItemID(index)
    local want = itemID and not done[itemID] and short[itemID]
    if want then
      local price, stack, avail, purchasable, extended = ItemInfo(index)
      if price and price > 0 and purchasable and not extended then
        stack = math.max(1, stack)
        local bundles = math.ceil(want / stack)
        if avail >= 0 then bundles = math.min(bundles, avail) end
        bundles = math.min(bundles, math.floor((money - total) / price))
        if bundles > 0 then
          done[itemID] = true
          plan[#plan + 1] = { index = index, itemID = itemID, count = bundles * stack, stack = stack, cost = bundles * price }
          total = total + bundles * price
        end
      end
    end
  end
  return plan, total
end

local function Label(e)
  return format(L["%dx %s"], e.count, NS.ItemLabel and NS.ItemLabel(e.itemID) or tostring(e.itemID))
end

local function ShowTooltip(self)
  if not GameTooltip then return end
  local plan, total = Merchant.Plan()
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine(L["Buy missing mats"])
  for _, e in ipairs(plan) do GameTooltip:AddLine(Label(e), 1, 1, 1) end
  if total > 0 then GameTooltip:AddLine(format(L["Total: %s"], MoneyText(total)), 1, 0.82, 0) end
  GameTooltip:Show()
end

local function Refresh()
  if not button then return end
  if not open then
    button:Hide()
    return
  end
  local ok, plan = pcall(Merchant.Plan)
  if ok and #plan > 0 then
    button:Show()
    button:SetEnabled(not cooling)
  else
    button:Hide()
  end
  if button:IsShown() and GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(button) then ShowTooltip(button) end
end

-- Buy the plan, in chunks the vendor accepts: each BuyMerchantItem call takes a number of items
-- that is a multiple of the bundle size and no more than the item's max stack.
local function Buy()
  local plan, total = Merchant.Plan()
  if #plan == 0 or not BuyMerchantItem then return end
  local bought = {}
  for _, e in ipairs(plan) do
    local chunk = math.max(e.stack, math.floor(MaxStack(e.index) / e.stack) * e.stack)
    local left = e.count
    while left > 0 do
      local n = math.min(chunk, left)
      if not pcall(BuyMerchantItem, e.index, n) then break end
      left = left - n
    end
    if left < e.count then bought[#bought + 1] = Label({ itemID = e.itemID, count = e.count - left }) end
  end
  if #bought > 0 then
    NS.Print(format(L["Bought %s (%s)."], table.concat(bought, ", "), MoneyText(total)))
  end
end

local function Create()
  if button or not (CreateFrame and MerchantFrame) then return end
  button = CreateFrame("Button", "CraftBoardMerchantBuy", MerchantFrame, "UIPanelButtonTemplate")
  button:SetSize(140, 22)
  button:SetPoint("TOPLEFT", MerchantFrame, "BOTTOMLEFT", 4, -2)
  button:SetText(L["Buy missing mats"])
  button:Hide()
  button:SetScript("OnEnter", ShowTooltip)
  button:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  button:SetScript("OnClick", function(self)
    if cooling then return end
    cooling = true
    self:SetEnabled(false)
    local ok, err = pcall(Buy)
    if not ok then
      local eh = geterrorhandler and geterrorhandler()
      if eh then eh(err) end
    end
    if C_Timer and C_Timer.After then
      C_Timer.After(1, function()
        cooling = false
        Refresh()
      end)
    else
      cooling = false
    end
  end)
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
if NS.RegisterCallback then
  NS.RegisterCallback(Merchant, "QUEUE_UPDATED", function() if open then Refresh() end end)
  NS.RegisterCallback(Merchant, "INVENTORY_UPDATED", function() if open then Refresh() end end)
end
