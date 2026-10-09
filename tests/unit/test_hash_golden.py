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


def test_rotating_groups_cover_the_full_hash():
    """Phase 9 (F9): check n hashes group n % 3; together the groups give exactly the full hash, every part in one
    group, money/time/terrain in every check."""
    L = lua.new_runtime({})
    with open(os.path.join(FIX, "simhash_world.lua"), encoding="utf-8") as f:
        L.execute(f.read())
    T = lua.load_bridge(L, expose=True)
    full = {k: v for k, v in T.simHash(7).items() if k != "time"}
    seen = {}
    for n in range(3):
        part = {k: v for k, v in T.simHash(7, n).items() if k != "time"}
        for always in ("money", "terrain"):
            assert always in part
        for k, v in part.items():
            if k not in ("money", "terrain"):
                assert k not in seen, "%s in two groups" % k
                seen[k] = v
        assert len(part) < len(full)
    seen.update({k: full[k] for k in ("money", "terrain")})
    assert seen == full
    # the same n gives the same group on every game
    assert dict(T.simHash(7, 4).items()).keys() == dict(T.simHash(7, 1).items()).keys()
