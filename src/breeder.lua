-- bb.breeder : the per-job breeding state machine.
--
-- Pure logic. Everything physical goes through a `cell` object so the same
-- code runs on a robot (bin/beecell.lua) and in the local simulator test.
--
-- cell interface (all calls block until done):
--   cell.listBees()                 -> { {slot=n, stack=t} ... } working inventory
--   cell.read(slot)                 -> stack or nil
--   cell.analyze(slot)              -> ok, err          (spends one honey drop)
--   cell.fetch(uid, kind, n, name)  -> slot or nil, err  (from the library; uid nil = any princess)
--   cell.insertQueen(slot)          -> ok, err          (swap slot <-> housing queen slot)
--   cell.insertDrone(slot)          -> ok, err          (swap slot <-> housing drone slot)
--   cell.takeDrone()                -> slot or nil      (pull the housing drone stack back)
--   cell.housingDrone()             -> stack or nil     (peek at the housing drone stack)
--   cell.waitCycle()                -> "done" | "timeout" | "notstarted" | "cancelled", info
--   cell.collect()                  -> n (bee stacks pulled from the output)
--   cell.archive(slot, n)           -> ok, err          (pure bees -> library)
--   cell.discard(slot)              -> ok               (junk -> dump)
--   cell.setFoundation(block)       -> ok, err
--   cell.setClimate(counts)         -> ok, err          (counts from climate.upgradeCounts)
--   cell.event(type, data)          (progress reporting)
--   cell.cancelled()                -> bool
--
-- job = {
--   id = "j12", target = <uid>, a = <uid>, b = <uid>, names = { [uid] = "Common", ... },
--   chance = 15, conds = {...parsed...},
--   keepDrones = 8, wantPrincess = true,
--   foundation = "Block of Copper" or nil, climate = { heater = 1 } or nil,
--   droneSupply = 16, maxGenerations = 400, warnAfter = 60,
-- }
-- A job with a == b == target is a plain stockpile run.
--
-- Phases, decided fresh every generation from the princess in hand:
--   convert   princess is not pure A yet        -> mate with A drones
--   mutate    princess pure A, no hit yet       -> mate with B drones
--   purify    princess or a drone carries T     -> mate with the best T carrier
--   stockpile princess pure T                   -> mate with pure T drones until keepDrones archived
local genome = require("src.genome")

local breeder = {}

--- How many drones of a species the robot keeps in its own inventory as the
--- next mate; everything above this goes to the library each generation.
local SPARE_MATES = 4

--- Generations a stockpile run may go without banking a single drone before
--- it is treated as broken rather than unlucky.
local STOCKPILE_STALL = 15

--- Handovers to the library that may fail before the job gives up.
local ARCHIVE_FAILURES = 3

--- Generations spent holding out for drones that stack before the job settles
--- for species-pure ones.
local STRICT_AFTER = 60

local function summarize(stack) return genome.summary(stack) end

--- How good is this drone as a mate for reaching species `uid` (display `name`)?
local function mateScore(stack, uid, name)
  if not genome.analyzed(stack) then
    return genome.displaySpecies(stack) == name and 1 or 0
  end
  -- A mate whose alleles all match passes them on whole, which is how a line
  -- converges on drones that stack.
  if genome.isPure(stack, uid) then return genome.isHomozygous(stack) and 4 or 3 end
  if genome.hasSpecies(stack, uid) then return 2 end
  return 0
end

function breeder.run(cell, job)
  if job.kind == "fertility" then return breeder.fertility(cell, job) end
  local target = job.target
  local A, B = job.a or target, job.b or target
  -- species are uids; job.names maps them to the display names seen on
  -- unanalyzed bees and used for library labels
  local names = job.names or {}
  local function nameOf(uid) return names[uid] or uid end
  local keep = job.keepDrones or 8
  local maxGen = job.maxGenerations or 400
  local supply = job.droneSupply or 16
  local state = {
    generation = 0, archivedDrones = 0, hits = 0, phase = "prepare",
    princessSlot = nil, mateSpecies = nil, honeyUsed = 0, fetchMissed = {}, noHoney = nil, found = {},
    strict = true, pureBanked = 0,
  }

  local function ev(kind, data)
    data = data or {}
    data.job = job.id
    data.generation = state.generation
    data.phase = state.phase
    pcall(cell.event, kind, data)
  end

  local function fail(reason)
    ev("error", { reason = reason })
    return { ok = false, reason = reason, generations = state.generation, archivedDrones = state.archivedDrones }
  end

  local function setPhase(p)
    if state.phase ~= p then
      state.phase = p
      ev("phase", { to = p })
    end
  end

  local function analyzeSlot(slot)
    local st = cell.read(slot)
    if not st then return nil end
    if genome.analyzed(st) then return st end
    local ok, err = cell.analyze(slot)
    if not ok then
      ev("warn", { text = "analyze failed: " .. tostring(err) })
      -- Without honey nothing can be read, and an unreadable offspring is
      -- indistinguishable from junk. Rather than quietly void generation
      -- after generation, the job stops and says what it needs.
      if tostring(err):lower():find("honey", 1, true) then state.noHoney = tostring(err) end
      return st
    end
    state.honeyUsed = state.honeyUsed + 1
    return cell.read(slot)
  end

  ----------------------------------------------------------------------
  -- 1. environment
  ----------------------------------------------------------------------
  if job.foundation then
    local ok, err = cell.setFoundation(job.foundation)
    if not ok then return fail("foundation: " .. tostring(err)) end
  end
  if job.climate then
    local ok, err = cell.setClimate(job.climate)
    if not ok then return fail("climate: " .. tostring(err)) end
  end

  ----------------------------------------------------------------------
  -- 2. stock: a princess (ideally species A), drones of B, and drones of
  --    A when the princess has to be converted first.
  ----------------------------------------------------------------------
  local princessSlot = cell.fetch(A, "princess", 1, nameOf(A))
  if not princessSlot then
    princessSlot = cell.fetch(nil, "princess", 1)
    if not princessSlot then return fail("no princess available in the library") end
  end
  state.princessSlot = princessSlot
  local pst = analyzeSlot(princessSlot)
  if state.noHoney then return fail("analysis needs Honey Drop: " .. state.noHoney) end
  -- A stockpile run mates the species with itself: each cycle yields
  -- `fertility` drones and spends one on the next mating, so fertility 1
  -- breaks even forever. Better to say so than to breed until the
  -- generation limit.
  if A == B and A == target then
    local fert = genome.fertility(pst)
    if fert and fert <= 1 then
      return fail(string.format(
        "%s has fertility %d: a cycle makes %d drone and mating spends one, so stockpiling cannot gain. " ..
        "Add drones from a hive or breed a higher-fertility line first", nameOf(target), fert, fert))
    end
    state.fertility = fert
  end
  if not pst or genome.kind(pst) ~= "princess" then return fail("fetched item is not a princess") end
  local princessIsA = genome.isPure(pst, A)

  if not princessIsA then
    if not cell.fetch(A, "drone", supply, nameOf(A)) then
      return fail("no drones of " .. nameOf(A) .. " to convert the princess with")
    end
  end
  if B ~= A or princessIsA then
    if not cell.fetch(B, "drone", supply, nameOf(B)) then
      return fail("no drones of " .. nameOf(B) .. " in the library")
    end
  end

  ----------------------------------------------------------------------
  -- helpers over the working inventory
  ----------------------------------------------------------------------
  local function bestMate(species, minScore)
    local bestSlot, bestStack, bestScore = nil, nil, (minScore or 1) - 1
    for _, e in ipairs(cell.listBees()) do
      if genome.kind(e.stack) == "drone" then
        local score = mateScore(e.stack, species, nameOf(species))
        if score > bestScore then bestSlot, bestStack, bestScore = e.slot, e.stack, score end
      end
    end
    return bestSlot, bestStack
  end

  --- Make sure the housing drone slot holds a mate carrying one of the
  --- species in `wantedList` (in order of preference).
  local function ensureMate(wantedList)
    local inHousing = cell.housingDrone()
    local function swapIn(slot, species)
      if inHousing then
        if not cell.takeDrone() then return false, "could not take the old mate out of the housing" end
        inHousing = nil
      end
      local ok, err = cell.insertDrone(slot)
      if not ok then return false, "insertDrone: " .. tostring(err) end
      state.mateSpecies = species
      return true
    end
    -- Best species first. For each: the housing stack, then the working
    -- inventory, then the library; only then the next-best species.
    for _, species in ipairs(wantedList) do
      local invSlot, invStack = bestMate(species, 1)
      local housingScore = inHousing and mateScore(inHousing, species, nameOf(species)) or 0
      local invScore = invStack and mateScore(invStack, species, nameOf(species)) or 0
      if housingScore > 0 and housingScore >= invScore then
        state.mateSpecies = species
        return true
      end
      if invScore > 0 then return swapIn(invSlot, species) end
      -- do not hammer the controller for a species it just said it lacks
      local lastMiss = state.fetchMissed[species]
      if not lastMiss or state.generation - lastMiss >= 10 then
        local slot = cell.fetch(species, "drone", supply, nameOf(species))
        if slot then return swapIn(slot, species) end
        state.fetchMissed[species] = state.generation
      end
    end
    return false, "ran out of drones (" .. table.concat(wantedList, "/") .. ")"
  end

  --- Archive pure target drones, keep one stack of each useful kind as a
  --- spare mate, return surplus pure parents to the library, discard the rest.
  --- Anything pure goes to the library, whatever species it is. Breeding
  --- throws up species nobody asked for: a princess carrying the target mated
  --- with a parent drone can mutate into the step *after* the one being bred,
  --- and that bee is worth far more than the honey it cost to read.
  local function keepFound(e)
    local st = e.stack
    local n = st.size or 1
    if cell.archive(e.slot, n) then
      local name = genome.activeName(st) or "?"
      state.found[name] = (state.found[name] or 0) + n
      return true
    end
    return false
  end

  local function cleanup(princessSlot)
    local groups = { target = {}, hybrid = {}, [A] = {}, [B] = {} }
    for _, e in ipairs(cell.listBees()) do
      local st = e.stack
      if e.slot ~= princessSlot and genome.kind(st) == "drone" then
        if genome.analyzed(st) then
          if genome.isPure(st, target) then table.insert(groups.target, e)
          elseif genome.hasSpecies(st, target) then table.insert(groups.hybrid, e)
          elseif genome.isPure(st, A) then table.insert(groups[A], e)
          elseif genome.isPure(st, B) then table.insert(groups[B], e)
          elseif genome.isPureAny(st) then keepFound(e)
          else cell.discard(e.slot) end
        else
          -- unanalyzed and not interesting to the prescreen: only parent-named
          -- drones get here.
          local sp = genome.displaySpecies(st)
          local uid = (sp == nameOf(A)) and A or ((sp == nameOf(B)) and B or nil)
          if uid and groups[uid] then table.insert(groups[uid], e) else cell.discard(e.slot) end
        end
      elseif e.slot ~= princessSlot and genome.kind(st) == "princess"
        and genome.analyzed(st) and genome.isPureAny(st) and not genome.isPure(st, target) then
        keepFound(e)
      end
    end
    local function order(list)
      table.sort(list, function(x, y)
        local ax, ay = genome.analyzed(x.stack) and 1 or 0, genome.analyzed(y.stack) and 1 or 0
        if ax ~= ay then return ax > ay end
        -- a bee that breeds true is worth holding on to over one that does not
        local hx, hy = genome.isHomozygous(x.stack) and 1 or 0, genome.isHomozygous(y.stack) and 1 or 0
        if hx ~= hy then return hx > hy end
        return (x.stack.size or 1) > (y.stack.size or 1)
      end)
      return list
    end

    --- Identical bees stack, so the offspring of every generation merge into
    --- the spare the robot is holding. Counting whole surplus *stacks* would
    --- therefore bank nothing at all: what leaves is a surplus of drones,
    --- keeping at most `spare` of them back as the next mate.
    local function trimToSpare(list, spare, onSurplus)
      local kept = 0
      for _, e in ipairs(order(list)) do
        local n = e.stack.size or 1
        local room = math.max(0, spare - kept)
        local hold = math.min(n, room)
        kept = kept + hold
        if n - hold > 0 then onSurplus(e, n - hold) end
      end
    end

    trimToSpare(groups.target, SPARE_MATES, function(e, n)
      local ok, moved = cell.archive(e.slot, n)
      if ok then
        local banked = tonumber(moved) or n
        state.pureBanked = state.pureBanked + banked
        -- The job is finished when the drones it banked stack, which means
        -- every allele matched, not just the species.
        if genome.isHomozygous(e.stack) or not state.strict then
          state.archivedDrones = state.archivedDrones + banked
        end
        state.archiveFailures = 0
        state.fetchMissed[target] = nil -- the library holds target drones now
      else
        state.archiveFailures = (state.archiveFailures or 0) + 1
      end
    end)
    trimToSpare(groups.hybrid, 0, function(e, n) cell.discard(e.slot, n) end)
    local done = {}
    for _, sp in ipairs({ A, B }) do
      if not done[sp] then
        done[sp] = true
        trimToSpare(groups[sp], SPARE_MATES, function(e, n)
          if genome.analyzed(e.stack) then cell.archive(e.slot, n) else cell.discard(e.slot, n) end
        end)
      end
    end
  end

  ----------------------------------------------------------------------
  -- 3. generations
  ----------------------------------------------------------------------
  local noProgress = 0
  while true do
    if cell.cancelled() then return fail("cancelled") end
    if state.generation >= maxGen then return fail("generation limit reached (" .. maxGen .. ")") end

    local princess = cell.read(state.princessSlot)
    if not princess or genome.kind(princess) ~= "princess" then
      return fail("princess lost from slot " .. tostring(state.princessSlot))
    end
    if not genome.analyzed(princess) then princess = analyzeSlot(state.princessSlot) end

    local princessPureTarget = genome.isPure(princess, target)
    local princessHasTarget = genome.hasSpecies(princess, target)
    local hasA, hasB = genome.hasSpecies(princess, A), genome.hasSpecies(princess, B)
    local haveTargetDrone = bestMate(target, 2) ~= nil
    local wanted

    if princessPureTarget then
      setPhase("stockpile")
      if state.archivedDrones >= keep then break end
      -- pure target drones give 100% pure offspring; a parent drone still
      -- yields target carriers when no target drone exists yet
      wanted = { target, A, B }
    elseif princessHasTarget or haveTargetDrone then
      setPhase("purify")
      -- best: a target carrier; otherwise any parent drone keeps the line going
      wanted = { target, A, B }
    elseif hasA or hasB then
      -- Forestry rolls the mutation from one allele of each parent, so a
      -- hybrid A/B princess is fine: mate her with the parent she lacks.
      -- A pure parent princess must get the other parent; falling back to
      -- her own species would breed nothing, so let the job fail loudly and
      -- the controller restock instead.
      setPhase("mutate")
      if hasA and not hasB then wanted = { B }
      elseif hasB and not hasA then wanted = { A }
      else wanted = { B, A } end
    else
      -- foreign princess from the pool: bring one parent species in first
      setPhase("convert")
      wanted = { A, B }
    end

    local okMate, errMate = ensureMate(wanted)
    if not okMate then return fail(errMate) end

    local okQ, errQ = cell.insertQueen(state.princessSlot)
    if not okQ then return fail("insertQueen: " .. tostring(errQ)) end

    local result, info = cell.waitCycle()
    if result ~= "done" then
      cell.collect()
      return fail("cycle " .. tostring(result) .. (info and (": " .. tostring(info)) or ""))
    end
    state.generation = state.generation + 1

    local before = {}
    for _, e in ipairs(cell.listBees()) do before[e.slot] = true end
    cell.collect()

    local newPrincessSlot, hitsThisGen, droneSummaries = nil, 0, {}
    for _, e in ipairs(cell.listBees()) do
      local st = e.stack
      local kind = genome.kind(st)
      if kind == "princess" then
        newPrincessSlot = e.slot
      elseif kind == "drone" and not before[e.slot] then
        local sp = genome.displaySpecies(st)
        local interesting = (state.phase ~= "mutate") or (sp ~= nameOf(A) and sp ~= nameOf(B))
        if interesting then st = analyzeSlot(e.slot) or st end
        if genome.analyzed(st) and genome.hasSpecies(st, target) then hitsThisGen = hitsThisGen + 1 end
        droneSummaries[#droneSummaries + 1] = summarize(st)
      end
    end
    if state.noHoney then
      return fail("analysis needs Honey Drop: " .. state.noHoney)
    end
    if not newPrincessSlot then return fail("princess did not come back from the housing") end
    state.princessSlot = newPrincessSlot
    princess = analyzeSlot(state.princessSlot)
    if genome.hasSpecies(princess, target) then hitsThisGen = hitsThisGen + 1 end
    state.hits = state.hits + hitsThisGen
    if hitsThisGen > 0 then noProgress = 0 else noProgress = noProgress + 1 end

    local bankedBefore = state.archivedDrones
    cleanup(state.princessSlot)
    -- Holding out for a line that breeds true is right, but not forever: past
    -- the cutoff the species-pure drones already banked are accepted, with a
    -- word about what they are.
    if state.strict and state.pureBanked >= keep and state.generation >= (job.strictAfter or STRICT_AFTER) then
      state.strict = false
      state.archivedDrones = state.pureBanked
      ev("warn", { text = string.format(
        "%d %s drones banked but they do not all stack; accepting them after %d generations",
        state.pureBanked, nameOf(target), state.generation) })
    end
    -- Drones that cannot be handed over pile up in the robot and the run
    -- makes no progress no matter how many generations it burns.
    if (state.archiveFailures or 0) >= ARCHIVE_FAILURES then
      return fail("the bee interface would not take the drones " .. state.archiveFailures ..
        " times: check that the interface below the robot is on the ME network and has a free slot")
    end
    -- A stockpile run can legitimately bank nothing for a while, waiting for
    -- a pure target drone to appear. Grinding for a long time without the
    -- count moving is worth saying out loud, though: that is what a silent
    -- failure to read or archive the offspring looks like from outside.
    if state.archivedDrones > bankedBefore then
      state.lastBanked = state.generation
    elseif state.phase == "stockpile" then
      state.stockSince = state.stockSince or state.generation
      local since = math.max(state.lastBanked or 0, state.stockSince)
      local waited = state.generation - since
      if waited > 0 and waited % STOCKPILE_STALL == 0 then
        ev("warn", { text = string.format("%d generations of stockpiling without banking a drone (%d of %d)",
          waited, state.archivedDrones, keep) })
      end
    end

    if next(state.found) then
      local kept = {}
      for name, n in pairs(state.found) do kept[#kept + 1] = string.format("%s x%d", name, n) end
      ev("found", { species = kept })
      state.found = {}
    end
    ev("gen", {
      princess = summarize(princess), drones = droneSummaries, hits = hitsThisGen,
      archived = state.archivedDrones, keep = keep, honey = state.honeyUsed, noProgress = noProgress,
    })
    if job.warnAfter and noProgress > 0 and noProgress % job.warnAfter == 0 then
      ev("warn", { text = string.format("%d generations without a %s hit", noProgress, target) })
    end
  end

  ----------------------------------------------------------------------
  -- 4. wrap up: pull the mate stack out, archive what is pure, return spares
  ----------------------------------------------------------------------
  cell.takeDrone()
  local producedPrincess = false
  for _, e in ipairs(cell.listBees()) do
    local st = e.stack
    if e.slot == state.princessSlot then
      if genome.isPure(st, target) and cell.archive(e.slot, 1) then producedPrincess = true end
    elseif genome.analyzed(st) and genome.isPureAny(st) then
      local n = st.size or 1
      if cell.archive(e.slot, n) and genome.kind(st) == "drone" and genome.isPure(st, target) then
        state.archivedDrones = state.archivedDrones + n
      end
    elseif genome.kind(st) == "drone" then
      cell.discard(e.slot)
    end
  end

  local res = {
    ok = true, target = target, generations = state.generation, hits = state.hits,
    archivedDrones = state.archivedDrones, princess = producedPrincess, honey = state.honeyUsed,
    stacks = state.strict, pureBanked = state.pureBanked,
  }
  ev("done", res)
  return res
end

--- Breed a better fertility allele into a species.
---
--- Fertility is an allele of its own, not a property of the species, so a
--- line that comes out of the hives at fertility 1 can be lifted to 2 or
--- more: cross in a donor that has the better allele, then breed the species
--- back to pure while keeping individuals that carry it. A bee shows both of
--- its alleles once analyzed, so "carries it twice" is something the robot
--- can check rather than guess.
---
--- job: { target, donor, wantFertility, keepDrones, names, maxGenerations }
function breeder.fertility(cell, job)
  local target, donor = job.target, job.donor
  local want = tonumber(job.wantFertility) or 2
  local keep = job.keepDrones or 4
  local maxGen = job.maxGenerations or 200
  local supply = job.droneSupply or 16
  local names = job.names or {}
  local function nameOf(uid) return names[uid] or uid end

  local state = { generation = 0, archivedDrones = 0, phase = "prepare", honeyUsed = 0, princessSlot = nil }

  local function ev(kind, data)
    data = data or {}
    data.job = job.id
    data.generation = state.generation
    data.phase = state.phase
    pcall(cell.event, kind, data)
  end

  local function fail(reason)
    ev("error", { reason = reason })
    return { ok = false, reason = reason, generations = state.generation, archivedDrones = state.archivedDrones }
  end

  local function setPhase(p)
    if state.phase ~= p then
      state.phase = p
      ev("phase", { to = p })
    end
  end

  local function analyzeSlot(slot)
    local st = cell.read(slot)
    if not st then return nil end
    if genome.analyzed(st) then return st end
    local ok, err = cell.analyze(slot)
    if not ok then
      if tostring(err):lower():find("honey", 1, true) then
        state.noHoney = tostring(err)
      end
      return st
    end
    state.honeyUsed = state.honeyUsed + 1
    return cell.read(slot)
  end

  --- Both alleles at or above the goal: only then does the line breed true.
  local function goodFertility(st)
    local a, i = genome.fertilityPair(st)
    return a ~= nil and i ~= nil and a >= want and i >= want
  end

  local function carriesFertility(st)
    local a, i = genome.fertilityPair(st)
    return (a ~= nil and a >= want) or (i ~= nil and i >= want)
  end

  local function finished(st)
    return genome.isPure(st, target) and goodFertility(st)
  end

  --- How useful a bee is to this job: the species matters most, the alleles
  --- decide between equals.
  local function score(st)
    if not genome.analyzed(st) then return 0 end
    local s = 0
    if genome.isPure(st, target) then s = s + 100
    elseif genome.hasSpecies(st, target) then s = s + 40 end
    if goodFertility(st) then s = s + 30
    elseif carriesFertility(st) then s = s + 15 end
    return s
  end

  local function bestIn(kind, pred)
    local bestSlot, bestScore, bestStack = nil, -1, nil
    for _, e in ipairs(cell.listBees()) do
      if genome.kind(e.stack) == kind and (pred == nil or pred(e.stack)) then
        local sc = score(e.stack)
        if sc > bestScore then bestSlot, bestScore, bestStack = e.slot, sc, e.stack end
      end
    end
    return bestSlot, bestStack, bestScore
  end

  ----------------------------------------------------------------------
  -- a princess of the species to lift
  ----------------------------------------------------------------------
  local princessSlot = cell.fetch(target, "princess", 1, nameOf(target))
  if not princessSlot then
    princessSlot = cell.fetch(nil, "princess", 1)
    if not princessSlot then return fail("no princess available in the library") end
  end
  state.princessSlot = princessSlot
  local princess = analyzeSlot(princessSlot)
  if state.noHoney then return fail("analysis needs Honey Drop: " .. state.noHoney) end
  if not princess or genome.kind(princess) ~= "princess" then return fail("fetched item is not a princess") end

  ----------------------------------------------------------------------
  -- generations
  ----------------------------------------------------------------------
  while true do
    if cell.cancelled() then return fail("cancelled") end
    if state.generation >= maxGen then return fail("generation limit reached (" .. maxGen .. ")") end

    princess = cell.read(state.princessSlot)
    if not princess or genome.kind(princess) ~= "princess" then
      return fail("princess lost from slot " .. tostring(state.princessSlot))
    end
    if not genome.analyzed(princess) then princess = analyzeSlot(state.princessSlot) end
    if state.noHoney then return fail("analysis needs Honey Drop: " .. state.noHoney) end

    if finished(princess) and state.archivedDrones >= keep then break end

    -- What she needs next: the species back if she has drifted, the better
    -- allele if she lacks it, and otherwise a partner as good as she is.
    local wanted
    if not genome.isPure(princess, target) then
      setPhase("recover")
      wanted = { { uid = target, need = "pure" }, { uid = target } }
    elseif not goodFertility(princess) then
      setPhase("uplift")
      wanted = { { uid = target, need = "good" }, { uid = donor, need = "carrier" }, { uid = donor } }
    else
      setPhase("fix")
      wanted = { { uid = target, need = "good" }, { uid = target, need = "carrier" }, { uid = target } }
    end

    local mateSlot
    for _, w in ipairs(wanted) do
      local pred = function(st)
        if w.uid and not genome.isPure(st, w.uid) then return false end
        if w.need == "good" then return goodFertility(st) end
        if w.need == "carrier" then return carriesFertility(st) end
        return true
      end
      mateSlot = select(1, bestIn("drone", pred))
      if not mateSlot then
        local slot = cell.fetch(w.uid, "drone", supply, nameOf(w.uid))
        if slot then
          local st = analyzeSlot(slot)
          if st and pred(st) then mateSlot = slot end
        end
      end
      if mateSlot then break end
    end
    if not mateSlot then
      return fail("ran out of drones (" .. nameOf(target) .. "/" .. nameOf(donor) .. ")")
    end

    local okD, errD = cell.insertDrone(mateSlot)
    if not okD then return fail("insertDrone: " .. tostring(errD)) end
    local okQ, errQ = cell.insertQueen(state.princessSlot)
    if not okQ then return fail("insertQueen: " .. tostring(errQ)) end

    local result, info = cell.waitCycle()
    if result ~= "done" then
      cell.collect()
      return fail("cycle " .. tostring(result) .. (info and (": " .. tostring(info)) or ""))
    end
    state.generation = state.generation + 1
    cell.collect()

    -- read everything new, then keep the best princess and bank the drones
    -- that already breed true
    for _, e in ipairs(cell.listBees()) do
      if not genome.analyzed(e.stack) then analyzeSlot(e.slot) end
    end
    if state.noHoney then return fail("analysis needs Honey Drop: " .. state.noHoney) end

    local nextSlot, nextStack = bestIn("princess")
    if not nextSlot then return fail("princess did not come back from the housing") end
    state.princessSlot = nextSlot

    local spare = 0
    for _, e in ipairs(cell.listBees()) do
      local st = e.stack
      if e.slot ~= state.princessSlot and genome.kind(st) == "drone" then
        local n = st.size or 1
        if genome.isPure(st, target) and goodFertility(st) then
          if spare < 2 then
            spare = spare + n            -- one mate for the next generation
          else
            local ok, moved = cell.archive(e.slot, n)
            if ok then state.archivedDrones = state.archivedDrones + (tonumber(moved) or n) end
          end
        elseif genome.kind(st) == "princess" then -- untouched
        elseif not carriesFertility(st) and not genome.isPure(st, target) and not genome.isPure(st, donor) then
          cell.discard(e.slot)           -- neither the species nor the allele
        end
      end
    end

    ev("gen", {
      princess = genome.summary(nextStack), hits = finished(nextStack) and 1 or 0,
      archived = state.archivedDrones, keep = keep, honey = state.honeyUsed,
      fertility = select(1, genome.fertilityPair(nextStack)),
    })
  end

  -- hand over what the job was for
  cell.takeDrone()
  local producedPrincess = false
  for _, e in ipairs(cell.listBees()) do
    local st = e.stack
    if e.slot == state.princessSlot then
      if finished(st) and cell.archive(e.slot, 1) then producedPrincess = true end
    elseif genome.kind(st) == "drone" and genome.analyzed(st) and genome.isPureAny(st) then
      local n = st.size or 1
      local ok, moved = cell.archive(e.slot, n)
      if ok and genome.isPure(st, target) and goodFertility(st) then
        state.archivedDrones = state.archivedDrones + (tonumber(moved) or n)
      end
    end
  end

  local res = { ok = true, target = target, generations = state.generation, hits = state.archivedDrones,
    archivedDrones = state.archivedDrones, princess = producedPrincess, honey = state.honeyUsed,
    fertility = want }
  ev("done", res)
  return res
end

return breeder
