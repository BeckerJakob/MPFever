# MPFever and mods

Every player of a session needs **the same mods, in the same version** as the host. MPFever 0.3.25 checks it:

- In a lobby, the multiplayer page lists the mods of the host's savegame. The ones to fix come first, in red:
  - **missing**: not installed on your PC;
  - **other version than the host's**: installed, but its files differ from the host's (update it, or ask the host to);
  - **incompatible**: known to break a session.
- In the host's lobby, a player whose mods differ shows as « (different mods) ».
- A player with a missing mod or another version cannot load the host's game. The page says which mods to install or update.

The version is compared from the mod's files (their paths, sizes and the contents of its scripts), found where the game installs mods: mod.io (`C:\Users\Public\mod.io`), the Steam Workshop and your own mods folder. A mod whose folder MPFever cannot find is not compared; the game still says whether it is installed.

> **TPF3-MP is incompatible with MPFever.** It is another multiplayer mod: turn it off in the mods of the savegame (when loading it) before hosting or joining with MPFever.

## What MPFever knows of each mod

| Shown as | Meaning |
|---|---|
| *(nothing)* | Models, vehicles, buildings, streets, interface, or game data changed at load. No risk known, as long as everybody has the same version. |
| **made compatible** (green) | A mod that used to break sessions; MPFever 0.3.25 makes it work. |
| **untested script** (orange) | The mod has a script that acts on the game by itself. It may work, or make the games drift apart: MPFever then reloads the host's game for everybody. |
| **incompatible** (red) | Known to break a session. Turn it off for multiplayer. |

## Mods seen in issue reports (October 2026)

| Mod | Status | Why |
|---|---|---|
| Auto Line Namer | made compatible | Its script renames lines on each game at moments chosen by the computer's clock: the line names differed between games ([#58](https://github.com/dkdknight/MPFever/issues/58)). Since 0.3.25 only the host's game renames; the names apply on every game at the same step. Tested. |
| Auto Color Lines | made compatible | Same as above for line colours. Tested. |
| Auto Assign Terminals | made compatible | Same mechanism for the terminals of a line (line updates). |
| Auto Signals | made compatible | Adds signals after a signal is placed. The other games replay the placed signal; since 0.3.25 the mods are told that a replayed build was not made by a player there, so only the game where the signal was placed adds the signals, and the others replay them. Tested with the real tool (2026-10-22). |
| Industry Evolution, Era Industries: Oil Platform, Military Production, Real Track Cant, Improved Destination Displays, ACCAD NEXUS, Cargo & Passenger Station Range, Parallel Tracks, Parallel Roads, Advanced Track Patterns, Fence Assets | untested script | Scripts that build, book money or change stocks by themselves. Their commands run on every game at the same step; they stay in sync only if the mod decides the same thing everywhere. |
| TPF3-MP | **incompatible** | Another multiplayer mod: it changes the same things as MPFever, and a game where it is active keeps desynchronising. **Turn it off in the savegame's mods before playing with MPFever.** MPFever 0.3.25 shows a red box in the lobby and a window at start when it is installed. |
| Vehicles, wagons, trams, buildings, stations, streets, tracks, assets (ModWerkstatt, MaikC, ACCAD assets, Classic/Early packs...) | no risk known | Content only. |
| Dark UI, Doubleclick To Edit, Easy Terminal Assignment, Disable Unreachable Terminals, Highlight Preferred Terminal, Industry Boosts at a Glance, Traffic Jam Analyzer, Better Minimap, Drive-in Warehouses | no risk known | Interface, or data changed at load. Their commands, when they send any, go through MPFever like the player's. |

## How MPFever 0.3.25 handles mod scripts

- **Line names, colours and line updates sent by a mod's simulation script** are taken from the host's game only and applied on every game at the same step, like a player's command. The other games drop their own. Expert setting: « Mods' line names, colours and terminals sent by the host only ».
- **A build replayed for another player** is announced to the mods' scripts as not made by a player on that game, so a mod that answers a player's build (adds signals, fences...) does it once, on the builder's game. The game's own scripts are not changed. Expert setting: « Replayed builds shown to mods as made elsewhere ».

## Mod authors

If your mod renames, recolours or changes things on its own, it helps to decide on the game time (`api.engine.getComponent(world, GAME_TIME)`) rather than `os.time` / `os.clock`, which differ on every PC. Get in touch through the [issues](https://github.com/dkdknight/MPFever/issues).
