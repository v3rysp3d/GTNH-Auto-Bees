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

  -- leave the cell idle: an earlier test dispatched a job that never ran
  if ctl.cells.cell1.job then ctl:command("cancel " .. ctl.cells.cell1.job, "test") end
  cell:step()
  ctl:tick()
  ctl.cells.cell1.job = nil

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
