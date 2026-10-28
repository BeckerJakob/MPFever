"""T2.11 (e2e) - the native module finds its places by their signatures (native/mpfever_sigs.txt, made by tools/mksigs.py),
as it does on a game build it does not know: MPFEVER_SIGTEST=1 resolves by signature on the installed (known) build too, and
the module installs its hooks with what it found. Starts TransportFever3.exe once (the winhttp.dll the launcher installed:
run after test_autotest.py)."""
import os
import shutil
import subprocess
import tempfile
import time

import pytest

from harness import game

pytestmark = pytest.mark.e2e


SIGS = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "native", "mpfever_sigs.txt")


def run_game(until, seconds=90, **extra):
    gdir = game.find_game_dir()
    if not gdir:
        pytest.skip("Transport Fever 3 not found")
    if not os.path.exists(os.path.join(gdir, "winhttp.dll")):
        pytest.skip("MPFever's native module is not installed (run the e2e autotest first)")
    work = tempfile.mkdtemp(prefix="mpf_sig_")
    env = dict(os.environ, MPFEVER_DIR=work, **extra)
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


def test_hooks_installed_from_signatures(metrics):
    text = run_game(lambda t: ("core found" in t or "core NOT found" in t) and t.count("detour installed") >= 2
                    or "hooks off" in t, MPFEVER_SIGTEST="1", MPFEVER_SIGS=SIGS)
    assert "; core found" in text, text[-2000:]
    assert "hooks off" not in text
    assert "separate companies' places found" in text
    assert text.count("detour installed") >= 2
    metrics["signature_detours"] = text.count("detour installed")
