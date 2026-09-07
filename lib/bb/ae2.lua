-- bb.ae2 : Applied Energistics 2 helpers (OpenComputers GTNH fork API).
--
-- Network component: any of me_interface / me_controller / me_exportbus /
-- me_importbus reached through an Adapter. Verified calls:
--   getItemsInNetwork(filter)      filter matches top-level stack fields (name, label, damage ...)
--   getCraftables(filter)          -> craftables; c.getItemStack(), c.request(n) -> status
--   store(filter, dbAddress, startSlot, count)  copy matching network stacks into a Database upgrade
--   me_interface.setInterfaceConfiguration(slot, dbAddress, entry, size)  keep `size` of the db entry in `slot`
--   me_interface.setInterfaceConfiguration(slot)                          clear that slot
local util = require("bb.util")
local genome = require("bb.genome")

local ae2 = {}
ae2.__index = ae2

ae2.networkComponents = { "me_interface", "me_controller", "me_exportbus", "me_importbus" }

--- Locate a network-capable component. `component` is the OC component library.
function ae2.findNetwork(component, preferred)
  if preferred and component.type(preferred) then return component.proxy(preferred) end
  for _, name in ipairs(ae2.networkComponents) do
    local addr = component.list(name)()
    if addr then return component.proxy(addr) end
  end
  return nil
end

--- me: network proxy; db: database proxy (optional, needed for stocking)
function ae2.new(me, db)
  return setmetatable({ me = me, db = db, dbSize = db and 9 or 0 }, ae2)
end

function ae2:setDatabase(db, size)
  self.db = db
  self.dbSize = size or 9
end

function ae2:items(filter)
  local ok, res = pcall(self.me.getItemsInNetwork, filter)
  if not ok or type(res) ~= "table" then return {} end
  return res
end

function ae2:count(filter)
  local n = 0
  for _, st in ipairs(self:items(filter)) do n = n + (st.size or 0) end
  return n
end

function ae2:countLabel(label)
  return self:count({ label = label })
end

--- All bee stacks in the network (princess/drone/queen).
function ae2:bees()
  local out = {}
  for _, itemName in ipairs({ "Forestry:beePrincessGE", "Forestry:beeDroneGE", "Forestry:beeQueenGE" }) do
    for _, st in ipairs(self:items({ name = itemName })) do
      if genome.isBee(st) then out[#out + 1] = st end
    end
  end
  return out
end

function ae2:craftable(label)
  local ok, res = pcall(self.me.getCraftables, { label = label })
  if not ok or type(res) ~= "table" then return nil end
  return res[1]
end

function ae2:hasPattern(label)
  return self:craftable(label) ~= nil
end

--- Request a craft. Returns the status object (isDone()/isCanceled()/hasFailed()) or nil, err.
function ae2:craft(label, amount)
  local c = self:craftable(label)
  if not c then return nil, "no pattern for " .. tostring(label) end
  local ok, status = pcall(c.request, amount or 1)
  if not ok then return nil, tostring(status) end
  return status
end

--- Ask the ME network to keep `count` of the first stack matching `filter`
--- in interface slot `slot`. Uses database entry `dbSlot` (default 1).
function ae2:stockIntoInterface(iface, slot, filter, count, dbSlot)
  if not self.db then return false, "no database upgrade configured" end
  dbSlot = dbSlot or 1
  pcall(self.db.clear, dbSlot)
  local ok, res = pcall(self.me.store, filter, self.db.address, dbSlot, 1)
  if not ok then return false, "store failed: " .. tostring(res) end
  local okGet, entry = pcall(self.db.get, dbSlot)
  if not okGet or entry == nil then return false, "nothing in the network matches " .. util.serialize(filter) end
  local okCfg, resCfg = pcall(iface.setInterfaceConfiguration, slot, self.db.address, dbSlot, count or 1)
  if not okCfg or resCfg == false then return false, "setInterfaceConfiguration failed: " .. tostring(resCfg) end
  return true, entry
end

function ae2:clearInterfaceSlot(iface, slot)
  local ok = pcall(iface.setInterfaceConfiguration, slot)
  return ok
end

--- Library view: species -> { drones = n, princesses = n, queens = n, hybrids = n, unanalyzed = n }
--- Only analyzed, pure-bred bees count towards drones/princesses.
function ae2:library()
  local lib = {}
  local function bucket(name)
    lib[name] = lib[name] or { drones = 0, princesses = 0, queens = 0, hybrids = 0, unanalyzed = 0 }
    return lib[name]
  end
  for _, st in ipairs(self:bees()) do
    local kind = genome.kind(st)
    local species = genome.displaySpecies(st) or "?"
    local b = bucket(species)
    if not genome.analyzed(st) then b.unanalyzed = b.unanalyzed + (st.size or 1)
    elseif not genome.isPureAny(st) then b.hybrids = b.hybrids + (st.size or 1)
    elseif kind == "drone" then b.drones = b.drones + (st.size or 1)
    elseif kind == "princess" then b.princesses = b.princesses + (st.size or 1)
    elseif kind == "queen" then b.queens = b.queens + (st.size or 1) end
  end
  return lib
end

return ae2
