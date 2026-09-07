-- bb.breeder : the per-job breeding state machine.
--
-- Pure logic. Everything physical goes through a `cell` object so the same
-- code runs on a robot (bin/beecell.lua) and in the local simulator test.
--
-- cell interface (all calls block until done):
--   cell.listBees()                 -> { {slot=n, stack=t} ... } working inventory
--   cell.read(slot)                 -> stack or nil
--   cell.analyze(slot)              -> ok, err          (spends one honey drop)
--   cell.fetch(species, kind, n)    -> slot or nil, err  (from the library; species nil = any)
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
--   id = "j12", target = "Common", a = "Forest", b = "Meadows",
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
local genome = require("bb.genome")

local breeder = {}

local function summarize(stack) return genome.summary(stack) end

--- How good is this drone as a mate for reaching `species`?
local function mateScore(stack, species)
  if not genome.analyzed(stack) then
    return genome.displaySpecies(stack) == species and 1 or 0
  end
  if genome.isPure(stack, species) then return 3 end
  if genome.hasSpecies(stack, species) then return 2 end
  return 0
end

function breeder.run(cell, job)
  local target = job.target
  local A, B = job.a or target, job.b or target
  local keep = job.keepDrones or 8
  local maxGen = job.maxGenerations or 400
  local supply = job.droneSupply or 16
  local state = {
    generation = 0, archivedDrones = 0, hits = 0, phase = "prepare",
    princessSlot = nil, mateSpecies = nil, honeyUsed = 0, fetchMissed = {},
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
    if not ok then ev("warn", { text = "analyze failed: " .. tostring(err) }) return st end
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
  local princessSlot = cell.fetch(A, "princess", 1)
  if not princessSlot then
    princessSlot = cell.fetch(nil, "princess", 1)
    if not princessSlot then return fail("no princess available in the library") end
  end
  state.princessSlot = princessSlot
  local pst = analyzeSlot(princessSlot)
  if not pst or genome.kind(pst) ~= "princess" then return fail("fetched item is not a princess") end
  local princessIsA = genome.isPure(pst, A)

  if not princessIsA then
    if not cell.fetch(A, "drone", supply) then
      return fail("no drones of " .. A .. " to convert the princess with")
    end
  end
  if B ~= A or princessIsA then
    if not cell.fetch(B, "drone", supply) then
      return fail("no drones of " .. B .. " in the library")
    end
  end

  ----------------------------------------------------------------------
  -- helpers over the working inventory
  ----------------------------------------------------------------------
  local function bestMate(species, minScore)
    local bestSlot, bestStack, bestScore = nil, nil, (minScore or 1) - 1
    for _, e in ipairs(cell.listBees()) do
      if genome.kind(e.stack) == "drone" then
        local score = mateScore(e.stack, species)
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
      local housingScore = inHousing and mateScore(inHousing, species) or 0
      local invScore = invStack and mateScore(invStack, species) or 0
      if housingScore > 0 and housingScore >= invScore then
        state.mateSpecies = species
        return true
      end
      if invScore > 0 then return swapIn(invSlot, species) end
      -- do not hammer the controller for a species it just said it lacks
      local lastMiss = state.fetchMissed[species]
      if not lastMiss or state.generation - lastMiss >= 10 then
        local slot = cell.fetch(species, "drone", supply)
        if slot then return swapIn(slot, species) end
        state.fetchMissed[species] = state.generation
      end
    end
    return false, "ran out of drones (" .. table.concat(wantedList, "/") .. ")"
  end

  --- Archive pure target drones, keep one stack of each useful kind as a
  --- spare mate, return surplus pure parents to the library, discard the rest.
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
          else cell.discard(e.slot) end
        else
          -- unanalyzed and not interesting to the prescreen: only parent-named
          -- drones get here.
          local sp = genome.displaySpecies(st)
          if groups[sp] then table.insert(groups[sp], e) else cell.discard(e.slot) end
        end
      end
    end
    -- keep one stack per group: analyzed before unanalyzed, bigger before smaller
    local function trim(list, onExtra)
      table.sort(list, function(x, y)
        local ax, ay = genome.analyzed(x.stack) and 1 or 0, genome.analyzed(y.stack) and 1 or 0
        if ax ~= ay then return ax > ay end
        return (x.stack.size or 1) > (y.stack.size or 1)
      end)
      for i = 2, #list do onExtra(list[i]) end
    end
    trim(groups.target, function(e)
      local n = e.stack.size or 1
      if cell.archive(e.slot, n) then state.archivedDrones = state.archivedDrones + n end
    end)
    trim(groups.hybrid, function(e) cell.discard(e.slot) end)
    local done = {}
    for _, sp in ipairs({ A, B }) do
      if not done[sp] then
        done[sp] = true
        trim(groups[sp], function(e)
          if genome.analyzed(e.stack) then cell.archive(e.slot, e.stack.size or 1) else cell.discard(e.slot) end
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
        local interesting = (state.phase ~= "mutate") or (sp ~= A and sp ~= B)
        if interesting then st = analyzeSlot(e.slot) or st end
        if genome.analyzed(st) and genome.hasSpecies(st, target) then hitsThisGen = hitsThisGen + 1 end
        droneSummaries[#droneSummaries + 1] = summarize(st)
      end
    end
    if not newPrincessSlot then return fail("princess did not come back from the housing") end
    state.princessSlot = newPrincessSlot
    princess = analyzeSlot(state.princessSlot)
    if genome.hasSpecies(princess, target) then hitsThisGen = hitsThisGen + 1 end
    state.hits = state.hits + hitsThisGen
    if hitsThisGen > 0 then noProgress = 0 else noProgress = noProgress + 1 end

    cleanup(state.princessSlot)

    ev("gen", {
      princess = summarize(princess), drones = droneSummaries, hits = hitsThisGen,
      archived = state.archivedDrones, honey = state.honeyUsed, noProgress = noProgress,
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
    elseif genome.kind(st) == "drone" then
      if genome.analyzed(st) and genome.isPureAny(st) then
        local n = st.size or 1
        if cell.archive(e.slot, n) and genome.isPure(st, target) then
          state.archivedDrones = state.archivedDrones + n
        end
      else
        cell.discard(e.slot)
      end
    end
  end

  local res = {
    ok = true, target = target, generations = state.generation, hits = state.hits,
    archivedDrones = state.archivedDrones, princess = producedPrincess, honey = state.honeyUsed,
  }
  ev("done", res)
  return res
end

return breeder
