-- bb.climate : Forestry climate arithmetic for the GT Industrial Apiary.
--
-- Forestry classifies the biome temperature float as:
--   > 1.00 Hot, > 0.85 Warm, > 0.35 Normal, > 0.00 Cold, else Icy
--   Hellish only for Nether-type biomes (the Hell emulation upgrade)
-- and humidity as:  > 0.85 Damp, > 0.30 Normal, else Arid
-- GTNH Industrial Apiary upgrades move the value by 0.25 per heater/cooler/
-- humidifier/dryer, up to 16 of each.
local climate = {}

climate.temperatures = { "Icy", "Cold", "Normal", "Warm", "Hot", "Hellish" }
climate.humidities = { "Arid", "Normal", "Damp" }
climate.step = 0.25
climate.maxUpgrades = 16

local tempIndex, humIndex = {}, {}
for i, n in ipairs(climate.temperatures) do tempIndex[n] = i end
for i, n in ipairs(climate.humidities) do humIndex[n] = i end

function climate.tempIndex(name) return tempIndex[name] end
function climate.humIndex(name) return humIndex[name] end

function climate.classifyTemp(v)
  if v > 1.00 then return "Hot" end
  if v > 0.85 then return "Warm" end
  if v > 0.35 then return "Normal" end
  if v > 0.00 then return "Cold" end
  return "Icy"
end

function climate.classifyHum(v)
  if v > 0.85 then return "Damp" end
  if v > 0.30 then return "Normal" end
  return "Arid"
end

--- "BOTH_2" -> {up=2, down=2}; "UP_1" -> {up=1, down=0}; "NONE" -> {0,0}
function climate.parseTolerance(s)
  s = tostring(s or "NONE"):upper()
  local kind, n = s:match("^(%a+)_(%d)$")
  n = tonumber(n) or 0
  if kind == "BOTH" then return { up = n, down = n } end
  if kind == "UP" then return { up = n, down = 0 } end
  if kind == "DOWN" then return { up = 0, down = n } end
  return { up = 0, down = 0 }
end

--- Set of climate names a bee with base `baseName` and tolerance `tol` accepts.
function climate.tolerable(list, index, baseName, tol)
  local out = {}
  local b = index[baseName]
  if not b then return out end
  tol = tol or { up = 0, down = 0 }
  for i = math.max(1, b - tol.down), math.min(#list, b + tol.up) do out[list[i]] = true end
  return out
end

--- Minimal number of steps (positive = heat/humidify, negative = cool/dry)
--- to turn base value `v` into class `target` using `classify`. nil if impossible.
local function stepsTo(v, target, classify)
  if classify(v) == target then return 0 end
  for n = 1, climate.maxUpgrades do
    if classify(v + n * climate.step) == target then return n end
    if classify(v - n * climate.step) == target then return -n end
  end
  return nil
end

--- Solve the upgrade set for one job.
--- params = {
---   baseTemp = 0.8, baseHum = 0.4,                  -- the cell's biome values
---   needTemp = {min="Hot", max="Hot"} or nil,       -- from the mutation
---   needHum  = {min=..., max=...} or nil,
---   queenTemp = "Normal", queenTol = {up=1,down=1}, -- the princess's species + tolerance
---   queenHum  = "Normal", queenHumTol = {...},
--- }
--- returns { temperature=name, humidity=name, heater=n, cooler=n, humidifier=n, dryer=n, hell=bool }
--- or nil, reason
function climate.solve(p)
  local res = { heater = 0, cooler = 0, humidifier = 0, dryer = 0, hell = false }

  -- temperature ---------------------------------------------------------
  local allowedT = {}
  if p.needTemp then
    local lo, hi = tempIndex[p.needTemp.min] or 1, tempIndex[p.needTemp.max] or #climate.temperatures
    for i = lo, hi do allowedT[climate.temperatures[i]] = true end
  else
    for _, n in ipairs(climate.temperatures) do allowedT[n] = true end
  end
  if p.queenTemp then
    local ok = climate.tolerable(climate.temperatures, tempIndex, p.queenTemp, p.queenTol)
    for n in pairs(allowedT) do if not ok[n] then allowedT[n] = nil end end
  end
  local bestT, bestCost
  for name in pairs(allowedT) do
    local cost
    if name == "Hellish" then cost = 100 -- possible via Hell upgrade, but prefer not to
    else cost = stepsTo(p.baseTemp or 0.8, name, climate.classifyTemp) end
    if cost then
      local abs = math.abs(cost)
      if not bestCost or abs < bestCost then bestT, bestCost = name, abs end
    end
  end
  if not bestT then return nil, "no temperature satisfies both the mutation and the queen" end
  res.temperature = bestT
  if bestT == "Hellish" then res.hell = true
  else
    local n = stepsTo(p.baseTemp or 0.8, bestT, climate.classifyTemp)
    if n > 0 then res.heater = n elseif n < 0 then res.cooler = -n end
  end

  -- humidity ------------------------------------------------------------
  local allowedH = {}
  if p.needHum then
    local lo, hi = humIndex[p.needHum.min] or 1, humIndex[p.needHum.max] or #climate.humidities
    for i = lo, hi do allowedH[climate.humidities[i]] = true end
  else
    for _, n in ipairs(climate.humidities) do allowedH[n] = true end
  end
  if p.queenHum then
    local ok = climate.tolerable(climate.humidities, humIndex, p.queenHum, p.queenHumTol)
    for n in pairs(allowedH) do if not ok[n] then allowedH[n] = nil end end
  end
  local bestH, bestHCost
  for name in pairs(allowedH) do
    local cost = stepsTo(p.baseHum or 0.4, name, climate.classifyHum)
    if cost then
      local abs = math.abs(cost)
      if not bestHCost or abs < bestHCost then bestH, bestHCost = name, abs end
    end
  end
  if not bestH then return nil, "no humidity satisfies both the mutation and the queen" end
  res.humidity = bestH
  local nh = stepsTo(p.baseHum or 0.4, bestH, climate.classifyHum)
  if nh > 0 then res.humidifier = nh elseif nh < 0 then res.dryer = -nh end

  return res
end

--- Upgrade item counts needed for a solution, keyed by upgrade name.
function climate.upgradeCounts(sol)
  local out = {}
  if sol.heater > 0 then out.heater = sol.heater end
  if sol.cooler > 0 then out.cooler = sol.cooler end
  if sol.humidifier > 0 then out.humidifier = sol.humidifier end
  if sol.dryer > 0 then out.dryer = sol.dryer end
  if sol.hell then out.hell = 1 end
  return out
end

return climate
