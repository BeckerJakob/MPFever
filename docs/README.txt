MPFever - Multiplayer for Transport Fever 3
Version 0.3.23
===========================================

MPFever lets several players play the same Transport Fever 3 world together, each one
in their own copy of the game, over the internet or a local network: either all in the SAME
company, or each player with their OWN company.

MPFever IS STILL IN ACTIVE DEVELOPMENT. You may meet bugs, pauses or a crash now and then. Keep
backups of the savegames you play with, and please send feedback (see "Reporting a
problem" below).


WHAT WORKS
----------
- Two ways to play, chosen by the host in the multiplayer window when hosting:
  - "One company for everybody": all players manage the SAME company (shared money,
    vehicles, lines).
  - "One company per player" (STILL IN DEVELOPMENT: many bugs remain to be fixed; use it
    mainly to test it and help the development of the mod): every player has their own company on the same map: own
    money, own roads, stations, depots, vehicles and lines, each company with its own
    colour (the lines a company creates take its colour, a little darker for each new
    one). The host plays the company of the savegame, every other player gets a new company
    with a starting capital (2,000,000 by default; write  companystart=1000000  in
    mpfever_settings.txt, next to MPFever.exe, to change it) the first time it is seen. The
    company belongs to the player's STEAM ACCOUNT (and name): after a reconnection, a
    resynchronisation, or in a later session on the same savegame, the player finds their
    company again, with everything they built, even if they changed their name. While a
    player is away, nobody else owns their company. The company name is the one of the
    player's company in the game (editable in the company window).
  - Every window of a station, depot, vehicle, line or building says on its first line which
    company owns it ("Owner: ..."; "(you)" for your own).
  - Contracts (subsidies): the offers are the same for everybody; a contract belongs to the
    company that accepts it (only its own vehicles count for it, the reward goes to it) and
    each player only sees their own contracts and the offers they did not decline.
  - Loans: every company has its own loans (offers, loans taken, monthly payments).
  - Shared stations: every station or stop is shared with the other companies from the start,
    for $100 per stop. In the station's window, its owner chooses the fee in a list
    ("Not shared", or $100 to $50,000 per stop). The other companies' lines may only stop at stations that are
    shared; each time one of their vehicles stops there, they pay the fee to the owner. The
    line windows show the fee next to the name of every other company's station.
- Start from the game itself: MPFever.exe starts Transport Fever 3, and a
  "MULTIJOUEUR / MPFever" button in the main menu opens the multiplayer window.
  - Host: pick one of your savegames (any of them, even one made without MPFever: the mod
    adds no content to the game, it only synchronises) and open the lobby. If the game uses
    other mods, every player must have the same ones installed: the lobby lists them and
    shows each player those missing on their PC.
  - Mods: MPFever is not made for other mods yet. Mods that only add content (vehicles,
    buildings...) usually work. Mods that change the game by themselves (rename lines,
    assign terminals, change colours...) do it on each game separately and break the
    synchronisation: play without them. Mod authors who want their mod to work with
    MPFever are welcome to get in touch (GitHub issues).
  - Lobby: the players join it in the main menu and see who is there. The host starts the
    game when everybody is there: every game loads the host's savegame at the same time.
  - Join: type the host's IP address. The host's game is received and loaded
    automatically (no file to send). Joining a session already running works too.
  - Steam invitations: friends can join from your Steam friends list.
- Everything a player builds or changes appears in the other games at the same moment:
  roads (all road types, with trees and other decorations), tracks, tram tracks laid on
  roads, rail signals, noise barriers, bus and tram stops, stations, depots (also those
  built against a street), buildings, terrain edits, trees and plants of the brush (new,
  see the limits), the bulldozer, vehicle purchases, lines and vehicle assignments, game
  speed and pause. The dust cloud of a construction going up is shown on every game.
- The host is the authority: every 10 seconds the games compare their state (money,
  loans, company, contracts, towns, industries, cargo in buildings and vehicles,
  vehicles, roads, road decorations...).
  - Money differences are corrected automatically.
  - Any other lasting difference triggers an automatic RESYNCHRONISATION: the game
    pauses, the host's game is saved and sent to every player, everybody reloads it,
    and the game resumes (about 20 seconds).
  - A build one game cannot reproduce makes the host resynchronise at once.
- If the connection is lost, the player's MPFever reconnects by itself (for 5 minutes).
- Dedicated server (NEW, in development): a PC of its own can run the world for everybody,
  without the PC of one of the players (MPFever.exe --server or start-server.bat). The world
  waits while nobody is connected, is saved every 10 minutes and survives a crash of the
  game. Players join its address as they join a host, with its password if it has one.
  It comes as a separate archive, MPFever-<version>-server.zip (see SERVER.txt in it).
- MPFever window in the game: open the pause menu (Esc) and click the MPFever card. It shows
  the players and their link (connected, behind, not responding, loading the host's game,
  left), whether the games are in sync and, for the host, a button to invite Steam friends.
  It stays open while you play; move it or close it as any game window.
- Chat in the game: the "Chat" card of the pause menu (or the button of the MPFever window)
  opens a chat window to write to the other players; new messages show for a few seconds
  at the left of the screen.
- The mod is built into the game: the only additions to the game interface are the
  MPFever button in the main menu and the MPFever and Chat cards in the pause menu.
- Since 0.3.4 the games stay identical much longer: the main cause of the desyncs (the
  game's own scripts did not take their decisions in the same order on every PC) is fixed.
  Resynchronisations should now be rare.


KNOWN LIMITATIONS
-----------------
- Separate companies: the level (rank, permits) of the savegame's company is shared by all the
  companies; the company actions of the Company window (market campaigns, greening, industry
  prospecting) only work for the host's company for now (the other players' requests are
  ignored); there is no money transfer between companies yet. Depots cannot be shared. The map
  shows the routes of your own company's lines only.
- The tutorial is not supported: its missions are validated on each game separately, so the
  games diverge (a unique building made by one player blocks the other's task). Play a game
  without the tutorial.
- Each build waits about 1 to 2 seconds before it appears: the games apply every
  construction at the same game time, which needs a safety margin.
- When a road upgrade moves several town buildings, the town may place one extra
  building differently on each game; the automatic resynchronisation then corrects it
  after a few seconds.
- Terrain editing (raising / lowering the ground) is copied to the other games: the game
  where you edit sends the new ground, the others apply it at the same game time (or a
  step later when they were already past it). If the copy fails the host's game is
  reloaded for everybody (automatic resynchronisation).
- Trees and plants of the brush are copied (since 0.3.3). Ground PAINT (textures) is not copied
  yet: each game keeps its own paint (it does not cause a resynchronisation).
- Tested with 2 players. More players should work but are untested.
- Windows only. Made for the current Steam version of Transport Fever 3 (builds 40408 and 40420).
  After a game update, the mod still runs but synchronisation may be worse until
  MPFever is updated.
- The host's port is opened on its router by itself (UPnP, else NAT-PMP) while a session
  runs, and closed again afterwards: the launcher's log says whether it worked. When the
  router has no public address of its own (CGNAT: the log says so), nobody outside can
  reach the host over IPv4: use IPv6, a dedicated server elsewhere, or a virtual LAN
  (Radmin VPN, ZeroTier, Tailscale, Porthole). Write  upnp=0  in mpfever_settings.txt to
  leave the router alone.
- IPv6: the host also accepts players over IPv6, and Steam invitations carry its IPv6
  address as well. A host behind DS-Lite (no public IPv4 address of its own, as on many
  cable connections) is reached that way when the joining player has IPv6 too and the
  host opens TCP port 28090 for IPv6 on its router. To join by hand, type the address
  in brackets: [2a02:...]:28090. Write  ipv6=0  in mpfever_settings.txt to leave it out
  of invitations.


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
MPFever connects to the address you type (or the one of the Steam invitation you accept).
The only other connections:
- At startup, before the game starts, and every 30 minutes, it asks GitHub
  (api.github.com) for the newest MPFever release. A newer one is installed by itself:
  at startup at once (downloaded from github.com/dkdknight/MPFever/releases, checked,
  MPFever's files replaced, your mpfever_settings.txt and logs kept, MPFever started
  again); found later, when you close the game; a dedicated server installs it and
  restarts once nobody is connected. Every player needs the same version, so everybody
  gets it this way. Write  autoupdate=ask  in mpfever_settings.txt (next to MPFever.exe)
  to be asked first, or  autoupdate=0  to disable the check.
- When the host's router supports UPnP or NAT-PMP, it asks the router to open the
  session's port, and to close it again afterwards (upnp=0 to disable).
- When you host, it asks api.ipify.org (a public service that answers with your public IP
  address, nothing else is sent) so that the address given to Steam invitations works from
  the internet. Write  lookupip=0  in mpfever_settings.txt (next to MPFever.exe) to disable
  this; invitations then carry your local address.

UNINSTALL: delete winhttp.dll and steam_appid.txt from the game folder, delete the
folder mods\mpfever_1 in your Transport Fever 3 user folder, and delete the MPFever
folder. The full source code is public (see the mod page).


REPORTING A PROBLEM
-------------------
The easiest: "Report a problem (logs)" in the MPFever window of the game (pause menu), or
"Report a problem" in the launcher window. MPFever puts every log into a zip file (folder
"reports" next to MPFever.exe), shows it in the Explorer and opens a new GitHub issue with
its text filled in: describe what you did and when, drag the zip into the issue, send.
After a crash of the game MPFever offers it by itself. The other players can send theirs
the same way. The game rewrites its own log at every start: MPFever keeps a copy (in the
session folder when the game closes, and logs\stdout-previous.txt before it starts it).
By hand, attach:
1. the newest file from the "logs" folder next to MPFever.exe (launcher-....log);
2. the folders %TEMP%\mpfever\Host-... or Client-... of that session (zip them);
3. if the game crashed: the newest files of
   C:\Program Files (x86)\Steam\userdata\<your id>\3493540\local\crash_dump\

CREDITS
-------
- dkdknight: author and maintainer.
- SlikerDev: the launcher's design, MPFever in the 13 languages of the game, the in-game
  MPFever window, the in-game chat and the fee list of the station windows.
- Thanks to every tester who reported a problem with their logs.


See INSTALL.txt to get started and ROADMAP.txt for what comes next.

Enjoying MPFever? Support the project or thank its author on Ko-fi: https://ko-fi.com/knighthd
