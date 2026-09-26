-- Developer aid: dump the visual structure of a Blizzard frame into saved data so the
-- look can be reproduced exactly. `/cb dump [FrameName]` (default ProfessionsFrame).
local ADDON, NS = ...

local MAX_NODES = 4000

local function safe(fn, ...)
  local ok, a, b, c, d = pcall(fn, ...)
  if ok then return a, b, c, d end
end

local function round(v) return v and math.floor(v * 10 + 0.5) / 10 or nil end

local function anchors(obj)
  local out = {}
  local n = safe(obj.GetNumPoints, obj) or 0
  for i = 1, n do
    local p, rel, rp, x, y = safe(obj.GetPoint, obj, i)
    if p then
      local relName = rel and (safe(rel.GetName, rel) or safe(rel.GetObjectType, rel)) or "nil"
      out[#out + 1] = string.format("%s->%s.%s %s,%s", tostring(p), tostring(relName), tostring(rp), tostring(round(x)), tostring(round(y)))
    end
  end
  return table.concat(out, " | ")
end

local function describe(obj, depth, list)
  if #list >= MAX_NODES then return end
  local t = safe(obj.GetObjectType, obj) or "?"
  local w, h = safe(obj.GetSize, obj)
  local rec = { d = depth, t = t, n = safe(obj.GetName, obj), w = round(w), h = round(h),
                shown = safe(obj.IsShown, obj) and 1 or 0 }
  local okA, a = pcall(anchors, obj)
  rec.a = okA and a or ("anchors failed: " .. tostring(a))
  if safe(obj.GetDebugName, obj) then rec.dn = safe(obj.GetDebugName, obj) end
  if t == "Texture" or t == "MaskTexture" then
    rec.atlas = safe(obj.GetAtlas, obj)
    rec.tex = safe(obj.GetTexture, obj)
    local l, r, tp, b = safe(obj.GetTexCoord, obj)
    if l then rec.tc = string.format("%.3f,%.3f,%.3f,%.3f", l, r, tp, b) end
    local cr, cg, cb, ca = safe(obj.GetVertexColor, obj)
    if cr then rec.col = string.format("%.2f,%.2f,%.2f,%.2f", cr, cg, cb, ca or 1) end
    rec.blend = safe(obj.GetBlendMode, obj)
    rec.layer = safe(obj.GetDrawLayer, obj)
    rec.alpha = round(safe(obj.GetAlpha, obj))
  elseif t == "FontString" then
    local fo = safe(obj.GetFontObject, obj)
    rec.font = fo and safe(fo.GetName, fo) or nil
    local path, size, flags = safe(obj.GetFont, obj)
    if path then rec.fontfile = string.format("%s %s %s", tostring(path), tostring(round(size)), tostring(flags)) end
    local cr, cg, cb = safe(obj.GetTextColor, obj)
    if cr then rec.col = string.format("%.2f,%.2f,%.2f", cr, cg, cb) end
    rec.text = safe(obj.GetText, obj)
    if rec.text and #rec.text > 40 then rec.text = rec.text:sub(1, 40) end
    rec.just = safe(obj.GetJustifyH, obj)
  else
    rec.alpha = round(safe(obj.GetAlpha, obj))
    if safe(obj.GetNormalTexture, obj) then
      local nt = safe(obj.GetNormalTexture, obj)
      rec.normal = nt and (safe(nt.GetAtlas, nt) or safe(nt.GetTexture, nt))
      local ht = safe(obj.GetHighlightTexture, obj)
      rec.highlight = ht and (safe(ht.GetAtlas, ht) or safe(ht.GetTexture, ht))
      local pt = safe(obj.GetPushedTexture, obj)
      rec.pushed = pt and (safe(pt.GetAtlas, pt) or safe(pt.GetTexture, pt))
    end
    if safe(obj.GetBackdrop, obj) then rec.backdrop = 1 end
  end
  list[#list + 1] = rec
  if t ~= "Texture" and t ~= "FontString" and t ~= "MaskTexture" then
    if obj.GetRegions then
      local regions = { safe(obj.GetRegions, obj) }
      for i = 1, #regions do describe(regions[i], depth + 1, list) end
    end
    if obj.GetChildren then
      local kids = { safe(obj.GetChildren, obj) }
      for i = 1, #kids do describe(kids[i], depth + 1, list) end
    end
  end
end

local function TopLevel(f)
  while f and f.GetParent do
    local p = f:GetParent()
    if not p or p == UIParent or p == WorldFrame then break end
    f = p
  end
  return f
end

local function MouseFrame()
  if GetMouseFoci then
    local t = GetMouseFoci()
    return t and t[1]
  elseif GetMouseFocus then
    return GetMouseFocus()
  end
end

-- `/cb frames`: list visible top-level windows so their real names are known.
function NS.ListFrames()
  if not EnumerateFrames then NS.Print("EnumerateFrames unavailable"); return end
  local f = EnumerateFrames()
  local n = 0
  while f do
    local ok, shown = pcall(f.IsVisible, f)
    if ok and shown and f:GetParent() == UIParent then
      local w, h = f:GetSize()
      if w >= 200 and h >= 200 then
        n = n + 1
        NS.Print(string.format("%s  %dx%d", tostring(f:GetName() or f:GetDebugName()), w, h))
      end
    end
    f = EnumerateFrames(f)
  end
  NS.Print(string.format("%d visible windows", n))
end

local function DumpObject(f, name)
  local list = {}
  describe(f, 0, list)
  CraftBoardDB.dumps = CraftBoardDB.dumps or {}
  CraftBoardDB.dumps[name] = { when = time(), build = select(2, GetBuildInfo()), nodes = list }
  local fonts = {}
  for _, n in ipairs({ "GameFontNormal", "GameFontHighlight", "GameFontNormalLarge", "GameFontHighlightSmall",
                       "GameFontNormalSmall", "GameFontDisable", "GameFontNormalMed2", "GameFontNormalMed3",
                       "GameFontHighlightMedium", "GameFontNormalHuge", "SystemFont_Shadow_Med1",
                       "QuestFont", "QuestTitleFont", "NumberFont_Shadow_Small" }) do
    local fo = _G[n]
    if fo and fo.GetFont then
      local p, s, fl = safe(fo.GetFont, fo)
      fonts[n] = string.format("%s %s %s", tostring(p), tostring(round(s)), tostring(fl))
    end
  end
  CraftBoardDB.dumps.fonts = fonts
  NS.Print(string.format("dumped %d nodes of %s; /reload to write it to disk", #list, name))
end

-- `/cb dump [FrameName]`: with a name, dump that global frame. Without one, wait 3 s and
-- dump the window under the mouse (so the frame's real name need not be known).
function NS.DumpFrame(name)
  if name and name ~= "" then
    local f = _G[name]
    if not f then NS.Print("no frame named " .. name .. "; try /cb frames or hover it and use /cb dump"); return end
    DumpObject(f, name)
    return
  end
  NS.Print("hover the window to capture; dumping in 3 seconds")
  C_Timer.After(3, function()
    local ok, err = pcall(function()
      local m = MouseFrame()
      NS.Print("under mouse: " .. tostring(m and (m:GetName() or m:GetDebugName()) or "nothing"))
      local f = TopLevel(m)
      if not f or f == UIParent or f == WorldFrame then NS.Print("nothing under the mouse"); return end
      DumpObject(f, f:GetName() or f:GetDebugName() or "unnamed")
    end)
    if not ok then NS.Print("dump failed: " .. tostring(err)) end
  end)
end
