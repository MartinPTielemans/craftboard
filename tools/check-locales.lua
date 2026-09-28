-- Checks the translation files against Locales.lua's enUS list: every key a translation sets
-- must be an enUS key, its value must keep the same format placeholders in the same order, and
-- (reported, not an error) which enUS keys it leaves in English.
-- Usage: lua tools/check-locales.lua [CraftBoard/Locales_deDE.lua ...]
local files = { ... }
if #files == 0 then files = { "CraftBoard/Locales_deDE.lua", "CraftBoard/Locales_frFR.lua", "CraftBoard/Locales_esES.lua" } end

-- enUS keys, by loading Locales.lua with a stub environment.
local NS = {}
GetLocale = function() return "enUS" end
assert(loadfile("CraftBoard/Locales.lua"))("CraftBoard", NS)
local enUS = {}
local src = io.open("CraftBoard/Locales.lua"):read("a")
local block = src:match("local enUS = {(.-)\n}")
for line in block:gmatch("[^\n]+") do
  local s = line:match('^%s*(".*"),%s*$')
  if s then enUS[load("return " .. s)()] = true end
end

-- The placeholders a string fills, in argument order. Positional ones ("%2$s", which the client's
-- string.format understands) are put back in argument order, so a translation may reorder them.
local function specs(s)
  local out, positional = {}, {}
  for spec in s:gmatch("%%[%-%d%.%$]*[sdif%%]") do
    if spec ~= "%%" then
      local n, rest = spec:match("^%%(%d+)%$(.*)$")
      if n then positional[#positional + 1] = { tonumber(n), "%" .. rest } else out[#out + 1] = spec end
    end
  end
  if #positional > 0 then
    table.sort(positional, function(a, b) return a[1] < b[1] end)
    for _, p in ipairs(positional) do out[#out + 1] = p[2] end
  end
  return table.concat(out, " ")
end

local fail = false
for _, file in ipairs(files) do
  local f = io.open(file)
  if not f then
    print(file .. ": missing")
    fail = true
  else
    f:close()
    local locale = file:match("Locales_(%a+)%.lua")
    local set = {}
    local L = setmetatable({}, { __newindex = function(t, k, v)
      if set[k] then print(file .. ": duplicate key " .. k) fail = true end
      set[k] = v
    end })
    GetLocale = function() return locale end
    local ok, err = pcall(assert(loadfile(file)), "CraftBoard", { L = L, locale = locale })
    if not ok then print(file .. ": " .. tostring(err)) fail = true end
    local n, missing = 0, {}
    for k, v in pairs(set) do
      n = n + 1
      if not enUS[k] then print(file .. ": not an enUS key: " .. k) fail = true
      elseif type(v) ~= "string" or v == "" then print(file .. ": empty value for " .. k) fail = true
      elseif specs(k) ~= specs(v) then
        print(file .. ": placeholders differ for " .. k .. "\n    en: " .. specs(k) .. "\n    " .. locale .. ": " .. specs(v))
        fail = true
      end
    end
    for k in pairs(enUS) do
      if set[k] == nil then missing[#missing + 1] = k end
    end
    table.sort(missing)
    print(string.format("%s: %d translated, %d left in English", file, n, #missing))
    for _, k in ipairs(missing) do print("    untranslated: " .. k) end
  end
end
os.exit(fail and 1 or 0)
