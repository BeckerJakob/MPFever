"""T1.1 / T1.6 - the module structure of the mod after Phase 1:
  - every Lua file of the mod compiles (Lua 5.2) and every bridge part is `return function(_ENV) ... end`;
  - the bridge writes no real global except data() (its parts share ONE environment table);
  - production parts never use what only the autotest parts define, and the autotest parts are loaded only in
    test / dev mode (MPFEVER_AUTOTEST=1 or MPFEVER_SAVE);
  - every file the game must load is listed in _content.json;
  - no production module is longer than 800 lines (PLAN.md, gate 1)."""
import json
import os
import re

import pytest

from harness import lua

pytestmark = pytest.mark.unit

FILES = sorted(f for f in os.listdir(lua.CONTENT) if f.endswith(".lua"))
PARTS = [f for f in FILES if f.startswith("mpfever_br_") or f.startswith("mpfever_dev_")]
DEV = [f for f in FILES if f.startswith("mpfever_dev_")]
PRODUCTION = [f for f in FILES if f not in DEV]


@pytest.mark.parametrize("name", FILES)
def test_compiles(name):
    L = lua.new_runtime({})
    err = L.eval("function(s, n) local f, e = load(s, n) return e end")(lua.source(name), name)
    assert err is None, err


@pytest.mark.parametrize("name", PARTS)
def test_part_is_an_environment_function(name):
    L = lua.new_runtime({})
    f = L.eval("function(n) return ug_require(n) end")(name)
    assert L.eval("type")(f) == "function"


def test_content_json_lists_every_file():
    with open(os.path.join(lua.CONTENT, "..", "_content.json"), encoding="utf-8") as f:
        listed = set(json.load(f)["files"])
    assert listed == set(FILES)


@pytest.mark.parametrize("name", PRODUCTION)
def test_production_modules_are_short(name):
    n = len(lua.source(name).split("\n"))
    assert n <= 800, "%s has %d lines" % (name, n)


def top_level_names(name):
    out = set()
    for line in lua.source(name).split("\n"):
        m = re.match(r"^function ([A-Za-z_]\w*)\s*\(", line) or re.match(r"^([A-Za-z_][\w, ]*?)\s*=[^=]", line)
        if m:
            out.update(n.strip() for n in m.group(1).split(","))
    return out


def code_of(name):
    return "\n".join(re.sub(r"--.*$", "", re.sub(r'"(?:[^"\\]|\\.)*"', '""', l)) for l in lua.source(name).split("\n"))


def test_production_does_not_use_autotest_names():
    dev_names = set().union(*(top_level_names(f) for f in DEV)) - set().union(*(top_level_names(f) for f in PARTS if f not in DEV))
    assert dev_names, "no autotest names found (parser)"
    offenders = []
    # (only the bridge parts share the environment; the other modules have their own locals)
    for f in [x for x in PARTS if x not in DEV]:
        code = code_of(f)
        for n in dev_names:
            if re.search(r"(?<![\w.:])" + re.escape(n) + r"(?!\w)", code):
                offenders.append("%s uses %s" % (f, n))
    assert not offenders, offenders


GUARD = """
local allowed = { data = true }
setmetatable(_G, { __newindex = function(t, k, v)
  if not allowed[k] then GLOBAL_WRITES[#GLOBAL_WRITES + 1] = tostring(k) end
  rawset(t, k, v)
end })
"""


@pytest.mark.parametrize("dev", [False, True])
def test_bridge_writes_no_real_global(tmp_path, dev):
    env = {"MPFEVER_DIR": str(tmp_path), "MPFEVER_NAME": "Hote", "MPFEVER_ROLE": "host"}
    if dev:
        env["MPFEVER_AUTOTEST"] = "1"
    try:
        L = lua.new_runtime(env)
        L.execute("GLOBAL_WRITES = {}")
        L.execute(GUARD)
        T = lua.load_bridge(L, expose=True)
        writes = [w for w in L.eval("GLOBAL_WRITES").values() if w not in ("MPF_T", "MOD_CACHE")]
        assert writes == [], writes
        # the autotest handlers exist only in dev mode; the protocol handlers always
        assert (T.H.newroad is not None) == dev
        assert T.H.act is not None and T.H.session is not None
        mod = L.eval("data()")
        assert all(mod[k] is not None for k in ("update", "handleEvent", "guiUpdate", "guiHandleEvent"))
    finally:
        os.environ.pop("MPFEVER_AUTOTEST", None)
