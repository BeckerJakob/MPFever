"""Makes the events file of the autotest "recplay" (MPFever.exe --autotest <savegame> with MPFEVER_SCENARIO=recplay and
MPFEVER_RECPLAY=<file>) from a real session's logs: the actions every player sent, in the order the host relayed them, the
session's pauses and speeds, and optional saves of one game (where its autosave was). Both games of the test replay every
action as another player's (as a player who received it did), from a savegame of that session.

    python tools/recplay.py --launcher <host launcher log> --out <a game's out.log> [--out <another game's out.log>]
        --start HH:MM:SS [--end HH:MM:SS] [--save host@HH:MM:SS] [--save client@HH:MM:SS] [--run 300] > recplay.txt

--start: the time (host's clock, the launcher log's) the savegame was made; the replay begins with what came after it.
--end: the last event replayed (default: the end of the log). --run: seconds the games run after the last event.
--save role@time: that game saves at that point of the replay (its autosave in the session).
--speed n: the session's speeds replaced by n (the simulation does not depend on the speed; x4 replays faster).
"""
import argparse
import re
import sys

ACT = re.compile(r"^(\d\d:\d\d:\d\d)\.\d+ Action (\S+) (?:de|by) (\S+) (?:au temps|at time) (\d+)")
PAUSE = re.compile(r"^(\d\d:\d\d:\d\d)\.\d+ Pause (?:au temps|at time) (\d+)")
SPEED = re.compile(r"^(\d\d:\d\d:\d\d)\.\d+ (?:Vitesse|Speed) : x(\d)|^(\d\d:\d\d:\d\d)\.\d+ Speed: x(\d)")
PENDING = re.compile(r"^(\d\d:\d\d:\d\d)\.\d+ (\S+) : nat_pending (\{.*\})$")
RESYNC = re.compile(r"^(\d\d:\d\d:\d\d)\.\d+ === Resynchroni[sz]ation n")


def acts_of(out_logs):
    """The acts each game sent, per origin, in order: (uid, at, payload)."""
    acts = {}
    for path in out_logs:
        for line in open(path, encoding="utf-8", errors="replace"):
            if not line.startswith("act\t"):
                continue
            kind, frm, payload = line.rstrip("\n").split("\t", 2)
            origin = re.search(r'\["origin"\]="([^"]+)"', payload)
            uid = re.search(r'\["uid"\]="([^"]+)"', payload)
            at = re.search(r'\["at"\]=(\d+)', payload)
            if origin and uid and at:
                acts.setdefault(origin.group(1), []).append((uid.group(1), int(at.group(1)), payload))
    return acts


def strip_turn(payload):
    # the replay's host gives the paused builds their turns again, in the order they come
    return re.sub(r',?\["pseq"\]=\d+', "", payload)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--launcher", required=True)
    ap.add_argument("--out", action="append", required=True)
    ap.add_argument("--start", required=True)
    ap.add_argument("--end", default="99:99:99")
    ap.add_argument("--save", action="append", default=[])
    ap.add_argument("--run", type=int, default=300)
    ap.add_argument("--speed", type=int, default=0, help="every speed of the session replaced by this one (0: as in the session)")
    a = ap.parse_args()
    acts = acts_of(a.out)
    nexti = {k: 0 for k in acts}
    saves = sorted((s.split("@", 1)[1], s.split("@", 1)[0]) for s in a.save)
    ev = ["# recplay from " + a.launcher + " start " + a.start + " end " + a.end]
    paused, speed, last = True, 1, None

    def flush_saves(upto):
        while saves and saves[0][0] <= upto:
            t, role = saves.pop(0)
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
            if not paused:
                # an action of a running game: the replay stops the games at its time, applies it, and runs on
                ev.append("pauseat\t" + str(at))
            ev.append("msg\tact\t" + origin + "\t" + strip_turn(payload))
            ev.append("waitact\t" + uid + "\t90")
            if not paused:
                ev.append("speed\t" + str(speed))
            last = clock
            continue
        if clock <= a.start or clock > a.end:
            continue
        m = PENDING.match(line)
        if m:
            flush_saves(clock)
            if paused:
                ev.append("msg\tnat_pending\t" + m.group(2) + "\t" + m.group(3))
            # (running: the replay pauses at the act's time instead)
            continue
        m = PAUSE.match(line)
        if m:
            flush_saves(clock)
            ev.append("pauseat\t" + m.group(2))
            paused = True
            continue
        m = SPEED.match(line)
        if m:
            flush_saves(clock)
            speed = a.speed or int(m.group(2) or m.group(4))
            ev.append("speed\t" + str(speed))
            paused = False
            continue
        if RESYNC.match(line):
            ev.append("log\tthe session resynchronised here (" + clock + ")")
            continue
    flush_saves("99:99:99")
    if paused:
        ev.append("speed\t4")
    ev.append("log\trunning " + str(a.run) + " s after the last event")
    for _ in range(max(1, a.run // 30)):
        ev.append("run\t30")
        ev.append("hash")
    print("\n".join(ev))


if __name__ == "__main__":
    main()
