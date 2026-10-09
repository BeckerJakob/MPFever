"""T0.12 / T0.13 / T0.14 (e2e) - the launcher's own autotest with two real game instances on this PC:
MPFever.exe --autotest <savegame> runs each scenario of MPFEVER_SCENARIO as host, then as client, compares the games'
state, and quits.

ONE session plays every scenario (one pair of games started, the savegame loaded once - about 15 minutes instead of
one session per scenario); the results are attributed to each scenario by its time window (tools/mpftest/analyze.py,
per_scenario). Two short extra sessions: speed 4 and paused. MPF_SCENARIOS=newroad,upgrade limits the main session
for a quick check.

Before the first run: build MPFever.exe and winhttp.dll (build.bat) and create the savegame MPF-Test-Small
(docs/dev/TESTING.md). The launcher installs MPFever into the game (see tools/mpftest/runner.py)."""
import os

import pytest

from tools.mpftest import analyze, runner

pytestmark = pytest.mark.e2e

SAVE = os.environ.get("MPF_SAVE", runner.DEFAULT_SAVE)

# the scenarios the bridge implements (H.<name>); stops last: after the host's stop build its simulation can stand
# still for minutes (F10), which must not spoil the scenarios after it
FULL = ["newroad", "upgrade", "tramstop", "bulldoze", "buy", "line", "split", "roadtypes", "terrain", "company", "stops"]
SCENARIOS = [s for s in os.environ.get("MPF_SCENARIOS", ",".join(FULL)).split(",") if s]
SMOKE = ["newroad", "upgrade"]

F10 = pytest.mark.xfail(strict=False, reason="F10: the host's simulation stands still after its own stop build (docs/dev/BASELINE.md)")

# session-wide KPIs reported as they are; the per-scenario ones carry the names of tests/kpi_thresholds.toml
SESSION_KPIS = ["checksum_seconds_max", "checksums_expensive", "barrier_stall_ratio", "stamp_distance_steps",
                "speed_changes", "margin_steps_min", "released_late_steps_max", "autotest_build_wall_seconds_max"]


@pytest.fixture(scope="module")
def exe():
    p = runner.find_exe()
    if not p:
        pytest.skip("MPFever.exe not built: run build.bat (Visual Studio 2022 with C++ and .NET desktop workloads) or set MPF_EXE")
    return p


@pytest.fixture(scope="module")
def session(exe):
    """The one main session with every scenario (run once for all the tests of this module)."""
    out = runner.run_autotest(exe, SCENARIOS, SAVE, timeout=3600)
    out["per_scenario"] = analyze.per_scenario(out["analysis"])
    return out


def check_session(out, metrics, prefix=""):
    """Hard checks: what works reliably in 0.2.10. Late builds, desyncs, checksum time... are KPIs with thresholds
    (tests/kpi_thresholds.toml: the measured baseline as a regression guard, docs/dev/BASELINE.md) - known findings,
    to be brought to the targets of docs/dev/PLAN.md by the later phases."""
    a = out["analysis"]["autotest"]
    for k in SESSION_KPIS:
        if k in out["kpi"]:
            metrics[k] = out["kpi"][k]
    metrics[prefix + "session_late_actions"] = out["kpi"].get("late_actions", 0)
    metrics[prefix + "session_desyncs"] = out["kpi"].get("desyncs", 0)
    metrics["run_seconds"] = out["seconds"]
    assert a["ready"], "the two games did not get ready with savegame %r: %s" % (SAVE, a["errors"])
    assert not a["errors"], a["errors"]
    assert out["kpi"].get("failed_lines", 0) == 0, "FAILED lines in the games' logs"
    assert out["kpi"].get("resyncs", 0) == 0, "resynchronisations during the run"


def test_session(session, metrics):
    """T0.12 + T0.14: the session as a whole (both games ready, no errors, no resynchronisation) and its KPIs."""
    check_session(session, metrics)


@pytest.mark.parametrize("scenario", [pytest.param(s, marks=F10) if s == "stops" else s for s in SCENARIOS])
def test_scenario(session, scenario, metrics):
    """T0.13: one scenario of the session, as host and as client: both roles answered (no timeout); late builds and
    failed sync checks in its time window are its KPIs."""
    results = [s for s in session["analysis"]["autotest"]["scenarios"] if s["name"] == scenario]
    for k, v in session["per_scenario"].get(scenario, {}).items():
        metrics[k] = v
    metrics["scenario_errors"] = sum(1 for s in results if any(w in s["result"].lower() for w in ("exception", "failed", "error")))
    assert sorted(s["role"] for s in results) == ["client", "host"], "scenario %s did not run in both roles: %s" % (scenario, results)
    timeouts = [s["role"] for s in results if s["timeout"]]
    assert not timeouts, "scenario %s timed out as %s" % (scenario, timeouts)


@pytest.mark.parametrize("speed,paused", [(4, False), (1, True)])
def test_smoke_at_speed_and_paused(exe, speed, paused, metrics):
    """The two default scenarios at speed 4 and with the session paused (own short sessions)."""
    out = runner.run_autotest(exe, SMOKE, SAVE, speed=speed, paused=paused)
    check_session(out, metrics)
    for k in ("late_actions", "late_steps_max", "desyncs"):
        metrics[k] = out["kpi"].get(k, 0)
    assert not [s for s in out["analysis"]["autotest"]["scenarios"] if s["timeout"]], out["analysis"]["autotest"]["scenarios"]
