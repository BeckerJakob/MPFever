"""Compares the free-id queues of two games of a session (diagnostic MPFEVER_FREEQLOG=1 on both games).

Each game's native.log has, at the start of every 50th simulation step, a line
    freeq step <step> size <ids waiting> sum <sum of their ids> head <the id the next new entity gets>
The step is the game's update count, the same on every game. Two games in step print the same line for the same step; the
first step where they differ is within 50 steps after the action that made or removed entities on one game only (the ids of
every later entity then differ, and the vehicles or the towns drift minutes later).

    python tools/freeq_diff.py <native.log of game A> <native.log of game B>
"""
import re
import sys

LINE = re.compile(r"freeq step (\d+) (size (\d+) sum (\d+) head (-?\d+)|unreadable)")


def read(path):
    steps = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = LINE.search(line)
            if m:
                # (a game loaded again counts its steps from the savegame's: the last line of a step wins)
                steps[int(m.group(1))] = m.group(2)
    return steps


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    a, b = read(sys.argv[1]), read(sys.argv[2])
    common = sorted(set(a) & set(b))
    if not common:
        print("no step in common (MPFEVER_FREEQLOG=1 on both games?): %d and %d lines" % (len(a), len(b)))
        return 2
    print("%d steps in common, from %d to %d" % (len(common), common[0], common[-1]))
    for s in common:
        if a[s] != b[s]:
            print("FIRST DIFFERENCE at step %d:\n  A: %s\n  B: %s" % (s, a[s], b[s]))
            before = [x for x in common if x < s]
            if before:
                print("  last step alike: %d (the action that shifted the ids came between)" % before[-1])
            return 1
    print("the same free ids at every step in common")
    return 0


if __name__ == "__main__":
    sys.exit(main())
