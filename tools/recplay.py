"""Makes the events file of the autotest "recplay" (MPFever.exe --autotest <savegame> with MPFEVER_SCENARIO=recplay and
MPFEVER_RECPLAY=<file>) from a real session's logs: the actions every player sent, in the order the host relayed them, the
session's pauses and speeds, and optional saves of one game (where its autosave was). Both games of the test replay every
action as another player's (as a player who received it did), from a savegame of that session.

    python tools/recplay.py --launcher <host launcher log> --out <a game's out.log> [--out <another game's out.log>]
        --start HH:MM:SS [--end HH:MM:SS] [--save host@HH:MM:SS] [--save client@HH:MM:SS] [--run 300] [--speed 4] > recplay.txt

--start: the time (host's clock, the launcher log's) the savegame was made; the replay begins with what came after it.
--end: the last event replayed (default: the end of the log). --run: seconds the games run after the last event.
--save role@time: that game saves at that point of the replay (its autosave in the session).
--speed n: the session's speeds replaced by n (the simulation does not depend on the speed; x4 replays faster).
--running: the session was running (not paused) at --start, as in a savegame the replay made itself with --save; it starts
running at the session's speed (or --speed), else paused as a session starts.
"""
import argparse
import re
import sys

ACT = re.compile(r"^(\d\d:\d\d:\d\d)\.\d+ Action (\S+) (?:de|by) (\S+) (?:au temps|at time) (\d+)")
PAUSE = re.compile(r"^(\d\d:\d\d:\d\d)\.\d+ Pause (?:au temps|at time) (\d+)")
SPEED = re.compile(r"^(\d\d:\d\d:\d\d)\.\d+ (?:Vitesse : |Speed: )x(\d)")
PENDING = re.compile(r"^(\d\d:\d\d:\d\d)\.\d+ (\S+) : nat_pending (\{.*\})$")
RESYNC = re.compile(r"^(\d\d:\d\d:\d\d)\.\d+ === Resynchroni[sz]ation n")
STEP = 200


def acts_of(out_logs):
    """The acts each game sent, per origin, in order: (uid, at, payload)."""
    acts = {}
    for path in out_logs:
        for line in open(path, encoding="utf-8", errors="replace"):
            if not line.startswith("act\t"):
                continue
            payload = line.rstrip("\n").split("\t", 2)[2]
            origin = re.search(r'\["origin"\]="([^"]+)"', payload)
            uid = re.search(r'\["uid"\]="([^"]+)"', payload)
            at = re.search(r'\["at"\]=(\d+)', payload)
            if origin and uid and at:
                acts.setdefault(origin.group(1), []).append((uid.group(1), int(at.group(1)), payload))
    return acts


def strip_turn(payload):
    # the replay's host gives the paused builds their turns again, in the order they come
    return re.sub(r',?\["pseq"\]=\d+', "", payload)


def strip_paused(payload):
    # an action made in a pause of the session that the replay does not have (a resynchronisation's, see PAUSE): sent to running
    # games, it must be stamped as a running one (the launcher stamps a paused one at the games' latest time, which a running game
    # passes before it arrives: built a step late on that game)
    return re.sub(r'\["paused"\]=true,|,\["paused"\]=true', "", payload)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--launcher", required=True)
    ap.add_argument("--out", action="append", required=True)
    ap.add_argument("--start", required=True)
    ap.add_argument("--end", default="99:99:99")
    ap.add_argument("--save", action="append", default=[])
    ap.add_argument("--run", type=int, default=300)
    ap.add_argument("--speed", type=int, default=0)
    ap.add_argument("--running", action="store_true")
    a = ap.parse_args()
    acts = acts_of(a.out)
    nexti = {k: 0 for k in acts}
    saves = sorted((s.split("@", 1)[1], s.split("@", 1)[0]) for s in a.save)
    ev = ["# recplay from " + a.launcher + " start " + a.start + " end " + a.end]
    st = {"paused": True, "speed": 1}
    if a.running:
        # (the session's speed at the start: its last speed line before it)
        for line in open(a.launcher, encoding="utf-8", errors="replace"):
            if line[:8] > a.start:
                break
            m = SPEED.match(line.rstrip("\n"))
            if m:
                st["speed"] = int(m.group(2))
        st["speed"] = a.speed or st["speed"]
        st["paused"] = False
        ev.append("speed\t" + str(st["speed"]))
    pending = {}     # nat_pending of a running game, by (origin, build number), sent with its act
    group = []       # the acts of a running game stamped with one time, sent together

    def flush_group():
        # a running game's acts: the games stop 30 steps before their time, receive them (with their builds' announcements),
        # run on, and apply them at their own time, as the games of the session did
        if not group:
            return
        at = group[0][1]
        ev.append("pauseat\t" + str(at - 30 * STEP))
        for origin, _, uid, payload, nat in group:
            if nat in pending:
                ev.append("msg\tnat_pending\t" + origin + "\t" + strip_paused(pending.pop(nat)))
            ev.append("msg\tact\t" + origin + "\t" + strip_paused(strip_turn(payload)))
        ev.append("speed\t" + str(st["speed"]))
        for _, _, uid, _, _ in group:
            ev.append("waitact\t" + uid + "\t600")
        group.clear()

    def flush_saves(upto):
        while saves and saves[0][0] <= upto:
            t, role = saves.pop(0)
            flush_group()
            ev.append("log\t" + role + " saves (its autosave at " + t + ")")
            ev.append("save\t" + role + "\trecplay save " + role + " " + t.replace(":", ""))

    for line in open(a.launcher, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        clock = line[:8]
        m = ACT.match(line)
        if m:
            origin = m.group(3)
            # (every act of the log is consumed, those before the start too, to stay in step with the out.log)
            i = nexti.get(origin)
            if i is None or i >= len(acts.get(origin, [])):
                if clock > a.start:
                    print("warning: act of " + origin + " at " + clock + " not found in the out.log files", file=sys.stderr)
                continue
            uid, at, payload = acts[origin][i]
            nexti[origin] = i + 1
            if clock <= a.start or clock > a.end:
                continue
            flush_saves(clock)
            if st["paused"] and '["paused"]=true' not in payload:
                # (an action stamped for a running game while the session stood: made around a resynchronisation, which the
                # replay does not do; the games run on to it, as they did after the reload)
                flush_group()
                st["paused"] = False
                ev.append("speed\t" + str(st["speed"]))
            if not st["paused"]:
                if group and group[0][1] != at:
                    flush_group()
                nat = re.search(r'\["natId"\]=(\d+)', payload)
                group.append((origin, at, uid, payload, (origin, nat.group(1)) if nat else None))
                continue
            flush_group()
            ev.append("msg\tact\t" + origin + "\t" + strip_turn(payload))
            ev.append("waitact\t" + uid + "\t600")
            continue
        if clock <= a.start or clock > a.end:
            continue
        m = PENDING.match(line)
        if m:
            flush_saves(clock)
            if st["paused"]:
                flush_group()
                ev.append("msg\tnat_pending\t" + m.group(2) + "\t" + m.group(3))
                # (the replay's host gives that build its turn and tells every game; the build itself comes after it, as in
                # the session, where the builder sends it once its game has made it)
                ev.append("run\t2")
            else:
                nid = re.search(r'\["id"\]=(\d+)', m.group(3))
                org = re.search(r'\["origin"\]="([^"]+)"', m.group(3))
                if nid and org:
                    pending[(org.group(1), nid.group(1))] = m.group(3)
            continue
        m = PAUSE.match(line)
        if m and "resynchroni" in line:
            # (the pause of a resynchronisation: the replay reloads nothing, the games run on; the actions stamped after it were
            # running ones, waited for in a pause they were never applied)
            continue
        if m:
            flush_saves(clock)
            flush_group()
            ev.append("pauseat\t" + m.group(2))
            st["paused"] = True
            continue
        m = SPEED.match(line)
        if m:
            flush_saves(clock)
            flush_group()
            st["speed"] = a.speed or int(m.group(2))
            ev.append("speed\t" + str(st["speed"]))
            st["paused"] = False
            continue
        if RESYNC.match(line):
            flush_group()
            ev.append("log\tthe session resynchronised here (" + clock + ")")
            continue
    flush_group()
    flush_saves("99:99:99")
    if st["paused"]:
        ev.append("speed\t4")
    ev.append("log\trunning " + str(a.run) + " s after the last event")
    for _ in range(max(1, a.run // 30)):
        ev.append("run\t30")
        ev.append("hash")
    print("\n".join(ev))


if __name__ == "__main__":
    main()
