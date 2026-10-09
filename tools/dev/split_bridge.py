"""Phase 1 refactoring tool (kept for reference): splits mpfever_bridge.script.lua (0.2.10, 5041 lines) into modules.

Each module is `return function(_ENV) ... end`; the bridge calls every module with ONE shared environment table, so
the sections keep referring to each other exactly as before. The only change inside a section: declarations at the
top level of the old file (column 0) become fields of that environment:
    local function f(...)   ->  function f(...)
    local a, b = ...        ->  a, b = ...
    local a                 ->  a = nil
Checked before splitting (scan): no name is declared twice at the top level, and none is used before its declaration
(that would have referred to a global before and to the shared field after).

    python tools/dev/split_bridge.py <old bridge> <content dir>
"""
import re
import sys

# (module, first line, last line) of the 0.2.10 file, 1-based; comment blocks right above a start line move along
SECTIONS = [
    ("mpfever_br_base.lua", 15, 219, "bridge: shared requires, game time, state hashing, order of simultaneous actions"),
    ("mpfever_br_exec.lua", 220, 414, "bridge: execution of a replicated action (entity references, retries)"),
    ("mpfever_br_sim.lua", 415, 883, "bridge: simulation half (actions applied at their stamp, captures of native builds, hash)"),
    ("mpfever_br_gui.lua", 884, 1083, "bridge: GUI half - link, session, barrier (pacing), stamps, received actions"),
    ("mpfever_br_replay.lua", 1084, 1791, "bridge: replays of other players' native builds"),
    ("mpfever_br_native.lua", 1792, 2125, "bridge: native deferral (builds held by the native module), terrain edits"),
    ("mpfever_br_resync.lua", 2126, 2385, "bridge: resynchronisation by the host's savegame, state checks, shipping"),
    ("mpfever_dev_autotest1.lua", 2386, 3183, "autotest scenarios (dev only): roads, stops, matrix, company"),
    ("mpfever_dev_autotest2.lua", 3184, 3936, "autotest scenarios (dev only): probes, terrain, tram stops, bulldoze"),
    ("mpfever_dev_autotest3.lua", 3937, 4840, "autotest scenarios (dev only): stops, buy, line, split, road types, camera"),
    ("mpfever_br_frame.lua", 4841, 5033, "bridge: the per-frame GUI update (link, pacing, native, hashes) and GUI events"),
]

RE_F = re.compile(r"^local function ([A-Za-z_]\w*)")
RE_V = re.compile(r"^local ([A-Za-z_][\w, ]*?)\s*(=.*)?$")


def convert(line):
    if RE_F.match(line):
        return line[len("local "):]
    m = RE_V.match(line)
    if m:
        names, rest = m.group(1).strip(), m.group(2)
        return names + " " + rest if rest else names + " = nil"
    return line


def pull_comments(lines, start):
    """Moves a start line (1-based) up over the comment block directly above it (a function keeps its comment)."""
    i = start
    while i - 1 >= 1 and lines[i - 2].startswith("--"):
        i -= 1
    return i


def main(old, outdir):
    lines = open(old, encoding="utf-8").read().split("\n")
    # only the cuts inside a section take the comment block above them along (the others start at a section rule)
    starts = [pull_comments(lines, s) if s in (1084, 3184, 3937) else s for _, s, _, _ in SECTIONS]
    ranges = [(starts[k], (starts[k + 1] - 1) if k + 1 < len(SECTIONS) else SECTIONS[k][2]) for k in range(len(SECTIONS))]
    for (name, _, _, title), (a, b) in zip(SECTIONS, ranges):
        body = [convert(l) for l in lines[a - 1:b]]
        while body and body[-1].strip() == "":
            body.pop()
        head = ["-- MPFever " + title + ".",
                "-- Part of mpfever_bridge.script.lua (split in Phase 1, tools/dev/split_bridge.py): called with the bridge's shared",
                "-- environment, so the top-level names of every part are visible to every other part.",
                "return function(_ENV)", ""]
        with open(outdir + "/" + name, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(head + body + ["", "end", ""]))
        print("%-28s lines %4d-%4d (%d)" % (name, a, b, b - a + 1))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
