# AGENTS.md

## Project Overview

This repository is a **Project Zomboid Build 42 game mod** ("KappaID & Faded's Pink Slips") written entirely in **Lua**. It adds a vehicle ownership/title system (Pink Slips) to the game. There is no build system, no package manager, no test framework, and no application server.

### Codebase structure

All mod source lives under:
```
IKappaIDPinkSlip_Backup_v0.2.11/IKappaIDPinkSlip/Contents/mods/IKappaIDPinkSlip/42/media/
```

- `lua/shared/IKappaIDPinkSlip_Shared.lua` — Constants, sandbox config accessors, vehicle serialization/deserialization
- `lua/server/IKappaIDPinkSlip_Server.lua` — Server-authoritative claim/deploy logic
- `lua/client/IKappaIDPinkSlip_Client.lua` — Client UI (radial menus, keybinds, quick-deploy button)
- `scripts/` — Item definitions and crafting recipes (`.txt` files)
- `sandbox-options.txt` — Server-configurable options

## Cursor Cloud specific instructions

### Development tools

- **Lua 5.4** is installed for syntax checking (`lua5.4`).
- **luacheck** (via luarocks) is the linter. It is the primary code quality tool for this codebase.

### Lint

Run luacheck with Project Zomboid API globals whitelisted (since these are only available inside the game engine):

```bash
luacheck IKappaIDPinkSlip_Backup_v0.2.11/IKappaIDPinkSlip/Contents/mods/IKappaIDPinkSlip/42/media/lua/ \
  --no-config --allow-defined-top --std lua54 \
  --globals isClient isServer getPlayer getCell getCore getTexture getMouseX getMouseY \
  getSpecificPlayer getPlayerRadialMenu getVehicleById addVehicleDebug instanceof \
  sendServerCommand sendClientCommand sendAddItemToContainer sendRemoveItemFromContainer \
  sendItemStats instanceItem HaloTextHelper ISButton ISVehicleMenu ISInventoryPane \
  IsoDirections Events Keyboard keyBinding SandboxVars VehicleUtils IKappaPinkSlip
```

Expected result: 0 errors. Warnings are limited to line-length (>120 chars) and one unused variable assignment — these are acceptable for PZ modding style.

### Syntax check

Parse-only check (no execution) for all Lua files:

```bash
for f in $(find IKappaIDPinkSlip_Backup_v0.2.11/ -name '*.lua'); do
  lua5.4 -e "local ok, err = loadfile('$f'); if ok then print('OK: '..('$f')) else print('FAIL: '..tostring(err)); os.exit(1) end"
done
```

### Running the Shared module standalone

The Shared module (`IKappaIDPinkSlip_Shared.lua`) can be loaded and tested outside the game engine:

```bash
lua5.4 -e "dofile('IKappaIDPinkSlip_Backup_v0.2.11/IKappaIDPinkSlip/Contents/mods/IKappaIDPinkSlip/42/media/lua/shared/IKappaIDPinkSlip_Shared.lua'); print(IKappaPinkSlip.MODULE_ID)"
```

The Server and Client modules cannot run standalone — they call PZ engine globals (`isClient()`, `isServer()`) on load and will error outside the game.

### Testing limitations

- There is no automated test suite. The mod can only be fully tested inside a running Project Zomboid Build 42 instance (not available in this VM).
- Standalone validation is limited to syntax parsing, linting, and loading the Shared module.
- No build step is needed — the codebase is plain Lua/text files loaded by the PZ engine.
