"""Session start with games at different times (found in the final e2e run of Phase 1/2): after loading, every game
runs a few steps at the savegame's speed before the bridge holds it, so the games stop at different times. The session
then starts at the time of the game that is furthest (pauseAt); the others run on to it. A build made meanwhile on the
game in front - before the session started - is built on the others when they get there."""
import pytest

from harness.cluster import STEP, Cluster

pytestmark = pytest.mark.sim

ROAD = """{ toAdd = {}, toRemove = {}, proposal = {
  addedNodes = { { entity = -1, comp = { position = { x = 50, y = 50, z = 0 } } } },
  addedSegments = { { entity = -2, comp = { node0 = 60, node1 = -1 } } } } }"""


def test_games_behind_catch_up_to_the_session_start(tmp_path):
    c = Cluster(str(tmp_path), n=2)
    A, B = c.games
    # the host's game ran 4 steps more than the client's before both were held
    A.L.execute("GAME.time = GAME.time + 4 * 200")
    c.tick(10)
    assert A.time() - B.time() == 4 * STEP
    # the player builds on the host's game before the session started (the autotest waited)
    A.tool_build(ROAD)
    c.tick(10)
    # MPFever.exe starts the session at the furthest time, held there (speed 0)
    start = max(A.time(), B.time())
    c.relay.started, c.relay.speed, c.relay.pauseAt = True, 0, start
    c.relay.session()
    ok = c.tick_until(lambda: B.time() == start, 40)
    assert ok is not None, "the client did not run on to the start time (%d, start %d)" % (B.time(), start)
    c.tick(10)
    assert A.time() == B.time() == start, "nobody runs past the start before the session speed is set"
    # the build made before the start is on both games, at the same game time
    assert A.applied() and A.applied() == B.applied(), (A.applied(), B.applied())
    # then the session runs
    c.relay.pauseAt, c.relay.speed = None, 1
    c.relay.session()
    c.tick(20)
    assert A.time() > start and B.time() > start
