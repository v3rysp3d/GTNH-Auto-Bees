-- Cell: robot worker for one breeding cell.
--
-- Physical layout (robot column beside the housing, level 0 = parking):
--   level +1 : front = output chest on top of the housing, up = main ME interface
--   level  0 : front = housing (GT Industrial Apiary / Apiary / Alveary block)
--   level -1 : front = foundation block position, down = bee-library ME interface
-- Levels +1 and -1 must be air so the robot can step up and down.
--
-- Robot parts: Beekeeper Upgrade, Inventory Controller Upgrade, Inventory
-- Upgrades, wireless network card, a pick in the tool slot.
-- Slot 1 = honey drops, slot 2 = scratch, 3+ = working slots.
local component = require("component")
local event = require("event")
local robot = require("robot")
local sides = require("sides")

local util = require("src.util")
local genome = require("src.genome")
local breeder = require("src.breeder")
local net = require("src.net")
local housing = require("src.housing")

local cell = {}

---Create the cell worker
---@param cfg table   config.cell
---@param logger Logger
function cell:new(cfg, logger)
  local obj = {}
  obj.cfg = cfg
  obj.logger = logger
  obj.hs = assert(housing.get(cfg.housing))

  local function need(name)
    local addr = component.list(name)()
    if not addr then error("missing component: " .. name) end
    return component.proxy(addr)
  end
  local beekeeper = need("beekeeper")
  local invctl = need("inventory_controller")
  local modem = need("modem")

  local link = net.new(modem, cfg.port, cfg.name)
  local controller = nil
  local cancelRequested = false
  local pendingJob = nil
  local pendingProbe = nil
  local replies = {}
  local state = util.loadTable(cfg.statePath, { foundation = nil, job = nil })
  local reqCounter = 0
  local hs = obj.hs

  local function saveState() util.saveTable(cfg.statePath, state) end

  local function say(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    if not cfg.quiet then print(string.format("[%s] %s", os.date("%H:%M:%S"), msg)) end
    pcall(function() logger:info(msg) end)
  end

  local function tell(msgType, payload)
    if controller then link:send(controller, msgType, payload) else link:broadcast(msgType, payload) end
  end

  ----------------------------------------------------------------------
  -- messaging
  ----------------------------------------------------------------------
  local function handleMessage(msg)
    if not msg then return end
    if msg.type == "welcome" then
      controller = msg.remote
      say("controller is %s", controller:sub(1, 8))
    elseif msg.type == "job" then
      if pendingJob or state.job then
        link:send(msg.remote, "busy", { job = msg.payload.id })
      else
        pendingJob = msg.payload
        controller = controller or msg.remote
        link:send(msg.remote, "accepted", { job = msg.payload.id })
      end
    elseif msg.type == "cancel" then
      cancelRequested = true
    elseif msg.type == "ping" then
      link:send(msg.remote, "pong", { name = cfg.name, job = state.job and state.job.id or nil })
    elseif msg.type == "ready" or msg.type == "fail" then
      if msg.payload.reqId then replies[msg.payload.reqId] = msg end
    elseif msg.type == "probe" then
      -- answered from step() when the robot is idle; moving mid-job is unsafe
      pendingProbe = { remote = msg.remote, payload = msg.payload or {} }
    elseif msg.type == "whois" then
      link:send(msg.remote, "hello", { name = cfg.name, housing = cfg.housing, job = state.job and state.job.id or nil })
    end
  end

  local function pump(timeout)
    timeout = timeout or 0
    local deadline = util.now() + timeout
    repeat
      local remaining = math.max(0, deadline - util.now())
      local sig = table.pack(event.pull(remaining, "modem_message"))
      if sig.n > 0 and sig[1] == "modem_message" then
        handleMessage(link:decode(table.unpack(sig, 1, sig.n)))
      end
    until util.now() >= deadline
  end

  local function ask(payload)
    reqCounter = reqCounter + 1
    local reqId = cfg.name .. "-" .. reqCounter
    payload.reqId = reqId
    if not controller then
      link:broadcast("hello", { name = cfg.name, housing = cfg.housing })
      pump(3)
      if not controller then return nil, "no controller" end
    end
    link:send(controller, "need", payload)
    local deadline = util.now() + cfg.requestTimeout
    while util.now() < deadline do
      pump(0.5)
      local r = replies[reqId]
      if r then
        replies[reqId] = nil
        if r.type == "fail" then return nil, r.payload.reason or "refused" end
        return r.payload
      end
    end
    return nil, "controller did not answer"
  end

  ----------------------------------------------------------------------
  -- which way is the housing?
  --
  -- The Beekeeper Upgrade takes WORLD directions (0 down, 1 up, 2 north,
  -- 3 south, 4 west, 5 east), not robot-relative ones, so the housing's
  -- compass side is probed once and remembered. The Inventory Controller
  -- and the robot's own moves are relative, so the body still has to face
  -- the housing for those.
  ----------------------------------------------------------------------
  local housingSide = tonumber(cfg.housingSide)

  local function beeSide()
    return housingSide or sides.front
  end

  ----------------------------------------------------------------------
  -- movement (vertical column)
  ----------------------------------------------------------------------
  local level = 0

  local function detectLevel()
    local downSolid = robot.detect(sides.down)
    local upSolid = robot.detect(sides.up)
    if downSolid and not upSolid then return -1 end
    if upSolid and not downSolid then return 1 end
    return 0
  end
  level = detectLevel()

  local function goTo(target)
    local tries = 0
    while level ~= target do
      local ok, why
      if level < target then ok, why = robot.up() else ok, why = robot.down() end
      if ok then
        level = level + (level < target and 1 or -1)
        tries = 0
      else
        tries = tries + 1
        if tries > 20 then error("cannot move to level " .. target .. ": " .. tostring(why)) end
        util.sleep(0.5)
      end
    end
  end

  ----------------------------------------------------------------------
  -- inventory helpers
  ----------------------------------------------------------------------
  local function invSize() return robot.inventorySize() end
  local function stackIn(slot) return invctl.getStackInInternalSlot(slot) end

  local function firstEmpty()
    for s = cfg.slots.firstWork, invSize() do
      if robot.count(s) == 0 then return s end
    end
    return nil
  end

  local function findSlot(pred)
    for s = cfg.slots.firstWork, invSize() do
      local st = stackIn(s)
      if st and pred(st) then return s, st end
    end
    return nil
  end

  local function labelMatches(st, needle)
    return st and st.label and st.label:lower():find(needle:lower(), 1, true) ~= nil
  end

  local function upgradeKeyOf(st)
    if not st or not st.label then return nil end
    local l = st.label:lower()
    for key, needle in pairs(cfg.upgradeKeys) do
      if l:find(needle, 1, true) then return key end
    end
    return nil
  end

  local function dumpSlot(slot)
    if robot.count(slot) == 0 then return true end
    goTo(1)
    robot.select(slot)
    local ok = invctl.dropIntoSlot(sides.up, cfg.interface.main.dump)
    if not ok then
      for s = 1, 9 do if invctl.dropIntoSlot(sides.up, s) then ok = true break end end
    end
    return ok
  end

  local function dumpJunk()
    for s = cfg.slots.firstWork, invSize() do
      local st = stackIn(s)
      if st and not genome.isBee(st) and not upgradeKeyOf(st) and not labelMatches(st, "honey") then
        dumpSlot(s)
      end
    end
  end

  --- Honey that landed in a working slot is moved back into the honey slot.
  local function consolidateHoney()
    for s = cfg.slots.firstWork, invSize() do
      local st = stackIn(s)
      if st and labelMatches(st, "honey") then
        robot.select(s)
        robot.transferTo(cfg.slots.honey)
      end
    end
  end

  --- An ME interface fills a configured slot over the next few ticks; wait
  --- for the item to show up before reaching in. Returns the stack or nil.
  local function awaitStock(side, slot, what)
    local deadline = util.now() + (cfg.stockTimeout or 15)
    while util.now() < deadline do
      local ok, st = pcall(invctl.getStackInSlot, side, slot)
      if ok and type(st) == "table" then return st end
      pump(0.5)
    end
    say("interface slot %d stayed empty while waiting for %s; run 'pair' on the controller to check which interface is which", slot, tostring(what))
    return nil
  end

  ----------------------------------------------------------------------
  -- probe: report what the robot can actually reach.
  --
  -- The controller knows the ME interface addresses but cannot see inside
  -- the blocks; the robot can see the blocks but not their addresses. A
  -- probe puts the two halves together, which is how `pair` and `diag`
  -- work out which interface is which.
  ----------------------------------------------------------------------
  local function runProbe(p)
    local where = p.where or "down"
    local lvl = (where == "down" and -1) or (where == "up" and 1) or 0
    local side = (where == "down" and sides.down) or (where == "up" and sides.up) or sides.front
    local res = { reqId = p.reqId, cell = cfg.name, where = where }
    local okMove, whyMove = pcall(goTo, lvl)
    if not okMove then
      res.error = tostring(whyMove)
      return res
    end
    res.size = tonumber(invctl.getInventorySize(side)) or 0
    local filled = {}
    for slot = 1, math.min(res.size, 27) do
      local okS, st = pcall(invctl.getStackInSlot, side, slot)
      if okS and type(st) == "table" then
        local n = math.floor(st.size or 1)
        filled[#filled + 1] = string.format("%d=%s x%d", slot, tostring(st.label), n)
        if p.slot and slot == p.slot then
          res.label, res.count = st.label, n
        end
        -- where the marker really landed, which is how the slot offset is measured
        if p.label and st.label == p.label then
          res.foundSlot, res.foundCount, res.foundLabel = slot, n, st.label
        end
      end
    end
    res.filled = table.concat(filled, ", ")
    return res
  end

  local function ensureHoney()
    if robot.count(cfg.slots.honey) >= cfg.honeyMin then return true end
    local reply = ask({ honey = true, count = cfg.honeyFetch })
    goTo(1)
    robot.select(cfg.slots.honey)
    local slot = reply and reply.slot or cfg.interface.main.honey
    awaitStock(sides.up, slot, "honey drops")
    invctl.suckFromSlot(sides.up, slot, cfg.honeyFetch)
    consolidateHoney()
    if robot.count(cfg.slots.honey) == 0 then
      say("WARNING: no honey drops available; analysis will fail")
      return false
    end
    return true
  end

  local function fetchItem(request, count)
    local reply, err = ask(request)
    if not reply then return nil, err end
    goTo(1)
    local slot = firstEmpty()
    if not slot then return nil, "robot inventory full" end
    robot.select(slot)
    local ifaceSlot = reply.slot or cfg.interface.main.supply
    awaitStock(sides.up, ifaceSlot, request.item or request.upgrade or "item")
    local moved = invctl.suckFromSlot(sides.up, ifaceSlot, count or 1)
    tell("got", { reqId = request.reqId })
    if not moved or robot.count(slot) == 0 then return nil, "nothing arrived in the interface" end
    return slot
  end

  ----------------------------------------------------------------------
  -- the cell interface used by src.breeder
  ----------------------------------------------------------------------
  local api = {}

  function api.listBees()
    local out = {}
    for s = cfg.slots.firstWork, invSize() do
      local st = stackIn(s)
      if st and genome.isBee(st) then out[#out + 1] = { slot = s, stack = st } end
    end
    return out
  end

  function api.read(slot) return stackIn(slot) end

  function api.analyze(slot)
    if not ensureHoney() then return false, "no honey drops reached the robot" end
    robot.select(slot)
    local ok, err = beekeeper.analyze(cfg.slots.honey)
    if not ok then return false, err end
    return true
  end

  --- Pull bees of species `uid` (display `name`) from the library. The ME
  --- network can only pick by label, so a pure bee of another species that
  --- shares the name is parked in the inventory while we ask again, and
  --- returned to the library afterwards. Impure drones are never returned.
  function api.fetch(uid, kind, count, name)
    local parked, result, err = {}, nil, nil
    for attempt = 1, 4 do
      local reply, askErr = ask({ species = uid, name = name, kind = kind, count = count })
      if not reply then err = askErr break end
      goTo(-1)
      local slot = firstEmpty()
      if not slot then err = "robot inventory full" break end
      robot.select(slot)
      awaitStock(sides.down, reply.slot, tostring(name or uid) .. " " .. kind)
      invctl.suckFromSlot(sides.down, reply.slot, count)
      tell("got", { reqId = reply.reqId })
      local st = stackIn(slot)
      if not st then
        say("fetch %s %s: nothing arrived (attempt %d)", tostring(name or uid), kind, attempt)
      elseif genome.kind(st) ~= kind then
        say("fetch: got %s instead of %s, returning it", tostring(genome.kind(st)), kind)
        dumpSlot(slot)
      elseif not uid or kind == "princess" then
        -- any princess is usable, the breeder converts her
        result = slot
        break
      else
        if not genome.analyzed(st) then api.analyze(slot); st = stackIn(slot) end
        if genome.isPure(st, uid) then
          result = slot
          break
        elseif genome.isPureAny(st) then
          say("fetch: %s shares the name but is another species, parking it", genome.describe(st))
          parked[#parked + 1] = slot
        else
          say("fetch: %s is not pure, quarantining", genome.describe(st))
          tell("badstock", { species = uid, kind = kind, got = genome.summary(st) })
          api.discard(slot)
        end
      end
    end
    for _, slot in ipairs(parked) do api.archive(slot, robot.count(slot)) end
    if result then return result end
    return nil, err or ("library did not deliver a pure " .. tostring(name or uid) .. " " .. kind)
  end

  function api.insertQueen(slot)
    goTo(0)
    robot.select(slot)
    local ok, err = beekeeper.swapQueen(beeSide())
    if not ok then return false, err or "swapQueen refused" end
    return true
  end

  function api.insertDrone(slot)
    goTo(0)
    robot.select(slot)
    local ok, err = beekeeper.swapDrone(beeSide())
    if not ok then return false, err or "swapDrone refused" end
    return true
  end

  function api.housingDrone()
    goTo(0)
    local ok, st = pcall(invctl.getStackInSlot, sides.front, hs.slots.drone)
    if ok and type(st) == "table" then return st end
    return nil
  end

  function api.takeDrone()
    goTo(0)
    local slot = firstEmpty()
    if not slot then return nil end
    robot.select(slot)
    local ok = beekeeper.swapDrone(beeSide())
    if not ok or robot.count(slot) == 0 then return nil end
    return slot
  end

  local function housingSize()
    goTo(0)
    return tonumber(invctl.getInventorySize(sides.front)) or 0
  end

  local function slotStack(slot)
    if not slot then return nil end
    local ok, st = pcall(invctl.getStackInSlot, sides.front, slot)
    if ok and type(st) == "table" then return st end
    return nil
  end

  --- The queen slot number differs between housings and GregTech machines do
  --- not always report the one we expect, so an empty configured slot falls
  --- back to looking for a queen anywhere in the machine. What it finds is
  --- remembered for the rest of the run.
  local function queenSlotStack()
    goTo(0)
    local st = slotStack(state.queenSlot or hs.slots.queen)
    if st then return st end
    for slot = 1, math.min(housingSize(), 27) do
      local other = slotStack(slot)
      if other and genome.kind(other) == "queen" then
        if slot ~= (state.queenSlot or hs.slots.queen) then
          say("the queen shows up in slot %d, not %d; using that from now on", slot, hs.slots.queen)
          state.queenSlot = slot
          saveState()
        end
        return other
      end
    end
    return nil
  end

  local function droneSlotStack()
    goTo(0)
    return slotStack(hs.slots.drone)
  end

  --- What the housing holds, for the log when something does not add up.
  local function housingContents()
    local out = {}
    for slot = 1, math.min(housingSize(), 27) do
      local st = slotStack(slot)
      if st then out[#out + 1] = string.format("%d=%s", slot, tostring(st.label)) end
    end
    return #out > 0 and table.concat(out, ", ") or "empty"
  end

  local function chestCount(kind)
    goTo(1)
    local size = invctl.getInventorySize(sides.front) or 0
    local n = 0
    for s = 1, size do
      local st = invctl.getStackInSlot(sides.front, s)
      if st and genome.kind(st) == kind then n = n + math.floor(st.size or 1) end
    end
    return n
  end

  local function outputChestHas(kind)
    return chestCount(kind) > 0
  end

  --- Wait for one queen to work through her life.
  ---
  -- A Forestry housing mates the princess into a queen that sits in the
  -- queen slot until she dies. A GregTech Industrial Apiary takes both bees
  -- straight into its recipe, so its slots go empty the moment work starts
  -- and the offspring turn up in the output chest. Both are accepted: work
  -- has started when a queen appears or when the machine has swallowed the
  -- pair, and it is finished when a princess lands in the chest or the queen
  -- is gone.
  function api.waitCycle()
    goTo(0)
    local toChest = (hs.outputs == "chest")
    local before = toChest and chestCount("princess") or 0

    local t0 = util.now()
    local started, sawQueen, sawPrincess = false, false, false
    while util.now() - t0 < cfg.startTimeout do
      local q = queenSlotStack()
      if q and genome.kind(q) == "queen" then started, sawQueen = true, true break end
      if q then sawPrincess = true end
      if toChest then
        if chestCount("princess") > before then return "done" end
        -- the machine keeps its drone stack and takes only the princess, so
        -- an empty queen slot after she went in means work has begun
        if q == nil then started = true break end
      end
      pump(0.25)
    end

    if not started then
      if chestCount("princess") > before then return "done" end
      if outputChestHas("queen") then return "notstarted", "the queen was ejected: enable Auto-Queen on the machine" end
      local q, d = queenSlotStack(), droneSlotStack()
      say("housing holds: %s", housingContents())
      if q and not d then return "notstarted", "the princess is in the machine but no drone reached it" end
      if q and genome.kind(q) == "princess" then
        return "notstarted", "the machine never took the princess: is it powered and enabled?"
      end
      if q then return "notstarted", "the machine is holding the bees but never started: power, or is it disabled?" end
      return "notstarted", "queen slot empty: no power, no drone, or machine disabled?"
    end

    local t1 = util.now()
    local stuckSince = nil
    -- if the bees were never seen in the machine the swap itself may have
    -- failed, so that case gets a short grace period rather than the full
    -- cycle timeout before it is called a failure
    local graceUntil = (not sawPrincess and not sawQueen) and (util.now() + (cfg.startGrace or 90)) or nil
    while true do
      if cancelRequested then return "cancelled" end
      if toChest then
        if chestCount("princess") > before then return "done" end
        if sawQueen and queenSlotStack() == nil and chestCount("drone") > 0 then return "done" end
        if graceUntil and util.now() > graceUntil and chestCount("drone") == 0 then
          return "notstarted", "the bees never showed up in the machine and nothing came back; did the swap work?"
        end
      else
        if queenSlotStack() == nil then return "done" end
      end
      if hs.reportsProgress then
        local okW, canWork = pcall(beekeeper.canWork, beeSide())
        if okW and canWork == false then
          stuckSince = stuckSince or util.now()
          if util.now() - stuckSince > 30 then return "timeout", "queen cannot work (flowers, climate, light?)" end
        else
          stuckSince = nil
        end
      end
      if util.now() - t1 > cfg.cycleTimeout then
        return "timeout", "queen still working after " .. cfg.cycleTimeout .. "s (flowers? climate? power?)"
      end
      pump(0.5)
    end
  end

  function api.collect()
    goTo(1)
    local n = 0
    local size = invctl.getInventorySize(sides.front) or 0
    for s = 1, size do
      local st = invctl.getStackInSlot(sides.front, s)
      if st then
        local target = firstEmpty()
        if not target then say("WARNING: robot inventory full while collecting") break end
        robot.select(target)
        if invctl.suckFromSlot(sides.front, s) then
          if genome.isBee(st) then n = n + 1
          else invctl.dropIntoSlot(sides.up, cfg.interface.main.dump) end
        end
      end
    end
    return n
  end

  --- Hand `count` items to the bee-library interface. The drop call can
  --- report success without moving anything, so what actually left the
  --- robot's slot is what counts: a bee that never reached the network is
  --- a bee the controller will never see.
  function api.archive(slot, count)
    goTo(-1)
    robot.select(slot)
    local before = robot.count(slot)
    if before == 0 then return false, "nothing in that slot" end
    local n = math.min(count or before, before)
    local tried = { cfg.interface.bees.archive }
    for s = 1, 9 do
      if s ~= cfg.interface.bees.princess and s ~= cfg.interface.bees.drone and s ~= cfg.interface.bees.archive then
        tried[#tried + 1] = s
      end
    end
    for _, s in ipairs(tried) do
      invctl.dropIntoSlot(sides.down, s, n)
      local moved = before - robot.count(slot)
      if moved > 0 then
        if s ~= cfg.interface.bees.archive then
          say("archive: slot %d would not take it, used slot %d instead", cfg.interface.bees.archive, s)
        end
        return true, moved
      end
    end
    say("archive FAILED: the interface below the robot took nothing. Is it full, or is every slot configured?")
    return false, "the bee interface accepted nothing"
  end

  --- Junk bees never go back into the ME network (the library would hand
  --- them out again). They are dropped into the air above the parking spot
  --- and despawn.
  ---Get rid of `count` items from `slot` (the whole stack when count is nil).
  ---
  ---Only hybrids reach here: every pure bee is archived, whatever species it
  ---is. A hybrid carries the same label as a pure bee of its active species,
  ---so returning it to the network means a later fetch can hand it back and
  ---the job wastes cycles rejecting it. It is therefore dropped by default;
  ---`cfg.keepJunk` sends it to the ME network instead, if you would rather
  ---sort them out by hand than lose them.
  function api.discard(slot, count)
    local have = robot.count(slot)
    if have == 0 then return true end
    local st = stackIn(slot)
    if st and not genome.isBee(st) then return dumpSlot(slot) end
    if cfg.keepJunk then
      local before = have
      goTo(1)
      robot.select(slot)
      local n = math.min(count or have, have)
      invctl.dropIntoSlot(sides.up, cfg.interface.main.dump, n)
      if robot.count(slot) < before then return true end
      say("could not hand the spare bees to the ME network; dropping them instead")
    end
    goTo(0)
    robot.select(slot)
    local n = math.min(count or have, have)
    local ok = robot.drop(sides.up, n)
    return ok or robot.count(slot) == 0
  end

  function api.setFoundation(block)
    if not hs.caps.foundation then return true end
    if state.foundation == block then
      -- remembered as placed: trust it only while a block is physically there
      goTo(-1)
      if robot.detect(sides.front) then return true end
      state.foundation = nil
    end
    local slot = findSlot(function(st) return st.label == block end)
    if not slot then
      local err
      slot, err = fetchItem({ item = block, count = 1 }, 1)
      if not slot then return false, "no " .. block .. " available: " .. tostring(err) end
    end
    goTo(-1)
    robot.select(slot)
    if robot.compare(sides.front) then
      state.foundation = block
      saveState()
      return true
    end
    if robot.detect(sides.front) then
      local okSwing, why = robot.swing(sides.front)
      if not okSwing and robot.detect(sides.front) then
        return false, "could not break the old foundation (" .. tostring(why) .. "); tool tier?"
      end
    end
    robot.select(slot)
    local okPlace, why = robot.place(sides.front)
    if not okPlace then return false, "place failed: " .. tostring(why) end
    if not robot.compare(sides.front) then say("note: compare() does not confirm %s, continuing", block) end
    state.foundation = block
    saveState()
    dumpJunk()
    return true
  end

  local function installedUpgrades()
    goTo(0)
    local list, misses = {}, 0
    for i = 1, cfg.maxUpgrades do
      local ok, st = pcall(beekeeper.getIndustrialUpgrade, beeSide(), i)
      if ok and type(st) == "table" then
        list[i] = { key = upgradeKeyOf(st), count = st.size or 1, label = st.label }
        misses = 0
      else
        misses = misses + 1
        if misses >= 2 and i > 4 then break end
      end
    end
    return list
  end

  local function removeUpgrade(index, count)
    goTo(0)
    local slot = firstEmpty() or cfg.slots.scratch
    robot.select(slot)
    local ok, moved = pcall(beekeeper.removeIndustrialUpgrade, beeSide(), index, count)
    if ok and (tonumber(moved) or 0) > 0 then dumpSlot(slot) return true end
    return false
  end

  function api.setClimate(counts)
    if not hs.caps.climateUpgrades then return true end
    counts = counts or {}
    local installed = installedUpgrades()
    for i, u in pairs(installed) do
      if u.key and cfg.climateKeys[u.key] and (counts[u.key] or 0) ~= u.count then
        if removeUpgrade(i, u.count) then installed[i] = nil end
      end
    end
    for key, n in pairs(counts) do
      local have = 0
      for _, u in pairs(installed) do if u.key == key then have = have + u.count end end
      if have < n then
        local needCount = n - have
        local slot = findSlot(function(st) return upgradeKeyOf(st) == key end)
        if not slot then
          local err
          slot, err = fetchItem({ upgrade = key, count = needCount }, needCount)
          if not slot then return false, "no " .. key .. " upgrades: " .. tostring(err) end
        end
        goTo(0)
        robot.select(slot)
        local ok, added = pcall(beekeeper.addIndustrialUpgrade, beeSide(), needCount)
        if not ok or (tonumber(added) or 0) < needCount then
          for i, u in pairs(installedUpgrades()) do
            if u.key and not cfg.keepUpgrades[u.key] and not cfg.climateKeys[u.key] then
              removeUpgrade(i, u.count)
              break
            end
          end
          robot.select(slot)
          ok, added = pcall(beekeeper.addIndustrialUpgrade, beeSide(), needCount)
          if not ok or (tonumber(added) or 0) < needCount then
            return false, "could not install " .. key .. " (" .. tostring(added) .. ")"
          end
        end
      end
    end
    return true
  end

  function api.event(kind, data)
    data = data or {}
    data.cell = cfg.name
    if kind == "gen" then
      say("gen %d [%s] hits=%d archived=%d honey=%d", data.generation or 0, data.phase or "-", data.hits or 0, data.archived or 0, data.honey or 0)
    elseif kind ~= "done" then
      say("%s: %s", kind, data.reason or data.text or data.to or "")
    end
    tell("event", { kind = kind, data = data })
  end

  function api.cancelled()
    pump(0)
    return cancelRequested
  end

  ----------------------------------------------------------------------
  -- boot sweep: put the world back into a known state
  ----------------------------------------------------------------------
  local function sweep()
    say("sweep: clearing housing and output chest")
    goTo(0)
    local q = queenSlotStack()
    if q and genome.kind(q) == "queen" then
      say("sweep: a queen is working, waiting for her")
      api.waitCycle()
    end
    local slot = firstEmpty()
    if slot then
      robot.select(slot)
      beekeeper.swapQueen(beeSide())
    end
    api.takeDrone()
    api.collect()
    for _, e in ipairs(api.listBees()) do
      local st = e.stack
      if not genome.analyzed(st) then api.analyze(e.slot); st = stackIn(e.slot) end
      if genome.kind(st) == "queen" then
        say("sweep: queen %s kept in inventory, insert her by hand", genome.describe(st))
      elseif genome.analyzed(st) and genome.isPureAny(st) then
        api.archive(e.slot, st.size or 1)
      elseif genome.analyzed(st) then
        api.discard(e.slot)          -- analyzed and impure: junk
      else
        -- never throw away a bee we could not read; it stays until analysis works
        say("sweep: keeping %s, it could not be analyzed", tostring(st.label))
      end
    end
    dumpJunk()
    goTo(0)
  end

  ----------------------------------------------------------------------
  -- main loop
  ----------------------------------------------------------------------
  --- Is there a bee housing on that world side of the robot?
  local function housingAt(side)
    local ok, res, msg = pcall(beekeeper.canWork, side)
    if not ok then return false end
    return not (res == false and tostring(msg or ""):find("No bee housing", 1, true))
  end

  --- Find the housing's compass side, then turn the body to face it (the
  --- housing is the only sizeable inventory next to the parking spot).
  local function orient()
    goTo(0)
    if not housingSide then
      for _, side in ipairs({ 2, 3, 4, 5 }) do
        if housingAt(side) then housingSide = side break end
      end
    end
    if not housingSide then
      say("WARNING: no bee housing next to the robot at parking level; check the placement")
      return false
    end
    local names = { [2] = "north", [3] = "south", [4] = "west", [5] = "east" }
    for turn = 0, 3 do
      local size = invctl.getInventorySize(sides.front)
      if size and size >= 4 then
        say("housing is to the %s%s", names[housingSide] or tostring(housingSide), turn > 0 and (", turned " .. turn .. " time(s) to face it") or "")
        return true
      end
      robot.turnLeft()
    end
    say("WARNING: housing found to the %s but nothing with an inventory in front after turning; check the placement", names[housingSide] or "?")
    return false
  end

  ---Announce, recover from an interrupted job. Call once before step().
  function obj:start()
    cfg.climateKeys = cfg.climateKeys or { heater = true, cooler = true, humidifier = true, dryer = true, hell = true,
      desert = true, plains = true, jungle = true, winter = true, ocean = true }
    say("cell '%s' starting (housing %s, level %d)", cfg.name, cfg.housing, level)
    orient()
    if state.job then
      say("recovering from an interrupted job %s", tostring(state.job.id))
      local aborted = state.job
      state.job = nil
      saveState()
      local okSweep, err = pcall(sweep)
      if not okSweep then say("sweep failed: %s", tostring(err)) end
      tell("aborted", { job = aborted.id, reason = "robot restarted" })
    end
    self.lastHello, self.lastIdle = 0, 0
    self.jobsDone = 0
  end

  ---One loop iteration: keep in touch with the controller, run a pending job.
  function obj:step()
    if not controller and util.now() - self.lastHello > 5 then
      link:broadcast("hello", { name = cfg.name, housing = cfg.housing })
      self.lastHello = util.now()
    end
    if controller and util.now() - self.lastIdle > 20 then
      link:send(controller, "idle", { name = cfg.name, housing = cfg.housing, foundation = state.foundation })
      self.lastIdle = util.now()
    end
    pump(1)
    if pendingProbe then
      local req = pendingProbe
      pendingProbe = nil
      local ok, res = pcall(runProbe, req.payload)
      if not ok then res = { reqId = req.payload.reqId, cell = cfg.name, error = tostring(res) } end
      say("probe %s: size=%s %s", tostring(req.payload.where or "down"), tostring(res.size),
        res.error and ("error " .. res.error) or (res.filled ~= "" and res.filled or "empty"))
      link:send(req.remote, "probeResult", res)
    end
    if not pendingJob then return false end

    local job = pendingJob
    pendingJob = nil
    cancelRequested = false
    state.job = job
    saveState()
    say("job %s: %s + %s -> %s (keep %d)", job.id, tostring(job.a), tostring(job.b), job.target, job.keepDrones or 0)
    local okRun, res = pcall(breeder.run, api, job)
    state.job = nil
    saveState()
    if not okRun then
      say("job crashed: %s", tostring(res))
      tell("result", { job = job.id, ok = false, reason = "crash: " .. tostring(res) })
      pcall(sweep)
    else
      tell("result", { job = job.id, ok = res.ok, reason = res.reason, generations = res.generations,
        archivedDrones = res.archivedDrones, princess = res.princess, honey = res.honey })
      if not res.ok then pcall(sweep) end
    end
    goTo(0)
    self.lastIdle = 0
    self.jobsDone = self.jobsDone + 1
    return true
  end

  function obj:run()
    self:start()
    while true do self:step() end
  end

  obj.api = api

  setmetatable(obj, self)
  self.__index = self
  return obj
end

return cell
