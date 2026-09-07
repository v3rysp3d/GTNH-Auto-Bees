-- Simulated Forestry genetics + a fake cell, driving bb.breeder end to end.
local breeder = require("bb.breeder")
local genome = require("bb.genome")
local util = require("bb.util")

------------------------------------------------------------------------
-- tiny genetics model
------------------------------------------------------------------------
local dominant = { Forest = true, Meadows = true, Common = true, Cultivated = false, Noble = false }
local mutations = {
  { a = "Forest", b = "Meadows", result = "Common", chance = 15 },
  { a = "Common", b = "Forest", result = "Cultivated", chance = 12 },
}

local function mkBee(kind, a1, a2, analyzed)
  local a, b = a1, a2 or a1
  local active, inactive = a, b
  if a ~= b then
    if dominant[b] and not dominant[a] then active, inactive = b, a end
  end
  local kindName = kind == "princess" and "Princess" or (kind == "queen" and "Queen" or "Drone")
  local st = {
    name = "Forestry:bee" .. kindName .. "GE", label = active .. " " .. kindName, size = 1,
    individual = { type = "bee", isAnalyzed = analyzed and true or false, displayName = active, isNatural = true },
  }
  st._a, st._b = a, b
  if analyzed then
    st.individual.active = { species = { name = active, temperature = "Normal", humidity = "Normal" }, fertility = 2, temperatureTolerance = "NONE" }
    st.individual.inactive = { species = { name = inactive }, fertility = 2 }
  end
  return st
end

local function analyzeStack(st)
  if st.individual.isAnalyzed then return end
  local a, b = st._a, st._b
  local active, inactive = a, b
  if a ~= b and dominant[b] and not dominant[a] then active, inactive = b, a end
  st.individual.isAnalyzed = true
  st.individual.active = { species = { name = active, temperature = "Normal", humidity = "Normal" }, fertility = 2, temperatureTolerance = "NONE" }
  st.individual.inactive = { species = { name = inactive }, fertility = 2 }
end

local function offspring(kind, p, d, rng)
  local pa = rng() < 0.5 and p._a or p._b
  local da = rng() < 0.5 and d._a or d._b
  for _, m in ipairs(mutations) do
    if (m.a == pa and m.b == da) or (m.a == da and m.b == pa) then
      if rng() * 100 < m.chance then return mkBee(kind, m.result, m.result, false) end
    end
  end
  return mkBee(kind, pa, da, false)
end

------------------------------------------------------------------------
-- fake cell
------------------------------------------------------------------------
local function makeCell(library, seed)
  local seedVal = seed or 1
  local function rng()
    seedVal = (seedVal * 1103515245 + 12345) % 2147483648
    return seedVal / 2147483648
  end
  local inv = {}            -- slot -> stack
  local housing = { queen = nil, drone = nil }
  local archived = {}       -- list of stacks
  local discarded = 0
  local events = {}
  local cell = {}
  local nextSlot = 3

  local function freeSlot()
    for s = 3, 40 do if inv[s] == nil then return s end end
    error("simulated inventory full")
  end

  function cell.listBees()
    local out = {}
    for s = 3, 40 do if inv[s] then out[#out + 1] = { slot = s, stack = inv[s] } end end
    return out
  end
  function cell.read(slot) return inv[slot] end
  function cell.analyze(slot)
    if not inv[slot] then return false, "empty" end
    analyzeStack(inv[slot])
    return true
  end
  function cell.fetch(species, kind, n)
    -- biggest matching stack first, like the ME network would hand out
    local bestI, bestSize = nil, -1
    for i, st in ipairs(library) do
      if genome.kind(st) == kind and (species == nil or (st._a == species and st._b == species)) then
        if (st.size or 1) > bestSize then bestI, bestSize = i, (st.size or 1) end
      end
    end
    if bestI then
      local st = table.remove(library, bestI)
      local slot = freeSlot()
      inv[slot] = st
      return slot
    end
    return nil, "library lacks " .. tostring(species) .. " " .. kind
  end
  function cell.insertQueen(slot)
    local st = inv[slot]
    if not st or genome.kind(st) ~= "princess" then return false, "not a princess" end
    inv[slot], housing.queen = housing.queen, st
    return true
  end
  function cell.insertDrone(slot)
    local st = inv[slot]
    if not st or genome.kind(st) ~= "drone" then return false, "not a drone" end
    inv[slot], housing.drone = housing.drone, st
    return true
  end
  function cell.takeDrone()
    if not housing.drone then return nil end
    local slot = freeSlot()
    inv[slot], housing.drone = housing.drone, nil
    return slot
  end
  function cell.housingDrone() return housing.drone end
  local outputs = {}
  function cell.waitCycle()
    if not housing.queen then return "notstarted", "no queen" end
    if not housing.drone then return "notstarted", "no drone" end
    local p, d = housing.queen, housing.drone
    d.size = d.size - 1
    if d.size <= 0 then housing.drone = nil end
    -- offspring: 1 princess + fertility(2) drones
    outputs[#outputs + 1] = offspring("princess", p, d, rng)
    for _ = 1, 2 do outputs[#outputs + 1] = offspring("drone", p, d, rng) end
    housing.queen = nil
    return "done"
  end
  function cell.collect()
    local n = #outputs
    for _, st in ipairs(outputs) do inv[freeSlot()] = st end
    outputs = {}
    return n
  end
  function cell.archive(slot, n)
    local st = inv[slot]
    if not st then return false end
    archived[#archived + 1] = st
    library[#library + 1] = st   -- archived bees are fetchable again, as in ME
    inv[slot] = nil
    return true
  end
  function cell.discard(slot) discarded = discarded + 1; inv[slot] = nil; return true end
  function cell.setFoundation(block) cell.foundation = block; return true end
  function cell.setClimate(c) cell.climate = c; return true end
  function cell.event(kind, data) events[#events + 1] = { kind = kind, data = data } end
  function cell.cancelled() return false end
  cell._archived = archived
  cell._events = events
  cell._inv = inv
  cell._discardedCount = function() return discarded end
  return cell
end

local function library(spec)
  local lib = {}
  for _, e in ipairs(spec) do
    for _ = 1, e.n or 1 do
      local st = mkBee(e.kind, e.species, e.species, e.analyzed ~= false)
      if e.kind == "drone" then st.size = 16 end
      lib[#lib + 1] = st
    end
  end
  return lib
end

T.run("breeder: Forest+Meadows -> Common with princess of A", function()
  local lib = library({ { kind = "princess", species = "Forest" }, { kind = "drone", species = "Meadows", n = 1 }, { kind = "drone", species = "Forest", n = 1 } })
  local cell = makeCell(lib, 7)
  local res = breeder.run(cell, { id = "t1", target = "Common", a = "Forest", b = "Meadows", chance = 15, keepDrones = 4, droneSupply = 16, maxGenerations = 300 })
  T.ok(res.ok, "job ok: " .. tostring(res.reason))
  T.ok(res.princess, "princess produced")
  T.ok(res.archivedDrones >= 4, "archived >= keep (" .. tostring(res.archivedDrones) .. ")")
  T.ok(res.generations < 150, "finished in a sane number of generations: " .. res.generations)
  local pureCommonPrincess, pureCommonDrones = 0, 0
  for _, st in ipairs(cell._archived) do
    if genome.kind(st) == "princess" and genome.isPure(st, "Common") then pureCommonPrincess = pureCommonPrincess + 1 end
    if genome.kind(st) == "drone" and genome.isPure(st, "Common") then pureCommonDrones = pureCommonDrones + (st.size or 1) end
  end
  T.eq(pureCommonPrincess, 1, "one pure Common princess archived")
  T.ok(pureCommonDrones >= 4, "pure Common drones archived")
  for _, st in ipairs(cell._archived) do T.ok(genome.isPureAny(st), "only pure bees archived: " .. genome.describe(st)) end
  local phases = {}
  for _, e in ipairs(cell._events) do if e.kind == "phase" then phases[#phases + 1] = e.data.to end end
  T.ok(util.contains(phases, "mutate") and util.contains(phases, "stockpile"), "phases seen: " .. table.concat(phases, ","))
end)

T.run("breeder: princess of parent B mates straight with A drones", function()
  local lib = library({ { kind = "princess", species = "Meadows" }, { kind = "drone", species = "Forest", n = 1 }, { kind = "drone", species = "Meadows", n = 1 } })
  local cell = makeCell(lib, 99)
  local res = breeder.run(cell, { id = "t2", target = "Common", a = "Forest", b = "Meadows", chance = 15, keepDrones = 2, droneSupply = 16, maxGenerations = 300 })
  T.ok(res.ok, "t2 job ok: " .. tostring(res.reason))
  local phases = {}
  for _, e in ipairs(cell._events) do if e.kind == "phase" then phases[#phases + 1] = e.data.to end end
  T.eq(phases[1], "mutate", "a princess carrying either parent goes straight to mutate")
end)

T.run("breeder: foreign princess is converted first", function()
  local lib = library({ { kind = "princess", species = "Noble" }, { kind = "drone", species = "Forest", n = 2 }, { kind = "drone", species = "Meadows", n = 2 } })
  local cell = makeCell(lib, 5)
  local res = breeder.run(cell, { id = "t2b", target = "Common", a = "Forest", b = "Meadows", chance = 15, keepDrones = 2, droneSupply = 16, maxGenerations = 300 })
  T.ok(res.ok, "t2b job ok: " .. tostring(res.reason))
  local phases = {}
  for _, e in ipairs(cell._events) do if e.kind == "phase" then phases[#phases + 1] = e.data.to end end
  T.eq(phases[1], "convert", "a princess of an unrelated species is converted first")
end)

T.run("breeder: stockpile only", function()
  local lib = library({ { kind = "princess", species = "Common" }, { kind = "drone", species = "Common", n = 1 } })
  local cell = makeCell(lib, 5)
  local res = breeder.run(cell, { id = "t3", target = "Common", a = "Common", b = "Common", keepDrones = 10, droneSupply = 16, maxGenerations = 100 })
  T.ok(res.ok, "stockpile ok: " .. tostring(res.reason))
  T.ok(res.archivedDrones >= 10, "10 drones stockpiled: " .. res.archivedDrones)
  T.ok(res.generations <= 12, "stockpile is quick: " .. res.generations)
end)

T.run("breeder: missing library stock fails cleanly", function()
  local cell = makeCell(library({ { kind = "princess", species = "Forest" } }), 1)
  local res = breeder.run(cell, { id = "t4", target = "Common", a = "Forest", b = "Meadows", keepDrones = 1 })
  T.ok(not res.ok and res.reason:match("Meadows"), "reports the missing species: " .. tostring(res.reason))
end)
