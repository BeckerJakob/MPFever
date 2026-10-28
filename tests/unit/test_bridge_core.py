"""T0.5 / T0.6 / T0.7 - core functions of the bridge (mpfever_bridge.script.lua), characterised as they are in 0.2.10:
valueHash (state comparison of game scripts), before (order of actions applied at the same game time), pacing (the
barrier: how fast this game may run), stampFor / pausedStamp (when an action issued now is applied everywhere)."""
import itertools
import random

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from harness import lua

pytestmark = pytest.mark.unit

STEP = 200


@pytest.fixture(scope="module")
def L():
    return lua.new_runtime({})


@pytest.fixture(scope="module")
def T(L):
    return lua.load_bridge(L, expose=True)


# ------------------------------------------------------------------ T0.5 valueHash

def build_table(L, items, order, holes=False):
    """Lua table with the same content, filled in another order (and optionally with keys added and removed first,
    which changes the internal layout and the pairs() order)."""
    t = L.table()
    if holes:
        for i in range(50):
            t["tmp%d" % i] = i
    for k in order:
        t[k] = items[k]
    if holes:
        for i in range(50):
            t["tmp%d" % i] = None
    return t


def test_value_hash_ignores_insertion_order(L, T):
    items = {"a": 1, "b": "two", "c": True, 4: 4.5, "nested": None}
    keys = [k for k in items if items[k] is not None]
    hashes = set()
    for order in itertools.permutations(keys):
        for holes in (False, True):
            hashes.add(T.valueHash(build_table(L, items, order, holes), 0))
    assert len(hashes) == 1


def test_value_hash_ignores_local_counters(L, T):
    a = lua.to_lua(L, {"x": 1, "revision": 5, "guiTimeSeconds": 12.5})
    b = lua.to_lua(L, {"x": 1, "revision": 99, "guiTimeSeconds": 0})
    assert T.valueHash(a, 0) == T.valueHash(b, 0)


@pytest.mark.parametrize("a,b", [
    ({"x": 1}, {"x": 2}),
    ({"x": 1}, {"y": 1}),
    ({"x": "1"}, {"x": 1}),
    ({"x": True}, {"x": False}),
    ({"x": {"y": 1}}, {"x": {"y": 2}}),
    ({"x": 0.5}, {"x": 0.25}),
])
def test_value_hash_sees_differences(L, T, a, b):
    assert T.valueHash(lua.to_lua(L, a), 0) != T.valueHash(lua.to_lua(L, b), 0)


def test_value_hash_float_precision(L, T):
    # characterisation: non-integral numbers are compared with 6 significant digits (%.6g)
    assert T.valueHash(0.1234561, 0) == T.valueHash(0.1234564, 0)
    assert T.valueHash(0.123456, 0) != T.valueHash(0.123457, 0)


def test_value_hash_depth_limit(L, T):
    deep = L.eval("(function() local r = {} local x = r for i = 1, 30 do x.n = {} x = x.n end x.v = 1 return r end)()")
    deep2 = L.eval("(function() local r = {} local x = r for i = 1, 30 do x.n = {} x = x.n end x.v = 2 return r end)()")
    # characterisation: below 14 levels the content is not compared any more
    assert T.valueHash(deep, 0) == T.valueHash(deep2, 0)


def test_value_hash_large_integer(T):
    # F1 (fixed in Phase 1): integers beyond 32 bits are hashed like the others
    assert T.valueHash(3000000000, 0) != T.valueHash(3000000001, 0)
    assert T.valueHash(7, 0) == T.valueHash(7.0, 0)


def test_counts_hash_is_a_multiset(L, T):
    a = T.countsHash(lua.to_lua(L, [3, 1, 2, 2]))
    b = T.countsHash(lua.to_lua(L, [2, 3, 2, 1]))
    c = T.countsHash(lua.to_lua(L, [3, 1, 2, 3]))
    assert a == b and a != c


# ------------------------------------------------------------------ T0.6 before (order of simultaneous actions)

def lua_sort(L, T, actions):
    t = lua.to_lua(L, actions)
    L.globals().table.sort(t, T.before)
    return [(x["at"], x["origin"], x["oseq"]) for x in lua.to_py(t).values()]


actions = st.lists(
    st.tuples(st.integers(0, 5).map(lambda s: 18600 + s * STEP), st.sampled_from(["Hote", "Client", "Client2", ""]), st.integers(0, 6)),
    min_size=1, max_size=25, unique=True)


@settings(max_examples=200, deadline=None)
@given(actions, st.randoms(use_true_random=False))
def test_before_gives_the_same_order_from_any_arrival_order(L, T, acts, rnd):
    items = [{"at": a, "origin": o, "oseq": s} for a, o, s in acts]
    shuffled = items[:]
    rnd.shuffle(shuffled)
    assert lua_sort(L, T, items) == lua_sort(L, T, shuffled) == sorted(acts)


def test_before_is_a_strict_order(L, T):
    rnd = random.Random(3)
    xs = [lua.to_lua(L, {"at": rnd.choice([1, 2]), "origin": rnd.choice(["A", "B"]), "oseq": rnd.randint(0, 3)}) for _ in range(40)]
    for x in xs:
        assert not T.before(x, x)
        for y in xs:
            if T.before(x, y):
                assert not T.before(y, x)
            for z in xs:
                if T.before(x, y) and T.before(y, z):
                    assert T.before(x, z)


def test_before_missing_origin_and_seq_sort_first(L, T):
    a = lua.to_lua(L, {"at": 1})
    b = lua.to_lua(L, {"at": 1, "origin": "A", "oseq": 1})
    assert T.before(a, b) and not T.before(b, a)


# ------------------------------------------------------------------ T0.7 pacing (barrier) and stamps

@pytest.fixture
def P(L, T):
    """Resets the bridge's GUI state for one pacing case; returns a helper."""
    G = T.G
    G.session = lua.to_lua(L, {"speed": 1, "started": True})
    G.peers = L.table()
    G.holdAt = None
    G.window = 3
    G.pstat = lua.to_lua(L, {"frames": 0, "barrier": 0, "hold": 0})
    G.wantSteps = None
    T.O.steps = None
    L.execute("GAME.time = 30000")

    class Helper:
        def now(self, t):
            L.execute("GAME.time = %d" % t)

        def peer(self, name, t):
            G.peers[name] = lua.to_lua(L, {"t": t})

        def session(self, **kw):
            G.session = lua.to_lua(L, dict({"started": True, "speed": 1}, **kw))

        def pace(self):
            return T.pacing()

    return Helper()


def test_pacing_not_started_is_paused(L, T, P):
    P.session(started=False)
    assert P.pace() == 0


def test_pacing_alone_runs_at_session_speed(P):
    P.session(speed=3)
    assert P.pace() == 3


def test_pacing_waits_for_the_slowest_peer(L, T, P):
    P.peer("Client", 30000 - 3 * STEP)       # barrier = peer + window(3) * STEP = 30000 = now
    assert P.pace() == 0
    assert T.G.pstat.barrier == 1
    P.peer("Client", 30000 - 2 * STEP)       # one step of room left
    assert P.pace() == 1


def test_pacing_uses_the_minimum_of_all_peers(P):
    P.peer("Client", 30400)
    P.peer("Client2", 30000 - 3 * STEP)
    assert P.pace() == 0


def test_pacing_stops_at_the_pause(P):
    P.session(speed=1, pauseAt=30000)
    assert P.pace() == 0


def test_pacing_steps_exactly_to_a_stop_point(L, T, P):
    T.O.steps = L.eval("function(n) return n end")
    P.session(speed=1, pauseAt=30000 + 2 * STEP)
    assert P.pace() == 0
    assert T.G.wantSteps == 2


def test_pacing_without_step_command_slows_down_near_a_stop_point(P):
    P.session(speed=4, pauseAt=30000 + 2 * STEP)
    assert P.pace() == 1


def test_pacing_held_action_runs_at_least_at_speed_one(L, T, P):
    P.session(speed=0)
    T.G.holdAt = 31000
    assert P.pace() == 1


def test_stamp_distance_formula(L, T):
    # characterisation (guiUpdate): window = speed + 2, ahead = window + (2 * speed + 1) + 1 steps
    for speed, ahead in ((1, 7), (2, 10), (4, 16)):
        window = speed + 2
        assert window + (2 * speed + 1) + 1 == ahead
        assert T.adaptAhead(ahead) == ahead      # MPFEVER_ADAPTAHEAD not set: never shortened


def test_stamp_for_respects_the_floor(L, T):
    T.G.ahead = 7
    T.G.stampFloor = 0
    assert T.stampFor(30000) == 30000 + 7 * STEP
    T.G.stampFloor = 40000
    assert T.stampFor(30000) == 40000


def test_paused_stamp_is_the_latest_clock(L, T):
    T.G.peers = lua.to_lua(L, {"A": {"t": 30400}, "B": {"t": 29800}})
    assert T.pausedStamp(30000) == 30400
    assert T.pausedStamp(31000) == 31000


def test_parse_line(T):
    assert tuple(T.parseLine('act\tHote\t{["a"]=1}')) == ("act", "Hote", '{["a"]=1}')
    assert tuple(T.parseLine("garbage")) == (None, None, None)
