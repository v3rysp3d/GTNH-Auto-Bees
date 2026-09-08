-- Settings: values collected by the first-boot guide or the `settings`
-- command. Stored as data in /home/settings.dat and merged over the
-- controller / cell sections of config.lua at start, so config.lua stays a
-- readable template and nothing in it is rewritten by the program.
local util = require("src.util")

local settings = {}
settings.path = "/home/settings.dat"

---@return table
function settings.load()
  local t = util.loadTable(settings.path, {})
  if type(t) ~= "table" then t = {} end
  t.controller = t.controller or {}
  t.cell = t.cell or {}
  return t
end

function settings.save(t)
  return util.saveTable(settings.path, t)
end

---Merge stored settings into the config sections (in place).
---@param config table  the table returned by config.lua
---@param s table       settings.load()
function settings.apply(config, s)
  config.controller = util.merge(config.controller or {}, s.controller or {})
  config.cell = util.merge(config.cell or {}, s.cell or {})
  return config
end

---True when the config still holds placeholder addresses or the guide never ran.
function settings.needsSetup(config, s, isRobot)
  if s.setupDone then return false end
  if isRobot then return true end
  for _, c in pairs((config.controller or {}).cells or {}) do
    if tostring(c.mainInterface or ""):match("^a+%-") or tostring(c.beeInterface or ""):match("^a+%-") then return true end
  end
  return util.count((config.controller or {}).cells or {}) == 0
end

---Set a dotted path, e.g. settings.set(s, "controller.discord.webhook", url)
function settings.set(s, path, value)
  local node = s
  local parts = util.split(path, "%.")
  for i = 1, #parts - 1 do
    node[parts[i]] = node[parts[i]] or {}
    node = node[parts[i]]
  end
  node[parts[#parts]] = value
  return s
end

---Lines describing the effective connection settings (secrets masked).
function settings.describe(cfg)
  local d = cfg.discord or {}
  local h = cfg.host or {}
  local function mask(v) v = tostring(v or "") if v == "" then return "-" end return v:sub(1, 6) .. "..." end
  local lines = {
    string.format("discord: %s  webhook=%s  bot token=%s  channel=%s  prefix=%s",
      d.enabled and "enabled" or "disabled", (d.webhook or "") ~= "" and "set" or "-", mask(d.token), (d.channel or "") ~= "" and d.channel or "-", d.prefix or "!"),
    string.format("host: %s  push every %ss", (h.url or "") ~= "" and h.url or "-", tostring(h.pushInterval or 0)),
    string.format("cells: %s", table.concat(util.sortedKeys(cfg.cells or {}), ", ")),
  }
  for _, name in ipairs(util.sortedKeys(cfg.cells or {})) do
    local c = cfg.cells[name]
    lines[#lines + 1] = string.format("  %s: main=%s bees=%s (main is above the robot, bees below; `pair` sets them)",
      name, tostring(c.mainInterface):sub(1, 8), tostring(c.beeInterface):sub(1, 8))
  end
  return lines
end

return settings
