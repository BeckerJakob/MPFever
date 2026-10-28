"""T1.5 - the state hash (simHash, the parts the games compare at every checkpoint) on the small world of
tests/fixtures/simhash_world.lua is the one of 0.5.12 (tests/fixtures/simhash_golden_0.5.12.json). A change of a hash part
makes games of different versions disagree, so it must be deliberate: then regenerate the golden file and say so in the
commit."""
import json
import os

import pytest

from harness import lua

pytestmark = pytest.mark.unit

FIX = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "fixtures")
GOLDEN = os.path.join(FIX, "simhash_golden_0.5.12.json")
# the expensive parts that take turns (issue #32), one group per checkpoint
GROUPS = ({"conParams"}, {"edges", "ages"}, {"constructions", "nodeConfigs"})


@pytest.fixture(autouse=True)
def _restore_env():
    # (the bridge reads MPFEVER_HASHROT when it hashes: set for the test only)
    was = os.environ.pop("MPFEVER_HASHROT", None)
    yield
    os.environ.pop("MPFEVER_HASHROT", None)
    if was is not None:
        os.environ["MPFEVER_HASHROT"] = was


def bridge(rot=None):
    L = lua.new_runtime({})
    if rot:
        os.environ["MPFEVER_HASHROT"] = rot
    else:
        os.environ.pop("MPFEVER_HASHROT", None)
    with open(os.path.join(FIX, "simhash_world.lua"), encoding="utf-8") as f:
        L.execute(f.read())
    return lua.load_bridge(L, expose=True)


def parts(T, n=None):
    return {k: v for k, v in T.simHash(7, None, n).items() if k != "time"}


def test_sim_hash_matches_golden():
    with open(GOLDEN, encoding="utf-8") as f:
        assert parts(bridge()) == json.load(f)


def test_sim_hash_is_deterministic():
    assert parts(bridge()) == parts(bridge())


def test_rotating_groups_cover_the_full_hash():
    """checkpoint n hashes the cheap parts and group n % 3: each expensive part is right in exactly its own group, the
    cheap ones in every checkpoint, and the same n gives the same group on every game."""
    T = bridge("1")
    full = parts(T)
    rotating = set().union(*GROUPS)
    for n in range(3):
        part = parts(T, n)
        keep = GROUPS[n % 3]
        for k, v in full.items():
            if k in keep or k not in rotating:
                assert part.get(k) == v, "checkpoint %d: %s" % (n, k)
            else:
                assert part.get(k) != v, "checkpoint %d hashes %s, of another group" % (n, k)
    assert parts(T, 4) == parts(T, 1)


def test_no_rotation_without_a_checkpoint_number_or_when_off():
    assert parts(bridge("1")) == parts(bridge("0"), 1) == parts(bridge())
