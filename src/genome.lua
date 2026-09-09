-- Helpers over the item stack tables OpenComputers returns for Forestry
-- bees (see OC ConverterIIndividual / ConverterIAlleles).
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
--
-- Species are identified by their allele uid everywhere in this program;
-- several mods reuse display names (Diamond, Ruby, Certus ...). Unanalyzed
-- bees only reveal their display name, so name-based helpers exist for the
-- prescreen.
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

--- uid of the species allele on one side of the genome (name when the uid is missing)
local function uidOf(side)
  if not side or not side.species then return nil end
  return side.species.uid or side.species.name
end

local function nameOf(side)
  if not side or not side.species then return nil end
  return side.species.name or side.species.uid
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

--- active / inactive species uid (analyzed bees only)
function genome.active(stack)
  if not genome.analyzed(stack) then return nil end
  return uidOf(stack.individual.active)
end

function genome.inactive(stack)
  if not genome.analyzed(stack) then return nil end
  return uidOf(stack.individual.inactive)
end

function genome.activeName(stack)
  if not genome.analyzed(stack) then return genome.displaySpecies(stack) end
  return nameOf(stack.individual.active)
end

function genome.inactiveName(stack)
  if not genome.analyzed(stack) then return nil end
  return nameOf(stack.individual.inactive)
end

--- Does the bee carry species `uid` on either allele? For an unanalyzed bee
--- only the display name is known, so pass `name` to compare against that.
function genome.hasSpecies(stack, uid, name)
  if not genome.analyzed(stack) then
    return name ~= nil and genome.displaySpecies(stack) == name
  end
  return genome.active(stack) == uid or genome.inactive(stack) == uid
end

function genome.isPure(stack, uid)
  if not genome.analyzed(stack) then return false end
  return genome.active(stack) == uid and genome.inactive(stack) == uid
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

--- Drones a queen of this bee produces per cycle. One of them is spent on
--- the next mating, so a line with fertility 1 can never grow.
function genome.fertility(stack)
  if not genome.analyzed(stack) then return nil end
  return tonumber(stack.individual.active.fertility)
end

--- Both fertility alleles: what she expresses, and what she carries. A line
--- breeds true for fertility only when both are at the wanted value.
function genome.fertilityPair(stack)
  if not genome.analyzed(stack) then return nil, nil end
  return tonumber(stack.individual.active.fertility), tonumber(stack.individual.inactive.fertility)
end

--- The chromosomes a bee carries, in the order Forestry lists them.
genome.alleleKeys = { "species", "speed", "lifespan", "fertility", "temperatureTolerance",
  "humidityTolerance", "nocturnal", "tolerantFlyer", "caveDwelling", "flowerProvider",
  "flowering", "effect", "territory" }

local function canon(v)
  local t = type(v)
  if t == "nil" then return "-" end
  if t == "table" then
    if v.uid then return tostring(v.uid) end
    if v.name then return tostring(v.name) end
    local parts = {}
    for i = 1, #v do parts[#parts + 1] = tostring(v[i]) end
    return table.concat(parts, ",")
  end
  return tostring(v)
end

--- Two bees stack only when every allele matches, which is what players mean
--- by a pure bee: one whose drones pile into a single stack. Species purity
--- alone is not enough, since two Common drones differing in fertility or
--- speed sit in separate stacks and breed unlike offspring.
function genome.fingerprint(stack)
  if not genome.analyzed(stack) then return nil end
  local a, i = stack.individual.active, stack.individual.inactive
  local parts = {}
  for _, key in ipairs(genome.alleleKeys) do
    parts[#parts + 1] = canon(a[key]) .. "/" .. canon(i[key])
  end
  return table.concat(parts, "|")
end

--- Both alleles equal on every chromosome: such a bee breeds true, and its
--- drones stack with each other.
function genome.isHomozygous(stack)
  if not genome.analyzed(stack) then return false end
  local a, i = stack.individual.active, stack.individual.inactive
  for _, key in ipairs(genome.alleleKeys) do
    -- a chromosome the converter did not report on both sides tells us
    -- nothing, so it is not held against the bee
    if a[key] ~= nil and i[key] ~= nil and canon(a[key]) ~= canon(i[key]) then return false end
  end
  return true
end

----------------------------------------------------------------------
-- trait quality
--
-- Two bees of the same species are not equally good: production speed,
-- fertility, working at night, in the rain and without a view of the sky all
-- make a hive worth more, and a few effects are worth avoiding. Alleles come
-- back as names ("Fastest", "forestry.speedFastest"), so they are matched by
-- substring and ranked.
----------------------------------------------------------------------
genome.speedRank = { slowest = 1, slower = 2, slow = 3, normal = 4, fast = 5, faster = 6, fastest = 7, blinding = 8 }
genome.lifespanRank = { shortest = 1, shorter = 2, short = 3, shortened = 4, normal = 5,
  long = 6, elongated = 7, longer = 8, longest = 9 }
genome.effectRank = {
  radioactive = -6, ignition = -4, explorer = -1, aggressive = -3, misanthrope = -3, glacial = -3,
  none = 0, beatific = 2, fertile = 3, heroic = 3, exploration = 2, snowing = 1, creeper = -2,
}

--- Pristine stock, which Forestry marks natural. Ignoble bees can be lost
--- when they breed, so a pristine one is the better bee to work with.
function genome.isPristine(stack)
  if not genome.isBee(stack) then return false end
  return stack.individual.isNatural == true
end

genome.traitWeights = {
  pristine = 3,     -- pristine rather than ignoble
  speed = 3,        -- faster production
  fertility = 4,    -- more drones per cycle, and a line that can grow
  lifespan = -1,    -- shorter lives mean quicker generations
  nocturnal = 2,    -- works at night
  tolerantFlyer = 2,-- works in the rain
  caveDwelling = 2, -- works underground
  effect = 2,
}

local function rankOf(ranks, value, default)
  if value == nil then return default or 0 end
  local text = tostring(value):lower()
  local bestKey, bestRank
  for key, rank in pairs(ranks) do
    -- the longest match wins, so "slowest" is not read as "slow"
    if text:find(key, 1, true) and (bestKey == nil or #key > #bestKey) then
      bestKey, bestRank = key, rank
    end
  end
  if bestRank == nil then return default or 0 end
  return bestRank
end

---A number for how good this bee's expressed traits are. Higher is better.
function genome.quality(stack, weights)
  if not genome.analyzed(stack) then return 0 end
  local a = stack.individual.active
  local w = weights or genome.traitWeights
  local score = 0
  score = score + (w.speed or 0) * rankOf(genome.speedRank, a.speed, 4)
  score = score + (w.fertility or 0) * (tonumber(a.fertility) or 2)
  score = score + (w.lifespan or 0) * rankOf(genome.lifespanRank, a.lifespan, 5)
  if a.nocturnal then score = score + (w.nocturnal or 0) end
  if a.tolerantFlyer then score = score + (w.tolerantFlyer or 0) end
  if a.caveDwelling then score = score + (w.caveDwelling or 0) end
  score = score + (w.effect or 0) * rankOf(genome.effectRank, a.effect, 0)
  if genome.isPristine(stack) then score = score + (w.pristine or 0) end
  return score
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
    s.activeName = genome.activeName(stack)
    s.inactiveName = genome.inactiveName(stack)
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
  return string.format("%s/%s %s x%d", s.activeName, s.inactiveName, s.kind or "?", s.size)
end

return genome
