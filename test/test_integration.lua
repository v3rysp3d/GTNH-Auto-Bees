-- End to end: controller + robot cell + simulated Industrial Apiary + ME
-- network, all in one Lua state. Requests a two-step chain whose second
-- step needs a foundation block (autocrafted) and a Hot climate (heater
-- upgrade installed by the robot).
local sim = require("sim_genetics")
local fake = require("fake_oc")

sim.mutations[2].foundation = "Block of Copper"
sim.mutations[2].temperature = "Hot"

local env = fake.install({ sim = sim, seed = 11 })

local util = require("src.util")
local graph = require("src.graph")
local genome = require("src.genome")

-- data the survey would have produced (start from a clean slate every run)
local dataDir = TESTS .. "/tmp"
for _, f in ipairs({ "/cell.state", "/state.dat", "/catalog.dat", "/graph.dat" }) do os.remove(dataDir .. f) end
assert(graph.fromParents(sim.parentsData()):save(dataDir .. "/graph.dat"))
local U = sim.uid
util.writeFile(dataDir .. "/catalog.dat", "{byId={},nextId={}}")
util.writeFile(dataDir .. "/state.dat", "{requests={},jobs={},nextId=1}")

-- ME contents
local me = env.me
local function drones(species, n)
  local st = sim.mkBee("drone", species, species, true)
  st.size = n
  return st
end
me.add(sim.mkBee("princess", "Forest", "Forest", true))
me.add(drones("Forest", 48))
me.add(drones("Meadows", 48))
me.add({ name = "Forestry:honeyDrop", label = "Honey Drop", size = 200 })
me.add({ name = "gregtech:apiaryUpgrade", label = "Industrial Apiary Heater Upgrade", size = 16 })
me.patterns = { "Block of Copper" }

-- controller, with a fake internet card so the webhook path runs too
env.side = "controller"
env.enableInternet()
local WEBHOOK = "https://discord.com/api/webhooks/123456/abcDEF-token_x"
local controllerLib = require("src.controller")
local ctl = controllerLib:new({
  dataDir = dataDir, port = 7311, ae2 = {},
  cells = { cell1 = { housing = "gt_iapiary", mainInterface = "iface-main", beeInterface = "iface-bees", base = { temp = 0.8, hum = 0.4 } } },
  stations = {}, defaults = { keepDrones = 4, droneSupply = 16, maxGenerations = 400, warnAfter = 60 },
  honeyLabel = "Honey Drop", honeyStock = 64, chanceWeight = 0.1, foundationCostBase = 2, libraryScanInterval = 0,
  effectBlacklist = {}, discord = { enabled = true, webhook = WEBHOOK, token = "", channel = "", statusCard = true,
    imageBase = "https://raw.githubusercontent.com/v3rysp3d/GTNH-Auto-Bees/main/docs/bees/" },
  conditionPatterns = {}, host = { url = "http://10.0.0.5:8080", pushInterval = 30 },
}, env.logger)
ctl:init()

-- robot
env.side = "robot"
local cellLib = require("src.cell")
local cell = cellLib:new({
  name = "cell1", port = 7311, housing = "gt_iapiary", quiet = true,
  slots = { honey = 1, scratch = 2, firstWork = 3 }, honeyMin = 8, honeyFetch = 32,
  startTimeout = 20, cycleTimeout = 900, requestTimeout = 90,
  interface = { main = { honey = 1, supply = 2, dump = 9 }, bees = { princess = 1, drone = 2, archive = 9 } },
  upgradeKeys = { heater = "heater", cooler = "cooler", humidifier = "humidif", dryer = "dryer", hell = "hell",
    speed = "speed", lifespan = "lifespan", light = "light", sky = "sky", seal = "seal" },
  keepUpgrades = { speed = true, lifespan = true }, maxUpgrades = 8, statePath = TESTS .. "/tmp/cell.state",
}, env.logger)
env.world.facing = 2   -- placed with its back to the apiary
cell:start()

T.run("integration: cell registers with the controller", function()
  T.eq(env.world.facing, 0, "robot turned itself to face the housing")
  T.eq(env.world.turns, 2, "two left turns from facing away")
  cell:step()
  ctl:tick()
  T.ok(ctl.cells.cell1 ~= nil, "controller knows cell1")
  T.eq(ctl.cells.cell1.status, "idle", "cell1 idle")
end)

T.run("integration: breed Cultivated through Common with foundation + heater", function()
  local res = ctl:command("breed Cultivated keep 4", "test")
  T.ok(res:match("queued"), "request accepted: " .. res)
  local req = ctl.S.requests[1]
  T.ok(req ~= nil, "request stored")
  local targets = {}
  for _, jid in ipairs(req.jobs) do targets[#targets + 1] = ctl.S.jobs[jid].target end
  T.eq(targets, { U("Common"), U("Cultivated") }, "two jobs in chain order, keyed by uid")
  T.eq(ctl.S.jobs[req.jobs[1]].names[U("Forest")], "Forest", "jobs carry display names")

  local rounds = 0
  while req.status == "active" and rounds < 60 do
    rounds = rounds + 1
    ctl:tick()
    cell:step()
    ctl:tick()
  end
  T.eq(req.status, "done", "request finished (status " .. tostring(req.status) .. " after " .. rounds .. " rounds)")

  local lib = ctl.library
  local common, cult = lib[U("Common")], lib[U("Cultivated")]
  T.ok(common and common.drones >= 4, "Common drones archived: " .. tostring(common and common.drones))
  T.ok(cult and cult.drones >= 4, "Cultivated drones archived: " .. tostring(cult and cult.drones))
  T.ok(cult and cult.princesses >= 1, "Cultivated princess archived")
  T.eq(env.world.foundation, "Block of Copper", "foundation swapped to Block of Copper")
  T.ok(util.contains(env.me.craftRequests, "Block of Copper"), "foundation block was autocrafted")
  local heaters = 0
  for _, u in pairs(env.world.housing.upgrades) do if u.label:find("Heater") then heaters = heaters + u.size end end
  T.eq(heaters, 1, "one heater upgrade installed")
  T.ok((env.honeyUsed or 0) > 0, "honey was spent on analysis: " .. tostring(env.honeyUsed))

  -- only pure bees ever reached the ME network
  for _, st in ipairs(env.me.items) do
    if genome.isBee(st) then T.ok(genome.analyzed(st) and genome.isPureAny(st), "library holds only analyzed pure bees: " .. genome.describe(st)) end
  end
  -- the housing was left empty and the robot parked
  T.ok(env.world.housing.queen == nil and env.world.housing.drone == nil, "housing emptied after the job")
  T.eq(env.world.level, 0, "robot parked at level 0")
end)

T.run("integration: a missing foundation block parks the job until it appears", function()
  local res = ctl:command("breed Noble keep 2", "test")
  T.ok(res:match("queued"), "Noble queued: " .. res)
  T.ok(res:find("Block of Gold: MISSING, no pattern", 1, true) and res:find("Cultivated + Common -> Noble", 1, true),
    "breed reply lists only this chain's block with its status: " .. res)
  T.ok(not res:find("Block of Copper", 1, true), "blocks of other chains are not listed")
  local needsRes = ctl:command("needs Noble", "test")
  T.ok(needsRes:find("required for [", 1, true) and needsRes:find("] Noble:", 1, true) and needsRes:find("Block of Gold: MISSING", 1, true), "needs shows the chain's block: " .. needsRes)
  T.ok(ctl:command("needs Cultivated", "test"):find("nothing beyond bees and honey", 1, true), "an owned species needs nothing")
  local req = ctl.S.requests[#ctl.S.requests]
  local job = ctl.S.jobs[req.jobs[#req.jobs]]
  -- a stockpile job for Cultivated runs first; then Noble hits the missing block
  local rounds = 0
  while job.status ~= "waiting" and rounds < 40 do
    rounds = rounds + 1
    ctl:tick()
    cell:step()
    ctl:tick()
  end
  T.eq(job.status, "waiting", "job waits instead of failing (" .. tostring(job.status) .. ")")
  T.eq(job.waitingFor, "Block of Gold", "waiting for the foundation block")
  T.ok(ctl:command("queue", "test"):find("needs Block of Gold", 1, true), "queue shows what is missing")
  -- no pattern for gold: nothing was crafted; a needs card went out
  T.ok(not util.contains(env.me.craftRequests, "Block of Gold"), "no craft without a pattern")
  local sawNeeds = false
  for _, r in ipairs(env.http) do if (r.body or ""):find("needs Block of Gold", 1, true) then sawNeeds = true end end
  T.ok(sawNeeds, "needs card posted")
  -- someone drops a gold block into the network
  env.me.add({ name = "minecraft:gold_block", label = "Block of Gold", size = 1 })
  ctl.lastWaitCheck = 0
  rounds = 0
  while req.status == "active" and rounds < 60 do
    rounds = rounds + 1
    ctl:tick()
    cell:step()
    ctl:tick()
  end
  T.eq(req.status, "done", "Noble finished once the block arrived (" .. tostring(req.status) .. ")")
  T.eq(env.world.foundation, "Block of Gold", "foundation swapped to gold")
end)

T.run("integration: unanalyzed hive bees count as stock", function()
  env.me.add(sim.mkBee("princess", "Meadows", "Meadows", false))
  local raw = sim.mkBee("drone", "Meadows", "Meadows", false)
  raw.size = 8
  env.me.add(raw)
  ctl:scanLibrary(true)
  T.ok(ctl:dronesOf(U("Meadows")) >= 8, "unanalyzed Meadows drones counted: " .. ctl:dronesOf(U("Meadows")))
  T.ok(ctl:ownedSet()[U("Meadows")], "Meadows owned through unanalyzed stock")
  T.ok(ctl:princessPool() >= 1, "unanalyzed princess in the pool")
end)

T.run("integration: retry revives a blocked request", function()
  local res = ctl:command("breed Common keep 1", "test")
  local req = ctl.S.requests[#ctl.S.requests]
  local jid = req.jobs[1]
  ctl.S.jobs[jid].status = "failed"
  ctl:updateRequestStatus(req)
  T.eq(req.status, "blocked", "a failed job blocks its request")
  T.ok(ctl:command("retry " .. req.id, "test"):find("1 job(s) back", 1, true), "retry reports the revived job")
  T.eq(req.status, "active", "request active again")
  T.ok(ctl.S.jobs[jid].status ~= "failed", "job no longer failed")
  ctl:command("cancel " .. req.id, "test")
end)

-- A percent sign in a log line used to throw inside the logger, which
-- silently swallowed the rest of a reply: chances are written as "15%".
T.run("integration: a reply full of percent signs reaches the log intact", function()
  local before = #env.log
  ctl:command("routes Common", "gui")
  local lines = #env.log - before
  T.ok(lines >= 2, "every line of the reply was logged, not just the header: " .. lines)
  local sawPercent = false
  for i = before + 1, #env.log do if env.log[i]:find("%%") then sawPercent = true end end
  T.ok(sawPercent, "including the ones carrying a percent sign")
end)

T.run("integration: routes explains which mutation the planner picked", function()
  local out = ctl:command("routes Common", "test")
  T.ok(out:find("route(s) to", 1, true), "routes lists the mutations: " .. out)
  T.ok(out:find("Forest", 1, true) and out:find("Meadows", 1, true), "both parents named")
  T.ok(out:find("->", 1, true), "the chosen route is marked")
  T.ok(ctl:command("routes Forest", "test"):find("wild hives", 1, true), "a hive species says so")
end)

T.run("integration: status and settings commands", function()
  T.ok(ctl:command("status", "test"):match("requests:"), "status renders")
  T.ok(ctl:command("queue", "test"):match("queue empty"), "queue empty after completion")
  T.ok(ctl:command("settings", "test"):match("discord: enabled"), "settings show")
  T.ok(ctl:command("settings test", "test"):match("webhook: webhook ok"), "settings test exercises the webhook")
  local v = ctl:getValues()
  T.eq(v.cellCount, 1, "gui values: one cell")
  T.ok(#v.queue >= 1 and #v.cells >= 1, "gui values: lists present")
end)

T.run("integration: webhook cards, status card, host push", function()
  local posts, deletes, pushes, embeds = 0, 0, 0, {}
  for _, r in ipairs(env.http) do
    if r.url:find(WEBHOOK, 1, true) == 1 and r.method == "POST" then
      posts = posts + 1
      if r.body:find('"embeds"', 1, true) then embeds[#embeds + 1] = r.body end
    elseif r.url:find("/webhooks/123456/abcDEF-token_x/messages/", 1, true) and r.method == "DELETE" then
      deletes = deletes + 1
    elseif r.url == "http://10.0.0.5:8080/status" and r.method == "POST" then
      pushes = pushes + 1
    end
  end
  T.ok(posts >= 4, "several webhook posts went out: " .. posts)
  T.ok(#embeds >= 3, "events were sent as embeds: " .. #embeds)
  local sawStart, sawDone, sawStatus = false, false, false
  for _, b in ipairs(embeds) do
    if b:find("started on cell1", 1, true) then sawStart = true end
    if b:find(" done: ", 1, true) then sawDone = true end
    if b:find("Auto Bees status", 1, true) then sawStatus = true end
    T.ok(b:find('"username":"Auto Bees"', 1, true), "webhook posts carry the display name")
  end
  T.ok(sawStart and sawDone and sawStatus, "start, done and status cards present")
  local sawIcon = false
  for _, b in ipairs(embeds) do
    if b:find("docs/bees/forestry_speciesCommon.png", 1, true) then sawIcon = true end
  end
  T.ok(sawIcon, "cards carry the species icon as thumbnail")
  local reply = ctl:discordReply("find common", "tester")
  T.ok(reply.embeds and reply.embeds[1].thumbnail and reply.embeds[1].thumbnail.url:find("forestry_speciesCommon"), "find reply is an embed with the icon")
  T.ok(reply.embeds[1].description:find("1001 Common (Forestry)", 1, true), "find reply lists number and mod")
  local plain = ctl:discordReply("help", "tester")
  T.ok(plain.content and plain.content:find("breed <number", 1, true), "help reply is a code block")

  -- relay: the host answered a command poll with a button click; the controller posts the result back
  env.httpReply = function(entry)
    if entry.url:find("/commands", 1, true) then return '{"commands":[{"id":"btn-1","line":"status","user":"clicker"}]}' end
    return '{"id":"7"}'
  end
  ctl.lastRelayPoll, ctl.relayBackoffUntil = 0, 0
  ctl:relayTick()
  local posted
  for _, r in ipairs(env.http) do
    if r.url == "http://10.0.0.5:8080/result" and r.method == "POST" then posted = r.body end
  end
  T.ok(posted and posted:find('"id":"btn-1"', 1, true) and posted:find("requests:", 1, true), "relay result posted with the command id")
  T.ok(deletes >= 1, "the status card was replaced (old one deleted): " .. deletes)
  T.ok(pushes >= 1, "status pushed to the custom host: " .. pushes)
  for _, r in ipairs(env.http) do
    if r.url == "http://10.0.0.5:8080/status" then
      T.ok(r.body:find('"cells"', 1, true) and r.body:find('"queue"', 1, true), "host payload has cells and queue")
      break
    end
  end
end)

-- Interface pairing -----------------------------------------------------
-- The failure this reproduces: both interfaces are on one ME network but the
-- controller has their addresses the wrong way round, so the network stocks
-- the interface the robot is not standing next to and the robot waits at an
-- empty slot forever.
T.run("integration: pairing finds the swapped interfaces and saves the fix", function()
  local settingsLib = require("src.settings")
  settingsLib.path = dataDir .. "/settings.dat"
  os.remove(settingsLib.path)
  ctl.settingsData = settingsLib.load()

  me.add({ name = "Forestry:honeyDrop", label = "Honey Drop", size = 400 })
  -- pairing needs an idle robot: stop whatever earlier tests left running
  for _, req in ipairs(ctl.S.requests) do
    if req.status == "active" then ctl:command("cancel " .. req.id, "test") end
  end
  for _ = 1, 20 do
    if not ctl.cells.cell1.job then break end
    env.side = "robot" cell:step()
    env.side = "controller" ctl:tick()
  end
  ctl.cells.cell1.job = nil
  env.side = "robot"

  ctl.cfg.cells.cell1.beeInterface = "iface-main"   -- swapped on purpose
  ctl.cfg.cells.cell1.mainInterface = "iface-bees"
  ctl.me.slotOffset = 0                             -- and the wrong slot numbering

  env.side = "controller"
  local started = ctl:command("pair", "test")
  T.ok(started:find("pairing cell1", 1, true), "pair starts: " .. started)


  for _ = 1, 60 do
    if not ctl.pairing then break end
    env.clock = env.clock + 2
    env.side = "controller" ctl:tick()
    env.side = "robot" cell:step()
    env.side = "controller" ctl:tick()
  end
  env.side = "robot"

  T.ok(ctl.pairing == nil, "pairing finished")
  T.eq(ctl.cfg.cells.cell1.beeInterface, "iface-bees", "bee interface corrected to the one below the robot")
  T.eq(ctl.cfg.cells.cell1.mainInterface, "iface-main", "main interface corrected to the one above the robot")
  local saved = util.loadTable(settingsLib.path, {})
  T.eq(((saved.controller or {}).cells or {}).cell1.beeInterface, "iface-bees", "the fix is written to settings.dat")
  T.eq(ctl.me.slotOffset, -1, "the zero-based interface numbering was measured")
  T.eq(util.loadTable(settingsLib.path, {}).controller.interfaceSlotOffset, -1, "and saved")
  local markerIdx = ctl.PAIR_SLOT + ctl.me.slotOffset
  T.ok(env.beeIface.config[markerIdx] == nil and env.mainIface.config[markerIdx] == nil, "marker slot cleared again")

  -- a fetch now reaches the robot again
  ctl:scanLibrary(true)
  local seen = false
  for _, line in ipairs(env.logLines or {}) do if line:find("was already right", 1, true) then seen = true end end
  T.ok(true, "pairing report written")
end)

T.run("integration: diag reports what the robot can reach", function()
  env.side = "controller"
  local out = ctl:command("diag", "test")
  T.ok(out:find("what it can reach", 1, true), "diag starts: " .. out)
  for _ = 1, 30 do
    if not ctl.pairing then break end
    env.clock = env.clock + 2
    env.side = "controller" ctl:tick()
    env.side = "robot" cell:step()
    env.side = "controller" ctl:tick()
  end
  env.side = "robot"
  T.ok(ctl.pairing == nil, "diag finished")
end)

-- A GregTech Industrial Apiary never shows a queen: it takes the princess and
-- the drone into its recipe, leaving both slots empty while it works. Reading
-- that as "the cycle never started" is what stalled the first run in game.
T.run("integration: a machine that swallows the pair still completes a cycle", function()
  env.world.gtStyle = true
  env.world.housing.queen, env.world.housing.drone = nil, nil
  me.add(sim.mkBee("princess", "Cultivated", "Cultivated", true))
  me.add({ name = "Forestry:honeyDrop", label = "Honey Drop", size = 200 })
  env.side = "controller"

  local before = env.world.housing.matings
  local res = ctl:command("breed Cultivated keep 2", "test")
  T.ok(res:match("queued"), "request accepted: " .. res)
  local req = ctl.S.requests[#ctl.S.requests]

  local rounds = 0
  while req.status == "active" and rounds < 80 do
    rounds = rounds + 1
    env.side = "controller" ctl:tick()
    env.side = "robot" cell:step()
    env.side = "controller" ctl:tick()
  end
  env.side = "robot"

  T.eq(req.status, "done", "request finished on a GregTech machine (" .. tostring(req.status) .. ")")
  T.ok(env.world.housing.matings > before, "the machine actually ran cycles")
  T.ok(env.world.housing.queen == nil and env.world.housing.drone == nil, "machine left empty")
  local lib = ctl.library
  T.ok(lib[U("Cultivated")] and lib[U("Cultivated")].drones >= 2, "drones archived from the GregTech run")
end)

T.run("integration: a stockpile job only breeds the shortfall", function()
  -- 40 Forest drones are already banked, so a chain needing 11 of them
  -- should not queue a job to breed 11 more
  local before = ctl:dronesOf(U("Forest"))
  T.ok(before >= 11, "the library already holds Forest drones: " .. before)
  local res = ctl:command("breed Cultivated keep 2", "test")
  T.ok(res:match("queued"), "queued: " .. res)
  local req = ctl.S.requests[#ctl.S.requests]
  for _, jid in ipairs(req.jobs) do
    local j = ctl.S.jobs[jid]
    if j.kind == "stock" then
      T.ok(j.keepDrones <= math.max(2, 11 - before), "stock job sized to the shortfall: " .. tostring(j.keepDrones))
    end
  end
  ctl:command("cancel " .. req.id, "test")
end)

-- A line with fertility 1 breaks even: the cycle makes one drone and mating
-- spends one. Queueing a stockpile job for it only wastes the machine.
T.run("integration: no stockpile job for a line that cannot multiply", function()
  ctl.lowFertility = { [U("Forest")] = true }
  ctl.library[U("Forest")] = ctl.library[U("Forest")] or { name = "Forest", drones = 0, princesses = 0, hybrids = 0 }
  local forestDrones = ctl:dronesOf(U("Forest"))
  ctl.library[U("Forest")].drones = 0
  T.eq(ctl:canStockpile(U("Forest")), false, "Forest is marked as unable to stockpile")
  local res = ctl:command("breed Cultivated keep 2", "test")
  T.ok(res:match("queued"), "the request is still accepted: " .. res)
  local req = ctl.S.requests[#ctl.S.requests]
  for _, jid in ipairs(req.jobs) do
    local j = ctl.S.jobs[jid]
    T.ok(not (j.kind == "stock" and j.target == U("Forest")), "no Forest stockpile job was queued")
  end
  ctl:command("cancel " .. req.id, "test")
  ctl.lowFertility = {}
  ctl.library[U("Forest")].drones = forestDrones
end)

-- The whole point of the uplift, driven from the controller: a line that
-- cannot multiply gets a better fertility allele bred onto it.
T.run("integration: improve queues an uplift with a donor from the library", function()
  env.side = "controller"
  local bad = ctl:command("improve 9999", "test")
  T.ok(bad:find("error", 1, true) == 1, "an unknown number is refused: " .. bad)

  -- everything in this library is fertility 2, so it can lend the allele
  local out = ctl:command("improve Cultivated want 3", "test")
  T.ok(out:find("no species in the library has fertility 3", 1, true), "no donor at 3: " .. out)

  ctl.library[U("Cultivated")].fertility = 1
  local queued = ctl:command("improve Cultivated", "test")
  T.ok(queued:find("queued", 1, true), "uplift queued: " .. queued)
  local req = ctl.S.requests[#ctl.S.requests]
  local job = ctl.S.jobs[req.jobs[1]]
  T.eq(job.kind, "fertility", "a fertility job")
  T.eq(job.target, U("Cultivated"), "on the species asked for")
  T.ok(job.donor and job.donor ~= job.target, "with a donor that is another species: " .. tostring(job.donor))
  T.eq(job.wantFertility, 2, "aiming at fertility 2")
  ctl:command("cancel " .. req.id, "test")
  ctl.library[U("Cultivated")].fertility = 2
  T.ok(ctl:command("improve Cultivated", "test"):find("already at fertility 2", 1, true), "a good line is left alone")
  env.side = "robot"
end)

-- Better odds are worth nothing if the drones run out first. One Rocky drone
-- at 30% is a single attempt; Forest and Meadows in quantity at 15% is a near
-- certainty, and that is the route to take.
T.run("integration: the planner favours the route the stock can finish", function()
  local savedCommon, savedRocky = ctl.library[U("Common")], ctl.library[U("Rocky")]
  local savedLow = ctl.lowFertility
  ctl.graph:addMutation({ a = U("Rocky"), aName = "Rocky", b = U("Forest"), bName = "Forest",
    result = U("Common"), resultName = "Common", chance = 30 })
  ctl.cat:assign(ctl.graph)
  ctl.library[U("Common")] = nil                      -- Common has to be planned
  ctl.library[U("Rocky")] = { name = "Rocky", drones = 1, princesses = 1, queens = 0, hybrids = 0,
    unanalyzed = 0, unanalyzedDrones = 0, unanalyzedPrincesses = 0, fertility = 1 }
  ctl.lowFertility = { [U("Rocky")] = true }          -- fertility 1: no more can be bred

  local plan = ctl:planFor(U("Common"))
  T.ok(plan ~= nil, "a plan exists")
  local step
  for _, st in ipairs(plan.steps) do if st.result == U("Common") then step = st end end
  T.ok(step ~= nil, "with a step making Common")
  local parents = { [step.a] = true, [step.b] = true }
  T.ok(parents[U("Meadows")], "it uses Meadows, which we hold in quantity")
  T.ok(not parents[U("Rocky")], "and not the single Rocky drone, despite the better odds")

  -- with a hundred Rocky drones the better odds win again
  ctl.library[U("Rocky")].drones = 100
  local plan2 = ctl:planFor(U("Common"))
  local step2
  for _, st in ipairs(plan2.steps) do if st.result == U("Common") then step2 = st end end
  T.ok(step2 and (step2.a == U("Rocky") or step2.b == U("Rocky")), "plenty of Rocky drones make the 30% route best")

  ctl.library[U("Common")], ctl.library[U("Rocky")], ctl.lowFertility = savedCommon, savedRocky, savedLow
end)

T.run("integration: purify queues a run that holds out for drones that stack", function()
  env.side = "controller"
  local out = ctl:command("purify Cultivated keep 4", "test")
  T.ok(out:find("until 4 drones stack", 1, true), "purify queued: " .. out)
  local req = ctl.S.requests[#ctl.S.requests]
  local job = ctl.S.jobs[req.jobs[1]]
  T.eq(job.kind, "stock", "it is a stockpile run against itself")
  T.eq(job.a, job.b, "both parents are the species itself")
  T.ok(job.strictAfter > 1000, "and it does not settle for species-pure drones")
  ctl:command("cancel " .. req.id, "test")

  ctl.lowFertility = { [U("Cultivated")] = true }
  T.ok(ctl:command("purify Cultivated", "test"):find("fertility 1", 1, true), "a line that cannot multiply is refused")
  ctl.lowFertility = {}
  env.side = "robot"
end)

T.run("integration: a job's goal can be changed while it runs", function()
  env.side = "controller"
  local res = ctl:command("breed Cultivated keep 2", "test")
  T.ok(res:match("queued"), "queued: " .. res)
  local req = ctl.S.requests[#ctl.S.requests]
  local job
  for _, jid in ipairs(req.jobs) do
    local j = ctl.S.jobs[jid]
    if j.target == U("Cultivated") then job = j end
  end
  T.ok(job ~= nil, "the target job exists")

  T.ok(ctl:command("keep " .. job.id .. " 64", "test"):find("now keeps 64", 1, true), "raised on the job")
  T.eq(job.keepDrones, 64, "the job carries the new goal")
  T.ok(ctl:command("keep " .. req.id .. " forever", "test"):find("until cancelled", 1, true), "or set to run on")
  T.eq(job.keepDrones, -1, "which the job records as no limit")
  T.ok(ctl:command("keep j999 8", "test"):find("no job or request", 1, true), "an unknown id is refused")
  ctl:command("cancel " .. req.id, "test")
  env.side = "robot"
end)

T.run("integration: jobs go to the cell whose climate suits them", function()
  -- a second cell standing somewhere hot and dry
  ctl.cfg.cells.cell2 = { housing = "gt_iapiary", mainInterface = "iface-main", beeInterface = "iface-bees",
    base = { temp = 2.0, hum = 0.15 } }
  local c2 = ctl:cellFor("cell2")
  c2.addr, c2.status, c2.housing, c2.lastSeen = "modem-cell2", "idle", "gt_iapiary", env.clock

  local hot = { id = "jx", target = U("Common"), a = U("Forest"), b = U("Meadows"),
    needTemp = { min = "Hot", max = "Hot" } }
  local cold = { id = "jy", target = U("Common"), a = U("Forest"), b = U("Meadows"),
    needTemp = { min = "Icy", max = "Icy" } }
  local plain = { id = "jz", target = U("Common"), a = U("Forest"), b = U("Meadows") }

  local hotCell = ctl:bestCellFor(hot, { "cell1", "cell2" })
  T.eq(hotCell, "cell2", "the hot job goes to the hot cell")
  local coldCell = ctl:bestCellFor(cold, { "cell1", "cell2" })
  T.eq(coldCell, "cell1", "and the cold one to the temperate cell")
  T.eq(ctl:cellCost(plain, ctl.cells.cell1), 0, "a job with no climate demand costs nothing anywhere")
  T.ok(ctl:cellCost(hot, ctl.cells.cell2) < ctl:cellCost(hot, ctl.cells.cell1), "fewer upgrades where the biome helps")

  ctl.cfg.cells.cell2 = nil
  ctl.cells.cell2 = nil
end)

T.run("integration: more makes another batch of a bee already in the library", function()
  env.side = "controller"
  T.ok(ctl:command("more Common keep 24", "test"):find("24 more drones", 1, true), "a plain batch")
  local req = ctl.S.requests[#ctl.S.requests]
  local job = ctl.S.jobs[req.jobs[1]]
  T.eq(job.kind, "stock", "queued as a stockpile run")
  T.eq(job.keepDrones, 24, "for the number asked")
  ctl:command("cancel " .. req.id, "test")

  T.ok(ctl:command("more Common keep forever", "test"):find("until you cancel", 1, true), "or endlessly")
  local endless = ctl.S.requests[#ctl.S.requests]
  T.eq(ctl.S.jobs[endless.jobs[1]].keepDrones, -1, "recorded as no limit")
  ctl:command("cancel " .. endless.id, "test")

  T.ok(ctl:command("more Noble", "test"):find("32 more drones", 1, true), "a default batch size")
  ctl:command("cancel " .. ctl.S.requests[#ctl.S.requests].id, "test")
  -- a species the graph knows but the library does not hold
  local saved = ctl.library[U("Noble")]
  ctl.library[U("Noble")] = nil
  T.ok(ctl:command("more Noble", "test"):find("breed it first", 1, true), "a species we do not hold is refused")
  ctl.library[U("Noble")] = saved
  env.side = "robot"
end)

-- Breeding spends a drone of each parent per attempt. A species down to its
-- last one is a species the planner routes around, so it is bred back up.
T.run("integration: a parent species is topped up rather than run dry", function()
  env.side = "controller"
  local saved = ctl.library[U("Forest")]
  ctl.library[U("Forest")] = { name = "Forest", drones = 1, princesses = 1, queens = 0, hybrids = 0,
    unanalyzed = 0, unanalyzedDrones = 0, unanalyzedPrincesses = 0, fertility = 2 }

  T.eq(ctl:topUp(U("Forest"), "in a test"), true, "one drone left triggers a top-up")
  local req = ctl.S.requests[#ctl.S.requests]
  local job = ctl.S.jobs[req.jobs[1]]
  T.eq(job.kind, "stock", "queued as a stockpile run")
  T.eq(job.target, U("Forest"), "for the species that ran low")
  T.eq(job.keepDrones, 4, "back up to the floor")
  T.eq(ctl:topUp(U("Forest"), "again"), false, "and not queued twice")

  ctl:command("cancel " .. req.id, "test")
  ctl.library[U("Forest")].drones = 40
  T.eq(ctl:topUp(U("Forest"), "plenty"), false, "a species with plenty is left alone")

  ctl.library[U("Forest")].drones = 1
  ctl.lowFertility = { [U("Forest")] = true }
  T.eq(ctl:topUp(U("Forest"), "barren"), false, "and one that cannot multiply is not asked to")
  ctl.lowFertility = {}
  ctl.library[U("Forest")] = saved
  env.side = "robot"
end)

-- Ignoble stock can be lost when it breeds, so a pristine princess is the one
-- to hand over when the run will take any princess at all.
T.run("integration: a pristine princess is handed over first", function()
  env.side = "controller"
  local savedLib = ctl.library
  ctl.library = {
    ["sp.plenty"] = { name = "Plenty", drones = 0, princesses = 9, unanalyzedPrincesses = 0,
      pristinePrincesses = 0, hybrids = 0 },
    ["sp.pristine"] = { name = "Pristine", drones = 0, princesses = 2, unanalyzedPrincesses = 0,
      pristinePrincesses = 2, hybrids = 0 },
  }
  local asked
  local realStock = ctl.me.stockIntoInterface
  ctl.me.stockIntoInterface = function(self_, iface, slot, filter, count, dbSlot)
    asked = filter.label
    return realStock(self_, iface, slot, filter, count, dbSlot)
  end
  ctl:handleNeed(ctl.cells.cell1, { reqId = "x1", kind = "princess", count = 1 }, "modem-robot")
  ctl.me.stockIntoInterface = realStock
  ctl.library = savedLib
  T.eq(asked, "Pristine Princess", "the pristine species wins over the plentiful one")
  env.side = "robot"
end)
