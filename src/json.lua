-- bb.json : minimal JSON encoder/decoder for the Discord bridge.
-- Lua 5.2 compatible, pure Lua, no dependencies.
local json = {}

json.null = setmetatable({}, { __tostring = function() return "null" end })
local arrayMt = { __jsonarray = true }

--- Mark a table as a JSON array (needed for empty arrays or sparse tables).
function json.array(t) return setmetatable(t or {}, arrayMt) end

local escapes = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function encodeString(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return escapes[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function isArray(t)
  if getmetatable(t) == arrayMt then return true end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then return false end
    n = n + 1
  end
  return n > 0 and n == #t
end

local function encodeValue(v, out, depth)
  local t = type(v)
  if v == nil or v == json.null then out[#out + 1] = "null"
  elseif t == "boolean" then out[#out + 1] = tostring(v)
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "null"
    elseif math.floor(v) == v and math.abs(v) < 2^53 then out[#out + 1] = string.format("%d", v)
    else out[#out + 1] = string.format("%.14g", v) end
  elseif t == "string" then out[#out + 1] = encodeString(v)
  elseif t == "table" then
    if depth > 64 then error("json: nesting too deep") end
    if isArray(v) then
      out[#out + 1] = "["
      for i = 1, #v do
        if i > 1 then out[#out + 1] = "," end
        encodeValue(v[i], out, depth + 1)
      end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local first = true
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      for _, k in ipairs(keys) do
        local val = v[k]
        if val == nil then val = v[tonumber(k)] end
        if not first then out[#out + 1] = "," end
        first = false
        out[#out + 1] = encodeString(k)
        out[#out + 1] = ":"
        encodeValue(val, out, depth + 1)
      end
      out[#out + 1] = "}"
    end
  else
    error("json: cannot encode " .. t)
  end
end

function json.encode(v)
  local out = {}
  encodeValue(v, out, 0)
  return table.concat(out)
end

------------------------------------------------------------------------
-- decoder
------------------------------------------------------------------------
local function utf8Char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local unescapes = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

local decodeValue

local function skipWs(s, i)
  local _, e = s:find("^[ \t\r\n]*", i)
  return e + 1
end

local function decodeString(s, i)
  -- s:sub(i,i) == '"'
  local out = {}
  i = i + 1
  while true do
    local c = s:sub(i, i)
    if c == "" then error("json: unterminated string") end
    if c == '"' then return table.concat(out), i + 1 end
    if c == "\\" then
      local e = s:sub(i + 1, i + 1)
      if e == "u" then
        local hex = s:sub(i + 2, i + 5)
        local cp = tonumber(hex, 16)
        if not cp then error("json: bad unicode escape") end
        i = i + 6
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(i, i + 1) == "\\u" then
          local lo = tonumber(s:sub(i + 2, i + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            i = i + 6
          end
        end
        out[#out + 1] = utf8Char(cp)
      else
        local r = unescapes[e]
        if not r then error("json: bad escape \\" .. e) end
        out[#out + 1] = r
        i = i + 2
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
end

local function decodeNumber(s, i)
  local numStr = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
  if not numStr or numStr == "" then error("json: bad number at " .. i) end
  local n = tonumber(numStr)
  if not n then error("json: bad number " .. numStr) end
  return n, i + #numStr
end

decodeValue = function(s, i, inArray)
  i = skipWs(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local obj = {}
    i = skipWs(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
      i = skipWs(s, i)
      if s:sub(i, i) ~= '"' then error("json: expected key at " .. i) end
      local key
      key, i = decodeString(s, i)
      i = skipWs(s, i)
      if s:sub(i, i) ~= ":" then error("json: expected ':' at " .. i) end
      local val
      val, i = decodeValue(s, i + 1, false)
      obj[key] = val
      i = skipWs(s, i)
      local d = s:sub(i, i)
      if d == "}" then return obj, i + 1 end
      if d ~= "," then error("json: expected ',' or '}' at " .. i) end
      i = i + 1
    end
  elseif c == "[" then
    local arr = json.array({})
    i = skipWs(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
      local val
      val, i = decodeValue(s, i, true)
      arr[#arr + 1] = val
      i = skipWs(s, i)
      local d = s:sub(i, i)
      if d == "]" then return arr, i + 1 end
      if d ~= "," then error("json: expected ',' or ']' at " .. i) end
      i = i + 1
    end
  elseif c == '"' then
    return decodeString(s, i)
  elseif c == "t" and s:sub(i, i + 3) == "true" then return true, i + 4
  elseif c == "f" and s:sub(i, i + 4) == "false" then return false, i + 5
  elseif c == "n" and s:sub(i, i + 3) == "null" then
    if inArray then return json.null, i + 4 end
    return nil, i + 4
  else
    return decodeNumber(s, i)
  end
end

function json.decode(s)
  if type(s) ~= "string" then return nil, "not a string" end
  local ok, res, pos = pcall(decodeValue, s, 1, true)
  if not ok then return nil, res end
  if res == json.null then res = nil end
  return res, pos
end

return json
