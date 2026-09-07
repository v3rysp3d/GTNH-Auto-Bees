-- Simulated Forestry genetics + a fake cell, driving src.breeder end to end.
local breeder = require("src.breeder")
local genome = require("src.genome")
local util = require("src.util")
local sim = require("sim_genetics")

local U = sim.uid

------------------------------------------------------------------------
-- fake cell
------------------------------------------------------------------------
local function makeCell(library, seed)
  local rng = sim.rng(seed)
  local inv = {}            -- slot -> stack
  local housing = { queen = nil, drone = nil }
  local archived = {}       -- list of stacks
  local discarded = 0
  local events = {}
  local cell = {}

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
    sim.analyze(inv[slot])
    return true
  end
  function cell.fetch(uid, kind, n, name)
    -- biggest matching stack first, like the ME network would hand out
    local bestI, bestSize = nil, -1
    for i, st in ipairs(library) do
      if genome.kind(st) == kind and (uid == nil or (U(st._a) == uid and U(st._b) == uid)) then
        if (st.size or 1) > bestSize then bestI, bestSize = i, (st.size or 1) end
      end
    end
    if bestI then
      local st = table.remove(library, bestI)
      local slot = freeSlot()
      inv[slot] = st
      return slot
    end
    return nil, "library lacks " .. tostring(name or uid) .. " " .. kind
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
    outputs[#outputs + 1] = sim.offspring("princess", p, d, rng)
    for _ = 1, 2 do outputs[#outputs + 1] = sim.offspring("drone", p, d, rng) end
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
      local st = sim.mkBee(e.kind, e.species, e.species, e.analyzed ~= false)
      if e.kind == "drone" then st.size = 16 end
      lib[#lib + 1] = st
    end
  end
  return lib
end

local function phasesOf(cell)
  local phases = {}
  for _, e in ipairs(cell._events) do if e.kind == "phase" then phases[#phases + 1] = e.data.to end end
  return phases
end

T.run("breeder: Forest+Meadows -> Common with princess of A", function()
  local lib = library({ { kind = "princess", species = "Forest" }, { kind = "drone", species = "Meadows", n = 1 }, { kind = "drone", species = "Forest", n = 1 } })
  local cell = makeCell(lib, 7)
  local res = breeder.run(cell, sim.job({ id = "t1", target = "Common", a = "Forest", b = "Meadows", chance = 15, keepDrones = 4, droneSupply = 16, maxGenerations = 300 }))
  T.ok(res.ok, "job ok: " .. tostring(res.reason))
  T.ok(res.princess, "princess produced")
  T.ok(res.archivedDrones >= 4, "archived >= keep (" .. tostring(res.archivedDrones) .. ")")
  T.ok(res.generations < 150, "finished in a sane number of generations: " .. res.generations)
  local pureCommonPrincess, pureCommonDrones = 0, 0
  for _, st in ipairs(cell._archived) do
    if genome.kind(st) == "princess" and genome.isPure(st, U("Common")) then pureCommonPrincess = pureCommonPrincess + 1 end
    if genome.kind(st) == "drone" and genome.isPure(st, U("Common")) then pureCommonDrones = pureCommonDrones + (st.size or 1) end
  end
  T.eq(pureCommonPrincess, 1, "one pure Common princess archived")
  T.ok(pureCommonDrones >= 4, "pure Common drones archived")
  for _, st in ipairs(cell._archived) do T.ok(genome.isPureAny(st), "only pure bees archived: " .. genome.describe(st)) end
  local phases = phasesOf(cell)
  T.ok(util.contains(phases, "mutate") and util.contains(phases, "stockpile"), "phases seen: " .. table.concat(phases, ","))
end)

T.run("breeder: princess of parent B mates straight with A drones", function()
  local lib = library({ { kind = "princess", species = "Meadows" }, { kind = "drone", species = "Forest", n = 1 }, { kind = "drone", species = "Meadows", n = 1 } })
  local cell = makeCell(lib, 99)
  local res = breeder.run(cell, sim.job({ id = "t2", target = "Common", a = "Forest", b = "Meadows", chance = 15, keepDrones = 2, droneSupply = 16, maxGenerations = 300 }))
  T.ok(res.ok, "t2 job ok: " .. tostring(res.reason))
  T.eq(phasesOf(cell)[1], "mutate", "a princess carrying either parent goes straight to mutate")
end)

T.run("breeder: foreign princess is converted first", function()
  local lib = library({ { kind = "princess", species = "Noble" }, { kind = "drone", species = "Forest", n = 2 }, { kind = "drone", species = "Meadows", n = 2 } })
  local cell = makeCell(lib, 5)
  local res = breeder.run(cell, sim.job({ id = "t2b", target = "Common", a = "Forest", b = "Meadows", chance = 15, keepDrones = 2, droneSupply = 16, maxGenerations = 300 }))
  T.ok(res.ok, "t2b job ok: " .. tostring(res.reason))
  T.eq(phasesOf(cell)[1], "convert", "a princess of an unrelated species is converted first")
end)

T.run("breeder: stockpile only", function()
  local lib = library({ { kind = "princess", species = "Common" }, { kind = "drone", species = "Common", n = 1 } })
  local cell = makeCell(lib, 5)
  local res = breeder.run(cell, sim.job({ id = "t3", target = "Common", a = "Common", b = "Common", keepDrones = 10, droneSupply = 16, maxGenerations = 100 }))
  T.ok(res.ok, "stockpile ok: " .. tostring(res.reason))
  T.ok(res.archivedDrones >= 10, "10 drones stockpiled: " .. res.archivedDrones)
  T.ok(res.generations <= 12, "stockpile is quick: " .. res.generations)
end)

T.run("breeder: missing library stock fails cleanly", function()
  local cell = makeCell(library({ { kind = "princess", species = "Forest" } }), 1)
  local res = breeder.run(cell, sim.job({ id = "t4", target = "Common", a = "Forest", b = "Meadows", keepDrones = 1 }))
  T.ok(not res.ok and res.reason:match("Meadows"), "reports the missing species by name: " .. tostring(res.reason))
end)
