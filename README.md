# MPFever – Multiplayer for Transport Fever 3

Experimental cooperative multiplayer for Transport Fever 3: several players run the same company, each in their own game, connected over the internet or a local network.

The game starts from `MPFever.exe`; a multiplayer button in the main menu lets you host one of your savegames or join a host by IP address (the host's game is received automatically). Steam invitations are supported. Roads, tracks, signals, stations, depots, buildings and the other construction tools are replicated exactly in every game.

Player documentation is in [`docs/`](docs/): [README](docs/README.txt), [INSTALL](docs/INSTALL.txt), [ROADMAP](docs/ROADMAP.txt) and [CHANGELOG](docs/CHANGELOG.txt).

## How it works

| Part | Folder | Role |
|---|---|---|
| Launcher | `launcher/` (C#, .NET Framework 4.8, WinForms) | Hosts or joins a session over TCP and starts the game. It installs the mod and the native module, relays player actions, compares the games' state and runs resynchronisations from the host's savegame. |
| Game mod | `mod/mpfever_1/` (Lua) | Game script and UI hook. It captures player actions and replays them in every game at the same game time (barrier lockstep). It computes state checksums, corrects money, and saves or loads for resynchronisation. It does nothing unless the game was started by the launcher. |
| Native module | `native/` (freestanding C++, no CRT) | Built as `winhttp.dll` and placed in the game folder, where the game loads it itself (the game imports `WINHTTP.dll`). Every WinHTTP call is passed unchanged to the system library. With an MPFever session only, it hooks the game's command queue so that construction tool commands run at the same game time in every game. It stays inert on any other game build. |
| Tests | `tests/` (Python + pytest + lupa) | Unit tests of the Lua modules, N simulated games running the real Lua files (mocked relay, native module and network), offline checks of the game executable, end-to-end runs with real games (`test.bat`). |

The launcher and the game talk through files in a per-session folder (`%TEMP%\mpfever\...`): `in.log` and `out.log`, plus control files. No process injection is used.

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
test.bat
```

Creates `.venv` (pytest, lupa, hypothesis) on the first run, then runs the offline levels (unit + simulated games).
`test.bat native` checks the installed game against the native module, `test.bat e2e` runs two real game instances.
Levels, harness and conventions: [`docs/dev/TESTING.md`](docs/dev/TESTING.md); measured baseline and findings:
[`docs/dev/BASELINE.md`](docs/dev/BASELINE.md); the 2.0 plan: [`docs/dev/PLAN.md`](docs/dev/PLAN.md).

## Status

Experimental (0.2.5). The game builds supported by the native module are 40408 and 40420 (Steam). See [`docs/ROADMAP.txt`](docs/ROADMAP.txt).
