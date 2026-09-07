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

  local function ensureHoney()
    if robot.count(cfg.slots.honey) >= cfg.honeyMin then return true end
    local reply = ask({ honey = true, count = cfg.honeyFetch })
    goTo(1)
    robot.select(cfg.slots.honey)
    local slot = reply and reply.slot or cfg.interface.main.honey
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
    local moved = invctl.suckFromSlot(sides.up, reply.slot or cfg.interface.main.supply, count or 1)
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
    ensureHoney()
    robot.select(slot)
    local ok, err = beekeeper.analyze(cfg.slots.honey)
    if not ok then return false, err end
    return true
  end

  function api.fetch(species, kind, count)
    for attempt = 1, 3 do
      local reply, err = ask({ species = species, kind = kind, count = count })
      if not reply then return nil, err end
      goTo(-1)
      local slot = firstEmpty()
      if not slot then return nil, "robot inventory full" end
      robot.select(slot)
      invctl.suckFromSlot(sides.down, reply.slot, count)
      tell("got", { reqId = reply.reqId })
      local st = stackIn(slot)
      if not st then
        say("fetch %s %s: nothing arrived (attempt %d)", tostring(species), kind, attempt)
      elseif genome.kind(st) ~= kind then
        say("fetch: got %s instead of %s, returning it", tostring(genome.kind(st)), kind)
        dumpSlot(slot)
      else
        if species and not genome.analyzed(st) then api.analyze(slot); st = stackIn(slot) end
        if species and kind == "drone" and not genome.isPure(st, species) then
          -- impure library stock: never return it to the network
          say("fetch: %s is not a pure %s, quarantining", genome.describe(st), species)
          tell("badstock", { species = species, kind = kind, got = genome.summary(st) })
          api.discard(slot)
        else
          -- princesses are always usable: the breeder converts an impure one
          return slot
        end
      end
    end
    return nil, "library did not deliver a pure " .. tostring(species) .. " " .. kind
  end

  function api.insertQueen(slot)
    goTo(0)
    robot.select(slot)
    local ok, err = beekeeper.swapQueen(sides.front)
    if not ok then return false, err or "swapQueen refused" end
    return true
  end

  function api.insertDrone(slot)
    goTo(0)
    robot.select(slot)
    local ok, err = beekeeper.swapDrone(sides.front)
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
    local ok = beekeeper.swapDrone(sides.front)
    if not ok or robot.count(slot) == 0 then return nil end
    return slot
  end

  local function queenSlotStack()
    local ok, st = pcall(invctl.getStackInSlot, sides.front, hs.slots.queen)
    if ok and type(st) == "table" then return st end
    return nil
  end

  local function outputChestHas(kind)
    goTo(1)
    local size = invctl.getInventorySize(sides.front) or 0
    for s = 1, size do
      local st = invctl.getStackInSlot(sides.front, s)
      if st and genome.kind(st) == kind then return true end
    end
    return false
  end

  function api.waitCycle()
    goTo(0)
    local t0 = util.now()
    local started = false
    while util.now() - t0 < cfg.startTimeout do
      local q = queenSlotStack()
      if q and genome.kind(q) == "queen" then started = true break end
      if q == nil and util.now() - t0 > 4 then break end
      pump(0.25)
    end
    if not started then
      if outputChestHas("princess") then return "done" end
      if outputChestHas("queen") then return "notstarted", "the queen was ejected: enable Auto-Queen on the machine" end
      goTo(0)
      if queenSlotStack() == nil then return "notstarted", "queen slot empty: no power, no drone, or machine disabled?" end
    end
    local t1 = util.now()
    local stuckSince = nil
    while true do
      local q = queenSlotStack()
      if q == nil then return "done" end
      if cancelRequested then return "cancelled" end
      if hs.reportsProgress then
        local okW, canWork = pcall(beekeeper.canWork, sides.front)
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

  function api.archive(slot, count)
    goTo(-1)
    robot.select(slot)
    local ok = invctl.dropIntoSlot(sides.down, cfg.interface.bees.archive, count)
    if not ok then
      for s = 1, 9 do
        if s ~= cfg.interface.bees.princess and s ~= cfg.interface.bees.drone then
          if invctl.dropIntoSlot(sides.down, s, count) then ok = true break end
        end
      end
    end
    return ok
  end

  --- Junk bees never go back into the ME network (the library would hand
  --- them out again). They are dropped into the air above the parking spot
  --- and despawn.
  function api.discard(slot)
    if robot.count(slot) == 0 then return true end
    local st = stackIn(slot)
    if st and not genome.isBee(st) then return dumpSlot(slot) end
    goTo(0)
    robot.select(slot)
    local ok = robot.drop(sides.up)
    return ok or robot.count(slot) == 0
  end

  function api.setFoundation(block)
    if not hs.caps.foundation then return true end
    if state.foundation == block then return true end
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
      local ok, st = pcall(beekeeper.getIndustrialUpgrade, sides.front, i)
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
    local ok, moved = pcall(beekeeper.removeIndustrialUpgrade, sides.front, index, count)
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
        local ok, added = pcall(beekeeper.addIndustrialUpgrade, sides.front, needCount)
        if not ok or (tonumber(added) or 0) < needCount then
          for i, u in pairs(installedUpgrades()) do
            if u.key and not cfg.keepUpgrades[u.key] and not cfg.climateKeys[u.key] then
              removeUpgrade(i, u.count)
              break
            end
          end
          robot.select(slot)
          ok, added = pcall(beekeeper.addIndustrialUpgrade, sides.front, needCount)
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
      beekeeper.swapQueen(sides.front)
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
      else
        api.discard(e.slot)
      end
    end
    dumpJunk()
    goTo(0)
  end

  ----------------------------------------------------------------------
  -- main loop
  ----------------------------------------------------------------------
  ---Announce, recover from an interrupted job. Call once before step().
  function obj:start()
    cfg.climateKeys = cfg.climateKeys or { heater = true, cooler = true, humidifier = true, dryer = true, hell = true,
      desert = true, plains = true, jungle = true, winter = true, ocean = true }
    say("cell '%s' starting (housing %s, level %d)", cfg.name, cfg.housing, level)
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
