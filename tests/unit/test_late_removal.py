"""F15 - a replayed native build that removes something (nodes, constructions, more segments than it adds) is not applied
when it arrives after its step: the place may have changed since, and the engine asserts when it removes a node something
is still connected to (AreAllNodesEmpty). The game asks the host for a reload (replay_failed) instead. Builds on time, late
builds that only add or replace, terrain edits and tree builds are replayed as before; MPFEVER_LATEREMOVAL=0 turns it off."""
import os

import pytest

from harness import lua

pytestmark = pytest.mark.unit

STEP = 200
NOW = 30000


@pytest.fixture
def T(tmp_path):
    L = lua.new_runtime({"MPFEVER_DIR": str(tmp_path), "MPFEVER_NAME": "Client", "MPFEVER_ROLE": "client"})
    os.environ.pop("MPFEVER_LATEREMOVAL", None)
    T = lua.load_bridge(L, expose=True)
    T.L = L
    T.dir = tmp_path
    yield T
    os.environ.pop("MPFEVER_LATEREMOVAL", None)


def build(T, uid, at, proposal, to_remove=0, fn="makeWorldBuildProposalCmd"):
    return lua.to_lua(T.L, {"uid": uid, "at": at, "fn": fn, "native": True, "origin": "Hote", "oseq": 1,
                            "args": {1: {"proposal": proposal, "toRemove": {i + 1: 1 for i in range(to_remove)}, "toAdd": {}}}})


REMOVAL = {"removedNodes": {1: {}, 2: {}}, "removedSegments": {1: {}}}


@pytest.mark.parametrize("proposal,to_remove,removes", [
    (REMOVAL, 0, True),                                                 # the bulldozer on a road
    ({}, 1, True),                                                      # a construction removed
    ({"removedSegments": {1: {}, 2: {}}, "addedSegments": {1: {}}}, 0, True),   # two segments become one
    ({"addedNodes": {1: {}}, "addedSegments": {1: {}}}, 0, False),      # a new road
    ({"removedSegments": {1: {}}, "addedSegments": {1: {}}}, 0, False), # an upgrade: one segment replaced
    ({"removedSegments": {1: {}}, "addedSegments": {1: {}, 2: {}}}, 0, False),  # a road cut by a new junction
])
def test_what_counts_as_a_removal(T, proposal, to_remove, removes):
    assert bool(T.G.lateRemoval(build(T, "Hote:1", NOW, proposal, to_remove))) is removes


@pytest.mark.parametrize("fn", ["terrainEdit", "assetBuild", "mpfCoJoin"])
def test_other_kinds_are_never_held_back(T, fn):
    assert not T.G.lateRemoval(build(T, "Hote:2", NOW, REMOVAL, 1, fn=fn))


def test_switch_turns_it_off(T):
    os.environ["MPFEVER_LATEREMOVAL"] = "0"
    assert not T.G.lateRemoval(build(T, "Hote:3", NOW, REMOVAL, 1))


def run(T, a):
    T.L.execute("GAME.time = %d" % NOW)
    T.G.stepTarget = NOW        # (the engine stands at this time: a replay due goes, see G.sendStillWait)
    T.G.nativeQueue[len(T.G.nativeQueue) + 1] = a
    T.runNativeReplays()
    out = (T.dir / "out.log").read_text(encoding="utf-8") if (T.dir / "out.log").exists() else ""
    return out


def test_late_removal_is_not_replayed_but_resynchronised(T):
    out = run(T, build(T, "Hote:4", NOW - 3 * STEP, REMOVAL, 1))
    assert "replay_failed" in out and "late removal" in out
    assert len(T.G.nativeQueue) == 0


def test_removal_on_time_goes_to_the_replay(T):
    out = run(T, build(T, "Hote:5", NOW, REMOVAL, 1))
    assert "late removal" not in out


def test_late_build_without_removal_goes_to_the_replay(T):
    out = run(T, build(T, "Hote:6", NOW - 2 * STEP, {"addedNodes": {1: {}}, "addedSegments": {1: {}}}))
    assert "late removal" not in out
