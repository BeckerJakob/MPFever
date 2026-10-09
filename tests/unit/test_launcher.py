"""T0.2 / T0.4 - the launcher (C#). Needs MPFever.exe built (build.bat, Visual Studio): skipped otherwise."""
import os
import subprocess

import pytest

from tools.mpftest import runner

pytestmark = pytest.mark.unit


def test_launcher_selftest():
    """T0.2: MPFever.exe --selftest - relay, client and file links of two simulated games, the Lua literal parser."""
    exe = runner.find_exe()
    if not exe:
        pytest.skip("MPFever.exe not built: run build.bat (Visual Studio 2022 with .NET desktop workload) or set MPF_EXE")
    p = subprocess.run([exe, "--selftest"], capture_output=True, text=True, timeout=60, cwd=os.path.dirname(exe))
    assert p.returncode == 0, p.stdout[-3000:] + p.stderr[-2000:]
    assert "SELFTEST OK" in p.stdout


@pytest.mark.skip(reason="T0.4: LuaLit (C#) is only reachable through --selftest; a direct test needs a test entry in the "
                         "launcher - planned with the Rust port (Phase 4/11), where the protocol gets its own crate")
def test_lualit_matches_lua_serializer():
    pass
