# MPFever – Multiplayer for Transport Fever 3

Experimental multiplayer for Transport Fever 3. Several players play the same world, each in their own copy of the game, over the internet or a local network. They play either:

- in **one shared company** (co-op);
- or **each with their own company**. This second mode is still in development and has many bugs: use it to test and help.

The game starts from `MPFever.exe`. A multiplayer button in the main menu lets you open a lobby with one of your savegames or join a host by IP address. The players gather in the lobby, then the host starts the game and every game loads it at the same time; the host's game is received automatically. Joining a game already running works too, and Steam invitations are supported.

A world can also run on a **dedicated server** (`MPFever.exe --server`): a PC of its own runs the world, nobody plays on it, and the players join it as they join a host. See [SERVER](docs/SERVER.txt).

Enjoying MPFever? You can support its development on [Ko-fi](https://ko-fi.com/H2H717LY5N).

Player documentation is in [`docs/`](docs/): [README](docs/README.txt), [INSTALL](docs/INSTALL.txt), [SERVER](docs/SERVER.txt), [ROADMAP](docs/ROADMAP.txt) and [CHANGELOG](docs/CHANGELOG.txt). What we learned about the engine, the causes of desyncs and what must be synchronised in each mode is in [RESEARCH](docs/RESEARCH.md).

## Features

- **Two ways to play**, chosen by the host:
  - "One company for everybody": shared money, vehicles and lines.
  - "One company per player": own money, roads, stations, depots, vehicles, lines, loans and contracts, and a colour per company. The company belongs to the player's Steam account and is found again after a reconnection.
- **Everything is replicated exactly** in every game, at the same game time:
  - roads, tracks, tram tracks, signals, stops, stations, depots, buildings;
  - terrain edits, trees of the brush, the bulldozer;
  - vehicle purchases, lines, game speed and pause.
- **Shared stations** (separate companies). Every station is shared at $100 per stop by default. Its owner sets the fee in the station window, from a list. Other companies' lines stop there and pay the fee.
- **In-game MPFever window**, opened from a card in the pause menu. It shows:
  - the players and their link (connected, behind, not responding, loading, left);
  - the sync state;
  - for the host, Steam invites.

  It stays open while playing.
- **In-game chat**, from a card in the pause menu. New messages show for a few seconds at the left of the screen.
- **Host authority.** The games compare their state every 10 seconds. Money is corrected at once. A lasting difference reloads the host's game for everybody (about 20 seconds).
- **Joining and reconnecting.** Joining a session already running works. A lost connection reconnects by itself for 5 minutes.
- **Dedicated server** (separate archive, `MPFever.exe --server`), in the spirit of the Minecraft, Satisfactory and Factorio servers:
  - the world runs on a PC of its own, without the PC of a player, and waits while nobody is connected;
  - settings in `mpfever_server.properties`: world, port, password, players at most, company mode, message of the day;
  - autosave with backups, restart of the game after a crash or a freeze, players reconnected by themselves;
  - a console in the server window: `status`, `say`, `save`, `pause`, `speed`, `kick`, `resync`, `restart`, `stop`.
- **In the game's 13 languages.** The launcher and the in-game windows follow the language of Transport Fever 3.

## Getting started

1. Download `MPFever-<version>.zip` from the [releases](https://github.com/dkdknight/MPFever/releases) and unzip it anywhere. Every player needs the same version.
2. Start `MPFever.exe`: it finds the game, installs the mod and starts Transport Fever 3.
3. In the game's main menu, click **Multiplayer (MPFever)**. The host opens a lobby with one of their savegames; the others join the host's address or accept a Steam invitation.
4. The host clicks **Start the game**, and every game loads it.

Details, ports and troubleshooting: [INSTALL](docs/INSTALL.txt). Dedicated server: [SERVER](docs/SERVER.txt).

## Reporting a problem

Please open an [issue](https://github.com/dkdknight/MPFever/issues) with the files below. **Without logs, a desync or a crash can rarely be found**; with them, most bugs are fixed in the next version.

### 1. Say what happened

- Your **MPFever version** (shown in the title of the MPFever window) and the **company mode** (one company, or one per player).
- **What you did** just before: built a station, bulldozed a road, bought a vehicle...
- **At what time**, on your clock. The logs are timed, so the time lets us find the moment.
- Who was the host, how many players there were, and whether it happens again.

### 2. Send the logs, of every player if you can

Close the game first, since some files are only complete then. Then zip:

| What | Where |
|---|---|
| **Session folder** of the game in question (the newest one) | `%TEMP%\mpfever\<name>-<time>-<id>\`. Paste `%TEMP%\mpfever` in the Explorer address bar. |
| **Launcher log** | `logs\launcher-<date>-<time>.log`, in the folder where `MPFever.exe` is. |
| **Game log** | `C:\Program Files (x86)\Steam\userdata\<number>\3493540\local\crash_dump\stdout.txt`. It is rewritten each time the game starts: copy it **before** starting the game again. |
| After a **crash** | In the same `crash_dump` folder, the newest `.dmp` file; in `local\save\`, the `crash_<world>_<date>.sav` the game wrote. |

The host's files matter most: they hold the checks of every game. The files of the player who built or bulldozed something show what that player's game did.

### 3. Send the savegame, ideally

With the savegame, we can replay the problem on two games here, which is the fastest way to a fix.

- The world you played: `C:\Program Files (x86)\Steam\userdata\<number>\3493540\local\save\<world>.sav`, with its `.jpg`.
- After a resynchronisation, also `MPFever resync.sav` from the same folder: the world as every game reloaded it.

Savegames are often larger than GitHub's 25 MB limit. Upload the zip to Google Drive, Dropbox, WeTransfer or similar, and put the link in the issue. If the savegame uses mods, list them.

## How it works

| Part | Folder | Role |
|---|---|---|
| Launcher | `launcher/` (C#, .NET Framework 4.8, WinForms) | Hosts or joins a session over TCP and starts the game. It installs the mod and the native module, relays player actions and the session status, compares the games' state and runs resynchronisations from the host's savegame. With `--server` it runs a dedicated server (`Server.cs`): it hosts one world by itself, saves it, restarts the game when needed and has a console. |
| Game mod | `mod/mpfever_1/` (Lua) | Game script and UI hook. It captures player actions and replays them in every game at the same game time (barrier lockstep). It computes state checksums, corrects money, manages the companies and shared stations, and saves or loads for resynchronisation. It draws the multiplayer page of the main menu and the in-game MPFever window. It does nothing unless the game was started by the launcher. |
| Native module | `native/` (freestanding C++, no CRT) | Built as `winhttp.dll` and placed in the game folder, where the game loads it itself (the game imports `WINHTTP.dll`). Every WinHTTP call is passed unchanged to the system library. With an MPFever session only, it does three things: it holds construction commands so they run at the same step in every game, it copies terrain edits, and it splits the "local player" between the simulation and the interface. It also fixes the Lua hash seed. It stays inert on any unknown game build. |
| Tests | `tests/` (Python + lupa) | Language file check (`test_lang.py`), and two simulated games running the real Lua bridge (`test_lockstep.py`). |

The launcher and the game talk through files in a per-session folder (`%TEMP%\mpfever\...`): `in.log` and `out.log`, plus control and status files. No process injection is used.

## Building from source

Requirements:

- Windows 10/11.
- Visual Studio 2022 or later, with these workloads:
  - **Desktop development with C++**;
  - **.NET desktop development**, including the .NET Framework 4.8 targeting pack.

From the repository folder, run:

```bat
build.bat
```

It builds:

1. `native\out\winhttp.dll` (via `native\build.bat`);
2. `launcher\bin\Release\MPFever.exe` (MSBuild);
3. the release archive `release\MPFever-<version>.zip` (with `release\dist\MPFever\`).

The release archive contains the launcher, `winhttp.dll`, the mod folder and the player documentation, exactly as published.

## Running the tests

```bat
pip install lupa
python tests\test_lang.py
python tests\test_lockstep.py
```

`test_lockstep.py` has not been updated for the companies module (0.3.x) yet and currently stops at start-up.

`MPFever.exe --selftest` checks the relay and the client without the game: messages between two simulated games, and the dedicated server's settings file and who it lets in (password, version, players at most, kick).

The real tests run two games on one PC: `MPFever.exe --autotest <savegame>`, with scenarios chosen by environment variables. See [RESEARCH](docs/RESEARCH.md) for the determinism test and the census.

## Status

Experimental (0.3.13). Supported game builds:

- **40420**, the current Steam version: supported, with the Lua seed fix.
- **40408**: supported, but the Lua seed fix is only applied on 40420.

See [`docs/ROADMAP.txt`](docs/ROADMAP.txt).

## Support the project

MPFever is free and open source, developed on free time. If you enjoy playing Transport Fever 3 with your friends and want to help the development, you can support it on Ko-fi:

[![Support MPFever on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/H2H717LY5N)

Testing and reporting problems with your logs helps just as much: thank you!

## Credits

- **[dkdknight](https://github.com/dkdknight)** – author and maintainer.
- **[Steelworm](https://github.com/Steelworm)** – contributor: build timing fixes and the experimental builder lead, detailed issue analyses.
- **[SlikerDev](https://github.com/SlikerDev)** – contributor (dedicated server, IPv6, connection fixes):
  - the redesigned launcher window and its icon;
  - the translation of MPFever into the 13 languages of the game (the launcher follows the game's language);
  - the in-game MPFever window (pause-menu card, players, sync state, Steam invites);
  - the in-game chat;
  - the fee list of the station windows.

Thanks to everyone who tests MPFever and reports problems in the [issues](https://github.com/dkdknight/MPFever/issues) (see [Reporting a problem](#reporting-a-problem)): every report with logs helped find a bug.

MPFever is not affiliated with Urban Games. Transport Fever 3 is a trademark of its owners.
