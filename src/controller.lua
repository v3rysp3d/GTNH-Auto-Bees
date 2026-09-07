-- Controller: planner, job queue, cell dispatcher, library bookkeeping,
-- command handling for the GUI and Discord.
--
-- Lives on the computer. Needs on its OC network: an ME network component,
-- per cell two ME Interfaces each behind an Adapter with a Database upgrade,
-- a modem, and optionally an internet card for Discord.
local component = require("component")
local event = require("event")

local util = require("src.util")
local graph = require("src.graph")
local catalog = require("src.catalog")
local conditions = require("src.conditions")
local climate = require("src.climate")
local needs = require("src.needs")
local ae2 = require("src.ae2")
local net = require("src.net")
local discord = require("src.discord")
local survey = require("src.survey")
local settings = require("src.settings")
local connect = require("src.connect")

---@class ControllerConfig
---@field dataDir string
---@field port number
---@field ae2 table
---@field cells table
---@field stations table
---@field defaults table
---@field discord table

local controller = {}

--- Strip characters the gui-lib template engine treats as markup.
local function clean(s)
  return (tostring(s):gsub("[%$#&@?]", ""))
end

---Create a controller
---@param cfg ControllerConfig
---@param logger Logger
function controller:new(cfg, logger)
  local obj = {}
  obj.cfg = cfg
  obj.logger = logger
  obj.running = false

  obj.cells = {}            -- name -> { addr, status, lastSeen, job, housing, foundation, gen, phase, cfg }
  obj.library = {}          -- species -> counts
  obj.libraryScannedAt = 0
  obj.requestsByReqId = {}
  obj.discordQueue = {}
  obj.lastPoll, obj.lastStatusPost, obj.statusMsgId = 0, 0, nil
  obj.commandOutput = {}

  ----------------------------------------------------------------------
  -- logging helpers
  ----------------------------------------------------------------------
  function obj:log(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    self.logger:info(clean(msg))
  end

  function obj:warn(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    self.logger:warning(clean(msg))
  end

  function obj:notify(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    self.logger:info(clean(msg))
    if self.discordOn then self.discordQueue[#self.discordQueue + 1] = msg end
  end

  ----------------------------------------------------------------------
  -- init
  ----------------------------------------------------------------------
  function obj:init()
    local cfg = self.cfg
    util.mkdirs(cfg.dataDir)
    for _, p in ipairs(cfg.conditionPatterns or {}) do
      conditions.addPattern(p.pattern, function(m) return { kind = p.kind, name = m, block = m } end)
    end

    if not util.exists(cfg.dataDir .. "/graph.dat") then
      self:log("no graph.dat yet, running the survey")
      local ok, err = survey.run(cfg.dataDir, function(l) self:log("%s", l) end)
      if not ok then error("survey failed: " .. tostring(err)) end
    end
    local graphTable = util.loadTable(cfg.dataDir .. "/graph.dat")
    if not graphTable then error("cannot load " .. cfg.dataDir .. "/graph.dat") end
    self.graph = graph.fromTable(graphTable)
    self.cat = catalog.new(cfg.dataDir .. "/catalog.dat")
    self.cat:load()
    self.cat:assign(self.graph:speciesList())
    self.cat:save()

    self.statePath = cfg.dataDir .. "/state.dat"
    self.S = util.loadTable(self.statePath, { requests = {}, jobs = {}, nextId = 1 })
    self.S.requests = self.S.requests or {}
    self.S.jobs = self.S.jobs or {}
    self.S.nextId = self.S.nextId or 1
    for _, job in pairs(self.S.jobs) do
      if job.status == "running" then job.status = "pending"; job.cell = nil end
    end
    self:saveState()

    -- components
    local meProxy = ae2.findNetwork(component, cfg.ae2 and cfg.ae2.network)
    self.me = meProxy and ae2.new(meProxy) or nil
    if self.me then
      local dbAddr = (cfg.ae2 and cfg.ae2.database) or component.list("database")()
      if dbAddr then self.me:setDatabase(component.proxy(dbAddr)) end
    end
    local modemAddr = component.list("modem")()
    self.link = net.new(modemAddr and component.proxy(modemAddr) or nil, cfg.port, "controller")
    local internetAddr = component.list("internet")()
    self.internet = internetAddr and component.proxy(internetAddr) or nil
    self.settingsData = settings.load()
    self:connectDiscord()
    self.lastPush = 0

    self:log("controller: %d species, %d mutations, ME %s, modem %s, discord %s",
      util.count(self.graph.species), #self.graph.mutations, self.me and "ok" or "MISSING", modemAddr and "ok" or "MISSING",
      self.discordOn and "on" or "off")
    if not self.me then self:warn("no ME network component: library and stocking are disabled") end
    if self.me and not self.me.db then self:warn("no Database upgrade found: robots cannot be served") end

    self:scanLibrary(true)
    if self.discordOn then
      if not self.S.discordLastId then self.dc:syncCursor(); self.S.discordLastId = self.dc.lastId; self:saveState() end
      self.discordQueue[#self.discordQueue + 1] = "Auto Bees controller online. Type `" .. (dcfg.prefix or "!") .. "help`."
    end

    self.signalHandler = function(...) self:onSignal(...) end
    event.listen("modem_message", self.signalHandler)
    self.link:broadcast("whois", {})
    self.running = true
  end

  function obj:stop()
    self.running = false
    if self.signalHandler then event.ignore("modem_message", self.signalHandler) end
    self:saveState()
  end

  ---(Re)build the Discord bridge from the current config.
  function obj:connectDiscord()
    local dcfg = self.cfg.discord or {}
    local function nonEmpty(v) if v and v ~= "" then return v end return nil end
    self.dc = discord.new(self.internet, {
      token = nonEmpty(dcfg.token), channel = nonEmpty(dcfg.channel), webhook = nonEmpty(dcfg.webhook),
      lastId = self.S and self.S.discordLastId or nil,
    })
    self.discordOn = dcfg.enabled and self.dc:enabled() or false
  end

  ---Persist one setting and apply it live. path is relative to `controller`.
  function obj:setSetting(path, value)
    settings.set(self.settingsData, "controller." .. path, value)
    settings.save(self.settingsData)
    settings.set(self.cfg, path, value)
    if path:match("^discord") then self:connectDiscord() end
  end

  ---Status snapshot pushed to the custom host and shown by `status`.
  function obj:statusTable()
    local cells = {}
    for name, c in pairs(self.cells) do
      local job = c.job and self.S.jobs[c.job]
      cells[name] = { status = c.status, job = job and job.id or nil, target = job and job.target or nil,
        generation = c.gen, phase = c.phase, foundation = c.foundation }
    end
    local queue = {}
    for _, r in ipairs(self.S.requests) do
      if r.status ~= "done" then queue[#queue + 1] = { id = r.id, target = r.target, status = r.status, by = r.by } end
    end
    return { time = util.now(), cells = cells, queue = queue,
      librarySpecies = util.count(self:ownedSet()), princesses = self:princessPool() }
  end

  function obj:hostTick()
    local h = self.cfg.host or {}
    local interval = tonumber(h.pushInterval) or 0
    if not self.internet or (h.url or "") == "" or interval <= 0 then return end
    if util.now() - self.lastPush < interval then return end
    self.lastPush = util.now()
    local ok, why = connect.pushStatus(self.internet, h.url, self:statusTable())
    if not ok and not self.hostWarned then
      self.hostWarned = true
      self:warn("host push failed: %s", tostring(why))
    elseif ok then
      self.hostWarned = false
    end
  end

  function obj:saveState() util.saveTable(self.statePath, self.S) end

  ----------------------------------------------------------------------
  -- library
  ----------------------------------------------------------------------
  function obj:scanLibrary(force)
    if not self.me then return end
    if not force and util.now() - self.libraryScannedAt < (self.cfg.libraryScanInterval or 60) then return end
    local ok, lib = pcall(function() return self.me:library() end)
    if ok and type(lib) == "table" then
      self.library = lib
      self.libraryScannedAt = util.now()
    else
      self:warn("library scan failed: %s", tostring(lib))
    end
  end

  function obj:ownedSet()
    local owned = {}
    for name, b in pairs(self.library) do if b.drones > 0 then owned[name] = true end end
    return owned
  end

  function obj:princessPool()
    local n = 0
    for _, b in pairs(self.library) do n = n + b.princesses end
    return n
  end

  function obj:dronesOf(name) return self.library[name] and self.library[name].drones or 0 end
  function obj:princessesOf(name) return self.library[name] and self.library[name].princesses or 0 end

  ----------------------------------------------------------------------
  -- planning
  ----------------------------------------------------------------------
  function obj:stationAvailable(kind, name)
    local st = self.cfg.stations or {}
    if kind == "gtmachine" then return st.gtmachine == true end
    local list = st[kind]
    return list ~= nil and (list[name] == true or list["*"] == true)
  end

  function obj:conditionCost(conds, m)
    local cost = 0
    for _, c in ipairs(conds) do
      if c.kind == "foundation" then
        cost = cost + (self.cfg.foundationCostBase or 2)
        if self.me and self.me:countLabel(c.block) == 0 and not self.me:hasPattern(c.block) then cost = cost + 50 end
      elseif c.kind == "temperature" or c.kind == "humidity" then
        cost = cost + 1
      elseif c.kind == "dimension" or c.kind == "biomeId" or c.kind == "biome" or c.kind == "gtmachine" then
        local name = c.name or (c.types and table.concat(c.types, "/")) or c.kind
        if not self:stationAvailable(c.kind, name) then return nil end
        cost = cost + 5
      elseif c.kind == "daytime" or c.kind == "date" then
        cost = cost + 3
      elseif c.kind == "unknown" then
        cost = cost + 20
      end
    end
    if (self.cfg.effectBlacklist or {})[m.result] then return nil end
    return cost
  end

  function obj:planFor(target)
    return self.graph:plan(target, self:ownedSet(), {
      chanceWeight = self.cfg.chanceWeight or 0.1,
      conditionCost = function(conds, m) return self:conditionCost(conds, m) end,
    })
  end

  function obj:label(name) return self.cat:label(name) end

  ----------------------------------------------------------------------
  -- requests and jobs
  ----------------------------------------------------------------------
  function obj:newId(prefix)
    local id = prefix .. self.S.nextId
    self.S.nextId = self.S.nextId + 1
    return id
  end

  function obj:jobFromStep(req, step, keep)
    local d = self.cfg.defaults
    local foundation, needTemp, needHum
    for _, c in ipairs(step.conds or {}) do
      if c.kind == "foundation" then foundation = c.block end
      if c.kind == "temperature" then needTemp = { min = c.min, max = c.max } end
      if c.kind == "humidity" then needHum = { min = c.min, max = c.max } end
    end
    return {
      id = self:newId("j"), request = req.id, kind = "mutate",
      target = step.result, a = step.a, b = step.b, chance = step.chance, conds = step.conds,
      foundation = foundation, needTemp = needTemp, needHum = needHum,
      keepDrones = keep, wantPrincess = true,
      droneSupply = d.droneSupply, maxGenerations = d.maxGenerations, warnAfter = d.warnAfter,
      status = "pending", created = util.now(),
    }
  end

  function obj:stockJob(req, species, keep)
    local d = self.cfg.defaults
    return {
      id = self:newId("j"), request = req.id, kind = "stock",
      target = species, a = species, b = species, chance = 100, conds = {},
      keepDrones = keep, wantPrincess = true,
      droneSupply = d.droneSupply, maxGenerations = d.maxGenerations,
      status = "pending", created = util.now(),
    }
  end

  ---Create a request. opts: { keep = n, extra = { [species] = n }, keepAll = n }
  function obj:addRequest(targetName, opts, who)
    opts = opts or {}
    local d = self.cfg.defaults
    self:scanLibrary(true)
    local plan, why, blockers = self:planFor(targetName)
    if not plan then
      local msg = why
      if blockers then
        if #blockers.base > 0 then msg = msg .. "; hive species needed: " .. table.concat(blockers.base, ", ") end
        if #blockers.blocked > 0 then msg = msg .. "; blocked: " .. table.concat(blockers.blocked, " | ") end
      end
      return nil, msg
    end
    local S = self.S
    local req = { id = self:newId("r"), target = targetName, by = who or "gui", created = util.now(),
      keep = opts.keep or d.keepDrones, extra = opts.extra or {}, status = "active", jobs = {} }

    -- a step with chance p burns roughly 100/p parent drones before it hits
    local needed = {}
    for _, step in ipairs(plan.steps) do
      local n = math.min(64, math.ceil(100 / math.max(step.chance or 10, 1)) + 4)
      for _, parent in ipairs({ step.a, step.b }) do needed[parent] = math.max(needed[parent] or 0, n) end
    end
    local produced, stocked = {}, {}
    for _, step in ipairs(plan.steps) do produced[step.result] = true end
    for _, step in ipairs(plan.steps) do
      for _, parent in ipairs({ step.a, step.b }) do
        if not produced[parent] and not stocked[parent] and self:dronesOf(parent) < math.min(needed[parent] or 0, 16) then
          stocked[parent] = true
          local sj = self:stockJob(req, parent, needed[parent])
          S.jobs[sj.id] = sj
          req.jobs[#req.jobs + 1] = sj.id
        end
      end
      local keep = math.max(d.keepDrones, needed[step.result] or 0)
      if step.result == targetName then keep = req.keep end
      if opts.keepAll then keep = math.max(keep, opts.keepAll) end
      if req.extra[step.result] then keep = math.max(keep, req.extra[step.result]) end
      local job = self:jobFromStep(req, step, keep)
      S.jobs[job.id] = job
      req.jobs[#req.jobs + 1] = job.id
    end
    for species, n in pairs(req.extra) do
      if not produced[species] then
        if not self.graph.species[species] then return nil, "unknown extra species " .. species end
        local job = self:stockJob(req, species, n)
        S.jobs[job.id] = job
        req.jobs[#req.jobs + 1] = job.id
      end
    end
    if #plan.steps == 0 and util.count(req.extra) == 0 then
      local job = self:stockJob(req, targetName, req.keep)
      S.jobs[job.id] = job
      req.jobs[#req.jobs + 1] = job.id
    end
    S.requests[#S.requests + 1] = req
    self:saveState()
    return req, plan
  end

  function obj:jobReady(job)
    if job.status ~= "pending" then return false end
    if job.kind == "stock" then
      return self:dronesOf(job.target) > 0 and (self:princessesOf(job.target) > 0 or self:princessPool() > 0)
    end
    if self:dronesOf(job.a) == 0 or self:dronesOf(job.b) == 0 then return false end
    return self:princessPool() > 0
  end

  function obj:nextReadyJob()
    for _, req in ipairs(self.S.requests) do
      if req.status == "active" then
        for _, jid in ipairs(req.jobs) do
          local job = self.S.jobs[jid]
          if job and self:jobReady(job) then return job end
        end
      end
    end
    return nil
  end

  function obj:requestOf(job)
    for _, req in ipairs(self.S.requests) do if req.id == job.request then return req end end
  end

  function obj:updateRequestStatus(req)
    if not req then return end
    local allDone, anyFailed = true, false
    for _, jid in ipairs(req.jobs) do
      local job = self.S.jobs[jid]
      if job then
        if job.status ~= "done" then allDone = false end
        if job.status == "failed" then anyFailed = true end
      end
    end
    if allDone then req.status = "done" elseif anyFailed then req.status = "blocked" end
  end

  ----------------------------------------------------------------------
  -- cells
  ----------------------------------------------------------------------
  function obj:cellFor(name)
    local c = self.cells[name]
    if not c then
      c = { name = name, status = "unknown", lastSeen = 0, cfg = (self.cfg.cells or {})[name] or {} }
      self.cells[name] = c
    end
    return c
  end

  function obj:cellByAddr(addr)
    for _, c in pairs(self.cells) do if c.addr == addr then return c end end
  end

  local function ifaceProxy(addr)
    if not addr then return nil end
    local ok, p = pcall(component.proxy, addr)
    if ok and type(p) == "table" then return p end
    return nil
  end

  function obj:prepareJob(job, c)
    local base = c.cfg.base or { temp = 0.8, hum = 0.4 }
    if job.needTemp or job.needHum then
      local sol, why = climate.solve({ baseTemp = base.temp, baseHum = base.hum, needTemp = job.needTemp, needHum = job.needHum })
      if not sol then return false, "climate: " .. why end
      job.climate = climate.upgradeCounts(sol)
    else
      job.climate = {}
    end
    if job.foundation and self.me and self.me:countLabel(job.foundation) == 0 then
      local status, err = self.me:craft(job.foundation, 1)
      if status then self:notify("crafting %s for %s", job.foundation, self:label(job.target))
      else return false, "no " .. job.foundation .. " in stock and " .. tostring(err) end
    end
    return true
  end

  function obj:dispatch()
    for name, c in pairs(self.cells) do
      if c.status == "idle" and c.addr and not c.job then
        local job = self:nextReadyJob()
        if not job then return end
        local ok, why = self:prepareJob(job, c)
        if not ok then
          job.status = "failed"
          job.error = why
          self:notify("%s cannot start: %s", job.id, why)
          self:updateRequestStatus(self:requestOf(job))
          self:saveState()
        else
          job.status = "running"
          job.cell = name
          job.started = util.now()
          c.job = job.id
          c.status = "busy"
          c.gen, c.phase = 0, "prepare"
          self.link:send(c.addr, "job", {
            id = job.id, target = job.target, a = job.a, b = job.b, chance = job.chance,
            keepDrones = job.keepDrones, wantPrincess = job.wantPrincess, foundation = job.foundation,
            climate = job.climate, droneSupply = job.droneSupply, maxGenerations = job.maxGenerations, warnAfter = job.warnAfter,
          })
          self:notify("%s -> %s: %s + %s -> %s%s", job.id, name, self:label(job.a), self:label(job.b), self:label(job.target),
            job.foundation and (" [" .. job.foundation .. "]") or "")
          self:saveState()
        end
      end
    end
  end

  function obj:handleNeed(c, p, remote)
    local cfg = self.cfg
    local function fail(reason)
      self.link:send(remote, "fail", { reqId = p.reqId, reason = reason })
      self:log("%s need refused: %s", c.name, reason)
    end
    if not self.me or not self.me.db then return fail("controller has no ME network/database") end
    local mainIface = ifaceProxy(c.cfg.mainInterface)
    local beeIface = ifaceProxy(c.cfg.beeInterface)
    local slots = cfg.interface or { main = { honey = 1, supply = 2, dump = 9 }, bees = { princess = 1, drone = 2, archive = 9 } }
    if p.kind then
      if not beeIface then return fail("cell has no beeInterface configured") end
      local slot = (p.kind == "princess") and slots.bees.princess or slots.bees.drone
      local label
      if p.species then
        label = p.species .. (p.kind == "princess" and " Princess" or " Drone")
      else
        local bestName, bestN = nil, 0
        for name, b in pairs(self.library) do if b.princesses > bestN then bestName, bestN = name, b.princesses end end
        if not bestName then return fail("no princesses in the library") end
        label = bestName .. " Princess"
      end
      local ok, err = self.me:stockIntoInterface(beeIface, slot, { label = label }, p.count or 1, 1)
      if not ok then return fail(err) end
      self.requestsByReqId[p.reqId] = { iface = beeIface, slot = slot }
      self.link:send(remote, "ready", { reqId = p.reqId, slot = slot })
    elseif p.honey then
      if not mainIface then return fail("cell has no mainInterface configured") end
      local ok, err = self.me:stockIntoInterface(mainIface, slots.main.honey, { label = cfg.honeyLabel or "Honey Drop" }, cfg.honeyStock or 64, 1)
      if not ok then return fail(err) end
      self.link:send(remote, "ready", { reqId = p.reqId, slot = slots.main.honey })
    elseif p.item then
      if not mainIface then return fail("cell has no mainInterface configured") end
      if self.me:countLabel(p.item) == 0 then
        local status, err = self.me:craft(p.item, p.count or 1)
        if not status then return fail("no " .. p.item .. " and no pattern: " .. tostring(err)) end
        self:notify("crafting %s", p.item)
        local deadline = util.now() + 60
        while util.now() < deadline and self.me:countLabel(p.item) == 0 do os.sleep(1) end
      end
      local ok, err = self.me:stockIntoInterface(mainIface, slots.main.supply, { label = p.item }, p.count or 1, 1)
      if not ok then return fail(err) end
      self.requestsByReqId[p.reqId] = { iface = mainIface, slot = slots.main.supply }
      self.link:send(remote, "ready", { reqId = p.reqId, slot = slots.main.supply })
    elseif p.upgrade then
      if not mainIface then return fail("cell has no mainInterface configured") end
      local key = tostring(p.upgrade):lower()
      local found
      for _, st in ipairs(self.me:items()) do
        local l = tostring(st.label or ""):lower()
        if l:find("apiary", 1, true) and l:find(key, 1, true) then found = st.label break end
      end
      if not found then return fail("no '" .. key .. "' apiary upgrade in the ME network") end
      local ok, err = self.me:stockIntoInterface(mainIface, slots.main.supply, { label = found }, p.count or 1, 1)
      if not ok then return fail(err) end
      self.requestsByReqId[p.reqId] = { iface = mainIface, slot = slots.main.supply }
      self.link:send(remote, "ready", { reqId = p.reqId, slot = slots.main.supply })
    else
      fail("unknown need")
    end
  end

  function obj:finishJob(job, ok, info)
    local req = self:requestOf(job)
    if ok then
      job.status = "done"
      job.finished = util.now()
      self:notify("%s done: %s in %d generations, %d drones + %s princess archived",
        job.id, self:label(job.target), info.generations or 0, info.archivedDrones or 0, info.princess and "1" or "no")
    else
      local missing = (info.reason or ""):match("ran out of drones %(([^/%)]+)")
      if missing and req and self.graph.species[missing] then
        local sj = self:stockJob(req, missing, 32)
        self.S.jobs[sj.id] = sj
        for i, jid in ipairs(req.jobs) do
          if jid == job.id then table.insert(req.jobs, i, sj.id) break end
        end
        job.status = "pending"
        job.cell = nil
        if self:dronesOf(missing) == 0 then
          self:notify("%s ran out of %s drones and the library has none left: add some to the ME network", job.id, self:label(missing))
        else
          self:notify("%s ran out of %s drones; stockpiling first (%s)", job.id, self:label(missing), sj.id)
        end
      else
        job.attempts = (job.attempts or 0) + 1
        if job.attempts < 3 and not (info.reason or ""):match("cancelled") then
          job.status = "pending"
          self:notify("%s failed (%s), will retry", job.id, tostring(info.reason))
        else
          job.status = "failed"
          job.error = info.reason
          self:notify("%s FAILED: %s", job.id, tostring(info.reason))
        end
      end
    end
    self:updateRequestStatus(req)
    self:saveState()
    self:scanLibrary(true)
  end

  function obj:onSignal(...)
    local msg = self.link:decode(...)
    if not msg then return end
    local ok, err = pcall(function() self:handleMessage(msg) end)
    if not ok then self:warn("message error: %s", tostring(err)) end
  end

  function obj:handleMessage(msg)
    local p = msg.payload
    local c
    if msg.type == "hello" or msg.type == "idle" or msg.type == "pong" then
      c = self:cellFor(p.name or msg.from)
      c.addr = msg.remote
      c.lastSeen = util.now()
      c.housing = p.housing or c.housing
      if p.foundation then c.foundation = p.foundation end
      if msg.type == "hello" then
        self.link:send(msg.remote, "welcome", {})
        self:log("cell %s online (%s)", c.name, tostring(c.housing))
      end
      if msg.type ~= "pong" and p.job == nil and not c.job then c.status = "idle" end
      return
    end
    c = self:cellByAddr(msg.remote) or self:cellFor(msg.from)
    c.lastSeen = util.now()
    if msg.type == "accepted" then
      c.status = "busy"
    elseif msg.type == "busy" then
      self:log("%s is busy, re-queueing %s", c.name, tostring(p.job))
      local job = self.S.jobs[p.job]
      if job then job.status = "pending"; job.cell = nil end
      c.job = nil
    elseif msg.type == "need" then
      self:handleNeed(c, p, msg.remote)
    elseif msg.type == "got" then
      local r = self.requestsByReqId[p.reqId]
      if r and self.me then self.me:clearInterfaceSlot(r.iface, r.slot) end
      self.requestsByReqId[p.reqId] = nil
    elseif msg.type == "badstock" then
      self:notify("%s: library sent a non-pure %s %s, quarantined", c.name, tostring(p.species), tostring(p.kind))
    elseif msg.type == "event" then
      local d = p.data or {}
      if p.kind == "gen" then
        c.gen = d.generation
        c.phase = d.phase
        c.lastGen = util.now()
        if d.hits and d.hits > 0 then
          local job = self.S.jobs[d.job]
          self:log("%s gen %d: %d hit(s) for %s", c.name, d.generation or 0, d.hits, job and self:label(job.target) or "-")
        end
      elseif p.kind == "phase" then
        c.phase = d.to
        local job = self.S.jobs[d.job]
        if d.to == "purify" or d.to == "stockpile" then
          self:notify("%s: %s reached phase %s at generation %d", c.name, job and self:label(job.target) or "-", d.to, d.generation or 0)
        end
      elseif p.kind == "warn" then
        self:notify("%s: %s", c.name, tostring(d.text))
      elseif p.kind == "error" then
        self:log("%s error: %s", c.name, tostring(d.reason))
      end
    elseif msg.type == "result" then
      local job = self.S.jobs[p.job]
      c.job = nil
      c.status = "idle"
      c.gen, c.phase = nil, nil
      if job then self:finishJob(job, p.ok, p) end
    elseif msg.type == "aborted" then
      local job = self.S.jobs[p.job]
      if job and job.status == "running" then
        job.status = "pending"
        job.cell = nil
        self:notify("%s was interrupted on %s (%s), re-queued", p.job, c.name, tostring(p.reason))
      end
      c.job = nil
      c.status = "idle"
      self:saveState()
    end
  end

  ----------------------------------------------------------------------
  -- formatting for GUI / Discord
  ----------------------------------------------------------------------
  function obj:cellLines()
    local out = {}
    for _, name in ipairs(util.sortedKeys(self.cells)) do
      local c = self.cells[name]
      local job = c.job and self.S.jobs[c.job]
      if job then
        out[#out + 1] = string.format("%-8s %s -> %s  gen %s [%s]  %s", name, job.id, self:label(job.target),
          tostring(c.gen or 0), tostring(c.phase or "-"), util.fmtSeconds(util.now() - (job.started or util.now())))
      else
        out[#out + 1] = string.format("%-8s %s  (seen %s ago)  foundation %s", name, c.status,
          util.fmtSeconds(util.now() - (c.lastSeen or 0)), tostring(c.foundation or "-"))
      end
    end
    if #out == 0 then out[1] = "no cells have reported yet" end
    return out
  end

  function obj:queueLines()
    local out = {}
    for _, r in ipairs(self.S.requests) do
      if r.status ~= "done" then
        out[#out + 1] = string.format("%s %s -> %s  by %s", r.id, r.status, self:label(r.target), r.by or "-")
        for _, jid in ipairs(r.jobs) do
          local j = self.S.jobs[jid]
          if j then
            out[#out + 1] = string.format("   %s %-8s %s + %s -> %s  keep %d%s%s", j.id, j.status, self:label(j.a), self:label(j.b),
              self:label(j.target), j.keepDrones or 0, j.cell and (" on " .. j.cell) or "", j.error and (" ! " .. j.error) or "")
          end
        end
      end
    end
    if #out == 0 then out[1] = "queue empty, type: breed <number>" end
    return out
  end

  function obj:fmtStatus()
    local active, done = 0, 0
    for _, r in ipairs(self.S.requests) do
      if r.status == "active" then active = active + 1 elseif r.status == "done" then done = done + 1 end
    end
    local out = { string.format("requests: %d active, %d done | library: %d species with drones, %d princesses",
      active, done, util.count(self:ownedSet()), self:princessPool()) }
    for _, l in ipairs(self:cellLines()) do out[#out + 1] = l end
    return table.concat(out, "\n")
  end

  ---Values for the GUI template.
  function obj:getValues()
    local h = self.cfg.host or {}
    return {
      cellCount = util.count(self.cells),
      libSpecies = util.count(self:ownedSet()),
      princesses = self:princessPool(),
      discord = self.discordOn and "on" or "off",
      host = (h.url or "") ~= "" and (self.hostWarned and "unreachable" or "linked") or "off",
      cells = util.map(self:cellLines(), clean),
      queue = util.map(self:queueLines(), clean),
    }
  end

  ----------------------------------------------------------------------
  -- commands
  ----------------------------------------------------------------------
  function obj:parseExtras(list)
    local extra = {}
    for _, item in ipairs(list or {}) do
      local tok, n = item:match("^(.-)=(%d+)$")
      if not tok then tok, n = item, self.cfg.defaults.keepDrones end
      local e, err = self.cat:resolve(tok)
      if not e then return nil, err end
      extra[e.name] = tonumber(n)
    end
    return extra
  end

  ---Execute a command line. Returns the response text.
  function obj:command(line, who)
    local ok, res = pcall(function() return self:runCommand(line, who) end)
    if not ok then res = "error: " .. tostring(res) end
    if who == "gui" then
      for l in (tostring(res) .. "\n"):gmatch("(.-)\n") do if l ~= "" then self.logger:info(clean(l)) end end
    end
    return res
  end

  function obj:runCommand(line, who)
    local cmd = util.parseCommand(line)
    local w = cmd.words
    local verb = (w[1] or ""):lower()
    if verb == "" then return "" end
    if verb == "help" then
      return table.concat({
        "breed <number|name> [keep N] [extra id=N ...] [all N]   queue a species, chain included",
        "plan <number|name>     show the chain the planner would use",
        "needs <number|name>    autocraft / station needs for that chain",
        "find <text>            catalog numbers",
        "status | queue | cells | library [text] | cancel <job|request> | scan | survey",
        "settings [show|test|host <url>|interval <s>|discord webhook <url>|discord bot <token> <channel>|discord on|off]",
      }, "\n")
    elseif verb == "settings" then
      return self:settingsCommand(w)
    elseif verb == "find" then
      local list = self.cat:find(w[2] or "", 25)
      if #list == 0 then return "no match" end
      return table.concat(util.map(list, function(e) return string.format("%d %s (%s)", e.id, e.name, e.mod or "-") end), "\n")
    elseif verb == "breed" or verb == "plan" or verb == "needs" then
      local e, err = self.cat:resolve(w[2])
      if not e then return "error: " .. tostring(err) end
      if verb == "breed" then
        local extra, err2 = self:parseExtras(cmd.opts.extra)
        if not extra then return "error: " .. tostring(err2) end
        local req, info = self:addRequest(e.name, { keep = tonumber(cmd.opts.keep), extra = extra, keepAll = tonumber(cmd.opts.all) }, who)
        if not req then return "cannot plan " .. self:label(e.name) .. ": " .. tostring(info) end
        self:notify("%s queued %s: %d job(s)", who or "gui", self:label(e.name), #req.jobs)
        self:dispatch()
        return string.format("queued %s as %s with %d job(s)", self:label(e.name), req.id, #req.jobs)
      end
      self:scanLibrary()
      local plan, why, blockers = self:planFor(e.name)
      if not plan then
        local msg = "cannot plan: " .. tostring(why)
        if blockers and #blockers.base > 0 then msg = msg .. "\nhive species needed: " .. table.concat(blockers.base, ", ") end
        if blockers and #blockers.blocked > 0 then msg = msg .. "\nblocked mutations:\n  " .. table.concat(blockers.blocked, "\n  ") end
        return msg
      end
      if verb == "plan" then
        local out = { string.format("%s: %d step(s), cost %.1f", self:label(e.name), #plan.steps, plan.cost) }
        for i, s in ipairs(plan.steps) do
          out[#out + 1] = string.format("%2d. %s + %s -> %s  %d%%  %s", i, self:label(s.a), self:label(s.b), self:label(s.result), s.chance, conditions.describeAll(s.conds))
        end
        if #plan.steps == 0 then out[#out + 1] = "already in the library" end
        return table.concat(out, "\n")
      end
      local ctx = { base = { temp = 0.8, hum = 0.4 }, station = function(k, n) return self:stationAvailable(k, n) end }
      if self.me then
        ctx.haveCount = function(label) return self.me:countLabel(label) end
        ctx.craftable = function(label) return self.me:hasPattern(label) end
      end
      return table.concat(needs.lines(needs.forSteps(plan.steps, ctx), false), "\n")
    elseif verb == "status" then
      return self:fmtStatus()
    elseif verb == "queue" then
      return table.concat(self:queueLines(), "\n")
    elseif verb == "cells" then
      local out = {}
      for _, name in ipairs(util.sortedKeys(self.cells)) do
        local c = self.cells[name]
        out[#out + 1] = string.format("%s %s housing=%s foundation=%s addr=%s", name, c.status, tostring(c.housing), tostring(c.foundation), c.addr and c.addr:sub(1, 8) or "-")
      end
      return #out > 0 and table.concat(out, "\n") or "no cells have reported yet"
    elseif verb == "library" then
      self:scanLibrary(true)
      local out = {}
      local filter = (w[2] or ""):lower()
      for _, name in ipairs(util.sortedKeys(self.library)) do
        local b = self.library[name]
        if filter == "" or name:lower():find(filter, 1, true) then
          out[#out + 1] = string.format("%-28s drones %3d  princesses %2d%s", self:label(name), b.drones, b.princesses,
            (b.hybrids > 0 or b.unanalyzed > 0) and string.format("  (+%d hybrid, %d unanalyzed)", b.hybrids, b.unanalyzed) or "")
        end
      end
      if #out > 40 then
        local n = #out
        while #out > 40 do table.remove(out) end
        out[#out + 1] = string.format("... %d more", n - 40)
      end
      return #out > 0 and table.concat(out, "\n") or "library empty (is the ME network reachable?)"
    elseif verb == "cancel" then
      local id = w[2]
      if not id then return "cancel what?" end
      local job = self.S.jobs[id]
      if job then
        if job.status == "running" and job.cell and self.cells[job.cell] and self.cells[job.cell].addr then
          self.link:send(self.cells[job.cell].addr, "cancel", { job = id })
        end
        job.status = "failed"
        job.error = "cancelled"
        self:updateRequestStatus(self:requestOf(job))
        self:saveState()
        return "cancelled " .. id
      end
      for _, r in ipairs(self.S.requests) do
        if r.id == id then
          r.status = "cancelled"
          for _, jid in ipairs(r.jobs) do
            local j = self.S.jobs[jid]
            if j and j.status ~= "done" then
              if j.status == "running" and j.cell and self.cells[j.cell] and self.cells[j.cell].addr then
                self.link:send(self.cells[j.cell].addr, "cancel", { job = jid })
              end
              j.status = "failed"
              j.error = "cancelled"
            end
          end
          self:saveState()
          return "cancelled " .. id
        end
      end
      return "no such job/request"
    elseif verb == "scan" then
      self:scanLibrary(true)
      return string.format("library: %d species with drones, %d princesses", util.count(self:ownedSet()), self:princessPool())
    elseif verb == "survey" then
      local lines = {}
      local ok, res = survey.run(self.cfg.dataDir, function(l) lines[#lines + 1] = l end, { verbose = cmd.opts.all })
      if ok then
        self.graph = graph.fromTable(util.loadTable(self.cfg.dataDir .. "/graph.dat"))
        self.cat:load()
      else
        lines[#lines + 1] = "survey failed: " .. tostring(res)
      end
      return table.concat(lines, "\n")
    end
    return "unknown command, try help"
  end

  ---`settings ...` subcommands. Values are saved to settings.dat and applied live.
  function obj:settingsCommand(w)
    local sub = (w[2] or "show"):lower()
    if sub == "show" then
      return table.concat(settings.describe(self.cfg), "\n")
    elseif sub == "test" then
      return table.concat(connect.report(self.internet, self.cfg.discord, self.cfg.host), "\n")
    elseif sub == "host" then
      if not w[3] then return "usage: settings host <url>" end
      self:setSetting("host.url", w[3])
      if not self.cfg.host.pushInterval then self:setSetting("host.pushInterval", 30) end
      local _, why = connect.testHost(self.internet, w[3])
      return "host set to " .. w[3] .. "; " .. why
    elseif sub == "interval" then
      local n = tonumber(w[3])
      if not n then return "usage: settings interval <seconds>" end
      self:setSetting("host.pushInterval", n)
      return "host push interval " .. n .. "s"
    elseif sub == "discord" then
      local what = (w[3] or ""):lower()
      if what == "webhook" and w[4] then
        self:setSetting("discord.webhook", w[4])
        self:setSetting("discord.enabled", true)
        local _, why = connect.testWebhook(self.internet, w[4], "Auto Bees: webhook linked")
        return "webhook saved; " .. why
      elseif what == "bot" and w[4] and w[5] then
        self:setSetting("discord.token", w[4])
        self:setSetting("discord.channel", w[5])
        self:setSetting("discord.enabled", true)
        local _, why = connect.testBot(self.internet, w[4], w[5])
        return "bot saved; " .. why
      elseif what == "on" or what == "off" then
        self:setSetting("discord.enabled", what == "on")
        return "discord " .. what .. (self.discordOn and " (active)" or " (inactive: missing internet card or credentials)")
      elseif what == "prefix" and w[4] then
        self:setSetting("discord.prefix", w[4])
        return "prefix " .. w[4]
      end
      return "usage: settings discord webhook <url> | bot <token> <channel> | prefix <p> | on | off"
    end
    return "usage: settings [show|test|host <url>|interval <s>|discord ...]"
  end

  ----------------------------------------------------------------------
  -- Discord
  ----------------------------------------------------------------------
  function obj:discordTick()
    if not self.discordOn then return end
    local dcfg = self.cfg.discord or {}
    while #self.discordQueue > 0 do
      local text = table.remove(self.discordQueue, 1)
      local ok, err = self.dc:post(text)
      if not ok then self:warn("discord post failed: %s", tostring(err)) break end
    end
    if self.dc:canRead() and util.now() - self.lastPoll > (dcfg.pollInterval or 5) then
      self.lastPoll = util.now()
      local msgs, err = self.dc:poll()
      if err then self:warn("discord poll: %s", tostring(err)) end
      for _, m in ipairs(msgs) do
        local prefix = dcfg.prefix or "!"
        if not m.bot and m.content:sub(1, #prefix) == prefix then
          local line = m.content:sub(#prefix + 1)
          self:log("discord %s: %s", m.author, line)
          local res = self:command(line, m.author)
          self.dc:post("**" .. line .. "**\n```\n" .. tostring(res) .. "\n```")
        end
      end
      if self.dc.lastId ~= self.S.discordLastId then self.S.discordLastId = self.dc.lastId; self:saveState() end
    end
    local interval = dcfg.statusInterval or 0
    if interval > 0 and self.dc:canRead() and util.now() - self.lastStatusPost > interval then
      self.lastStatusPost = util.now()
      self.statusMsgId = self.dc:edit(self.statusMsgId, "```\n" .. self:fmtStatus() .. "\n```") or self.statusMsgId
    end
  end

  ----------------------------------------------------------------------
  -- main loop (runs in a program-lib thread)
  ----------------------------------------------------------------------
  function obj:tick()
    self:scanLibrary()
    self:dispatch()
    self:discordTick()
    self:hostTick()
    for _, c in pairs(self.cells) do
      if c.status ~= "offline" and util.now() - c.lastSeen > 120 then c.status = "offline" end
    end
  end

  function obj:loop()
    while self.running do
      local ok, err = pcall(function() self:tick() end)
      if not ok then self:warn("tick error: %s", tostring(err)) end
      os.sleep(2)
    end
  end

  setmetatable(obj, self)
  self.__index = self
  return obj
end

return controller
