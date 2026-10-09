"""T1.5 - the state hash (simHash, the parts the games compare every check) is the same as before the Phase 1 split:
tests/fixtures/simhash_golden_0.2.10.json was computed with the single-file bridge of 0.2.10 (commit 9985780) on the
small world of tests/fixtures/simhash_world.lua. A change of a hash part makes games of different versions disagree,
so it must be deliberate (then regenerate the golden file and say so in the commit)."""
import json
import os

import pytest

from harness import lua

pytestmark = pytest.mark.unit

FIX = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "fixtures")


def test_sim_hash_matches_0_2_10():
    L = lua.new_runtime({})
    with open(os.path.join(FIX, "simhash_world.lua"), encoding="utf-8") as f:
        L.execute(f.read())
    T = lua.load_bridge(L, expose=True)
    parts = {k: v for k, v in T.simHash(7).items() if k != "time"}
    with open(os.path.join(FIX, "simhash_golden_0.2.10.json"), encoding="utf-8") as f:
        golden = json.load(f)
    assert parts == golden


def test_sim_hash_is_deterministic():
    def run():
        L = lua.new_runtime({})
        with open(os.path.join(FIX, "simhash_world.lua"), encoding="utf-8") as f:
            L.execute(f.read())
        T = lua.load_bridge(L, expose=True)
        return {k: v for k, v in T.simHash(7).items() if k != "time"}
    assert run() == run()
