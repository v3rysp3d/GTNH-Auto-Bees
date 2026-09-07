-- bb.catalog : stable numbering of bee species.
--
-- Numbers never change once assigned. Ranges hint at the source mod:
--   1000+ Forestry   2000+ Extra Bees   3000+ Magic Bees   4000+ GregTech
--   5000+ other mods with a known UID   9000+ species with no UID
--   (hive-only base species only appear as parents in the breeding data,
--    which carries names but no UIDs)
local util = require("src.util")

local catalog = {}
catalog.__index = catalog

catalog.ranges = {
  { prefix = "forestry.",  base = 1000, label = "Forestry" },
  { prefix = "extrabees.", base = 2000, label = "ExtraBees" },
  { prefix = "magicbees.", base = 3000, label = "MagicBees" },
  { prefix = "gregtech.",  base = 4000, label = "GregTech" },
}
catalog.otherBase = 5000
catalog.unknownBase = 9000

function catalog.new(path)
  return setmetatable({ path = path, byId = {}, byName = {}, nextId = {} }, catalog)
end

function catalog:rebuildIndex()
  self.byName = {}
  for id, e in pairs(self.byId) do
    e.id = tonumber(id)
    self.byName[e.name:lower()] = e
  end
end

function catalog:load()
  local t = util.loadTable(self.path)
  if type(t) ~= "table" then return false end
  self.byId = {}
  for k, v in pairs(t.byId or {}) do self.byId[tonumber(k)] = v end
  self.nextId = t.nextId or {}
  self:rebuildIndex()
  return true
end

function catalog:save()
  if not self.path then return false end
  return util.saveTable(self.path, { byId = self.byId, nextId = self.nextId })
end

function catalog.modOf(uid)
  if not uid or uid == "" then return "base", catalog.unknownBase end
  local l = uid:lower()
  for _, r in ipairs(catalog.ranges) do
    if util.startsWith(l, r.prefix) then return r.label, r.base end
  end
  return "other", catalog.otherBase
end

--- Assign ids to a list of species { name=..., uid=... }.
--- Existing names keep their ids (and learn a uid if they had none).
--- Returns the number of newly assigned entries.
function catalog:assign(speciesList)
  local fresh = {}
  for _, sp in ipairs(speciesList) do
    if sp.name and sp.name ~= "" then
      local e = self.byName[sp.name:lower()]
      if e then
        if (not e.uid or e.uid == "") and sp.uid and sp.uid ~= "" then
          e.uid = sp.uid
          e.mod = catalog.modOf(sp.uid)
        end
      else
        fresh[#fresh + 1] = sp
      end
    end
  end
  table.sort(fresh, function(a, b) return a.name:lower() < b.name:lower() end)
  for _, sp in ipairs(fresh) do
    local mod, base = catalog.modOf(sp.uid)
    local id = self.nextId[tostring(base)] or (base + 1)
    while self.byId[id] do id = id + 1 end
    self.nextId[tostring(base)] = id + 1
    local e = { id = id, name = sp.name, uid = sp.uid, mod = mod }
    self.byId[id] = e
    self.byName[sp.name:lower()] = e
  end
  return #fresh
end

function catalog:get(id) return self.byId[tonumber(id)] end
function catalog:byNameLookup(name) return self.byName[tostring(name):lower()] end

function catalog:idOf(name)
  local e = self:byNameLookup(name)
  return e and e.id or nil
end

function catalog:nameOf(id)
  local e = self:get(id)
  return e and e.name or nil
end

function catalog:label(name)
  local e = self:byNameLookup(name)
  if e then return string.format("[%d] %s", e.id, e.name) end
  return tostring(name)
end

function catalog:all()
  local list = {}
  for _, e in pairs(self.byId) do list[#list + 1] = e end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

--- Substring search (case-insensitive) over names and uids.
function catalog:find(query, limit)
  query = tostring(query or ""):lower()
  local out = {}
  for _, e in ipairs(self:all()) do
    if e.name:lower():find(query, 1, true) or (e.uid and e.uid:lower():find(query, 1, true)) then
      out[#out + 1] = e
      if limit and #out >= limit then break end
    end
  end
  return out
end

--- Resolve a user token: number, exact name, or unique substring.
--- Returns entry or nil, reason.
function catalog:resolve(token)
  if token == nil then return nil, "missing species" end
  local n = tonumber(token)
  if n then
    local e = self:get(n)
    if e then return e end
    return nil, "no species with number " .. tostring(token)
  end
  local exact = self:byNameLookup(token)
  if exact then return exact end
  local matches = self:find(token)
  if #matches == 1 then return matches[1] end
  if #matches == 0 then return nil, "no species matching '" .. tostring(token) .. "'" end
  local names = {}
  for i = 1, math.min(6, #matches) do names[#names + 1] = string.format("#%d %s", matches[i].id, matches[i].name) end
  return nil, "ambiguous '" .. tostring(token) .. "': " .. table.concat(names, ", ")
end

function catalog:lines()
  local out = {}
  for _, e in ipairs(self:all()) do
    out[#out + 1] = string.format("%-5d %-10s %s", e.id, e.mod or "?", e.name)
  end
  return out
end

return catalog
