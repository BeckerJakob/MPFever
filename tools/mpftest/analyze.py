"""Reads what a real game session leaves behind - autotest_result.txt (launcher), launcher-*.log, and per game the
session folder %TEMP%\\mpfever\\<name>-... (mod.log, native.log) - into plain data. The line formats are the ones of
0.2.10 (launcher/MainForm.cs, mpfever_bridge.script.lua); the launcher writes French or English (Windows language)."""
import os
import re

TIME = r"(?:\d\d:\d\d:\d\d(?:\.\d+)? )?"


def secs(line):
    """Seconds of the day of a log line that starts with HH:MM:SS, else None."""
    m = re.match(r"(\d\d):(\d\d):(\d\d)", line)
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3)) if m else None


def read_lines(path):
    if not path or not os.path.exists(path):
        return []
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().splitlines()


# ------------------------------------------------------------------ autotest_result.txt

def parse_autotest_result(lines):
    """-> {savegame, ready, scenarios: [{name, role, result}], sync, desyncs, refused, errors, sessions}"""
    r = {"savegame": None, "ready": False, "scenarios": [], "sync": None, "desyncs": None, "refused": None,
         "errors": [], "sessions": []}
    current = {}
    for line in lines:
        if line.startswith("savegame: "):
            r["savegame"] = line[len("savegame: "):]
        elif line == "both games ready":
            r["ready"] = True
        elif line.startswith("FAILED") or line.startswith("ERROR"):
            r["errors"].append(line)
        elif m := re.match(r"scenario (\S+) by (\w+)$", line):
            current[m.group(2)] = m.group(1)
        elif m := re.match(r"(\w+) scenario: (.*)$", line):
            r["scenarios"].append({"name": current.get(m.group(1)), "role": m.group(1), "result": m.group(2),
                                   "timeout": m.group(2) == "TIMEOUT"})
        elif m := re.match(r"sync: (.*) \(desyncs (\d+)(?:, refused (\d+))?\)$", line):
            r["sync"], r["desyncs"] = m.group(1), int(m.group(2))
            r["refused"] = int(m.group(3)) if m.group(3) else None
        elif line.startswith("sessions: "):
            r["sessions"] = [s.strip() for s in line[len("sessions: "):].split(" ; ") if s.strip()]
    return r


# ------------------------------------------------------------------ mod.log (bridge of one game)

RE_HELD = re.compile(TIME + r"native build (\d+) held by the DLL, released at t=(\d+) \(now (\d+)\)")
RE_RELEASED = re.compile(TIME + r"native build (\d+) released at t=(\d+)(?:.*?\((\d+) step\(s\) late\))?")
RE_LATE = re.compile(TIME + r"LATE (.*?) for t=(\d+) applied at (\d+) \((\d+) step\(s\) late\)")
RE_MARGIN = re.compile(TIME + r"MARGIN (\S+(?: ?\(\w+\))?) (-?\d+) steps \(smallest so far (-?\d+), stamp distance (\d+), speed (\d+)\)")
RE_AUTO_BUILD = re.compile(r"(\d\d):(\d\d):(\d\d) pending mark drawn for autotest build (\d+)")
RE_RELEASED_AT = re.compile(r"(\d\d):(\d\d):(\d\d) native build (\d+) released at")
RE_HASH = re.compile(TIME + r"hash parts: (.*)$")
RE_SLOWED = re.compile(TIME + r"gui alive frame (\d+) .*slowed by other clocks (\d+)/(\d+) frames, by held actions (\d+)")


def parse_mod_log(lines):
    r = {"held": [], "released": [], "late": [], "margins": [], "failed": [], "slowed": [], "stamp_distance": None,
         "auto_builds": [], "hashes": []}
    announced = {}
    for line in lines:
        # scripted builds of the autotest scenarios (deferredSend): announce -> release, wall clock (1 s resolution)
        if m := RE_AUTO_BUILD.match(line):
            announced[int(m.group(4))] = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
        elif (m := RE_RELEASED_AT.match(line)) and int(m.group(4)) in announced:
            t = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
            r["auto_builds"].append({"id": int(m.group(4)), "wall_seconds": (t - announced.pop(int(m.group(4)))) % 86400})
        if m := RE_HASH.match(line):
            r["hashes"].append(dict(kv.split("=", 1) for kv in m.group(1).split(" ; ") if "=" in kv))
        if m := RE_HELD.match(line):
            r["held"].append({"id": int(m.group(1)), "at": int(m.group(2)), "now": int(m.group(3))})
        elif m := RE_RELEASED.match(line):
            r["released"].append({"id": int(m.group(1)), "at": int(m.group(2)), "late_steps": int(m.group(3) or 0)})
        elif m := RE_LATE.match(line):
            r["late"].append({"what": m.group(1), "at": int(m.group(2)), "applied": int(m.group(3)), "steps": int(m.group(4)),
                              "t": secs(line)})
        elif m := RE_MARGIN.match(line):
            r["margins"].append({"kind": m.group(1), "steps": int(m.group(2)), "distance": int(m.group(4)), "speed": int(m.group(5))})
            r["stamp_distance"] = int(m.group(4))
        elif m := RE_SLOWED.match(line):
            r["slowed"].append({"frames": int(m.group(3)), "by_clocks": int(m.group(2)), "by_held": int(m.group(4))})
        if "FAILED" in line or "replay failed" in line.lower():
            r["failed"].append(line)
    return r


# ------------------------------------------------------------------ launcher log

RE_RESYNC_START = re.compile(TIME + r"=== Resynchronisation (?:#|n°)(\d+) (?:on the host's game|sur la partie de l'hôte)")
RE_RESYNC_DONE = re.compile(TIME + r"=== Resynchronisation (?:#|n°)(\d+) (?:done in|terminée en) (\d+) s ===")
RE_RESYNC_CANCEL = re.compile(TIME + r"Resynchronisation (?:cancelled|abandonnée)")
# the state checksum a game computed in one frame (the game stands still meanwhile); decimal comma or point
RE_CHECKSUM = re.compile(TIME + r"(\S+) ?: (?:expensive checksum|empreinte coûteuse) \((\d+)[,.](\d+) s(?:, [^)]*)?\)")
RE_SPEED = re.compile(TIME + r"(?:Speed|Vitesse) ?: x(\d+) \((?:asked by|demandée par) (.+)\)")
RE_SCENARIO = re.compile(TIME + r"AUTOTEST scenario (\S+) by (\w+)$")
RE_OUT_OF_SYNC = re.compile(TIME + r"!!! (?:OUT OF SYNC|DÉSYNCHRONISATION|DESYNCHRONISATION)")
RE_SYNC_OK = re.compile(TIME + r"(?:Sync check|Synchronisation) (?:#|n°)\d+ .*?(?:IDENTICAL|IDENTIQUE|slight simulation drift|légère dérive)")


def parse_launcher_log(lines):
    r = {"resyncs_started": 0, "resync_seconds": [], "resyncs_cancelled": 0, "checksum_seconds": [], "speed_changes": [],
         "scenario_starts": [], "out_of_sync": [], "desync_onsets": []}
    in_sync = True
    for line in lines:
        if m := RE_SCENARIO.match(line):
            r["scenario_starts"].append({"t": secs(line), "name": m.group(1), "role": m.group(2)})
        elif RE_OUT_OF_SYNC.match(line):
            r["out_of_sync"].append(secs(line))
            # a desync that starts here (the games were equal at the check before): the later checks of the same
            # difference are not new desyncs (the autotest does not resynchronise)
            if in_sync:
                r["desync_onsets"].append(secs(line))
            in_sync = False
        elif RE_SYNC_OK.match(line):
            in_sync = True
        if m := RE_CHECKSUM.match(line):
            r["checksum_seconds"].append(float(m.group(2) + "." + m.group(3)))
        elif m := RE_SPEED.match(line):
            r["speed_changes"].append({"speed": int(m.group(1)), "by": m.group(2)})
        if RE_RESYNC_START.match(line):
            r["resyncs_started"] += 1
        elif m := RE_RESYNC_DONE.match(line):
            r["resync_seconds"].append(int(m.group(2)))
        elif RE_RESYNC_CANCEL.match(line):
            r["resyncs_cancelled"] += 1
    return r


# ------------------------------------------------------------------ the game's own log (crash_dump/stdout.txt)

RE_STDOUT_HEAD = re.compile(r"^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)Z - (\w+)\s*- ([^-]+?)\s*- ")
RE_ASSERTION = re.compile(r"Assertion Failure: (.*)$")


def parse_game_stdout(lines, since=None):
    """Engine assertions ('Fatal error' dialogs: the game stops there) in the game's stdout.txt. since: UTC text
    'YYYY-MM-DD HH:MM:SS' - only the entries from then on (both instances of a local test write the same file).
    -> [{"time", "thread", "text"}], one per assertion (the engine logs each twice: deduplicated)."""
    out, cur_time, cur_thread, seen = [], None, None, set()
    for line in lines:
        m = RE_STDOUT_HEAD.match(line)
        if m:
            cur_time, cur_thread = m.group(1), m.group(3).strip()
            continue
        a = RE_ASSERTION.search(line)
        if a and cur_time and (since is None or cur_time >= since):
            key = (cur_time, cur_thread, a.group(1))
            if key not in seen:
                seen.add(key)
                out.append({"time": cur_time, "thread": cur_thread, "text": a.group(1)})
    return out


def per_scenario(run):
    """Several scenarios in one session: late builds and desyncs that START (desync_onsets) counted in the time window of the
    scenario (from its start, host or client role, to the start of the next one; the last window is open)."""
    starts = sorted(run["launcher"]["scenario_starts"], key=lambda x: x["t"])
    if not starts:
        return {}
    bounds = [x["t"] for x in starts[1:]] + [None]

    def window(t):
        if t is None or t < starts[0]["t"]:
            return None
        for st, end in zip(starts, bounds):
            if end is None or t < end:
                return st["name"]
        return None

    out = {}
    for st in starts:
        out.setdefault(st["name"], {"late_actions": 0, "late_steps_max": 0, "desyncs": 0})
    for g in run["games"].values():
        for x in g["late"]:
            name = window(x.get("t"))
            if name:
                out[name]["late_actions"] += 1
                out[name]["late_steps_max"] = max(out[name]["late_steps_max"], x["steps"])
    for t in run["launcher"].get("desync_onsets", run["launcher"]["out_of_sync"]):
        name = window(t)
        if name:
            out[name]["desyncs"] += 1
    return out


def analyze_run(result_file, launcher_log=None):
    """Everything of one autotest run: the result file, the launcher log and every game's session folder."""
    res = parse_autotest_result(read_lines(result_file))
    games = {}
    for d in res["sessions"]:
        games[os.path.basename(d)] = parse_mod_log(read_lines(os.path.join(d, "mod.log")))
    return {"autotest": res, "launcher": parse_launcher_log(read_lines(launcher_log)), "games": games}
