"""F15 (Phase 1/2 final test) - a replayed build that removes something is not applied when it arrives late: the
engine asserts when a vehicle moved onto a removed node (crash); the game asks for a resynchronisation instead.
Builds on time, and late builds that only add or replace, are applied as before."""
import pytest

from harness import lua

pytestmark = pytest.mark.unit

STEP = 200


@pytest.fixture
def T(tmp_path):
    L = lua.new_runtime({"MPFEVER_DIR": str(tmp_path), "MPFEVER_NAME": "Client", "MPFEVER_ROLE": "client"})
    T = lua.load_bridge(L, expose=True)
    T.L = L
    T.dir = tmp_path
    replays = L.table()
    T.replayNative = L.eval("function(rec) return function(a) rec[#rec + 1] = a.uid end end")(replays)
    T.replays = replays
    return T


def queue(T, uid, at, proposal, to_remove=0):
    a = lua.to_lua(T.L, {"uid": uid, "at": at, "fn": "makeWorldBuildProposalCmd", "origin": "Hote", "oseq": 1,
                         "args": {1: {"proposal": proposal, "toRemove": {i + 1: 1 for i in range(to_remove)}, "toAdd": {}}}})
    T.G.nativeQueue[len(T.G.nativeQueue) + 1] = a


def run(T):
    T.L.execute("GAME.time = 30000")
    T.runNativeReplays()
    out = (T.dir / "out.log").read_text(encoding="utf-8") if (T.dir / "out.log").exists() else ""
    return list(T.replays.values()), out


def test_late_removal_is_not_replayed_but_resynchronised(T):
    queue(T, "Hote:4", 30000 - 3 * STEP, {"removedNodes": {1: {}, 2: {}}, "removedSegments": {1: {}}}, to_remove=1)
    replayed, out = run(T)
    assert replayed == []
    assert "replay_failed" in out and "late removal" in out


def test_removal_on_time_is_replayed(T):
    queue(T, "Hote:5", 30000, {"removedNodes": {1: {}}, "removedSegments": {1: {}}})
    replayed, out = run(T)
    assert replayed == ["Hote:5"] and "replay_failed" not in out


@pytest.mark.parametrize("proposal", [
    {"addedNodes": {1: {}}, "addedSegments": {1: {}}},                 # a new road
    {"removedSegments": {1: {}}, "addedSegments": {1: {}}},            # an upgrade: one segment replaced
])
def test_late_build_without_removal_is_replayed(T, proposal):
    queue(T, "Hote:6", 30000 - 2 * STEP, proposal)
    replayed, out = run(T)
    assert replayed == ["Hote:6"] and "replay_failed" not in out
