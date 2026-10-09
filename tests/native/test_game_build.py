"""T0.11 - the installed TransportFever3.exe against what the native module (native/mpfever_native.cpp) expects.
Read only: the game is neither started nor changed. Answers before any game test: is this game build supported, and
do the hook addresses still point at what they were found on?"""
import os

import pytest

from harness import game
from harness.pe import PE

pytestmark = pytest.mark.native

GAME_DIR = game.find_game_dir()
needs_game = pytest.mark.skipif(GAME_DIR is None, reason="Transport Fever 3 not found (Steam) - set MPF_GAME_DIR")

# fields of BUILDS[] that are function entry points (the others are addresses inside functions or data)
ENTRY_POINTS = ["add", "move", "dtor", "handleDtor", "apply", "swap", "sync", "preIter", "lua"]


@pytest.fixture(scope="module")
def exe():
    return PE(os.path.join(GAME_DIR, "TransportFever3.exe"))


@pytest.fixture(scope="module")
def builds():
    return game.native_builds()


@pytest.fixture(scope="module")
def build(exe, builds):
    for number, b in builds.items():
        if b["stamp"] == exe.timestamp:
            return number, b
    pytest.fail("installed game build (link timestamp %#x) is not supported by the native module (known: %s): the "
                "construction hooks stay off - see docs/dev/TESTING.md, 'new game build'" % (
                    exe.timestamp, ", ".join("%d=%#x" % (n, b["stamp"]) for n, b in builds.items())))


def test_native_module_knows_builds(builds):
    assert builds, "BUILDS[] not found in mpfever_native.cpp"
    for number, b in builds.items():
        assert len(b["sites"]) >= 10, "UI_SITES_%d looks incomplete" % number


@needs_game
def test_exe_is_x64(exe):
    assert exe.machine == 0x8664


@needs_game
def test_installed_build_is_supported(build, metrics):
    metrics["game_build"] = build[0]


@needs_game
def test_entry_points_are_function_starts(exe, build):
    """Every hooked function starts in .text, 16-byte aligned, after padding (int3/nop) or a ret - what MSVC emits
    between functions. A moved function (another build) would fail this."""
    number, b = build
    bad = []
    for f in ENTRY_POINTS:
        rva = b[f]
        before = exe.read(rva - 1, 1)
        if not exe.in_text(rva) or rva % 16 or before not in (b"\xcc", b"\x90", b"\xc3"):
            bad.append("%s=%#x (byte before %s)" % (f, rva, before.hex()))
    assert not bad, "build %d: %s" % (number, ", ".join(bad))


@needs_game
def test_command_list_add_prologue(exe, build):
    """CommandList::Add, the hook that holds the tools' builds: its first bytes are the ones the module checks (P_ADD)."""
    number, b = build
    expected = game.native_bytes("P_ADD")
    assert expected, "P_ADD not found in mpfever_native.cpp"
    assert exe.read(b["add"], len(expected)) == expected


@needs_game
def test_ui_sites_follow_a_call(exe, build):
    """The return addresses of the tools' Add calls (UI_SITES_<build>) each follow a call instruction (IsCallBefore)."""
    number, b = build
    bad = []
    for rva in b["sites"]:
        p = exe.read(rva - 6, 6)
        call = (p[-5] == 0xE8 or (p[-6] == 0xFF and p[-5] == 0x15) or (p[-2] == 0xFF and (p[-1] & 0x38) == 0x10)
                or (p[-3] == 0xFF and (p[-2] & 0x38) == 0x10) or (p[-3] == 0x41 and p[-2] == 0xFF and (p[-1] & 0x38) == 0x10))
        if not (exe.in_text(rva) and call):
            bad.append("%#x" % rva)
    assert not bad, "build %d: sites not after a call: %s" % (number, bad)


@needs_game
def test_steam_and_lua_of_the_game(exe):
    """What the mod relies on in the executable: Lua 5.2 (the language level of the offline tests) and Steam."""
    assert b"Lua 5.2.2" in exe.data
    assert os.path.exists(os.path.join(GAME_DIR, "steam_api64.dll"))


@needs_game
def test_game_folder_state(metrics):
    """Not a requirement - recorded for the report: is MPFever installed in the game folder (winhttp.dll)?"""
    metrics["mpfever_native_installed"] = int(os.path.exists(os.path.join(GAME_DIR, "winhttp.dll")))
    metrics["steam_appid_txt"] = int(os.path.exists(os.path.join(GAME_DIR, "steam_appid.txt")))
