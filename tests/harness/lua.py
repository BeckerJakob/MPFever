"""Loading the real MPFever Lua files into lupa (Lua 5.2, the language level of the game) for the offline tests."""
import os

import lupa.lua52 as lupa

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
CONTENT = os.path.join(REPO, "mod", "mpfever_1", "content")

# local functions and tables of mpfever_bridge.script.lua that the unit tests reach (the file keeps them local: the
# harness appends one line that collects them, the file itself is not changed)
BRIDGE_LOCALS = [
    "valueHash", "countsHash", "before", "pacing", "stampFor", "pausedStamp", "adaptAhead", "parseLine",
    "readLines", "simHash", "G", "O", "H", "STEP", "STAMP_AHEAD", "GAME_SCRIPTS",
]


def source(name):
    with open(os.path.join(CONTENT, name), encoding="utf-8") as f:
        return f.read()


def harness_source(name):
    with open(os.path.join(HERE, name), encoding="utf-8") as f:
        return f.read()


REQUIRE = '''ug_require = function(p)
  if p == "mpfever_common.lua" then if not COMMON then COMMON = load(COMMON_SRC, "mpfever_common.lua")() end return COMMON end
  if p == "mpfever_refs.lua" then if not REFS then REFS = load(REFS_SRC, "mpfever_refs.lua")() end return REFS end
  error("no " .. p)
end'''


def new_runtime(env=None, encoding="utf-8"):
    """A Lua runtime with the mocked engine and ug_require. env: MPFEVER_* variables seen by os.getenv at load time.
    encoding=None: Lua strings come back as bytes (to look at what really goes into a file)."""
    if env is not None:
        for k in ("MPFEVER_DIR", "MPFEVER_NAME", "MPFEVER_ROLE"):
            os.environ.pop(k, None)
        os.environ.update(env)
    L = lupa.LuaRuntime(unpack_returned_tuples=True, encoding=encoding)
    L.execute(harness_source("mock_engine.lua"))
    enc = (lambda t: t) if encoding else (lambda t: t.encode("utf-8"))
    L.globals().COMMON_SRC = enc(source("mpfever_common.lua"))
    L.globals().REFS_SRC = enc(source("mpfever_refs.lua"))
    L.execute(REQUIRE)
    return L


def load_common(L):
    return L.eval('ug_require("mpfever_common.lua")')


def load_refs(L):
    return L.eval('ug_require("mpfever_refs.lua")')


def load_bridge(L, expose=True):
    """Runs the bridge in L (defines data()); with expose, its locals are reachable as the Lua global MPF_T."""
    src = source("mpfever_bridge.script.lua")
    if expose:
        src += "\nMPF_T = { " + ", ".join("%s = %s" % (n, n) for n in BRIDGE_LOCALS) + " }\n"
    L.execute(src)
    return L.globals().MPF_T if expose else None


def to_lua(L, v):
    """Python value -> Lua value (dicts and lists become tables, recursively)."""
    if isinstance(v, dict):
        t = L.table()
        for k, x in v.items():
            t[to_lua(L, k)] = to_lua(L, x)
        return t
    if isinstance(v, (list, tuple)):
        t = L.table()
        for i, x in enumerate(v, 1):
            t[i] = to_lua(L, x)
        return t
    return v


def to_py(v):
    """Lua value -> Python value (tables become dicts with their keys as they are)."""
    if lupa.lua_type(v) == "table":
        return {to_py(k): to_py(x) for k, x in v.items()}
    return v
