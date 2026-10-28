"""T0.3 - the protocol serializer of the mod (mpfever_common.lua: C.ser / C.deser / C.line), characterised as it is in
0.2.10. Every message between the games goes through it."""
import locale
import math

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from harness import lua

pytestmark = pytest.mark.unit


@pytest.fixture(scope="module")
def L():
    return lua.new_runtime({})


@pytest.fixture(scope="module")
def C(L):
    return lua.load_common(L)


def roundtrip(L, C, value):
    s = C.ser(lua.to_lua(L, value))
    return s, lua.to_py(C.deser(s))


# Finding F1 (fixed in Phase 1): integers went through string.format("%d"), which is 32 bits in the game's Lua 5.2
# (confirmed in the game, tests/e2e/test_game_lua.py) - beyond +-2^31 it raised. C.ser now writes them with C.int.
@pytest.mark.parametrize("value", [
    0, 1, -1, 42, 2 ** 31 - 1, -(2 ** 31), 2 ** 31, 2 ** 32, 2 ** 53 - 1, -(2 ** 53 - 1),
    0.5, -0.25, 1e-300, 1e300, 0.1 + 0.2, math.pi, 123456.789,
])
def test_numbers_roundtrip_exactly(L, C, value):
    s, back = roundtrip(L, C, value)
    assert back == value, "%r -> %s -> %r" % (value, s, back)


def test_integers_are_written_without_exponent(C):
    assert C.ser(2147483647) == "2147483647"
    assert C.ser(4294967295) == "4294967295"
    assert C.ser(-7) == "-7"
    assert C.ser(-0.0) == "0"


def test_large_balance_serializes(C):
    # a company balance of 3 billion, as authValues() sends it with sync_hash
    assert C.ser(3000000000) == "3000000000"


@pytest.mark.parametrize("value", [float("nan"), float("inf"), float("-inf")])
def test_nan_and_infinity_become_zero(C, value):
    # characterisation: lossy on purpose (a Lua literal cannot carry them); a NaN in a payload arrives as 0
    assert C.ser(value) == "0"


@pytest.mark.parametrize("text", [
    "", "plain", "tab\there", "new\nline", "cr\rlf\n", 'quote " inside', "back\\slash", "\\n literally",
    "all control: " + "".join(chr(i) for i in range(32)) + chr(127),
    "Ümlaut ß é 日本 🚂", "Ligne 1", "]] [[ { } , = ",
])
def test_strings_roundtrip(L, C, text):
    s, back = roundtrip(L, C, text)
    assert back == text
    # one protocol line per message: the serialized text never contains a line break or a tab
    assert "\n" not in s and "\r" not in s and "\t" not in s


def test_tables_roundtrip(L, C):
    v = {"a": 1, "b": {"c": [1, 2, 3], "d": {}}, 5: "five", "flag": True, "off": False}
    s, back = roundtrip(L, C, v)
    assert back == {"a": 1, "b": {"c": {1: 1, 2: 2, 3: 3}, "d": {}}, 5: "five", "flag": True, "off": False}


def test_depth_limit_cuts_deep_tables(L, C):
    # characterisation: below 40 levels a table becomes nil (protects against cycles)
    t = L.eval("(function() local r = {} local x = r for i = 1, 60 do x.n = {} x = x.n end return r end)()")
    s = C.ser(t)
    assert s.count("{") == 40
    assert C.deser(s) is not None


def test_cycle_does_not_hang(L, C):
    t = L.eval("(function() local r = {} r.self = r return r end)()")
    assert C.ser(t).count("{") == 40


def test_functions_and_userdata_become_nil(L, C):
    assert C.ser(L.eval("print")) == "nil"


def test_deser_rejects_code_and_garbage(L, C):
    assert C.deser("os.exit(1)") is None          # no access to os: empty environment
    assert C.deser("{") is None
    assert C.deser("") is None


def test_line_format(L, C):
    line = C.line("act", lua.to_lua(L, {"fn": "x"}))
    kind, frm, payload = line.rstrip("\n").split("\t")
    assert (kind, frm) == ("act", "player")      # C.NAME without MPFEVER_NAME
    assert lua.to_py(C.deser(payload)) == {"fn": "x"}
    assert line.endswith("\n") and line.count("\n") == 1


lua_values = st.recursive(
    st.none() | st.booleans() | st.integers(-(2 ** 53 - 1), 2 ** 53 - 1)
    | st.floats(allow_nan=False, allow_infinity=False) | st.text(max_size=40),
    lambda children: st.dictionaries(st.text(min_size=1, max_size=8) | st.integers(1, 50), children, max_size=6),
    max_leaves=25,
)


def normalise(v):
    """What a Lua table can hold: nil values vanish, -0.0 equals 0."""
    if isinstance(v, dict):
        return {k: normalise(x) for k, x in v.items() if x is not None}
    if isinstance(v, float) and v == int(v) and abs(v) < 2 ** 53:
        return int(v)
    return v


@settings(max_examples=300, deadline=None)
@given(lua_values)
def test_property_roundtrip(L, C, value):
    if value is None:
        return
    s, back = roundtrip(L, C, value)
    assert normalise(back) == normalise(value), s


# Finding F2 (fixed in Phase 1): C.ser escaped the bytes Lua's %c matches, which follows the process locale; under a
# code page locale it escaped bytes inside UTF-8 characters ("í" -> C3 "{": invalid UTF-8 for MPFever.exe). It now
# escapes the control bytes 0-31 and 127 explicitly. (The game itself runs with the C locale - tests/e2e.)
def test_utf8_survives_code_page_locale():
    Lb = lua.new_runtime({}, encoding=None)
    Cb = lua.load_common(Lb)
    old = locale.setlocale(locale.LC_CTYPE)
    try:
        locale.setlocale(locale.LC_CTYPE, "German_Germany.1252")
        s = Cb.ser("Línea Í ō".encode("utf-8"))
    finally:
        locale.setlocale(locale.LC_CTYPE, old)
    s.decode("utf-8")       # what MPFever.exe does with the line


def test_utf8_survives_c_locale():
    Lb = lua.new_runtime({}, encoding=None)
    Cb = lua.load_common(Lb)
    s = Cb.ser("Línea Í ō 日本 €".encode("utf-8"))
    assert s.decode("utf-8") == '"Línea Í ō 日本 €"'
