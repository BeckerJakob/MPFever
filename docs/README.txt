MPFever - Multiplayer for Transport Fever 3
Version 0.1.1-experimental
===========================================

MPFever lets several players run the same Transport Fever 3 company together, each one
in their own copy of the game, over the internet or a local network.

THIS IS AN EXPERIMENTAL VERSION. Expect bugs, pauses and the occasional crash. Keep
backups of the savegames you play with, and please send feedback (see "Reporting a
problem" below).


WHAT WORKS IN 0.1
-----------------
- Cooperative play: all players manage the SAME company (shared money, vehicles, lines).
- Everything a player builds or changes appears in the other games at the same moment:
  roads and tracks (new roads, joins in the middle of a road, upgrades), bus and tram
  stops (also on tram tracks without sidewalks), stations, depots, buildings, the
  bulldozer, vehicle purchases, lines and vehicle assignments, game speed and pause.
- The host is the authority: every 10 seconds the games compare their state (money,
  loans, company, contracts, towns, industries, cargo in buildings and vehicles,
  vehicles, roads...).
  - Money differences are corrected automatically.
  - Any other lasting difference triggers an automatic RESYNCHRONISATION: the game
    pauses, the host's game is saved and sent to every player, everybody reloads it,
    and the game resumes (about 20 seconds).
- The mod is built into the game: no extra button in the game interface. Everything is
  driven by the small MPFever.exe window.
- Direct connection by IP address (host and join).


KNOWN LIMITATIONS
-----------------
- Only cooperative mode (one shared company). Separate companies come later.
- Every player must load THE SAME savegame file before starting (the host sends their
  .sav file to the others; see INSTALL.txt). Automatic transfer at join is planned.
- Joining a session that is already running is not possible yet: everybody connects,
  loads the save, then the host starts the game.
- Vehicles can drift apart a little after road building; the automatic
  resynchronisation fixes it (at most once every 2 minutes).
- No Steam invites yet: connection by IP address only (port forwarding or a virtual LAN
  such as Radmin VPN, ZeroTier or Tailscale).
- Tested with 2 players. More players should work but are untested.
- Windows only. Made for the current Steam version of Transport Fever 3 (build 40408).
  After a game update, the mod still runs but synchronisation may be worse until
  MPFever is updated.


WHAT MPFEVER CHANGES ON YOUR PC
-------------------------------
- It copies winhttp.dll into the game folder. The game loads it by itself at startup,
  the same way well-known mod loaders work. This small module passes every network
  call of the game unchanged to Windows' own winhttp.dll, and only does something when
  the game was started by MPFever.exe: in a normal solo game it is inactive. It lets
  MPFever synchronise the game's own construction tools precisely.
- It writes a file steam_appid.txt in the game folder (so that the game can be started
  directly, several times on one PC).
- It adds the mod to the game's default mod list in settings.lua (a backup is kept as
  settings.lua.bak_mpfever).
- It installs the mod files in your Transport Fever 3 user mods folder.
MPFever does not connect anywhere except to the address you type.

UNINSTALL: delete winhttp.dll and steam_appid.txt from the game folder, delete the
folder mods\mpfever_1 in your Transport Fever 3 user folder, and delete the MPFever
folder. The full source code is public (see the mod page).


REPORTING A PROBLEM
-------------------
Please describe what you did, what you expected and what happened, and attach:
1. the newest file from the "logs" folder next to MPFever.exe (launcher-....log);
2. the folders %TEMP%\mpfever\Hote-... or Client-... of that session (zip them);
3. if the game crashed: the newest files of
   C:\Program Files (x86)\Steam\userdata\<your id>\3493540\local\crash_dump\

See INSTALL.txt to get started and ROADMAP.txt for what comes next.
