-- bb.util : small helpers shared by every BeeBreeder program.
-- Lua 5.2 compatible (OpenComputers default CPU architecture).
-- Safe to load outside OpenComputers (used by the local test suite).
local util = {}

local okComputer, computer = pcall(require, "computer")
if not okComputer then computer = nil end

------------------------------------------------------------------------
-- time / sleep
------------------------------------------------------------------------
function util.now()
  if computer and computer.uptime then return computer.uptime() end
  return os.clock()
end

function util.sleep(s)
  if os.sleep then os.sleep(s) return end
  local t = os.clock() + s
  while os.clock() < t do end
end

------------------------------------------------------------------------
-- strings
------------------------------------------------------------------------
function util.trim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end
function util.startsWith(s, p) return s:sub(1, #p) == p end
function util.endsWith(s, p) return p == "" or s:sub(-#p) == p end
function util.lower(s) return tostring(s or ""):lower() end

function util.split(s, sep)
  sep = sep or "%s"
  local out = {}
  for piece in tostring(s):gmatch("([^" .. sep .. "]+)") do out[#out + 1] = piece end
  return out
end

function util.pad(s, n, right)
  s = tostring(s)
  if #s >= n then return s:sub(1, n) end
  if right then return string.rep(" ", n - #s) .. s end
  return s .. string.rep(" ", n - #s)
end

function util.fmtSeconds(s)
  s = math.floor(s or 0)
  if s < 60 then return s .. "s" end
  if s < 3600 then return math.floor(s / 60) .. "m" .. (s % 60) .. "s" end
  return math.floor(s / 3600) .. "h" .. math.floor((s % 3600) / 60) .. "m"
end

------------------------------------------------------------------------
-- tables
------------------------------------------------------------------------
function util.keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  return out
end

function util.sortedKeys(t)
  local ks = util.keys(t)
  table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
  return ks
end

function util.count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

function util.copy(t, seen)
  if type(t) ~= "table" then return t end
  seen = seen or {}
  if seen[t] then return seen[t] end
  local out = {}
  seen[t] = out
  for k, v in pairs(t) do out[util.copy(k, seen)] = util.copy(v, seen) end
  return setmetatable(out, getmetatable(t))
end

function util.merge(base, over)
  local out = util.copy(base or {})
  for k, v in pairs(over or {}) do
    if type(v) == "table" and type(out[k]) == "table" then out[k] = util.merge(out[k], v)
    else out[k] = v end
  end
  return out
end

function util.contains(list, v)
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

function util.map(list, f)
  local out = {}
  for i, v in ipairs(list) do out[i] = f(v, i) end
  return out
end

function util.filter(list, f)
  local out = {}
  for _, v in ipairs(list) do if f(v) then out[#out + 1] = v end end
  return out
end

function util.set(list)
  local s = {}
  for _, v in ipairs(list) do s[v] = true end
  return s
end

------------------------------------------------------------------------
-- serialization (own implementation: no size limits, stable key order)
------------------------------------------------------------------------
local function serializeValue(v, out, depth)
  local t = type(v)
  if t == "number" then
    if v ~= v then out[#out + 1] = "0/0"
    elseif v == math.huge then out[#out + 1] = "math.huge"
    elseif v == -math.huge then out[#out + 1] = "-math.huge"
    elseif math.floor(v) == v and math.abs(v) < 2^53 then out[#out + 1] = string.format("%d", v)
    else out[#out + 1] = string.format("%.17g", v) end
  elseif t == "string" then out[#out + 1] = string.format("%q", v)
  elseif t == "boolean" or t == "nil" then out[#out + 1] = tostring(v)
  elseif t == "table" then
    if depth > 64 then error("serialize: nesting too deep") end
    out[#out + 1] = "{"
    local n = #v
    for i = 1, n do
      serializeValue(v[i], out, depth + 1)
      out[#out + 1] = ","
    end
    local keys = {}
    for k in pairs(v) do
      if not (type(k) == "number" and k >= 1 and k <= n and math.floor(k) == k) then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b)
      local ta, tb = type(a), type(b)
      if ta ~= tb then return ta < tb end
      return tostring(a) < tostring(b)
    end)
    for _, k in ipairs(keys) do
      if type(k) == "string" and k:match("^[%a_][%w_]*$") then out[#out + 1] = k
      else
        out[#out + 1] = "["
        serializeValue(k, out, depth + 1)
        out[#out + 1] = "]"
      end
      out[#out + 1] = "="
      serializeValue(v[k], out, depth + 1)
      out[#out + 1] = ","
    end
    out[#out + 1] = "}"
  else
    error("serialize: cannot serialize " .. t)
  end
end

function util.serialize(v)
  local out = {}
  serializeValue(v, out, 0)
  return table.concat(out)
end

--- Serialize straight into a writer function, never holding the whole text
--- in memory (OpenComputers computers have little RAM).
function util.serializeTo(write, v)
  local buf, size = {}, 0
  local sink = setmetatable({}, { __newindex = function(_, _, piece)
    buf[#buf + 1] = piece
    size = size + #piece
    if size > 4096 then
      write(table.concat(buf))
      buf, size = {}, 0
    end
  end })
  serializeValue(v, sink, 0)
  if #buf > 0 then write(table.concat(buf)) end
end

function util.unserialize(s)
  if type(s) ~= "string" then return nil, "not a string" end
  local fn, err = load("return " .. s, "=unserialize", "t", { math = { huge = math.huge } })
  if not fn then return nil, err end
  local ok, res = pcall(fn)
  if not ok then return nil, res end
  return res
end

------------------------------------------------------------------------
-- files
------------------------------------------------------------------------
function util.readFile(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local s = f:read("*a")
  f:close()
  return s
end

function util.writeFile(path, s)
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  f:write(s)
  f:close()
  return true
end

function util.exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

function util.mkdirs(path)
  local okfs, fs = pcall(require, "filesystem")
  if okfs and fs and fs.makeDirectory then
    if not fs.exists(path) then fs.makeDirectory(path) end
  end
end

function util.loadTable(path, default)
  local s = util.readFile(path)
  if not s then return default end
  local t = util.unserialize(s)
  if t == nil then return default end
  return t
end

function util.saveTable(path, t)
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  local ok, serr = pcall(util.serializeTo, function(s) f:write(s) end, t)
  f:close()
  if not ok then return nil, serr end
  return true
end

------------------------------------------------------------------------
-- logging
------------------------------------------------------------------------
util.logSinks = {}
util.logLevel = 2 -- 1 debug, 2 info, 3 warn, 4 error
local levelNames = { "DEBUG", "INFO", "WARN", "ERROR" }

function util.addLogSink(fn) util.logSinks[#util.logSinks + 1] = fn end

function util.log(level, fmt, ...)
  if level < util.logLevel then return end
  local msg
  if select("#", ...) > 0 then msg = string.format(fmt, ...) else msg = tostring(fmt) end
  local line = string.format("[%s] %s", levelNames[level] or "?", msg)
  if #util.logSinks == 0 then print(line) end
  for _, sink in ipairs(util.logSinks) do pcall(sink, level, msg, line) end
end
function util.debug(...) util.log(1, ...) end
function util.info(...) util.log(2, ...) end
function util.warn(...) util.log(3, ...) end
function util.error(...) util.log(4, ...) end

------------------------------------------------------------------------
-- command line parsing: "breed 4137 keep 16 extra 4051=64 4060=32"
-- -> { words = {"breed","4137"}, opts = { keep = "16", extra = {"4051=64","4060=32"} } }
------------------------------------------------------------------------
util.optionWords = { keep = 1, extra = -1, princess = 0, drones = 1, cell = 1, all = 0, force = 0, want = 1 }

---A drone count, where "forever" and its synonyms mean keep going until
---told otherwise. Returns a number, -1 for no limit, or nil if unreadable.
function util.parseKeep(word)
  if word == nil then return nil end
  local text = tostring(word):lower()
  if text == "forever" or text == "infinite" or text == "unlimited" or text == "endless" then return -1 end
  return tonumber(text)
end

function util.parseCommand(line)
  local toks = util.split(util.trim(line), "%s")
  local res = { words = {}, opts = {} }
  local i = 1
  while i <= #toks do
    local tok = toks[i]
    local key = tok:gsub("^%-%-", "")
    local arity = util.optionWords[key]
    if arity ~= nil and (tok:sub(1, 2) == "--" or i > 1) then
      if arity == 0 then res.opts[key] = true; i = i + 1
      elseif arity == 1 then res.opts[key] = toks[i + 1]; i = i + 2
      else
        local list = {}
        i = i + 1
        while i <= #toks and util.optionWords[toks[i]:gsub("^%-%-", "")] == nil do
          list[#list + 1] = toks[i]
          i = i + 1
        end
        res.opts[key] = list
      end
    else
      res.words[#res.words + 1] = tok
      i = i + 1
    end
  end
  return res
end

return util
