"""T2.3 (Phase 2) - the signatures of the hooked engine addresses (signatures/signatures.txt, made by tools/sigtool):
every one resolves exactly once in the installed TransportFever3.exe, and for a known build at the known address.
The header the native module includes (native/signatures_gen.h) carries the same signatures."""
import json
import os
import re
import shutil
import subprocess

import pytest

from harness import game
from harness.lua import REPO

pytestmark = pytest.mark.native

SIGS = os.path.join(REPO, "signatures", "signatures.txt")
HEADER = os.path.join(REPO, "native", "signatures_gen.h")
GAME_DIR = game.find_game_dir()


def cargo():
    c = shutil.which("cargo") or os.path.join(os.path.expanduser("~"), ".cargo", "bin", "cargo.exe")
    return c if os.path.exists(c) else None


@pytest.fixture(scope="module")
def sigtool():
    exe = os.path.join(REPO, "target", "release", "sigtool.exe")
    c = cargo()
    if c:
        subprocess.run([c, "build", "--release", "-q", "-p", "sigtool"], cwd=REPO, check=True)
    if not os.path.exists(exe):
        pytest.skip("sigtool not built and no cargo (rustup)")
    return exe


def sig_lines():
    with open(SIGS, encoding="utf-8") as f:
        return [l.rstrip("\n").split("\t") for l in f if l.strip() and not l.startswith("#")]


def test_header_matches_signatures():
    with open(HEADER, encoding="utf-8") as f:
        h = f.read()
    for name, offset, pattern in sig_lines():
        entry = re.search(r'\{ "%s", (-?\d+), (\d+), SIGB_%s, SIGM_%s \}' % (re.escape(name), name, name), h)
        assert entry, "%s missing in the header" % name
        assert int(entry.group(1)) == int(offset) and int(entry.group(2)) == len(pattern.split())


def test_every_hooked_address_has_a_signature():
    names = {l[0] for l in sig_lines()}
    for f in ("add", "move", "dtor", "handleDtor", "apply", "swap", "sync", "preIter", "lua", "pool", "loopRet"):
        assert f in names
    assert len([n for n in names if n.startswith("site")]) >= 10


@pytest.mark.skipif(GAME_DIR is None, reason="Transport Fever 3 not found")
def test_signatures_resolve_in_installed_game(sigtool, metrics):
    exe = os.path.join(GAME_DIR, "TransportFever3.exe")
    builds = game.native_builds()
    from harness.pe import PE
    stamp = PE(exe).timestamp
    known = [os.path.join(REPO, "signatures", "known_%d.txt" % n) for n, b in builds.items() if b["stamp"] == stamp]
    args = [sigtool, "check", exe, SIGS, "--json"] + (["--known", known[0]] if known else [])
    p = subprocess.run(args, capture_output=True, text=True, timeout=120)
    out = json.loads(p.stdout)
    bad = [s for s in out["signatures"] if s["status"] != "ok"]
    metrics["signatures_resolved"] = len(out["signatures"]) - len(bad)
    assert out["ok"] and not bad, bad
