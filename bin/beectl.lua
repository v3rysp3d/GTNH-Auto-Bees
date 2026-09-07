-- beectl : the controller. Planner, job queue, cell dispatcher, library
-- bookkeeping, text GUI, and the Discord bridge.
--
-- Needs on its network:
--   * ME network component (Adapter on an ME Interface/Controller)
--   * per cell: two ME Interfaces (main + bee library) each touched by an
--     Adapter that holds a Database upgrade
--   * wireless network card (or the same wired network as the robots)
--   * optional: internet card for Discord
-- Run `survey` first so graph.dat / catalog.dat exist.
--
-- usage: beectl            (config in /etc/beebreeder.cfg, see etc/beebreeder.cfg)
local component = require("component")
local computer = require("computer")
local event = require("event")
local term = require("term")
local keyboard = require("keyboard")
local util = require("bb.util")
local graph = require("bb.graph")
local catalog = require("bb.catalog")
local conditions = require("bb.conditions")
local climate = require("bb.climate")
local needs = require("bb.needs")
local ae2 = require("bb.ae2")
local net = require("bb.net")
local discord = require("bb.discord")
local housing = require("bb.housing")

local CFG_PATH = "/etc/beebreeder.cfg"
local defaults = {
  dataDir = "/home/beebreeder",
  port = 7311,
  ae2 = { network = nil, database = nil },
  cells = {},                 -- name -> { mainInterface=addr, beeInterface=addr, database=addr, base={temp,hum}, housing=... }
  stations = {},              -- kind -> { [name] = true }  e.g. { dimension = { End = true } }
  defaults = { keepDrones = 8, droneSupply = 16, maxGenerations = 400, warnAfter = 60 },
  interface = {
    main = { honey = 1, supply = 2, dump = 9 },
    bees = { princess = 1, drone = 2, archive = 9 },
  },
  honeyLabel = "Honey Drop",
  honeyStock = 64,
  chanceWeight = 0.1,
  foundationCostBase = 2,
  libraryScanInterval = 60,
  discord = { enabled = false, token = nil, channel = nil, webhook = nil, pollInterval = 5, prefix = "!", statusInterval = 0 },
  conditionPatterns = {},     -- { { pattern = "^Occurs only in dimension (.+)$", kind = "dimension" } }
  effectBlacklist = {},       -- species names never bred at home
  gui = true,
}
local cfg = util.merge(defaults, util.loadTable(CFG_PATH, {}))
util.mkdirs(cfg.dataDir)

for _, p in ipairs(cfg.conditionPatterns) do
  conditions.addPattern(p.pattern, function(m) return { kind = p.kind, name = m, block = m } end)
end

------------------------------------------------------------------------
-- data
------------------------------------------------------------------------
local graphTable = util.loadTable(cfg.dataDir .. "/graph.dat")
if not graphTable then
  print("No " .. cfg.dataDir .. "/graph.dat. Run `survey` first.")
  return
end
local g = graph.fromTable(graphTable)
local cat = catalog.new(cfg.dataDir .. "/catalog.dat")
cat:load()
cat:assign(g:speciesList())
cat:save()

local STATE_PATH = cfg.dataDir .. "/state.dat"
local S = util.loadTable(STATE_PATH, { requests = {}, jobs = {}, nextId = 1, discordLastId = nil })
S.requests = S.requests or {}
S.jobs = S.jobs or {}
S.nextId = S.nextId or 1
local function saveState() util.saveTable(STATE_PATH, S) end

local cells = {}          -- name -> { addr=, status=, lastSeen=, job=, housing=, foundation=, gen=, phase=, cfg= }
local library = {}        -- species -> counts
local libraryScannedAt = 0
local logLines = {}
local dirty = true
local requestsByReqId = {} -- reqId -> { cell=, iface=, slot= }

------------------------------------------------------------------------
-- components
------------------------------------------------------------------------
local meProxy = ae2.findNetwork(component, cfg.ae2.network)
local me = meProxy and ae2.new(meProxy) or nil
if me then
  local dbAddr = cfg.ae2.database or component.list("database")()
  if dbAddr then me:setDatabase(component.proxy(dbAddr)) end
end
local modemAddr = component.list("modem")()
local link = net.new(modemAddr and component.proxy(modemAddr) or nil, cfg.port, "controller")
local internetAddr = component.list("internet")()
local dc = discord.new(internetAddr and component.proxy(internetAddr) or nil, {
  token = cfg.discord.token, channel = cfg.discord.channel, webhook = cfg.discord.webhook, lastId = S.discordLastId,
})
local discordOn = cfg.discord.enabled and dc:enabled()

------------------------------------------------------------------------
-- logging
------------------------------------------------------------------------
local function log(fmt, ...)
  local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  local line = os.date("%H:%M:%S ") .. msg
  logLines[#logLines + 1] = line
  if #logLines > 200 then table.remove(logLines, 1) end
  if not cfg.gui then print(line) end
  dirty = true
end

local discordQueue = {}
local function notify(text)
  log("%s", text)
  if discordOn then discordQueue[#discordQueue + 1] = text end
end

------------------------------------------------------------------------
-- library
------------------------------------------------------------------------
local function scanLibrary(force)
  if not me then return end
  if not force and util.now() - libraryScannedAt < cfg.libraryScanInterval then return end
  local ok, lib = pcall(function() return me:library() end)
  if ok and type(lib) == "table" then
    library = lib
    libraryScannedAt = util.now()
    dirty = true
  else
    log("library scan failed: %s", tostring(lib))
  end
end

local function ownedSet()
  local owned = {}
  for name, b in pairs(library) do if b.drones > 0 then owned[name] = true end end
  return owned
end

local function princessPool()
  local n = 0
  for _, b in pairs(library) do n = n + b.princesses end
  return n
end

local function dronesOf(name) return library[name] and library[name].drones or 0 end
local function princessesOf(name) return library[name] and library[name].princesses or 0 end

------------------------------------------------------------------------
-- stations / condition costs
------------------------------------------------------------------------
local function stationAvailable(kind, name)
  if kind == "gtmachine" then return cfg.stations.gtmachine == true end
  local list = cfg.stations[kind]
  return list ~= nil and (list[name] == true or list["*"] == true)
end

--- Extra planner cost for a mutation's conditions; nil = cannot do it.
local function conditionCost(conds, m)
  local cost = 0
  for _, c in ipairs(conds) do
    if c.kind == "foundation" then
      cost = cost + cfg.foundationCostBase
      if me then
        if me:countLabel(c.block) == 0 and not me:hasPattern(c.block) then cost = cost + 50 end
      end
    elseif c.kind == "temperature" or c.kind == "humidity" then
      cost = cost + 1
    elseif c.kind == "dimension" or c.kind == "biomeId" or c.kind == "biome" or c.kind == "gtmachine" then
      local name = c.name or (c.types and table.concat(c.types, "/")) or c.kind
      if not stationAvailable(c.kind, name) then return nil end
      cost = cost + 5
    elseif c.kind == "daytime" or c.kind == "date" then
      cost = cost + 3
    elseif c.kind == "unknown" then
      cost = cost + 20
    end
  end
  if cfg.effectBlacklist[m.result] then return nil end
  return cost
end

local function planFor(target)
  return g:plan(target, ownedSet(), { chanceWeight = cfg.chanceWeight, conditionCost = conditionCost })
end

------------------------------------------------------------------------
-- requests -> jobs
------------------------------------------------------------------------
local function newId(prefix)
  local id = prefix .. S.nextId
  S.nextId = S.nextId + 1
  return id
end

local function jobFromStep(req, step, keep)
  local foundation, needTemp, needHum = nil, nil, nil
  for _, c in ipairs(step.conds or {}) do
    if c.kind == "foundation" then foundation = c.block end
    if c.kind == "temperature" then needTemp = { min = c.min, max = c.max } end
    if c.kind == "humidity" then needHum = { min = c.min, max = c.max } end
  end
  return {
    id = newId("j"), request = req.id, kind = "mutate",
    target = step.result, a = step.a, b = step.b, chance = step.chance, conds = step.conds,
    foundation = foundation, needTemp = needTemp, needHum = needHum,
    keepDrones = keep, wantPrincess = true,
    droneSupply = cfg.defaults.droneSupply, maxGenerations = cfg.defaults.maxGenerations, warnAfter = cfg.defaults.warnAfter,
    status = "pending", created = util.now(),
  }
end

local function stockJob(req, species, keep)
  return {
    id = newId("j"), request = req.id, kind = "stock",
    target = species, a = species, b = species, chance = 100, conds = {},
    keepDrones = keep, wantPrincess = true,
    droneSupply = cfg.defaults.droneSupply, maxGenerations = cfg.defaults.maxGenerations,
    status = "pending", created = util.now(),
  }
end

--- Create a request. opts: { keep = n, extra = { [species] = n }, princess = bool }
local function addRequest(targetName, opts, who)
  opts = opts or {}
  scanLibrary(true)
  local plan, why, blockers = planFor(targetName)
  if not plan then
    local msg = why
    if blockers then
      if #blockers.base > 0 then msg = msg .. "; hive species needed: " .. table.concat(blockers.base, ", ") end
      if #blockers.blocked > 0 then msg = msg .. "; blocked: " .. table.concat(blockers.blocked, " | ") end
    end
    return nil, msg
  end
  local req = { id = newId("r"), target = targetName, by = who or "gui", created = util.now(),
    keep = opts.keep or cfg.defaults.keepDrones, extra = opts.extra or {}, status = "active", jobs = {} }
  local keepAll = opts.keepAll
  -- A step with chance p burns roughly 100/p parent drones before it hits,
  -- so every parent gets stockpiled to at least that (capped at a stack).
  local needed = {}
  for _, step in ipairs(plan.steps) do
    local n = math.min(64, math.ceil(100 / math.max(step.chance or 10, 1)) + 4)
    for _, parent in ipairs({ step.a, step.b }) do needed[parent] = math.max(needed[parent] or 0, n) end
  end
  local produced = {}
  for _, step in ipairs(plan.steps) do produced[step.result] = true end
  local stocked = {}
  for _, step in ipairs(plan.steps) do
    -- parents we already own but hold too few of: stock them up first
    for _, parent in ipairs({ step.a, step.b }) do
      if not produced[parent] and not stocked[parent] and dronesOf(parent) < math.min(needed[parent] or 0, 16) then
        stocked[parent] = true
        local sj = stockJob(req, parent, needed[parent])
        S.jobs[sj.id] = sj
        req.jobs[#req.jobs + 1] = sj.id
      end
    end
    local keep = math.max(cfg.defaults.keepDrones, needed[step.result] or 0)
    if step.result == targetName then keep = req.keep end
    if keepAll then keep = math.max(keep, keepAll) end
    if req.extra[step.result] then keep = math.max(keep, req.extra[step.result]) end
    local job = jobFromStep(req, step, keep)
    S.jobs[job.id] = job
    req.jobs[#req.jobs + 1] = job.id
  end
  -- extras for species we already own (or the target itself when owned)
  for species, n in pairs(req.extra) do
    local produced = false
    for _, step in ipairs(plan.steps) do if step.result == species then produced = true end end
    if not produced then
      if not g.species[species] then return nil, "unknown extra species " .. species end
      local job = stockJob(req, species, n)
      S.jobs[job.id] = job
      req.jobs[#req.jobs + 1] = job.id
    end
  end
  if #plan.steps == 0 and util.count(req.extra) == 0 then
    local job = stockJob(req, targetName, req.keep)
    S.jobs[job.id] = job
    req.jobs[#req.jobs + 1] = job.id
  end
  S.requests[#S.requests + 1] = req
  saveState()
  dirty = true
  return req, plan
end

local function jobReady(job)
  if job.status ~= "pending" then return false end
  if job.kind == "stock" then
    return dronesOf(job.target) > 0 and (princessesOf(job.target) > 0 or princessPool() > 0)
  end
  if dronesOf(job.a) == 0 or dronesOf(job.b) == 0 then return false end
  return princessPool() > 0
end

local function nextReadyJob()
  -- oldest request first, in step order
  for _, req in ipairs(S.requests) do
    if req.status == "active" then
      for _, jid in ipairs(req.jobs) do
        local job = S.jobs[jid]
        if job and jobReady(job) then return job end
      end
    end
  end
  return nil
end

local function requestOf(job)
  for _, req in ipairs(S.requests) do if req.id == job.request then return req end end
end

local function updateRequestStatus(req)
  local allDone, anyFailed = true, false
  for _, jid in ipairs(req.jobs) do
    local job = S.jobs[jid]
    if job then
      if job.status ~= "done" then allDone = false end
      if job.status == "failed" then anyFailed = true end
    end
  end
  if allDone then req.status = "done"
  elseif anyFailed then req.status = "blocked" end
end

------------------------------------------------------------------------
-- cells
------------------------------------------------------------------------
local function cellFor(name)
  local c = cells[name]
  if not c then
    c = { name = name, status = "unknown", lastSeen = 0, cfg = cfg.cells[name] or {} }
    cells[name] = c
  end
  return c
end

local function cellByAddr(addr)
  for _, c in pairs(cells) do if c.addr == addr then return c end end
  return nil
end

local function ifaceProxy(addr)
  if not addr then return nil end
  local ok, p = pcall(component.proxy, addr)
  if ok then return p end
  return nil
end

--- Prepare the job for a specific cell: climate solution, foundation craft.
local function prepareJob(job, c)
  local base = c.cfg.base or { temp = 0.8, hum = 0.4 }
  if job.needTemp or job.needHum then
    local sol, why = climate.solve({ baseTemp = base.temp, baseHum = base.hum, needTemp = job.needTemp, needHum = job.needHum })
    if not sol then return false, "climate: " .. why end
    job.climate = climate.upgradeCounts(sol)
  else
    job.climate = {}
  end
  if job.foundation and me then
    if me:countLabel(job.foundation) == 0 then
      local status, err = me:craft(job.foundation, 1)
      if status then notify(string.format("crafting %s for %s", job.foundation, cat:label(job.target)))
      else return false, "no " .. job.foundation .. " in stock and " .. tostring(err) end
    end
  end
  return true
end

local function dispatch()
  for name, c in pairs(cells) do
    if c.status == "idle" and c.addr and not c.job then
      local job = nextReadyJob()
      if not job then return end
      local ok, why = prepareJob(job, c)
      if not ok then
        job.status = "failed"
        job.error = why
        notify(string.format("%s cannot start: %s", job.id, why))
        updateRequestStatus(requestOf(job))
        saveState()
      else
        job.status = "running"
        job.cell = name
        job.started = util.now()
        c.job = job.id
        c.status = "busy"
        c.gen, c.phase = 0, "prepare"
        local payload = {
          id = job.id, target = job.target, a = job.a, b = job.b, chance = job.chance,
          keepDrones = job.keepDrones, wantPrincess = job.wantPrincess, foundation = job.foundation,
          climate = job.climate, droneSupply = job.droneSupply, maxGenerations = job.maxGenerations, warnAfter = job.warnAfter,
        }
        link:send(c.addr, "job", payload)
        notify(string.format("%s -> %s: %s + %s -> %s%s", job.id, name, cat:label(job.a), cat:label(job.b), cat:label(job.target),
          job.foundation and (" [" .. job.foundation .. "]") or ""))
        saveState()
      end
    end
  end
end

--- Handle a robot's "need" request: stock the right interface slot.
local function handleNeed(c, p, remote)
  local function fail(reason)
    link:send(remote, "fail", { reqId = p.reqId, reason = reason })
    log("%s need refused: %s", c.name, reason)
  end
  if not me or not me.db then return fail("controller has no ME network/database") end
  local mainIface = ifaceProxy(c.cfg.mainInterface)
  local beeIface = ifaceProxy(c.cfg.beeInterface)
  local dbSlot = 1
  if p.species ~= nil or p.kind then
    if not beeIface then return fail("cell has no beeInterface configured") end
    local slot = (p.kind == "princess") and cfg.interface.bees.princess or cfg.interface.bees.drone
    local label
    if p.species then
      label = p.species .. (p.kind == "princess" and " Princess" or " Drone")
    else
      -- any princess: take the species with the most princesses
      local bestName, bestN = nil, 0
      for name, b in pairs(library) do if b.princesses > bestN then bestName, bestN = name, b.princesses end end
      if not bestName then return fail("no princesses in the library") end
      label = bestName .. " Princess"
    end
    local ok, err = me:stockIntoInterface(beeIface, slot, { label = label }, p.count or 1, dbSlot)
    if not ok then return fail(err) end
    requestsByReqId[p.reqId] = { iface = beeIface, slot = slot }
    link:send(remote, "ready", { reqId = p.reqId, slot = slot })
  elseif p.honey then
    if not mainIface then return fail("cell has no mainInterface configured") end
    local ok, err = me:stockIntoInterface(mainIface, cfg.interface.main.honey, { label = cfg.honeyLabel }, cfg.honeyStock, dbSlot)
    if not ok then return fail(err) end
    link:send(remote, "ready", { reqId = p.reqId, slot = cfg.interface.main.honey })
  elseif p.item then
    if not mainIface then return fail("cell has no mainInterface configured") end
    if me:countLabel(p.item) == 0 then
      local status, err = me:craft(p.item, p.count or 1)
      if not status then return fail("no " .. p.item .. " and no pattern: " .. tostring(err)) end
      -- give the crafting a moment; the robot will retry if the slot stays empty
      notify("crafting " .. p.item)
      local deadline = util.now() + 60
      while util.now() < deadline and me:countLabel(p.item) == 0 do os.sleep(1) end
    end
    local ok, err = me:stockIntoInterface(mainIface, cfg.interface.main.supply, { label = p.item }, p.count or 1, dbSlot)
    if not ok then return fail(err) end
    requestsByReqId[p.reqId] = { iface = mainIface, slot = cfg.interface.main.supply }
    link:send(remote, "ready", { reqId = p.reqId, slot = cfg.interface.main.supply })
  elseif p.upgrade then
    if not mainIface then return fail("cell has no mainInterface configured") end
    -- find an Industrial Apiary upgrade item whose label contains the key
    local key = tostring(p.upgrade):lower()
    local found
    for _, st in ipairs(me:items()) do
      local l = tostring(st.label or ""):lower()
      if l:find("apiary", 1, true) and l:find(key, 1, true) then found = st.label break end
    end
    if not found then return fail("no '" .. key .. "' apiary upgrade in the ME network") end
    local ok, err = me:stockIntoInterface(mainIface, cfg.interface.main.supply, { label = found }, p.count or 1, dbSlot)
    if not ok then return fail(err) end
    requestsByReqId[p.reqId] = { iface = mainIface, slot = cfg.interface.main.supply }
    link:send(remote, "ready", { reqId = p.reqId, slot = cfg.interface.main.supply })
  else
    fail("unknown need")
  end
end

local function finishJob(job, ok, info)
  local req = requestOf(job)
  if ok then
    job.status = "done"
    job.finished = util.now()
    notify(string.format("%s done: %s in %d generations, %d drones + %s princess archived",
      job.id, cat:label(job.target), info.generations or 0, info.archivedDrones or 0, info.princess and "1" or "no"))
  else
    local missing = (info.reason or ""):match("ran out of drones %(([^/%)]+)")
    if missing and req and g.species[missing] then
      -- restock the species that ran dry, then run this job again
      local sj = stockJob(req, missing, 32)
      S.jobs[sj.id] = sj
      for i, jid in ipairs(req.jobs) do
        if jid == job.id then table.insert(req.jobs, i, sj.id) break end
      end
      job.status = "pending"
      job.cell = nil
      if dronesOf(missing) == 0 then
        notify(string.format("%s ran out of %s drones and the library has none left: add some to the ME network", job.id, cat:label(missing)))
      else
        notify(string.format("%s ran out of %s drones; stockpiling %s first (%s)", job.id, cat:label(missing), cat:label(missing), sj.id))
      end
      updateRequestStatus(req)
      saveState()
      scanLibrary(true)
      return
    end
    job.attempts = (job.attempts or 0) + 1
    if job.attempts < 3 and not (info.reason or ""):match("cancelled") then
      job.status = "pending"
      notify(string.format("%s failed (%s), will retry", job.id, tostring(info.reason)))
    else
      job.status = "failed"
      job.error = info.reason
      notify(string.format("%s FAILED: %s", job.id, tostring(info.reason)))
    end
  end
  if req then updateRequestStatus(req) end
  saveState()
  scanLibrary(true)
end

local function handleMessage(msg)
  local p = msg.payload
  local c = nil
  if msg.type == "hello" or msg.type == "idle" or msg.type == "pong" then
    c = cellFor(p.name or msg.from)
    c.addr = msg.remote
    c.lastSeen = util.now()
    c.housing = p.housing or c.housing
    if p.foundation then c.foundation = p.foundation end
    if msg.type == "hello" then
      link:send(msg.remote, "welcome", {})
      log("cell %s online (%s)", c.name, tostring(c.housing))
    end
    if msg.type ~= "pong" then
      if p.job == nil and not c.job then c.status = "idle" end
    end
    dirty = true
    return
  end
  c = cellByAddr(msg.remote) or cellFor(msg.from)
  c.lastSeen = util.now()
  if msg.type == "accepted" then
    c.status = "busy"
  elseif msg.type == "busy" then
    log("%s is busy, re-queueing %s", c.name, tostring(p.job))
    local job = S.jobs[p.job]
    if job then job.status = "pending"; job.cell = nil end
    c.job = nil
  elseif msg.type == "need" then
    handleNeed(c, p, msg.remote)
  elseif msg.type == "got" then
    local r = requestsByReqId[p.reqId]
    if r and me then me:clearInterfaceSlot(r.iface, r.slot) end
    requestsByReqId[p.reqId] = nil
  elseif msg.type == "badstock" then
    notify(string.format("%s: library sent a non-pure %s %s, quarantined", c.name, tostring(p.species), tostring(p.kind)))
  elseif msg.type == "event" then
    local d = p.data or {}
    if p.kind == "gen" then
      c.gen = d.generation
      c.phase = d.phase
      c.lastGen = util.now()
      c.hits = (c.hits or 0) + (d.hits or 0)
      if d.hits and d.hits > 0 then
        local job = S.jobs[d.job]
        log("%s gen %d: %d hit(s) for %s", c.name, d.generation or 0, d.hits, job and cat:label(job.target) or "?")
      end
    elseif p.kind == "phase" then
      c.phase = d.to
      local job = S.jobs[d.job]
      if d.to == "purify" or d.to == "stockpile" then
        notify(string.format("%s: %s reached phase %s at generation %d", c.name, job and cat:label(job.target) or "?", d.to, d.generation or 0))
      end
    elseif p.kind == "warn" then
      notify(string.format("%s: %s", c.name, tostring(d.text)))
    elseif p.kind == "error" then
      log("%s error: %s", c.name, tostring(d.reason))
    end
    dirty = true
  elseif msg.type == "result" then
    local job = S.jobs[p.job]
    c.job = nil
    c.status = "idle"
    c.gen, c.phase = nil, nil
    if job then finishJob(job, p.ok, p) end
  elseif msg.type == "aborted" then
    local job = S.jobs[p.job]
    if job and job.status == "running" then
      job.status = "pending"
      job.cell = nil
      notify(string.format("%s was interrupted on %s (%s), re-queued", p.job, c.name, tostring(p.reason)))
    end
    c.job = nil
    c.status = "idle"
    saveState()
  end
  dirty = true
end

------------------------------------------------------------------------
-- commands (shared by the GUI input line and Discord)
------------------------------------------------------------------------
local function fmtStatus()
  local out = {}
  local active, done = 0, 0
  for _, r in ipairs(S.requests) do if r.status == "active" then active = active + 1 elseif r.status == "done" then done = done + 1 end end
  out[#out + 1] = string.format("requests: %d active, %d done | library: %d species with drones, %d princesses",
    active, done, util.count(ownedSet()), princessPool())
  for name, c in pairs(cells) do
    local job = c.job and S.jobs[c.job]
    local age = util.now() - (c.lastSeen or 0)
    if job then
      out[#out + 1] = string.format("%s: %s -> %s gen %s [%s] (%s)", name, job.id, cat:label(job.target), tostring(c.gen or 0), tostring(c.phase or "?"), util.fmtSeconds(util.now() - (job.started or util.now())))
    else
      out[#out + 1] = string.format("%s: %s (seen %s ago)", name, c.status, util.fmtSeconds(age))
    end
  end
  return table.concat(out, "\n")
end

local function fmtQueue()
  local out = {}
  for _, r in ipairs(S.requests) do
    if r.status ~= "done" then
      out[#out + 1] = string.format("%s %s -> %s by %s", r.id, r.status, cat:label(r.target), r.by or "?")
      for _, jid in ipairs(r.jobs) do
        local j = S.jobs[jid]
        if j then
          out[#out + 1] = string.format("   %s %-8s %s + %s -> %s keep %d%s%s", j.id, j.status, cat:label(j.a), cat:label(j.b), cat:label(j.target), j.keepDrones or 0,
            j.cell and (" @" .. j.cell) or "", j.error and (" !" .. j.error) or "")
        end
      end
    end
  end
  if #out == 0 then out[1] = "queue empty" end
  return table.concat(out, "\n")
end

local function parseExtras(list)
  local extra = {}
  for _, item in ipairs(list or {}) do
    local tok, n = item:match("^(.-)=(%d+)$")
    if not tok then tok, n = item, cfg.defaults.keepDrones end
    local e, err = cat:resolve(tok)
    if not e then return nil, err end
    extra[e.name] = tonumber(n)
  end
  return extra
end

local function command(line, who)
  local cmd = util.parseCommand(line)
  local w = cmd.words
  local verb = (w[1] or ""):lower()
  if verb == "" then return "" end
  if verb == "help" then
    return table.concat({
      "breed <id|name> [keep N] [extra id=N ...] [all N]   queue a species (chain included)",
      "plan <id|name>       show the chain the planner would use",
      "needs <id|name>      autocraft / station needs for that chain",
      "find <text>          look up catalog numbers",
      "status | queue | cells | library [text] | cancel <job|request> | scan | help",
    }, "\n")
  elseif verb == "find" then
    local list = cat:find(w[2] or "", 25)
    if #list == 0 then return "no match" end
    return table.concat(util.map(list, function(e) return string.format("%d %s (%s)", e.id, e.name, e.mod or "?") end), "\n")
  elseif verb == "plan" or verb == "needs" or verb == "breed" then
    local e, err = cat:resolve(w[2])
    if not e then return "error: " .. tostring(err) end
    if verb == "breed" then
      local extra, err2 = parseExtras(cmd.opts.extra)
      if not extra then return "error: " .. tostring(err2) end
      local req, info = addRequest(e.name, { keep = tonumber(cmd.opts.keep), extra = extra, keepAll = tonumber(cmd.opts.all) }, who)
      if not req then return "cannot plan " .. cat:label(e.name) .. ": " .. tostring(info) end
      notify(string.format("%s queued %s: %d step(s)", who or "gui", cat:label(e.name), #req.jobs))
      dispatch()
      return string.format("queued %s as %s with %d job(s)", cat:label(e.name), req.id, #req.jobs)
    end
    scanLibrary()
    local plan, why, blockers = planFor(e.name)
    if not plan then
      local msg = "cannot plan: " .. tostring(why)
      if blockers and #blockers.base > 0 then msg = msg .. "\nhive species needed: " .. table.concat(blockers.base, ", ") end
      if blockers and #blockers.blocked > 0 then msg = msg .. "\nblocked mutations:\n  " .. table.concat(blockers.blocked, "\n  ") end
      return msg
    end
    if verb == "plan" then
      local out = { string.format("%s: %d step(s), cost %.1f", cat:label(e.name), #plan.steps, plan.cost) }
      for i, s in ipairs(plan.steps) do
        out[#out + 1] = string.format("%2d. %s + %s -> %s  %d%%  %s", i, cat:label(s.a), cat:label(s.b), cat:label(s.result), s.chance, conditions.describeAll(s.conds))
      end
      if #plan.steps == 0 then out[#out + 1] = "already in the library" end
      return table.concat(out, "\n")
    else
      local ctx = { base = { temp = 0.8, hum = 0.4 }, station = stationAvailable }
      if me then
        ctx.haveCount = function(label) return me:countLabel(label) end
        ctx.craftable = function(label) return me:hasPattern(label) end
      end
      local rep = needs.forSteps(plan.steps, ctx)
      return table.concat(needs.lines(rep, false), "\n")
    end
  elseif verb == "status" then
    return fmtStatus()
  elseif verb == "queue" then
    return fmtQueue()
  elseif verb == "cells" then
    local out = {}
    for name, c in pairs(cells) do
      out[#out + 1] = string.format("%s %s housing=%s foundation=%s addr=%s", name, c.status, tostring(c.housing), tostring(c.foundation), c.addr and c.addr:sub(1, 8) or "?")
    end
    return #out > 0 and table.concat(out, "\n") or "no cells have reported yet"
  elseif verb == "library" then
    scanLibrary(true)
    local out = {}
    local filter = (w[2] or ""):lower()
    for _, name in ipairs(util.sortedKeys(library)) do
      local b = library[name]
      if filter == "" or name:lower():find(filter, 1, true) then
        out[#out + 1] = string.format("%-28s drones %3d  princesses %2d%s", cat:label(name), b.drones, b.princesses,
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
    local job = S.jobs[id]
    if job then
      if job.status == "running" and job.cell and cells[job.cell] and cells[job.cell].addr then
        link:send(cells[job.cell].addr, "cancel", { job = id })
      end
      job.status = "failed"
      job.error = "cancelled"
      updateRequestStatus(requestOf(job))
      saveState()
      return "cancelled " .. id
    end
    for _, r in ipairs(S.requests) do
      if r.id == id then
        r.status = "cancelled"
        for _, jid in ipairs(r.jobs) do
          local j = S.jobs[jid]
          if j and j.status ~= "done" then
            if j.status == "running" and j.cell and cells[j.cell] and cells[j.cell].addr then
              link:send(cells[j.cell].addr, "cancel", { job = jid })
            end
            j.status = "failed"
            j.error = "cancelled"
          end
        end
        saveState()
        return "cancelled " .. id
      end
    end
    return "no such job/request"
  elseif verb == "scan" then
    scanLibrary(true)
    return string.format("library: %d species with drones, %d princesses", util.count(ownedSet()), princessPool())
  end
  return "unknown command, try help"
end

------------------------------------------------------------------------
-- GUI (text, redraws on change)
------------------------------------------------------------------------
local gpu = cfg.gui and term.isAvailable() and term.gpu() or nil
local inputBuffer = ""
local outputLines = {}

local function draw()
  if not gpu or not dirty then return end
  dirty = false
  local w, h = gpu.getResolution()
  gpu.setBackground(0x000000)
  gpu.setForeground(0xFFFFFF)
  gpu.fill(1, 1, w, h, " ")
  gpu.setForeground(0xFFD700)
  gpu.set(1, 1, util.pad(string.format(" BeeBreeder  cells %d  library %d/%d  %s", util.count(cells), util.count(ownedSet()), princessPool(), discordOn and "discord on" or "discord off"), w))
  gpu.setForeground(0xFFFFFF)
  local leftW = math.floor(w * 0.55)
  -- left: queue
  local y = 3
  gpu.setForeground(0x00FF00)
  gpu.set(1, 2, "QUEUE")
  gpu.setForeground(0xFFFFFF)
  for line in (fmtQueue() .. "\n"):gmatch("(.-)\n") do
    if y > math.floor(h * 0.6) then break end
    gpu.set(1, y, util.pad(line, leftW - 1))
    y = y + 1
  end
  -- right: cells
  gpu.setForeground(0x00FF00)
  gpu.set(leftW + 1, 2, "CELLS")
  gpu.setForeground(0xFFFFFF)
  y = 3
  for line in (fmtStatus() .. "\n"):gmatch("(.-)\n") do
    if y > math.floor(h * 0.6) then break end
    gpu.set(leftW + 1, y, util.pad(line, w - leftW))
    y = y + 1
  end
  -- bottom: log / output
  local top = math.floor(h * 0.6) + 1
  gpu.setForeground(0x00FF00)
  gpu.set(1, top, "LOG")
  gpu.setForeground(0xAAAAAA)
  local rows = h - top - 2
  local src = #outputLines > 0 and outputLines or logLines
  local start = math.max(1, #src - rows + 1)
  for i = start, #src do
    gpu.set(1, top + 1 + (i - start), util.pad(src[i], w))
  end
  gpu.setForeground(0xFFFFFF)
  gpu.set(1, h, util.pad("> " .. inputBuffer, w))
end

local function runInput(line)
  outputLines = {}
  local res = command(line, "gui")
  for l in (tostring(res) .. "\n"):gmatch("(.-)\n") do outputLines[#outputLines + 1] = l end
  dirty = true
end

------------------------------------------------------------------------
-- Discord
------------------------------------------------------------------------
local lastPoll, lastStatusPost, statusMsgId = 0, 0, nil

local function discordTick()
  if not discordOn then return end
  -- outbound queue
  while #discordQueue > 0 do
    local text = table.remove(discordQueue, 1)
    local ok, err = dc:post(text)
    if not ok then log("discord post failed: %s", tostring(err)) break end
  end
  -- inbound commands
  if dc:canRead() and util.now() - lastPoll > (cfg.discord.pollInterval or 5) then
    lastPoll = util.now()
    local msgs, err = dc:poll()
    if err then log("discord poll: %s", tostring(err)) end
    for _, m in ipairs(msgs) do
      local prefix = cfg.discord.prefix or "!"
      if not m.bot and m.content:sub(1, #prefix) == prefix then
        local line = m.content:sub(#prefix + 1)
        log("discord %s: %s", m.author, line)
        local res = command(line, m.author)
        dc:post("**" .. line .. "**\n```\n" .. tostring(res) .. "\n```")
      end
    end
    if dc.lastId ~= S.discordLastId then S.discordLastId = dc.lastId; saveState() end
  end
  -- optional live status message
  local interval = cfg.discord.statusInterval or 0
  if interval > 0 and dc:canRead() and util.now() - lastStatusPost > interval then
    lastStatusPost = util.now()
    statusMsgId = dc:edit(statusMsgId, "```\n" .. fmtStatus() .. "\n```") or statusMsgId
  end
end

------------------------------------------------------------------------
-- main loop
------------------------------------------------------------------------
log("beectl starting: %d species, %d mutations, ME %s, modem %s, discord %s",
  util.count(g.species), #g.mutations, me and "ok" or "MISSING", modemAddr and "ok" or "MISSING", discordOn and "on" or "off")
if not me then log("WARNING: no ME network component; library and stocking are disabled") end
if not me or not me.db then log("WARNING: no Database upgrade found; the robots cannot be served") end

-- re-queue jobs that were running when we last stopped; cells will re-announce
for _, job in pairs(S.jobs) do
  if job.status == "running" then job.status = "pending"; job.cell = nil end
end
saveState()
scanLibrary(true)
if discordOn then
  if not S.discordLastId then dc:syncCursor(); S.discordLastId = dc.lastId; saveState() end
  discordQueue[#discordQueue + 1] = "BeeBreeder controller online. Type `" .. (cfg.discord.prefix or "!") .. "help`."
end
link:broadcast("whois", {})

local lastDispatch = 0
while true do
  draw()
  local sig = table.pack(event.pull(0.5))
  local name = sig[1]
  if name == "modem_message" then
    local msg = link:decode(table.unpack(sig, 1, sig.n))
    if msg then
      local ok, err = pcall(handleMessage, msg)
      if not ok then log("message error: %s", tostring(err)) end
    end
  elseif name == "key_down" and gpu then
    local char, code = sig[3], sig[4]
    if code == keyboard.keys.enter then
      local line = inputBuffer
      inputBuffer = ""
      if line == "quit" or line == "exit" then break end
      local ok, err = pcall(runInput, line)
      if not ok then log("command error: %s", tostring(err)) end
    elseif code == keyboard.keys.back then
      inputBuffer = inputBuffer:sub(1, -2)
      dirty = true
    elseif char and char >= 32 and char < 127 then
      inputBuffer = inputBuffer .. string.char(char)
      dirty = true
    end
  elseif name == "interrupted" then
    break
  end
  if util.now() - lastDispatch > 2 then
    lastDispatch = util.now()
    scanLibrary()
    local ok, err = pcall(dispatch)
    if not ok then log("dispatch error: %s", tostring(err)) end
    local okD, errD = pcall(discordTick)
    if not okD then log("discord error: %s", tostring(errD)) end
    -- cells that went quiet
    for _, c in pairs(cells) do
      if c.status ~= "offline" and util.now() - c.lastSeen > 120 then
        c.status = "offline"
        dirty = true
      end
    end
  end
end
if gpu then term.clear() end
saveState()
print("beectl stopped")
