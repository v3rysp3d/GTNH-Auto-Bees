-- survey : first thing to run. Reads the mutation graph out of the game,
-- assigns catalog numbers, checks every condition string, and writes the
-- data files the controller needs.
--
-- Run on any computer that has:
--   * an Adapter touching a Forestry bee housing (Bee House is fine)
--   * optionally an Adapter touching an ME Interface / Controller (needs list)
--
-- usage: survey [--out=/home/beebreeder] [--verbose]
local component = require("component")
local shell = require("shell")
local util = require("bb.util")
local graph = require("bb.graph")
local catalog = require("bb.catalog")
local conditions = require("bb.conditions")
local needs = require("bb.needs")
local ae2 = require("bb.ae2")
local housing = require("bb.housing")

local args, opts = shell.parse(...)
local dataDir = opts.out or "/home/beebreeder"
local verbose = opts.verbose or opts.v

util.mkdirs(dataDir)

local function say(fmt, ...) print(string.format(fmt, ...)) end

say("BeeBreeder survey")
say("=================")

------------------------------------------------------------------------
-- 1. bee housing component
------------------------------------------------------------------------
local housingAddr = component.list("bee_housing")()
if not housingAddr then
  say("No 'bee_housing' component found.")
  say("Place an Adapter next to a Forestry Bee House / Apiary / Alveary block and connect it.")
  say("(The GT Industrial Apiary does NOT expose this component; use a cheap Bee House.)")
  return
end
local bh = component.proxy(housingAddr)
say("bee_housing at %s", housingAddr:sub(1, 8))

local okData, data = pcall(bh.getBeeBreedingData)
if not okData or type(data) ~= "table" then
  say("getBeeBreedingData failed: %s", tostring(data))
  return
end
local okSpecies, speciesList = pcall(bh.listAllSpecies)
if not okSpecies or type(speciesList) ~= "table" then speciesList = {} end

-- The component returns Java sets; make sure we have proper arrays.
local function toArray(t)
  local out = {}
  for _, v in pairs(t) do out[#out + 1] = v end
  return out
end
data = toArray(data)
speciesList = toArray(speciesList)

------------------------------------------------------------------------
-- 2. graph + catalog
------------------------------------------------------------------------
local g = graph.fromBreedingData(data, speciesList)
local stats = g:stats()
say("mutations: %d   species: %d   hive-only species: %d", stats.mutations, stats.species, stats.baseSpecies)

util.saveTable(dataDir .. "/graph.dat", g:toTable())

local cat = catalog.new(dataDir .. "/catalog.dat")
cat:load()
local fresh = cat:assign(g:speciesList())
cat:save()
util.writeFile(dataDir .. "/catalog.txt", table.concat(cat:lines(), "\n") .. "\n")
say("catalog: %d species numbered (%d new) -> %s/catalog.txt", util.count(cat.byId), fresh, dataDir)

------------------------------------------------------------------------
-- 3. condition strings
------------------------------------------------------------------------
say("")
say("Condition kinds:")
for _, kind in ipairs(util.sortedKeys(stats.kinds)) do say("  %-12s %d", kind, stats.kinds[kind]) end
if util.count(stats.unknown) > 0 then
  say("")
  say("UNPARSED condition strings (please report these, add patterns in /etc/beebreeder.cfg):")
  for _, raw in ipairs(util.sortedKeys(stats.unknown)) do say("  %s   (x%d)", raw, stats.unknown[raw]) end
end

-- Show one example per kind so the user can eyeball the parser.
if verbose then
  say("")
  say("Examples:")
  local shown = {}
  for _, m in ipairs(g.mutations) do
    for _, c in ipairs(m.conds) do
      if not shown[c.kind] then
        shown[c.kind] = true
        say("  %-12s %s  <=  %s", c.kind, conditions.describe(c), tostring(c.raw))
      end
    end
  end
end

------------------------------------------------------------------------
-- 4. AE2 (optional): global needs list
------------------------------------------------------------------------
say("")
local me = ae2.findNetwork(component)
local ctx = { base = { temp = tonumber(opts.temp) or 0.8, hum = tonumber(opts.hum) or 0.4 } }
if me then
  local net = ae2.new(me)
  say("ME network found (%s). Checking foundation blocks against stock and patterns...", me.type)
  ctx.haveCount = function(label) return net:countLabel(label) end
  ctx.craftable = function(label) return net:hasPattern(label) end
  local lib = net:library()
  local pureSpecies = 0
  for _, b in pairs(lib) do if b.drones > 0 or b.princesses > 0 then pureSpecies = pureSpecies + 1 end end
  say("bees in ME: %d species with pure stock", pureSpecies)
else
  say("No ME network component found (optional). Needs list will not show stock/pattern status.")
end
local rep = needs.global(g, ctx)
local lines = needs.lines(rep, verbose)
util.writeFile(dataDir .. "/needs_global.txt", table.concat(lines, "\n") .. "\n")
say("global needs list -> %s/needs_global.txt (%d foundation blocks, %d stations)",
  dataDir, util.count(rep.foundation), util.count(rep.stations))
local actions = needs.actionLines(rep)
if #actions > 0 then
  say("")
  say("Things you will eventually have to provide (%d):", #actions)
  for i = 1, math.min(#actions, 25) do say("  %s", actions[i]) end
  if #actions > 25 then say("  ... see needs_global.txt") end
end

------------------------------------------------------------------------
-- 5. other components worth knowing about
------------------------------------------------------------------------
say("")
say("Components:")
local function has(name) return component.list(name)() ~= nil end
say("  beekeeper upgrade : %s", has("beekeeper") and "yes (this is a robot)" or "no")
say("  inventory ctrl    : %s", has("inventory_controller") and "yes" or "no")
say("  modem             : %s", has("modem") and "yes" or "no")
say("  database          : %s", has("database") and "yes" or "no")
if has("internet") then
  local inet = component.internet
  local okH, httpOk = pcall(inet.isHttpEnabled)
  say("  internet          : yes, http %s", (okH and httpOk) and "enabled" or "DISABLED in server config")
else
  say("  internet          : no (Discord bridge unavailable)")
end
say("")
say("Housing drivers known: %s", table.concat(housing.kinds(), ", "))
say("Done. Next: edit /etc/beebreeder.cfg and run beectl, then beecell on the robot.")
