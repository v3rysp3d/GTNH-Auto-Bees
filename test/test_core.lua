-- Pure-logic tests: util, json, conditions, catalog, climate, genome, graph.
local util = require("src.util")
local json = require("src.json")
local conditions = require("src.conditions")
local catalog = require("src.catalog")
local climate = require("src.climate")
local genome = require("src.genome")
local graph = require("src.graph")

T.run("util.serialize roundtrip", function()
  local t = { a = 1, b = "x\ny", c = { 1, 2, { d = true } }, [5] = 2.5 }
  local back = util.unserialize(util.serialize(t))
  T.eq(back, t, "roundtrip")
  T.eq(util.parseCommand("breed 4137 keep 16 extra 4051=64 4060=32 princess"),
    { words = { "breed", "4137" }, opts = { keep = "16", extra = { "4051=64", "4060=32" }, princess = true } }, "parseCommand")
  T.eq(util.parseCommand("find naquadah").words, { "find", "naquadah" }, "parseCommand plain")
  T.eq(util.fmtSeconds(3725), "1h2m", "fmtSeconds")
end)

T.run("json", function()
  local s = json.encode({ content = "hi \"there\"\n", n = 3, list = { 1, 2, 3 }, empty = json.array({}) })
  T.eq(s, '{"content":"hi \\"there\\"\\n","empty":[],"list":[1,2,3],"n":3}', "encode")
  local d = json.decode('{"id":"12","a":[1,null,{"x":false}],"s":"\\u00e9\\ud83d\\ude00","f":-1.5e2}')
  T.eq(d.id, "12", "decode string")
  T.eq(#d.a, 3, "decode array with null keeps length")
  T.eq(d.a[3].x, false, "decode nested")
  T.eq(d.s, "\195\169\240\159\152\128", "decode unicode")
  T.eq(d.f, -150, "decode number")
end)

T.run("discord helpers", function()
  local discord = require("src.discord")
  local id, token = discord.webhookParts("https://discord.com/api/webhooks/1546395125088002118/50V1vaKIVNob-CTNF_7O3j")
  T.eq({ id, token }, { "1546395125088002118", "50V1vaKIVNob-CTNF_7O3j" }, "webhook url parsed")
  T.eq({ discord.webhookParts("https://example.com/x") }, {}, "non-webhook url gives nothing")
  local e = discord.embed("done", "j1 done", nil, { { "Generations", 12 }, { "Princess", "yes" } })
  T.eq(e.color, discord.colors.done, "embed colour by kind")
  T.eq(#e.fields, 2, "embed fields")
  local encoded = json.encode({ embeds = json.array({ e }) })
  T.ok(encoded:find('"embeds":[{', 1, true) and encoded:find('"inline":true', 1, true), "embed encodes as a JSON array")
  T.eq(#discord.chunk(string.rep("line\n", 1000)), 3, "chunking splits long text")
end)

T.run("conditions", function()
  T.eq(conditions.parse("Requires Block of Copper as a foundation."), { kind = "foundation", block = "Block of Copper" }, "foundation (raw dropped to save memory)")
  conditions.keepRaw = true
  T.eq(conditions.parse("Requires Block of Copper as a foundation.").raw, "Requires Block of Copper as a foundation.", "raw kept on request")
  conditions.keepRaw = false
  T.eq(conditions.parse("Occurs within a Jungle biome.").types, { "Jungle" }, "biome single")
  T.eq(conditions.parse("Occurs within biomes like: Forest, Plains").types, { "Forest", "Plains" }, "biome list")
  T.eq(conditions.parse("Requires Hot temperature.").min, "Hot", "temp single")
  local r = conditions.parse("Requires temperature between Warm and Hot.")
  T.eq({ r.min, r.max }, { "Warm", "Hot" }, "temp range")
  T.eq(conditions.parse("Requires Damp humidity.").kind, "humidity", "humidity")
  T.eq(conditions.parse("During the night.").day, false, "night")
  T.eq(conditions.parse("Needs a running GT Machine below to breed").kind, "gtmachine", "gt machine")
  local dim = conditions.parse("mutation.condition.dim Moon")
  T.eq({ dim.kind, dim.name }, { "dimension", "Moon" }, "dimension unlocalized")
  local dim2 = conditions.parse("Occurs only in dimension: The End")
  T.eq({ dim2.kind, dim2.name }, { "dimension", "The End" }, "dimension localized guess")
  local bid = conditions.parse("mutation.condition.biomeid Magical Forest")
  T.eq({ bid.kind, bid.name }, { "biomeId", "Magical Forest" }, "biome id")
  T.eq(conditions.parse("Something odd").kind, "unknown", "unknown")
  T.eq(conditions.describeAll(conditions.parseAll({ "Requires Hot temperature.", "Requires Block of Gold as a foundation." })),
    "temp:Hot; found:Block of Gold", "describeAll")
end)

T.run("catalog", function()
  local c = catalog.new(nil)
  local n = c:assign({
    { name = "Forest", uid = "forestry.speciesForest" },
    { name = "Common", uid = "forestry.speciesCommon" },
    { name = "Naquadah", uid = "gregtech.bee.speciesNaquadah" },
    { name = "Zzz Unknown" }, -- no uid and no hint: base range
  })
  T.eq(n, 4, "assigned")
  local function idOf(name) local e = c:uniqueByName(name) return e and e.id end
  T.eq(idOf("Common"), 1001, "forestry first alphabetically")
  T.eq(idOf("Forest"), 1002, "forestry second")
  T.eq(idOf("Naquadah"), 4001, "gregtech range")
  T.eq(idOf("Zzz Unknown"), 9001, "unknown range")
  c:assign({ { name = "Forest", uid = "forestry.speciesForest" }, { name = "Meadows", uid = "forestry.speciesMeadows" } })
  T.eq(idOf("Forest"), 1002, "stable id")
  T.eq(idOf("Meadows"), 1003, "appended")
  -- hive-only species come without a uid from name-only data; the generated table fills it in
  c:assign({ { name = "Tropical" } })
  T.eq(c:uniqueByName("Tropical").uid, "forestry.speciesTropical", "uid hint applied")
  T.ok(idOf("Tropical") >= 1000 and idOf("Tropical") < 2000, "hinted species lands in the Forestry range")
  T.eq(catalog.iconFile("forestry.speciesForest"), "forestry_speciesForest.png", "icon file from uid")
  T.eq(catalog.iconFile(nil), nil, "no icon without uid")
  T.eq(c:resolve("4001").name, "Naquadah", "resolve number")
  T.eq(c:resolve("naqua").name, "Naquadah", "resolve substring")
  T.eq(c:resolve("forestry.speciesForest").id, 1002, "resolve uid")
  local e, err = c:resolve("o")
  T.ok(e == nil and err:match("ambiguous"), "ambiguous")
  -- the same display name in two mods
  c:assign({ { name = "Diamond", uid = "gregtech.bee.speciesDiamond" }, { name = "Diamond", uid = "extrabees.species.diamond" } })
  T.eq(#c:byNameLookup("Diamond"), 2, "two Diamonds")
  T.ok(c:label("gregtech.bee.speciesDiamond"):match("Diamond %(GregTech%)"), "shared name labelled with mod: " .. c:label("gregtech.bee.speciesDiamond"))
  T.ok(c:label("extrabees.species.diamond"):match("Diamond %(Extra Bees%)"), "other mod labelled too")
  T.ok(not c:label("forestry.speciesForest"):match("%("), "unique names stay plain")
  local d, derr = c:resolve("Diamond")
  T.ok(d == nil and derr:match("use the number"), "shared name must be picked by number")
  T.eq(c:resolve(tostring(c:byUidLookup("extrabees.species.diamond").id)).uid, "extrabees.species.diamond", "number picks the right one")
end)

T.run("climate", function()
  T.eq(climate.classifyTemp(0.8), "Normal", "plains normal")
  T.eq(climate.parseTolerance("BOTH_2"), { up = 2, down = 2 }, "tolerance")
  local sol = climate.solve({ baseTemp = 0.8, baseHum = 0.4, needTemp = { min = "Hot", max = "Hot" },
    queenTemp = "Normal", queenTol = { up = 2, down = 0 } })
  T.eq({ sol.temperature, sol.heater, sol.cooler }, { "Hot", 1, 0 }, "one heater to Hot")
  local sol2 = climate.solve({ baseTemp = 0.8, baseHum = 0.4, needTemp = { min = "Icy", max = "Icy" } })
  T.eq({ sol2.temperature, sol2.cooler }, { "Icy", 4 }, "four coolers to Icy")
  local sol3, why = climate.solve({ baseTemp = 0.8, baseHum = 0.4, needTemp = { min = "Hot", max = "Hot" },
    queenTemp = "Normal", queenTol = { up = 0, down = 0 } })
  T.ok(sol3 == nil and why ~= nil, "impossible with intolerant queen")
  local sol4 = climate.solve({ baseTemp = 0.8, baseHum = 0.4, needHum = { min = "Damp", max = "Damp" } })
  T.eq(sol4.humidifier, 2, "two humidifiers to Damp")
  local sol5 = climate.solve({ baseTemp = 0.8, baseHum = 0.4, needTemp = { min = "Hellish", max = "Hellish" } })
  T.eq(sol5.hell, true, "hell upgrade")

  -- what a bee will put up with, which is how a stuck queen is diagnosed
  T.eq(climate.accepts("temperature", "Normal", "BOTH_1", "Warm"), true, "one step up is tolerated")
  T.eq(climate.accepts("temperature", "Normal", "NONE", "Warm"), false, "without tolerance it is not")
  T.eq(climate.accepts("humidity", "Arid", "NONE", "Arid"), true, "her own climate always works")
  T.eq(climate.accepts("temperature", nil, "NONE", "Warm"), true, "an unknown preference is not held against her")
end)

T.run("util.parseKeep", function()
  T.eq(util.parseKeep("64"), 64, "a number")
  T.eq(util.parseKeep("forever"), -1, "forever means no limit")
  T.eq(util.parseKeep("Infinite"), -1, "and so do its synonyms, whatever the case")
  T.eq(util.parseKeep("unlimited"), -1, "unlimited too")
  T.eq(util.parseKeep("banana"), nil, "anything else is unreadable")
  T.eq(util.parseKeep(nil), nil, "as is nothing at all")
end)

T.run("genome", function()
  local drone = { name = "Forestry:beeDroneGE", label = "Common Drone", size = 2, individual = {
    type = "bee", isAnalyzed = true, isNatural = true,
    active = { species = { name = "Common", uid = "forestry.speciesCommon", temperature = "Normal", humidity = "Normal" },
      fertility = 2, temperatureTolerance = "BOTH_1", flowerProvider = "flowersVanilla" },
    inactive = { species = { name = "Forest" }, fertility = 3 },
  } }
  T.eq(genome.kind(drone), "drone", "kind")
  T.eq(genome.active(drone), "forestry.speciesCommon", "active uid")
  T.eq(genome.inactive(drone), "Forest", "inactive falls back to the name without a uid")
  T.eq(genome.isPure(drone, "forestry.speciesCommon"), false, "hybrid not pure")
  T.eq(genome.hasSpecies(drone, "Forest"), true, "has inactive")
  T.eq(genome.hasSpecies(raw or drone, "x", "Common"), false, "unanalyzed compare by name only when given")
  T.eq(genome.displaySpecies(drone), "Common", "display")
  T.eq(genome.fertility(drone), 2, "fertility read from the active allele")
  T.eq(genome.isHomozygous(drone), false, "a hybrid does not breed true")

  -- traits worth having: faster production, more fertility, night, rain, caves
  local function bee(traits)
    local a = { species = { name = "Common", uid = "forestry.speciesCommon" } }
    for k, v in pairs(traits) do a[k] = v end
    return { name = "Forestry:beeDroneGE", label = "Common Drone", size = 1,
      individual = { type = "bee", isAnalyzed = true, active = a, inactive = a } }
  end
  local plain = bee({ speed = "Normal", fertility = 2, lifespan = "Normal" })
  local better = bee({ speed = "Fastest", fertility = 4, lifespan = "Shortest",
    nocturnal = true, tolerantFlyer = true, caveDwelling = true, effect = "forestry.effectBeatific" })
  local worse = bee({ speed = "Slowest", fertility = 1, lifespan = "Longest", effect = "forestry.effectRadioactive" })
  T.ok(genome.quality(better) > genome.quality(plain), "better traits score higher")
  local pristine = bee({ speed = "Normal", fertility = 2, lifespan = "Normal" })
  pristine.individual.isNatural = true
  plain.individual.isNatural = false
  -- a bee item with no genome table at all crashed the library scan
  T.eq(genome.isPristine({ name = "Forestry:beeDroneGE", label = "Common Drone", size = 1 }), false,
    "a bee item without its genome is simply not pristine")
  T.eq(genome.isPristine(nil), false, "and neither is nothing")
  T.eq(genome.isPristine(pristine), true, "natural stock is pristine")
  T.eq(genome.isPristine(plain), false, "and ignoble stock is not")
  T.ok(genome.quality(pristine) > genome.quality(plain), "pristine outranks ignoble, all else equal")
  T.ok(genome.quality(plain) > genome.quality(worse), "and a slow radioactive bee scores lowest")
  T.ok(genome.quality(bee({ speed = "Slowest" })) < genome.quality(bee({ speed = "Slow" })),
    "slowest is read as worse than slow, not as a match for it")
  local twin = { name = "Forestry:beeDroneGE", label = "Common Drone", size = 1, individual = {
    type = "bee", isAnalyzed = true,
    active = { species = { name = "Common", uid = "forestry.speciesCommon" }, fertility = 2, speed = "slowest" },
    inactive = { species = { name = "Common", uid = "forestry.speciesCommon" }, fertility = 2, speed = "slowest" },
  } }
  local other = { name = "Forestry:beeDroneGE", label = "Common Drone", size = 1, individual = {
    type = "bee", isAnalyzed = true,
    active = { species = { name = "Common", uid = "forestry.speciesCommon" }, fertility = 2, speed = "fast" },
    inactive = { species = { name = "Common", uid = "forestry.speciesCommon" }, fertility = 2, speed = "fast" },
  } }
  T.eq(genome.isHomozygous(twin), true, "matching alleles throughout breed true")
  T.eq(genome.isPure(other, "forestry.speciesCommon"), true, "both are species-pure")
  T.ok(genome.fingerprint(twin) ~= genome.fingerprint(other), "but differing speed means they do not stack")
  local raw = { name = "Forestry:beePrincessGE", label = "Meadows Princess", size = 1, individual = { type = "bee", isAnalyzed = false, displayName = "Meadows" } }
  T.eq(genome.kind(raw), "princess", "princess kind")
  T.eq(genome.displaySpecies(raw), "Meadows", "unanalyzed display")
  T.eq(genome.analyzed(raw), false, "unanalyzed")
  T.eq(genome.describe(drone), "Common/Forest drone x2", "describe")
end)

T.run("graph plan", function()
  local data = {
    { allele1 = "Forest", allele2 = "Meadows", result = "Common", chance = 15, specialConditions = {} },
    { allele1 = "Common", allele2 = "Forest", result = "Cultivated", chance = 12, specialConditions = {} },
    { allele1 = "Cultivated", allele2 = "Common", result = "Noble", chance = 10, specialConditions = {} },
    { allele1 = "Noble", allele2 = "Cultivated", result = "Majestic", chance = 8, specialConditions = {} },
    { allele1 = "Majestic", allele2 = "Noble", result = "Imperial", chance = 8, specialConditions = { "Requires Block of Gold as a foundation." } },
    { allele1 = "Imperial", allele2 = "Ender", result = "Spatial", chance = 4, specialConditions = { "mutation.condition.dim End" } },
    { allele1 = "Forest", allele2 = "Ender", result = "Shortcut", chance = 50, specialConditions = { "Requires Block of Unobtainium as a foundation." } },
    { allele1 = "Shortcut", allele2 = "Forest", result = "Imperial", chance = 50, specialConditions = {} },
  }
  local g = graph.fromBreedingData(data, {})
  T.eq(g:stats().mutations, 8, "mutations loaded")
  -- uid-keyed build from getBeeParents-shaped data
  local gp = graph.fromParents({
    { result = { name = "Common", uid = "forestry.speciesCommon" }, allele1 = { name = "Forest", uid = "forestry.speciesForest" },
      allele2 = { name = "Meadows", uid = "forestry.speciesMeadows" }, chance = 15, specialConditions = {} },
    { result = { name = "Diamond", uid = "gregtech.bee.speciesDiamond" }, allele1 = { name = "Common", uid = "forestry.speciesCommon" },
      allele2 = { name = "Diamond", uid = "extrabees.species.diamond" }, chance = 5, specialConditions = {} },
  })
  T.eq(gp:nameOf("forestry.speciesForest"), "Forest", "names kept per uid")
  -- streamed file round trip keeps species, mutations and conditions
  local path = TESTS .. "/tmp/graph_roundtrip.dat"
  T.ok(g:save(path), "graph saved")
  local back = graph.load(path)
  T.eq(back:stats().mutations, 8, "mutations reloaded")
  T.eq(back:nameOf("Imperial"), "Imperial", "species reloaded")
  local reloaded = back:plan("Imperial", { Forest = true, Meadows = true })
  T.eq(reloaded.steps[5].conds[1].block, "Block of Gold", "condition reloaded from text")
  T.eq(reloaded.steps[5].conds[1].raw, nil, "raw text dropped for known conditions")
  local dim = graph.load(path):mutationsFor("Imperial", "Ender")[1]
  T.eq(dim.conds[1].kind, "dimension", "dimension condition survives the round trip")
  T.eq(conditions.text({ kind = "temperature", min = "Hot", max = "Hot" }), "Requires Hot temperature.", "condition text rebuilt")
  -- streamed serializer matches the in-memory one
  local pieces = {}
  util.serializeTo(function(s) pieces[#pieces + 1] = s end, { a = { 1, 2 }, b = "x" })
  T.eq(table.concat(pieces), util.serialize({ a = { 1, 2 }, b = "x" }), "serializeTo")
  T.eq(gp:stats().duplicates["Diamond"] ~= nil, true, "duplicate names detected")
  local pp = gp:plan("gregtech.bee.speciesDiamond", { ["forestry.speciesForest"] = true, ["forestry.speciesMeadows"] = true, ["extrabees.species.diamond"] = true })
  T.eq(util.map(pp.steps, function(s) return s.result end), { "forestry.speciesCommon", "gregtech.bee.speciesDiamond" }, "plan over uids")
  local plan = g:plan("Imperial", { Forest = true, Meadows = true })
  T.ok(plan ~= nil, "plan found")
  T.eq(util.map(plan.steps, function(s) return s.result end), { "Common", "Cultivated", "Noble", "Majestic", "Imperial" }, "ordered chain")
  T.eq(plan.steps[5].conds[1].block, "Block of Gold", "foundation carried")

  -- with Ender owned and the shortcut foundation allowed, planner takes the cheap route
  local plan2 = g:plan("Imperial", { Forest = true, Meadows = true, Ender = true })
  T.eq(util.map(plan2.steps, function(s) return s.result end), { "Shortcut", "Imperial" }, "shortcut route")

  -- forbid unobtainium via condition cost -> long route again
  local plan3 = g:plan("Imperial", { Forest = true, Meadows = true, Ender = true }, {
    conditionCost = function(conds)
      for _, c in ipairs(conds) do if c.kind == "foundation" and c.block:match("Unobtainium") then return nil end end
      return 0
    end })
  T.eq(#plan3.steps, 5, "blocked shortcut")

  -- unreachable: dimension not available
  local p4, why, blockers = g:plan("Spatial", { Forest = true, Meadows = true }, {
    conditionCost = function(conds) for _, c in ipairs(conds) do if c.kind == "dimension" then return nil end end return 0 end })
  T.ok(p4 == nil and why:match("no breeding path"), "unreachable reported")
  T.eq(blockers.base, { "Ender" }, "missing base species listed")
  T.eq(#blockers.blocked, 1, "blocked mutation listed")

  -- already owned target -> empty plan
  T.eq(#g:plan("Common", { Common = true }).steps, 0, "owned target")
end)

-- The logger substitutes the message into its format with gsub, where a
-- percent sign in the REPLACEMENT is an escape character. "15% chance" threw
-- "invalid use of '%'", and because the reply was logged line by line the
-- rest of it vanished with the error.
T.run("logger: a message with a percent sign survives formatting", function()
  -- the library pulls in OpenComputers modules it does not need for this
  package.loaded["event"] = package.loaded["event"] or { listen = function() end, timer = function() end }
  package.loaded["filesystem"] = package.loaded["filesystem"] or
    { exists = function() return false end, lastModified = function() return 0 end }
  package.loaded["computer"] = package.loaded["computer"] or { uptime = function() return 0 end }
  local loggerLib = require("lib.logger-lib")
  local logger = loggerLib:new("Test", 0, {})
  logger.getTime = function() return "00:00:00" end   -- it reads a temp file for the clock
  local ok, res = pcall(function()
    return logger:formatMessage("[{LogLevel}] {Message}", "info", "Forest + Rocky  15%  (you have 3 drones)")
  end)
  T.ok(ok, "formatting does not throw: " .. tostring(res))
  T.ok(tostring(res):find("15%%") ~= nil, "and the percent sign is still there: " .. tostring(res))
end)
