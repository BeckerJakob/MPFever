# MPFever – Tests

Teststrategie und Phasen: [PLAN.md](PLAN.md). Gemessene Ausgangswerte und Befunde: [BASELINE.md](BASELINE.md).

## Schnellstart

```bat
test.bat            :: unit + sim (ohne Spiel, ~2 min)
test.bat native     :: installierte TransportFever3.exe gegen das Native-Modul prüfen (nur lesen)
test.bat gate 0     :: alles, was Phase 0 verlangt
test.bat report     :: neuesten Report öffnen
```

Beim ersten Aufruf legt `test.bat` die Python-Umgebung `.venv` an (`tests/requirements.txt`: pytest, lupa, hypothesis).
Weitere pytest-Argumente hinter der Ebene, z. B. `test.bat sim -k 3games`.

Jeder Lauf schreibt `reports/<datum>-<zeit>/results.json` und `report.html`: jeder Test mit Ergebnis, Dauer und
gemessenen Werten (`metrics`). Messwerte außerhalb von `tests/kpi_thresholds.toml` lassen den Lauf scheitern.

## Ebenen

| Ebene | Marker | Ordner | Was | Spiel nötig |
|---|---|---|---|---|
| L1 | `unit` | `tests/unit` | Lua-Module einzeln (Serializer, Hash, Reihenfolge, Taktung, Referenzen), Log-Auswertung, Launcher-Selbsttest | nein |
| L2 | `sim` | `tests/sim` | N gemockte Spiele mit den echten Lua-Dateien, Mock-Relay, Mock-DLL, Netzwerk-Emulation | nein |
| L3 | `native` | `tests/native` | Spiel-Exe vs. `native/mpfever_native.cpp`: unterstützter Build, Hook-Adressen, Prologe, UI-Sites | installiert |
| L4 | `e2e` | `tests/e2e` | Autotest des Launchers mit zwei echten Spielinstanzen, Lua-Probe im Spiel | gebaut + installiert |
| L5 | `soak` | `tests/soak` | Dauerläufe (`MPF_SOAK_SECONDS`, Standard 1800 s je Geschwindigkeit) | gebaut + installiert |

`e2e` und `soak` laufen nur mit `--run-e2e` / `--run-soak` (macht `test.bat e2e` / `soak` / `gate 0`) und werden ohne
gebautes `MPFever.exe` mit Begründung übersprungen.

## Aufbau der Offline-Harness (`tests/harness`)

- **`mock_engine.lua`** – gemockte Engine (Welt, Komponenten, Befehle, Systeme). Aus dem alten `test_lockstep.py`
  übernommen, ergänzt um den Schrittbefehl (`makeGamePerformSimulationStepsCmd`, den die Bridge seit 0.1.x nutzt) und
  `getNode2SegmentMap`.
- **Mock-DLL** (in `mock_engine.lua`): bildet „deferral of native builds v3“ nach – Werkzeug-Bauten (`TOOL_BUILD`)
  werden bei aktivem Modul gehalten, als `deferred <id>` in `native_events.log` gemeldet und auf `release <n>` in
  `native_ctl.txt` vor dem nächsten Befehl freigegeben. `Cluster(..., dll=False)` = unbekannter Spiel-Build.
- **`cluster.py`** – `MockGame` (UI-State + GUI-Hälfte + Simulation, echte Lua-Dateien), `MockRelay` (leitet wie
  `MainForm.OnHostMessage` alles weiter außer `hello`, `replay_failed`, `save_done`, `act_fail`, `act_refused`,
  `speed_req`, `sync_hash`, `det_hash`; aus `clock` wird `peerclock`), `NetEm` (Latenz/Jitter in Runden je Link zum
  Relay, Reihenfolge pro Paar bleibt wie bei TCP), `Cluster` (N Spiele, Clients „laggen“ unterschiedlich).
- **Zeitmodell:** 1 Runde = ein GUI-Frame jedes Spiels + ein Relay-Durchlauf = 40 ms virtuelle Zeit; 1 Tick = 5 Runden +
  ein Simulationsschritt-Paket = 200 ms = 1 Schritt bei Speed 1. `os.clock()`/`os.time()` laufen **virtuell**
  (sonst sind Läufe nicht reproduzierbar, siehe Befund F4).
- **Locale:** Die Tests laufen mit `LC_CTYPE=C` (Python setzt sonst die Code-Page des Benutzers, Befund F2).
- **`lua.py`** – lädt die Mod-Dateien in lupa (Lua 5.2 wie das Spiel) über ein nachgebildetes `ug_require` (jede Datei
  des Content-Ordners); `load_bridge(expose=True)` macht die gemeinsame Umgebung der Bridge-Teile (`valueHash`,
  `before`, `pacing`, `G`, `H`, …) als `MPF_T` erreichbar, ohne eine Datei zu ändern. Die Autotest-Teile lädt die
  Bridge nur mit `MPFEVER_AUTOTEST=1` (oder `MPFEVER_SAVE`).

## Aufbau der Mod (seit Phase 1)

| Datei | Inhalt |
|---|---|
| `mpfever_bridge.script.lua` | Einstieg (Spielskript): lädt die Teile mit **einer** gemeinsamen Umgebung, `data()` |
| `mpfever_br_base/exec/sim/gui/replay/native/resync/frame.lua` | die Teile der Bridge (`return function(_ENV) … end`) |
| `mpfever_dev_autotest1-3.lua` | Autotest-Szenarien (nur Test/Dev) |
| `mpfever_link.lua` | Kanäle zu MPFever.exe, UI-Hook und Native-Modul (Dateien / Speicher) |
| `mpfever_common.lua` + `mpfever_proposal.lua` | Serializer, Marshalling, Nachbau von Proposals |
| `mpfever_refs.lua`, `mpfever_ui.script.lua`, `mpfever_auto.lua`, `mpfever_menu.lua` | unverändert aufgeteilt |

Neue Dateien müssen in `mod/mpfever_1/_content.json` stehen (das Spiel lädt nur diese) – `test_modules.py` prüft das.
- **`pe.py`, `game.py`** – PE-Leser (nur lesen), Spielordner über Steam finden, `BUILDS[]`/`UI_SITES_*` aus dem
  C++-Quelltext lesen.
- **`reporting.py`** – Report + KPI-Schwellen.

`tools/mpftest` wertet echte Läufe aus (`autotest_result.txt`, Launcher-Log, `mod.log` je Spiel). Die Sim-Tests
prüfen die Auswertung zusätzlich gegen die Logs, die die echte Bridge in der Simulation schreibt.

## Konventionen

- **Test-IDs** aus PLAN.md stehen im Docstring oder in der Parameter-ID (`T0.9-3games`).
- **Befunde** (Verhalten, das als falsch erkannt, aber in dieser Phase nicht geändert wird) werden als
  `pytest.mark.xfail(strict=True, reason="Fn: …")` festgehalten: Wird der Fehler behoben, schlägt der Test als
  „xpassed“ fehl und erinnert daran, den Marker zu entfernen. Liste: BASELINE.md.
- **Szenarien prüfen Invarianten, keine festen Wartezeiten:** `cluster.tick_until(bedingung, max)`.
- Neue Messwerte über das Fixture `metrics` (`metrics["name"] = wert`), Schwellen in `tests/kpi_thresholds.toml`.

## E2E vorbereiten (einmalig)

1. **Bauen:** Visual Studio 2022+ mit den Workloads „Desktop development with C++“ und „.NET desktop development“
   (inkl. .NET Framework 4.8 Targeting Pack), dann `build.bat` → `release\dist\MPFever\MPFever.exe` + `winhttp.dll`.
   Alternativ `MPF_EXE` auf ein vorhandenes `MPFever.exe` setzen.
   - Installiert mit `winget install Microsoft.VisualStudio.2022.BuildTools` (Workloads `VCTools`,
     `ManagedDesktopBuildTools`, Komponenten `Net.Component.4.8.TargetingPack`, `NetCore.Component.SDK`).
   - Direkt nach der Installation kennt eine schon offene Konsole `C:\Program Files\dotnet` noch nicht
     („No .NET SDKs were found“): neue Konsole öffnen oder den Ordner vorn in `PATH` setzen.
   - Zwei Build-Korrekturen aus Phase 0 (MSVC 14.44): `native\build.bat` linkt `libcmt.lib` nur für `__chkstk`
     (Stack-Prüfung von `Init` mit > 4 KB lokalen Puffern; per `/VERBOSE` geprüft: nur `chkstk.obj`, das Modul
     importiert weiter nur `kernel32.dll`); `build.bat` ruft MSBuild mit `-restore` auf (SDK-Projekt, sonst NETSDK1004).
2. **Was der Launcher dabei am PC ändert** (docs/README.txt): kopiert `winhttp.dll` und `steam_appid.txt` in den
   Spielordner, trägt die Mod in `settings.lua` ein (Sicherung `settings.lua.bak_mpfever`), installiert die Mod in den
   Mods-Ordner des Steam-Benutzers. Rückgängig: siehe „UNINSTALL“ in docs/README.txt.
3. **Test-Spielstand `MPF-Test-Small`:** Spiel normal starten, neues Freies Spiel, kleinste Karte, keine weiteren Mods,
   ein paar Straßen, ein Straßendepot, eine Bushaltestelle; speichern unter genau diesem Namen. Für Dauerläufe
   `MPF-Test-Busy` (mittlere Karte mit Verkehr). Andere Namen: `MPF_SAVE=<name>`.
4. `test.bat e2e` – drei Sessions mit je zwei Spielinstanzen (viel RAM/VRAM: Grafik niedrig stellen), ~25 min:
   eine Haupt-Session spielt die sicheren Szenarien nacheinander (Host, dann Client); `stops`, `bulldoze`, `tramstop`, `roadtypes`
   können die Engine abstürzen lassen (F10) und laufen je in einer eigenen kurzen Session; dazu
   je eine kurze Session mit Speed 4 und pausiert, außerdem die Lua-Probe (eine Instanz, ~15 s). Die Ergebnisse der
   Haupt-Session werden über die Startzeiten im Launcher-Log den Szenarien zugeordnet (`analyze.per_scenario`).
   Schnelltest: `set MPF_SCENARIOS=newroad,upgrade` vor `test.bat e2e`.
   Vor jeder Session wartet der Runner, bis kein `MPFever.exe`/Spiel mehr läuft und Port 28090 frei ist.

## Neuer Spiel-Build

Seit Phase 2 findet das Native-Modul seine Hook-Adressen bei einem **unbekannten** Build über Signaturen
(`signatures/signatures.txt` → `native/signatures_gen.h`, Rel32-/RIP-Verschiebungen sind Wildcards). native.log meldet
dann „unknown game build: addresses found by their signatures“ – oder „signatures incomplete: hooks off“.

```bat
cargo build --release -p sigtool
targetelease\sigtool.exe check "<Spielordner>\TransportFever3.exe" signatures\signatures.txt
```

`check` zeigt für jede Signatur die gefundene Adresse oder „not found“/„found N times“. Für einen neuen Build, der
übernommen werden soll: Adressen bestätigen (`MPFEVER_SIGSCAN=1` loggt den Vergleich im Spiel), `signatures/known_<build>.txt`
anlegen und mit `sigtool make <exe> signatures\known_<build>.txt signatures\signatures.txt --header native\signatures_gen.h`
neue Signaturen erzeugen; `test.bat native` prüft sie gegen die installierte Exe.
