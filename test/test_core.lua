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
  T.eq(conditions.parse("Requires Block of Copper as a foundation."), { kind = "foundation", block = "Block of Copper", raw = "Requires Block of Copper as a foundation." }, "foundation")
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
  T.eq(c:idOf("Common"), 1001, "forestry first alphabetically")
  T.eq(c:idOf("Forest"), 1002, "forestry second")
  T.eq(c:idOf("Naquadah"), 4001, "gregtech range")
  T.eq(c:idOf("Zzz Unknown"), 9001, "unknown range")
  c:assign({ { name = "Forest", uid = "forestry.speciesForest" }, { name = "Meadows", uid = "forestry.speciesMeadows" } })
  T.eq(c:idOf("Forest"), 1002, "stable id")
  T.eq(c:idOf("Meadows"), 1003, "appended")
  -- hive-only species come without a uid from the game; the generated table fills it in
  c:assign({ { name = "Tropical" } })
  T.eq(c:byNameLookup("Tropical").uid, "forestry.speciesTropical", "uid hint applied")
  T.ok(c:idOf("Tropical") >= 1000 and c:idOf("Tropical") < 2000, "hinted species lands in the Forestry range")
  T.eq(catalog.iconFile("Forest"), "forestry_speciesForest.png", "icon file from hint")
  T.eq(catalog.iconFile("Nope"), nil, "no icon for unknown species")
  T.eq(c:resolve("4001").name, "Naquadah", "resolve number")
  T.eq(c:resolve("naqua").name, "Naquadah", "resolve substring")
  local e, err = c:resolve("o")
  T.ok(e == nil and err:match("ambiguous"), "ambiguous")
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
end)

T.run("genome", function()
  local drone = { name = "Forestry:beeDroneGE", label = "Common Drone", size = 2, individual = {
    type = "bee", isAnalyzed = true, isNatural = true,
    active = { species = { name = "Common", uid = "forestry.speciesCommon", temperature = "Normal", humidity = "Normal" },
      fertility = 2, temperatureTolerance = "BOTH_1", flowerProvider = "flowersVanilla" },
    inactive = { species = { name = "Forest" }, fertility = 3 },
  } }
  T.eq(genome.kind(drone), "drone", "kind")
  T.eq(genome.isPure(drone, "Common"), false, "hybrid not pure")
  T.eq(genome.hasSpecies(drone, "Forest"), true, "has inactive")
  T.eq(genome.displaySpecies(drone), "Common", "display")
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
  local g = graph.fromBreedingData(data, { { name = "Common", uid = "forestry.speciesCommon" } })
  T.eq(g:stats().mutations, 8, "mutations loaded")
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
