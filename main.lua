local component = require("component")
local keyboard = require("keyboard")
local event = require("event")

local util = require("src.util")
local settingsLib = require("src.settings")

package.loaded.config = nil
local config = require("config")
local version = require("version")

local repository = "v3rysp3d/GTNH-Auto-Bees"
local archiveName = "AutoBees"

local args = { ... }
local isRobot = component.isAvailable("robot")

------------------------------------------------------------------------
-- settings.dat (written by the guide) overrides config.lua sections
------------------------------------------------------------------------
local stored = settingsLib.load()
settingsLib.apply(config, stored)

if args[1] == "setup" or settingsLib.needsSetup(config, stored, isRobot) then
  require("src.setup").run(config, isRobot)
  package.loaded.config = nil
  config = require("config")
  settingsLib.apply(config, settingsLib.load())
end

-- one webhook URL drives both the event cards and the logger's warnings
local webhook = config.controller.discord and config.controller.discord.webhook or ""
if webhook ~= "" then
  for _, handler in ipairs(config.logger.handlers or {}) do
    if handler.discordWebhookUrl ~= nil and handler.discordWebhookUrl == "" then handler.discordWebhookUrl = webhook end
  end
end

------------------------------------------------------------------------
-- Robot: run the breeding cell worker, no GUI
------------------------------------------------------------------------
if isRobot then
  require("src.cell"):new(config.cell, config.logger):run()
  return
end

------------------------------------------------------------------------
-- Computer: controller with GUI
------------------------------------------------------------------------
local programLib = require("lib.program-lib")
local guiLib = require("lib.gui-lib")
local scrollList = require("lib.gui-widgets.scroll-list")
local controllerLib = require("src.controller")

local program = programLib:new(config.logger, config.enableAutoUpdate, version, repository, archiveName)
local gui = guiLib:new(program)
local controller = controllerLib:new(config.controller, config.logger)

local logo = {
  "    _         _          ____                 ",
  "   / \\  _   _| |_ ___   | __ )  ___  ___  ___ ",
  "  / _ \\| | | | __/ _ \\  |  _ \\ / _ \\/ _ \\/ __|",
  " / ___ \\ |_| | || (_) | | |_) |  __/  __/\\__ \\",
  "/_/   \\_\\__,_|\\__\\___|  |____/ \\___|\\___||___/",
}

local WIDTH = 120

local function bar(color, text)
  return "&&" .. color .. ";&white;" .. util.pad(text, WIDTH) .. "&&black;"
end

local function times(text, n)
  local out = {}
  for _ = 1, n do out[#out + 1] = text end
  return out
end

local lines = { "&&steelBlue;&white;$header$&&black;", "" }
local function section(title, widget, rows)
  lines[#lines + 1] = bar("darkSlateGrey", title)
  for _, l in ipairs(times("#" .. widget .. "#", rows)) do lines[#lines + 1] = l end
  lines[#lines + 1] = ""
end
section(" CELLS                                 Home / Delete scroll", "cellsList", 4)
section(" QUEUE                                 PgUp / PgDn scroll", "queueList", 12)
section(" LOG                                   Up / Down scroll        type a command, Enter runs it, `help` lists them, End quits", "logsList", 14)
lines[#lines + 1] = "&cyan;> $input$&lightGray;_"

local mainTemplate = {
  width = WIDTH,
  background = gui.palette.black,
  foreground = gui.palette.white,
  widgets = {
    cellsList = scrollList:new("cellsList", "cells", keyboard.keys.home, keyboard.keys.delete),
    queueList = scrollList:new("queueList", "queue", keyboard.keys.pageUp, keyboard.keys.pageDown),
    logsList = scrollList:new("logsList", "logs", keyboard.keys.up, keyboard.keys.down),
  },
  lines = lines,
}

local inputBuffer = ""
local keyListener
local quitKeyMoved = false

local function init()
  gui:setTemplate(mainTemplate)
  controller:init()

  -- typing goes to the command line; program-lib's `q` quits, so quitting moves to End
  keyListener = function(_, _, char, code)
    if code == keyboard.keys.enter then
      local line = inputBuffer
      inputBuffer = ""
      if line ~= "" then controller:command(line, "gui") end
    elseif code == keyboard.keys.back then
      inputBuffer = inputBuffer:sub(1, -2)
    elseif char and char >= 32 and char < 127 then
      inputBuffer = inputBuffer .. string.char(char)
    end
  end
  event.listen("key_down", keyListener)
end

local function loop()
  controller:loop()
end

local function guiLoop()
  if not quitKeyMoved then
    quitKeyMoved = true
    program:removeKeyHandler(keyboard.keys.q)
    program:registerKeyHandler(keyboard.keys["end"], function() event.push("exit") end)
  end
  local v = controller:getValues()
  v.header = util.pad(string.format(" GTNH AUTO BEES  v%s     cells %d     library %d species / %d princesses     discord %s     host %s",
    version.programVersion, v.cellCount, v.libSpecies, v.princesses, v.discord, v.host), WIDTH)
  v.input = inputBuffer
  v.logs = config.logger.handlers[3].logs.list
  gui:render(v)
end

local function onExit()
  if keyListener then event.ignore("key_down", keyListener) end
  controller:stop()
end

program:registerLogo(logo)
program:registerInit(init)
program:registerOnExit(onExit)
program:registerThread(loop)
program:registerTimer(guiLoop, math.huge, 0.5)
program:start()
