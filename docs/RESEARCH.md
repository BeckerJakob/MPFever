# MPFever – Research notes: game state, determinism and desyncs

This file records what we learned about Transport Fever 3 while building MPFever. It covers how the game keeps its state, why games drifted apart, what has to be synchronised, and where the work stands. It is for contributors; players only need [README.txt](README.txt).

Game build studied: **40420** (Steam). Addresses are RVAs of `TransportFever3.exe` for that build. They change with every game update, so `native/mpfever_native.cpp` checks the bytes before patching anything.

Last update: 2026-10-11 (MPFever 0.3.5).

---

## 1. How MPFever keeps games together

MPFever is a **lockstep** mod. Every player runs the full game, and only the players' **inputs** travel:

- construction tool commands;
- vehicle purchases;
- lines and settings.

Each game applies those inputs at the same simulation step. The world itself (towns, industries, people, cargo, money flows) is never sent. Each game computes it again.

This only works if the engine is **deterministic**: the same savegame plus the same inputs at the same steps must give the same world on every PC. When it is not, games drift apart (a *desync*). The host then compares state hashes and, if needed, reloads its own savegame on every client (a *resync*).

The main question of this research was therefore: **what in the engine is not deterministic, and what does that mean for what must be synced?**

---

## 2. What we learned about the engine

### Threads and timing

- **Main thread.** `CGame::Sync` runs every 200 ms, whatever the game speed. It swaps the command list: commands added by the interface reach the simulation only at that swap.
- **Simulation thread.** `CGame::RunGameSimLoop` runs one iteration per simulation **step** (200 ms of game time). Before each step it applies the queued commands ("Simulation Thread: Apply Command").
- **Command kinds.** Commands carry a kind byte:
  - 52 = WorldBuildProposal (every construction tool);
  - 42 = VehicleBuy;
  - 57 = PerformSimulationSteps;
  - 27 = ScriptingSendEvent.

  Kind 52 also covers previews: those are applied "directly", outside the loop.
- **Two game-state objects.** The engine keeps two game-state objects and copies one into the other at every iteration (`GameState::Replicate`, 0x255e60). The interface reads one copy while the simulation writes the other.
- **ECS.** All world data lives in an entity–component system.
  - `ecs::Engine::AddEntity` is at 0x2bb8940 and `RemoveEntity` at 0x2bbc700.
  - Freed entity ids are reused first-in first-out (a deque at engine+0xd8..0xf8). Otherwise a new id equals the size of the entity table.
  - During play, every add and every remove happens on the simulation thread. So entity ids stay identical across games only as long as every add and remove happens in the same order.

### The "local player"

- The game state holds one word at **+0x20C**: the player (company) this PC plays.
- In co-op mode it is the same on every PC.
- In separate-companies mode each PC wants its own company there, but 59 places in the exe read that word, some of them on the simulation thread. A game playing another company then simulated differently.
- The native module now hooks every one of those 59 reads (`native/sites20c.h`):
  - the simulation thread always reads the savegame's company (the *canon*);
  - the interface (tools, windows, money checks) reads the player's own company.
- **Money checks.** The engine never refuses a build for lack of money: the check is made by the tool in the interface (0xccfbd0). It is redirected to the player's own company.

### Lua

- The game's scripts run in Lua **5.2.2** (towns, industries, construction scripts, game mechanics).
- They run inside the simulation, on the simulation thread.
- See section 3: this turned out to be the main cause of desyncs.

---

## 3. The main cause of desyncs (found 2026-10-11)

**Lua 5.2.2 seeds its string hash randomly in every process.**

- `lua_newstate` calls `makeseed` (0x2fc8fe0), which mixes `_time64()` with a few memory addresses.
- The result is stored in the Lua state (`g->seed`) and used to hash every string.
- So the order in which `pairs()` walks a table with string keys **differs on every PC and every launch**.

The game's scripts walk such tables and act in that order. As a result:

1. towns pick different buildings to grow, upgrade or remove;
2. a new industry placed by the game gets its internal lanes numbered differently;
3. entity ids are then reused in a different order;
4. people, cars, cargo, pollution, happiness and money drift apart.

This is exactly the "towns grow differently" report (issue #7).

**Fix.** At load time, `PatchLuaSeed` in the native module replaces `makeseed` with `mov eax, 'MPFV'; ret`, before the engine creates any Lua state.

- Every game now uses the same seed, so every table is walked in the same order.
- Set `MPFEVER_LUASEED=0` to disable the patch for tests.
- The patch is only applied when the expected bytes are found, so another game build is left alone.

**Results on the savegame of a report ("Test Multi 3"):**

| Test | Before | After |
|---|---|---|
| Two games, no input, compared every few hundred steps | the 32-part hash differs after 1600–1900 steps; the full census differs after 100–400 steps | identical for 5400 steps (18 min of game time), 3 runs out of 3; all 116 714 entity adds and removes in the same order |
| 10-minute session at x4 | towns drift | 61 checks out of 61 identical |
| Separate companies: buy, line, road, stop, resync | drift | in sync, 0 desyncs, 0 refused actions |

### Causes ruled out on the way

- **Wall clock and pauses.** Pauses of 60 s of real time between steps changed nothing.
- **Processor count and thread scheduling.** No effect once the seed was fixed; MPFever never limits CPU cores.
- **The interface reading game data.** Heavy reads by the census did not change the simulation once the seed was fixed.
- **Money.** Already corrected by the host, and not a cause of divergence.

### Terrain edits and timing (found 2026-10-11, fixed in 0.3.5)

A real game showed the towns drifting right after a client's terrain edit, then a client crash when the host demolished a street bus terminal.

- **The crash** is an engine assertion in `ecs::TransportNetworkSystem::EntityToBeRemoved`, `AreAllNodesEmpty` (0xb6fd30). Decompiled, it does not check vehicles: every node of the removed entity's transport network must have no port left, i.e. no other entity may still be connected to it. With different towns, something of the client's town was still connected to the terminal; the host's removal plan did not include it.
- **The drift.** The terrain tool (`UI::TerrainModifier`) cannot be held like the other tools: it reads back the handle of its command, which a held command leaves empty (that crashed in 0.2.8). So the edit is applied at once at its author's game time, and another game that is already a few steps further applies it late (2 steps in the report). Every terrain edit lowers the reputation of the nearest town, so the towns took that change at different steps.
- **Fix.** The construction menu builds a terrain tool's action through `construction_react_util.getActionParams`; MPFever watches it in the interface. While a player has a terrain tool in hand (or made an edit in the last minute), that game leads: the others stay behind it by twice the overshoot reserve, and get every edit before its time. If two players use one, the more recent user leads.
- **Exact stops, two older imprecisions found on the way.** Approaching an action's time, a game could run on at speed when the action waited just past the barrier. It also asked for its exact steps while the simulation was still running: the interface sees the simulation clock only at the 200 ms handshake, so a clock still for 12 frames proves nothing. Both are fixed: exact steps whenever an action is near, and a stopped simulation means 0.45 s of real time without its clock moving.
- **Checked.** Twelve edits in a row by the host and by the client at x4 all land at the same step on the other game; every check is identical.

### Stops on a street cut by a road (found 2026-10-11, fixed in 0.3.5)

A client crashed (access violation in `ecs::CatchmentAreaSystem::EndModification` → `station_util::GetTerminalPersonEdges`) when the host built a road across a street where the client had put a pair of bus stops.

- **Stop replay.** The stop tool removes the node configurations of the segment's two junctions and puts new ones back (`nodeConfigsToAdd`); the replay removed them and never put any back. Right after each pair of stops, the host had 4 fewer node configurations than the client (`nodeConfigs` part of the check). Fixed: the replay adds the tool's configurations. Replaying the report's two stops on its savegame now gives exactly the client's value.
- **Road across a street with stops.** The tool's native proposal moves the existing stops (edge objects) onto the new segments.
  - A script proposal (`SimpleProposal`) cannot do that. Without the objects, the stops stay on the removed segment and the game crashes in their catchment area.
  - With them, the engine asserts while adding a component the stop already has (`Find(components, compTypeIndex) == components.end()`).
  - A rebuilt native proposal is refused (`lc.segment0 not found`) or, given the node configurations, hangs the game.

  The fix is to rebuild it exactly as a construction placed against a street is rebuilt (`replayNativeStreet`). The removed segments and nodes come from the engine's own removal proposal (`makeSegmentsRemoveProposal`), not from the capture. The tool's node configurations and id maps are added on top (`C.rebuildNativeWithConstruction` with no construction). Checked with the client's road of a later report: the same number of new segments, all the stops kept. If even that is refused, the build is reported as not reproduced and the host's game is reloaded; the script forms are never tried (`C.movesObjects`). Reloading was the first fix, but every such road a player built then vanished.

### Line routes on the map (2026-10-11, not fixed yet)

`UI::LineViewer::Update` (0x7f7180) draws the lines of one player, looked up in a per-player table (0xad3840), the player being a field of the viewer (+0x28). The viewer is made in 0x29f9d50, whose read of the player word at 0x29f9f14 takes it from an object of the interface's own (not one of the two game states), holding the savegame's company. On a client playing another company, the routes of its own lines flashed and vanished. 0x29f9f14 is now a "UI object" site like the tool factory: off the simulation thread, the savegame's company read there becomes the player's. Each company should see the routes of its own lines only, as in a solo game. A real game showed that this is not enough: the client's routes still flash and vanish. The next lead is the other reads of the player word made while the routes are drawn or refreshed (another viewer, or the simulation-side line data sent to the interface).

---

## 4. Tools built for this research

All of them are off by default and switched on by environment variables of `MPFever.exe --autotest`.

| Tool | Switch | What it does |
|---|---|---|
| Determinism test | `MPFEVER_SCENARIO=det`, `MPFEVER_DET_SCHEDULE=0,20,100,...`, `MPFEVER_DET_PAUSE=s` | Both games load the same savegame paused. They run exactly N steps, then their hashes are compared. This repeats for each value of the schedule. |
| Full census | `MPFEVER_CENSUS=1` (or a list of component types), `MPFEVER_CENSUS_FROM=n`; also the `census` scenario | Dumps every component of every entity (about 60 component types) to `census_<tag>.txt` in the session folder. The transport network is summarised (a full dump took 26 min). Render-only components are left out. |
| Entity watch | `MPFEVER_ENTWATCH=1`, `MPFEVER_ENTLOG=1` | Hooks AddEntity and RemoveEntity, counts them per thread and can write the full sequence (`entseq.txt`) to compare between games. |
| Word-read counters | always on, reported in `native.log` | Counts the readings of the local-player word per site and per thread. |
| Static analysis | (offline) | `re/retool.py` (pefile and capstone) and a Ghidra headless project, used to decompile the engine functions named here. |

A census comparison script (host vs client, per component type, first differing fields) was used alongside. It will be added to `tests/` once cleaned up.

---

## 5. What must be synchronised

### Co-op (one company for everybody)

With the seed fixed, **only the players' inputs need to be synced**. Everything else follows from them:

| Data | How it stays the same |
|---|---|
| Roads, tracks, stations, depots, buildings, bulldozing | The construction command is replayed at the same step (kind 52, native replay) |
| Vehicles, lines, assignments, line settings | The action is replayed at the same step |
| Game speed, pause | Set by the host for every game |
| Towns (growth, buildings, happiness), industries (production, new industries), stocks | Computed by the game: deterministic since the seed fix |
| People, cars, cargo, routes | Computed by the game: deterministic |
| Pollution and noise (emission grid), traffic | Computed by the game: deterministic |
| Money | Computed by the game, and corrected by the host as a safety net |
| Terrain | Copied cell by cell by the native module (tools whose replay is not exact) |
| Ground paint | **Not synced yet** (cosmetic, no effect on the simulation) |

The state hash and resync stay as a safety net: a player's own mods, a different game build or a lost message can still break determinism.

### Separate companies (one company per player)

The world is shared. What differs is **who owns what** and **who pays**. Census component types:

| Category | Components / data | Rule |
|---|---|---|
| **Per company** (one per player, the same in every game) | `PLAYER` and its `ACCOUNT` (money, loans), `LOG_BOOK` (income and costs), `PLAYER_OWNED` on stations, depots, edges, vehicles and lines, `COLOR`, `NAME` of the company | Created by an action (company join) at the same step everywhere; every action carries its company; money is checked per company by the host |
| **Owned objects** | `LINE`, `TRANSPORT_VEHICLE`, `VEHICLE_DEPOT`, `STATION`, `STATION_GROUP`, `MAINTENANCE_COST` | Built or bought with the owner the player chose; maintenance charged to that owner |
| **Shared world** | `TOWN`, `TOWN_BUILDING`, `INDUSTRY`, `STOCK_LIST`, `SIM_PERSON*`, `SIM_CARGO`, `SIM_ENTITY_*`, `MOVE_PATH`, `LAND_VEHICLE`, `EMISSION_GRID`, `BASE_EDGE`/`BASE_NODE` of the street network, `TRANSPORT_NETWORK`, `WORLD`, `GAME_TIME`, `GAME_SPEED` | Computed by the game, the same as in co-op |
| **Game scripts that assume one company** | loans, contracts (subventions), company growth, achievements, notifications | On the simulation side they see the canon company only. Loans are reimplemented per company in MPFever. Contracts of other companies are ignored for now. |
| **Interface only** (may differ per PC, must never reach the simulation) | the local-player word (+0x20C) as the interface sees it, tool owner, money check, windows, money popups (account positions of other companies) | Redirected by the native module; cleared before the interface copy |
| **MPFever data** | shared station fees (`shares.txt`), company list (`companies.txt`) | Replayed as actions; part of the hash |

### Known remaining differences (no effect observed)

- **`BASE_NODE_CONFIG` crosswalk order.** On about 50 junctions the crosswalk lists hold the same elements in a different order. This comes from the C++ side, probably a container keyed by pointers. No effect on traffic was observed, and the hash compares counts only.
- **`GAME_TIME.tickCount`** (offset 4) counts rendered frames, not steps, so it differs from one PC to another. The simulation does not seem to use it; not yet proven.
- **One rare divergence.** Seen once, around step 1200 of a long census run (ids of pollution emitters, tiny float differences in town pollution). Not reproduced since; still being watched.

---

## 6. Progress and next steps

Done:

- [x] Lockstep of every construction tool, vehicles and lines (0.1 – 0.2)
- [x] Terrain copy, resync from the host's savegame, join while running (0.2)
- [x] Separate companies: registry, per-company money, loans, owners, shared stations with fees (0.3.0 – 0.3.4)
- [x] Simulation and interface split for the local-player word (59 hooked reads) (0.3.4)
- [x] **Main desync cause found and fixed: the Lua string hash seed** (0.3.4)
- [x] Full-state census and entity watch, to find any future divergence quickly (0.3.4)
- [x] In-game MPFever window: players, link and sync state, opened from the pause menu (0.3.4, thanks to SlikerDev)
- [x] Terrain edits at the same step everywhere (terrain tool lead), exact stops at x4 (0.3.5)
- [x] In-game chat (0.3.5, thanks to SlikerDev)

Next:

- [ ] Long real games (2+ players, both modes) to confirm the fix outside the test savegame
- [ ] Check that player-built constructions (stations, depots, industries placed by scripts of mods) stay deterministic over hours
- [ ] Find whether the simulation ever reads `GAME_TIME.tickCount`
- [ ] Explain the crosswalk order, and fix it if it ever matters
- [ ] A lighter continuous check: hash only what can drift (entity count and order, money, town and industry summaries) instead of the 32 parts
- [ ] Contracts, company growth and achievements per company
- [ ] Ground paint
- [ ] Separate companies: the client's line routes still flash and vanish on the map (0x29f9f14 alone did not fix it)
