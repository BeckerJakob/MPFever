"""T0.11b (e2e) - findings F1 and F2 checked in the game's own Lua: starts TransportFever3.exe once with a probe
script (tests/e2e/probe/mpf_probe.lua), reads its answers, closes the game it started.

Needs MPFever installed once (steam_appid.txt in the game folder, the mod in the user mods folder): run an e2e
autotest first. Copies the probe into the installed mod folder for the run and removes it afterwards."""
import json
import os
import shutil
import subprocess
import tempfile
import time

import pytest

from harness import game

pytestmark = pytest.mark.e2e

PROBE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "probe", "mpf_probe.lua")


def installed_mod_dirs():
    steam = game.steam_path()
    if not steam:
        return []
    root = os.path.join(steam, "userdata")
    out = []
    for u in os.listdir(root) if os.path.isdir(root) else []:
        d = os.path.join(root, u, game.APP_ID, "local", "mods", "mpfever_1")
        if os.path.isdir(d):
            out.append(d)
    return out


@pytest.fixture(scope="module")
def probe():
    """Runs the probe once in the game; -> its answers (dict)."""
    gdir = game.find_game_dir()
    if not gdir:
        pytest.skip("Transport Fever 3 not found")
    mods = installed_mod_dirs()
    if not mods or not os.path.exists(os.path.join(gdir, "steam_appid.txt")):
        pytest.skip("MPFever is not installed yet (run test.bat e2e once: the launcher installs it)")
    work = tempfile.mkdtemp(prefix="mpf_probe_")
    copies, manifests = [], {}
    try:
        for d in mods:
            dst = os.path.join(d, "content", "mpf_probe.lua")
            shutil.copy(PROBE, dst)
            copies.append(dst)
            # the game only loads the files listed in the mod's _content.json
            cj = os.path.join(d, "_content.json")
            with open(cj, encoding="utf-8") as f:
                manifests[cj] = f.read()
            m = json.loads(manifests[cj])
            m["files"] = list(m.get("files") or []) + ["mpf_probe.lua"]
            with open(cj, "w", encoding="utf-8") as f:
                json.dump(m, f, indent=4)
        env = dict(os.environ, MPFEVER_DIR=work)
        proc = subprocess.Popen([os.path.join(gdir, "TransportFever3.exe"), "--script", "mpfever_1::/mpf_probe.lua"], cwd=gdir, env=env)
        result = os.path.join(work, "probe.txt")
        try:
            for _ in range(240):
                if os.path.exists(result) and "finished=" in open(result, encoding="utf-8", errors="replace").read():
                    break
                time.sleep(0.5)
        finally:
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], capture_output=True)
        assert os.path.exists(result), "the probe did not answer within 2 minutes"
        with open(result, encoding="utf-8", errors="replace") as f:
            ans = dict(l.split("=", 1) for l in f.read().splitlines() if "=" in l)
    finally:
        for cj, text in manifests.items():
            with open(cj, "w", encoding="utf-8") as f:
                f.write(text)
        for c in copies:
            try:
                os.remove(c)
            except OSError:
                pass
        shutil.rmtree(work, ignore_errors=True)
    print("probe:", ans)
    return ans


@pytest.mark.xfail(strict=True, reason="F1 confirmed in the game on 09.10.2026 (build 40420): %d is 32 bits")
def test_f1_integer_format_in_game(probe, metrics):
    metrics["game_fmt_d_64bit"] = int(probe.get("fmt_d_2^31_ok") == "true")
    assert probe.get("fmt_d_2^31_ok") == "true", "F1: string.format('%%d', 2^31) fails in the game (%s)" % probe.get("fmt_d_2^31")


def test_f2_locale_in_game(probe, metrics):
    """F2 does not happen in the game: its process runs with the C locale (no control bytes above 127)."""
    metrics["game_ctl_bytes_above_127"] = len([b for b in probe.get("ctl_bytes_128_255", "").split(",") if b])
    assert "ctl_error" not in probe and probe.get("ctl_bytes_128_255", "") == "", "F2 in the game: bytes %s are control characters" % probe.get("ctl_bytes_128_255")
    assert probe.get("lua_version") == "Lua 5.2"
