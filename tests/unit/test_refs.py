"""T0.8 - entity references (mpfever_refs.lua). Two worlds that share the savegame's entities but number everything
built during the session differently (game B allocates 1000 higher), as in the real game: a reference described on
game A, sent through the protocol serializer, must resolve to game B's own entity - or to nothing."""
import pytest

from harness import lua

pytestmark = pytest.mark.unit

# entities built during the session (same things, other ids): (offset A, offset B) = (50000, 51000)
SESSION = """
local o = %d
WORLD[o + 10] = { CONSTRUCTION = { fileName = "station.con", transf = { [13] = 300, [14] = 400, [15] = 0 }, depots = {}, stations = { o + 11, o + 12 } } }
WORLD[o + 11] = { STATION = {} }
WORLD[o + 12] = { STATION = {} }
WORLD[o + 20] = { CONSTRUCTION = { fileName = "depot.con", transf = { [13] = 700, [14] = 100, [15] = 0 }, depots = { o + 21, o + 22 }, stations = {} } }
WORLD[o + 21] = { VEHICLE_DEPOT = {} }
WORLD[o + 22] = { VEHICLE_DEPOT = {} }
WORLD[o + 30] = { BASE_NODE = { position = { x = 5, y = 5, z = 0 } } }
WORLD[o + 40] = { BASE_EDGE = { node0 = %s, node1 = %s, objects = {} } }
WORLD[o + 50] = { LINE = {} }
WORLD[o + 60] = { TRANSPORT_VEHICLE = {} }
"""


def world(offset, reverse_edge=False, shift=None):
    L = lua.new_runtime({})
    a, b = ("60", "o + 30") if not reverse_edge else ("o + 30", "60")
    L.execute(SESSION % (offset, a, b))
    if shift:
        L.execute("WORLD[%d].CONSTRUCTION.transf[13] = WORLD[%d].CONSTRUCTION.transf[13] + %s" % (offset + 10, offset + 10, shift))
    return L, lua.load_common(L), lua.load_refs(L)


@pytest.fixture(scope="module")
def A():
    return world(50000)


@pytest.fixture(scope="module")
def B():
    return world(51000)


def ship(src, dst, kind, entity):
    """describe on src, serialize, deserialize on dst, resolve on dst."""
    Ls, Cs, Rs = src
    Ld, Cd, Rd = dst
    text = Cs.ser(Rs.describe(kind, entity))
    return Rd.resolve(Cd.deser(text))


@pytest.mark.parametrize("kind,a,b", [
    ("con", 50010, 51010),
    ("station", 50012, 51012),
    ("depot", 50022, 51022),
    ("node", 50030, 51030),
    ("edge", 50040, 51040),
    ("depot", 55, 55),          # from the savegame: same id everywhere
    ("node", 60, 60),
])
def test_reference_resolves_to_the_local_entity(A, B, kind, a, b):
    assert ship(A, B, kind, a) == b


def test_edge_resolves_whatever_its_direction():
    assert ship(world(50000), world(51000, reverse_edge=True), "edge", 50040) == 51040


@pytest.mark.parametrize("shift,found", [(0.5, True), (2.5, True), (3.5, False)])
def test_construction_position_tolerance(A, shift, found):
    # characterisation: same file within 3 m (search), exact id within 1 m
    B = world(51000, shift=shift)
    assert ship(A, B, "con", 50010) == (51010 if found else None)


def test_reference_to_something_missing_resolves_to_nothing(A):
    L, C, R = world(51000)
    L.execute("WORLD[51020] = nil")   # the depot's construction does not exist here
    L.execute("WORLD[51021] = nil; WORLD[51022] = nil")
    assert ship(A, (L, C, R), "depot", 50022) is None


def test_plain_ids_and_player(A, B):
    La, Ca, Ra = A
    Lb, Cb, Rb = B
    assert Rb.resolve(lua.to_lua(Lb, {"k": "player", "id": 7})) == 7
    assert Rb.resolve(lua.to_lua(Lb, {"k": "veh", "id": 100})) == 100       # exists (town 100)
    assert Rb.resolve(lua.to_lua(Lb, {"k": "veh", "id": 424242})) is None


def test_translate_out_and_in_with_creation_keys(A, B):
    """A line assignment by game A: its vehicle and line were created by replicated actions (keys Hote:1, Hote:2);
    game B resolves the keys to its own vehicle and line."""
    La, Ca, Ra = A
    Lb, Cb, Rb = B
    margs = lua.to_lua(La, {1: 50060, 2: 50050, 3: 0, "n": 3})
    rev = lua.to_lua(La, {50060: "Hote:1", 50050: "Hote:2"})
    Ra.translateOut("makeVehicleSetLineCmd", margs, rev)
    text = Ca.ser(margs)
    got = Cb.deser(text)
    missing = Rb.translateIn(got, lua.to_lua(Lb, {"Hote:1": 51060, "Hote:2": 51050}))
    assert len(missing) == 0
    assert (got[1], got[2], got[3]) == (51060, 51050, 0)


def test_translate_in_reports_what_is_missing(A, B):
    La, Ca, Ra = A
    Lb, Cb, Rb = B
    margs = lua.to_lua(La, {1: 7, 2: 50022, "n": 2})
    Ra.translateOut("makeVehicleBuyCmd", margs, None)
    Lc, Cc, Rc = world(52000)
    Lc.execute("WORLD[52020] = nil")
    got = Cc.deser(Ca.ser(margs))
    missing = lua.to_py(Rc.translateIn(got, None))
    assert list(missing.values()) == ["depot#50022"]
    assert got[2] == -999999999            # never executed with a wrong id


def test_translate_out_road_proposal(A, B):
    """A road from the existing node 60 to a new node: node0 is described, the new node (negative id) stays."""
    La, Ca, Ra = A
    Lb, Cb, Rb = B
    proposal = {1: {"toAdd": {}, "toRemove": {}, "proposal": {
        "addedNodes": {1: {"entity": -1, "comp": {"position": {"x": 9, "y": 9, "z": 0}}}},
        "addedSegments": {1: {"entity": -2, "comp": {"node0": 50030, "node1": -1}}}}}, "n": 1}
    margs = lua.to_lua(La, proposal)
    Ra.translateOut("makeWorldBuildProposalCmd", margs, None)
    got = Cb.deser(Ca.ser(margs))
    assert len(Rb.translateIn(got, None)) == 0
    seg = got[1].proposal.addedSegments[1]
    assert (seg.entity, seg.comp.node0, seg.comp.node1) == (-2, 51030, -1)
