-- bb.conditions : turn Forestry / GregTech mutation condition strings into
-- typed requirements the planner and stations can reason about.
--
-- Verified source strings (GTNH ForestryMC lang + GT5U GTBees.java):
--   "Requires %s as a foundation."
--   "Occurs within a %s biome."          "Occurs within biomes like: %s"
--   "Requires %s temperature."           "Requires temperature between %LOW and %HIGH."
--   "Requires %s humidity."              "Requires humidity between %LOW and %HIGH."
--   "During the day."                    "During the night."
--   "Occurs between %START and %END."
--   "Needs a running GT Machine below to breed"
--   GT dimension: <localized "mutation.condition.dim"> .. " " .. dimName
--   GT biome id:  <localized "mutation.condition.biomeid"> .. " " .. biomeName
local util = require("src.util")

local conditions = {}

conditions.temperatures = { "Icy", "Cold", "Normal", "Warm", "Hot", "Hellish" }
conditions.humidities = { "Arid", "Normal", "Damp" }

local function capitalize(s)
  s = util.trim(s)
  return (s:sub(1, 1):upper() .. s:sub(2):lower())
end

local function climateName(s, list)
  local c = capitalize(s)
  for _, name in ipairs(list) do if name == c then return name end end
  return c -- unknown spelling, keep as is so it shows up in the survey
end

--- Extra patterns can be registered from config:
--- conditions.addPattern("^Occurs only in dimension (.+)$", function(m) return {kind="dimension", name=m} end)
conditions.extraPatterns = {}
function conditions.addPattern(pattern, builder)
  conditions.extraPatterns[#conditions.extraPatterns + 1] = { pattern = pattern, builder = builder }
end

local function stripDot(s) return (s:gsub("%.$", "")) end

--- When false, parsed conditions keep the original text only for kinds the
--- parser did not understand, which saves memory on large graphs.
conditions.keepRaw = false

--- Parse one condition string. Always returns a table with .kind; .raw is
--- kept for unknown kinds, and for all kinds while conditions.keepRaw is true.
function conditions.parse(raw)
  local parsed = conditions.parseInner(raw)
  if not conditions.keepRaw and parsed.kind ~= "unknown" then parsed.raw = nil end
  return parsed
end

function conditions.parseInner(raw)
  local s = util.trim(raw or "")
  local c = { raw = raw }

  for _, extra in ipairs(conditions.extraPatterns) do
    local m1, m2 = s:match(extra.pattern)
    if m1 then
      local built = extra.builder(m1, m2)
      if built then built.raw = raw return built end
    end
  end

  local m = s:match("^Requires (.+) as a foundation%.?$")
  if m then c.kind = "foundation"; c.block = util.trim(m); return c end

  m = s:match("^Occurs within an? (.+) biome%.?$")
  if m then c.kind = "biome"; c.types = { util.trim(m) }; return c end

  m = s:match("^Occurs within biomes like: (.+)$")
  if m then
    c.kind = "biome"
    c.types = util.map(util.split(stripDot(m), ","), util.trim)
    return c
  end

  local lo, hi = s:match("^Requires temperature between (.+) and (.+)%.?$")
  if lo then
    c.kind = "temperature"
    c.min = climateName(lo, conditions.temperatures)
    c.max = climateName(stripDot(hi), conditions.temperatures)
    return c
  end
  m = s:match("^Requires (.+) temperature%.?$")
  if m then
    c.kind = "temperature"
    c.min = climateName(m, conditions.temperatures)
    c.max = c.min
    return c
  end

  lo, hi = s:match("^Requires humidity between (.+) and (.+)%.?$")
  if lo then
    c.kind = "humidity"
    c.min = climateName(lo, conditions.humidities)
    c.max = climateName(stripDot(hi), conditions.humidities)
    return c
  end
  m = s:match("^Requires (.+) humidity%.?$")
  if m then
    c.kind = "humidity"
    c.min = climateName(m, conditions.humidities)
    c.max = c.min
    return c
  end

  if s:match("^During the day%.?$") then c.kind = "daytime"; c.day = true; return c end
  if s:match("^During the night%.?$") then c.kind = "daytime"; c.day = false; return c end

  lo, hi = s:match("^Occurs between (.+) and (.+)%.?$")
  if lo then c.kind = "date"; c.start = util.trim(lo); c.stop = util.trim(stripDot(hi)); return c end

  if s:lower():match("running gt machine") then c.kind = "gtmachine"; return c end

  -- GregTech dimension / biome-id conditions. The prefix is a localized
  -- string we cannot know for sure, so match loosely on keywords and keep
  -- the trailing name.
  local lower = s:lower()
  if lower:match("mutation%.condition%.dim") or lower:match("dimension") then
    c.kind = "dimension"
    c.name = util.trim(s:match("[:%s]([^:]+)$") or s)
    if lower:match("mutation%.condition%.dim") then
      c.name = util.trim(s:gsub("^.-mutation%.condition%.dim%s*", ""))
    end
    return c
  end
  if lower:match("mutation%.condition%.biomeid") or lower:match("biome") then
    c.kind = "biomeId"
    c.name = util.trim(s:match("[:%s]([^:]+)$") or s)
    if lower:match("mutation%.condition%.biomeid") then
      c.name = util.trim(s:gsub("^.-mutation%.condition%.biomeid%s*", ""))
    end
    return c
  end

  c.kind = "unknown"
  return c
end

function conditions.parseAll(list)
  local out = {}
  for _, raw in ipairs(list or {}) do out[#out + 1] = conditions.parse(raw) end
  return out
end

--- Short human readable form, e.g. "found:Block of Copper".
function conditions.describe(c)
  if c.kind == "foundation" then return "found:" .. c.block end
  if c.kind == "biome" then return "biome:" .. table.concat(c.types, "/") end
  if c.kind == "biomeId" then return "biomeid:" .. c.name end
  if c.kind == "dimension" then return "dim:" .. c.name end
  if c.kind == "temperature" then
    if c.min == c.max then return "temp:" .. c.min end
    return "temp:" .. c.min .. "-" .. c.max
  end
  if c.kind == "humidity" then
    if c.min == c.max then return "hum:" .. c.min end
    return "hum:" .. c.min .. "-" .. c.max
  end
  if c.kind == "daytime" then return c.day and "day" or "night" end
  if c.kind == "date" then return "date:" .. c.start .. "-" .. c.stop end
  if c.kind == "gtmachine" then return "gtmachine" end
  return "?:" .. tostring(c.raw)
end

--- The original condition text (rebuilt from the parsed form when it was dropped).
function conditions.text(c)
  if c.raw then return c.raw end
  if c.kind == "foundation" then return "Requires " .. c.block .. " as a foundation." end
  if c.kind == "biome" then
    if #c.types == 1 then return "Occurs within a " .. c.types[1] .. " biome." end
    return "Occurs within biomes like: " .. table.concat(c.types, ", ")
  end
  if c.kind == "temperature" then
    if c.min == c.max then return "Requires " .. c.min .. " temperature." end
    return "Requires temperature between " .. c.min .. " and " .. c.max .. "."
  end
  if c.kind == "humidity" then
    if c.min == c.max then return "Requires " .. c.min .. " humidity." end
    return "Requires humidity between " .. c.min .. " and " .. c.max .. "."
  end
  if c.kind == "daytime" then return c.day and "During the day." or "During the night." end
  if c.kind == "date" then return "Occurs between " .. c.start .. " and " .. c.stop .. "." end
  if c.kind == "gtmachine" then return "Needs a running GT Machine below to breed" end
  if c.kind == "dimension" then return "mutation.condition.dim " .. tostring(c.name) end
  if c.kind == "biomeId" then return "mutation.condition.biomeid " .. tostring(c.name) end
  return ""
end

function conditions.describeAll(list)
  if not list or #list == 0 then return "-" end
  return table.concat(util.map(list, conditions.describe), "; ")
end

--- Pull the single value of a given kind out of a condition list.
function conditions.find(list, kind)
  for _, c in ipairs(list or {}) do if c.kind == kind then return c end end
  return nil
end

function conditions.findAll(list, kind)
  return util.filter(list or {}, function(c) return c.kind == kind end)
end

return conditions
