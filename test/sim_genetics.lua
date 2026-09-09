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

function sim.mkBee(kind, a1, a2, analyzed, fa, fb)
  local a, b = a1, a2 or a1
  local active, inactive = activeOf(a, b)
  local kindName = kind == "princess" and "Princess" or (kind == "queen" and "Queen" or "Drone")
  local st = {
    name = "Forestry:bee" .. kindName .. "GE", label = active .. " " .. kindName, size = 1,
    individual = { type = "bee", isAnalyzed = false, displayName = active, isNatural = true },
  }
  st._a, st._b = a, b
  -- fertility is an allele of its own, inherited independently of species;
  -- a bee from a hive carries its species' default twice
  st._fa = fa or sim.fertilityOf(a)
  st._fb = fb or sim.fertilityOf(b)
  if analyzed then sim.analyze(st) end
  return st
end

--- Drones a queen of a species makes per cycle; 2 unless a test says
--- otherwise. Some real bees have 1, which means a line cannot grow.
sim.fertility = {}

local traitRng = nil
local function traitRoll()
  traitRng = traitRng or sim.rng(4242)
  return traitRng()
end

--- What a queen actually expresses, which is how many drones she makes.
function sim.expressed(bee)
  local fa = bee._fa or sim.fertilityOf(bee._a)
  local fb = bee._fb or sim.fertilityOf(bee._b)
  return math.max(fa, fb)
end

function sim.fertilityOf(species)
  return sim.fertility[species] or 2
end

function sim.analyze(st)
  if st.individual.isAnalyzed then return end
  local active, inactive = activeOf(st._a, st._b)
  st.individual.isAnalyzed = true
  local fa, fb = st._fa or sim.fertilityOf(st._a), st._fb or sim.fertilityOf(st._b)
  local hi, lo = math.max(fa, fb), math.min(fa, fb)   -- the better allele shows
  st.individual.active = { species = { name = active, uid = sim.uid(active), temperature = "Normal", humidity = "Normal" },
    fertility = hi, temperatureTolerance = "BOTH_2" }
  -- both sides of every chromosome, as the real converter reports them
  st.individual.inactive = { species = { name = inactive, uid = sim.uid(inactive) }, fertility = lo,
    temperatureTolerance = "BOTH_2" }
end

---One offspring of princess p and drone d. `conditions(m)` decides whether
---mutation m can fire in the current housing.
function sim.offspring(kind, p, d, rng, conditions)
  local pa = rng() < 0.5 and p._a or p._b
  local da = rng() < 0.5 and d._a or d._b
  -- One fertility allele from each parent. Drawn from a stream of its own so
  -- that adding trait genetics does not shift which species a test rolls.
  local pf = traitRoll() < 0.5 and (p._fa or sim.fertilityOf(p._a)) or (p._fb or sim.fertilityOf(p._b))
  local df = traitRoll() < 0.5 and (d._fa or sim.fertilityOf(d._a)) or (d._fb or sim.fertilityOf(d._b))
  for _, m in ipairs(sim.mutations) do
    if (m.a == pa and m.b == da) or (m.a == da and m.b == pa) then
      if (conditions == nil or conditions(m)) and rng() * 100 < m.chance then
        return sim.mkBee(kind, m.result, m.result, false, pf, df)
      end
    end
  end
  return sim.mkBee(kind, pa, da, false, pf, df)
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
