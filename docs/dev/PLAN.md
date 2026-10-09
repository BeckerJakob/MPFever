# MPFever 2.0 – Umsetzungsplan

> Ausgangsbasis: Repository `BeckerJakob/MPFever`, Stand `b36f48d` (0.2.10-experimental, 09.10.2026).
> Ziel: Zwei (später mehr) Spieler fühlen sich wie **gemeinsam auf einer Karte** – sie sehen sich gegenseitig,
> Aktionen erscheinen praktisch sofort, Abweichungen werden still repariert statt mit 20-Sekunden-Pausen.
> Grundregel dieses Plans: **Erst Tests, dann Code.** Jede Phase beginnt mit Testfällen, die zunächst rot sind,
> und endet mit einem Abnahme-Gate, das lokal auf dem Entwicklungsrechner ausgeführt wird.

---

## Umsetzungsstand

### Phase 0 – Testfundament und Baseline ✅ (09.10.2026)
- [x] T0.1 alter Lockstep-Test als pytest (Mock korrigiert, Befund F3)
- [x] T0.2 `MPFever.exe --selftest`
- [x] T0.3 Serializer inkl. Property-Test
- [ ] T0.4 C#-`LuaLit` ↔ Lua-Serializer – verschoben: braucht Test-Einstieg im Launcher (Rust-Port, Phase 4/11)
- [x] T0.5–T0.8 `valueHash`, `before`, `pacing`/Stempel, Entity-Referenzen
- [x] T0.9 3 Spiele, T0.10 Netzwerk-Emulation + Ausweichpfad ohne DLL
- [x] T0.11 Spiel-Exe vs. Native-Modul, T0.11b Lua-Probe im Spiel
- [x] T0.12–T0.14 E2E: Session mit allen Szenarien, Speed 4, pausiert, KPIs
- [ ] T0.15 Dauerlauf – vorbereitet (`test.bat soak`), noch nicht gelaufen
- [x] Baseline + Befunde F1–F13: [BASELINE.md](BASELINE.md)

### Phase 1 – Lua-Bridge modularisieren ✅ (09.10.2026)
- [x] Bridge (5041 Zeilen) in Teile mit gemeinsamer Umgebung zerlegt (`mpfever_br_*.lua`, Werkzeug `tools/dev/split_bridge.py`);
      `mpfever_bridge.script.lua` lädt nur noch die Teile (44 Zeilen)
- [x] Autotest-Szenarien ausgelagert (`mpfever_dev_autotest1-3.lua`), geladen nur mit `MPFEVER_AUTOTEST=1`/`MPFEVER_SAVE`
      (der Launcher setzt `MPFEVER_AUTOTEST=1` bei `--dev`/`--autotest`)
- [x] `mpfever_common.lua` geteilt (Nachbau von Proposals → `mpfever_proposal.lua`); größtes Produktionsmodul 730 Zeilen
- [x] Verbindungsschicht `mpfever_link.lua` (Kanäle out/in/ui/results/bindings/native_ctl/native_events; Datei- und
      Speicher-Implementierung mit gemeinsamem Vertrag) – die UI-Hook-Seite (`mpfever_ui.script.lua`) liest noch selbst (Phase 3)
- [x] T1.1 Module kompilieren, Teile sind Umgebungs-Funktionen, keine echten Globals außer `data`
- [x] T1.2/T1.3 Link-Vertrag für beide Implementierungen
- [~] T1.4 Aktionsarten im Mock: Fahrzeug, Linie, Zuweisung, Straße (nativ, beide Richtungen), Geschwindigkeit/Pause;
      Konstruktion, Haltestelle, Terrain, Abriss nur über E2E (Mock-Grenze F7)
- [x] T1.5 Zustands-Hash identisch zu 0.2.10 (Golden-Datei)
- [x] T1.6 Produktionsteile benutzen keine Autotest-Namen
- [x] T1.7 Regression: alle Gates von Phase 0 grün, Simulations-KPIs unverändert
- [~] Linting: `selene`/`stylua` nicht installiert – ersetzt durch Kompilierprüfung aller Dateien + Wächter gegen globale Schreibzugriffe
- [x] Befunde behoben: **F1** (ganze Zahlen über 2³¹: `C.int`), **F2** (Escapen ohne Locale), **F4** (eine Zeitquelle `C.clock`),
      **F8** (Autostart nach dem Laden: Anforderung in `autoload.txt`), **F9 kurzfristig** (Prüfintervall ≥ 10 × letzte Prüfdauer)

### Phase 2 – Signaturbasierte Adressen (Teil-Umsetzung, 09.10.2026)
- [x] Rust-Workspace: `mpf-pe` (PE-Parser), `mpf-sig` (Signaturen mit Wildcards, eindeutige Suche, Erzeugung per
      x86-Decoder iced-x86), `tools/sigtool` (`make`, `check`, Header-Generator)
- [x] `signatures/known_40408.txt`, `known_40420.txt` (aus `BUILDS[]`), `signatures/signatures.txt` (23 Adressen, Build 40420)
- [x] Native-Modul: unbekannter Build → Adressen per Signatur (`signatures_gen.h`); `MPFEVER_SIGSCAN=1` vergleicht,
      `=2` nutzt sie auch bei bekanntem Build
- [x] T2.1/T2.2 Rust-Tests (PE, Muster, Erzeugung, verschobene Aufrufziele), T2.3 alle Signaturen eindeutig an den bekannten
      Adressen der installierten Exe, Header passt zu `signatures.txt`
- [x] T2.11 (E2E) Signaturen im Spiel: Vergleich und Hooks aus Signaturen (`tests/e2e/test_native_signatures.py`)
- [ ] Hook-Logik selbst nach Rust (`mpf-core`), Proxy auf Loader reduzieren – **offen** (ohne Debugging im Spiel zu riskant;
      die C++-Hooks bleiben), ebenso T2.5–T2.9 (Dummy-Exe)
- [ ] T2.4 Signaturen gegen Build 40408 – Exe nicht verfügbar

### Phase 6 – Präsenz (Teil-Umsetzung, 09.10.2026) und Phase 7 (Sofort-Rückmeldung, Teil)
- [x] `mpfever_br_presence.lua`: Maus (Gelände) und Kamera ~10×/s, nur bei Bewegung (+ Herzschlag); beim Mitspieler
      als Punkt (geglättet) und blasser Kamera-Kreis in einer festen Spielerfarbe; Markierungen verschwinden bei
      `peerleft` oder ohne Update
- [x] Live-Bauanzeige: `nat_pending` trägt die Klickposition – die anderen zeigen dort einen Kreis in der Farbe des
      Bauenden, bis der Bau ankommt (oder abgebrochen ist); der eigene Warte-Kreis in der eigenen Farbe (Phase 7)
- [x] Launcher: Präsenz wird weitergeleitet, aber nicht geloggt
- [x] T6.1 (Größe < 200 Byte, nur bei Bewegung), T6.2 (Glättung), T6.3 (Simulation identisch mit/ohne Präsenz),
      T6.5 (Aufräumen), Bauanzeige – `tests/sim/test_presence.py`
- [ ] Namensschilder, Spielerleiste, Folgen/Springen, Pings, Chat-Fenster, Aktivitätsfeed – brauchen eigene UI-Fenster
      bzw. Eingaben (Spike S6, im Spiel zu klären); Präsenz über eigenen unzuverlässigen Kanal → Phase 4
- [ ] Phase 7: echtes Geisterbild der Bau-Geometrie (die DLL hält den Befehl, Lua kennt nur die Klickposition)

---

## Inhalt

1. [Zielbild und Messgrößen](#1-zielbild-und-messgrößen)
2. [Ist-Analyse: wo Zeit und Robustheit verloren gehen](#2-ist-analyse-wo-zeit-und-robustheit-verloren-gehen)
3. [Zielarchitektur und Sprachentscheidungen](#3-zielarchitektur-und-sprachentscheidungen)
4. [Teststrategie (gilt für alle Phasen)](#4-teststrategie-gilt-für-alle-phasen)
5. [Phasenplan](#5-phasenplan)
   - [Phase 0 – Testfundament und Baseline](#phase-0--testfundament-und-baseline)
   - [Phase 1 – Lua-Bridge modularisieren](#phase-1--lua-bridge-modularisieren)
   - [Phase 2 – Native Core in Rust, signaturbasiert](#phase-2--native-core-in-rust-signaturbasiert)
   - [Phase 3 – Direkte Kopplung Lua ↔ Native (keine Dateien mehr)](#phase-3--direkte-kopplung-lua--native-keine-dateien-mehr)
   - [Phase 4 – Netzwerk-Neubau: Protokoll v2, Steam-P2P, QUIC](#phase-4--netzwerk-neubau-protokoll-v2-steam-p2p-quic)
   - [Phase 5 – Lockstep im Simulations-Thread, adaptiver Vorlauf](#phase-5--lockstep-im-simulations-thread-adaptiver-vorlauf)
   - [Phase 6 – Präsenz: den Mitspieler sehen](#phase-6--präsenz-den-mitspieler-sehen)
   - [Phase 7 – Sofortige Rückmeldung (lokale Vorhersage)](#phase-7--sofortige-rückmeldung-lokale-vorhersage)
   - [Phase 8 – Deterministische Entity-IDs](#phase-8--deterministische-entity-ids)
   - [Phase 9 – Desync-Lokalisierung und gezielte Reparatur](#phase-9--desync-lokalisierung-und-gezielte-reparatur)
   - [Phase 10 – Schneller Resync und Beitritt ohne Pause](#phase-10--schneller-resync-und-beitritt-ohne-pause)
   - [Phase 11 – Launcher in Rust, Installation, Updates, Absturzberichte](#phase-11--launcher-in-rust-installation-updates-absturzberichte)
   - [Phase 12 – Rechte, getrennte Firmen (optional)](#phase-12--rechte-getrennte-firmen-optional)
   - [Phase 13 – Härtung: 3–4 Spieler, Dauerläufe, Release](#phase-13--härtung-34-spieler-dauerläufe-release)
6. [Abhängigkeiten und Reihenfolge](#6-abhängigkeiten-und-reihenfolge)
7. [Risiken und Fallbacks](#7-risiken-und-fallbacks)
8. [Anhang: Zielstruktur des Repositories, Test-Kommandos, Konventionen](#8-anhang)

---

## 1. Zielbild und Messgrößen

### Spielgefühl (was der Spieler merkt)

- Man sieht **Kamera-Position, Cursor und Namen** des Mitspielers auf der Karte, kann ihm folgen oder zu ihm springen.
- Man sieht **live, was der andere gerade plant** (Straße/Gleis/Bahnhof als Vorschau, bevor er klickt).
- Eigene Bauten reagieren **sofort** (Geisterbild), beim Mitspieler erscheinen sie nach Bruchteilen einer Sekunde.
- **Pings**, **Chat**, **Aktivitätsfeed** („Anna hat Linie 4 erstellt“).
- **Beitritt ohne Pause** für die, die schon spielen. **Keine** 20-Sekunden-Resyncs im Normalbetrieb.
- **Verbinden ohne Portweiterleitung** (Steam-Einladung genügt).

### Messgrößen (KPIs) – Baseline wird in Phase 0 gemessen

| ID | Messgröße | Heute (laut Code/Doku) | Ziel 2.0 |
|---|---|---|---|
| K1 | Bau-Latenz Klick → beim Mitspieler gebaut, Speed 1, LAN | Vorlauf 7 Simulationsschritte (`G.ahead = window + 2·spd+1 + 1`), README: „1–2 s“ | ≤ 2 Schritte, ≤ 400 ms Echtzeit |
| K2 | Bau-Latenz wie K1, emuliertes Internet (80 ms RTT, 20 ms Jitter) | nicht gemessen | ≤ 600 ms |
| K3 | Lokale Rückmeldung eigener Bau (Geisterbild sichtbar) | gelber Kreis (0.2.8) | ≤ 1 Frame, volle Vorschau |
| K4 | Präsenz-Latenz (Cursor/Kamera des Mitspielers) | – | ≤ 150 ms + Interpolation |
| K5 | Ende-zu-Ende-Nachrichtenweg Spiel A → Spiel B | Datei → Launcher (Poll 5 ms) → TCP → Launcher → Datei → Lua (pro Frame) | In-Prozess, kein Datei-Hop |
| K6 | Resync-Dauer | ~20 s | ≤ 8 s; im Normalbetrieb 0 Resyncs |
| K7 | Beitritt eines Spielers | alle pausieren und laden neu | bestehende Spieler pausieren nicht |
| K8 | Resyncs pro Stunde im Dauerlauf (2 Spieler, Szenario-Mix) | nicht gemessen | 0 (außer dokumentierte Engine-Ursache) |
| K9 | Desync-Lokalisierung | Teil-Hash pro Bereich | betroffene Entity(s) + Komponente benannt |
| K10 | Aufwand neuer Spiel-Build | Adressen pro Build händisch | Signaturen lösen automatisch auf, Gate in < 1 h |
| K11 | Overhead Sync-Check pro Frame (amortisiert) | `cost` wird geloggt | ≤ 2 ms |
| K12 | Verbindung ohne Portweiterleitung | nur mit VPN/Weiterleitung | Steam-P2P mit Relay |

Jede Phase nennt, welche KPIs sie bewegt; das Abnahme-Gate prüft sie automatisiert, soweit möglich.

---

## 2. Ist-Analyse: wo Zeit und Robustheit verloren gehen

| Bereich | Heute | Problem | Wird gelöst in |
|---|---|---|---|
| Taktung | Lua-GUI-Hälfte setzt Spielgeschwindigkeit 0 und lässt Schritte laufen (`pacing()`); Simulation läuft auf eigenem Thread, Echtzeit-getrieben | Der GUI-Frame reagiert zu spät → großer Sicherheitsvorlauf („overshoot reserve“) nötig → 7 Schritte Verzögerung | Phase 5 |
| Nachrichtenweg | `out.log` → C#-Thread pollt alle 5 ms → TCP → Relay → TCP → `in.log` → Lua liest pro Frame | Mehrere Hops, Dateisystem, Polling, Textparsing | Phase 3, 4 |
| Lua ↔ Native | `native_ctl.txt`, `native_events.log`, `terrain_in_<id>.txt` | Polling über Dateien, Rennbedingungen, Latenz | Phase 3 |
| Entity-IDs | IDs divergieren (UI legt Vorschau-Entities an) → `mpfever_refs.lua` (577 Zeilen) beschreibt Objekte über Position etc. | Komplex, fehleranfällig, Suchaufwand | Phase 8 |
| Native Hooks | Feste RVAs pro Build (`BUILDS[]` 40408/40420) | Jedes Spiel-Update bricht Hooks | Phase 2 |
| Bridge | `mpfever_bridge.script.lua` = 5041 Zeilen, davon ~2000 Zeilen Testszenarien (`H.autotest`, `H.matrix`, `H.stops` …) im Produktionscode | Schwer testbar, schwer änderbar | Phase 1 |
| Protokoll | `kind TAB from TAB <Lua-Literal>`, eigener Parser in C# (`LuaLit`) | Keine Versionierung, kein Schema, Parsing-Kosten | Phase 4 |
| Netzwerk | TCP 28090, Portweiterleitung/VPN nötig | Hürde für Spieler, kein unzuverlässiger Kanal für Präsenzdaten | Phase 4 |
| Desync | Hash alle 10 s, Geld wird korrigiert, Rest → Voll-Resync | 20 s Pause, Ursache oft unklar | Phase 9, 10 |
| Beitritt | Alle pausieren, laden Host-Save | Störung für alle | Phase 10 |
| Launcher | C# WinForms, Logik und UI vermischt (`MainForm.cs` 1194 Zeilen) | Netzwerklogik nicht headless testbar, zweite Runtime | Phase 4, 11 |
| Tests | `tests/test_lockstep.py` (2 gemockte Spiele, lupa), `--selftest` (C#), In-Game-Autotests über `--autotest` + `MPFEVER_SCENARIO` | Kein gemeinsamer Runner, keine Netzwerk-Emulation, keine KPI-Messung, keine Gates | Phase 0 |

Was **gut** ist und erhalten bleibt: das Lockstep-Prinzip, die Testszenarien im echten Spiel (werden ausgelagert, nicht gelöscht), die Determinismus-Patches (Script-Pool mit einem Worker, `MPFEVER_THREADS`, `MPFEVER_SIMPOOL`), die Terrain-Kopie, das Command-Audit, der Start zweier Spielinstanzen auf einem PC (`steam_appid.txt`).

---

## 3. Zielarchitektur und Sprachentscheidungen

### Prozess- und Modulbild

```
┌──────────────────────────── Spielprozess TransportFever3.exe ───────────────────────────┐
│                                                                                          │
│  Lua UI-State             Lua GUI-Hälfte (game script)       Lua Sim-Hälfte              │
│  mpf/ui/*.lua  ◄────────► mpf/bridge/*.lua  ◄─────────────►  mpf/sim/*.lua               │
│       │  Präsenz-Rendering     │ Aktionen, Barriere, Hash         │ onPreBuildProposal     │
│       └──────────┬─────────────┘                                  │                       │
│                  │  MPF.native.*  (Phase 3: registrierte C-Funktionen, Fallback: Dateien) │
│  ┌───────────────▼───────────────────────────────────────────────────────────────────┐  │
│  │ mpf_core.dll  (Rust)                                                              │  │
│  │  hooks/      Signatur-Scanner, Inline-Hooks, Command-Halten/Freigeben, Terrain    │  │
│  │  lockstep/   Barriere im Sim-Thread (preIter-Hook), Stempel, Uhren                │  │
│  │  ids/        getrennte Entity-ID-Bereiche UI vs. Simulation (Phase 8)             │  │
│  │  net/        Transport-Trait: SteamP2P | QUIC | Loopback(Test) ; Kanäle:          │  │
│  │              reliable-ordered (Aktionen) / unreliable (Präsenz) / bulk (Saves)    │  │
│  │  session/    Handshake, Rollen, Reconnect, Join, Resync-Orchestrierung            │  │
│  │  telemetry/  JSON-Logs, Metriken, Replay-Rekorder                                 │  │
│  └───────────────▲───────────────────────────────────────────────────────────────────┘  │
│  winhttp.dll (C++, freestanding, klein): Proxy + frühe Patches in DllMain + lädt Core    │
└──────────────────┼───────────────────────────────────────────────────────────────────────┘
                   │ Named Pipe (nur Steuerung: Start, Status, Cold-Join)
┌──────────────────▼──────────────┐
│ MPFever.exe (Rust, Phase 11)    │  Installation, Start, Steam-Cold-Join, Updates, Crash-Upload,
│                                 │  Dev-Dashboard (lokale HTML-Seite aus Metriken)
└─────────────────────────────────┘
```

### Sprachentscheidungen

| Komponente | Heute | Neu | Begründung |
|---|---|---|---|
| Mod-Logik | Lua | **Lua** (bleibt) | Vom Spiel vorgegeben. Wird modularisiert, mit LuaLS-Annotationen, `selene` (Lint) und `stylua` (Format). |
| DLL-Proxy + frühe Patches | C++ freestanding | **C++ freestanding** (bleibt, ~300 Zeilen) | Muss in `DllMain` vor der statischen Initialisierung des Spiels patchen; ist klein und bewährt. Lädt den Core über einen eigenen Thread (nicht unter Loader-Lock). |
| Hooks, Lockstep, Netzwerk, Session | C++ freestanding (1643 Z.) + C# (Relay/Client) | **Rust** (`mpf_core.dll`, cdylib mit std) | Speichersicherheit im Spielprozess, `panic`-Grenzen an jeder FFI-Kante, gute Netzwerk-Crates (quinn, steamworks-sys), echte Unit-Tests, ein Codebestand für Spiel, Launcher und Testpeers. |
| Launcher | C# .NET 4.8 WinForms | **Rust** (Phase 11) | Teilt Crates mit dem Core (Protokoll, Install, Steam-Pfade); eine Toolchain weniger. Die Spieler-UI lebt bereits im Spiel (Hauptmenü-Seite). |
| Tests/Orchestrierung | Python + lupa | **Python + pytest + lupa** (bleibt) + `cargo test` | Vorhandener Test läuft echte Lua-Dateien; pytest gibt Marker, Fixtures, Reports. |

**Warum nicht alles in Rust/C++ neu?** Weil die Spielmechanik nur über die Lua-API zugänglich ist und die bestehenden Replay-Pfade (Straßen-Upgrades, Haltestellen, Konstruktionen an Straßen …) hart erarbeitetes Wissen sind. Die werden umgezogen und getestet, nicht neu erfunden.

### Crate-/Paketstruktur (neu)

```
crates/
  mpf-proto/      Nachrichtentypen (serde), Versionierung, Kodierung (postcard), Kompatibilitätstests
  mpf-net/        Transport-Trait + SteamP2P, QUIC (quinn), Loopback; Netzwerk-Emulator (Latenz/Jitter/Verlust)
  mpf-session/    Session-Zustandsautomat (Host/Client, Join, Reconnect, Resync) – rein, ohne Spiel testbar
  mpf-lockstep/   Barriere, Stempel, Ordnung, adaptiver Vorlauf – rein, ohne Spiel testbar
  mpf-hooks/      Signatur-Scanner, PE-Parser, Hook-Installer (x64), Build-Profil
  mpf-core/       cdylib: verbindet alles mit dem Spiel (FFI zu Lua, Hooks, Steam)
  mpf-launcher/   MPFever.exe
  mpf-testpeer/   Headless-Peer (CLI), spricht Protokoll v2 – für Tests gegen ein echtes Spiel
native/proxy/     winhttp.dll (C++)
mod/mpfever_1/content/mpf/...   Lua-Module (siehe Phase 1)
tests/            pytest-Suite (siehe Abschnitt 4)
```

---

## 4. Teststrategie (gilt für alle Phasen)

### Grundsätze

1. **Test zuerst:** Zu jedem Arbeitspaket werden die Testfälle (IDs `Tn.x`) geschrieben und laufen **rot**, bevor implementiert wird. Ausnahme: reine Charakterisierungstests in Phase 0/1 – sie müssen gegen den **heutigen** Code grün sein.
2. **Jede Phase endet mit einem Gate** (`test.bat gate <phase>`), das alle Ebenen bis zur Phase ausführt. Ein Gate ist nur bestanden, wenn **alle früheren Gates** ebenfalls grün sind (Regressionsschutz).
3. **Lokal ausführbar:** Alles läuft auf dem Entwicklungsrechner (Windows 11, Steam, TF3 installiert). Ebenen ohne Spiel laufen in Sekunden; Ebenen mit Spiel starten zwei Instanzen auf demselben PC.
4. **Messbar:** Jeder E2E-Lauf schreibt `reports/<datum>-<lauf>/report.html` + `metrics.json` (KPIs, Logs, Hash-Verläufe). Gates vergleichen gegen Schwellen in `tests/kpi_thresholds.toml`.
5. **Deterministisch reproduzierbar:** Jeder Fehler aus einem E2E- oder Dauerlauf erzeugt eine **Replay-Datei** (Start-Save-Hash + alle Aktionen mit Stempeln), die offline erneut abgespielt werden kann (ab Phase 0 rudimentär, ab Phase 9 vollständig).

### Testebenen

| Ebene | Marker | Was | Werkzeuge | Laufzeit | Spiel nötig |
|---|---|---|---|---|---|
| L1 Unit | `unit` | Einzelne Lua-Module, Rust-Crates, Proxy-Funktionen | pytest+lupa, `cargo test` | Sekunden | nein |
| L2 Simulation | `sim` | N gemockte Spiele (echte Lua-Dateien) + echter Rust-Session/Lockstep-Code über Loopback-Transport + Netzwerk-Emulator | pytest+lupa, `mpf-testpeer`, PyO3-freie Kopplung über Subprozess/Pipe | < 2 min | nein |
| L3 Native-Offline | `native` | Signatur-Scanner gegen die **installierte** `TransportFever3.exe` (nur lesen), Hook-Framework gegen eine Dummy-Exe mit identischen Prologen, Proxy-Exports gegen System-`winhttp.dll` | `cargo test`, Dummy-Exe `tests/native/dummy_game` | < 1 min | Spiel installiert, nicht gestartet |
| L4 E2E | `e2e` | Zwei echte Spielinstanzen auf einem PC, Test-Savegame, Szenarien (bestehende Autotests + neue), Netzwerk-Emulation im Core | `tools/mpftest` (Python), `MPFever.exe --autotest` | 3–15 min je Szenario-Set | ja |
| L5 Dauerlauf | `soak` | 2 h (bzw. über Nacht) gemischte Aktionen, Speed 1–4, Pausen, Reconnects, Joins | wie L4 + Szenario-Generator | Stunden | ja |
| L6 Gefühl | `manual` | Checkliste mit Screenshots/Video; zwei Menschen, zwei PCs oder zwei Fenster | `tests/manual/checklist.md` | 20 min | ja |

### Einheitlicher Einstieg

```bat
test.bat unit            :: L1
test.bat sim             :: L1+L2
test.bat native          :: L3
test.bat e2e [szenarien] :: L4 (Standard: smoke)
test.bat soak [stunden]  :: L5
test.bat gate <phase>    :: alles, was die Phase verlangt, inkl. KPI-Schwellen
test.bat report          :: letzten Report im Browser öffnen
```

`test.bat` ruft intern `python -m pytest -m <marker>`, `cargo test --workspace` und für E2E `python -m tools.mpftest`.

### Testdaten

- **`MPF-Test-Small`**: kleine Karte, feste Startparameter, wenige Städte, einige Straßen/Gleise, 1 Depot, 1 Bahnhof – Save liegt in `tests/fixtures/saves/` (Git LFS) mit SHA-256 in `fixtures.lock`. Ein Skript (`tools/mpftest/make_fixture.py`) kann ihn aus dem Spiel neu erzeugen.
- **`MPF-Test-Busy`**: mittlere Karte mit viel Verkehr (für Determinismus, Performance, Dauerlauf).
- **Mod-freie Spielkonfiguration**: E2E prüft vor dem Start, dass nur `mpfever_1` aktiv ist (sonst Abbruch mit klarer Meldung).

### Hardware-Hinweis für L4/L5

Zwei TF3-Instanzen auf einem PC brauchen viel RAM/VRAM. Der Test-Harness setzt für beide Instanzen niedrige Grafik, kleines Fenster und eine Bildratenbegrenzung über die Spieleinstellungen der jeweiligen Instanz (eigener User-Ordner pro Instanz, falls möglich – sonst Settings-Datei vor dem Start patchen und danach zurücksetzen).

---

## 5. Phasenplan

Jede Phase hat dieselbe Struktur: **Ziel · Tests zuerst · Umsetzung · geänderte/neue Dateien · Gate · Risiken.**

---

### Phase 0 – Testfundament und Baseline

**Ziel:** Bevor irgendetwas umgebaut wird, sind alle Testebenen lauffähig, das heutige Verhalten ist durch Charakterisierungstests festgehalten und die KPIs der Version 0.2.10 sind gemessen. **Keine funktionalen Änderungen.**

#### Tests zuerst

| ID | Testfall | Ebene |
|---|---|---|
| T0.1 | Bestehender `tests/test_lockstep.py` läuft unverändert als pytest-Test (Wrapper, keine Logikänderung) | sim |
| T0.2 | `MPFever.exe --selftest` läuft als pytest-Test (Exit-Code 0) | unit |
| T0.3 | Serializer `C.ser`/Parser: Roundtrip für Zahlen (int, float, NaN, ±inf), Strings mit Tab/Newline/Backslash/Anführungszeichen/UTF-8, verschachtelte Tabellen, leere Tabellen | unit |
| T0.4 | C#-`LuaLit.Parse` und Lua-`C.ser` sind kompatibel (1000 zufällig generierte Werte, Property-based mit Hypothesis) | unit |
| T0.5 | `valueHash` ist unabhängig von der Einfügereihenfolge der Tabelle; ignoriert `revision`/`guiTimeSeconds` | unit |
| T0.6 | `before(x, y)` ordnet gleichzeitige Aktionen total und stabil (Antisymmetrie, Transitivität, gleiche Ordnung auf allen Spielen) | unit |
| T0.7 | `pacing()`: bei Peer-Uhr hinter eigener Zeit → Geschwindigkeit 0; Stopp-Punkte; Statistik `barrier/hold` | unit |
| T0.8 | `mpfever_refs.lua`: Referenz erzeugen/auflösen für Depot, Station, Konstruktion, Knoten, Kante, Linie, Fahrzeug – mit verschobenen IDs (Offset 1000 wie im Mock) | unit |
| T0.9 | Sim-Harness mit **N=3** Spielen (Erweiterung des Mocks) – gleiche Prüfungen wie T0.1 | sim |
| T0.10 | Netzwerk-Emulator im Sim-Harness: Latenz 0/50/150 ms, Jitter 0/30 ms, Neuordnung; alle Prüfungen aus T0.1 bleiben grün | sim |
| T0.11 | Signatur-Prüfung offline: alle RVAs aus `BUILDS[]` zeigen auf die erwarteten Prolog-Bytes in der installierten Exe (meldet Build-Stempel) | native |
| T0.12 | E2E-Smoke: zwei Instanzen, `MPF-Test-Small`, Szenarien `newroad,upgrade` (bestehend) → keine `replay_failed`, Hashes gleich, kein Resync | e2e |
| T0.13 | E2E-Voll: alle vorhandenen Autotest-Szenarien (`stops`, `tramstop`, `bulldoze`, `buy`, `line`, `split`, `roadtypes`, `terrain`, `company`, `matrix` …) einzeln, je mit Ergebnis im Report | e2e |
| T0.14 | E2E-KPI-Messung: Bau-Latenz K1/K2 (Zeitstempel per QueryPerformanceCounter auf beiden Instanzen – gleicher PC, gleiche Uhr), Resync-Dauer K6, Hash-Kosten K11 | e2e |
| T0.15 | Dauerlauf 30 min Baseline: Anzahl Resyncs (K8), Barrier-Stalls, Speicherverbrauch | soak |

#### Umsetzung

1. `tests/` umstrukturieren: `tests/unit`, `tests/sim`, `tests/native`, `tests/e2e`, `tests/soak`, `tests/conftest.py` (Fixtures: `lua_game`, `sim_cluster(n, netem)`, `game_pair`).
2. `tests/sim/harness.py`: aus dem Mock in `test_lockstep.py` eine wiederverwendbare Klasse `MockGame` + `MockRelay` + `NetEm` (Verzögerungswarteschlange mit simuliertem Taktgeber, deterministischer Zufallsgenerator mit Seed).
3. `tools/mpftest/` (Python-Paket):
   - `runner.py` – startet `MPFever.exe --autotest`, setzt `MPFEVER_SCENARIO`, `MPFEVER_SPEED`, `MPFEVER_PAUSED`, wartet auf `autotest_done`, sammelt `%TEMP%\mpfever\<Session>\*` und `logs\`.
   - `analyze.py` – liest `mod.log`, `native.log`, `launcher-*.log`, `audit-*.txt`; extrahiert Ereignisse (`replay_failed`, `LATE`, Resync, Hash-Diffs).
   - `kpi.py` – berechnet K1, K2, K6, K8, K11 aus Zeitstempeln.
   - `report.py` – HTML-Report (Tabelle pro Szenario, Diagramme, Links auf Logs).
4. **Messpunkte** (minimal-invasiv, hinter `MPFEVER_TIMING=1`, existiert bereits teilweise): Lua loggt `t_click`, `t_stamp`, `t_apply` mit Spielzeit und QPC-Zeit; der Native-Timing-Probe (`MPFEVER_TIMING`) wird in den Report übernommen.
5. `test.bat` + `tests/kpi_thresholds.toml` (Phase 0: Schwellen = gemessene Baseline + 10 % Toleranz, als Regressionsschutz).
6. Fixture-Saves anlegen, Hash festhalten.
7. Linting einführen (nur melden, nicht blockieren): `selene`, `stylua --check`.

#### Gate 0

```bat
test.bat gate 0
```

- T0.1–T0.13 grün, T0.14/T0.15 haben Werte geliefert.
- `reports/baseline-0.2.10/` ist eingecheckt (nur `metrics.json` + `report.html`, keine großen Logs).
- Dokument `docs/dev/BASELINE.md` mit den gemessenen KPI-Werten.

#### Risiken

- E2E auf einem PC ist ressourcenintensiv → Grafik-Minimalprofil, Szenarien einzeln.
- Zeitmessung über zwei Prozesse: QPC ist systemweit monoton → gleiche Uhr auf einem PC; für zwei PCs (L6) NTP-ähnlicher Offset-Abgleich über Ping (später in Phase 4 eingebaut).

---

### Phase 1 – Lua-Bridge modularisieren

**Ziel:** `mpfever_bridge.script.lua` (5041 Zeilen) in klar getrennte Module zerlegen; Testszenarien aus dem Produktionscode auslagern; eine **abstrakte Native-Schnittstelle** `MPF.native` einführen, hinter der zunächst weiterhin die Datei-Kommunikation steckt. Verhalten bleibt **identisch** (alle Gates von Phase 0 grün).

#### Tests zuerst

| ID | Testfall | Ebene |
|---|---|---|
| T1.1 | Jedes neue Modul lässt sich isoliert in lupa laden (keine versteckten globalen Abhängigkeiten) | unit |
| T1.2 | `mpf.transport` (Datei-Variante): Zeilen schreiben/lesen, Teilzeilen am Dateiende, Offset-Fortsetzung nach Neustart, CR/LF | unit |
| T1.3 | `mpf.native` Schnittstelle: Mock-Implementierung erfüllt denselben Vertrag wie die Datei-Implementierung (gemeinsame Vertragstests) | unit |
| T1.4 | `mpf.actions.<typ>`: je Aktionstyp (vehicle, line, street, construction, stop, terrain, bulldoze, speed) – capture → serialize → resolve → execute im Mock | unit |
| T1.5 | `mpf.hash`: identische Parts wie vorher (Golden-Datei aus Phase 0 für den Mock-Welt-Zustand) | unit |
| T1.6 | Kein Produktionsmodul referenziert Autotest-Code (statische Prüfung: `require`-Graph) | unit |
| T1.7 | Gate-0-Suite komplett grün (Regression) | alle |

#### Umsetzung

Neue Lua-Struktur unter `mod/mpfever_1/content/mpf/`:

```
mpf/common.lua         (aus mpfever_common.lua: Logger, ser/parse, Hash-Funktionen, Pfade)
mpf/native.lua         Schnittstelle MPF.native: send(kind,payload), poll(), holdEnable(b), release(n),
                       terrainCapture/Inject – Implementierung: native_files.lua (heute) / native_ffi.lua (Phase 3)
mpf/transport.lua      send/receive zum Launcher bzw. Core (heute in.log/out.log)
mpf/clock.lua          gameTime, gameSpeed, STEP, Stempel, before()
mpf/lockstep.lua       pacing(), Barriere, Stopp-Punkte, adaptAhead, Pausen
mpf/refs/*.lua         (aus mpfever_refs.lua, aufgeteilt nach Entity-Art)
mpf/actions/vehicle.lua, line.lua, street.lua, construction.lua, stop.lua, terrain.lua, bulldoze.lua, speed.lua
mpf/replay/native.lua  replayNative, replayTwoStep, replayUpgrade, replayStop, replayNativeConstruction
mpf/hash.lua           valueHash, countsHash, simHash, extendedParts
mpf/resync.lua         Save/Load-Ablauf, claimResync
mpf/session.lua        welcome/session/peerclock/peerleft-Handler
mpf/bridge.lua         dünner Einstieg: verdrahtet Module, Handler-Tabelle H
mpf/ui/hook.lua        (aus mpfever_ui.script.lua)
mpf/ui/menu.lua        (aus mpfever_menu.lua)
mpf/dev/autotest/*.lua alle Szenarien (matrix, stops, tramstop, split, roadtypes, terrainsoak, camtour, …)
                       – werden nur geladen, wenn MPFEVER_AUTOTEST=1
```

Die alten Dateinamen (`mpfever_bridge.script.lua` etc.) bleiben als **dünne Einstiegspunkte**, weil das Spiel sie über `mod.json`/`_content.json` bzw. Namenskonventionen (`*.script.lua`, `*.gs.lua`, `*.res.lua`) lädt.

Module werden über `ug_require` geladen (wie heute mit Fallback auf `mpfever_1::/…`).

#### Gate 1

```bat
test.bat gate 1
```

- T1.1–T1.7 grün, Gate 0 grün, KPIs unverändert (± 10 %).
- `selene` ohne Fehler auf `mpf/` (Warnungen erlaubt).
- Größtes Produktionsmodul < 800 Zeilen.

#### Risiken

- Ladereihenfolge/`ug_require`-Eigenheiten im Spiel → T0.12 (E2E-Smoke) fängt das ab; Modul-Ladefehler werden beim Start explizit geloggt und an den Launcher gemeldet.

---

### Phase 2 – Native Core in Rust, signaturbasiert

**Ziel:** Die Hook-Logik aus `native/mpfever_native.cpp` wird nach Rust (`mpf_core.dll`) portiert; Adressen werden über **Signaturen + Aufrufgraph** gefunden statt über feste RVAs pro Build. `winhttp.dll` (C++) wird auf Proxy + frühe Patches + Core-Loader reduziert. Verhalten identisch.

#### Tests zuerst

| ID | Testfall | Ebene |
|---|---|---|
| T2.1 | PE-Parser: Sections, Imports, Exporte, Link-Zeitstempel aus Test-Binärdateien | unit |
| T2.2 | Signatur-Scanner: Muster mit Wildcards, „genau ein Treffer“-Regel, RIP-relative Auflösung, Call-Ziel-Auflösung | unit |
| T2.3 | **Gegen die installierte `TransportFever3.exe`:** jede Signatur aus `signatures.toml` löst eindeutig auf; Ergebnis entspricht für Build 40420 den bekannten RVAs aus `BUILDS[]` | native |
| T2.4 | Gleiches für ein archiviertes 40408-Exe (falls lokal vorhanden; sonst übersprungen mit Hinweis) | native |
| T2.5 | Hook-Installer auf Dummy-Exe (`tests/native/dummy_game`, C++, gleiche Prologe wie die echten Ziele): Trampolin führt Original aus, Relay-Thunk erhält korrekte Argumente, Deinstallation stellt Bytes wieder her | native |
| T2.6 | Command-Halten auf Dummy-Exe: `CommandList::Add`-Äquivalent wird gehalten, `release(n)` reicht in Reihenfolge durch, Überlauf (> 64) wird sauber abgelehnt | native |
| T2.7 | Terrain-Grid-Kopie (LZ-Pack/Unpack) – Roundtrip für zufällige Gitter bis 3 Mio. Zellen; identische Ausgabe wie C++-Version (Golden-Dateien) | unit |
| T2.8 | `panic` in einer Hook-Funktion → wird gefangen, Hook deaktiviert sich, Spiel läuft weiter, Fehler im Log | native |
| T2.9 | Unbekannter Build → Core lädt, meldet „inert“, alle Hooks aus, Proxy-Funktionen funktionieren (WinHttpOpen gegen System-DLL) | native |
| T2.10 | Proxy-Exporte: alle Exporte der System-`winhttp.dll` sind vorhanden (Vergleich der Exporttabellen) | native |
| T2.11 | Gate-1-Suite inkl. E2E komplett grün mit neuem Core | e2e |

#### Umsetzung

1. `crates/mpf-hooks`: PE-Parser, Scanner, x64-Längendisassembler (z. B. `iced-x86`), Inline-Hook (eigener Code oder `retour`), Breakpoint-Sites (vectored exception handler) wie bisher.
2. `signatures.toml`: pro Ziel (`add`, `move`, `dtor`, `handleDtor`, `apply`, `swap`, `sync`, `preIter`, `lua`, `pool`, `loopRet`, UI-Sites, Terrain-Funktionen, Steam-Callback) ein Muster + optional „Aufrufer von X an Offset Y“. Feste RVAs bleiben als **Prüfwerte** für bekannte Builds.
3. `tools/sigtool` (Rust-CLI): `sigtool check <exe>`, `sigtool diff <alt.exe> <neu.exe>` (findet verschobene Funktionen über Aufrufgraph-Ähnlichkeit), `sigtool make <exe> <rva>` (erzeugt eindeutiges Muster).
4. `native/proxy/` (C++): behält WinHTTP-Relay (`winhttp_proxy.cpp`), die DllMain-Patches (`MPFEVER_THREADS`, `MPFEVER_SIMPOOL`, Script-Pool mit einem Worker, Hauptmenü-Seite), startet einen Thread, der nach Loader-Lock-Freigabe `mpf_core.dll` lädt – nur wenn `MPFEVER_DIR` gesetzt ist.
5. `mpf-core`: portiert Command-Halten, Freigabe, Terrain-Capture/Inject, Command-Audit, Steam-Einladungen, Cold-Join. Steuerung zunächst weiterhin über dieselben Dateien (`native_ctl.txt`, `native_events.log`), damit Lua unverändert bleibt.
6. Build: `build.bat` ruft `cargo build --release -p mpf-core` + `native\proxy\build.bat`. Voraussetzung: Rust stable (`x86_64-pc-windows-msvc`), Visual Studio 2022 mit Windows SDK.

#### Gate 2

- T2.1–T2.11 grün; Gate 1 grün.
- `sigtool check` gegen die installierte Exe: 100 % eindeutige Treffer.
- KPIs unverändert (± 10 %), keine neuen Abstürze in 30 min Dauerlauf (T0.15 erneut).

#### Risiken

- Rust + Loader-Lock: Core niemals in `DllMain` laden → eigener Thread; frühe Patches bleiben C++.
- Signaturen zu generisch/zu speziell → `sigtool make` erzwingt Eindeutigkeit, T2.3 prüft jede Version.

---

### Phase 3 – Direkte Kopplung Lua ↔ Native (keine Dateien mehr)

**Ziel:** Die Lua-Zustände des Spiels rufen den Core **direkt** auf (`MPF.native.send(...)`, `MPF.native.poll()`), statt Dateien zu pollen. Der Core reicht Nachrichten in-Prozess weiter; der Launcher ist aus dem Nachrichtenweg entfernt (bis Phase 4 übernimmt der Core die bestehende TCP-Verbindung zum Relay). Bewegt **K1, K5**.

#### Spike S3 (vorab, max. 3 Tage)

Frage: Kann der Core C-Funktionen in die Lua-States des Spiels registrieren?
Vorgehen: Die Adresse `lua` aus `BUILDS[]` (bereits bekannt) bzw. die Lua-API-Funktionen (`lua_pushcclosure`, `lua_setfield`, `lua_tolstring` …) per Signatur finden; beim Erzeugen bzw. ersten Ausführen eines States eine Tabelle `MPF_NATIVE` mit C-Funktionen setzen.
**Go:** Aufruf aus GUI-, Sim- und UI-State funktioniert, auch nach Laden eines Saves (neue States).
**No-Go → Fallback:** Der Core übernimmt die bestehenden Dateien in-Prozess (Memory-mapped-Datei als Ringpuffer, Lua liest weiter per `io`, aber ohne Launcher-Hop). Auch das halbiert die Latenz des Nachrichtenwegs.

#### Tests zuerst

| ID | Testfall | Ebene |
|---|---|---|
| T3.1 | Vertragstests aus T1.3 laufen gegen `native_ffi.lua` mit Mock-FFI (Python stellt `MPF_NATIVE` bereit) | unit |
| T3.2 | Ringpuffer (Rust): Einzelner Produzent/Konsument, Überlauf → Rückdruck statt Verlust, Nachrichten > Puffergröße werden fragmentiert | unit |
| T3.3 | Lua-Aufruf während Lade-/Speichervorgang → definierte Antwort (Warteschlange), kein Absturz | native (Dummy-Lua 5.2 im Test) |
| T3.4 | Mehrere Lua-States (UI, GUI-Hälfte, Sim-Hälfte) bekommen getrennte Postfächer mit garantierter Reihenfolge je Absender | unit |
| T3.5 | E2E: Nachrichtenweg-Latenz K5 (Lua A → Lua B) < 5 ms auf einem PC | e2e |
| T3.6 | E2E: alle Szenarien aus Gate 2 grün; K1 verbessert gegenüber Baseline | e2e |
| T3.7 | Fallback-Pfad (`MPFEVER_NATIVE_IPC=files`) besteht ebenfalls Gate 2 | e2e |

#### Umsetzung

- `mpf-core/src/lua_ffi.rs`: Registrierung, Marshalling Lua-Tabelle ↔ `mpf-proto`-Wert (Strings, Zahlen, Booleans, Tabellen; Tiefenlimit).
- `mpf/native_ffi.lua`: Implementierung von `MPF.native` über `MPF_NATIVE`; Auswahl in `mpf/native.lua` per Fähigkeitserkennung.
- Launcher: Relay/Client-Logik wandert für den Übergang in den Core (Rust-Port von `Relay`/`Client`, gleiches Textprotokoll) – Launcher startet nur noch das Spiel.

#### Gate 3

- T3.1–T3.7 grün; Gate 2 grün.
- K5 < 5 ms; K1 mindestens 1 Schritt besser als Baseline.

---

### Phase 4 – Netzwerk-Neubau: Protokoll v2, Steam-P2P, QUIC

**Ziel:** Ein versioniertes Binärprotokoll mit getrennten Kanälen; Verbindung über **Steam Networking** (NAT-Traversal + Relay, keine Portweiterleitung) mit **QUIC** als direkter Alternative (LAN, Tests, Nicht-Steam). Handshake prüft Kompatibilität. Bewegt **K2, K12**, Grundlage für Präsenz (Phase 6).

#### Tests zuerst

| ID | Testfall | Ebene |
|---|---|---|
| T4.1 | `mpf-proto`: Roundtrip aller Nachrichtentypen; feste Kodierungs-Goldens (Schutz vor unbeabsichtigten Formatänderungen) | unit |
| T4.2 | Versionierung: v2.x-Peer lehnt inkompatiblen Peer mit lesbarem Grund ab (Protokoll, Spiel-Build, Mod-Hash, Mod-Liste) | unit |
| T4.3 | Kanäle: reliable-ordered (Aktionen, Uhren, Hashes), unreliable-sequenced (Präsenz, nur neueste zählt), bulk (Savegames, Terrain) mit Fortsetzung nach Abbruch | unit |
| T4.4 | `mpf-session` Zustandsautomat: Host/Client, Join, Leave, Reconnect (5 min), Host-Verlust → klare Meldung; als reine Logik mit simulierter Zeit | unit |
| T4.5 | Netzwerk-Emulator (`mpf-net::netem`): Latenz, Jitter, Verlust, Duplikat, Neuordnung, Bandbreite; reproduzierbar per Seed | unit |
| T4.6 | Sim-Cluster (L2) über Loopback-Transport + netem: 3 Spiele, 150 ms RTT, 2 % Verlust → alle T0.1-Prüfungen grün, keine späten Aktionen | sim |
| T4.7 | QUIC zwischen zwei `mpf-testpeer`-Prozessen auf localhost: Verbindung, 10 000 Nachrichten, Savegame-Transfer 200 MB mit Abbruch/Fortsetzung | sim |
| T4.8 | Steam-P2P zwischen **zwei Spielinstanzen auf einem PC**: Verbindungsaufbau über SteamID (lokal ggf. nur über Relay möglich – Test prüft, dass ein Pfad zustande kommt) | e2e |
| T4.9 | Zeitabgleich: geschätzter Uhren-Offset zwischen Peers ± 2 ms (auf einem PC gegen QPC prüfbar) | e2e |
| T4.10 | E2E mit `MPF_NETEM=rtt=80,jitter=20,loss=1`: alle Szenarien grün; K2 gemessen | e2e |
| T4.11 | Verbindungsabbruch mitten im Bau (Kabel ziehen simuliert über netem `blackhole=10s`) → Reconnect, keine doppelte/verlorene Aktion | e2e |

#### Umsetzung

- `mpf-proto`: `Envelope { v, kind, from, seq, stamp?, payload }`, Nutzlast-Typen als Rust-Enums (`Act`, `Clock`, `Hash`, `Presence`, `Chat`, `Ping`, `ResyncOffer`, `SaveChunk`, …), Kodierung `postcard`. Lua-Seite sieht weiterhin Tabellen (Marshalling im Core).
- `mpf-net`:
  - `SteamP2P`: nutzt die im Spielprozess **bereits initialisierte** `steam_api64.dll` des Spiels (Flat-API `SteamNetworkingMessages`/`SteamNetworkingSockets`); Version der Interfaces zur Laufzeit erkennen.
  - `Quic`: `quinn`, selbstsignierte Zertifikate mit Pinning über den Einladungscode.
  - `Loopback`: für Tests.
- Einladungen: Steam-Rich-Presence trägt künftig die SteamID des Hosts (statt IP); IP-Join bleibt als QUIC-Variante (`ipify`-Abfrage entfällt bei Steam-Pfad).
- Host-Autorität bleibt: der Host stempelt (bzw. bestätigt Stempel), sammelt Hashes, entscheidet Resync.
- Launcher-Relay (C#) wird entfernt.

#### Gate 4

- T4.1–T4.11 grün; Gate 3 grün.
- K2 ≤ Baseline-K1 (Internet so schnell wie vorher LAN), K12 erfüllt (Verbindung ohne Weiterleitung zwischen zwei Instanzen).

#### Risiken

- Steam-Networking zwischen zwei Instanzen desselben Accounts auf einem PC ist evtl. nicht möglich → T4.8 notfalls mit zweitem Steam-Account auf zweitem PC/VM (L6), QUIC deckt den lokalen Fall ab.
- Rechtlich: Nutzung der Steam-API im Namen der App-ID des Spiels – mit den Steamworks-Bedingungen abgleichen, ggf. mit Urban Games abstimmen.

---

### Phase 5 – Lockstep im Simulations-Thread, adaptiver Vorlauf

**Ziel:** Die Barriere wird **im Simulations-Thread** durchgesetzt (Hook vor jeder Iteration, Adresse `preIter` ist bereits bekannt), statt über die Lua-GUI-Hälfte mit Geschwindigkeit 0/Schrittbefehlen. Damit entfällt die Überschuss-Reserve. Der Vorlauf (Stempelabstand) wird aus gemessener RTT/Jitter berechnet. Bewegt **K1, K2** am stärksten.

#### Hintergrund

Heute: `G.window = spd + 2`, `G.ahead = adaptAhead(window + (2·spd + 1) + 1)` → bei Speed 1: **7 Schritte**. Die `2·spd+1`-Reserve existiert nur, weil der GUI-Frame die Simulation zu spät stoppt.
Neu: Der Sim-Thread prüft **vor jedem Schritt** `nächsterSchritt ≤ min(Peer-Uhren) + Fenster`. Wenn nicht, wartet er (kurzer Spin + Event). Vorlauf = `ceil((RTT/2 + 2·Jitter + Verarbeitung) / Schrittdauer_echtzeit) + 1`, mindestens 1.

#### Tests zuerst

| ID | Testfall | Ebene |
|---|---|---|
| T5.1 | `mpf-lockstep`: Barriere-Logik als reine Funktion – kein Spiel überholt `min(peers)+window`; Fortschritt garantiert (keine Deadlocks) bei beliebigen Ankunftsreihenfolgen (Property-based, `proptest`) | unit |
| T5.2 | Adaptiver Vorlauf: aus RTT/Jitter-Verläufen korrekte Stempeldistanz; Hysterese (kein Flattern); Sprung nach oben sofort, nach unten langsam | unit |
| T5.3 | Spät angekommene Aktion (Stempel bereits überschritten) → nie stillschweigend falsch anwenden: Vorlauf erhöhen, Aktion zum nächstmöglichen gemeinsamen Zeitpunkt **auf allen** Spielen (Re-Stamp durch Host) | unit + sim |
| T5.4 | Pause/Geschwindigkeitswechsel über die Barriere: alle Spiele stoppen am **selben** Schritt (wie T0.1, jetzt mit Sim-Thread-Barriere) | sim |
| T5.5 | Dummy-Exe mit Sim-Loop: Hook blockiert Iteration, Render-Thread (Dummy) läuft weiter; Timeout-Schutz (> 30 s Warten → Meldung, kein Hängen) | native |
| T5.6 | E2E: K1 ≤ 2 Schritte bei Speed 1 LAN; K2 gemessen ≤ 600 ms | e2e |
| T5.7 | E2E: Speed 4 + Pausen + Bau-Sturm (100 Aktionen/min): keine LATE-Aktionen, Hashes gleich | e2e |
| T5.8 | Dauerlauf 2 h: K8 nicht schlechter als Baseline; Barrier-Stall-Anteil < 2 % der Frames | soak |

#### Umsetzung

- `mpf-core/src/lockstep.rs`: Hook auf `preIter` (Sim-Loop ruft die Funktion einmal pro Iteration), hält die Iteration, bis die Barriere es erlaubt. Peer-Uhren kommen direkt aus `mpf-net` (kein Umweg über Lua).
- Lua `mpf/lockstep.lua` wird schlanker: setzt nur noch Sitzungsgeschwindigkeit; `pacing()`-Stopp-Logik bleibt als Fallback (`MPFEVER_BARRIER=lua`), wenn der Hook auf einem Build fehlt.
- Uhren werden pro Sim-Schritt vom Core gesendet (nicht pro GUI-Frame).
- Aktionen werden vor der eigenen Uhr verschickt (wie heute garantiert), jetzt im selben Thread → Reihenfolge strikt.

#### Gate 5

- T5.1–T5.8 grün; Gate 4 grün; KPI-Schwellen K1/K2 auf Zielwerte gesetzt.

#### Risiken

- Render-Thread wartet evtl. auf Sim-Sync (`sync`-Adresse) → Ruckler. Spike im Rahmen von T5.5/T5.6; Gegenmaßnahme: Warten in kleinen Scheiben, Sim-Schrittzeit glätten (Spiel läuft gleichmäßig minimal langsamer statt zu stocken).

---

### Phase 6 – Präsenz: den Mitspieler sehen

**Ziel:** Das „gemeinsam auf einer Karte“-Gefühl. Alles über den **unzuverlässigen Präsenz-Kanal**, nicht Teil des Lockstep, nicht im Hash. Bewegt **K4**.

#### Funktionen

| Funktion | Daten | Darstellung (vorhandene Spiel-APIs zuerst) |
|---|---|---|
| Spielerfarbe & Name | beim Join vergeben | überall konsistent |
| Kamera des Mitspielers | `cam.getCameraData()` (wird in `H.camtour` bereits genutzt), 10 Hz | Kegel/Rahmen auf der Karte (Zonen-Polygon), Minikarte-Marker |
| Cursor | `getTerrainPosition()` (bereits genutzt), 15 Hz, interpoliert | Farbiger Kreis via `api.gui.mission.setZoneCircle` (wie der gelbe Warte-Kreis aus 0.2.8) + Namensschild |
| Live-Bauvorschau | aktives Werkzeug + aktuelle Proposal-Geometrie (Segmente, Konstruktions-Footprint), 5 Hz, gedrosselt/vereinfacht | Zonen-Polygone/Linien in Spielerfarbe, halbtransparent |
| Auswahl | ausgewähltes Objekt (als Referenz) | Umriss/Markierung |
| Folgen / Springen | – | `cam.setCameraData()` mit Glättung; Hotkey + Spielerleiste |
| Pings | Position + Typ (Achtung/Hier bauen/Frage) | Zonen-Kreis pulsierend + Ton + Eintrag im Feed |
| Chat | Text | In-Game-Fenster (Lua-UI), Hotkey Enter |
| Aktivitätsfeed | aus angewendeten Aktionen abgeleitet (lokal, deterministisch) | kleine Liste am Rand, klickbar → Kamera springt hin |
| Spielerleiste | Name, Farbe, Ping, Status (baut/idle/lädt) | oben rechts |

#### Spike S6 (vorab, max. 3 Tage)

Was kann die Lua-UI-API von TF3 an Overlays? (Zonen-Polygone in beliebiger Farbe und Anzahl, Aktualisierungsrate, Kosten; Weltkoordinate → Bildschirmkoordinate für Namensschilder; eigene Fenster/Leisten.)
**Go:** ≥ 20 Zonen-Updates/s ohne messbaren Frameverlust; Namensschild-Positionierung möglich.
**Fallback:** Namensschilder ohne Weltbezug (nur Spielerleiste + Kamera-Sprung); für Vorschau-Linien ein Native-Render-Hook als spätere Erweiterung (eigene Phase, nicht Teil des Gates).

#### Tests zuerst

| ID | Testfall | Ebene |
|---|---|---|
| T6.1 | Präsenz-Nachrichten: Drosselung, Delta-Kodierung, nur neueste zählt (Sequenznummer), Größe < 200 Byte/Update | unit |
| T6.2 | Interpolation/Extrapolation des Cursors: glatte Bahn bei 15 Hz Eingang und 5 % Verlust (numerischer Test) | unit |
| T6.3 | Präsenzdaten beeinflussen **nie** den Simulationszustand: Sim-Cluster mit/ohne Präsenzverkehr → identische Hashes und Aktionsfolgen | sim |
| T6.4 | Bauvorschau-Vereinfachung: Proposal → Polylinien/Polygone, max. N Punkte, stabil bei Mausbewegung | unit |
| T6.5 | UI-Modul (lupa mit Mock-`api.gui`): Zonen werden angelegt, aktualisiert, beim Verlassen/Timeout entfernt (keine Leichen) | unit |
| T6.6 | Chat: Längenlimit, Escaping, Rate-Limit, Reihenfolge | unit |
| T6.7 | E2E: Instanz A bewegt Kamera/Cursor skriptgesteuert entlang einer Bahn; Instanz B protokolliert empfangene Marker-Positionen → K4 ≤ 150 ms, Positionsfehler nach Interpolation < 5 m | e2e |
| T6.8 | E2E: A plant Straße (Werkzeug offen, nicht gebaut) → B zeigt Vorschau; A bricht ab → Vorschau verschwindet in < 500 ms | e2e |
| T6.9 | E2E: Frame-Zeit mit Präsenz an vs. aus: Mehrkosten < 1 ms/Frame | e2e |
| T6.10 | Manuelle Checkliste L6: „Fühlt sich an wie zusammen“ – Folgen, Ping, Chat, Vorschau, Feed (Screenshots im Report) | manual |

#### Umsetzung

- `mpf/presence/collect.lua` (UI-State): sammelt Kamera, Cursor, Werkzeug, Proposal-Vorschau.
- `mpf/presence/render.lua` (UI-State): Zonen, Namensschilder, Spielerleiste, Feed.
- `mpf/ui/chat.lua`, `mpf/ui/players.lua`.
- `mpf-core`: Präsenz-Kanal, Drosselung, Interpolationszeitstempel.
- Einstellungen (Lua-Fenster): Präsenz ein/aus, Farbe, Feed-Filter.

#### Gate 6

- T6.1–T6.9 grün, T6.10 abgehakt; Gate 5 grün; K4 erfüllt.

---

### Phase 7 – Sofortige Rückmeldung (lokale Vorhersage)

**Ziel:** Der eigene Bau **wirkt sofort**, obwohl er erst zum Stempel ausgeführt wird. Bewegt **K3**.

#### Umsetzung

- Beim Halten eines Bau-Commands (nativer Hold in `CommandList::Add`) zeigt der eigene Client die **finale Vorschau-Geometrie als Geisterbild** (gleiche Darstellung wie Präsenz-Vorschau, eigene Farbe, „wird gebaut“-Animation) bis zur Ausführung; der gelbe Kreis entfällt.
- Kosten werden sofort als „vorgemerkt“ in der Geldanzeige angezeigt (nur Anzeige).
- Fahrzeugkauf/Linien: UI bekommt sofort einen Platzhalter-Eintrag („wird gekauft …“), echtes Ergebnis ersetzt ihn (heutiger Callback-Mechanismus über `results.log` bleibt, nur schneller).
- Bei Ablehnung durch die Engine (Kollision) oder durch Host: Geisterbild rot blinken, Meldung, verschwinden.
- **Kein Rollback der Simulation** – Vorhersage ist rein visuell; daher keine Gefahr für den Determinismus.

#### Tests zuerst

| ID | Testfall | Ebene |
|---|---|---|
| T7.1 | Geisterbild-Lebenszyklus: angelegt beim Halten, entfernt bei Ausführung/Ablehnung/Timeout/Resync | unit |
| T7.2 | Vorhersage beeinflusst Simulation nicht (wie T6.3) | sim |
| T7.3 | E2E: K3 – Zeit Klick → Geisterbild ≤ 1 Frame (Frame-Zähler) | e2e |
| T7.4 | E2E: abgelehnter Bau → Geisterbild verschwindet, Meldung erscheint, Mitspieler sieht nichts | e2e |

#### Gate 7

- T7.1–T7.4 grün; Gate 6 grün.

---

### Phase 8 – Deterministische Entity-IDs

**Ziel:** Entities, die in der Simulation entstehen, bekommen **auf allen Spielen dieselbe ID**. Damit kann `mpfever_refs.lua` von „suchen“ auf „prüfen“ reduziert werden – weniger Code, weniger Fehler, schnelleres Anwenden.

#### Spike S8 (vorab, max. 5 Tage)

Die Divergenz entsteht, weil UI/Vorschau Entities aus demselben Zähler zieht. Untersuchen:
1. Allokator der Entity-IDs finden (Signatur; Aufrufer aus UI- vs. Sim-Thread unterscheiden – Thread-ID oder Rücksprungadresse wie bei den UI-Sites).
2. Option A: UI-Allokationen in einen separaten hohen Bereich umleiten. Prüfen, ob die Engine IDs als Index in dichte Arrays nutzt (dann wäre ein hoher Bereich speicherteuer).
3. Option B: Sim-Allokationen aus einem eigenen deterministischen Zähler, UI behält den Originalzähler.
**Go:** In Test „A öffnet 50 Vorschauen, B keine, beide bauen dasselbe“ haben die neuen Entities gleiche IDs, Speicher/Performance unverändert, Speichern/Laden funktioniert.
**No-Go:** `refs` bleibt, wird aber durch Phase 9 (Entity-Hashes) besser abgesichert.

#### Tests zuerst

| ID | Testfall | Ebene |
|---|---|---|
| T8.1 | Dummy-Exe: Allokator-Hook trennt UI- und Sim-Zähler | native |
| T8.2 | Sim: Mock-Engine mit getrennten Zählern → `refs.resolve` liefert in allen Fällen „gleiche ID“ (Schnellpfad), Suchpfad wird nie benutzt | sim |
| T8.3 | E2E: Szenario „Vorschau-Sturm“ (Instanz A öffnet viele Vorschauen/Fenster, B nicht) → danach gebaute Entities ID-gleich | e2e |
| T8.4 | E2E: Speichern/Laden/Resync → IDs bleiben konsistent, Zähler werden korrekt fortgesetzt | e2e |
| T8.5 | Alle bisherigen Szenarien grün; `refs`-Suchpfad-Zähler im Report = 0 | e2e |

#### Umsetzung

- `mpf-core/src/ids.rs` (Hook + Zähler), Persistenz des Zählers im Save über Game-Script-State (damit Laden deterministisch ist).
- `mpf/refs/*`: Schnellpfad zuerst, Suchpfad nur noch als Fallback mit Warnung im Log.

#### Gate 8

- T8.1–T8.5 grün (bei No-Go: Spike-Bericht + Gate 7 grün, Phase gilt als abgeschlossen ohne Funktion).

---

### Phase 9 – Desync-Lokalisierung und gezielte Reparatur

**Ziel:** Abweichungen werden **früh, genau und billig** erkannt und möglichst **ohne Resync** behoben. Bewegt **K8, K9, K11**.

#### Umsetzung

1. **Inkrementelle Hashes:** statt alle 10 s alles zu hashen, pro Sim-Schritt einen Teil (rotierend über Entity-Buckets), plus sofortige Teil-Hashes für alles, was eine Aktion berührt hat. Zustand pro Bereich als Merkle-Baum (Bereich → Bucket → Entity).
2. **Lokalisierung:** Bei Abweichung fragt der Host den Merkle-Pfad ab, bis Entity + Komponente feststehen. Ergebnis im Log und Report („Fahrzeug #… Komponente TRANSPORT_VEHICLE.lineStopTarget differiert seit Schritt …“).
3. **Gezielte Reparatur** je Bereich, wo die API es erlaubt: Geld (wie heute), Linienparameter, Namen, Fahrzeugstatus, Konstruktionsparameter, Straßen-Dekorationen, Knoten-Konfiguration (`nodeConfigs`) – über normale Befehle zu einem Stempel auf **allen** Clients mit Host-Werten. Nicht reparierbare Bereiche → Resync (Phase 10, schnell).
4. **Ursachenjagd-Werkzeug:** `tools/mpftest desync <report>` spielt die Replay-Datei in zwei Instanzen ab und bisektiert den ersten abweichenden Schritt.
5. **Replay-Rekorder vollständig:** Core schreibt Start-Save-Hash, alle gestempelten Aktionen, Speed-Wechsel, Terrain-Daten, Hash-Verlauf.

#### Tests zuerst

| ID | Testfall | Ebene |
|---|---|---|
| T9.1 | Merkle-Struktur: Änderung einer Entity ändert genau einen Pfad; Kosten O(log n) | unit |
| T9.2 | Inkrementeller Hash ≡ Voll-Hash nach vollständiger Rotation | unit |
| T9.3 | Sim: absichtlich injizierte Abweichung (Mock ändert Komponente auf B) → Lokalisierung nennt richtige Entity + Komponente in ≤ 3 Abfragerunden | sim |
| T9.4 | Sim: reparierbare Abweichung → Reparatur-Befehl auf allen Spielen zum selben Stempel, danach Hashes gleich, kein Resync | sim |
| T9.5 | E2E: Fehlerinjektion (`MPFEVER_INJECT=line_name,vehicle_stop,money,node_config`) → Reparatur ohne Resync, Report nennt Ursache | e2e |
| T9.6 | E2E: K11 – Hash-Kosten pro Frame ≤ 2 ms auf `MPF-Test-Busy` | e2e |
| T9.7 | Replay: Aufzeichnung aus E2E-Lauf offline in zwei Instanzen abspielen → identischer Hash-Verlauf | e2e |
| T9.8 | Dauerlauf 2 h: K8 = 0 nicht reparierbare Abweichungen ohne bekannte Ursache | soak |

#### Gate 9

- T9.1–T9.8 grün; Gate 8 grün.

---

### Phase 10 – Schneller Resync und Beitritt ohne Pause

**Ziel:** Resync ≤ 8 s (K6), Beitritt ohne Pause für bestehende Spieler (K7).

#### Umsetzung

1. **Schneller Resync:**
   - Speichern beim Host im Hintergrund (Engine-Save; prüfen, ob asynchron möglich – sonst Pause nur für Speichern selbst).
   - Übertragung komprimiert (zstd) über den Bulk-Kanal; **Delta** gegenüber dem letzten gemeinsamen Save (Clients behalten ihn) – rsync-ähnliche Blockprüfsummen.
   - Laden auf den Clients parallel, Fortsetzen automatisch (heutiger `auto.lua`-Mechanismus ohne „Taste drücken“-Schirm, robuster gemacht).
   - Overlay statt schwarzer Ladebildschirm mit Fortschritt.
2. **Beitritt mit Aufholen (Catch-up):**
   - Host speichert bei Zeit T0 (Hintergrund), sendet Save + seitdem gestempelte Aktionen.
   - Neuer Spieler lädt, simuliert mit maximaler Geschwindigkeit (Schrittbefehle) von T0 bis zur aktuellen Zeit, wendet Aktionen an ihren Stempeln an.
   - Während des Aufholens zählt er **nicht** zur Barriere der anderen; erst wenn er aufgeholt hat und sein Hash passt, wird er Teil der Barriere.
   - Scheitert der Hash-Abgleich → klassischer Resync nur für den Neuen.

#### Tests zuerst

| ID | Testfall | Ebene |
|---|---|---|
| T10.1 | Delta-Übertragung: Blockprüfsummen, Rekonstruktion bitgenau, Fortsetzen nach Abbruch | unit |
| T10.2 | Session: Join-Zustände (laden → aufholen → synchron) – Barriere schließt Aufholenden aus, nimmt ihn danach auf | unit |
| T10.3 | Sim: dritter Mock-Spieler tritt bei Zeit T1 bei; Spieler 1+2 laufen ohne Stopp weiter; Spieler 3 erreicht gleichen Hash | sim |
| T10.4 | E2E: Resync-Dauer K6 ≤ 8 s auf `MPF-Test-Busy` | e2e |
| T10.5 | E2E: Beitritt während laufenden Baus – Instanz A spielt weiter (Frame-Log zeigt keine Pause), Instanz B ist nach Aufholen synchron | e2e |
| T10.6 | E2E: Resync während Spieler gerade ein Werkzeug offen hat → kein Absturz, Werkzeug wird sauber geschlossen | e2e |
| T10.7 | E2E: Kein „press any key“-Hänger in 50 aufeinanderfolgenden Resyncs | soak |

#### Gate 10

- T10.1–T10.7 grün; Gate 9 grün; K6, K7 erfüllt.

#### Risiken

- Aufholen verlangt dieselbe Determinismus-Qualität wie Lockstep; bei Abweichung Fallback auf klassischen Resync (nur für den Neuen).

---

### Phase 11 – Launcher in Rust, Installation, Updates, Absturzberichte

**Ziel:** Die C#-Anwendung wird durch einen schlanken Rust-Launcher ersetzt; Installation, Start und Diagnose werden robuster.

#### Umsetzung

- `mpf-launcher` (`MPFever.exe`): Spiel über Steam finden (Port von `GameInstall`), Mod und DLLs installieren (atomar, mit Versions-/Hash-Prüfung, Rollback), `settings.lua` sicher patchen (Backup wie heute), `steam_appid.txt`, Start mit Umgebung (`MPFEVER_DIR` …), Cold-Join (`--join`).
- **Dev-Dashboard**: `MPFever.exe --dev` öffnet eine lokale HTML-Seite (aus Core-Metriken: Peers, RTT, Vorlauf, Barrier-Stalls, Hash-Status, letzte Aktionen) – ersetzt das alte Entwicklerfenster.
- **Absturzberichte**: Minidump-Sammlung (Spiel-Crash-Ordner + Core-Logs + Session-Ordner) in ein ZIP; „Bericht erstellen“-Knopf im In-Game-Menü.
- **Update-Prüfung**: Hinweis auf neue Version (GitHub Releases), kein Auto-Download ohne Zustimmung.
- **Deinstallation**: `MPFever.exe --uninstall` stellt alles zurück (DLLs, `settings.lua`, Mod-Ordner).
- Spieler-UI bleibt im Hauptmenü des Spiels (heute `mpfever_menu.lua`), wird um Spielerleiste/Einladen/Status erweitert.

#### Tests zuerst

| ID | Testfall | Ebene |
|---|---|---|
| T11.1 | Installer gegen temporären Fake-Spielordner: frische Installation, Update, Rollback bei Fehler, Deinstallation stellt Ausgangszustand bitgenau her | unit |
| T11.2 | `settings.lua`-Patch: idempotent, bewahrt andere Mods, Backup | unit |
| T11.3 | Steam-Bibliotheken finden (libraryfolders.vdf-Varianten) | unit |
| T11.4 | Vorhandene fremde `winhttp.dll` im Spielordner → klare Warnung, nichts überschreiben ohne Zustimmung | unit |
| T11.5 | E2E: kompletter Ablauf mit neuem Launcher (alle Szenarien) | e2e |
| T11.6 | Absturzbericht: simulierter Crash (Testschalter) → ZIP enthält erwartete Dateien, keine fremden Daten | e2e |

#### Gate 11

- T11.1–T11.6 grün; Gate 10 grün; C#-Projekt entfernt, `build.bat` baut nur noch Rust + C++-Proxy.

---

### Phase 12 – Rechte, getrennte Firmen (optional)

**Ziel:** Roadmap 0.3/0.4: Host-Einstellungen (wer darf bauen/abreißen/Geld ausgeben) und – falls technisch tragfähig – getrennte Firmen auf einer Karte (laut Changelog 0.2.8 sind zusätzliche Spielerfirmen in der Engine möglich).

#### Umsetzung (Kurzfassung)

- **Rechte:** Host-seitige Prüfung jeder Aktion vor dem Stempeln (Rolle → erlaubte Aktionsarten, Budgetgrenzen); abgelehnte Aktionen → Meldung + Geisterbild rot (Phase 7).
- **Spike S12 getrennte Firmen:** zusätzliche Spieler-Entity anlegen, Aktionen im Kontext der jeweiligen Firma ausführen (`playerContext()` existiert bereits als Ansatz), Eigentum an Fahrzeugen/Linien/Stationen, Hash pro Firma.

#### Tests zuerst

| ID | Testfall | Ebene |
|---|---|---|
| T12.1 | Rechte-Matrix: jede Aktionsart × Rolle → erlaubt/abgelehnt | unit |
| T12.2 | Sim: abgelehnte Aktion wird auf keinem Spiel ausgeführt | sim |
| T12.3 | (Spike-Go) E2E: zwei Firmen, jede kauft Fahrzeug/baut Linie → Eigentum korrekt, Geld getrennt, Hashes gleich | e2e |

#### Gate 12

- T12.1–T12.2 grün (+ T12.3 bei Spike-Go); Gate 11 grün.

---

### Phase 13 – Härtung: 3–4 Spieler, Dauerläufe, Release

**Ziel:** Release-Reife von 2.0.

#### Tests zuerst / Umsetzung

| ID | Testfall | Ebene |
|---|---|---|
| T13.1 | Sim-Cluster mit 4 und 8 Spielern, netem gemischt (ein Spieler mit 250 ms RTT) | sim |
| T13.2 | E2E mit 3 Instanzen auf einem PC (falls Ressourcen reichen) oder 2 PCs + VM | e2e |
| T13.3 | Dauerlauf über Nacht (8 h): K8 = 0, keine Speicherlecks (Arbeitsspeicher-Trend), keine Abstürze | soak |
| T13.4 | Fuzzing des Protokoll-Parsers (`cargo fuzz`) 1 h ohne Fund | unit |
| T13.5 | Sicherheitsprüfung: keine beliebigen Pfade aus Netzwerkdaten (Savegame-Name, Terrain-Datei), Größenlimits, Rate-Limits pro Peer | unit |
| T13.6 | Manuelle L6-Checkliste mit zwei Menschen auf zwei PCs über Internet (Steam-Einladung) | manual |
| T13.7 | Neuer-Build-Übung: mit `sigtool diff` einen (älteren) Build „neu“ aufnehmen, Gate in < 1 h (K10) | native |

Dokumentation aktualisieren (README, INSTALL, ROADMAP, CHANGELOG), Release-Archiv, Versionsnummer 2.0.0.

#### Gate 13 = Release-Gate

- Alle Gates 0–13 grün, alle KPI-Zielwerte erreicht oder begründet dokumentiert.

---

## 6. Abhängigkeiten und Reihenfolge

```
P0 Testfundament ──► P1 Lua modular ──► P2 Rust-Core/Signaturen ──► P3 Lua↔Native direkt
                                                                         │
                                         ┌───────────────────────────────┘
                                         ▼
                                   P4 Netzwerk v2 ──► P5 Sim-Thread-Lockstep ──► P7 Sofort-Rückmeldung
                                         │
                                         ├──► P6 Präsenz (braucht unzuverlässigen Kanal aus P4)
                                         │
                                         └──► P10 Schneller Resync/Join (braucht Bulk-Kanal aus P4, profitiert von P9)
P2 ──► P8 Deterministische IDs (Spike, unabhängig von P3–P7)
P1 ──► P9 Desync-Lokalisierung (Lua-Teil früh möglich, Core-Teil nach P4)
P4 ──► P11 Rust-Launcher
P11 ──► P12 Rechte/Firmen (optional) ──► P13 Härtung/Release
```

**Empfohlene Reihenfolge für schnellen spürbaren Nutzen:** P0 → P1 → P2 → P3 → P4 → **P5 + P6 parallel** → P7 → P9 → P10 → P8 → P11 → P12 → P13.
Nach P6 hat man bereits das „zu zweit auf einer Karte“-Gefühl mit deutlich geringerer Latenz; P8–P10 machen es robust.

Grober Aufwand (eine Person, Teilzeit-Annahmen bewusst weggelassen – relative Größen):

| Phase | Größe |
|---|---|
| P0 | M |
| P1 | M |
| P2 | L |
| P3 | M (+ Spike) |
| P4 | L |
| P5 | M |
| P6 | L (+ Spike) |
| P7 | S |
| P8 | M (Spike-abhängig) |
| P9 | L |
| P10 | L |
| P11 | M |
| P12 | M–XL (Spike-abhängig) |
| P13 | M |

---

## 7. Risiken und Fallbacks

| Risiko | Auswirkung | Gegenmaßnahme / Fallback |
|---|---|---|
| Spiel-Update ändert Code | Hooks greifen nicht | Signaturen + `sigtool diff` (P2), jede Native-Funktion hat Lua-Fallback (Barriere in Lua, Dateien statt FFI, Suchpfad in refs), Core meldet „inert“ statt abzustürzen |
| Lua-FFI-Registrierung unmöglich (S3) | Kein direkter Aufruf | In-Prozess-Datei/Ringpuffer ohne Launcher-Hop |
| Sim-Thread-Blockade verursacht Ruckler (P5) | Spielgefühl schlechter | Warten in Scheiben, Schrittzeit glätten, Schalter `MPFEVER_BARRIER=lua` |
| UI-API reicht nicht für Präsenz-Overlays (S6) | Weniger schöne Darstellung | Zonen + Spielerleiste + Kamera-Sprung; Native-Render-Hook als spätere Ausbaustufe |
| ID-Allokator nicht trennbar (S8) | refs bleibt komplex | refs bleibt, abgesichert durch Merkle-Hashes (P9) |
| Steam-P2P lokal nicht testbar | T4.8 unvollständig | QUIC lokal, Steam-Test mit zweitem Account/PC in L6 |
| Restlicher Nichtdeterminismus der Engine | Resyncs bleiben | Lokalisierung + gezielte Reparatur (P9), schneller Resync (P10), Bisektions-Werkzeug |
| Rechtliches (EULA, Steamworks-Bedingungen) | Projekt gefährdet | Nur Laufzeit-Patches, keine veränderte Exe verteilen, Kontakt zu Urban Games suchen (offizielle Schnittstelle wäre langfristig ideal) |
| Ressourcen für 2 Instanzen auf einem PC | E2E langsam/instabil | Grafik-Minimalprofil, Szenarien einzeln, Dauerläufe über Nacht |

---

## 8. Anhang

### 8.1 Zielstruktur des Repositories

```
MPFever/
  build.bat                     cargo + C++-Proxy + Paket
  test.bat                      Einstieg für alle Testebenen und Gates
  Cargo.toml                    Workspace
  crates/                       mpf-proto, mpf-net, mpf-session, mpf-lockstep, mpf-hooks, mpf-core, mpf-launcher, mpf-testpeer
  native/proxy/                 winhttp.dll (C++, freestanding), build.bat, winhttp.def, kernel32.def
  signatures/                   signatures.toml, known_builds.toml (RVAs als Prüfwerte)
  mod/mpfever_1/content/
    mpfever_*.lua               dünne Einstiegspunkte (vom Spiel geladen)
    mpf/                        Module (siehe Phase 1), presence/, ui/, dev/autotest/
  tests/
    conftest.py, kpi_thresholds.toml, fixtures/ (Saves via LFS, Golden-Dateien)
    unit/  sim/  native/  e2e/  soak/  manual/checklist.md
  tools/
    mpftest/                    Runner, Analyse, KPI, Report, desync-Bisektion, Fixture-Erzeugung
    sigtool/                    (Rust, im Workspace)
  docs/
    README/INSTALL/ROADMAP/CHANGELOG (Spieler)
    dev/ARCHITECTURE.md, dev/PROTOCOL.md, dev/BASELINE.md, dev/TESTING.md, dev/NEW_GAME_BUILD.md
  reports/                      nur Baseline- und Release-Reports eingecheckt
```

### 8.2 Voraussetzungen auf dem Entwicklungsrechner

- Windows 10/11, Steam, Transport Fever 3 (aktueller Build), genug RAM/VRAM für zwei Instanzen.
- Visual Studio 2022+ (C++-Workload, Windows SDK), Rust stable (`rustup`, Ziel `x86_64-pc-windows-msvc`), Python 3.11+ (`pip install -r tests/requirements.txt`: pytest, lupa, hypothesis, jinja2), Git LFS.
- Optional: `cargo-fuzz` (nightly), `selene`, `stylua`.

### 8.3 Konventionen

- **Branch pro Phase** (`phase/03-lua-ffi`), Merge nur mit grünem Gate; Gate-Report-Link in der Merge-Beschreibung.
- **Test-IDs** (`T5.3`) stehen im Testnamen (`test_T5_3_late_action_restamped`) → Report ordnet zu.
- **Schalter**: Jede neue Native-Funktion hat einen Umgebungsschalter zum Abschalten (`MPFEVER_BARRIER=lua`, `MPFEVER_NATIVE_IPC=files`, `MPFEVER_PRESENCE=0`, `MPFEVER_IDS=legacy`) – E2E prüft beide Pfade, solange der Fallback existiert.
- **Logs**: JSON-Zeilen mit `t_game`, `t_qpc`, `peer`, `kind`; menschenlesbare Logs bleiben zusätzlich.
- **Keine Funktion ohne Messpunkt**: Was eine KPI beeinflusst, liefert Zahlen in `metrics.json`.

### 8.4 Erste konkrete Schritte (Woche 1)

1. `tests/` umbauen, pytest-Wrapper für `test_lockstep.py` und `--selftest` (T0.1, T0.2).
2. Charakterisierungstests T0.3–T0.8 schreiben (gegen heutigen Code grün).
3. `tools/mpftest/runner.py` für bestehende Autotests (T0.12) – zuerst nur Smoke.
4. Fixture `MPF-Test-Small` anlegen.
5. Baseline-Messung K1/K6 (T0.14) → `docs/dev/BASELINE.md`.
