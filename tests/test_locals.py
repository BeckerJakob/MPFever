"""The mod's Lua files must load in the game: Lua allows 200 local variables in a file's main chunk, and the game uses
about 8 of them itself (0.3.16 had 6 left under plain Lua 5.2 and did not load at all, issue #56).

Needs lupa (pip install lupa). Run: python tests/test_locals.py
"""
import glob
import os
import sys

MARGIN = 12   # free locals required under plain Lua 5.2 (the game takes about 8)

try:
    import lupa.lua52 as lua52
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

L = lua52.LuaRuntime()
check = L.eval('function(s, n) local f, e = load(s, n) return e end')
here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mod", "mpfever_1", "content")
failed = False
for path in sorted(glob.glob(os.path.join(here, "*.lua"))):
    name = os.path.basename(path)
    src = open(path, encoding="utf-8").read()
    err = check(src, name)
    if err:
        print(f"{name:32} DOES NOT COMPILE: {err}")
        failed = True
        continue
    # (the extra locals go before a module's final return)
    cut = src.rstrip().rfind("\nreturn ")
    if cut < 0 or src[cut:].strip().count("\n") > 0:
        cut = len(src)
    free = 0
    while free < 200 and not check(src[:cut] + "\n" + "\n".join(f"local zz{k} = 1" for k in range(free + 1)) + "\n" + src[cut:], name):
        free += 1
    ok = free >= MARGIN
    failed = failed or not ok
    print(f"{name:32} {free:3} free locals {'OK' if ok else 'TOO FEW (at least %d)' % MARGIN}")
sys.exit(1 if failed else 0)
