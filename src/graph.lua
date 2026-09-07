-- The mutation graph and the breeding planner.
--
-- Species are keyed by allele uid ("forestry.speciesForest"); every species
-- also carries its display name. The survey builds the graph from
-- bee_housing.getBeeParents(uid), which reports parents with uids. The older
-- name-only shape from getBeeBreedingData() is accepted too: names then act
-- as uids, which is fine as long as no two mods share a name.
local util = require("src.util")
local conditions = require("src.conditions")

local graph = {}
graph.__index = graph

function graph.new()
  return setmetatable({
    mutations = {},   -- list of { a, b, result (uids), chance, conds, raw }
    byResult = {},    -- result uid -> list of mutation indexes
    byParent = {},    -- parent uid -> list of mutation indexes
    species = {},     -- uid -> { uid=, name= }
  }, graph)
end

function graph:addSpecies(uid, name)
  if not uid or uid == "" then return end
  local e = self.species[uid]
  if not e then
    e = { uid = uid, name = name or uid }
    self.species[uid] = e
  elseif name and name ~= "" and e.name == uid then
    e.name = name
  end
  return e
end

function graph:nameOf(uid)
  local e = self.species[uid]
  return e and e.name or uid
end

function graph:addMutation(m)
  if not (m.a and m.b and m.result) then return nil end
  local idx = #self.mutations + 1
  local entry = {
    a = m.a, b = m.b, result = m.result,
    chance = tonumber(m.chance) or 0,
    raw = m.raw or {},
    conds = m.conds or conditions.parseAll(m.raw or {}),
  }
  self.mutations[idx] = entry
  self.byResult[m.result] = self.byResult[m.result] or {}
  table.insert(self.byResult[m.result], idx)
  for _, p in ipairs({ m.a, m.b }) do
    self.byParent[p] = self.byParent[p] or {}
    table.insert(self.byParent[p], idx)
  end
  self:addSpecies(m.a, m.aName); self:addSpecies(m.b, m.bName); self:addSpecies(m.result, m.resultName)
  return entry
end

local function rawList(t)
  local raw = {}
  for _, s in ipairs(t or {}) do raw[#raw + 1] = tostring(s) end
  return raw
end

--- Build from getBeeParents() output.
--- parentsData: list of { result = {name=,uid=}, allele1 = {name=,uid=}, allele2 = {name=,uid=}, chance=, specialConditions={} }
function graph.fromParents(parentsData)
  local g = graph.new()
  for _, m in ipairs(parentsData or {}) do
    if type(m) == "table" and m.result and m.allele1 and m.allele2 then
      g:addMutation({
        a = m.allele1.uid or m.allele1.name, aName = m.allele1.name,
        b = m.allele2.uid or m.allele2.name, bName = m.allele2.name,
        result = m.result.uid or m.result.name, resultName = m.result.name,
        chance = m.chance, raw = rawList(m.specialConditions),
      })
    end
  end
  return g
end

--- Build from getBeeBreedingData() output (names only). speciesList (from
--- listAllSpecies) supplies uids for the names it knows; other names act as uids.
function graph.fromBreedingData(breedingData, speciesList)
  local g = graph.new()
  local uidByName = {}
  for _, sp in ipairs(speciesList or {}) do
    if type(sp) == "table" and sp.name then
      if sp.uid and sp.uid ~= "" then uidByName[sp.name] = sp.uid end
      g:addSpecies(sp.uid or sp.name, sp.name)
    end
  end
  local function key(name) return uidByName[name] or name end
  for _, m in ipairs(breedingData or {}) do
    if type(m) == "table" and m.allele1 and m.allele2 and m.result then
      g:addMutation({
        a = key(m.allele1), aName = m.allele1,
        b = key(m.allele2), bName = m.allele2,
        result = key(m.result), resultName = m.result,
        chance = m.chance, raw = rawList(m.specialConditions),
      })
    end
  end
  return g
end

function graph:toTable()
  local muts = {}
  for i, m in ipairs(self.mutations) do
    muts[i] = { a = m.a, b = m.b, result = m.result, chance = m.chance, raw = m.raw }
  end
  return { mutations = muts, species = self.species, keyed = "uid" }
end

function graph.fromTable(t)
  local g = graph.new()
  for uid, e in pairs(t.species or {}) do g:addSpecies(e.uid or uid, e.name) end
  for _, m in ipairs(t.mutations or {}) do g:addMutation(m) end
  return g
end

function graph:speciesList()
  local out = {}
  for _, e in pairs(self.species) do out[#out + 1] = { uid = e.uid, name = e.name } end
  table.sort(out, function(x, y) return x.name < y.name or (x.name == y.name and x.uid < y.uid) end)
  return out
end

function graph:mutationsFor(a, b)
  local out = {}
  for _, idx in ipairs(self.byParent[a] or {}) do
    local m = self.mutations[idx]
    if (m.a == a and m.b == b) or (m.a == b and m.b == a) then out[#out + 1] = m end
  end
  return out
end

function graph:isBase(uid)
  return (self.byResult[uid] == nil or #self.byResult[uid] == 0)
end

--- uids grouped by display name, for duplicate detection
function graph:namesInUse()
  local byName = {}
  for uid, e in pairs(self.species) do
    byName[e.name] = byName[e.name] or {}
    table.insert(byName[e.name], uid)
  end
  return byName
end

------------------------------------------------------------------------
-- planning
------------------------------------------------------------------------
local function defaultStepCost(m, opts)
  local chance = m.chance > 0 and m.chance or 0.5
  local cost = 1 + (100 / chance) * (opts.chanceWeight or 0.1)
  if opts.conditionCost then
    local extra = opts.conditionCost(m.conds, m)
    if extra == nil then return nil end
    cost = cost + extra
  end
  return cost
end

--- Cheapest way to obtain `target` (uid) from the species in `owned` (uid -> true).
--- Returns { target=, cost=, steps = { {result=, a=, b=, chance=, conds=, mutation=} ... } }
--- ordered so that every step's parents are owned or produced by an earlier step.
--- On failure returns nil, reason, blockers.
function graph:plan(target, owned, opts)
  opts = opts or {}
  owned = owned or {}
  if not self.species[target] then return nil, "unknown species '" .. tostring(target) .. "'" end
  if owned[target] and not opts.force then
    return { target = target, cost = 0, steps = {} }
  end

  local cost, best = {}, {}
  for uid in pairs(owned) do cost[uid] = 0 end

  local stepCost = {}
  for i, m in ipairs(self.mutations) do stepCost[i] = defaultStepCost(m, opts) end

  local changed, rounds = true, 0
  local maxRounds = util.count(self.species) + 2
  while changed and rounds < maxRounds do
    changed = false
    rounds = rounds + 1
    for i, m in ipairs(self.mutations) do
      local sc = stepCost[i]
      if sc and cost[m.a] and cost[m.b] then
        local c = cost[m.a] + cost[m.b] + sc
        if not owned[m.result] and (cost[m.result] == nil or c < cost[m.result] - 1e-9) then
          cost[m.result] = c
          best[m.result] = i
          changed = true
        end
      end
    end
  end

  if cost[target] == nil then
    return nil, "no breeding path to " .. self:nameOf(target), self:blockers(target, owned, stepCost)
  end

  local steps, seen = {}, {}
  local function expand(uid, depth)
    if owned[uid] or seen[uid] then return end
    if depth > 400 then error("plan: cycle while expanding " .. uid) end
    local idx = best[uid]
    if not idx then return end
    local m = self.mutations[idx]
    expand(m.a, depth + 1)
    expand(m.b, depth + 1)
    seen[uid] = true
    steps[#steps + 1] = {
      result = uid, a = m.a, b = m.b, chance = m.chance,
      conds = m.conds, raw = m.raw, mutation = idx, cost = stepCost[idx],
    }
  end
  expand(target, 0)
  return { target = target, cost = cost[target], steps = steps }
end

--- Why is `target` unreachable? Base species we do not own plus mutations
--- blocked by impossible conditions.
function graph:blockers(target, owned, stepCost)
  local seen, missingBase, blockedMut = {}, {}, {}
  local queue = { target }
  seen[target] = true
  while #queue > 0 do
    local uid = table.remove(queue, 1)
    if not owned[uid] then
      local muts = self.byResult[uid]
      if not muts or #muts == 0 then
        missingBase[#missingBase + 1] = uid
      else
        for _, idx in ipairs(muts) do
          local m = self.mutations[idx]
          if stepCost and stepCost[idx] == nil then
            blockedMut[#blockedMut + 1] = string.format("%s+%s->%s [%s]", self:nameOf(m.a), self:nameOf(m.b), self:nameOf(m.result), conditions.describeAll(m.conds))
          end
          for _, p in ipairs({ m.a, m.b }) do
            if not seen[p] then seen[p] = true; queue[#queue + 1] = p end
          end
        end
      end
    end
  end
  table.sort(missingBase)
  return { base = missingBase, blocked = blockedMut }
end

function graph:ancestors(target, limit)
  local seen, out = { [target] = true }, {}
  local queue = { target }
  while #queue > 0 and #out < (limit or 10000) do
    local uid = table.remove(queue, 1)
    for _, idx in ipairs(self.byResult[uid] or {}) do
      local m = self.mutations[idx]
      for _, p in ipairs({ m.a, m.b }) do
        if not seen[p] then seen[p] = true; out[#out + 1] = p; queue[#queue + 1] = p end
      end
    end
  end
  return out
end

function graph:stats()
  local st = { species = util.count(self.species), mutations = #self.mutations, kinds = {}, unknown = {}, duplicates = {} }
  local base = 0
  for uid in pairs(self.species) do if self:isBase(uid) then base = base + 1 end end
  st.baseSpecies = base
  for _, m in ipairs(self.mutations) do
    for _, c in ipairs(m.conds) do
      st.kinds[c.kind] = (st.kinds[c.kind] or 0) + 1
      if c.kind == "unknown" then st.unknown[c.raw] = (st.unknown[c.raw] or 0) + 1 end
    end
  end
  for name, uids in pairs(self:namesInUse()) do
    if #uids > 1 then st.duplicates[name] = uids end
  end
  return st
end

return graph
