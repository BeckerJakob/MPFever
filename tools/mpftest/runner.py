"""Runs the launcher's own autotest (MPFever.exe --autotest <savegame>): two game instances on this PC, host and client,
the scenarios of MPFEVER_SCENARIO played by each role, then the state comparison. The launcher writes
autotest_result.txt next to itself and quits.

What MPFever.exe changes on this PC when it starts (docs/README.txt): it copies winhttp.dll and steam_appid.txt into the
game folder, adds the mod to settings.lua (backup settings.lua.bak_mpfever) and installs the mod in the user mods folder.
"""
import datetime
import glob
import os
import socket
import subprocess
import time

from . import analyze, kpi

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
EXE_CANDIDATES = [
    os.path.join(REPO, "release", "dist", "MPFever", "MPFever.exe"),
    os.path.join(REPO, "launcher", "bin", "Release", "MPFever.exe"),
]
DEFAULT_SAVE = "MPF-Test-Small"
PORT = 28090


def running(image):
    out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq %s" % image, "/NH", "/FO", "CSV"], capture_output=True).stdout
    return ('"%s"' % image).lower().encode() in out.lower()     # (OEM code page text: compared as bytes)


def port_free(port=PORT):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("0.0.0.0", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def wait_idle(timeout=120):
    """Before a run: the previous launcher and its games have exited and the host port is free again (a launcher
    started a second after the previous one exited could not listen: 'socket address already in use', and then
    waited 10 minutes for games that never came)."""
    end = time.time() + timeout
    while time.time() < end:
        if not running("MPFever.exe") and not running("TransportFever3.exe") and port_free():
            return
        time.sleep(2)
    raise RuntimeError("not idle after %d s: MPFever.exe running=%s, TransportFever3.exe running=%s, port %d free=%s" % (
        timeout, running("MPFever.exe"), running("TransportFever3.exe"), PORT, port_free()))


def game_stdout_files():
    """crash_dump/stdout.txt of every Steam user of this PC (the game's own log)."""
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as k:
            steam = winreg.QueryValueEx(k, "SteamPath")[0]
    except OSError:
        return []
    return glob.glob(os.path.join(steam, "userdata", "*", "3493540", "local", "crash_dump", "stdout.txt"))


def find_exe():
    env = os.environ.get("MPF_EXE")
    if env:
        return env if os.path.exists(env) else None
    return next((p for p in EXE_CANDIDATES if os.path.exists(p)), None)


def newest(pattern):
    files = glob.glob(pattern)
    return max(files, key=os.path.getmtime) if files else None


def run_autotest(exe, scenarios, save=DEFAULT_SAVE, speed=None, paused=False, timeout=1800, extra_env=None):
    """-> {"analysis": ..., "kpi": ..., "returncode": .., "seconds": .., "result_file": ..}"""
    wait_idle()
    exe_dir = os.path.dirname(exe)
    result_file = os.path.join(exe_dir, "autotest_result.txt")
    if os.path.exists(result_file):
        os.remove(result_file)
    env = dict(os.environ)
    env["MPFEVER_SCENARIO"] = ",".join(scenarios) if isinstance(scenarios, (list, tuple)) else scenarios
    # the native module's timing probe (extra hooks on the simulation loop, Sync and Swap, a log line per command):
    # a diagnostic players never run; the games stalled with it in a sync call (finding F10) - off unless asked for
    if os.environ.get("MPF_TIMING") == "1":
        env["MPFEVER_TIMING"] = "1"
    else:
        env.pop("MPFEVER_TIMING", None)
    if speed:
        env["MPFEVER_SPEED"] = str(speed)
    if paused:
        env["MPFEVER_PAUSED"] = "1"
    env.update(extra_env or {})
    t0 = time.time()
    since = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    proc = subprocess.Popen([exe, "--autotest", save], cwd=exe_dir, env=env)
    try:
        rc = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        # the launcher kills its two games itself on exit; on a timeout the whole tree it started goes
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], capture_output=True)
        rc = None
    seconds = round(time.time() - t0, 1)
    run = analyze.analyze_run(result_file, newest(os.path.join(exe_dir, "logs", "launcher-*.log")))
    run["engine_errors"] = [e for f in game_stdout_files() for e in analyze.parse_game_stdout(analyze.read_lines(f), since)]
    return {"analysis": run, "kpi": kpi.compute(run), "returncode": rc, "seconds": seconds, "result_file": result_file}
