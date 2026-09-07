-- Discord bridge over the internet card.
--
-- Webhook mode (a URL is all you need): rich embeds for events, a status
-- card that is refreshed by delete + repost, needs lists.
-- Bot mode (token + channel id): the same, plus commands polled from the
-- channel with GET /channels/{id}/messages?after=<lastId>.
-- Java's HttpURLConnection cannot send PATCH, so edits are delete + post.
local json = require("src.json")
local http = require("src.http")

local discord = {}
discord.__index = discord

discord.API = "https://discord.com/api/v10"
discord.userAgent = "DiscordBot (https://github.com/v3rysp3d/GTNH-Auto-Bees, 1.0)"
discord.username = "Auto Bees"

discord.colors = {
  info = 0x3498DB, start = 0x3498DB, phase = 0xF1C40F, done = 0x2ECC71,
  failed = 0xE74C3C, warn = 0xE67E22, status = 0x95A5A6, needs = 0xE67E22,
}

---@param internet table|nil  internet card proxy
---@param cfg table  { token, channel, webhook, pollLimit, lastId }
function discord.new(internet, cfg)
  cfg = cfg or {}
  local self = setmetatable({
    internet = internet,
    token = cfg.token, channel = cfg.channel, webhook = cfg.webhook,
    pollLimit = cfg.pollLimit or 20,
    lastId = cfg.lastId,
  }, discord)
  self.webhookId, self.webhookToken = discord.webhookParts(cfg.webhook)
  return self
end

---Split a webhook URL into id and token (nil, nil when it is not one).
function discord.webhookParts(url)
  if type(url) ~= "string" then return nil, nil end
  return url:match("/webhooks/(%d+)/([%w%-%_%.]+)")
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

---Build an embed. fields = { {name, value[, inline]} ... }
function discord.embed(kind, title, description, fields)
  local e = {
    title = title and tostring(title):sub(1, 250) or nil,
    description = description and tostring(description):sub(1, 4000) or nil,
    color = discord.colors[kind] or discord.colors.info,
    footer = { text = "GTNH Auto Bees" },
  }
  if fields and #fields > 0 then
    local list = json.array({})
    for _, f in ipairs(fields) do
      list[#list + 1] = { name = tostring(f[1]):sub(1, 250), value = tostring(f[2] == nil and "-" or f[2]):sub(1, 1000), inline = f[3] ~= false }
    end
    e.fields = list
  end
  return e
end

---Send a message payload (table). Returns message id, or true, or nil, err.
function discord:send(payload)
  if not self:enabled() then return nil, "discord disabled" end
  payload.allowed_mentions = { parse = json.array({}) }
  local code, resp
  if self.token and self.channel then
    code, resp = self:http("POST", discord.API .. "/channels/" .. self.channel .. "/messages", json.encode(payload))
  else
    payload.username = discord.username
    code, resp = self:http("POST", self.webhook .. "?wait=true", json.encode(payload))
  end
  if not code then return nil, resp end
  if code < 200 or code >= 300 then return nil, "http " .. code .. ": " .. tostring(resp):sub(1, 200) end
  local data = json.decode(resp)
  if type(data) == "table" and data.id then return data.id end
  return true
end

---Post plain text (split into chunks). Returns the last message id or true.
function discord:post(text)
  if not self:enabled() then return nil, "discord disabled" end
  local lastId
  for _, piece in ipairs(discord.chunk(text)) do
    local id, err = self:send({ content = piece })
    if not id then return nil, err end
    lastId = id
  end
  return lastId or true
end

---Post one embed (optionally with a text line above it).
function discord:postEmbed(embed, content)
  return self:send({ content = content, embeds = json.array({ embed }) })
end

---Delete a message we posted (bot or webhook).
function discord:deleteMessage(messageId)
  if not messageId or messageId == true then return false end
  local url
  if self.token and self.channel then
    url = discord.API .. "/channels/" .. self.channel .. "/messages/" .. messageId
  elseif self.webhookId then
    url = discord.API .. "/webhooks/" .. self.webhookId .. "/" .. self.webhookToken .. "/messages/" .. messageId
  else
    return false
  end
  local code = self:http("DELETE", url)
  return code ~= nil and code >= 200 and code < 300
end

---Replace a message: delete the old one, post the new payload. Returns the new id.
function discord:replace(messageId, payload)
  if messageId then self:deleteMessage(messageId) end
  return self:send(payload)
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
