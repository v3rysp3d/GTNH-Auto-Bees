-- Survey: read the mutation graph out of the game, number the species,
-- check every condition string, write the data files the controller needs.
--
-- Needs an Adapter touching a Forestry bee housing (a Bee House is fine).
-- Optionally an ME network component for stock / pattern status.
local component = require("component")

local util = require("src.util")
local graph = require("src.graph")
local catalog = require("src.catalog")
local conditions = require("src.conditions")
local needs = require("src.needs")
local ae2 = require("src.ae2")
local housing = require("src.housing")

local survey = {}

local function toArray(t)
  local out = {}
  for _, v in pairs(t or {}) do out[#out + 1] = v end
  return out
end

---Run the survey.
---@param dataDir string      where graph.dat / catalog.dat / *.txt are written
---@param say fun(line: string)  output sink
---@param opts? table         { verbose = bool, temp = number, hum = number }
---@return boolean ok
---@return table|string       stats or error message
function survey.run(dataDir, say, opts)
  opts = opts or {}
  say = say or print
  util.mkdirs(dataDir)

  local housingAddr = component.list("bee_housing")()
  if not housingAddr then
    say("No 'bee_housing' component. Put an Adapter next to a Forestry Bee House and connect it.")
    say("(The GT Industrial Apiary does not expose it.)")
    return false, "no bee_housing component"
  end
  local bh = component.proxy(housingAddr)

  local okData, data = pcall(bh.getBeeBreedingData)
  if not okData or type(data) ~= "table" then return false, "getBeeBreedingData failed: " .. tostring(data) end
  local okSpecies, speciesList = pcall(bh.listAllSpecies)
  if not okSpecies or type(speciesList) ~= "table" then speciesList = {} end

  local g = graph.fromBreedingData(toArray(data), toArray(speciesList))
  local stats = g:stats()
  say(string.format("mutations %d, species %d, hive-only species %d", stats.mutations, stats.species, stats.baseSpecies))
  util.saveTable(dataDir .. "/graph.dat", g:toTable())

  local cat = catalog.new(dataDir .. "/catalog.dat")
  cat:load()
  local fresh = cat:assign(g:speciesList())
  cat:save()
  util.writeFile(dataDir .. "/catalog.txt", table.concat(cat:lines(), "\n") .. "\n")
  say(string.format("catalog: %d species numbered (%d new) -> %s/catalog.txt", util.count(cat.byId), fresh, dataDir))

  for _, kind in ipairs(util.sortedKeys(stats.kinds)) do say(string.format("  condition %-12s %d", kind, stats.kinds[kind])) end
  local unknownCount = util.count(stats.unknown)
  if unknownCount > 0 then
    say("UNPARSED condition strings (report these; add patterns in config.lua):")
    for _, raw in ipairs(util.sortedKeys(stats.unknown)) do say(string.format("  %s  (x%d)", raw, stats.unknown[raw])) end
  end
  if opts.verbose then
    local shown = {}
    for _, m in ipairs(g.mutations) do
      for _, c in ipairs(m.conds) do
        if not shown[c.kind] then
          shown[c.kind] = true
          say(string.format("  example %-10s %s  <=  %s", c.kind, conditions.describe(c), tostring(c.raw)))
        end
      end
    end
  end

  local ctx = { base = { temp = tonumber(opts.temp) or 0.8, hum = tonumber(opts.hum) or 0.4 } }
  local me = ae2.findNetwork(component)
  if me then
    local net = ae2.new(me)
    ctx.haveCount = function(label) return net:countLabel(label) end
    ctx.craftable = function(label) return net:hasPattern(label) end
    local lib = net:library()
    local pure = 0
    for _, b in pairs(lib) do if b.drones > 0 or b.princesses > 0 then pure = pure + 1 end end
    say(string.format("ME network found: %d species with pure stock", pure))
  else
    say("no ME network component found (optional)")
  end
  local rep = needs.global(g, ctx)
  util.writeFile(dataDir .. "/needs_global.txt", table.concat(needs.lines(rep, opts.verbose), "\n") .. "\n")
  say(string.format("global needs -> %s/needs_global.txt (%d foundation blocks, %d stations)",
    dataDir, util.count(rep.foundation), util.count(rep.stations)))
  local actions = needs.actionLines(rep)
  if #actions > 0 then
    say(string.format("%d things to provide eventually, first few:", #actions))
    for i = 1, math.min(#actions, 10) do say("  " .. actions[i]) end
  end

  local function has(name) return component.list(name)() ~= nil end
  say(string.format("components: beekeeper=%s inventory_controller=%s modem=%s database=%s internet=%s",
    tostring(has("beekeeper")), tostring(has("inventory_controller")), tostring(has("modem")), tostring(has("database")), tostring(has("internet"))))
  say("housing drivers: " .. table.concat(housing.kinds(), ", "))

  return true, { stats = stats, species = util.count(cat.byId), unknown = unknownCount, foundation = util.count(rep.foundation) }
end

return survey
