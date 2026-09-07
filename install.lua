-- install : copy the BeeBreeder files onto an OpenComputers computer or robot.
--
-- Two ways to use it:
--   1. From a floppy/disk that contains this repository:
--        install /mnt/<disk>      (controller: everything; robot: add "robot")
--   2. From the internet (internet card required):
--        wget <base-url>/install.lua /tmp/install.lua
--        /tmp/install.lua <base-url> [robot]
--      where <base-url> serves the repository files, e.g. a raw GitHub URL
--      like https://raw.githubusercontent.com/<user>/<repo>/main
local shell = require("shell")
local fs = require("filesystem")

local args = shell.parse(...)
local source = args[1]
local isRobot = args[2] == "robot"
if not source then
  print("usage: install <path-or-url> [robot]")
  return
end

local files = {
  "lib/bb/util.lua", "lib/bb/json.lua", "lib/bb/conditions.lua", "lib/bb/catalog.lua",
  "lib/bb/climate.lua", "lib/bb/genome.lua", "lib/bb/graph.lua", "lib/bb/housing.lua",
  "lib/bb/ae2.lua", "lib/bb/net.lua", "lib/bb/discord.lua", "lib/bb/needs.lua", "lib/bb/breeder.lua",
}
local programs = { "bin/survey.lua", "bin/beectl.lua", "bin/beecell.lua" }
local configs = { "etc/beebreeder.cfg", "etc/beecell.cfg" }

local function ensureDir(path)
  local dir = fs.path(path)
  if dir and not fs.exists(dir) then fs.makeDirectory(dir) end
end

local function copyLocal(rel, dest)
  local src = source .. "/" .. rel
  if not fs.exists(src) then return false, "missing " .. src end
  ensureDir(dest)
  local ok, err = fs.copy(src, dest)
  return ok, err
end

local function download(rel, dest)
  local internet = require("internet")
  ensureDir(dest)
  local ok, err = pcall(function()
    local data = {}
    for chunk in internet.request(source .. "/" .. rel) do data[#data + 1] = chunk end
    local f = assert(io.open(dest, "w"))
    f:write(table.concat(data))
    f:close()
  end)
  return ok, err
end

local fetch = source:match("^https?://") and download or copyLocal

local function put(rel, dest)
  local ok, err = fetch(rel, dest)
  print((ok and "  ok   " or "  FAIL ") .. rel .. (ok and "" or (" : " .. tostring(err))))
end

print("Installing libraries to /usr/lib/bb")
for _, f in ipairs(files) do put(f, "/usr" .. "/" .. f) end

print("Installing programs to /usr/bin")
for _, f in ipairs(programs) do
  local name = f:match("([^/]+)$")
  if isRobot and name ~= "beecell.lua" then
    -- robots only need the worker, but survey is handy for probing
    if name == "survey.lua" then put(f, "/usr/bin/" .. name) end
  else
    put(f, "/usr/bin/" .. name)
  end
end

print("Installing example configs to /etc (existing files are not overwritten)")
for _, f in ipairs(configs) do
  local name = f:match("([^/]+)$")
  if fs.exists("/etc/" .. name) then print("  keep " .. name) else put(f, "/etc/" .. name) end
end

if isRobot then
  print("Robot install done. Edit /etc/beecell.cfg then run: beecell")
  print("To start on boot: echo 'beecell' >> /home/.shrc")
else
  print("Controller install done. Run: survey   then edit /etc/beebreeder.cfg and run: beectl")
end
