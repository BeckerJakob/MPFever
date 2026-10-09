"""The Rust crates (Cargo workspace: crates/mpf-pe, crates/mpf-sig, tools/sigtool): `cargo test` as part of the unit
level, so that test.bat runs everything. Skipped without a Rust toolchain (rustup)."""
import os
import shutil
import subprocess

import pytest

from harness.lua import REPO

pytestmark = pytest.mark.unit


def test_cargo_test_workspace():
    c = shutil.which("cargo") or os.path.join(os.path.expanduser("~"), ".cargo", "bin", "cargo.exe")
    if not os.path.exists(c):
        pytest.skip("no Rust toolchain (rustup)")
    p = subprocess.run([c, "test", "--workspace", "-q"], cwd=REPO, capture_output=True, text=True, timeout=900)
    assert p.returncode == 0, (p.stdout[-3000:] + p.stderr[-3000:])
