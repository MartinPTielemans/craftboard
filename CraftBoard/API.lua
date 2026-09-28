-- CraftBoard API: a small, stable surface for other addons (Town Square hands public chat crafting
-- asks over through it). Every function is safe to call at any time, does nothing when the part it
-- needs isn't loaded, and never sends anything.
local ADDON, NS = ...

local API = { version = 1 }

local function Open(tab)
  if NS.UI and NS.UI.ShowTab then
    NS.UI.ShowTab(tab)
    return true
  end
  return false
end

-- Requests' "Seen in chat" row for a player ("First Surname" or "First Surname-Realm"), or nil.
local function SeenFrom(sender)
  local full = type(sender) == "string" and NS.FullName(sender)
  if not (full and NS.ChatWatch and NS.ChatWatch.Seen) then return nil end
  for _, s in ipairs(NS.ChatWatch.Seen()) do
    if NS.SamePlayer(s.from, full) then return s end
  end
  return nil
end

-- Open CraftBoard on Requests; with a sender, select that player's "Seen in chat" row if there is one.
function API.ShowRequests(sender)
  if not Open(2) then return false end
  local s = SeenFrom(sender)
  if s and NS.UI.SelectRequest then
    NS.UI.SelectRequest("chat:" .. s.from .. ":" .. (s.itemName or s.prof or ""))
  end
  return true
end

-- Open CraftBoard on Find, searching for text (an item or recipe name).
function API.Find(text)
  if not Open(1) then return false end
  if type(text) == "string" and text ~= "" and NS.UI.Search then NS.UI.Search(text) end
  return true
end

-- A public chat line asking for a crafter: add it to "Seen in chat" the way the chat watcher would
-- (CraftBoard hears the same channels, so it is usually there already). Returns true when
-- CraftBoard reads the line as a crafting ask. The same sender and text twice adds one row.
function API.AddChatSeen(text, sender, channelLabel)
  if type(text) ~= "string" or type(sender) ~= "string" or not (NS.ChatWatch and NS.ChatWatch.Add) then
    return false
  end
  local s = SeenFrom(sender)
  if s and s.text == NS.ChatWatch.Clean(text) then return true end
  return NS.ChatWatch.Add(text, sender, channelLabel or "Trade") ~= nil
end

CraftBoardAPI = API
