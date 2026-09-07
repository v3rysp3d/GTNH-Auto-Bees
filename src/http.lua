-- HTTP over the OpenComputers internet card (GTNH fork: custom headers and
-- any method). Shared by the Discord bridge and the custom host link.
local util = require("src.util")

local http = {}

---Perform a request and read the whole response.
---@param internet table   internet card component proxy
---@param method string    "GET" | "POST" | "DELETE" | ...
---@param url string
---@param body string|nil
---@param headers table|nil
---@param timeout number|nil seconds (default 10)
---@return number|nil code   nil on transport failure
---@return string body_or_error
function http.request(internet, method, url, body, headers, timeout)
  if not internet then return nil, "no internet card" end
  timeout = timeout or 10
  headers = headers or {}
  if body and not headers["Content-Type"] then headers["Content-Type"] = "application/json" end

  local ok, handle = pcall(internet.request, url, body, headers, method)
  if not ok or not handle then return nil, "request failed: " .. tostring(handle) end

  local deadline = util.now() + timeout
  while true do
    local okc, connected, err = pcall(handle.finishConnect)
    if not okc then pcall(handle.close) return nil, "connect error: " .. tostring(connected) end
    if connected then break end
    if err then pcall(handle.close) return nil, "connect error: " .. tostring(err) end
    if util.now() > deadline then pcall(handle.close) return nil, "timeout" end
    util.sleep(0.1)
  end

  local chunks = {}
  while true do
    local okr, chunk = pcall(handle.read)
    if not okr or chunk == nil then break end
    if chunk ~= "" then chunks[#chunks + 1] = chunk end
    if util.now() > deadline + timeout then break end
  end
  local code = 0
  local okResp, c = pcall(handle.response)
  if okResp and type(c) == "number" then code = c end
  pcall(handle.close)
  return code, table.concat(chunks)
end

---Reachability probe. Returns ok, description.
function http.probe(internet, url, timeout)
  local started = util.now()
  local code, body = http.request(internet, "GET", url, nil, nil, timeout or 8)
  local ms = math.floor((util.now() - started) * 1000)
  if not code then return false, tostring(body) end
  return code >= 200 and code < 400, string.format("HTTP %d in %d ms, %d bytes", code, ms, #(body or ""))
end

return http
