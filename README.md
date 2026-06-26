# IKappaID PinkSlip

Vehicle title system for Project Zomboid Build 42. Claim vehicles into portable Pink Slip items, trade them, and redeploy later with full state capture.

| | |
|---|---|
| **Version** | 0.2.12 |
| **Target build** | B42.0+ |
| **Mod ID** | `IKappaIDPinkSlip` |
| **Author** | IKappaID & Faded |
| **Steam Workshop** | [3749738575](https://steamcommunity.com/sharedfiles/filedetails/?id=3749738575) |

## Overview

PinkSlip turns vehicle ownership into an inventory item. Claim a vehicle from the radial menu, store its complete state in a filled slip, and deploy it again later. Filled slips can be traded, stored, or looted like any other item.

## Features

- Full state capture: engine, parts, fuel, battery, and container contents
- Stable vehicle UID across claim and deploy cycles
- Server-authoritative validation for multiplayer
- Radial menu claim and configurable quick-deploy hotkey
- Sandbox options for claim distance, slip limits, and ownership rules

## Optional add-on

| Add-on | Repository | Purpose |
|--------|------------|---------|
| Pink Slip — Loot | [KappaID-Faded-s-PinkSlip-LOOTABLE-PINKSLIP-](https://github.com/fearthebest/KappaID-Faded-s-PinkSlip-LOOTABLE-PINKSLIP-) | Prefilled slips in world containers |

## Repository structure

```text
.
├── README.md
└── IKappaIDPinkSlip_v0.2.12/
    └── IKappaIDPinkSlip/          # Workshop upload package
        ├── workshop.txt
        ├── preview.png
        └── Contents/
            └── mods/
                └── IKappaIDPinkSlip/42/
                    ├── mod.info
                    └── media/
```

The versioned wrapper folder matches the packaged Workshop layout. Game files live under `Contents/mods/<mod_id>/42/`.

## Installation

1. Copy `IKappaIDPinkSlip_v0.2.12/IKappaIDPinkSlip/` to your Steam Workshop content folder, or extract `Contents/mods/IKappaIDPinkSlip` into `%UserProfile%\Zomboid\mods\`.
2. Enable **IKappaID PinkSlip** in the mod list.
3. Configure sandbox options on the server or in SP.

## Links

- **Steam Workshop:** https://steamcommunity.com/sharedfiles/filedetails/?id=3749738575
- **Support:** https://ko-fi.com/ikappaid

Community mod — not affiliated with or endorsed by The Indie Stone.
