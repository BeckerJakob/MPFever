"""The e2e log analysis (tools/mpftest) on lines in the formats the launcher and the bridge write (0.2.10). The sim
scenario (tests/sim) additionally runs the analysis on the logs the real bridge wrote there."""
import pytest

from tools.mpftest import analyze, kpi

pytestmark = pytest.mark.unit

RESULT = """savegame: MPF-Test-Small
both games ready
scenario newroad by host
host scenario: {["role"]="host",["ok"]=true}
scenario newroad by client
client scenario: TIMEOUT
sync: identical (desyncs 1, refused 2)
sessions: C:\\T\\mpfever\\Hote-101010-abc ; C:\\T\\mpfever\\Client-101030-def""".splitlines()

MOD = """10:41:49 native build 1 held by the DLL, released at t=44600 (now 43000) [frame 996]
10:41:50 native build 1 released at t=44600 [frame 1051]
10:41:51 native build 2 released at t=47200 (2 step(s) late) [frame 1161]
10:41:51 MARGIN act(native) -2 steps (smallest so far -2, stamp distance 7, speed 1) [frame 1167]
10:41:52 MARGIN act 5 steps (smallest so far -2, stamp distance 7, speed 1) [frame 1200]
10:41:51 LATE native build Client:5 for t=46800 applied at 47200 (2 step(s) late)
10:41:53 NATIVE REPLAY Client:5 FAILED with every form
10:35:37 gui alive frame 1200 t=41400 | slowed by other clocks 234/600 frames, by held actions 3
11:43:07 pending mark drawn for autotest build 100001
11:43:08 native build 100001 released at t=92435200 (1 step(s) late) [frame 437]
11:43:02 hash parts: conParams=2849/3764181060 ; edges=3202/3311768893 ; nodeConfigs=2726/16576""".splitlines()

LAUNCHER = """10:00:00.123 === Resynchronisation #1 on the host's game (difference: towns) ===
10:00:21.000 === Resynchronisation #1 done in 21 s ===
10:05:00.000 === Resynchronisation n°2 sur la partie de l'hôte (écart : money) ===
10:05:01.000 Resynchronisation abandonnée : les jeux ne se sont pas arrêtés.
12:03:07.859 Hote: expensive checksum (4,06 s)
12:03:08.100 Client#1 : empreinte coûteuse (3,50 s, prochaine dans 41 s)
12:03:07.929 Speed: x3 (asked by Hote)
12:03:14.104 Speed: x2 (asked by Client#1)""".splitlines()


def test_autotest_result():
    r = analyze.parse_autotest_result(RESULT)
    assert r["ready"] and r["savegame"] == "MPF-Test-Small"
    assert [(s["name"], s["role"], s["timeout"]) for s in r["scenarios"]] == [("newroad", "host", False), ("newroad", "client", True)]
    assert (r["sync"], r["desyncs"], r["refused"]) == ("identical", 1, 2)
    assert r["sessions"] == ["C:\\T\\mpfever\\Hote-101010-abc", "C:\\T\\mpfever\\Client-101030-def"]


def test_mod_log():
    r = analyze.parse_mod_log(MOD)
    assert r["held"] == [{"id": 1, "at": 44600, "now": 43000}]
    assert [x["late_steps"] for x in r["released"]] == [0, 2, 1]
    assert r["late"] == [{"what": "native build Client:5", "at": 46800, "applied": 47200, "steps": 2, "t": 10 * 3600 + 41 * 60 + 51}]
    assert [m["steps"] for m in r["margins"]] == [-2, 5] and r["stamp_distance"] == 7
    assert len(r["failed"]) == 1
    assert r["slowed"] == [{"frames": 600, "by_clocks": 234, "by_held": 3}]
    assert r["auto_builds"] == [{"id": 100001, "wall_seconds": 1}]
    assert r["hashes"] == [{"conParams": "2849/3764181060", "edges": "3202/3311768893", "nodeConfigs": "2726/16576"}]


def test_launcher_log_in_both_languages():
    r = analyze.parse_launcher_log(LAUNCHER)
    assert (r["resyncs_started"], r["resync_seconds"], r["resyncs_cancelled"]) == (2, [21], 1)
    assert r["checksum_seconds"] == [4.06, 3.5]
    assert r["speed_changes"] == [{"speed": 3, "by": "Hote"}, {"speed": 2, "by": "Client#1"}]


def test_kpis():
    run = {"autotest": analyze.parse_autotest_result(RESULT), "launcher": analyze.parse_launcher_log(LAUNCHER),
           "games": {"Hote": analyze.parse_mod_log(MOD)}}
    k = kpi.compute(run)
    assert k["native_delay_steps_max"] == 8
    assert k["late_actions"] == 1 and k["late_steps_max"] == 2
    assert k["margin_steps_min"] == -2 and k["stamp_distance_steps"] == 7
    assert k["barrier_stall_ratio"] == 0.39
    assert k["released_late_steps_max"] == 2 and k["autotest_build_wall_seconds_max"] == 1
    assert k["resyncs"] == 2 and k["resync_seconds_max"] == 21
    assert k["desyncs"] == 1 and k["scenario_timeouts"] == 1
    assert k["checksum_seconds_max"] == 4.06 and k["speed_changes"] == 2 and k["scenario_errors"] == 0


def test_per_scenario_windows():
    """One session with several scenarios: late builds and failed checks go to the scenario whose window they are in."""
    launcher = analyze.parse_launcher_log("""12:00:00.000 AUTOTEST scenario newroad by host
12:00:30.000 AUTOTEST scenario newroad by client
12:00:45.000 !!! OUT OF SYNC #1 (time 100): 2 difference(s)
12:01:00.000 AUTOTEST scenario company by host
12:01:30.000 AUTOTEST scenario company by client
12:00:55.000 Sync check #2 (time 150): IDENTICAL on 2 games (28 measures)
12:01:40.000 !!! DÉSYNCHRONISATION n°3 (temps 200) : 1 différence(s)
12:01:50.000 !!! OUT OF SYNC #4 (time 250): 1 difference(s)
12:02:10.000 !!! OUT OF SYNC #5 (time 300): 1 difference(s)""".splitlines())
    mod = analyze.parse_mod_log("""11:59:00 LATE native build Hote:0 for t=1 applied at 2 (1 step(s) late)
12:00:10 LATE native build Hote:1 for t=10 applied at 30 (4 step(s) late)
12:00:50 LATE native build Client#1:1 for t=40 applied at 50 (2 step(s) late)
12:01:35 LATE native build Hote:2 for t=60 applied at 61 (1 step(s) late)""".splitlines())
    run = {"autotest": analyze.parse_autotest_result([]), "launcher": launcher, "games": {"Hote": mod}}
    assert analyze.per_scenario(run) == {
        "newroad": {"late_actions": 2, "late_steps_max": 4, "desyncs": 1},
        "company": {"late_actions": 1, "late_steps_max": 1, "desyncs": 1},      # #4, #5: the same desync still there
    }


def test_engine_assertions_from_game_stdout():
    lines = """[2026-10-09 14:35:22Z - MESSAGE  - Main             - Main           ]  Application startup. Hello!
[2026-10-09 14:37:45Z - VERBOSE  - Main Thread      - Main           ]+ Exception type: Fatal error
    | Details:
    | Assertion Failure: Assertion `be.roadType == RoadType::STREET' failed.
[2026-10-09 14:37:59Z - VERBOSE  - Simulation Threa - Main           ]+ Exception type: Fatal error
    | Assertion Failure: Assertion `AreAllNodesEmpty(tpNetData, entity, (int)tn.nodes.size())' failed.
[2026-10-09 14:37:59Z - VERBOSE  - Simulation Threa - Main           ]+ Exception type: Fatal error
    | Assertion Failure: Assertion `AreAllNodesEmpty(tpNetData, entity, (int)tn.nodes.size())' failed.""".splitlines()
    errs = analyze.parse_game_stdout(lines)
    assert [(e["time"][-8:], e["thread"]) for e in errs] == [("14:37:45", "Main Thread"), ("14:37:59", "Simulation Threa")]
    assert analyze.parse_game_stdout(lines, since="2026-10-09 14:37:50")[0]["text"].startswith("Assertion `AreAllNodesEmpty")
    run = {"autotest": analyze.parse_autotest_result([]), "launcher": analyze.parse_launcher_log([]), "games": {},
           "engine_errors": errs}
    assert kpi.compute(run)["engine_assertions"] == 2
