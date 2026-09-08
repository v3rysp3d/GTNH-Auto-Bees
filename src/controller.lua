-- Controller: planner, job queue, cell dispatcher, library bookkeeping,
-- command handling for the GUI, Discord and the relay on the custom host.
--
-- Species are identified by allele uid everywhere; display names come from
-- the catalog and carry the mod name when several mods share a name.
--
-- Lives on the computer. Needs on its OC network: an ME network component,
-- per cell two ME Interfaces each behind an Adapter with a Database upgrade,
-- a modem, and optionally an internet card for Discord and the host link.
local component = require("component")
local event = require("event")

local util = require("src.util")
local json = require("src.json")
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
local http = require("src.http")

local controller = {}

--- Strip characters the gui-lib template engine treats as markup.
local function clean(s)
  return (tostring(s):gsub("[%$#&@?]", ""))
end

---Create a controller
---@param cfg table   config.controller
---@param logger Logger
function controller:new(cfg, logger)
  local obj = {}
  obj.cfg = cfg
  obj.logger = logger
  obj.running = false

  obj.cells = {}            -- name -> { addr, status, lastSeen, job, housing, foundation, gen, phase, cfg }
  obj.library = {}          -- uid -> counts (see ae2:library)
  obj.libraryScannedAt = 0
  obj.requestsByReqId = {}
  obj.discordQueue = {}
  obj.lastPoll, obj.lastStatusPost = 0, 0
  obj.lastPush, obj.lastRelayPoll, obj.relayBackoffUntil = 0, 0, 0

  ----------------------------------------------------------------------
  -- logging helpers
  ----------------------------------------------------------------------
  local function fmt(f, ...)
    if select("#", ...) > 0 then return string.format(f, ...) end
    return tostring(f)
  end

  function obj:log(f, ...) self.logger:info(clean(fmt(f, ...))) end
  function obj:warn(f, ...) self.logger:warning(clean(fmt(f, ...))) end

  function obj:notify(f, ...)
    local msg = fmt(f, ...)
    self.logger:info(clean(msg))
    if self.discordOn then self.discordQueue[#self.discordQueue + 1] = { text = msg } end
  end

  ---Icon URL for a species uid (generated icons served from the repository).
  function obj:imageUrl(uid)
    local base = (self.cfg.discord or {}).imageBase
    if not uid or not base or base == "" then return nil end
    local file = catalog.iconFile(uid)
    if not file then return nil end
    return base .. file
  end

  ---Log a line and queue a Discord embed card for it.
  ---kind: start | phase | done | failed | warn | needs   fields: { {name, value[, inline]} ... }
  ---species: uid whose icon becomes the card thumbnail
  function obj:card(kind, title, fields, description, species)
    self.logger:info(clean(title))
    if self.discordOn then
      self.discordQueue[#self.discordQueue + 1] = { embed = discord.embed(kind, title, description, fields, self:imageUrl(species)) }
      if kind == "start" or kind == "done" or kind == "failed" then self.statusDirty = true end
    end
  end

  function obj:label(uid) return self.cat:label(uid) end
  function obj:nameOf(uid) return self.cat:nameOf(uid) end

  ----------------------------------------------------------------------
  -- init / stop
  ----------------------------------------------------------------------
  function obj:init()
    local cfg = self.cfg
    util.mkdirs(cfg.dataDir)
    for _, p in ipairs(cfg.conditionPatterns or {}) do
      conditions.addPattern(p.pattern, function(m) return { kind = p.kind, name = m, block = m } end)
    end

    local graphPath = cfg.dataDir .. "/graph.dat"
    local g, gerr
    if util.exists(graphPath) then
      g, gerr = graph.load(graphPath)
      if not g then
        self:warn("graph.dat is unreadable (%s), running the survey again", tostring(gerr))
        os.remove(graphPath)
      end
    end
    if not g then
      self:log("no graph.dat yet, running the survey")
      local ok, err = survey.run(cfg.dataDir, function(l) self:log("%s", l) end)
      if not ok then error("survey failed: " .. tostring(err)) end
      g, gerr = graph.load(graphPath)
      if not g then error("cannot load " .. graphPath .. ": " .. tostring(gerr)) end
    end
    self.graph = g
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

    self:log("controller: %d species, %d mutations, ME %s, modem %s, discord %s, host %s",
      util.count(self.graph.species), #self.graph.mutations, self.me and "ok" or "MISSING", modemAddr and "ok" or "MISSING",
      self.discordOn and "on" or "off", ((cfg.host or {}).url or "") ~= "" and "linked" or "off")
    if not self.me then self:warn("no ME network component: library and stocking are disabled") end
    if self.me and not self.me.db then self:warn("no Database upgrade found: robots cannot be served") end

    self:scanLibrary(true)
    if self.discordOn then
      local dcfg = cfg.discord or {}
      if self.dc:canRead() and not self.S.discordLastId then self.dc:syncCursor(); self.S.discordLastId = self.dc.lastId; self:saveState() end
      local how = self.dc:canRead() and ("Type `" .. (dcfg.prefix or "!") .. "help` here for commands.")
        or "Webhook mode: events and the status card are posted here. Commands come through the relay or a bot token."
      self:card("info", "Auto Bees controller online", { { "Species", tostring(util.count(self.graph.species)) },
        { "Cells configured", tostring(util.count(cfg.cells or {})) } }, how)
      self.statusDirty = true
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

  function obj:saveState() util.saveTable(self.statePath, self.S) end

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

  --- Unanalyzed bees only show a display name. When that name belongs to
  --- exactly one species they count as stock of it: the robot analyzes what
  --- it fetches and keeps only what is pure.
  function obj:unanalyzedBucketFor(uid)
    local name = self:nameOf(uid)
    local b = self.library["name:" .. tostring(name)]
    if not b then return nil end
    local e = self.cat:uniqueByName(name)
    if not e or e.uid ~= uid then return nil end
    return b
  end

  function obj:dronesOf(uid)
    local n = self.library[uid] and self.library[uid].drones or 0
    local u = self:unanalyzedBucketFor(uid)
    if u then n = n + (u.unanalyzedDrones or 0) end
    return n
  end

  function obj:princessesOf(uid)
    local n = self.library[uid] and self.library[uid].princesses or 0
    local u = self:unanalyzedBucketFor(uid)
    if u then n = n + (u.unanalyzedPrincesses or 0) end
    return n
  end

  function obj:ownedSet()
    local owned = {}
    for uid, b in pairs(self.library) do
      if uid:match("^name:") then
        local e = self.cat:uniqueByName(b.name)
        if e and (b.unanalyzedDrones or 0) > 0 then owned[e.uid] = true end
      elseif b.drones > 0 then
        owned[uid] = true
      end
    end
    return owned
  end

  function obj:princessPool()
    local n = 0
    for _, b in pairs(self.library) do n = n + b.princesses + (b.unanalyzedPrincesses or 0) end
    return n
  end

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
        -- stock and patterns are not consulted here: that is one ME call per
        -- block and would freeze the planner. Missing blocks are handled at
        -- dispatch time (the job waits and you get a card).
        cost = cost + (self.cfg.foundationCostBase or 2)
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
    local black = self.cfg.effectBlacklist or {}
    if black[m.result] or black[self:nameOf(m.result)] then return nil end
    return cost
  end

  --- Context for needs reports: stock and pattern lookups, station availability, labels.
  function obj:needsCtx()
    local ctx = { base = { temp = 0.8, hum = 0.4 }, station = function(k, n) return self:stationAvailable(k, n) end,
      label = function(u) return self:nameOf(u) end }
    if self.me then
      ctx.haveCount = function(label) return self.me:countLabel(label) end
      ctx.craftable = function(label) return self.me:hasPattern(label) end
    end
    return ctx
  end

  function obj:planFor(uid)
    return self.graph:plan(uid, self:ownedSet(), {
      chanceWeight = self.cfg.chanceWeight or 0.1,
      conditionCost = function(conds, m) return self:conditionCost(conds, m) end,
    })
  end

  ----------------------------------------------------------------------
  -- requests and jobs
  ----------------------------------------------------------------------
  function obj:newId(prefix)
    local id = prefix .. self.S.nextId
    self.S.nextId = self.S.nextId + 1
    return id
  end

  function obj:namesFor(...)
    local names = {}
    for _, uid in ipairs({ ... }) do names[uid] = self:nameOf(uid) end
    return names
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
      target = step.result, a = step.a, b = step.b, names = self:namesFor(step.result, step.a, step.b),
      chance = step.chance, conds = step.conds,
      foundation = foundation, needTemp = needTemp, needHum = needHum,
      keepDrones = keep, wantPrincess = true,
      droneSupply = d.droneSupply, maxGenerations = d.maxGenerations, warnAfter = d.warnAfter,
      status = "pending", created = util.now(),
    }
  end

  function obj:stockJob(req, uid, keep)
    local d = self.cfg.defaults
    return {
      id = self:newId("j"), request = req.id, kind = "stock",
      target = uid, a = uid, b = uid, names = self:namesFor(uid), chance = 100, conds = {},
      keepDrones = keep, wantPrincess = true,
      droneSupply = d.droneSupply, maxGenerations = d.maxGenerations,
      status = "pending", created = util.now(),
    }
  end

  ---Create a request. opts: { keep = n, extra = { [uid] = n }, keepAll = n }
  function obj:addRequest(targetUid, opts, who)
    opts = opts or {}
    local d = self.cfg.defaults
    self:scanLibrary(true)
    local plan, why, blockers = self:planFor(targetUid)
    if not plan then
      local msg = why
      if blockers then
        if #blockers.base > 0 then
          msg = msg .. "; hive species needed: " .. table.concat(util.map(blockers.base, function(u) return self:label(u) end), ", ")
        end
        if #blockers.blocked > 0 then msg = msg .. "; blocked: " .. table.concat(blockers.blocked, " | ") end
      end
      return nil, msg
    end
    local S = self.S
    local req = { id = self:newId("r"), target = targetUid, by = who or "gui", created = util.now(),
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
      if step.result == targetUid then keep = req.keep end
      if opts.keepAll then keep = math.max(keep, opts.keepAll) end
      if req.extra[step.result] then keep = math.max(keep, req.extra[step.result]) end
      local job = self:jobFromStep(req, step, keep)
      S.jobs[job.id] = job
      req.jobs[#req.jobs + 1] = job.id
    end
    for uid, n in pairs(req.extra) do
      if not produced[uid] then
        if not self.graph.species[uid] then return nil, "unknown extra species " .. tostring(uid) end
        local job = self:stockJob(req, uid, n)
        S.jobs[job.id] = job
        req.jobs[#req.jobs + 1] = job.id
      end
    end
    if #plan.steps == 0 and util.count(req.extra) == 0 then
      local job = self:stockJob(req, targetUid, req.keep)
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
      local cells = self.cfg.cells or {}
      local cellCfg = cells[name]
      if not cellCfg and util.count(cells) == 1 then
        -- a robot named differently from the one configured cell: use that cell
        local onlyName = util.sortedKeys(cells)[1]
        cellCfg = cells[onlyName]
        self:log("cell '%s' is not in the config; using the settings of '%s'", name, onlyName)
      end
      c = { name = name, status = "unknown", lastSeen = 0, cfg = cellCfg or {} }
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

  --- Label of the Industrial Apiary upgrade item for a climate key ("heater"),
  --- found by looking at what the ME network holds.
  function obj:findUpgradeLabel(key)
    if not self.me then return nil end
    key = tostring(key):lower()
    self.upgradeLabels = self.upgradeLabels or {}
    if self.upgradeLabels[key] then return self.upgradeLabels[key] end
    for _, st in ipairs(self.me:items()) do
      local l = tostring(st.label or ""):lower()
      if l:find("apiary", 1, true) and l:find(key, 1, true) then
        self.upgradeLabels[key] = st.label
        return st.label
      end
    end
    return nil
  end

  --- Make sure the things a job needs exist. Returns true, or "wait", reason
  --- when an item is missing (a craft is requested when a pattern exists), or
  --- false, reason when the job can never run on this cell.
  function obj:prepareJob(job, c)
    local base = c.cfg.base or { temp = 0.8, hum = 0.4 }
    if job.needTemp or job.needHum then
      local sol, why = climate.solve({ baseTemp = base.temp, baseHum = base.hum, needTemp = job.needTemp, needHum = job.needHum })
      if not sol then return false, "climate: " .. why end
      job.climate = climate.upgradeCounts(sol)
    else
      job.climate = {}
    end
    if not self.me then return true end
    if job.foundation and self.me:countLabel(job.foundation) == 0 then
      return "wait", job.foundation
    end
    for key, n in pairs(job.climate or {}) do
      local label = self:findUpgradeLabel(key)
      if not label then return "wait", key .. " upgrade for the Industrial Apiary" end
      if self.me:countLabel(label) < n then return "wait", label .. " x" .. n end
    end
    return true
  end

  --- Park a job until `item` shows up in the ME network; ask AE2 to craft it
  --- when a pattern exists. The queue moves on to other jobs meanwhile.
  function obj:waitFor(job, item)
    job.status = "waiting"
    job.waitingFor = item
    job.waitSince = job.waitSince or util.now()
    job.cell = nil
    local crafted = false
    if self.me and self.me:hasPattern(item) then
      local status = self.me:craft(item, 1)
      crafted = status ~= nil
      job.lastCraft = util.now()
    end
    if not job.notified then
      job.notified = true
      if crafted then
        self:card("needs", string.format("%s waits for %s", job.id, item), {
          { "Target", self:label(job.target) }, { "Action", "crafting requested, the job resumes when it lands in ME" } }, nil, job.target)
      else
        self:card("needs", string.format("%s needs %s", job.id, item), {
          { "Target", self:label(job.target) }, { "Action", "no pattern: put it in the ME network by hand, the job resumes on its own" } }, nil, job.target)
      end
    end
    self:saveState()
  end

  --- Re-check waiting jobs: release the ones whose item arrived, re-request
  --- crafts that went nowhere.
  function obj:checkWaiting()
    if not self.me then return end
    if util.now() - (self.lastWaitCheck or 0) < 30 then return end
    self.lastWaitCheck = util.now()
    for _, job in pairs(self.S.jobs) do
      if job.status == "waiting" and job.waitingFor then
        local item = job.waitingFor
        local needed = tonumber(item:match(" x(%d+)$")) or 1
        local label = item:gsub(" x%d+$", "")
        if not label:find(" upgrade for the Industrial Apiary", 1, true) and self.me:countLabel(label) >= needed then
          job.status = "pending"
          job.waitingFor, job.notified, job.waitSince = nil, nil, nil
          self:notify("%s: %s is available, resuming", job.id, label)
        elseif label:find(" upgrade for the Industrial Apiary", 1, true) then
          local key = label:match("^(%S+) upgrade")
          if key and self:findUpgradeLabel(key) then
            job.status = "pending"
            job.waitingFor, job.notified, job.waitSince = nil, nil, nil
          end
        elseif self.me:hasPattern(label) and util.now() - (job.lastCraft or 0) > 300 then
          -- the earlier craft did not deliver (ingredients ran out?): ask again
          self.me:craft(label, needed)
          job.lastCraft = util.now()
        end
      end
    end
  end

  function obj:dispatch()
    for name, c in pairs(self.cells) do
      if c.status == "idle" and c.addr and not c.job then
        local job = self:nextReadyJob()
        if not job then return end
        local ok, why = self:prepareJob(job, c)
        if ok == "wait" then
          self:waitFor(job, why)
        elseif not ok then
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
            id = job.id, target = job.target, a = job.a, b = job.b, names = job.names, chance = job.chance,
            keepDrones = job.keepDrones, wantPrincess = job.wantPrincess, foundation = job.foundation,
            climate = job.climate, droneSupply = job.droneSupply, maxGenerations = job.maxGenerations, warnAfter = job.warnAfter,
          })
          local climateText = {}
          for k, n in pairs(job.climate or {}) do climateText[#climateText + 1] = k .. " x" .. n end
          self:card("start", string.format("%s started on %s: %s", job.id, name, self:label(job.target)), {
            { "Parents", self:label(job.a) .. " + " .. self:label(job.b) },
            { "Chance", tostring(job.chance) .. "%" },
            { "Keep", tostring(job.keepDrones) .. " drones" },
            { "Foundation", job.foundation or "none" },
            { "Climate", #climateText > 0 and table.concat(climateText, ", ") or "as is" },
          }, nil, job.target)
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
      local name = p.name or (p.species and self:nameOf(p.species))
      if not name then
        -- any princess: the species with the most princesses, analyzed or not
        local bestName, bestN = nil, 0
        for _, b in pairs(self.library) do
          local n = (b.princesses or 0) + (b.unanalyzedPrincesses or 0)
          if n > bestN and b.name then bestName, bestN = b.name, n end
        end
        if not bestName then return fail("no princesses in the library") end
        name = bestName
      end
      local label = name .. (p.kind == "princess" and " Princess" or " Drone")
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
      local found = self:findUpgradeLabel(key)
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
      self:card("done", string.format("%s done: %s", job.id, self:label(job.target)), {
        { "Generations", tostring(info.generations or 0) },
        { "Drones archived", tostring(info.archivedDrones or 0) },
        { "Princess", info.princess and "yes" or "no" },
        { "Honey used", tostring(info.honey or 0) },
        { "Time", util.fmtSeconds(util.now() - (job.started or util.now())) },
      }, nil, job.target)
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
        -- the robot found something missing that the controller can wait for
        local reason = info.reason or ""
        local missingItem = reason:match("^foundation: no (.-) available") or reason:match("no (%S+) upgrades")
        if missingItem then
          if reason:match("upgrades") then missingItem = missingItem .. " upgrade for the Industrial Apiary" end
          job.notified = nil
          self:waitFor(job, missingItem)
          self:updateRequestStatus(req)
          self:scanLibrary(true)
          return
        end
        job.attempts = (job.attempts or 0) + 1
        if job.attempts < 3 and not reason:match("cancelled") then
          job.status = "pending"
          self:card("warn", string.format("%s failed, will retry", job.id), { { "Reason", tostring(info.reason) }, { "Target", self:label(job.target) } }, nil, job.target)
        else
          job.status = "failed"
          job.error = info.reason
          self:card("failed", string.format("%s FAILED: %s", job.id, self:label(job.target)), { { "Reason", tostring(info.reason) } }, nil, job.target)
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
    elseif msg.type == "probeResult" then
      self.probeReply = p
    elseif msg.type == "badstock" then
      self:notify("%s: library sent a non-pure %s %s, quarantined", c.name, self:label(p.species), tostring(p.kind))
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
          self:card("phase", string.format("%s: %s reached %s at generation %d", c.name, job and self:label(job.target) or "-", d.to, d.generation or 0),
            nil, nil, job and job.target or nil)
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
  -- formatting for GUI / Discord / host
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
      if r.status ~= "done" and r.status ~= "cancelled" then
        out[#out + 1] = string.format("%s %s -> %s  by %s", r.id, r.status, self:label(r.target), r.by or "-")
        for _, jid in ipairs(r.jobs) do
          local j = self.S.jobs[jid]
          if j then
            out[#out + 1] = string.format("   %s %-8s %s + %s -> %s  keep %d%s%s%s", j.id, j.status, self:label(j.a), self:label(j.b),
              self:label(j.target), j.keepDrones or 0, j.cell and (" on " .. j.cell) or "",
              j.waitingFor and (" needs " .. j.waitingFor) or "", j.error and (" ! " .. j.error) or "")
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

  ---Status snapshot pushed to the custom host (the relay draws its main card from it).
  function obj:statusTable()
    local cells = {}
    for name, c in pairs(self.cells) do
      local job = c.job and self.S.jobs[c.job]
      cells[name] = { status = c.status, job = job and job.id or nil, target = job and self:label(job.target) or nil,
        targetUid = job and job.target or nil, generation = c.gen, phase = c.phase, foundation = c.foundation }
    end
    local queue = {}
    for _, r in ipairs(self.S.requests) do
      if r.status ~= "done" then
        queue[#queue + 1] = { id = r.id, target = self:label(r.target), targetUid = r.target, status = r.status, by = r.by }
      end
    end
    return { time = util.now(), cells = cells, queue = queue, queueLines = self:queueLines(),
      librarySpecies = util.count(self:ownedSet()), princesses = self:princessPool(),
      imageBase = (self.cfg.discord or {}).imageBase }
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
      extra[e.uid] = tonumber(n)
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

  ---A Discord/relay reply for a command line: an embed with the species icon
  ---for species-centred commands, a plain code block otherwise.
  function obj:discordReply(line, who)
    local cmd = util.parseCommand(line)
    local verb = (cmd.words[1] or ""):lower()
    local text = tostring(self:command(line, who))
    local embedVerbs = { find = true, plan = true, needs = true, library = true, status = true, queue = true, cells = true, breed = true }
    if not embedVerbs[verb] then
      return { content = ("**" .. line .. "**\n```\n" .. text .. "\n```"):sub(1, 1990) }
    end
    local uid
    if verb == "find" then
      local matches = self.cat:find(cmd.words[2] or "", 1)
      uid = matches[1] and matches[1].uid or nil
    elseif cmd.words[2] then
      local e = self.cat:resolve(cmd.words[2])
      uid = e and e.uid or nil
    end
    local body = text
    if #body > 3900 then body = body:sub(1, 3880) .. "\n..." end
    local kind = (verb == "breed") and "start" or "info"
    local title = uid and (verb .. ": " .. self:label(uid)) or verb
    return { embeds = json.array({ discord.embed(kind, title, "```\n" .. body .. "\n```", nil, self:imageUrl(uid)) }) }
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
        "find <text>            catalog numbers (shared names show their mod)",
        "hives                  species that cannot be bred and must come from wild hives, with your stock",
        "status | queue | cells | library [text] | cancel <job|request> | retry <job|request> | scan | survey",
        "pair [cell]            find out which ME interface is which by marking them for the robot",
        "diag [cell]            report what the robot can reach above, below and in front",
        "settings [show|test|host <url>|interval <s>|discord webhook <url>|discord bot <token> <channel>|discord on|off]",
      }, "\n")
    elseif verb == "pair" then
      return self:startPairing(w[2], false)
    elseif verb == "diag" then
      return self:startPairing(w[2], true)
    elseif verb == "settings" then
      return self:settingsCommand(w)
    elseif verb == "find" then
      local list = self.cat:find(w[2] or "", 25)
      if #list == 0 then return "no match" end
      return table.concat(util.map(list, function(e)
        return string.format("%d %s (%s)%s", e.id, e.name, e.mod or "-", self.library[e.uid] and self.library[e.uid].drones > 0 and "  in library" or "")
      end), "\n")
    elseif verb == "breed" or verb == "plan" or verb == "needs" then
      local e, err = self.cat:resolve(w[2])
      if not e then return "error: " .. tostring(err) end
      if verb == "breed" then
        local extra, err2 = self:parseExtras(cmd.opts.extra)
        if not extra then return "error: " .. tostring(err2) end
        local req, info = self:addRequest(e.uid, { keep = tonumber(cmd.opts.keep), extra = extra, keepAll = tonumber(cmd.opts.all) }, who)
        if not req then return "cannot plan " .. self:label(e.uid) .. ": " .. tostring(info) end
        self:notify("%s queued %s: %d job(s)", who or "gui", self:label(e.uid), #req.jobs)
        local out = { string.format("queued %s as %s with %d job(s)", self:label(e.uid), req.id, #req.jobs) }
        -- only what this chain needs, with its status
        local required = needs.summary(needs.forSteps(info.steps, self:needsCtx()), false)
        if #required > 0 then
          out[#out + 1] = "required for this chain:"
          for _, l in ipairs(required) do out[#out + 1] = "  " .. l end
          local missing = {}
          for _, l in ipairs(required) do if l:find("MISSING", 1, true) then missing[#missing + 1] = l end end
          if #missing > 0 then
            self:card("needs", string.format("%s needs %d thing(s) you must provide", req.id, #missing),
              util.map(missing, function(l) return { (l:match("^(.-):") or l), (l:match("^.-:%s*(.*)$") or l) } end), nil, e.uid)
          end
        end
        self:dispatch()
        return table.concat(out, "\n")
      end
      self:scanLibrary()
      local plan, why, blockers = self:planFor(e.uid)
      if not plan then
        local msg = "cannot plan: " .. tostring(why)
        if blockers and #blockers.base > 0 then
          msg = msg .. "\nhive species needed: " .. table.concat(util.map(blockers.base, function(u) return self:label(u) end), ", ")
        end
        if blockers and #blockers.blocked > 0 then msg = msg .. "\nblocked mutations:\n  " .. table.concat(blockers.blocked, "\n  ") end
        return msg
      end
      if verb == "plan" then
        local out = { string.format("%s: %d step(s), cost %.1f", self:label(e.uid), #plan.steps, plan.cost) }
        for i, s in ipairs(plan.steps) do
          out[#out + 1] = string.format("%2d. %s + %s -> %s  %d%%  %s", i, self:label(s.a), self:label(s.b), self:label(s.result), s.chance, conditions.describeAll(s.conds))
        end
        if #plan.steps == 0 then out[#out + 1] = "already in the library" end
        return table.concat(out, "\n")
      end
      local lines = needs.summary(needs.forSteps(plan.steps, self:needsCtx()), false)
      if #lines == 0 then return self:label(e.uid) .. ": nothing beyond bees and honey" end
      table.insert(lines, 1, "required for " .. self:label(e.uid) .. ":")
      return table.concat(lines, "\n")
    elseif verb == "hives" then
      self:scanLibrary()
      local out = {}
      for _, e in ipairs(self.graph:speciesList()) do
        if self.graph:isBase(e.uid) then
          local d, p = self:dronesOf(e.uid), self:princessesOf(e.uid)
          out[#out + 1] = string.format("%-34s %s", self:label(e.uid),
            (d > 0 or p > 0) and string.format("have: %d drones, %d princesses", d, p) or "MISSING")
        end
      end
      table.sort(out)
      table.insert(out, 1, string.format("%d hive-only species (never bred, found in the world):", #out))
      return table.concat(out, "\n")
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
      for _, key in ipairs(util.sortedKeys(self.library)) do
        local b = self.library[key]
        local name = b.name or key
        if filter == "" or name:lower():find(filter, 1, true) then
          if key:match("^name:") then
            out[#out + 1] = string.format("%-30s unanalyzed %d", name, b.unanalyzed)
          else
            out[#out + 1] = string.format("%-30s drones %3d  princesses %2d%s", self:label(key), b.drones, b.princesses,
              b.hybrids > 0 and string.format("  (+%d hybrid)", b.hybrids) or "")
          end
        end
      end
      if #out > 40 then
        local n = #out
        while #out > 40 do table.remove(out) end
        out[#out + 1] = string.format("... %d more", n - 40)
      end
      if #out == 0 then return "library empty (is the ME network reachable?)" end
      if self.me and filter == "" then
        out[#out + 1] = string.format("honey drops in ME: %d", self.me:countLabel(self.cfg.honeyLabel or "Honey Drop"))
      end
      return table.concat(out, "\n")
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
    elseif verb == "retry" then
      local id = w[2]
      if not id then return "usage: retry <job|request>" end
      local revived = 0
      local function revive(j)
        if j.status == "failed" then
          j.status, j.error, j.attempts, j.cell = "pending", nil, 0, nil
          revived = revived + 1
        end
      end
      local job = self.S.jobs[id]
      if job then
        revive(job)
        local req = self:requestOf(job)
        if req and req.status == "blocked" then req.status = "active" end
      else
        local found
        for _, r in ipairs(self.S.requests) do
          if r.id == id then
            found = r
            for _, jid in ipairs(r.jobs) do if self.S.jobs[jid] then revive(self.S.jobs[jid]) end end
            if r.status == "blocked" or r.status == "cancelled" then r.status = "active" end
          end
        end
        if not found then return "no such job/request" end
      end
      self:saveState()
      self:dispatch()
      return string.format("%d job(s) back in the queue", revived)
    elseif verb == "scan" then
      self:scanLibrary(true)
      return string.format("library: %d species with drones, %d princesses", util.count(self:ownedSet()), self:princessPool())
    elseif verb == "survey" then
      local lines = {}
      local ok, res = survey.run(self.cfg.dataDir, function(l) lines[#lines + 1] = l end, { verbose = cmd.opts.all })
      if ok then
        self.graph = graph.load(self.cfg.dataDir .. "/graph.dat") or self.graph
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
    elseif sub == "interfaces" then
      return self:startPairing(w[3], false)
    elseif sub == "host" then
      if not w[3] then return "usage: settings host <url>" end
      self:setSetting("host.url", w[3])
      if not self.cfg.host.pushInterval then self:setSetting("host.pushInterval", 30) end
      self.relayBackoffUntil = 0
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
  -- interface pairing
  --
  -- The controller knows the ME interface addresses but cannot see inside
  -- the blocks. The robot sees the blocks but not their addresses. So the
  -- controller marks one interface at a time with honey drops and asks the
  -- robot which one it can reach: the interface it sees below itself is the
  -- bee library, the one above is the main interface. Sharing an ME network
  -- is not enough, because each interface is a separate block with its own
  -- slots and only the adjacent one can be reached.
  ----------------------------------------------------------------------
  obj.PAIR_SLOT = 5

  function obj:sendProbe(where, slot)
    local P = self.pairing
    self.probeSeq = (self.probeSeq or 0) + 1
    self.probeReply = nil
    P.waiting = true
    P.deadline = util.now() + 45
    self.link:send(P.addr, "probe", { reqId = "p" .. self.probeSeq, where = where, slot = slot })
  end

  function obj:startPairing(cellName, diagOnly)
    local c = cellName and self.cells[cellName] or nil
    if not c then
      local names = util.sortedKeys(self.cells)
      if #names == 1 then c = self.cells[names[1]] end
    end
    if not c or not c.addr then return "no cell is online; start the robot first" end
    if c.job then return "cell " .. c.name .. " is running job " .. tostring(c.job) .. "; cancel it first" end
    if self.pairing then return "already running, wait for it to finish" end
    local cands = {}
    if not diagOnly then
      if not self.me or not self.me.db then return "no ME network or database upgrade on the controller" end
      for addr in component.list("me_interface") do cands[#cands + 1] = addr end
      if #cands == 0 then return "no me_interface component: is an adapter touching each interface?" end
    end
    self.pairing = { name = c.name, addr = c.addr, cands = cands, i = 1, phase = diagOnly and "diag_down" or "stock",
                     seen = {}, sizes = {}, diagOnly = diagOnly, started = util.now() }
    if diagOnly then return "asking " .. c.name .. " what it can reach; watch the log" end
    return string.format("pairing %s against %d interface(s); this takes about a minute, watch the log", c.name, #cands)
  end

  function obj:pairMark(addr, on)
    local iface = ifaceProxy(addr)
    if not iface then return false, "address not reachable" end
    if not on then
      self.me:clearInterfaceSlot(iface, self.PAIR_SLOT)
      return true
    end
    return self.me:stockIntoInterface(iface, self.PAIR_SLOT, { label = self.cfg.honeyLabel or "Honey Drop" }, 2, 1)
  end

  function obj:pairTick()
    local P = self.pairing
    if not P then return end

    if P.waiting then
      local r = self.probeReply
      if not r then
        if util.now() > P.deadline then
          self:warn("pair: %s did not answer the probe; is the robot running main?", P.name)
          self.pairing = nil
        end
        return
      end
      self.probeReply = nil
      P.waiting = false
      P.sizes[r.where or "?"] = r.size
      if r.error then self:warn("pair: robot could not move to look %s: %s", tostring(r.where), tostring(r.error)) end
      if P.diagOnly then
        self:log("robot %s, looking %s: %s", P.name, tostring(r.where),
          (r.size or 0) == 0 and "nothing with an inventory" or
          string.format("%d slots%s", r.size, (r.filled or "") ~= "" and (", holding " .. r.filled) or ", empty"))
        P.phase = (r.where == "down" and "diag_up") or (r.where == "up" and "diag_front") or "report"
      else
        if r.label ~= nil and r.count == 2 then
          P.seen[r.where] = P.cands[P.i]
          self:log("pair: %s is the interface %s the robot", tostring(P.cands[P.i]):sub(1, 8),
            r.where == "down" and "below" or "above")
        end
        P.phase = (r.where == "down") and "probe_up" or "unmark"
      end
      return
    end

    if P.phase == "stock" then
      local addr = P.cands[P.i]
      if not addr or (P.seen.down and P.seen.up) then P.phase = "report" return end
      local ok, err = self:pairMark(addr, true)
      if not ok then
        self:warn("pair: cannot mark %s: %s", tostring(addr):sub(1, 8), tostring(err))
        P.i = P.i + 1
        return
      end
      P.marked = addr
      P.phase = "settle"
      P.settleUntil = util.now() + 4
    elseif P.phase == "settle" then
      if util.now() >= P.settleUntil then P.phase = "probe_down" end
    elseif P.phase == "probe_down" then
      self:sendProbe("down", self.PAIR_SLOT)
    elseif P.phase == "probe_up" then
      if P.seen.up then P.phase = "unmark" else self:sendProbe("up", self.PAIR_SLOT) end
    elseif P.phase == "unmark" then
      if P.marked then self:pairMark(P.marked, false) P.marked = nil end
      P.i = P.i + 1
      P.phase = "stock"
    elseif P.phase == "diag_down" then
      self:sendProbe("down", nil)
    elseif P.phase == "diag_up" then
      self:sendProbe("up", nil)
    elseif P.phase == "diag_front" then
      self:sendProbe("front", nil)
    elseif P.phase == "report" then
      if P.marked then self:pairMark(P.marked, false) end
      for _, line in ipairs(self:pairReport(P)) do self:log("%s", line) end
      self.pairing = nil
    end
  end

  ---Explain the outcome and save the addresses when both roles were found.
  function obj:pairReport(P)
    local out = {}
    if P.diagOnly then
      out[#out + 1] = "diag done. An ME interface reports 9 slots, the apiary more, air reports none."
      return out
    end
    local cellCfg = (self.cfg.cells or {})[P.name] or {}
    if P.seen.down then
      if cellCfg.beeInterface ~= P.seen.down then
        self:setSetting("cells." .. P.name .. ".beeInterface", P.seen.down)
        out[#out + 1] = "bee interface corrected to " .. P.seen.down:sub(1, 8) .. " and saved"
      else
        out[#out + 1] = "bee interface " .. P.seen.down:sub(1, 8) .. " was already right"
      end
    end
    if P.seen.up then
      if cellCfg.mainInterface ~= P.seen.up then
        self:setSetting("cells." .. P.name .. ".mainInterface", P.seen.up)
        out[#out + 1] = "main interface corrected to " .. P.seen.up:sub(1, 8) .. " and saved"
      else
        out[#out + 1] = "main interface " .. P.seen.up:sub(1, 8) .. " was already right"
      end
    end
    if not P.seen.down then
      local size = P.sizes.down or 0
      if size == 0 then
        out[#out + 1] = "PROBLEM: nothing with an inventory below the robot. The bee interface belongs"
        out[#out + 1] = "directly under the robot's lower position, two blocks below the parking spot."
      else
        out[#out + 1] = string.format("PROBLEM: an inventory of %d slots sits below the robot but the network", size)
        out[#out + 1] = "never put the marker in it: no adapter touches it, it is on another ME network,"
        out[#out + 1] = "or it has no channel or power."
      end
    end
    if not P.seen.up then
      out[#out + 1] = "the interface above the robot was not identified; honey and blocks cannot arrive"
    end
    if P.seen.down and P.seen.up then out[#out + 1] = "pairing done, start the job again with: retry r1" end
    return out
  end

  ----------------------------------------------------------------------
  -- Discord
  ----------------------------------------------------------------------
  function obj:statusEmbed()
    local fields = {}
    for _, name in ipairs(util.sortedKeys(self.cells)) do
      local c = self.cells[name]
      local job = c.job and self.S.jobs[c.job]
      local value
      if job then
        value = string.format("%s -> %s\ngen %s, %s", job.id, self:label(job.target), tostring(c.gen or 0), tostring(c.phase or "-"))
      else
        value = c.status
      end
      fields[#fields + 1] = { name, value }
    end
    local pending, running, waiting = 0, 0, {}
    for _, j in pairs(self.S.jobs) do
      if j.status == "pending" then pending = pending + 1
      elseif j.status == "running" then running = running + 1
      elseif j.status == "waiting" then waiting[#waiting + 1] = tostring(j.waitingFor) end
    end
    fields[#fields + 1] = { "Queue", string.format("%d running, %d pending%s", running, pending,
      #waiting > 0 and (", waiting for " .. table.concat(waiting, ", ")) or "") }
    fields[#fields + 1] = { "Library", string.format("%d species, %d princesses", util.count(self:ownedSet()), self:princessPool()) }
    return discord.embed("status", "Auto Bees status", nil, fields)
  end

  function obj:refreshStatusCard()
    if not self.discordOn or (self.cfg.discord or {}).statusCard == false then return end
    local id = self.dc:replace(self.S.discordStatusId, { embeds = json.array({ self:statusEmbed() }) })
    if id and id ~= true then self.S.discordStatusId = id; self:saveState() end
    self.statusDirty = false
  end

  function obj:discordTick()
    if not self.discordOn then return end
    local dcfg = self.cfg.discord or {}
    while #self.discordQueue > 0 do
      local item = table.remove(self.discordQueue, 1)
      local ok, err
      if item.embed then ok, err = self.dc:postEmbed(item.embed) else ok, err = self.dc:post(item.text) end
      if not ok then self:warn("discord post failed: %s", tostring(err)) break end
    end
    if self.statusDirty then self:refreshStatusCard() end
    if self.dc:canRead() and util.now() - self.lastPoll > (dcfg.pollInterval or 5) then
      self.lastPoll = util.now()
      local msgs, err = self.dc:poll()
      if err then self:warn("discord poll: %s", tostring(err)) end
      for _, m in ipairs(msgs) do
        local prefix = dcfg.prefix or "!"
        if not m.bot and m.content:sub(1, #prefix) == prefix then
          local line = m.content:sub(#prefix + 1)
          self:log("discord %s: %s", m.author, line)
          local ok, err2 = self.dc:send(self:discordReply(line, m.author))
          if not ok then self:warn("discord reply failed: %s", tostring(err2)) end
        end
      end
      if self.dc.lastId ~= self.S.discordLastId then self.S.discordLastId = self.dc.lastId; self:saveState() end
    end
    local interval = tonumber(dcfg.statusInterval) or 0
    if interval > 0 and util.now() - self.lastStatusPost > interval then
      self.lastStatusPost = util.now()
      self:refreshStatusCard()
    end
  end

  ----------------------------------------------------------------------
  -- custom host: status push + relay commands (buttons on Discord)
  ----------------------------------------------------------------------
  function obj:hostTick()
    local h = self.cfg.host or {}
    if not self.internet or (h.url or "") == "" then return end
    local interval = tonumber(h.pushInterval) or 0
    if interval > 0 and util.now() - self.lastPush >= interval then
      self.lastPush = util.now()
      local ok, why = connect.pushStatus(self.internet, h.url, self:statusTable(), connect.hostHeaders(h))
      if not ok and not self.hostWarned then
        self.hostWarned = true
        self:warn("host push failed: %s", tostring(why))
      elseif ok then
        self.hostWarned = false
      end
    end
    self:relayTick()
  end

  ---Ask the relay for queued commands (button clicks, slash commands) and answer them.
  function obj:relayTick()
    local h = self.cfg.host or {}
    if h.relay == false or util.now() < self.relayBackoffUntil then return end
    local pollEvery = tonumber(h.pollInterval) or 3
    if util.now() - self.lastRelayPoll < pollEvery then return end
    self.lastRelayPoll = util.now()
    local base = h.url:gsub("/+$", "")
    local headers = connect.hostHeaders(h)
    local code, body = http.request(self.internet, "GET", base .. "/commands", nil, headers, 5)
    if not code or code == 404 then
      -- no relay behind this host (or it is down): try again in a minute
      self.relayBackoffUntil = util.now() + 60
      return
    end
    if code < 200 or code >= 300 then return end
    local data = json.decode(body)
    local list = type(data) == "table" and (data.commands or data) or {}
    for _, c in ipairs(list) do
      if type(c) == "table" and c.line then
        self:log("relay %s: %s", tostring(c.user or "?"), c.line)
        local payload = self:discordReply(c.line, c.user or "relay")
        payload.id = c.id
        http.request(self.internet, "POST", base .. "/result", json.encode(payload), headers, 5)
      end
    end
  end

  ----------------------------------------------------------------------
  -- main loop (runs in a program-lib thread)
  ----------------------------------------------------------------------
  function obj:tick()
    self:scanLibrary()
    self:checkWaiting()
    self:dispatch()
    self:discordTick()
    self:hostTick()
    for _, c in pairs(self.cells) do
      if c.status ~= "offline" and util.now() - c.lastSeen > 120 then c.status = "offline" end
    end
    local okPair, whyPair = pcall(function() self:pairTick() end)
    if not okPair then
      self:warn("pair failed: %s", tostring(whyPair))
      self.pairing = nil
    end
    if self.interfaceProbe then
      for i = #self.interfaceProbe, 1, -1 do
        local p = self.interfaceProbe[i]
        if util.now() >= p.until_ then
          if self.me then self.me:clearInterfaceSlot(p.iface, 3) end
          table.remove(self.interfaceProbe, i)
        end
      end
    end
    if self.me and #self.me.slowCalls > 0 then
      for _, line in ipairs(self.me.slowCalls) do self:warn("slow ME call: %s", line) end
      self.me.slowCalls = {}
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
