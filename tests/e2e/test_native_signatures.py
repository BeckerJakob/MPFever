"""T2.11 (e2e, Phase 2) - the native module resolves the hooked addresses by their signatures inside the game:
  MPFEVER_SIGSCAN=1  on the known build: every signature finds the known address (native.log: "= known");
  MPFEVER_SIGSCAN=2  the module takes its addresses from the signatures and installs its hooks with them.
Starts TransportFever3.exe once per mode (the winhttp.dll the launcher installed: run after test_autotest.py)."""
import os
import shutil
import subprocess
import tempfile
import time

import pytest

from harness import game

pytestmark = pytest.mark.e2e


def run_game(mode, until, seconds=90):
    gdir = game.find_game_dir()
    if not gdir:
        pytest.skip("Transport Fever 3 not found")
    if not os.path.exists(os.path.join(gdir, "winhttp.dll")):
        pytest.skip("MPFever's native module is not installed (run the e2e autotest first)")
    work = tempfile.mkdtemp(prefix="mpf_sig_")
    env = dict(os.environ, MPFEVER_DIR=work, MPFEVER_SIGSCAN=mode)
    proc = subprocess.Popen([os.path.join(gdir, "TransportFever3.exe")], cwd=gdir, env=env)
    log = os.path.join(work, "native.log")
    text = ""
    try:
        end = time.time() + seconds
        while time.time() < end:
            if os.path.exists(log):
                text = open(log, encoding="utf-8", errors="replace").read()
                if until(text):
                    break
            time.sleep(0.5)
    finally:
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], capture_output=True)
        time.sleep(2)
        shutil.rmtree(work, ignore_errors=True)
    return text


def test_signatures_find_the_known_addresses(metrics):
    text = run_game("1", lambda t: t.count("signature ") >= 23 and "detour installed" in t)
    lines = [l for l in text.splitlines() if " signature " in l and "->" in l]
    metrics["signatures_logged"] = len(lines)
    assert len(lines) >= 23, text[-2000:]
    assert all("= known" in l for l in lines), [l for l in lines if "= known" not in l]


def test_hooks_installed_from_signatures():
    text = run_game("2", lambda t: "addresses taken from the signatures" in t and t.count("detour installed") >= 2
                    or "signatures incomplete" in t)
    assert "addresses taken from the signatures" in text, text[-2000:]
    assert "signatures incomplete" not in text
    assert text.count("detour installed") >= 2
