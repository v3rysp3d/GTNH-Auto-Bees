-- Connectivity checks and the custom host link. Everything returns
-- (ok, text) so it can be shown in the GUI, on Discord, or in the guide.
local http = require("src.http")
local json = require("src.json")
local util = require("src.util")

local connect = {}

connect.userAgent = "DiscordBot (https://github.com/v3rysp3d/GTNH-Auto-Bees, 1.0)"
connect.discordApi = "https://discord.com/api/v10"

---Post a test message through a webhook.
function connect.testWebhook(internet, url, text)
  if not internet then return false, "no internet card" end
  if not url or url == "" then return false, "no webhook url" end
  local body = json.encode({ username = "Auto Bees", content = text or "Auto Bees: webhook test" })
  local code, resp = http.request(internet, "POST", url .. "?wait=true", body)
  if not code then return false, tostring(resp) end
  if code >= 200 and code < 300 then return true, "webhook ok (HTTP " .. code .. ")" end
  return false, "HTTP " .. code .. " " .. tostring(resp):sub(1, 120)
end

---Check a bot token against a channel.
function connect.testBot(internet, token, channel)
  if not internet then return false, "no internet card" end
  if not token or token == "" or not channel or channel == "" then return false, "bot token or channel id missing" end
  local code, resp = http.request(internet, "GET", connect.discordApi .. "/channels/" .. channel, nil,
    { Authorization = "Bot " .. token, ["User-Agent"] = connect.userAgent })
  if not code then return false, tostring(resp) end
  if code == 200 then
    local info = json.decode(resp) or {}
    return true, "bot ok, channel '" .. tostring(info.name or "?") .. "'"
  end
  return false, "HTTP " .. code .. " " .. tostring(resp):sub(1, 120)
end

---Probe the custom host.
function connect.testHost(internet, url)
  if not internet then return false, "no internet card" end
  if not url or url == "" then return false, "no host url" end
  local ok, why = http.probe(internet, url)
  return ok, (ok and "reachable: " or "not reachable: ") .. why
end

---Push a status table as JSON to <url>/status.
function connect.pushStatus(internet, url, status)
  if not internet or not url or url == "" then return false, "host link not configured" end
  local base = url:gsub("/+$", "")
  local code, resp = http.request(internet, "POST", base .. "/status", json.encode(status), nil, 6)
  if not code then return false, tostring(resp) end
  if code >= 200 and code < 300 then return true, "HTTP " .. code end
  return false, "HTTP " .. code
end

---Text lines for the GUI/Discord `settings test` command.
function connect.report(internet, discordCfg, hostCfg)
  local out = {}
  local d = discordCfg or {}
  local h = hostCfg or {}
  if (d.webhook or "") ~= "" then
    local ok, why = connect.testWebhook(internet, d.webhook)
    out[#out + 1] = "webhook: " .. why .. (ok and "" or " (FAILED)")
  else
    out[#out + 1] = "webhook: not set"
  end
  if (d.token or "") ~= "" and (d.channel or "") ~= "" then
    local ok, why = connect.testBot(internet, d.token, d.channel)
    out[#out + 1] = "bot: " .. why .. (ok and "" or " (FAILED)")
  else
    out[#out + 1] = "bot: not set"
  end
  if (h.url or "") ~= "" then
    local ok, why = connect.testHost(internet, h.url)
    out[#out + 1] = "host: " .. why
  else
    out[#out + 1] = "host: not set"
  end
  if not internet then out[#out + 1] = "no internet card in this computer" end
  return out
end

return connect
