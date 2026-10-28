"""T6.1 / T6.2 / T6.3 / T6.5 - presence: the other players' mouse and view on the map (G.presenceTick, H.presence). Two
mocked games; the mock's interface records the zones a game draws (ZONES) and lets a test move a game's mouse (MOUSE) and
camera (CAMERA). (What a player is about to build, and builds on their way, are upstream's previews and pending marks.)"""
import os

import pytest

from harness.cluster import TAB, Cluster, NetEm

pytestmark = pytest.mark.sim

ROAD = """{ toAdd = {}, toRemove = {}, proposal = {
  addedNodes = { { entity = -1, comp = { position = { x = 50, y = 50, z = 0 } } } },
  addedSegments = { { entity = -2, comp = { node0 = 60, node1 = -1 } } } } }"""


def start(tmp, netem=None):
    c = Cluster(tmp, n=2, netem=netem or NetEm())
    c.tick(20)
    c.relay.started, c.relay.speed = True, 1
    c.relay.session()
    c.tick(10)
    return c


def zones(g):
    return {k: {"x": v.x, "y": v.y, "r": v.r} for k, v in g.L.eval("ZONES").items()}


def mark(g, who, what):
    """the zone game g draws for player who: "c" the mouse, "k" the view (None when not drawn)"""
    q = g.T.G.pres.seen[who]
    return zones(g).get("mpfever_p_%s_%s" % (q.tag, what)) if q else None


def marks_of(g, who):
    q = g.T.G.pres.seen[who]
    return [k for k in zones(g) if q and k.startswith("mpfever_p_%s_" % q.tag)]


def sent_presence(g):
    return [l for l in g.read("out.log") if l.split(TAB, 1)[0] == "presence"]


def test_cursor_and_camera_appear_on_the_other_game(tmp_path, metrics):
    c = start(str(tmp_path))
    A, B = c.games
    A.L.execute("MOUSE = { x = 120, y = -40 }; CAMERA = { x = 100, y = -30 }")
    used = c.tick_until(lambda: (mark(B, "Hote", "c") or {}).get("x", 0) > 119, 60)
    assert used is not None, zones(B)
    z, k = mark(B, "Hote", "c"), mark(B, "Hote", "k")
    assert abs(z["x"] - 120) < 1 and abs(z["y"] + 40) < 1
    assert k["x"] == 100 and k["y"] == -30 and k["r"] > z["r"]
    # and the other way round
    B.L.execute("MOUSE = { x = -5, y = 7 }")
    assert c.tick_until(lambda: mark(A, "Client", "c") is not None, 30) is not None
    # a game never draws itself
    assert A.T.G.pres.seen["Hote"] is None and B.T.G.pres.seen["Client"] is None
    metrics["presence_ticks_to_show"] = used


def test_updates_are_small_and_only_when_something_moves(tmp_path, metrics):
    c = start(str(tmp_path))
    A = c.games[0]
    A.L.execute("MOUSE = { x = 1, y = 1 }")
    c.tick(10)
    n0 = len(sent_presence(A))
    c.tick(30)                     # nothing moves: at most a heartbeat
    n1 = len(sent_presence(A))
    assert n1 - n0 <= 1
    for i in range(6):            # (a tick is 5 interface frames: 30 frames)
        A.L.execute("MOUSE = { x = %d, y = 1 }" % (10 + 10 * i))
        c.tick(1)
    n2 = len(sent_presence(A))
    assert n2 - n1 >= 4, "a moving mouse is sent (%d updates in 30 frames)" % (n2 - n1)
    assert n2 - n1 <= 6, "at most one update every 6 frames (%d in 30)" % (n2 - n1)
    sizes = [len(l.encode("utf-8")) for l in sent_presence(A)]
    metrics["presence_bytes_max"] = max(sizes)
    assert max(sizes) < 200


def test_cursor_moves_smoothly(tmp_path):
    c = start(str(tmp_path))
    A, B = c.games
    A.L.execute("MOUSE = { x = 0, y = 0 }")
    c.tick_until(lambda: mark(B, "Hote", "c") is not None, 30)
    A.L.execute("MOUSE = { x = 100, y = 0 }")
    xs = []
    for _ in range(12):
        c.tick(1)
        xs.append(mark(B, "Hote", "c")["x"])
    # moves towards 100 without jumping there at once, never overshoots, arrives
    assert all(b >= a for a, b in zip(xs, xs[1:]))
    assert xs[-1] > 95 and max(xs) <= 100.0001
    assert any(0 < x < 95 for x in xs), xs


def test_cursor_goes_when_the_mouse_leaves_the_ground(tmp_path):
    c = start(str(tmp_path))
    A, B = c.games
    A.L.execute("MOUSE = { x = 3, y = 4 }")
    c.tick_until(lambda: mark(B, "Hote", "c") is not None, 30)
    A.L.execute("MOUSE = nil")
    assert c.tick_until(lambda: mark(B, "Hote", "c") is None, 30) is not None
    assert mark(B, "Hote", "k") is not None            # the view stays


def test_marks_go_when_a_player_leaves_or_goes_quiet(tmp_path):
    c = start(str(tmp_path))
    A, B = c.games
    A.L.execute("MOUSE = { x = 3, y = 4 }")
    c.tick_until(lambda: mark(B, "Hote", "c") is not None, 30)
    tag = B.T.G.pres.seen["Hote"].tag
    B.write("peerleft" + TAB + "Hote" + TAB + '{["name"]="Hote"}')
    c.tick(2)
    assert not [k for k in zones(B) if k.startswith("mpfever_p_%s_" % tag)]
    # timeout: no update for PRESENCE.timeout frames
    A.L.execute("MOUSE = { x = 30, y = 4 }")
    c.tick_until(lambda: mark(B, "Hote", "c") is not None, 30)
    tag = B.T.G.pres.seen["Hote"].tag
    B.T.G.PRESENCE.timeout = 30
    A.T.G.PRESENCE.heartbeat = 100000
    A.L.execute("MOUSE = { x = 30, y = 4 }")
    c.tick(45)
    assert not [k for k in zones(B) if k.startswith("mpfever_p_%s_" % tag)]


def test_switched_off_by_the_host(tmp_path):
    os.environ["MPFEVER_PRESENCE"] = "0"
    try:
        c = start(str(tmp_path))
        A, B = c.games
        A.L.execute("MOUSE = { x = 3, y = 4 }")
        c.tick(30)
        assert sent_presence(A) == [] and not [k for k in zones(B) if k.startswith("mpfever_p_")]
    finally:
        os.environ.pop("MPFEVER_PRESENCE", None)


def test_presence_does_not_change_the_simulation(tmp_path):
    """T6.3: the same actions with and without a busy mouse: same results at the same game times."""
    def run(sub, busy):
        c = start(str(tmp_path / sub), NetEm(latency=2, jitter=2, seed=3))
        A, B = c.games
        for i in range(40):
            if busy:
                A.L.execute("MOUSE = { x = %d, y = %d }" % (i * 7, -i * 3))
                B.L.execute("MOUSE = { x = %d, y = %d }; CAMERA = { x = %d, y = 0 }" % (-i, i, i * 11))
            if i == 5:
                B.ui("api.cmd.sendCommand(api.cmd.makeVehicleBuyCmd(7, 55, { vehicles = {} }), function() end)")
            if i == 12:
                A.tool_build(ROAD)
            c.tick(2)
        c.tick(30)
        return A.applied(), B.applied(), A.T.simHash(0).constructions
    quiet, busy = run("quiet", False), run("busy", True)
    assert quiet == busy
    assert quiet[0] == quiet[1] and len(quiet[0]) == 2
