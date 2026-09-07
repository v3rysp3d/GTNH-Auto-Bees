-- Discord bridge over the internet card.
--
-- Outbound: bot token (POST /channels/{id}/messages) or a webhook URL.
-- Inbound : polling GET /channels/{id}/messages?after=<lastId> with the bot token.
-- Java's HttpURLConnection cannot send PATCH, so "edit" falls back to
-- delete + post when PATCH is rejected.
local json = require("src.json")
local http = require("src.http")

local discord = {}
discord.__index = discord

discord.API = "https://discord.com/api/v10"
discord.userAgent = "DiscordBot (https://github.com/v3rysp3d/GTNH-Auto-Bees, 1.0)"

---@param internet table|nil  internet card proxy
---@param cfg table  { token, channel, webhook, pollLimit, lastId }
function discord.new(internet, cfg)
  cfg = cfg or {}
  return setmetatable({
    internet = internet,
    token = cfg.token, channel = cfg.channel, webhook = cfg.webhook,
    pollLimit = cfg.pollLimit or 20,
    lastId = cfg.lastId,
  }, discord)
end

function discord:enabled()
  return self.internet ~= nil and ((self.token and self.channel) or self.webhook) and true or false
end

function discord:canRead()
  return self.internet ~= nil and self.token ~= nil and self.channel ~= nil
end

function discord:http(method, url, body)
  local headers = { ["User-Agent"] = discord.userAgent, Accept = "application/json" }
  if self.token and url:find(discord.API, 1, true) == 1 then headers.Authorization = "Bot " .. self.token end
  return http.request(self.internet, method, url, body, headers)
end

---Split a long text into Discord-sized pieces (limit 2000 chars).
function discord.chunk(text, limit)
  limit = limit or 1900
  local out, cur, len = {}, {}, 0
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

---Post a message. Returns the message id (bot) or true, or nil, err.
function discord:post(text)
  if not self:enabled() then return nil, "discord disabled" end
  local lastId
  for _, piece in ipairs(discord.chunk(text)) do
    local body = json.encode({ content = piece, allowed_mentions = { parse = json.array({}) } })
    local code, resp
    if self.token and self.channel then
      code, resp = self:http("POST", discord.API .. "/channels/" .. self.channel .. "/messages", body)
    else
      code, resp = self:http("POST", self.webhook .. "?wait=true", body)
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

---Edit a message in place; falls back to delete + post. Returns the (possibly new) id.
function discord:edit(messageId, text)
  if not self:canRead() then return nil, "edit needs a bot token" end
  if messageId then
    local body = json.encode({ content = text:sub(1, 1990) })
    local code = self:http("PATCH", discord.API .. "/channels/" .. self.channel .. "/messages/" .. messageId, body)
    if code and code >= 200 and code < 300 then return messageId end
    self:delete(messageId)
  end
  return self:post(text)
end

---Fetch new messages since the last poll, oldest first: { id, author, content, bot }.
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
  return out
end

---Remember the newest message id without acting on history.
function discord:syncCursor()
  if not self:canRead() then return false end
  local code, resp = self:http("GET", discord.API .. "/channels/" .. self.channel .. "/messages?limit=1")
  if not code or code < 200 or code >= 300 then return false end
  local data = json.decode(resp)
  if type(data) == "table" and data[1] and data[1].id then self.lastId = data[1].id end
  return true
end

return discord
