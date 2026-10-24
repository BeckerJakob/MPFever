# Checks mpf_math.cpp (out\mpfmath_test.dll, built by mathtest_build.bat) against this Windows' C runtime (ucrtbase.dll): the
# largest error in units in the last place of each function, the special values, the exact results (integer powers).
import ctypes, math, random, struct, sys
here = sys.argv[1] if len(sys.argv) > 1 else "."
mine = ctypes.CDLL(here + r"\out\mpfmath_test.dll")
crt = ctypes.CDLL("ucrtbase")
D, F = ctypes.c_double, ctypes.c_float
def fn(lib, name, n, T=D):
    f = getattr(lib, name); f.restype = T; f.argtypes = [T] * n; return f
def ulps(a, b):
    if a != a and b != b: return 0
    if a == b: return 0
    if a != a or b != b or math.isinf(a) or math.isinf(b): return 1e30
    return abs(a - b) / (math.nextafter(abs(b), math.inf) - abs(b))
bad = 0
random.seed(7)
N = 300000
def test(name, n, ranges):
    global bad
    m, r = fn(mine, "mpf_" + name, n), fn(crt, name, n)
    for rg in ranges:
        mx, over, worst = 0, 0, None
        for _ in range(N):
            a = [random.uniform(*rg[2*i:2*i+2]) for i in range(n)]
            u = ulps(m(*a), r(*a))
            if u > mx: mx, worst = u, a
            if u > 1: over += 1
        flag = "   <-- CHECK " + repr(worst) if mx > 4 else ""
        if mx > 4: bad += 1
        print(f"{name:6} {str(rg):28} max {mx:8.2f} ulp, {over} of {N} over 1{flag}", flush=True)
test("sin", 1, [(-10, 10), (-1e5, 1e5)])
test("cos", 1, [(-10, 10), (-1e5, 1e5)])
test("tan", 1, [(-10, 10), (-1e4, 1e4)])
test("asin", 1, [(-1, 1)])
test("acos", 1, [(-1, 1)])
test("atan", 1, [(-10, 10), (-1e6, 1e6)])
test("sinh", 1, [(-2, 2), (-700, 700)])
test("cosh", 1, [(-2, 2), (-700, 700)])
test("tanh", 1, [(-3, 3)])
test("exp", 1, [(-2, 2), (-740, 709)])
test("exp2", 1, [(-1070, 1023)])
test("log", 1, [(0, 3), (0, 1e300), (0, 1e-310)])
test("log2", 1, [(0, 3), (0, 1e300)])
test("log10", 1, [(0, 3), (0, 1e300)])
test("pow", 2, [(0, 10, -20, 20), (0, 2, -500, 500), (0.9, 1.1, -5000, 5000)])
test("atan2", 2, [(-10, 10, -10, 10)])
# special values
sp = [0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 2.0, -2.0, 3.0, -3.0, math.inf, -math.inf, math.nan, 1e-320, -1e-320, 1e308, -1e308]
def same(what, a, b):
    global bad
    ok = (a != a and b != b) or (a == b and math.copysign(1, a) == math.copysign(1, b))
    if not ok: print(f"SPECIAL {what}: mine {a!r}, CRT {b!r}"); bad += 1
for name in ["pow", "atan2"]:
    m, r = fn(mine, "mpf_" + name, 2), fn(crt, name, 2)
    for a in sp:
        for b in sp:
            if ulps(m(a, b), r(a, b)) > 1: same(f"{name}({a}, {b})", m(a, b), r(a, b))
for name in ["exp", "log", "sin", "cos", "asin", "acos", "atan", "tanh", "sinh", "cosh", "log10", "log2", "exp2", "tan"]:
    m, r = fn(mine, "mpf_" + name, 1), fn(crt, name, 1)
    for a in sp:
        x, y = m(a), r(a)
        if ulps(x, y) > 1: same(f"{name}({a})", x, y)
# exact results a script may count on
pw, cp = fn(mine, "mpf_pow", 2), fn(crt, "pow", 2)
inexact = 0
for b in range(-9, 10):
    for e in range(-30, 61):
        x, y = pw(b, e), cp(b, e)
        if x != y:
            inexact += 1
            if inexact <= 10: print(f"pow({b}, {e}): mine {x!r}, CRT {y!r}")
l10, l2, e2 = fn(mine, "mpf_log10", 1), fn(mine, "mpf_log2", 1), fn(mine, "mpf_exp2", 1)
for e in range(0, 23):
    if l10(10.0 ** e) != e: print("log10(1e%d) = %r" % (e, l10(10.0 ** e))); inexact += 1
for e in range(-1074, 1024):
    if l2(math.ldexp(1.0, e)) != e: print("log2(2^%d) = %r" % (e, l2(math.ldexp(1.0, e)))); inexact += 1; break
for e in range(-1074, 1024, 7):
    if e2(e) != math.ldexp(1.0, e): print("exp2(%d) differs" % e); inexact += 1; break
if pw(16.0, 0.5) != 4.0 or pw(2.0, 0.5) != math.sqrt(2.0): print("pow(x, 0.5) differs from sqrt"); inexact += 1
print("exact results that differ:", inexact)
pf, cf = fn(mine, "mpf_powf", 2, F), fn(crt, "powf", 2, F)
mx = 0
for _ in range(N):
    x, y = random.uniform(0, 50), random.uniform(-8, 8)
    x = struct.unpack("f", struct.pack("f", x))[0]; y = struct.unpack("f", struct.pack("f", y))[0]
    a, b = pf(x, y), cf(x, y)
    if a != b:
        u = abs(a - b) / (math.nextafter(abs(b), math.inf) - abs(b)) / 2 ** 29   # (float ulp = 2^29 double ulp)
        mx = max(mx, u)
print("powf   max %.2f float ulp" % mx)
print("MATH CHECK: " + ("PROBLEMS" if bad or inexact else "OK"))
