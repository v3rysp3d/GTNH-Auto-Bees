-- bb.needs : "what do I need to have available" lists, per plan and global.
local util = require("bb.util")
local conditions = require("bb.conditions")
local climate = require("bb.climate")

local needs = {}

--- ctx = {
---   base = { temp = 0.8, hum = 0.4 },          -- cell biome values
---   haveCount = function(label) -> n end,       -- optional (AE2)
---   craftable = function(label) -> bool end,    -- optional (AE2)
---   station = function(kind, name) -> bool end, -- optional: is a station for this condition available
--- }
local function newReport()
  return { foundation = {}, upgrades = {}, stations = {}, other = {}, unknown = {}, steps = 0 }
end

local function addCond(rep, c, ctx, stepLabel)
  if c.kind == "foundation" then
    local e = rep.foundation[c.block]
    if not e then
      e = { label = c.block, uses = 0, steps = {} }
      if ctx.haveCount then e.have = ctx.haveCount(c.block) end
      if ctx.craftable then e.craftable = ctx.craftable(c.block) end
      rep.foundation[c.block] = e
    end
    e.uses = e.uses + 1
    if #e.steps < 5 then e.steps[#e.steps + 1] = stepLabel end
  elseif c.kind == "temperature" or c.kind == "humidity" then
    local sol
    if c.kind == "temperature" then
      sol = climate.solve({ baseTemp = ctx.base.temp, baseHum = ctx.base.hum, needTemp = { min = c.min, max = c.max } })
    else
      sol = climate.solve({ baseTemp = ctx.base.temp, baseHum = ctx.base.hum, needHum = { min = c.min, max = c.max } })
    end
    if sol then
      for k, n in pairs(climate.upgradeCounts(sol)) do
        rep.upgrades[k] = math.max(rep.upgrades[k] or 0, n)
      end
    else
      rep.other[#rep.other + 1] = stepLabel .. ": " .. conditions.describe(c) .. " (unsolvable)"
    end
  elseif c.kind == "dimension" or c.kind == "biomeId" or c.kind == "biome" or c.kind == "gtmachine" then
    local name = c.name or (c.types and table.concat(c.types, "/")) or c.kind
    local key = c.kind .. ":" .. name
    local e = rep.stations[key]
    if not e then
      e = { kind = c.kind, name = name, uses = 0, steps = {} }
      if ctx.station then e.available = ctx.station(c.kind, name) end
      rep.stations[key] = e
    end
    e.uses = e.uses + 1
    if #e.steps < 5 then e.steps[#e.steps + 1] = stepLabel end
  elseif c.kind == "daytime" or c.kind == "date" then
    rep.other[#rep.other + 1] = stepLabel .. ": " .. conditions.describe(c) .. " (scheduler waits)"
  else
    rep.unknown[#rep.unknown + 1] = stepLabel .. ": " .. tostring(c.raw)
  end
end

--- steps: plan.steps from graph:plan()
function needs.forSteps(steps, ctx)
  ctx = ctx or {}
  ctx.base = ctx.base or { temp = 0.8, hum = 0.4 }
  local rep = newReport()
  for _, s in ipairs(steps or {}) do
    rep.steps = rep.steps + 1
    local label = string.format("%s+%s->%s", s.a, s.b, s.result)
    for _, c in ipairs(s.conds or {}) do addCond(rep, c, ctx, label) end
  end
  return rep
end

--- Everything any mutation in the whole graph could ask for.
function needs.global(g, ctx)
  ctx = ctx or {}
  ctx.base = ctx.base or { temp = 0.8, hum = 0.4 }
  local rep = newReport()
  for _, m in ipairs(g.mutations) do
    rep.steps = rep.steps + 1
    local label = string.format("%s+%s->%s", m.a, m.b, m.result)
    for _, c in ipairs(m.conds or {}) do addCond(rep, c, ctx, label) end
  end
  return rep
end

local function sortedValues(t, key)
  local list = {}
  for _, v in pairs(t) do list[#list + 1] = v end
  table.sort(list, function(a, b) return tostring(a[key]) < tostring(b[key]) end)
  return list
end

--- Render a report as text lines. `verbose` adds the steps each item serves.
function needs.lines(rep, verbose)
  local out = {}
  local f = sortedValues(rep.foundation, "label")
  local missing, craftable, stocked = 0, 0, 0
  out[#out + 1] = string.format("Foundation blocks (%d distinct):", #f)
  for _, e in ipairs(f) do
    local status
    if e.have and e.have > 0 then status = "stocked"; stocked = stocked + 1
    elseif e.craftable then status = "craftable"; craftable = craftable + 1
    elseif e.have ~= nil or e.craftable ~= nil then status = "MISSING"; missing = missing + 1
    else status = "" end
    local line = string.format("  %-40s %-9s x%d", e.label, status, e.uses)
    if verbose and #e.steps > 0 then line = line .. "  [" .. table.concat(e.steps, ", ") .. "]" end
    out[#out + 1] = line
  end
  if stocked + craftable + missing > 0 then
    out[#out + 1] = string.format("  stocked %d, craftable %d, missing %d", stocked, craftable, missing)
  end
  local ups = util.sortedKeys(rep.upgrades)
  if #ups > 0 then
    out[#out + 1] = "Industrial Apiary climate upgrades (max at once):"
    for _, k in ipairs(ups) do out[#out + 1] = string.format("  %-12s x%d", k, rep.upgrades[k]) end
  end
  local st = sortedValues(rep.stations, "name")
  if #st > 0 then
    out[#out + 1] = "Stations:"
    for _, e in ipairs(st) do
      local status = ""
      if e.available == true then status = "available" elseif e.available == false then status = "MISSING" end
      local line = string.format("  %-9s %-28s %-9s x%d", e.kind, e.name, status, e.uses)
      if verbose and #e.steps > 0 then line = line .. "  [" .. table.concat(e.steps, ", ") .. "]" end
      out[#out + 1] = line
    end
  end
  if #rep.other > 0 then
    out[#out + 1] = "Timing / other:"
    for _, l in ipairs(rep.other) do out[#out + 1] = "  " .. l end
  end
  if #rep.unknown > 0 then
    out[#out + 1] = "Unparsed conditions (add patterns in config):"
    for _, l in ipairs(rep.unknown) do out[#out + 1] = "  " .. l end
  end
  return out
end

--- Only the items a human has to act on.
function needs.actionLines(rep)
  local out = {}
  for _, e in ipairs(sortedValues(rep.foundation, "label")) do
    if (e.have == nil or e.have == 0) and e.craftable == false then
      out[#out + 1] = "add autocraft pattern: " .. e.label
    end
  end
  for _, e in ipairs(sortedValues(rep.stations, "name")) do
    if e.available == false then out[#out + 1] = "build station: " .. e.kind .. " " .. e.name end
  end
  for _, l in ipairs(rep.unknown) do out[#out + 1] = "unknown condition: " .. l end
  return out
end

return needs
