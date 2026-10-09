"""T6.1 / T6.2 / T6.3 / T6.5 (Phase 6) - presence: the other players' mouse, camera and pending builds on the map.
Two mocked games; the mock's interface records the zones a game draws (ZONES) and lets a test move a game's mouse
(MOUSE) and camera (CAMERA)."""
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


def sent_presence(g):
    return [l for l in g.read("out.log") if l.split(TAB, 1)[0] == "presence"]


def test_cursor_and_camera_appear_on_the_other_game(tmp_path, metrics):
    c = start(str(tmp_path))
    A, B = c.games
    A.L.execute("MOUSE = { x = 120, y = -40 }; CAMERA = { x = 100, y = -30 }")
    used = c.tick_until(lambda: "mpfever_p_Hote_c" in zones(B), 20)
    assert used is not None, zones(B)
    c.tick(5)
    z = zones(B)
    assert abs(z["mpfever_p_Hote_c"]["x"] - 120) < 1 and abs(z["mpfever_p_Hote_c"]["y"] + 40) < 1
    assert z["mpfever_p_Hote_k"]["x"] == 100 and z["mpfever_p_Hote_k"]["r"] > z["mpfever_p_Hote_c"]["r"]
    # and the other way round
    B.L.execute("MOUSE = { x = -5, y = 7 }")
    c.tick_until(lambda: "mpfever_p_Client_c" in zones(A), 20)
    assert "mpfever_p_Client_c" in zones(A)
    # a game never draws itself
    assert not [k for k in zones(A) if k.startswith("mpfever_p_Hote")]
    metrics["presence_ticks_to_show"] = used


def test_updates_are_small_and_only_when_something_moves(tmp_path, metrics):
    c = start(str(tmp_path))
    A = c.games[0]
    A.L.execute("MOUSE = { x = 1, y = 1 }")
    c.tick(10)
    n0 = len(sent_presence(A))
    c.tick(10)                     # nothing moves: at most a heartbeat
    n1 = len(sent_presence(A))
    assert n1 - n0 <= 1
    for i in range(10):
        A.L.execute("MOUSE = { x = %d, y = 1 }" % (10 + 10 * i))
        c.tick(1)
    n2 = len(sent_presence(A))
    assert n2 - n1 >= 5, "a moving mouse is sent (%d updates in 10 ticks)" % (n2 - n1)
    sizes = [len(l.encode("utf-8")) for l in sent_presence(A)]
    metrics["presence_bytes_max"] = max(sizes)
    assert max(sizes) < 200


def test_cursor_moves_smoothly(tmp_path):
    c = start(str(tmp_path))
    A, B = c.games
    A.L.execute("MOUSE = { x = 0, y = 0 }")
    c.tick_until(lambda: "mpfever_p_Hote_c" in zones(B), 20)
    A.L.execute("MOUSE = { x = 100, y = 0 }")
    xs = []
    for _ in range(8):
        c.tick(1)
        xs.append(zones(B)["mpfever_p_Hote_c"]["x"])
    # moves towards 100 without jumping there in one frame, never overshoots, arrives
    assert all(b >= a for a, b in zip(xs, xs[1:]))
    assert xs[-1] > 95 and max(xs) <= 100.0001
    assert any(0 < x < 100 for x in xs)


def test_marks_go_when_a_player_leaves_or_goes_quiet(tmp_path):
    c = start(str(tmp_path))
    A, B = c.games
    A.L.execute("MOUSE = { x = 3, y = 4 }")
    c.tick_until(lambda: "mpfever_p_Hote_c" in zones(B), 20)
    B.write("peerleft" + TAB + "Hote" + TAB + '{["name"]="Hote"}')
    c.tick(2)
    assert not [k for k in zones(B) if k.startswith("mpfever_p_Hote")]
    # timeout: no update for PRESENCE.timeout frames
    A.L.execute("MOUSE = { x = 30, y = 4 }")
    c.tick_until(lambda: "mpfever_p_Hote_c" in zones(B), 20)
    B.T.PRESENCE.timeout = 30
    A.T.PRESENCE.heartbeat = 100000
    c.tick(15)
    assert not [k for k in zones(B) if k.startswith("mpfever_p_Hote")]


def test_other_players_pending_build_is_shown_until_built(tmp_path):
    c = start(str(tmp_path))
    A, B = c.games
    A.L.execute("MOUSE = { x = 50, y = 50 }")
    A.tool_build(ROAD)
    shown = c.tick_until(lambda: any(k.startswith("mpfever_pb_Hote_") for k in zones(B)), 30)
    assert shown is not None, zones(B)
    z = [v for k, v in zones(B).items() if k.startswith("mpfever_pb_Hote_")][0]
    assert abs(z["x"] - 50) < 1 and abs(z["y"] - 50) < 1
    # own pending mark on A in A's colour
    assert any(k.startswith("mpfever_pending_") for k in zones(A))
    built = c.tick_until(lambda: len(B.applied()) >= 1, 60)
    assert built is not None
    c.tick(5)
    assert not any(k.startswith("mpfever_pb_Hote_") for k in zones(B))


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
