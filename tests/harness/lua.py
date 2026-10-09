"""Loading the real MPFever Lua files into lupa (Lua 5.2, the language level of the game) for the offline tests."""
import os

import lupa.lua52 as lupa

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
CONTENT = os.path.join(REPO, "mod", "mpfever_1", "content")



def source(name):
    with open(os.path.join(CONTENT, name), encoding="utf-8") as f:
        return f.read()


def harness_source(name):
    with open(os.path.join(HERE, name), encoding="utf-8") as f:
        return f.read()


# the game's ug_require: any file of the mod's content folder, by its name (or "mpfever_1::/<name>"), loaded once
REQUIRE = '''MOD_CACHE = {}
ug_require = function(p)
  p = p:gsub("^mpfever_1::/", "")
  if MOD_CACHE[p] == nil then
    local src = MPF_SRC[p]
    if not src then error("no " .. p) end
    MOD_CACHE[p] = assert(load(src, p))()
  end
  return MOD_CACHE[p]
end'''


def module_sources():
    out = {}
    for name in os.listdir(CONTENT):
        if name.endswith(".lua"):
            out[name] = source(name)
    return out


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
    srcs = L.table()
    for name, text in module_sources().items():
        srcs[enc(name)] = enc(text)
    L.globals().MPF_SRC = srcs
    L.execute(REQUIRE)
    return L


def load_common(L):
    return L.eval('ug_require("mpfever_common.lua")')


def load_refs(L):
    return L.eval('ug_require("mpfever_refs.lua")')


def load_bridge(L, expose=True):
    """Runs the bridge in L (defines data()); with expose, the bridge's shared environment (every top-level name of
    its parts: valueHash, pacing, G, O, H...) is reachable as the Lua global MPF_T. The file itself is not changed."""
    src = source("mpfever_bridge.script.lua")
    if expose:
        src += "\nMPF_T = ENV\n"
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
