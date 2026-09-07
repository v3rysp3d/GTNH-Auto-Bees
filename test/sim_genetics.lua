-- A tiny Forestry-like genetics model for the tests. Deterministic RNG.
local sim = {}

sim.dominant = { Forest = true, Meadows = true, Common = true, Cultivated = false, Noble = false }

--- mutations may carry `foundation` (block label) and `temperature` ("Hot")
sim.mutations = {
  { a = "Forest", b = "Meadows", result = "Common", chance = 15 },
  { a = "Common", b = "Forest", result = "Cultivated", chance = 12 },
}

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

function sim.analyze(st)
  if st.individual.isAnalyzed then return end
  local active, inactive = activeOf(st._a, st._b)
  st.individual.isAnalyzed = true
  st.individual.active = { species = { name = active, temperature = "Normal", humidity = "Normal" }, fertility = 2, temperatureTolerance = "BOTH_2" }
  st.individual.inactive = { species = { name = inactive }, fertility = 2 }
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

---Breeding data in the shape bee_housing.getBeeBreedingData() returns.
function sim.breedingData()
  local out = {}
  for _, m in ipairs(sim.mutations) do
    local conds = {}
    if m.foundation then conds[#conds + 1] = "Requires " .. m.foundation .. " as a foundation." end
    if m.temperature then conds[#conds + 1] = "Requires " .. m.temperature .. " temperature." end
    out[#out + 1] = { allele1 = m.a, allele2 = m.b, result = m.result, chance = m.chance, specialConditions = conds }
  end
  return out
end

return sim
