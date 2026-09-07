-- First-boot guide. Runs in the plain terminal before the GUI starts, walks
-- through what the computer can see, and writes /home/settings.dat.
-- Re-run any time with:  main setup
local component = require("component")
local term = require("term")

local util = require("src.util")
local settings = require("src.settings")
local connect = require("src.connect")
local survey = require("src.survey")

local setup = {}

local biomes = {
  { "Plains",  0.8,  0.4 }, { "Forest", 0.7, 0.8 }, { "Jungle", 0.95, 0.9 }, { "Swamp", 0.8, 0.9 },
  { "Desert",  2.0,  0.0 }, { "Taiga",  0.05, 0.8 }, { "Ocean", 0.5, 0.5 }, { "Extreme Hills", 0.2, 0.3 },
}

local function write(fmt, ...)
  term.write((select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)) .. "\n")
end

local function ask(prompt, default)
  term.write(prompt .. (default ~= nil and (" [" .. tostring(default) .. "]") or "") .. ": ")
  local line = io.read()
  if line == nil then return default end
  line = util.trim(line)
  if line == "" then return default end
  return line
end

local function askYesNo(prompt, default)
  local v = ask(prompt .. " (y/n)", default and "y" or "n")
  return tostring(v):lower():sub(1, 1) == "y"
end

local function askChoice(prompt, options, default)
  for i, o in ipairs(options) do write("  [%d] %s", i, o) end
  while true do
    local v = ask(prompt, default)
    local n = tonumber(v)
    if n and options[n] then return n end
    if v and v ~= "" and not n then return v end
  end
end

local function has(name) return component.list(name)() ~= nil end

local function componentReport()
  write("")
  write("Components on this network:")
  local function line(name, ok, note)
    write("  %-22s %s%s", name, ok and "found" or "MISSING", note and ("  " .. note) or "")
  end
  local meType
  for _, t in ipairs({ "me_interface", "me_controller", "me_exportbus", "me_importbus" }) do
    if has(t) then meType = t break end
  end
  line("ME network", meType ~= nil, meType and ("via " .. meType) or "adapter on an ME Interface/Controller")
  line("database upgrade", has("database"), "inside an Adapter next to each ME Interface")
  line("modem", has("modem"), "wireless card, or wired to the robots")
  local housingAddr, housingType = survey.findHousing(component)
  line("bee housing", housingAddr ~= nil, housingAddr and ("seen as " .. tostring(housingType)) or "adapter on a Bee House (mutation data)")
  local inet = has("internet")
  local httpOk = false
  if inet then
    local okH, v = pcall(component.internet.isHttpEnabled)
    httpOk = okH and v
  end
  line("internet card", inet, inet and (httpOk and "http enabled" or "http DISABLED in server config") or "needed for Discord and the host link")
  write("")
end

local function chooseInterfaces(cellName, existing)
  local list = {}
  for addr in component.list("me_interface") do list[#list + 1] = addr end
  table.sort(list)
  if #list == 0 then
    write("No ME Interface components reachable. Add Adapters (with Database upgrades) touching both interfaces of %s.", cellName)
    return existing.mainInterface, existing.beeInterface
  end
  write("ME Interfaces reachable:")
  for i, a in ipairs(list) do write("  [%d] %s", i, a) end
  local main = askChoice("Main interface (above the robot column: honey, blocks, upgrades)", list, 1)
  local bee = askChoice("Bee-library interface (below the robot column)", list, math.min(2, #list))
  local function pick(v) if type(v) == "number" then return list[v] end return v end
  return pick(main), pick(bee)
end

local function internetProxy()
  if has("internet") then return component.internet end
  return nil
end

local function testDiscord(_, s)
  for _, line in ipairs(connect.report(internetProxy(), s.controller.discord, nil)) do write("  %s", line) end
end

local function testHost(s)
  local _, why = connect.testHost(internetProxy(), s.controller.host and s.controller.host.url or "")
  write("  host: %s", why)
end

---Run the guide.
---@param config table   config.lua table (already merged with settings)
---@param isRobot boolean
function setup.run(config, isRobot)
  term.clear()
  write("GTNH Auto Bees - setup guide")
  write("============================")
  write("Enter accepts the value in brackets. Re-run later with: main setup")
  local s = settings.load()

  if isRobot then
    write("")
    write("This is a robot, so it will run as a breeding cell.")
    local cell = s.cell
    cell.name = ask("Cell name (matches controller.cells)", cell.name or config.cell.name or "cell1")
    local kinds = { "gt_iapiary", "apiary", "magic_apiary", "alveary" }
    local k = askChoice("Housing type", kinds, 1)
    cell.housing = type(k) == "number" and kinds[k] or k
    write("")
    write("Robot checklist: Beekeeper Upgrade %s, Inventory Controller %s, modem %s",
      has("beekeeper") and "ok" or "MISSING", has("inventory_controller") and "ok" or "MISSING", has("modem") and "ok" or "MISSING")
    write("Park it at level 0 facing the housing, with the block above and below it free.")
    s.setupDone = true
    settings.save(s)
    write("Saved. Starting the cell worker.")
    return s
  end

  componentReport()
  local ctl = s.controller
  ctl.cells = ctl.cells or {}
  local existingNames = util.sortedKeys(config.controller.cells or {})
  local cellName = ask("Cell name to configure", existingNames[1] or "cell1")
  local existing = (config.controller.cells or {})[cellName] or {}
  local cellCfg = ctl.cells[cellName] or {}
  local kinds = { "gt_iapiary", "apiary", "magic_apiary", "alveary" }
  local k = askChoice("Housing type", kinds, 1)
  cellCfg.housing = type(k) == "number" and kinds[k] or k
  cellCfg.mainInterface, cellCfg.beeInterface = chooseInterfaces(cellName, existing)
  local names = util.map(biomes, function(b) return string.format("%-14s temp %.2f  humidity %.2f", b[1], b[2], b[3]) end)
  local bi = askChoice("Biome the cell stands in", names, 1)
  if type(bi) == "number" then cellCfg.base = { temp = biomes[bi][2], hum = biomes[bi][3] }
  else
    cellCfg.base = { temp = tonumber(ask("temperature value", 0.8)) or 0.8, hum = tonumber(ask("humidity value", 0.4)) or 0.4 }
  end
  ctl.cells[cellName] = cellCfg

  write("")
  write("Discord (optional). A webhook posts events; a bot token + channel also accepts commands.")
  ctl.discord = ctl.discord or {}
  local d = ctl.discord
  d.enabled = askYesNo("Enable Discord", d.enabled or false)
  if d.enabled then
    d.webhook = ask("Webhook URL (blank for none)", d.webhook or "")
    d.token = ask("Bot token (blank for none)", d.token or "")
    d.channel = ask("Channel id (blank for none)", d.channel or "")
    d.prefix = ask("Command prefix", d.prefix or "!")
    if askYesNo("Test Discord now", true) then testDiscord(config.controller, s) end
  end

  write("")
  write("Custom host (optional). The controller pushes a JSON status to <url>/status and can probe it.")
  ctl.host = ctl.host or {}
  ctl.host.url = ask("Host URL, e.g. http://192.168.1.10:8080 (blank for none)", ctl.host.url or "")
  if ctl.host.url ~= "" then
    ctl.host.pushInterval = tonumber(ask("Push interval seconds (0 = never push)", ctl.host.pushInterval or 30)) or 30
    if askYesNo("Test the host now", true) then testHost(s) end
  end

  s.setupDone = true
  settings.save(s)
  write("")
  write("Saved to %s. The survey runs on first start if the mutation data is missing.", settings.path)
  write("Press Enter to start.")
  io.read()
  return s
end

setup.testDiscord = testDiscord
setup.testHost = testHost

return setup
