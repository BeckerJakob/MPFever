# MPFever – Multiplayer for Transport Fever 3

Experimental multiplayer for Transport Fever 3. Several players play the same world, each in their own copy of the game, over the internet or a local network. They play either:

- in **one shared company** (co-op);
- or **each with their own company**. This second mode is still in development and has many bugs: use it to test and help.

The game starts from `MPFever.exe`. A multiplayer button in the main menu lets you open a lobby with one of your savegames or join a host by IP address. The players gather in the lobby, then the host starts the game and every game loads it at the same time; the host's game is received automatically. Joining a game already running works too, and Steam invitations are supported.

Enjoying MPFever? You can support its development on [Ko-fi](https://ko-fi.com/H2H717LY5N).

Player documentation is in [`docs/`](docs/): [README](docs/README.txt), [INSTALL](docs/INSTALL.txt), [ROADMAP](docs/ROADMAP.txt) and [CHANGELOG](docs/CHANGELOG.txt). What we learned about the engine, the causes of desyncs and what must be synchronised in each mode is in [RESEARCH](docs/RESEARCH.md).

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
- **In the game's 13 languages.** The launcher and the in-game windows follow the language of Transport Fever 3.

## What's new in 0.3.8

Three fixes from the GitHub issues (thanks to Zippo1578 and Steelworm):

- **The speed buttons show the session's speed** when another player changes it (#24).
- **Editing a large station no longer slows the other games down** for seconds per module (#25).
- **Double slip switches** can be set in a session (#26).

## What's new in 0.3.7

More fixes from the GitHub issues and from our own tests (thanks again to Steelworm), and IPv6 from SlikerDev:

- **No more crash when a street station is bulldozed:** the other games remove the station together with its entrance street (#15).
- **Rail signals keep the track as it is:** a signal in a tunnel no longer digs the tunnel out on the other games, and a signal no longer causes a reload (#16).
- **Builds and timing:**
  - a build made during a reload is dropped on every game, and the chat says so (#17);
  - builds are no longer released early after several reloads (#18);
  - quick successive edits of a station are replayed in order (#19);
  - a bulldozer is replayed with the bulldozer's own settings (#20).
- **A road joined to a street with bus stops** is now built on the other games too.
- **Separate companies:** a client's own line routes are drawn on the map.
- **Line manager:** copying vehicles no longer freezes the game for a second per vehicle part (#21), and "Send To Line" works fully again (#22).
- **Sessions:**
  - going back to the main menu ends the session;
  - a player joining right as the session starts gets the host's game.
- **The tutorial is not supported in multiplayer:** the chat warns when such a game is hosted.
- **IPv6** (thanks to SlikerDev): the host also accepts players over IPv6, which helps hosts without a public IPv4 address (DS-Lite).

## What's new in 0.3.6

Fixes from the GitHub issues (thanks to Steelworm and Shog-SC for their detailed analyses):

- **Builds made while the session is paused** (in the tutorial, for example) are sent to the other games again, and an action on a vehicle that was never bought no longer crashes a game (#12).
- **A difference found while applying an action** (something it refers to is missing) reloads the host's game at once, and the games are checked during a pause too (#12).
- **Rejoining from the main menu works:** "Cancel" ends the session, and a join or a Steam invitation from the main menu replaces what is left of an earlier session (#13).
- **Editing an existing street station** (adding a module to a terminal) is reproduced on the other games: its lines keep their stops (#14).
- **A session starts** even when one game ran a few steps more after loading (#4).
- **The native module builds** with recent Visual Studio toolsets (#4).

## What's new in 0.3.5

- **Terrain edits land at the same step on every game.** A terrain tool cannot be delayed on the game of the player who uses it, so a game slightly ahead used to apply the edit a few steps late. An edit changes the reputation of the nearest town, so the towns drifted apart and a later demolition could crash a game. While a player has a terrain tool in hand, the other games now stay just behind that player's game.
- **Actions arriving near a wait point are no longer one step late at x4.**
- **No more crash when a road is built across a street with another player's bus stops.** Stops are rebuilt with their junction settings, and a road that cuts a street carrying stops is rebuilt as the game's own tool makes it (the stops move to the new pieces of street).
- **Hosting works at the first click** (the multiplayer window ended the session it had just started), and the window closes again when the game loads.
- **Separate companies:** a terrain edit is paid by the company of the player who made it, on every game.
- **A simulation difference now reloads the host's game after 30 seconds** instead of 5 minutes, since the games no longer drift by themselves.
- **In-game chat** (thanks to SlikerDev).
- **Known issue (separate companies):** the routes of a client's own lines are not drawn on the map yet (they flash and vanish). The lines themselves work.

## What's new in 0.3.4

- **The main cause of desyncs is found and fixed.** The game's Lua 5.2.2 seeds its string hash with the clock and memory addresses, differently on every PC. So the game's own scripts walked their tables in a different order on each game:
  1. towns grew differently;
  2. new industries got their lanes numbered differently;
  3. then people, cars, pollution and money drifted apart.

  The native module now gives Lua the same seed on every game. Two games left alone now stay identical for 18 minutes of game time, every entity created and removed in the same order; before, they were apart after 6 minutes. See [RESEARCH](docs/RESEARCH.md).
- **Separate companies stay in sync.** The engine's "local player" is split between the simulation (the same company on every game) and the interface (the player's own company: tools, money checks, Finances window, line tool).
- **No more crash on resynchronisation, and no more duplicated vehicle purchases.**
- **New in-game MPFever window**, opened from the pause menu, and a fee list in the station windows.
- **Stations are shared by default.** The fee per stop is shown next to every other company's station name.
- **Diagnostic tools for developers:**
  - a full census of the game state compared between two games;
  - a watch on entity creation and removal.

The full list since 0.2.10 is in the [CHANGELOG](docs/CHANGELOG.txt).

## How it works

| Part | Folder | Role |
|---|---|---|
| Launcher | `launcher/` (C#, .NET Framework 4.8, WinForms) | Hosts or joins a session over TCP and starts the game. It installs the mod and the native module, relays player actions and the session status, compares the games' state and runs resynchronisations from the host's savegame. |
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

The real tests run two games on one PC: `MPFever.exe --autotest <savegame>`, with scenarios chosen by environment variables. See [RESEARCH](docs/RESEARCH.md) for the determinism test and the census.

## Status

Experimental (0.3.8). Supported game builds:

- **40420**, the current Steam version: supported, with the Lua seed fix.
- **40408**: supported, but the Lua seed fix is only applied on 40420.

See [`docs/ROADMAP.txt`](docs/ROADMAP.txt).

## Support the project

MPFever is free and open source, developed on free time. If you enjoy playing Transport Fever 3 with your friends and want to help the development, you can support it on Ko-fi:

[![Support MPFever on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/H2H717LY5N)

Testing and reporting problems with your logs helps just as much: thank you!

## Credits

- **[dkdknight](https://github.com/dkdknight)** – author and maintainer.
- **[SlikerDev](https://github.com/SlikerDev)** – contributor:
  - the redesigned launcher window and its icon;
  - the translation of MPFever into the 13 languages of the game (the launcher follows the game's language);
  - the in-game MPFever window (pause-menu card, players, sync state, Steam invites);
  - the in-game chat;
  - the fee list of the station windows.

Thanks to everyone who tests MPFever and reports problems in the [issues](https://github.com/dkdknight/MPFever/issues): every report with logs helped find a bug.

MPFever is not affiliated with Urban Games. Transport Fever 3 is a trademark of its owners.
