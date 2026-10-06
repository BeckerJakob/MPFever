MPFever - Multiplayer for Transport Fever 3
Version 0.2.5-experimental
===========================================

MPFever lets several players run the same Transport Fever 3 company together, each one
in their own copy of the game, over the internet or a local network.

THIS IS AN EXPERIMENTAL VERSION. Expect bugs, pauses and the occasional crash. Keep
backups of the savegames you play with, and please send feedback (see "Reporting a
problem" below).


WHAT WORKS
----------
- Cooperative play: all players manage the SAME company (shared money, vehicles, lines).
- Start from the game itself: MPFever.exe starts Transport Fever 3, and a
  "MULTIJOUEUR / MPFever" button in the main menu opens the multiplayer window.
  - Host: pick one of your savegames (any of them, even one made without MPFever).
  - Join: type the host's IP address. The host's game is received and loaded
    automatically (no file to send). Joining a session already running works.
  - Steam invitations: friends can join from your Steam friends list.
- Everything a player builds or changes appears in the other games at the same moment:
  roads (all road types, with trees and other decorations), tracks, tram tracks laid on
  roads, rail signals, noise barriers, bus and tram stops, stations, depots (also those
  built against a street), buildings, the bulldozer, vehicle purchases, lines and
  vehicle assignments, game speed and pause. The dust cloud of a construction going up
  is shown on every game.
- The host is the authority: every 10 seconds the games compare their state (money,
  loans, company, contracts, towns, industries, cargo in buildings and vehicles,
  vehicles, roads, road decorations...).
  - Money differences are corrected automatically.
  - Any other lasting difference triggers an automatic RESYNCHRONISATION: the game
    pauses, the host's game is saved and sent to every player, everybody reloads it,
    and the game resumes (about 20 seconds).
  - A build one game cannot reproduce makes the host resynchronise at once.
- If the connection is lost, the player's MPFever reconnects by itself (for 5 minutes).
- The mod is built into the game: the only addition to the game interface is the
  MPFever button in the main menu.


KNOWN LIMITATIONS
-----------------
- Only cooperative mode (one shared company). Separate companies come later.
- Each build waits about 1 to 2 seconds before it appears: the games apply every
  construction at the same game time, which needs a safety margin.
- When a road upgrade moves several town buildings, the town may place one extra
  building differently on each game; the automatic resynchronisation then corrects it
  after a few seconds.
- Tested with 2 players. More players should work but are untested.
- No player list or chat in the game yet.
- Windows only. Made for the current Steam version of Transport Fever 3 (build 40408).
  After a game update, the mod still runs but synchronisation may be worse until
  MPFever is updated.
- Without port forwarding on the host's box, players need a virtual LAN (Radmin VPN,
  ZeroTier, Tailscale) or Steam invitations will not reach the host.


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
