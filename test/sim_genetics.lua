-- A tiny Forestry-like genetics model for the tests. Deterministic RNG.
-- Species are identified by uid ("forestry.species<Name>") like in the game;
-- display names are the plain names.
local sim = {}

sim.dominant = { Forest = true, Meadows = true, Common = true, Cultivated = false, Noble = false }

--- mutations may carry `foundation` (block label) and `temperature` ("Hot")
sim.mutations = {
  { a = "Forest", b = "Meadows", result = "Common", chance = 15 },
  { a = "Common", b = "Forest", result = "Cultivated", chance = 12 },
  { a = "Cultivated", b = "Common", result = "Noble", chance = 20, foundation = "Block of Gold" },
}

function sim.uid(name) return "forestry.species" .. name end

function sim.rng(seed)
  local v = seed or 1
  return function()
    v = (v * 1103515245 + 12345) % 2147483648
    return v / 2147483648
  end
end

local function activeOf(a, b)
  if a ~= b and sim.dominant[b] and not sim.dominant[a] then return b, a end
  return a, b
end

function sim.mkBee(kind, a1, a2, analyzed)
  local a, b = a1, a2 or a1
  local active, inactive = activeOf(a, b)
  local kindName = kind == "princess" and "Princess" or (kind == "queen" and "Queen" or "Drone")
  local st = {
    name = "Forestry:bee" .. kindName .. "GE", label = active .. " " .. kindName, size = 1,
    individual = { type = "bee", isAnalyzed = false, displayName = active, isNatural = true },
  }
  st._a, st._b = a, b
  if analyzed then sim.analyze(st) end
  return st
end

--- Drones a queen of a species makes per cycle; 2 unless a test says
--- otherwise. Some real bees have 1, which means a line cannot grow.
sim.fertility = {}

function sim.fertilityOf(species)
  return sim.fertility[species] or 2
end

function sim.analyze(st)
  if st.individual.isAnalyzed then return end
  local active, inactive = activeOf(st._a, st._b)
  st.individual.isAnalyzed = true
  st.individual.active = { species = { name = active, uid = sim.uid(active), temperature = "Normal", humidity = "Normal" },
    fertility = sim.fertilityOf(active), temperatureTolerance = "BOTH_2" }
  st.individual.inactive = { species = { name = inactive, uid = sim.uid(inactive) },
    fertility = sim.fertilityOf(inactive) }
end

---One offspring of princess p and drone d. `conditions(m)` decides whether
---mutation m can fire in the current housing.
function sim.offspring(kind, p, d, rng, conditions)
  local pa = rng() < 0.5 and p._a or p._b
  local da = rng() < 0.5 and d._a or d._b
  for _, m in ipairs(sim.mutations) do
    if (m.a == pa and m.b == da) or (m.a == da and m.b == pa) then
      if (conditions == nil or conditions(m)) and rng() * 100 < m.chance then
        return sim.mkBee(kind, m.result, m.result, false)
      end
    end
  end
  return sim.mkBee(kind, pa, da, false)
end

local function conds(m)
  local out = {}
  if m.foundation then out[#out + 1] = "Requires " .. m.foundation .. " as a foundation." end
  if m.temperature then out[#out + 1] = "Requires " .. m.temperature .. " temperature." end
  return out
end

---Breeding data in the shape bee_housing.getBeeBreedingData() returns (names only).
function sim.breedingData()
  local out = {}
  for _, m in ipairs(sim.mutations) do
    out[#out + 1] = { allele1 = m.a, allele2 = m.b, result = m.result, chance = m.chance, specialConditions = conds(m) }
  end
  return out
end

---Mutation list in the shape the survey builds from getBeeParents (with uids).
function sim.parentsData()
  local out = {}
  for _, m in ipairs(sim.mutations) do
    out[#out + 1] = {
      result = { name = m.result, uid = sim.uid(m.result) },
      allele1 = { name = m.a, uid = sim.uid(m.a) }, allele2 = { name = m.b, uid = sim.uid(m.b) },
      chance = m.chance, specialConditions = conds(m),
    }
  end
  return out
end

---A breeder job for the simulator: names become uids + a names map.
function sim.job(fields)
  local job = {}
  for k, v in pairs(fields) do job[k] = v end
  job.names = {}
  for _, k in ipairs({ "target", "a", "b" }) do
    if job[k] then
      job.names[sim.uid(job[k])] = job[k]
      job[k] = sim.uid(job[k])
    end
  end
  return job
end

return sim
