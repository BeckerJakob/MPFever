"""T0.1 / T0.9 / T0.10 - the lockstep scenario of the old tests/test_lockstep.py on N mocked games, optionally behind
an emulated network. The checks are those of the old test, generalised to every client:
  - actions captured on any game are applied by every simulation at the same game time;
  - entity references (depot of a purchase, vehicle of a line assignment, nodes of a road) resolve to each game's own
    local entity; a reference that cannot be resolved is skipped instead of crashing;
  - native tools: the host's road is rebuilt by every client at the same game time, not shipped back;
  - pause at the same step on every game, an action during the pause applied at the pause time everywhere;
  - the originator's tool receives the real result (its own local entity id).
"""
import pytest

from harness.cluster import STEP, TAB, Checks, Cluster, NetEm
from tools.mpftest import analyze, kpi

pytestmark = pytest.mark.sim


ROAD = """{ toAdd = {}, toRemove = {}, proposal = {
  addedNodes = { { entity = -1, comp = { position = { x = %d, y = %d, z = 0 } } } },
  addedSegments = { { entity = -2, comp = { node0 = 60, node1 = -1 } } } } }"""
NODE0 = "(function() for i = #GAME.applied, 1, -1 do local x = GAME.applied[i] if x.name == 'build' and x.args[1].streetProposal then return x.args[1].streetProposal.edgesToAdd[1].comp.node0 end end end)()"


def run_scenario(tmp, n, netem, metrics, dll=True):
    c = Cluster(tmp, n=n, netem=netem, dll=dll)
    games = c.games
    A, B = games[0], games[1]
    others = games[1:]
    k = Checks()

    c.tick(20)
    k.check(all(g.time() == 18600 for g in games), "every game held at the save time before start (%s)" % [g.time() for g in games])
    c.relay.started, c.relay.speed = True, 1
    c.relay.session()
    c.tick(60, lag=True)
    k.check(all(g.time() > 18600 for g in games), "session running (%s)" % [g.time() for g in games])
    gaps = []
    for _ in range(10):
        c.tick(3, lag=True)
        ts = [g.time() for g in games]
        gaps.append((max(ts) - min(ts)) // STEP)
    k.check(max(gaps) <= 3, "barrier: no game runs more than 3 steps ahead of another (spread in steps: %s)" % gaps)
    metrics["barrier_spread_steps_max"] = max(gaps)

    # a client buys a vehicle in the save's depot 55 (same id everywhere); the vehicle gets different ids
    t_issue = B.time()
    B.ui("api.cmd.sendCommand(api.cmd.makeVehicleBuyCmd(7, 55, { vehicles = {} }), function(d, s, e) BUY_CB = { s, d and d.resultVehicleEntity } end)")
    k.check(B.L.eval("BUY_CB == nil"), "purchase callback waits for the real result")
    used = c.tick_until(lambda: all(len(g.applied()) >= 1 for g in games), 120, lag=True)
    c.tick(5, lag=True)
    applied = [g.applied() for g in games]
    k.check(used is not None and all(a == applied[0] and len(a) == 1 for a in applied),
            "purchase applied at the same time on every game: %s" % applied)
    metrics["stamp_distance_steps_x1"] = A.T.G.ahead
    if used is not None:
        t_apply = int(applied[0][0].split("@")[1])
        metrics["action_delay_steps"] = (t_apply - t_issue) // STEP
        metrics["action_delay_ticks"] = used
    vids = [g.L.eval("GAME.applied[1] and GAME.applied[1].entity") for g in games]
    k.check(len(set(vids)) == len(vids), "the bought vehicle has a different id in every game (%s), as in the real game" % vids)
    c.tick_until(lambda: B.L.eval("BUY_CB ~= nil"), 30)
    k.check(B.L.eval("BUY_CB ~= nil and BUY_CB[1] == true and BUY_CB[2] == %s" % vids[1]),
            "client's depot window got ITS local vehicle id %s" % vids[1])

    # the client creates a line, then assigns its vehicle to it: ids must be translated on every other game
    B.ui('api.cmd.sendCommand(api.cmd.makeLineCreateCmd("Ligne 1", { x = 1, y = 0, z = 0 }, 7, { stops = {} }), function(d, s, e) LINE_CB = { s, e and e[1] and e[1][1] } end)')
    c.tick_until(lambda: all(len(g.applied()) >= 2 for g in games) and B.L.eval("LINE_CB ~= nil"), 120, lag=True)
    c.tick(5)
    line_b = B.L.eval("LINE_CB and LINE_CB[2]")
    B.ui("api.cmd.sendCommand(api.cmd.makeVehicleSetLineCmd(%s, %s, 0), function() end)" % (vids[1], line_b))
    c.tick_until(lambda: all(len(g.applied()) >= 3 for g in games), 120, lag=True)
    c.tick(5, lag=True)
    setline = "(function() for _, a in ipairs(GAME.applied) do if a.name == 'makeVehicleSetLineCmd' then return a.args[1] .. ',' .. a.args[2] end end end)()"
    got = [g.L.eval(setline) for g in games]
    want = ["%s,%s" % (vids[i], g.L.eval("GAME.applied[2] and GAME.applied[2].entity")) for i, g in enumerate(games)]
    k.check(got == want, "line assignment used each game's own vehicle and line ids (got %s, want %s)" % (got, want))
    applied = [g.applied() for g in games]
    k.check(all(a == applied[0] for a in applied), "same actions at the same times on every game: %s" % applied)

    # a reference that cannot be resolved is skipped, not executed with a bad id
    B.L.execute("WORLD[9999] = { VEHICLE_DEPOT = {} }")   # a depot that only exists in this client's game
    B.ui("api.cmd.sendCommand(api.cmd.makeVehicleBuyCmd(7, 9999, { vehicles = {} }), function() end)")
    c.tick(40, lag=True)
    buys = [len([x for x in g.applied() if x.startswith("makeVehicleBuyCmd")]) for g in games]
    k.check(all(b == 1 for i, b in enumerate(buys) if i != 1),
            "a purchase in a depot unknown to the other games is skipped there, no crash (purchases per game: %s)" % buys)

    # native construction tools: the host's player, then a client's player builds a road. With the native module
    # (dll=True, known game build) the tool's build is held, announced, and released at its stamp on the builder's game;
    # without it (dll=False) it is applied at once on the builder's game. Captured by the engine event, rebuilt by every
    # other game at the same game time; the replays are not shipped back.
    shipped_before = [len([l for l in g.read("out.log") if l.split(TAB, 1)[0] == "act"]) for g in games]
    for builder, (x, y) in ((A, (50, 50)), (B, (80, 20))):
        before = [len(g.applied()) for g in games]
        t_issue = builder.time()
        builder.tool_build(ROAD % (x, y))
        c.tick_until(lambda: all(len(g.applied()) >= before[i] + 1 for i, g in enumerate(games)), 120, lag=True)
        c.tick(5, lag=True)
        last = [g.applied()[-1:] for g in games]
        k.check(all(len(g.applied()) == before[i] + 1 for i, g in enumerate(games)) and all(x == last[0] and x[0].startswith("build@") for x in last),
                "native road of %s built on every game at the same game time: %s" % (builder.name, last))
        if last[0]:
            metrics["native_delay_steps_" + builder.role] = (int(last[0][0].split("@")[1]) - t_issue) // STEP
        receivers = [g for g in games if g is not builder]
        n0 = [g.L.eval(NODE0) for g in receivers]
        k.check(all(x == 60 for x in n0), "existing node reference of %s's road resolved on every other game (node0=%s)" % (builder.name, n0))
    shipped = [len([l for l in g.read("out.log") if l.split(TAB, 1)[0] == "act"]) - shipped_before[i] for i, g in enumerate(games)]
    k.check(shipped[0] == 1 and shipped[1] == 1 and all(x == 0 for x in shipped[2:]),
            "each road shipped once by its builder, replays not shipped back (actions shipped per game: %s)" % shipped)

    # pause / action during the pause
    c.relay.pauseAt = c.relay.stamp()
    c.relay.session()
    c.tick_until(lambda: all(g.time() == c.relay.pauseAt for g in games), 120, lag=True)
    c.tick(10, lag=True)
    k.check(all(g.time() == c.relay.pauseAt for g in games), "every game paused exactly at %d (%s)" % (c.relay.pauseAt, [g.time() for g in games]))
    A.ui("api.cmd.sendCommand(api.cmd.makeVehicleBuyCmd(7, 55, { vehicles = {} }), function() end)")
    want = "makeVehicleBuyCmd@%d" % c.relay.pauseAt
    c.tick_until(lambda: all(g.applied()[-1] == want for g in games), 60)
    last = [g.applied()[-1:] for g in games]
    k.check(all(x == [want] for x in last), "purchase during the pause applied at the pause time on every game: %s" % last)

    c.relay.pauseAt, c.relay.speed = None, 2
    c.relay.session()
    c.tick(30)
    t0 = A.time()
    c.tick(30)
    steps = (A.time() - t0) // STEP
    # throughput is a metric (KPI), not a check, once the network has a delay: a delay larger than the barrier window
    # slows every game down (the barrier waits for clocks that are on their way) - Phase 5 addresses it
    # (the engine speed of a game held by the barrier is 0 for a moment: the session speed is what must be 2)
    k.check(all(g.T.G.session.speed == 2 for g in games) and steps > 0 and (steps >= 45 or netem.latency > 0),
            "resumed at x2 (%d steps in 30 ticks)" % steps)
    metrics["steps_in_30_ticks_at_x2"] = steps

    logs = c.logs()
    bad = [l for l in logs if ("FAILED" in l or "LATE" in l)]
    k.check(not bad, "no failure / late action in logs %s" % bad[:3])
    metrics["stamp_distance_steps_x2"] = A.T.G.ahead
    metrics["messages_delivered"] = c.relay.delivered

    # the e2e analysis (tools/mpftest) on the logs the real bridge wrote here: it must see what the harness measured
    run = {"autotest": analyze.parse_autotest_result([]), "launcher": analyze.parse_launcher_log([]),
           "games": {g.name: analyze.parse_mod_log(g.read("mod.log")) for g in games}}
    kk = kpi.compute(run)
    k.check(kk.get("native_builds") == 2 if dll else True, "log analysis found the 2 held native builds (%s)" % kk.get("native_builds"))
    k.check(kk.get("late_actions", 0) == 0, "log analysis found no late action (%s)" % kk.get("late_actions"))
    if dll and "native_delay_steps_max" in kk:
        metrics["log_native_delay_steps_max"] = kk["native_delay_steps_max"]
    return k, logs


CASES = [
    pytest.param(2, NetEm(), id="T0.1-2games"),
    pytest.param(3, NetEm(), id="T0.9-3games"),
    pytest.param(2, NetEm(latency=3, jitter=0), id="T0.10-2games-lat3"),
    pytest.param(2, NetEm(latency=3, jitter=4, seed=7), id="T0.10-2games-lat3-jit4"),
    pytest.param(3, NetEm(latency=8, jitter=4, seed=11), id="T0.10-3games-lat8-jit4"),
]


@pytest.mark.parametrize("n,netem", CASES)
def test_lockstep_scenario(tmp_path, n, netem, metrics):
    k, logs = run_scenario(str(tmp_path), n, netem, metrics)
    if k.failed:
        tail = "\n".join(l for l in logs if "session:" not in l)[-3000:]
        pytest.fail("%d of %d checks failed (%r):\n%s\n--- logs (tail) ---\n%s" % (len(k.failed), len(k.results), netem, k.summary(), tail))


def test_native_build_without_native_module(tmp_path, metrics):
    """T0.10b - fallback path (unknown game build: no native module). A tool's build is applied at once on the
    builder's game; a game that is ahead of the builder can only build it later. Invariant checked here: no silent
    difference - every game builds it, and a game that built it at another time logged it as LATE (the state check
    then corrects it). Characterises the current behaviour; the number of late games is a metric."""
    c = Cluster(str(tmp_path), n=3, netem=NetEm(latency=8, jitter=4, seed=11), dll=False)
    c.tick(20)
    c.relay.started, c.relay.speed = True, 1
    c.relay.session()
    c.tick(60, lag=True)
    builder = c.games[1]          # a client: often behind the host
    before = [len(g.applied()) for g in c.games]
    builder.tool_build(ROAD % (50, 50))
    ok = c.tick_until(lambda: all(len(g.applied()) >= before[i] + 1 for i, g in enumerate(c.games)), 150, lag=True)
    assert ok is not None, "the road was not built on every game"
    at = {g.name: g.applied()[-1] for g in c.games}
    t_builder = at[builder.name]
    late = [g for g in c.games if at[g.name] != t_builder]
    metrics["fallback_late_games"] = len(late)
    for g in late:
        assert any("LATE native build" in l for l in g.read("mod.log")), "%s built at %s (builder %s) without logging it as LATE" % (g.name, at[g.name], t_builder)
