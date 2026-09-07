-- Stable numbering of bee species, keyed by allele uid.
--
-- Numbers never change once assigned. Ranges hint at the source mod:
--   1000+ Forestry   2000+ Extra Bees   3000+ Magic Bees   4000+ GregTech
--   5000+ other mods   9000+ species with no uid at all
-- Several mods reuse display names (Diamond, Ruby, Certus ...); labels of
-- such species carry the mod name so they can be told apart.
local util = require("src.util")

local catalog = {}
catalog.__index = catalog

catalog.ranges = {
  { prefix = "forestry.",  base = 1000, label = "Forestry" },
  { prefix = "extrabees.", base = 2000, label = "Extra Bees" },
  { prefix = "magicbees.", base = 3000, label = "Magic Bees" },
  { prefix = "gregtech.",  base = 4000, label = "GregTech" },
}
catalog.otherBase = 5000
catalog.unknownBase = 9000

-- display name -> uid for species the game reports without a uid (hive-only
-- parents in name-only data), generated from the mod sources by tools/bee_images.py
local okHints, uidHints = pcall(require, "src.species_uids")
catalog.uidHints = (okHints and type(uidHints) == "table") and uidHints or {}

function catalog.uidFor(name, uid)
  if uid and uid ~= "" then return uid end
  return catalog.uidHints[name]
end

---file name of the generated icon for a species (docs/bees/<file>.png)
function catalog.iconFile(uid)
  if not uid or uid == "" then return nil end
  return (uid:gsub("[^%w]", "_")) .. ".png"
end

function catalog.modOf(uid)
  if not uid or uid == "" then return "base", catalog.unknownBase end
  local l = uid:lower()
  for _, r in ipairs(catalog.ranges) do
    if util.startsWith(l, r.prefix) then return r.label, r.base end
  end
  -- a real uid has a mod prefix ("magicbees.speciesX"); a bare name has none
  local mod = uid:match("^([%w]+)%.")
  if not mod then return "base", catalog.unknownBase end
  return mod:sub(1, 1):upper() .. mod:sub(2), catalog.otherBase
end

function catalog.new(path)
  return setmetatable({ path = path, byId = {}, byUid = {}, byName = {}, nextId = {} }, catalog)
end

function catalog:rebuildIndex()
  self.byUid, self.byName = {}, {}
  for id, e in pairs(self.byId) do
    e.id = tonumber(id)
    self.byUid[e.uid] = e
    local key = e.name:lower()
    self.byName[key] = self.byName[key] or {}
    table.insert(self.byName[key], e)
  end
  for _, list in pairs(self.byName) do table.sort(list, function(a, b) return a.id < b.id end) end
end

function catalog:load()
  local t = util.loadTable(self.path)
  if type(t) ~= "table" then return false end
  self.byId = {}
  for k, v in pairs(t.byId or {}) do
    v.uid = v.uid or v.name
    self.byId[tonumber(k)] = v
  end
  self.nextId = t.nextId or {}
  self:rebuildIndex()
  return true
end

function catalog:save()
  if not self.path then return false end
  return util.saveTable(self.path, { byId = self.byId, nextId = self.nextId })
end

--- Assign ids to a list of species { uid=, name= }. Existing uids keep their
--- ids. Returns the number of new entries.
function catalog:assign(speciesList)
  local fresh = {}
  for _, sp in ipairs(speciesList) do
    local name = sp.name or sp.uid
    local uid = catalog.uidFor(name, sp.uid) or name
    if uid and uid ~= "" then
      local e = self.byUid[uid]
      if e then
        if name and name ~= "" and e.name ~= name and e.name == e.uid then e.name = name end
      else
        fresh[#fresh + 1] = { uid = uid, name = name }
      end
    end
  end
  table.sort(fresh, function(a, b)
    if a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
    return a.uid < b.uid
  end)
  for _, sp in ipairs(fresh) do
    local mod, base = catalog.modOf(sp.uid)
    local id = self.nextId[tostring(base)] or (base + 1)
    while self.byId[id] do id = id + 1 end
    self.nextId[tostring(base)] = id + 1
    self.byId[id] = { id = id, uid = sp.uid, name = sp.name, mod = mod }
  end
  self:rebuildIndex()
  return #fresh
end

function catalog:get(id) return self.byId[tonumber(id)] end
function catalog:byUidLookup(uid) return self.byUid[uid] end

--- Entries sharing a display name (case-insensitive)
function catalog:byNameLookup(name)
  return self.byName[tostring(name):lower()] or {}
end

--- The one entry for a name, or nil when unknown or shared by several mods
function catalog:uniqueByName(name)
  local list = self:byNameLookup(name)
  if #list == 1 then return list[1] end
  return nil
end

function catalog:nameOf(uid)
  local e = self.byUid[uid]
  return e and e.name or uid
end

function catalog:isShared(uid)
  local e = self.byUid[uid]
  return e ~= nil and #self:byNameLookup(e.name) > 1
end

--- "[1002] Forest", or "[4060] Diamond (GregTech)" when the name is shared
function catalog:label(uid)
  local e = self.byUid[uid]
  if not e then return tostring(uid) end
  if self:isShared(uid) then return string.format("[%d] %s (%s)", e.id, e.name, e.mod) end
  return string.format("[%d] %s", e.id, e.name)
end

function catalog:all()
  local list = {}
  for _, e in pairs(self.byId) do list[#list + 1] = e end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

--- Substring search (case-insensitive) over names, uids and mods.
function catalog:find(query, limit)
  query = tostring(query or ""):lower()
  local out = {}
  for _, e in ipairs(self:all()) do
    if e.name:lower():find(query, 1, true) or e.uid:lower():find(query, 1, true) or tostring(e.mod):lower():find(query, 1, true) then
      out[#out + 1] = e
      if limit and #out >= limit then break end
    end
  end
  return out
end

--- Resolve a user token: number, uid, exact name, or unique substring.
--- Returns entry or nil, reason.
function catalog:resolve(token)
  if token == nil then return nil, "missing species" end
  local n = tonumber(token)
  if n then
    local e = self:get(n)
    if e then return e end
    return nil, "no species with number " .. tostring(token)
  end
  if self.byUid[token] then return self.byUid[token] end
  local exact = self:byNameLookup(token)
  if #exact == 1 then return exact[1] end
  local matches = #exact > 1 and exact or self:find(token)
  if #matches == 1 then return matches[1] end
  if #matches == 0 then return nil, "no species matching '" .. tostring(token) .. "'" end
  local names = {}
  for i = 1, math.min(6, #matches) do names[#names + 1] = self:label(matches[i].uid) end
  return nil, "ambiguous '" .. tostring(token) .. "', use the number: " .. table.concat(names, ", ")
end

function catalog:lines()
  local out = {}
  for _, e in ipairs(self:all()) do
    out[#out + 1] = string.format("%-5d %-11s %s", e.id, e.mod or "?", e.name)
  end
  return out
end

return catalog
