-- fake_oc : an in-process stand-in for the OpenComputers APIs used by
-- src/controller.lua and src/cell.lua, so both can run together in one Lua
-- state with a simulated GT Industrial Apiary, ME network, and modems.
--
-- Usage (see test_integration.lua):
--   local fake = require("fake_oc")
--   local env = fake.install({ sim = require("sim_genetics"), seed = 7 })
--   env.side = "controller"   -- component.list() answers for the controller
--   ... require and init the controller ...
--   env.side = "robot"
--   ... require and create the cell ...
local fake = {}

function fake.install(opts)
  local sim = opts.sim
  local rng = sim.rng(opts.seed or 1)
  local env = { side = "controller", clock = 1000, log = {} }

  ------------------------------------------------------------------
  -- clock / computer / os.sleep
  ------------------------------------------------------------------
  local ticks = {}   -- functions run whenever fake time advances
  local function advance(seconds)
    env.clock = env.clock + seconds
    for _, f in ipairs(ticks) do f(seconds) end
  end
  env.advance = advance
  package.loaded["computer"] = { uptime = function() return env.clock end, address = function() return "computer-0" end }
  os.sleep = function(s) advance(s or 0.05) end

  ------------------------------------------------------------------
  -- ME network
  ------------------------------------------------------------------
  local me = { items = {}, patterns = {}, crafts = {}, craftRequests = {} }
  env.me = me

  local function stackMatches(st, filter)
    for k, v in pairs(filter or {}) do
      local sv = st[k]
      if sv == nil then return false end
      if type(v) == "number" and type(sv) == "number" then
        if math.floor(v) ~= math.floor(sv) then return false end
      elseif tostring(v) ~= tostring(sv) then return false end
    end
    return true
  end

  function me.add(stack) me.items[#me.items + 1] = stack return stack end
  function me.count(label)
    local n = 0
    for _, st in ipairs(me.items) do if st.label == label then n = n + (st.size or 1) end end
    return n
  end
  --- take up to `count` items matching label out of the network -> list of stacks
  function me.take(label, count)
    local out = {}
    local i = 1
    while i <= #me.items and count > 0 do
      local st = me.items[i]
      if st.label == label then
        if (st.size or 1) <= count then
          table.remove(me.items, i)
          count = count - (st.size or 1)
          out[#out + 1] = st
        else
          st.size = st.size - count
          local piece = {}
          for k, v in pairs(st) do piece[k] = v end
          piece.size = count
          count = 0
          out[#out + 1] = piece
        end
      else
        i = i + 1
      end
    end
    return out
  end
  ticks[#ticks + 1] = function()
    for i = #me.crafts, 1, -1 do
      local c = me.crafts[i]
      if env.clock >= c.doneAt then
        me.add({ name = "fake:" .. c.label:gsub("%s", ""), label = c.label, size = c.count })
        table.remove(me.crafts, i)
      end
    end
  end

  local database = { address = "db-0000", slots = {} }
  function database.get(slot) return database.slots[slot] end
  function database.clear(slot) database.slots[slot] = nil return true end

  local function networkApi(proxy)
    function proxy.getItemsInNetwork(filter)
      local out = {}
      for _, st in ipairs(me.items) do if stackMatches(st, filter) then out[#out + 1] = st end end
      return out
    end
    function proxy.getCraftables(filter)
      local out = {}
      for _, label in ipairs(me.patterns) do
        if not filter or not filter.label or filter.label == label then
          out[#out + 1] = {
            getItemStack = function() return { label = label, size = 1 } end,
            request = function(n)
              me.crafts[#me.crafts + 1] = { label = label, count = n or 1, doneAt = env.clock + 3 }
              me.craftRequests[#me.craftRequests + 1] = label
              return { isDone = function() return false end, isCanceled = function() return false end }
            end,
          }
        end
      end
      return out
    end
    function proxy.store(filter, dbAddr, slot, count)
      assert(dbAddr == database.address, "unknown database")
      for _, st in ipairs(me.items) do
        if stackMatches(st, filter) then
          local copy = {}
          for k, v in pairs(st) do copy[k] = v end
          copy.size = 1
          database.slots[slot or 1] = copy
          return true
        end
      end
      return true
    end
    return proxy
  end

  local function newInterface(address)
    local iface = networkApi({ address = address, type = "me_interface", config = {} })
    --- Faithful to GTNH: configuration slots count from zero, so config
    --- index 0 is the slot the robot reads as 1.
    function iface.setInterfaceConfiguration(idx, dbAddr, entry, size)
      if idx < 0 or idx > 8 then return false end
      if dbAddr == nil then iface.config[idx] = nil return true end
      local st = database.slots[entry]
      if not st then return false end
      iface.config[idx] = { label = st.label, size = size or 1 }
      return true
    end
    --- what the robot sees in slot `slot` (materialised from the network on demand)
    function iface.peek(slot)
      local c = iface.config[slot - 1]
      if not c then return nil end
      local n = math.min(c.size, me.count(c.label))
      if n == 0 then return nil end
      return { label = c.label, size = n }
    end
    return iface
  end
  local mainIface = newInterface("iface-main")
  local beeIface = newInterface("iface-bees")
  env.mainIface, env.beeIface = mainIface, beeIface

  ------------------------------------------------------------------
  -- modems and events
  ------------------------------------------------------------------
  local listeners = {}     -- name -> { callbacks }
  local robotQueue = {}
  local modems = {}
  local function deliver(toAddr, fromAddr, port, ...)
    local sig = { "modem_message", toAddr, fromAddr, port, 1, ... }
    if toAddr == "modem-robot" then
      robotQueue[#robotQueue + 1] = sig
    else
      for _, cb in ipairs(listeners["modem_message"] or {}) do cb(table.unpack(sig, 1, #sig)) end
    end
  end
  local function newModem(address)
    local m = { address = address, type = "modem" }
    function m.open() return true end
    function m.isWireless() return true end
    function m.setStrength() return true end
    function m.send(addr, port, ...) deliver(addr, address, port, ...) return true end
    function m.broadcast(port, ...)
      for _, other in ipairs(modems) do if other.address ~= address then deliver(other.address, address, port, ...) end end
      return true
    end
    modems[#modems + 1] = m
    return m
  end
  local ctlModem, robotModem = newModem("modem-ctl"), newModem("modem-robot")

  local eventLib = {}
  function eventLib.listen(name, cb)
    listeners[name] = listeners[name] or {}
    table.insert(listeners[name], cb)
    return true
  end
  function eventLib.ignore(name, cb)
    for i, c in ipairs(listeners[name] or {}) do if c == cb then table.remove(listeners[name], i) return true end end
    return false
  end
  function eventLib.pull(timeout, filter)
    if type(timeout) == "string" then filter, timeout = timeout, nil end
    if #robotQueue > 0 and (filter == nil or robotQueue[1][1] == filter) then
      local sig = table.remove(robotQueue, 1)
      return table.unpack(sig, 1, #sig)
    end
    advance(timeout or 0.05)
    return nil
  end
  function eventLib.push() end
  function eventLib.timer() return 1 end
  function eventLib.cancel() return true end
  package.loaded["event"] = eventLib

  ------------------------------------------------------------------
  -- robot world: inventory, column, housing, chest
  ------------------------------------------------------------------
  local world = {
    inv = {}, invSize = 32, selected = 1, level = 0,
    foundation = "Dirt", chest = {}, chestSize = 27,
    housing = { queen = nil, drone = nil, upgrades = {}, ticksLeft = 0, working = false, matings = 0 },
    placed = {}, swung = 0,
  }
  env.world = world
  local housing = world.housing

  local function conditionsMet(m)
    if m.foundation and world.foundation ~= m.foundation then return false end
    if m.temperature == "Hot" then
      local heaters = 0
      for _, u in pairs(housing.upgrades) do if u.label:lower():find("heater", 1, true) then heaters = heaters + (u.size or 1) end end
      if heaters < 1 then return false end
    end
    return true
  end

  local function chestAdd(st)
    for s = 1, world.chestSize do if not world.chest[s] then world.chest[s] = st return true end end
    return false
  end

  --- GregTech style: the machine pulls the princess and the drone straight
  --- into its recipe, so both slots read empty while it works and nothing
  --- resembling a queen is ever visible. Offspring appear in the chest.
  local function gtTick()
    local q = housing.queen
    if q and q._kind == "princess" and housing.drone then
      local d = housing.drone
      housing.pending = { p = { _a = q._a, _b = q._b }, d = { _a = d._a, _b = d._b } }
      housing.queen = nil
      d.size = (d.size or 1) - 1
      if d.size <= 0 then housing.drone = nil end
      -- a real cycle outlasts the robot's start timeout, so the slots stay
      -- empty for a good while before anything reaches the chest
      housing.doneAt = env.clock + 30
      housing.matings = housing.matings + 1
    elseif housing.pending then
      if env.clock >= (housing.doneAt or 0) then
        local pend = housing.pending
        housing.pending = nil
        local princess = sim.offspring("princess", pend.p, pend.d, rng, conditionsMet)
        princess._kind = "princess"
        chestAdd(princess)
        for _ = 1, sim.fertilityOf(pend.p._a) do
          local drone = sim.offspring("drone", pend.p, pend.d, rng, conditionsMet)
          drone._kind = "drone"
          chestAdd(drone)
        end
        chestAdd({ name = "Forestry:beeCombs", label = "Honey Comb", size = 2 })
      end
    end
  end

  ticks[#ticks + 1] = function()
    if world.gtStyle then return gtTick() end
    local q = housing.queen
    if q and q._kind == "princess" and housing.drone then
      -- mate: princess + one drone -> queen
      local d = housing.drone
      local queen = sim.mkBee("queen", q._a, q._b, true)
      queen._mate = { _a = d._a, _b = d._b }
      queen._kind = "queen"
      housing.queen = queen
      d.size = (d.size or 1) - 1
      if d.size <= 0 then housing.drone = nil end
      housing.ticksLeft = 3
      housing.matings = housing.matings + 1
    elseif q and q._kind == "queen" then
      housing.ticksLeft = housing.ticksLeft - 1
      if housing.ticksLeft <= 0 then
        local p = { _a = q._a, _b = q._b }
        local d = q._mate
        local princess = sim.offspring("princess", p, d, rng, conditionsMet)
        princess._kind = "princess"
        chestAdd(princess)
        for _ = 1, sim.fertilityOf(p._a) do
          local drone = sim.offspring("drone", p, d, rng, conditionsMet)
          drone._kind = "drone"
          chestAdd(drone)
        end
        chestAdd({ name = "Forestry:beeCombs", label = "Honey Comb", size = 2 })
        housing.queen = nil
      end
    end
  end

  local sides = { bottom = 0, top = 1, back = 2, front = 3, right = 4, left = 5, down = 0, up = 1 }
  package.loaded["sides"] = sides

  local function invFirstFree(from)
    for s = from or 1, world.invSize do if not world.inv[s] then return s end end
    return nil
  end
  --- like OC: merge into a matching stack (non-bee items) in the preferred
  --- slot first, otherwise use the preferred slot if empty, else the first free one
  --- Two bees stack when their genome and analysis state match, exactly as
  --- in game. This matters: offspring merge into the stack the robot keeps
  --- as a spare mate instead of landing in a slot of their own.
  local function sameItem(x, y)
    if x.label ~= y.label or x.name ~= y.name then return false end
    local xb, yb = x.individual ~= nil, y.individual ~= nil
    if xb ~= yb then return false end
    if not xb then return true end
    return x._a == y._a and x._b == y._b and x._kind == y._kind
      and (x.individual.isAnalyzed == true) == (y.individual.isAnalyzed == true)
  end

  local function invInsert(st, preferred)
    if preferred and world.inv[preferred] and sameItem(world.inv[preferred], st) then
      world.inv[preferred].size = (world.inv[preferred].size or 1) + (st.size or 1)
      return true
    end
    for slot = 1, world.invSize do
      local other = world.inv[slot]
      if other and other ~= st and sameItem(other, st) and (other.size or 1) < 64 then
        other.size = (other.size or 1) + (st.size or 1)
        return true
      end
    end
    local target = (preferred and not world.inv[preferred]) and preferred or invFirstFree(3)
    if not target then return false end
    world.inv[target] = st
    return true
  end

  local robotLib = {}
  function robotLib.select(s) world.selected = s return s end
  function robotLib.count(s) local st = world.inv[s] return st and (st.size or 1) or 0 end
  function robotLib.inventorySize() return world.invSize end
  function robotLib.up() world.level = world.level + 1 return true end
  function robotLib.down() world.level = world.level - 1 return true end
  world.facing = 0
  function robotLib.turnLeft() world.facing = (world.facing + 1) % 4 world.turns = (world.turns or 0) + 1 return true end
  function robotLib.turnRight() world.facing = (world.facing + 3) % 4 return true end
  function robotLib.detect(side)
    if side == sides.front and world.level == -1 then return world.foundation ~= nil, "solid" end
    if side == sides.up and world.level == 1 then return true, "solid" end
    if side == sides.down and world.level == -1 then return true, "solid" end
    return false, "air"
  end
  function robotLib.compare(side)
    if side == sides.front and world.level == -1 then
      local st = world.inv[world.selected]
      return st ~= nil and st.label == world.foundation
    end
    return false
  end
  function robotLib.swing(side)
    if side == sides.front and world.level == -1 and world.foundation then
      world.swung = world.swung + 1
      invInsert({ name = "fake:" .. world.foundation:gsub("%s", ""), label = world.foundation, size = 1 })
      world.foundation = nil
      return true, "block"
    end
    return false, "air"
  end
  function robotLib.transferTo(toSlot, count)
    local st = world.inv[world.selected]
    if not st or toSlot == world.selected then return false end
    local n = math.min(count or (st.size or 1), st.size or 1)
    local dst = world.inv[toSlot]
    if dst then
      if dst.label ~= st.label or dst.individual then return false end
      dst.size = (dst.size or 1) + n
    else
      local piece = {}
      for k, v in pairs(st) do piece[k] = v end
      piece.size = n
      world.inv[toSlot] = piece
    end
    st.size = (st.size or 1) - n
    if st.size <= 0 then world.inv[world.selected] = nil end
    return true
  end
  function robotLib.drop(side, count)
    local st = world.inv[world.selected]
    if not st then return false end
    if side == sides.up and world.level == 0 then
      local have = st.size or 1
      local n = math.min(count or have, have)
      world.voided = (world.voided or 0) + n
      world.voidedLabels = world.voidedLabels or {}
      world.voidedLabels[#world.voidedLabels + 1] = string.format("%s x%d", tostring(st.label), n)
      if n >= have then world.inv[world.selected] = nil else st.size = have - n end
      return true
    end
    return false
  end
  function robotLib.place(side)
    if side == sides.front and world.level == -1 and world.foundation == nil then
      local st = world.inv[world.selected]
      if not st then return false, "nothing selected" end
      world.foundation = st.label
      world.placed[#world.placed + 1] = st.label
      st.size = (st.size or 1) - 1
      if st.size <= 0 then world.inv[world.selected] = nil end
      return true
    end
    return false, "cannot place"
  end
  package.loaded["robot"] = robotLib

  local invctl = { type = "inventory_controller", address = "invctl-0" }
  local function sideTarget(side)
    -- relative sides: the housing is in front only while the body faces it (facing 0);
    -- facing 2 has the charger (a 1-slot inventory) in front
    if world.level == 0 and side == sides.front and world.facing == 2 then return "charger" end
    if world.level == 0 and side == sides.front and world.facing ~= 0 then return nil end
    if world.level == 0 and side == sides.front then return "housing" end
    if world.level == 1 and side == sides.front then return "chest" end
    if world.level == 1 and side == sides.up then return "main" end
    if world.level == -1 and side == sides.down then return "bees" end
    return nil
  end
  function invctl.getStackInInternalSlot(s) return world.inv[s] end
  function invctl.getInventorySize(side)
    local t = sideTarget(side)
    if t == "chest" then return world.chestSize end
    if t == "housing" then return 16 end
    if t == "charger" then return 1 end
    if t then return 9 end
    return nil
  end
  function invctl.getStackInSlot(side, slot)
    local t = sideTarget(side)
    if t == "housing" then
      if slot == 6 then return housing.queen end
      if slot == 7 then return housing.drone end
      return nil
    elseif t == "chest" then return world.chest[slot]
    elseif t == "main" then return mainIface.peek(slot)
    elseif t == "bees" then return beeIface.peek(slot) end
    return nil
  end
  function invctl.suckFromSlot(side, slot, count)
    local t = sideTarget(side)
    if t == "chest" then
      local st = world.chest[slot]
      if not st then return false end
      world.chest[slot] = nil
      return invInsert(st, world.selected)
    elseif t == "main" or t == "bees" then
      local iface = (t == "main") and mainIface or beeIface
      local c = iface.config[slot - 1]   -- config indices count from zero
      if not c then return false end
      local n = math.min(count or c.size, c.size)
      local got = me.take(c.label, n)
      if #got == 0 then return false end
      -- several distinct stacks may come out; the first goes to the selected slot
      local first = true
      for _, st in ipairs(got) do
        if not invInsert(st, first and world.selected or nil) then me.add(st) end
        first = false
      end
      return true
    end
    return false
  end
  function invctl.dropIntoSlot(side, slot, count)
    local t = sideTarget(side)
    if t ~= "main" and t ~= "bees" then return false end
    local st = world.inv[world.selected]
    if not st then return false end
    local n = math.min(count or (st.size or 1), st.size or 1)
    if n >= (st.size or 1) then
      world.inv[world.selected] = nil
      me.add(st)
    else
      st.size = st.size - n
      local piece = {}
      for k, v in pairs(st) do piece[k] = v end
      piece.size = n
      me.add(piece)
    end
    return true
  end

  local beekeeper = { type = "beekeeper", address = "beekeeper-0" }
  function beekeeper.swapQueen(side)
    if world.level ~= 0 or side ~= 3 then return false, "no housing" end
    local mine = world.inv[world.selected]
    world.inv[world.selected], housing.queen = housing.queen, mine
    if housing.queen and not housing.queen._kind then housing.queen._kind = "princess" end
    return true
  end
  function beekeeper.swapDrone(side)
    if world.level ~= 0 or side ~= 3 then return false, "no housing" end
    local mine = world.inv[world.selected]
    world.inv[world.selected], housing.drone = housing.drone, mine
    return true
  end
  function beekeeper.analyze(honeySlot)
    local st = world.inv[world.selected]
    if not st or not st.individual then return false, "Not a bee" end
    local honey = world.inv[honeySlot]
    if not honey or (honey.size or 0) < 1 then return false, "No honey!" end
    if not st.individual.isAnalyzed then
      sim.analyze(st)
      honey.size = honey.size - 1
      if honey.size <= 0 then world.inv[honeySlot] = nil end
      env.honeyUsed = (env.honeyUsed or 0) + 1
    end
    return true
  end
  function beekeeper.getIndustrialUpgrade(_, i) return housing.upgrades[i] end
  function beekeeper.addIndustrialUpgrade(_, amount)
    local st = world.inv[world.selected]
    if not st then return 0 end
    for i = 1, 4 do
      if not housing.upgrades[i] then
        local n = math.min(amount or st.size, st.size or 1)
        housing.upgrades[i] = { label = st.label, size = n }
        st.size = (st.size or 1) - n
        if st.size <= 0 then world.inv[world.selected] = nil end
        return n
      end
    end
    return 0
  end
  function beekeeper.removeIndustrialUpgrade(_, i, amount)
    local u = housing.upgrades[i]
    if not u then return 0 end
    local n = math.min(amount or u.size, u.size)
    invInsert({ label = u.label, size = n, name = "fake:upgrade" }, world.selected)
    u.size = u.size - n
    if u.size <= 0 then housing.upgrades[i] = nil end
    return n
  end
  -- Beekeeper calls take world sides: the housing is to the south (3) of the
  -- parking spot whatever way the robot faces
  local HOUSING_SIDE = 3
  function beekeeper.canWork(side)
    if world.level == 0 and side == HOUSING_SIDE then return true end
    return false, "No bee housing found"
  end
  function beekeeper.getBeeProgress() return 0 end

  ------------------------------------------------------------------
  -- internet card (optional): records every request, answers 200
  ------------------------------------------------------------------
  env.http = {}
  local internet = { type = "internet", address = "internet-0" }
  function internet.isHttpEnabled() return true end
  function internet.request(url, body, headers, method)
    local entry = { url = url, body = body, headers = headers, method = method or (body and "POST" or "GET") }
    env.http[#env.http + 1] = entry
    local reply = (env.httpReply and env.httpReply(entry)) or '{"id":"' .. tostring(#env.http) .. '"}'
    local served = false
    return {
      finishConnect = function() return true end,
      read = function() if served then return nil end served = true return reply end,
      response = function() return 200, "OK", {} end,
      close = function() end,
    }
  end

  ------------------------------------------------------------------
  -- component registry
  ------------------------------------------------------------------
  local registry = {
    controller = {
      { addr = mainIface.address, type = "me_interface", proxy = mainIface },
      { addr = beeIface.address, type = "me_interface", proxy = beeIface },
      { addr = database.address, type = "database", proxy = database },
      { addr = ctlModem.address, type = "modem", proxy = ctlModem },
    },
    robot = {
      { addr = beekeeper.address, type = "beekeeper", proxy = beekeeper },
      { addr = invctl.address, type = "inventory_controller", proxy = invctl },
      { addr = robotModem.address, type = "modem", proxy = robotModem },
      { addr = "robot-0", type = "robot", proxy = {} },
    },
  }
  local componentLib = {}
  local function all()
    local out = {}
    for _, e in ipairs(registry.controller) do out[#out + 1] = e end
    for _, e in ipairs(registry.robot) do out[#out + 1] = e end
    return out
  end
  function componentLib.list(filter)
    local entries = registry[env.side] or {}
    local i = 0
    return function()
      while true do
        i = i + 1
        local e = entries[i]
        if not e then return nil end
        if filter == nil or e.type == filter then return e.addr, e.type end
      end
    end
  end
  function componentLib.proxy(addr)
    for _, e in ipairs(all()) do if e.addr == addr then return e.proxy end end
    error("no such component " .. tostring(addr))
  end
  function componentLib.type(addr)
    for _, e in ipairs(all()) do if e.addr == addr then return e.type end end
    return nil
  end
  function componentLib.isAvailable(t)
    for _, e in ipairs(registry[env.side] or {}) do if e.type == t then return true end end
    return false
  end
  setmetatable(componentLib, { __index = function(_, key)
    for _, e in ipairs(registry[env.side] or {}) do if e.type == key then return e.proxy end end
    return nil
  end })
  package.loaded["component"] = componentLib
  env.component = componentLib
  function env.enableInternet()
    table.insert(registry.controller, { addr = internet.address, type = "internet", proxy = internet })
  end

  ------------------------------------------------------------------
  -- logger stand-in (same interface as lib.logger-lib)
  ------------------------------------------------------------------
  env.logger = {
    info = function(_, m) env.log[#env.log + 1] = "I " .. tostring(m) end,
    warning = function(_, m) env.log[#env.log + 1] = "W " .. tostring(m) end,
    error = function(_, m) env.log[#env.log + 1] = "E " .. tostring(m) end,
    debug = function() end,
  }

  -- fresh copies of our modules bound to the fake libraries
  for name in pairs(package.loaded) do
    if type(name) == "string" and name:match("^src%.") then package.loaded[name] = nil end
  end

  return env
end

return fake
