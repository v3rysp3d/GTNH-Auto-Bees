-- GTNH Auto Bees installer
-- Based on Navatusein's GTNH-OC-Installer (MIT). Installs into /home.
--
--   wget -f https://raw.githubusercontent.com/v3rysp3d/GTNH-Auto-Bees/main/installer.lua && installer
--
-- Downloads the latest release archive from GitHub; if no release exists yet
-- it falls back to fetching the files from the main branch one by one.
local shell = require("shell")
local term = require("term")
local filesystem = require("filesystem")
local internet = require("internet")

local repository = "v3rysp3d/GTNH-Auto-Bees"
local archiveName = "AutoBees"

local releaseUrl = "https://github.com/" .. repository .. "/releases/latest/download/" .. archiveName .. ".tar"
local rawBase = "https://raw.githubusercontent.com/" .. repository .. "/main/"

local tarManUrl = "https://raw.githubusercontent.com/mpmxyz/ocprograms/master/usr/man/tar.man"
local tarBinUrl = "https://raw.githubusercontent.com/mpmxyz/ocprograms/master/home/bin/tar.lua"

-- files fetched when no release archive is available
local files = {
  "main.lua", "config.lua", "version.lua",
  "lib/program-lib.lua", "lib/gui-lib.lua", "lib/logger-lib.lua", "lib/state-machine-lib.lua",
  "lib/component-discover-lib.lua", "lib/list-lib.lua", "lib/gui-widgets/scroll-list.lua",
  "lib/logger-handler/discord-logger-handler-lib.lua", "lib/logger-handler/file-logger-handler-lib.lua",
  "lib/logger-handler/scroll-list-logger-handler-lib.lua",
  "src/util.lua", "src/json.lua", "src/conditions.lua", "src/catalog.lua", "src/climate.lua",
  "src/genome.lua", "src/graph.lua", "src/housing.lua", "src/ae2.lua", "src/net.lua", "src/http.lua",
  "src/discord.lua", "src/connect.lua", "src/settings.lua", "src/setup.lua", "src/needs.lua",
  "src/breeder.lua", "src/survey.lua", "src/controller.lua", "src/cell.lua",
}

local function checkIsOsInstall()
  local file = io.open("/home/.installer.test", "w")
  if file == nil then error("OpenOS is not installed") end
  file:close()
  filesystem.remove("/home/.installer.test")
end

local function checkGithub()
  local ok, request = pcall(internet.request, rawBase .. "version.lua")
  if not ok then error("GitHub is unreachable: " .. tostring(request)) end
  local okRead, result = pcall(request)
  if not okRead then
    if tostring(result):match("PKIX") then
      error("GitHub's SSL certificate was rejected by Java. Update Java or install the certificate manually.")
    end
    error("GitHub is unreachable: " .. tostring(result))
  end
end

local function downloadTarUtility()
  if filesystem.exists("/bin/tar.lua") then return end
  filesystem.makeDirectory("/usr/man")
  shell.setWorkingDirectory("/usr/man")
  shell.execute("wget -fq " .. tarManUrl)
  shell.setWorkingDirectory("/bin")
  shell.execute("wget -fq " .. tarBinUrl)
end

local function fileSize(path)
  if not filesystem.exists(path) then return 0 end
  return filesystem.size(path) or 0
end

local function installFromRelease()
  shell.execute("wget -fq " .. releaseUrl .. " program.tar")
  if fileSize("program.tar") < 1000 then
    if filesystem.exists("program.tar") then filesystem.remove("program.tar") end
    return false
  end
  downloadTarUtility()
  shell.execute("tar -xf program.tar")
  filesystem.remove("program.tar")
  return true
end

local function installFromMain()
  for _, rel in ipairs(files) do
    local dir = filesystem.path(rel)
    if dir and dir ~= "" and not filesystem.exists("/home/" .. dir) then filesystem.makeDirectory("/home/" .. dir) end
    shell.execute("wget -fq " .. rawBase .. rel .. " " .. rel)
    term.write((fileSize(rel) > 0 and "  ok   " or "  FAIL ") .. rel .. "\n")
  end
end

local function makeAutoRun()
  term.write("\nStart the program automatically on boot [y/n]\n===>")
  local userInput = io.read() or "n"
  if string.lower(userInput) == "y" then
    local file = assert(io.open("/home/.shrc", "w"))
    file:write("main")
    file:close()
    term.write("Auto run created\n")
  else
    term.write("Auto run skipped\n")
  end
end

local function main()
  checkIsOsInstall()
  checkGithub()

  term.clear()
  term.write("GTNH Auto Bees installer\n\n")
  shell.setWorkingDirectory("/home")

  local hadConfig = filesystem.exists("/home/config.lua")
  if hadConfig then shell.execute("mv config.lua config.prev.lua") end

  term.write("Downloading latest release...\n")
  if installFromRelease() then
    term.write("Installed from the release archive\n")
  else
    term.write("No release archive found, fetching files from the main branch\n")
    installFromMain()
  end

  if hadConfig then
    -- keep the user's configuration, ship the fresh template next to it
    shell.execute("mv config.lua config.new.lua")
    shell.execute("mv config.prev.lua config.lua")
    term.write("Kept your config.lua; the new template is config.new.lua\n")
  end

  makeAutoRun()
  term.write("\nDone. Edit config.lua, then run: main\n")
  term.write("(on a robot `main` starts the cell worker automatically)\n")
end

main()
