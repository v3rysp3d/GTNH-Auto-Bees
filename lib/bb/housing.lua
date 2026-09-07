-- bb.housing : per-housing-type drivers.
--
-- The planner only looks at `caps` (what a housing can satisfy); the robot
-- and the transposer station code look at `access` and `slots`.
-- Slot numbers are OpenComputers 1-based inventory slots.
local housing = {}

housing.types = {
  -- GregTech Industrial Apiary (GTNH). Robot access through the Beekeeper
  -- Upgrade (swapQueen/swapDrone act on the machine directly). Progress and
  -- canWork are NOT reported for this machine (dummy logic), so completion
  -- is detected from the queen slot and the output chest.
  gt_iapiary = {
    label = "GT Industrial Apiary",
    access = "robot",
    slots = { queen = 6, drone = 7 },      -- MTEIndustrialApiary: queen=5, drone=6 (0-based)
    outputs = "chest",                     -- machine auto-outputs into an adjacent chest
    caps = { mutations = true, foundation = true, climateUpgrades = true, biomeUpgrades = true, builtinAccel = true },
    reportsProgress = false,
  },
  -- Forestry Apiary. Slots: queen 1, drone 2, products 3-9, frames 10-12.
  apiary = {
    label = "Apiary",
    access = "any",
    slots = { queen = 1, drone = 2, outputs = { 3, 4, 5, 6, 7, 8, 9 }, frames = { 10, 11, 12 } },
    outputs = "self",
    caps = { mutations = true, foundation = true, climateUpgrades = false, worldAccelerator = true },
    reportsProgress = true,
  },
  -- Magic Bees Magic Apiary, same layout as the Apiary for our purposes.
  magic_apiary = {
    label = "Magic Apiary",
    access = "any",
    slots = { queen = 1, drone = 2, outputs = { 3, 4, 5, 6, 7, 8, 9 } },
    outputs = "self",
    caps = { mutations = true, foundation = true, climateUpgrades = false, worldAccelerator = true },
    reportsProgress = true,
  },
  -- Forestry Alveary. Any alveary block delegates to the controller.
  -- Foundation goes under the bottom-centre block.
  alveary = {
    label = "Alveary",
    access = "any",
    slots = { queen = 1, drone = 2, outputs = { 3, 4, 5, 6, 7, 8, 9 } },
    outputs = "self",
    caps = { mutations = true, foundation = true, climateUpgrades = false, alvearyClimate = true },
    reportsProgress = true,
  },
  -- Bee House: no mutations at all, only useful as the adapter target that
  -- provides getBeeBreedingData().
  bee_house = {
    label = "Bee House",
    access = "any",
    slots = { queen = 1, drone = 2, outputs = { 3, 4, 5, 6, 7, 8, 9 } },
    outputs = "self",
    caps = { mutations = false },
    reportsProgress = true,
  },
}

function housing.get(kind)
  local h = housing.types[kind]
  if not h then return nil, "unknown housing type '" .. tostring(kind) .. "'" end
  return h
end

function housing.kinds()
  local out = {}
  for k in pairs(housing.types) do out[#out + 1] = k end
  table.sort(out)
  return out
end

return housing
