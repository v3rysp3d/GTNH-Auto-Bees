-- bb.genome : helpers over the item stack tables OpenComputers returns for
-- Forestry bees (see OC ConverterIIndividual / ConverterIAlleles).
--
-- stack = {
--   name = "Forestry:beeDroneGE", label = "Forest Drone", size = 3,
--   individual = {
--     displayName = "Forest", isAnalyzed = true, isSecret = false, type = "bee",
--     canSpawn, generation, hasEffect, isAlive, isNatural,
--     active   = { species = {name="Forest", uid="forestry.speciesForest", temperature="Normal", humidity="Normal"},
--                  speed, lifespan, fertility, temperatureTolerance="BOTH_1", humidityTolerance,
--                  nocturnal, tolerantFlyer, caveDwelling, flowerProvider="flowersVanilla",
--                  flowering, effect, territory },
--     inactive = { ... same shape ... },
--   } }
-- active/inactive only exist for analyzed bees.
local genome = {}

local kinds = { princess = "Princess", drone = "Drone", queen = "Queen" }

-- exact item names; "Forestry:beeCombs" and friends are not bees
genome.itemNames = {
  ["Forestry:beePrincessGE"] = "princess",
  ["Forestry:beeDroneGE"] = "drone",
  ["Forestry:beeQueenGE"] = "queen",
}

function genome.isBee(stack)
  if type(stack) ~= "table" then return false end
  if genome.itemNames[tostring(stack.name or "")] then return true end
  return type(stack.individual) == "table" and stack.individual.type == "bee"
end

--- "princess" | "drone" | "queen" | nil
function genome.kind(stack)
  if not genome.isBee(stack) then return nil end
  local byName = genome.itemNames[tostring(stack.name or "")]
  if byName then return byName end
  local label = tostring(stack.label or "")
  for k, suffix in pairs(kinds) do if label:sub(-#suffix) == suffix then return k end end
  return nil
end

function genome.analyzed(stack)
  return genome.isBee(stack) and stack.individual ~= nil and stack.individual.isAnalyzed == true
end

--- Species name shown on the item (the active species), works unanalyzed.
function genome.displaySpecies(stack)
  if not genome.isBee(stack) then return nil end
  local ind = stack.individual
  if ind and ind.active and ind.active.species and ind.active.species.name then return ind.active.species.name end
  if ind and ind.displayName and ind.displayName ~= "" then return ind.displayName end
  local label = tostring(stack.label or "")
  for _, suffix in pairs(kinds) do
    if label:sub(-#suffix - 1) == " " .. suffix then return label:sub(1, -#suffix - 2) end
  end
  return label ~= "" and label or nil
end

local function speciesOf(side)
  return side and side.species and side.species.name or nil
end

function genome.active(stack)
  if not genome.analyzed(stack) then return nil end
  return speciesOf(stack.individual.active)
end

function genome.inactive(stack)
  if not genome.analyzed(stack) then return nil end
  return speciesOf(stack.individual.inactive)
end

function genome.hasSpecies(stack, name)
  if not genome.analyzed(stack) then return genome.displaySpecies(stack) == name end
  return genome.active(stack) == name or genome.inactive(stack) == name
end

function genome.isPure(stack, name)
  if not genome.analyzed(stack) then return false end
  return genome.active(stack) == name and genome.inactive(stack) == name
end

--- true when both species alleles are identical (any species)
function genome.isPureAny(stack)
  if not genome.analyzed(stack) then return false end
  local a, b = genome.active(stack), genome.inactive(stack)
  return a ~= nil and a == b
end

function genome.speciesClimate(stack)
  if not genome.analyzed(stack) then return nil end
  local sp = stack.individual.active.species
  return sp.temperature, sp.humidity
end

function genome.tolerances(stack)
  if not genome.analyzed(stack) then return nil end
  local a = stack.individual.active
  return a.temperatureTolerance, a.humidityTolerance
end

function genome.trait(stack, key)
  if not genome.analyzed(stack) then return nil end
  return stack.individual.active[key], stack.individual.inactive[key]
end

function genome.flowerType(stack)
  if not genome.analyzed(stack) then return nil end
  return stack.individual.active.flowerProvider
end

function genome.effect(stack)
  if not genome.analyzed(stack) then return nil end
  return stack.individual.active.effect, stack.individual.inactive.effect
end

--- Compact summary used in network messages and logs.
function genome.summary(stack)
  if not genome.isBee(stack) then return nil end
  local s = {
    kind = genome.kind(stack),
    size = stack.size or 1,
    label = stack.label,
    analyzed = genome.analyzed(stack),
    species = genome.displaySpecies(stack),
  }
  if s.analyzed then
    s.active = genome.active(stack)
    s.inactive = genome.inactive(stack)
    s.pure = (s.active == s.inactive)
    local a = stack.individual.active
    s.fertility = a.fertility
    s.lifespan = a.lifespan
    s.effect = a.effect
    s.flower = a.flowerProvider
    s.temperature = a.species and a.species.temperature
    s.humidity = a.species and a.species.humidity
    s.tempTol = a.temperatureTolerance
    s.humTol = a.humidityTolerance
    s.natural = stack.individual.isNatural
  end
  return s
end

function genome.describe(stack)
  local s = genome.summary(stack)
  if not s then return tostring(stack and stack.label or "?") end
  if not s.analyzed then return string.format("%s %s (unanalyzed) x%d", s.species or "?", s.kind or "?", s.size) end
  return string.format("%s/%s %s x%d", s.active, s.inactive, s.kind or "?", s.size)
end

return genome
