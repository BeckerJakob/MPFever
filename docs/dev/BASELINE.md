# MPFever – Baseline 0.2.10 (Phase 0)

Gemessen am 09.10.2026, Stand `b36f48d` (0.2.10-experimental). Am Mod-, Native- und Launcher-Code wurde nichts
geändert, nur zwei Build-Korrekturen (TESTING.md, „E2E vorbereiten“). Reports: `reports/baseline-0.2.10/` (offline),
`reports/baseline-0.2.10-e2e/` (echte Spiele). Teststrategie: [TESTING.md](TESTING.md).

## Umgebung

| | |
|---|---|
| Spiel | Transport Fever 3, Build **40420** (Link-Zeitstempel `0x6ac50427`), von `BUILDS[]` unterstützt |
| Lua im Spiel | **Lua 5.2.2** (in TransportFever3.exe), C-Locale, `os.setlocale` im App-Skript nicht verfügbar |
| Offline-Lua | lupa 2.8, Lua 5.2 |
| Python | 3.13.15, pytest 9.1, hypothesis 6.168 |
| Build | VS 2022 Build Tools 17.14 (MSVC 14.44), .NET SDK 9.0.318, .NET Framework 4.8 Targeting Pack |
| PC | Ryzen AI 9 HX 370, 32 GB RAM, Radeon 890M (integriert) – zwei Spielinstanzen gleichzeitig |
| E2E-Spielstand | `MPF-Test-Small` = Kopie von „Neues Spiel“ (67 MB, 2849 Konstruktionen, 3202 Straßenstücke, 258 Fahrzeuge, 39 Linien) |

## Gate-0-Stand

| ID | Test | Stand |
|---|---|---|
| T0.1 | Lockstep-Szenario 2 Spiele (alter Test, pytest) | ✅ (nach Mock-Korrektur, F3) |
| T0.2 | `MPFever.exe --selftest` | ✅ |
| T0.3 | Serializer `C.ser`/`C.deser` inkl. Property-Test | ✅ + F1, F2 (xfail) |
| T0.4 | C#-`LuaLit` ↔ Lua-Serializer | ⏸ braucht Test-Einstieg im Launcher (mit Rust-Port, Phase 4/11) |
| T0.5 | `valueHash` reihenfolgeunabhängig | ✅ + F1 (xfail) |
| T0.6 | `before` totale, stabile Ordnung (Property-Test) | ✅ |
| T0.7 | `pacing`, Stempel, Vorlauf-Formel | ✅ |
| T0.8 | Entity-Referenzen mit verschobenen IDs | ✅ |
| T0.9 | Szenario mit 3 Spielen | ✅ |
| T0.10 | Netzwerk-Emulation (Latenz/Jitter), Ausweichpfad ohne DLL | ✅ (Messwerte F5, F6) |
| T0.11 | Spiel-Exe vs. Native-Modul (offline) | ✅ |
| T0.11b | Lua-Probe im Spiel | ✅ F1 **bestätigt** (xfail), F2 im Spiel **nicht** vorhanden |
| T0.12 | E2E Smoke (2 echte Spiele) | ✅ |
| T0.13 | E2E alle 11 Szenarien + Speed 4 + pausiert | ✅ bis auf `stops` (F10, xfail); Messwerte unten |
| Offline-Suite | unit + sim + native, 1:20 min | ✅ 99 bestanden, 7 xfail (F1, F2), 1 übersprungen (T0.4) |
| E2E-Suite | eine Haupt-Session + 2 kurze Sessions + Probe, 23 min | ✅ 14 bestanden, 2 xfail (F1, F10), keine KPI-Verletzung |
| T0.14 | KPIs aus echten Läufen | ✅ |
| T0.15 | Dauerlauf | ⏸ noch nicht gelaufen (`test.bat soak`, 2 × 30 min) |

## Messwerte – Simulation (L2)

Schritt = 200 Spielzeit-Einheiten; 1 Tick ≈ 200 ms (5 Frames à 40 ms). Netzlatenz in Runden à 40 ms je Link zum Relay
(Client → Client = 2 Links).

| Messgröße | 2 Spiele | 3 Spiele | 2 Spiele, 120 ms | 3 Spiele, 320 ms + Jitter |
|---|---|---|---|---|
| Vorlauf (Stempelabstand) Speed 1 / Speed 2 | 7 / 10 | 7 / 10 | 7 / 10 | 7 / 10 |
| Lua-Befehl (Kauf) → überall angewendet | 7 Schritte | 7 | 7 | 7 |
| Werkzeug-Bau (DLL-Pfad) Host / Client → überall gebaut | 8 / 8 Schritte | 8 / 8 | 8 / 8 | 8 / 8 |
| max. Abstand zwischen Spielen (Barriere) | 2 Schritte | 2 | 2 | 2 |
| Schritte in 30 Ticks bei Speed 2 (Soll 60) | 60 | 60 | 60 | **26** |
| Spiele, die ohne DLL einen Bau zu spät bauen | – | – | – | **2 von 3** |

**K5 (Datei-Umweg):** Ein `open()` kostet auf diesem PC ~1,7 ms (Virenscanner). Der alte Test verbrachte 8,8 s von
17,8 s nur mit Dateiöffnen; die Bridge selbst öffnet `in.log` in jedem Frame.

## Messwerte – echte Spiele (L4)

Zwei komplette Durchgänge mit `MPF-Test-Small`, je zwei Instanzen auf diesem PC. Maßgeblich ist der zweite
(`reports/baseline-0.2.10-e2e/`): **eine** Session mit allen 11 Szenarien (Host, dann Client), dazu Speed 4 und
pausiert. Späte Bauten und neu entstandene Desyncs werden über die Startzeiten dem Szenario zugeordnet.

| Szenario | LATE (max. Schritte) | neue Desyncs | Bemerkung |
|---|---|---|---|
| newroad | 2 (1) | 0 | |
| upgrade | 0 | 0 | |
| tramstop | 0 | 0 | Szenario baut auf dieser Karte nicht (F13) |
| bulldoze | 1 (1) | 0 | |
| buy | 0 | 0 | |
| line | 0 | 0 | |
| split | 1 (5) | 0 | Host-Bau von der Engine abgelehnt (Kollision), Client baut |
| roadtypes | 4 (1) | **1** | Stadtgebäude 2705 ≠ 2703, Konstruktionen 2866 ≠ 2864 – bleibt bis Session-Ende (25 Prüfungen, kein Resync im Autotest) |
| terrain | 2 (2) | 0 | |
| company | 1 (5) | 0 | |
| stops | 1 (3) | 0 | Client-Timeout (F10) |
| Speed 4 (newroad, upgrade) | 0 | 0 | eigene Session |
| pausiert (newroad, upgrade) | 0 | 0 | eigene Session |

Ganze Haupt-Session (15 min): **150** teure Prüfsummen, max. **4,98 s**; **266** Geschwindigkeitswechsel;
kleinste Restmarge −5 Schritte; Barriere bremst 9 % der Frames. Erster Durchgang (eine Session je Szenario):
LATE in 9 von 13 Läufen (1–6 Schritte), Prüfsumme 3,8–4,9 s, bis 90 Geschwindigkeitswechsel in 3 min, Desyncs
bei `roadtypes` und `company`.

- **K1:** Stempelabstand im Spiel 7 (Speed 1) bis 16 (Speed 4) Schritte; ein Autotest-Bau braucht vom Ankündigen bis
  zur Freigabe 1–16 s Echtzeit (inkl. Prüfsummen-Hängern).
- **K6/K8:** Im Autotest sind Resyncs abgeschaltet – Desyncs bleiben stehen.
- **K11:** Jede Zustandsprüfung kostet **3,8–5,0 s** (Ziel PLAN.md: ≤ 2 ms je Frame).

## Befunde

| | Befund | Schwere | Test | Klärung / Phase |
|---|---|---|---|---|
| **F1** | `C.ser` und `valueHash` formatieren ganze Zahlen mit `string.format("%d")`. **Im Spiel bestätigt:** Lua 5.2.2 von TF3 wirft für 2³¹ „not a number in proper range“. Betroffen: `authValues` (Kontostand/Kredit in `sync_hash`) ab 2,147 Mrd. → `sync_hash` lässt sich nicht serialisieren, Geldabgleich fällt aus; `valueHash` großer Zahlen in Spielskripten (per `pcall` als „ERR“ im Hash). | **hoch** (späte Spielstände) | `test_serializer.py`, `test_bridge_core.py`, `test_game_lua.py::test_f1…` (xfail) | ✅ **behoben in Phase 1** (`C.int`, `"%.0f"`) |
| **F2** | `C.ser` escaped Bytes, die `%c` trifft – das folgt der Prozess-Locale. Unter einer Code-Page-Locale würden Bytes **innerhalb** von UTF-8-Zeichen escaped („í“, „Í“, „ō“ …) → ungültiges UTF-8 → `MPFever.exe` macht U+FFFD daraus → Namen weichen ab. **Im Spiel nicht vorhanden** (C-Locale, Probe). | niedrig (latent) | `test_serializer.py` (xfail), `test_game_lua.py::test_f2…` | ✅ **behoben in Phase 1** (feste Byte-Klasse statt `%c`) |
| **F3** | `tests/test_lockstep.py` war seit 0.1.0 nicht angepasst: Die Mock-Engine kannte den Schrittbefehl nicht (5 von 17 Prüfungen rot auf `b36f48d`), das Mock-Relay leitete nur `clock`/`act` weiter. | Test | – | in der Harness behoben |
| **F4** | Die UI-Logik nutzt `os.clock()` für Zeitlimits (Geschwindigkeitsanfrage max. 1/s, Resync-Claims 1,5 s). Offline ergaben gleiche Läufe unterschiedliche Ergebnisse, bis die Uhr virtualisiert wurde. Im Spiel: siehe F9 (Geschwindigkeits-Pingpong). | mittel | Harness (virtuelle Zeit) | ✅ Phase 1: eine Zeitquelle `C.clock` (Pingpong selbst: siehe F9) |
| **F5** | Ohne Native-Modul (unbekannter Spiel-Build) baut jedes Spiel, das gerade **vor** dem Bauenden liegt, dessen Bau zu spät. 3 Spiele mit Latenz: 2 von 3. | mittel (nur ohne DLL) | `test_native_build_without_native_module` | Phase 2, Phase 5 |
| **F6** | Latenz größer als das Barriere-Fenster bremst alle Spiele: 3 Spiele, 320 ms je Link → **26 statt 60 Schritte** bei Speed 2. | hoch für Internet-Spiel | `T0.10-3games-lat8-jit4` | Phase 5 |
| **F7** | Mock-Grenze: Die gemockte Bau-Proposal ist kein vollständiges Engine-Objekt („SEGMENT COUNT DIFFERS“ im Replay). | nur Harness | – | Mock in Phase 1 vervollständigen |
| **F8** | Autostart nach dem Laden unzuverlässig: In 1 von 20 Autotest-Starts blieben beide Spiele > 9 min nach dem Laden stehen (Bridge nie gestartet). `mpfever_auto.lua` schreibt in **keinem** Lauf „game loaded, starting it“: Nach `app.loadGame` startet das App-Skript neu, `S.requested` ist weg, `startWhenReady()` wird im Autotest nie aufgerufen. | mittel (Autotest; Resync-Pfad nutzt eine Datei und ist nicht betroffen) | Launcher-Wartezeit 600 s | ✅ **behoben in Phase 1** (`autoload.txt`, Test `test_auto.py`) |
| **F9** | **Zustandsprüfung friert die Simulation ein:** Der Launcher fordert alle 10 s einen Hash an; `simHash` läuft im Simulationsschritt und braucht auf `MPF-Test-Small` **3,8–4,9 s**. Die Simulation steht damit rund 40 % der Zeit still; in derselben Zeit pendelt die Geschwindigkeit (bis 90 Wechsel in 3 min, abwechselnd von Host und Client angefordert) und die Barriere bremst 8–51 % der Frames. Größere Spielstände (z. B. 84 MB) vermutlich schlimmer. | **hoch** | E2E-KPI `checksum_seconds_max` | Phase 1: **entschärft** – nächste Prüfung frühestens nach 10 × letzter Prüfdauer (≤ ~10 % Stillstand); Lösung Phase 9 |
| **F10** | **Engine-Assertions durch Autotest-Szenarien** (Neubewertung in Phase 1): Das „Stehenbleiben“ war ein Absturz mit „Fatal error“-Dialog. Die Szenarien bauen Proposals, die das Werkzeug eines Spielers so nie erzeugt: `bulldoze` entfernte ein Stück mit Fahrzeugen (`AreAllNodesEmpty(tpNetData…)`, Simulations-Thread), `tramstop` eine Haltestelle auf einem Nicht-Straßen-Stück (`be.roadType == RoadType::STREET`, Haupt-Thread). Der Zeitmess-Hook war nicht die Ursache (Vergleichslauf ohne). Risiko im Spiel: ein Replay auf einem abweichenden Spielstand könnte dieselbe Assertion treffen. | hoch (Tests), mittel (Spiel) | Spiel-Log `crash_dump/stdout.txt` → KPI `engine_assertions` (harter Fehler) | Phase 1: Szenarien wählen nur echte Straßen, `bulldoze` die neueste Sackgasse, `stops`/`bulldoze` prüfen vorher mit `makeProposalData`; Replays absichern: Phase 9 |
| **F11** | **LATE-Bauten im echten Spiel:** Durchgang 1: 13 native Bauten 1–6 Schritte zu spät (9 von 13 Läufen), meist der **erste Bau des Hosts** einer Session (4–6 Schritte); Durchgang 2: 12 in einer Session (0–4 je Szenario, bis 5 Schritte) – zeitgleich mit Prüfsummen-Hängern (F9) und Geschwindigkeitswechseln. Kleinste Restmarge −6 Schritte. | hoch | E2E-KPI `late_actions`, `late_steps_max` | Phase 5 (Barriere im Sim-Thread), F9 beheben |
| **F12** | **Echte Desyncs:** `roadtypes` in beiden Durchgängen (Stadtgebäude und Konstruktionen weichen ab – Straßen-Upgrades versetzen Stadtgebäude unterschiedlich; danach auch Personen, Fahrgäste, Lager), `company` im ersten Durchgang (der Client hat 30 s lang ein Fahrzeug und einen Namen weniger). Zusätzlich fast immer leichter Drift `nodeConfigs` (2726 ≠ 2725 nach dem ersten Bau) und `script:towns`/`towncargo`. | hoch | E2E-KPI `desyncs` (neu entstandene je Szenario) | Phase 9 (Lokalisierung), Phase 8 (IDs) |
| **F13** | `tramstop` baute auf dieser Karte nicht („factory Unknown exception“) – Ursache: Kandidaten mit anderem Straßentyp (Assertion, siehe F10). | niedrig | KPI `scenario_errors` | Phase 1: nur Stadt-/Landstraßen |

## Offen

- T0.15 Dauerlauf (2 × 30 min, `test.bat soak`) und K8 (Resyncs pro Stunde, mit eingeschalteten Resyncs außerhalb des Autotests).
- Echtzeit-Latenz Klick → beim Mitspieler sichtbar in ms (QPC-Messpunkte, `MPFEVER_TIMING` liefert die Rohdaten in
  `native.log`; Auswertung noch nicht in `tools/mpftest`).
