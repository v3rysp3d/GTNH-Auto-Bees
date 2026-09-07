-- bb.graph : the mutation graph and the breeding planner.
--
-- Built from bee_housing.getBeeBreedingData():
--   { allele1 = "Forest", allele2 = "Meadows", result = "Common",
--     chance = 15, specialConditions = { "Requires ..." } }
-- Species are keyed by display name, the same string found in
-- stack.individual.active.species.name.
local util = require("src.util")
local conditions = require("src.conditions")

local graph = {}
graph.__index = graph

function graph.new()
  return setmetatable({
    mutations = {},   -- list of { a, b, result, chance, conds, raw }
    byResult = {},    -- result name -> list of mutation indexes
    byParent = {},    -- parent name -> list of mutation indexes
    species = {},     -- name -> { name=, uid= }
  }, graph)
end

function graph:addSpecies(name, uid)
  if not name or name == "" then return end
  local e = self.species[name]
  if not e then
    e = { name = name }
    self.species[name] = e
  end
  if uid and uid ~= "" then e.uid = uid end
  return e
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
  self:addSpecies(m.a); self:addSpecies(m.b); self:addSpecies(m.result)
  return entry
end

--- Build from the raw component output.
--- breedingData: array from getBeeBreedingData()
--- speciesList : array from listAllSpecies() (each { name=, uid= }) or nil
function graph.fromBreedingData(breedingData, speciesList)
  local g = graph.new()
  for _, sp in ipairs(speciesList or {}) do
    if type(sp) == "table" then g:addSpecies(sp.name, sp.uid) end
  end
  for _, m in ipairs(breedingData or {}) do
    if type(m) == "table" then
      local raw = {}
      for _, s in ipairs(m.specialConditions or {}) do raw[#raw + 1] = tostring(s) end
      g:addMutation({ a = m.allele1, b = m.allele2, result = m.result, chance = m.chance, raw = raw })
    end
  end
  return g
end

function graph:toTable()
  local muts = {}
  for i, m in ipairs(self.mutations) do
    muts[i] = { a = m.a, b = m.b, result = m.result, chance = m.chance, raw = m.raw }
  end
  return { mutations = muts, species = self.species }
end

function graph.fromTable(t)
  local g = graph.new()
  for name, e in pairs(t.species or {}) do g:addSpecies(name, e.uid) end
  for _, m in ipairs(t.mutations or {}) do g:addMutation(m) end
  return g
end

function graph:speciesList()
  local out = {}
  for _, e in pairs(self.species) do out[#out + 1] = { name = e.name, uid = e.uid } end
  table.sort(out, function(x, y) return x.name < y.name end)
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

function graph:isBase(name)
  return (self.byResult[name] == nil or #self.byResult[name] == 0)
end

------------------------------------------------------------------------
-- planning
------------------------------------------------------------------------
--- Default step cost: cheap high-chance mutations first.
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

--- Compute the cheapest way to obtain `target` from the species in `owned`
--- (a set: name -> true). Returns a plan:
--- { target=, cost=, steps = { {result=, a=, b=, chance=, conds=, mutation=} ... } }
--- ordered so that every step's parents are owned or produced by an earlier step.
--- On failure returns nil, reason, blockers (list of species names).
function graph:plan(target, owned, opts)
  opts = opts or {}
  owned = owned or {}
  if not self.species[target] then return nil, "unknown species '" .. tostring(target) .. "'" end
  if owned[target] and not opts.force then
    return { target = target, cost = 0, steps = {} }
  end

  local cost, best = {}, {}
  for name in pairs(owned) do cost[name] = 0 end

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
        -- a species we already own is never re-bred
        if not owned[m.result] and (cost[m.result] == nil or c < cost[m.result] - 1e-9) then
          cost[m.result] = c
          best[m.result] = i
          changed = true
        end
      end
    end
  end

  if cost[target] == nil then
    return nil, "no breeding path to " .. target, self:blockers(target, owned, stepCost)
  end

  -- expand the tree into an ordered, de-duplicated step list
  local steps, seen = {}, {}
  local function expand(name, depth)
    if owned[name] or seen[name] then return end
    if depth > 400 then error("plan: cycle while expanding " .. name) end
    local idx = best[name]
    if not idx then return end
    local m = self.mutations[idx]
    expand(m.a, depth + 1)
    expand(m.b, depth + 1)
    seen[name] = true
    steps[#steps + 1] = {
      result = name, a = m.a, b = m.b, chance = m.chance,
      conds = m.conds, raw = m.raw, mutation = idx, cost = stepCost[idx],
    }
  end
  expand(target, 0)
  return { target = target, cost = cost[target], steps = steps }
end

--- Why is `target` unreachable? Walks backwards and reports base species
--- we do not own plus mutations blocked by impossible conditions.
function graph:blockers(target, owned, stepCost)
  local seen, missingBase, blockedMut = {}, {}, {}
  local queue = { target }
  seen[target] = true
  while #queue > 0 do
    local name = table.remove(queue, 1)
    if not owned[name] then
      local muts = self.byResult[name]
      if not muts or #muts == 0 then
        missingBase[#missingBase + 1] = name
      else
        for _, idx in ipairs(muts) do
          local m = self.mutations[idx]
          if stepCost and stepCost[idx] == nil then
            blockedMut[#blockedMut + 1] = string.format("%s+%s->%s [%s]", m.a, m.b, m.result, conditions.describeAll(m.conds))
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

--- All species that appear anywhere upstream of `target` (for display).
function graph:ancestors(target, limit)
  local seen, out = { [target] = true }, {}
  local queue = { target }
  while #queue > 0 and #out < (limit or 10000) do
    local name = table.remove(queue, 1)
    for _, idx in ipairs(self.byResult[name] or {}) do
      local m = self.mutations[idx]
      for _, p in ipairs({ m.a, m.b }) do
        if not seen[p] then seen[p] = true; out[#out + 1] = p; queue[#queue + 1] = p end
      end
    end
  end
  return out
end

--- Statistics for the survey report.
function graph:stats()
  local st = { species = util.count(self.species), mutations = #self.mutations, kinds = {}, unknown = {} }
  local base = 0
  for name in pairs(self.species) do if self:isBase(name) then base = base + 1 end end
  st.baseSpecies = base
  for _, m in ipairs(self.mutations) do
    for _, c in ipairs(m.conds) do
      st.kinds[c.kind] = (st.kinds[c.kind] or 0) + 1
      if c.kind == "unknown" then st.unknown[c.raw] = (st.unknown[c.raw] or 0) + 1 end
    end
  end
  return st
end

return graph
