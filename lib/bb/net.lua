-- bb.net : tiny message protocol between the controller and the cell robots.
--
-- Wire format: modem.send(addr, port, "BB1", <serialized table>)
--   { t = "job", from = "cell1", seq = 12, p = { ... payload ... } }
-- Works over wireless (strength raised to 400) and wired networks, and
-- through AE2 OpenComputers P2P tunnels since those carry the OC network.
local util = require("bb.util")

local net = {}
net.__index = net

net.TAG = "BB1"
net.MAX_PACKET = 7800 -- OC default maxNetworkPacketSize is 8192

function net.new(modem, port, name)
  local self = setmetatable({ modem = modem, port = port or 7311, name = name or "node", seq = 0 }, net)
  if modem then
    pcall(modem.open, self.port)
    if modem.isWireless and modem.isWireless() then pcall(modem.setStrength, 400) end
  end
  return self
end

function net:encode(msgType, payload)
  self.seq = self.seq + 1
  local s = util.serialize({ t = msgType, from = self.name, seq = self.seq, p = payload })
  if #s > net.MAX_PACKET then
    util.warn("net: message %s is %d bytes, over the packet limit", msgType, #s)
  end
  return s
end

function net:send(addr, msgType, payload)
  if not self.modem then return false, "no modem" end
  local ok, res = pcall(self.modem.send, addr, self.port, net.TAG, self:encode(msgType, payload))
  if not ok then return false, tostring(res) end
  return res ~= false
end

function net:broadcast(msgType, payload)
  if not self.modem then return false, "no modem" end
  local ok, res = pcall(self.modem.broadcast, self.port, net.TAG, self:encode(msgType, payload))
  if not ok then return false, tostring(res) end
  return true
end

--- Decode a "modem_message" signal. Returns msg or nil.
--- signal: "modem_message", localAddr, remoteAddr, port, distance, tag, data
function net:decode(name, _, remoteAddr, port, distance, tag, data)
  if name ~= "modem_message" or port ~= self.port or tag ~= net.TAG or type(data) ~= "string" then return nil end
  local t = util.unserialize(data)
  if type(t) ~= "table" or not t.t then return nil end
  return { type = t.t, from = t.from, seq = t.seq, payload = t.p or {}, remote = remoteAddr, distance = distance }
end

return net
