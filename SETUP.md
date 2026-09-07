# Setup: parts list and install

Everything below is for **one controller + one breeding cell**. Add one more "breeding cell" block per extra cell.

## 1. Download onto an OpenComputers computer

The computer or robot needs an **Internet Card**. `wget` fetches one file; `install.lua` fetches the rest.

Controller:

```
wget -f https://raw.githubusercontent.com/v3rysp3d/GTNH-Auto-Bees/main/install.lua /tmp/install.lua
/tmp/install.lua https://raw.githubusercontent.com/v3rysp3d/GTNH-Auto-Bees/main
```

Robot (run from the robot's own shell, it has a screen and keyboard if you assembled it with them,
otherwise plug a keyboard into an adjacent screen... simplest is to give the robot a T1 screen + keyboard):

```
wget -f https://raw.githubusercontent.com/v3rysp3d/GTNH-Auto-Bees/main/install.lua /tmp/install.lua
/tmp/install.lua https://raw.githubusercontent.com/v3rysp3d/GTNH-Auto-Bees/main robot
```

No internet card on the robot? Install on the controller, copy `/usr/lib/bb`, `/usr/bin/beecell.lua` and
`/etc/beecell.cfg` to a floppy, and copy them onto the robot from a Disk Drive it was assembled with.

Files land in `/usr/lib/bb/`, `/usr/bin/`, and `/etc/`. Re-running the installer overwrites the code but keeps
existing configs.

Then:

```
survey                      # controller: reads the game, writes /home/beebreeder/catalog.txt and needs_global.txt
edit /etc/beebreeder.cfg    # controller: interface addresses, cell biome, stations, Discord
edit /etc/beecell.cfg       # robot: cell name, housing type
beectl                      # controller
beecell                     # robot   (echo beecell >> /home/.shrc to autostart)
```

## 2. Parts list

### Data source (once)

| Item | Count | Notes |
|---|---|---|
| Bee House (Forestry) | 1 | any Forestry housing works; it only supplies `getBeeBreedingData()` |
| OC Adapter | 1 | touching the Bee House, cabled to the controller |

### Controller computer (once)

| Item | Count | Notes |
|---|---|---|
| Computer Case T3 | 1 | T2 works for a single cell; T3 leaves room for more cells and cards |
| CPU T3 | 1 | component limit 16; a Server Rack with Component Buses if you go past ~6 cells |
| Memory T3.5 | 2 | the planner holds the whole mutation graph in RAM |
| Hard Disk T2 or T3 | 1 | OpenOS + data |
| EEPROM (Lua BIOS) | 1 | |
| Graphics Card T3 | 1 | |
| Screen T3 | 1+ | a multiblock screen is nicer; T3 gives the 160x50 text grid |
| Keyboard | 1 | |
| Wireless Network Card T2 | 1 | or wired OC cable to every robot |
| Internet Card | 1 | wget and Discord |
| Disk Drive + OpenOS floppy | 1 | to install the OS once |
| OC Power Converter or Charger power | 1 | any EU/RF source |

### Breeding cell (per cell)

Housing:

| Item | Count | Notes |
|---|---|---|
| GT Industrial Apiary | 1 | HV machine. Auto-Queen ON, item output facing the chest on top, speed lock on |
| Speed upgrade | 1 | tier of your choice: speed 5 = 32x at 8,192 EU/t, speed 6 = 64x at 32,768 EU/t |
| Lifespan upgrade | 4 | divides queen lifespan by about 5 |
| Light, Sky, Seal upgrade | 1 each | queen works in any light/weather; evicted automatically if climate needs the slot |
| Chest | 1 | on top of the housing, receives princess, drones and combs |
| Dirt (or any block) | 1 | placeholder foundation directly under the housing |
| Flowers of the target species' flower types | some | inside the queen's territory |
| HV power | | plus whatever the speed upgrade adds |

Climate upgrade pool (shared by all cells through the ME network, installed per job):

| Item | Count | Notes |
|---|---|---|
| Heater upgrade | 16 | +0.25 temperature each |
| Cooler upgrade | 16 | |
| Humidifier upgrade | 16 | |
| Dryer upgrade | 16 | |
| Hell emulation upgrade | 1 | Hellish temperature without a Nether station |
| Desert / Plains / Jungle / Winter / Ocean emulation | 1 each | only for biome-type conditions |

Robot (assembled in the Electronics Assembler):

| Item | Count | Notes |
|---|---|---|
| Computer Case T2 (T3 recommended) | 1 | T2 has 3 tier-2 + 3 tier-1 upgrade slots, T3 has 3+3+3 |
| CPU T2 | 1 | |
| Memory T2 | 2 | |
| Hard Disk T1 | 1 | with OpenOS installed |
| EEPROM (Lua BIOS) | 1 | |
| Beekeeper Upgrade | 1 | GTNH-only OC item, tier 2 slot |
| Inventory Controller Upgrade | 1 | tier 2 slot |
| Inventory Upgrade | 2 | 16 slots each; 32 working slots keeps big generations comfortable |
| Wireless Network Card T2 | 1 | |
| Graphics Card T1 + Screen T1 + Keyboard | 1 each | optional, but you will want to see the robot's console |
| Disk Drive | 1 | optional, to install OpenOS from a floppy directly on the robot |
| Pick (tool slot) | 1 | foundation swaps wear it; a self-repairing or high-durability pick |
| OC Charger + lever | 1 | next to the robot's parking spot; charge speed follows the redstone level |

Interfaces (per cell):

| Item | Count | Notes |
|---|---|---|
| ME Interface (block) | 2 | one above the robot column (honey, blocks, upgrades), one below (bee library) |
| OC Adapter | 2 | one touching each interface |
| Database Upgrade T1 | 2 | one in each Adapter |
| ME cable | | both interfaces on the ME network |
| OC cable | | both adapters on the controller's OC network |

### Physical layout of a cell

```
   y+2   [Main ME Interface][Adapter+DB]
   y+1   [Robot column: air]   [Chest]        <- chest sits on top of the housing
   y     [Robot parks here ]   [Industrial Apiary]   [Charger + lever] behind the robot
   y-1   [Robot column: air]   [foundation block]
   y-2   [Bee ME Interface][Adapter+DB]
```

The robot only moves straight up and down inside its column. Keep the three column blocks free.

### Consumables

| Item | Rate | Source |
|---|---|---|
| Honey Drop | 2 to 5 per generation | centrifuged combs; stocked in the main interface, slot 1 |
| Foundation blocks | 1 per distinct block, reusable | AE2 patterns; `survey` writes the full list to `needs_global.txt` |
| Pick durability | 1 per foundation swap | |
| EU | HV + speed upgrade draw | |

### Later: remote stations

Per dimension or biome-ID station: Apiary, Transposer, Adapter, EnderStorage chest pair, and an OpenComputers
P2P tunnel pair on the quantum-linked ME network. Not supported by the code yet.
