-- bb.discord : Discord bridge over the OpenComputers internet card.
--
-- Outbound: bot token (POST /channels/{id}/messages) or a webhook URL.
-- Inbound : polling GET /channels/{id}/messages?after=<lastId> with the bot token.
-- Needs the GTNH OC fork (internet.request(url, body, headers, method)) and the
-- server config defaults: enableHttp=true, enableHttpHeaders=true (both are the
-- GTNH pack defaults).
--
-- Java's HttpURLConnection cannot send PATCH, so "edit" falls back to
-- delete + post when PATCH is rejected.
local util = require("bb.util")
local json = require("bb.json")

local discord = {}
discord.__index = discord

discord.API = "https://discord.com/api/v10"

--- internet: the internet card component proxy
--- cfg: { token = "...", channel = "123", webhook = "https://...", pollLimit = 20 }
function discord.new(internet, cfg)
  cfg = cfg or {}
  return setmetatable({
    internet = internet,
    token = cfg.token, channel = cfg.channel, webhook = cfg.webhook,
    pollLimit = cfg.pollLimit or 20,
    lastId = cfg.lastId,
    timeout = cfg.timeout or 10,
    userAgent = "DiscordBot (https://github.com/oc-beebreeder, 1.0)",
  }, discord)
end

function discord:enabled()
  return self.internet ~= nil and ((self.token and self.channel) or self.webhook) and true or false
end

function discord:canRead()
  return self.internet ~= nil and self.token ~= nil and self.channel ~= nil
end

--- Raw HTTP. Returns code, body or nil, err.
function discord:http(method, url, body, extraHeaders)
  if not self.internet then return nil, "no internet card" end
  local headers = { ["User-Agent"] = self.userAgent, ["Accept"] = "application/json" }
  if body then headers["Content-Type"] = "application/json" end
  if self.token and url:find(discord.API, 1, true) == 1 then headers["Authorization"] = "Bot " .. self.token end
  for k, v in pairs(extraHeaders or {}) do headers[k] = v end

  local ok, handle = pcall(self.internet.request, url, body, headers, method)
  if not ok or not handle then return nil, "request failed: " .. tostring(handle) end

  local deadline = util.now() + self.timeout
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
    if not okr then break end
    if chunk == nil then break end
    if chunk ~= "" then chunks[#chunks + 1] = chunk end
    if util.now() > deadline + self.timeout then break end
  end
  local code = 0
  local okResp, c = pcall(handle.response)
  if okResp and type(c) == "number" then code = c end
  pcall(handle.close)
  return code, table.concat(chunks)
end

--- Split a long text into Discord-sized pieces (limit 2000 chars).
function discord.chunk(text, limit)
  limit = limit or 1900
  local out, cur = {}, {}
  local len = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if len + #line + 1 > limit and #cur > 0 then
      out[#out + 1] = table.concat(cur, "\n")
      cur, len = {}, 0
    end
    cur[#cur + 1] = line
    len = len + #line + 1
  end
  if #cur > 0 then out[#out + 1] = table.concat(cur, "\n") end
  return out
end

--- Post a message. Returns the message id (bot only) or true, or nil, err.
function discord:post(text, opts)
  opts = opts or {}
  if not self:enabled() then return nil, "discord disabled" end
  local pieces = discord.chunk(text)
  local lastId
  for _, piece in ipairs(pieces) do
    local body = json.encode({ content = piece, allowed_mentions = { parse = json.array({}) } })
    local code, resp, err
    if self.token and self.channel and not opts.webhookOnly then
      code, resp = self:http("POST", discord.API .. "/channels/" .. self.channel .. "/messages", body)
    elseif self.webhook then
      code, resp = self:http("POST", self.webhook .. "?wait=true", body)
    else
      return nil, "no token/channel or webhook"
    end
    if not code then return nil, resp end
    if code < 200 or code >= 300 then return nil, "http " .. code .. ": " .. tostring(resp):sub(1, 200) end
    local data = json.decode(resp)
    if type(data) == "table" and data.id then lastId = data.id end
  end
  return lastId or true
end

function discord:delete(messageId)
  if not self:canRead() then return false end
  local code = self:http("DELETE", discord.API .. "/channels/" .. self.channel .. "/messages/" .. messageId)
  return code ~= nil and code >= 200 and code < 300
end

--- Edit a message in place; falls back to delete + post. Returns the (possibly new) id.
function discord:edit(messageId, text)
  if not self:canRead() then return nil, "edit needs a bot token" end
  if messageId then
    local body = json.encode({ content = text:sub(1, 1990) })
    local code, resp = self:http("PATCH", discord.API .. "/channels/" .. self.channel .. "/messages/" .. messageId, body)
    if code and code >= 200 and code < 300 then return messageId end
    self:delete(messageId)
  end
  return self:post(text)
end

--- Fetch new messages since the last poll. Returns a list of
--- { id=, author=, content=, bot=bool } in chronological order.
function discord:poll()
  if not self:canRead() then return {}, "poll needs a bot token" end
  local url = discord.API .. "/channels/" .. self.channel .. "/messages?limit=" .. self.pollLimit
  if self.lastId then url = url .. "&after=" .. self.lastId end
  local code, resp = self:http("GET", url)
  if not code then return {}, resp end
  if code < 200 or code >= 300 then return {}, "http " .. code .. ": " .. tostring(resp):sub(1, 200) end
  local data = json.decode(resp)
  if type(data) ~= "table" then return {}, "bad json" end
  local out = {}
  -- Discord returns newest first
  for i = #data, 1, -1 do
    local m = data[i]
    if type(m) == "table" and m.id then
      out[#out + 1] = {
        id = m.id,
        author = m.author and (m.author.global_name or m.author.username) or "?",
        content = m.content or "",
        bot = m.author and m.author.bot == true,
      }
      self.lastId = m.id
    end
  end
  if not self.lastId and #data == 0 then
    -- first poll on an empty channel: nothing to remember yet
  end
  return out
end

--- On first start we do not want to replay the channel history: remember
--- the newest id without acting on anything.
function discord:syncCursor()
  if not self:canRead() then return false end
  local code, resp = self:http("GET", discord.API .. "/channels/" .. self.channel .. "/messages?limit=1")
  if not code or code < 200 or code >= 300 then return false end
  local data = json.decode(resp)
  if type(data) == "table" and data[1] and data[1].id then self.lastId = data[1].id end
  return true
end

return discord
