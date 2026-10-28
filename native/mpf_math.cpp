// MPFever's own mathematical functions (freestanding: no C runtime).
//
// The game takes sin, exp, pow... from Windows' C runtime (ucrtbase.dll, api-ms-win-crt-math), and that library is not the
// same on every Windows: its builds 22621 and 26100 give other last digits for pow, atan2, asin, acos, sinh, cosh, exp2,
// log2f... (392 of 200,000 pow results). Two players on two Windows saw their towns drift apart (the towns' game script uses
// pow through Lua) whatever MPFever did. The native module points the game's imports of these functions here, so that every
// game computes them with the same code. The algorithms are those of fdlibm (Sun Microsystems, freely usable) as FreeBSD's
// msun and musl carry them; pow is computed in double-double precision, and exactly when its result can be. SSE2 only, no
// fused multiply-add: the same bits on every x64 processor.
// (no header: the module is built without the Windows SDK)

typedef unsigned long long mu64;
typedef long long mi64;
typedef unsigned int mu32;

static inline mu64 Bits(double x) { union { double d; mu64 u; } v; v.d = x; return v.u; }
static inline double FromBits(mu64 u) { union { double d; mu64 u; } v; v.u = u; return v.d; }
static inline mu32 Hi(double x) { return (mu32)(Bits(x) >> 32); }
static inline double Abs(double x) { return FromBits(Bits(x) & 0x7fffffffffffffffULL); }
static inline bool IsNan(double x) { return (Bits(x) & 0x7fffffffffffffffULL) > 0x7ff0000000000000ULL; }
static inline bool IsInf(double x) { return (Bits(x) & 0x7fffffffffffffffULL) == 0x7ff0000000000000ULL; }
extern "C" double mpf_sqrt(double x);   // mpf_math_asm.asm: sqrtsd
static inline double Sqrt(double x) { return mpf_sqrt(x); }
static inline double ClearLow(double x) { return FromBits(Bits(x) & 0xffffffff00000000ULL); }
static inline double CopySign(double x, double s) { return FromBits((Bits(x) & 0x7fffffffffffffffULL) | (Bits(s) & 0x8000000000000000ULL)); }
static const double kInf = FromBits(0x7ff0000000000000ULL);
static const double kNan = FromBits(0x7ff8000000000000ULL);

// nearest integer (ties to even), for |x| < 2^52 (larger values are integers already)
static inline double Rint(double x)
{
    const double big = 6755399441055744.0;   // 1.5 * 2^52
    if (Abs(x) >= 4503599627370496.0) return x;
    volatile double t = x + big;
    return t - big;
}

static double ScaleB(double x, int n)
{
    const double p1023 = FromBits(0x7fe0000000000000ULL), pm969 = FromBits(0x0360000000000000ULL);   // 2^1023, 2^-969
    if (n > 1023) {
        x *= p1023; n -= 1023;
        if (n > 1023) { x *= p1023; n -= 1023; if (n > 1023) n = 1023; }
    } else if (n < -1022) {
        x *= pm969; n += 969;   // (2^-1022 * 2^53: no double rounding in the subnormals)
        if (n < -1022) { x *= pm969; n += 969; if (n < -1022) n = -1022; }
    }
    return x * FromBits((mu64)(0x3ff + n) << 52);
}

// ---------------------------------------------------------------- exp, log (fdlibm e_exp.c, musl log.c)

extern "C" double mpf_exp(double x)
{
    static const double halF[2] = { 0.5, -0.5 };
    static const double ln2HI[2] = { 6.93147180369123816490e-01, -6.93147180369123816490e-01 };
    static const double ln2LO[2] = { 1.90821492927058770002e-10, -1.90821492927058770002e-10 };
    const double o_threshold = 7.09782712893383973096e+02, u_threshold = -7.45133219101941108420e+02;
    const double invln2 = 1.44269504088896338700e+00;
    const double P1 = 1.66666666666666019037e-01, P2 = -2.77777777770155933842e-03, P3 = 6.61375632143793436117e-05,
                 P4 = -1.65339022054652515390e-06, P5 = 4.13813679705723846039e-08;
    if (IsNan(x)) return x + x;
    if (x > o_threshold) return kInf;
    if (x < u_threshold) return 0.0;
    int xsb = (int)(Bits(x) >> 63);
    double hi = 0, lo = 0;
    int k = 0;
    double ax = Abs(x);
    if (ax > 3.46573590279972643113e-01) {          // |x| > 0.5 ln2
        if (ax < 1.03972077083991796413e+00) {        // and < 1.5 ln2
            hi = x - ln2HI[xsb]; lo = ln2LO[xsb]; k = 1 - xsb - xsb;
        } else {
            k = (int)(invln2 * x + halF[xsb]);
            double t = k;
            hi = x - t * ln2HI[0];
            lo = t * ln2LO[0];
        }
        x = hi - lo;
    } else if (ax < 3.7252902984e-09) {               // 2^-28
        return 1.0 + x;
    }
    double t = x * x;
    double c = x - t * (P1 + t * (P2 + t * (P3 + t * (P4 + t * P5))));
    if (k == 0) return 1.0 - ((x * c) / (c - 2.0) - x);
    double y = 1.0 - ((lo - (x * c) / (2.0 - c)) - hi);
    return ScaleB(y, k);
}

static const double Lg1 = 6.666666666666735130e-01, Lg2 = 3.999999999940941908e-01, Lg3 = 2.857142874366239149e-01,
                    Lg4 = 2.222219843214978396e-01, Lg5 = 1.818357216161805012e-01, Lg6 = 1.531383769920937332e-01,
                    Lg7 = 1.479819860511658591e-01;

// x = 2^k (1 + f), sqrt(2)/2 < 1 + f < sqrt(2); returns false (and *special) for zero, negative, infinite, NaN, 1
static bool LogSplit(double x, int* k, double* f, double* special)
{
    mu64 ix = Bits(x);
    *k = 0;
    if (ix < 0x0010000000000000ULL || (ix >> 63)) {
        if ((ix << 1) == 0) { *special = -kInf; return false; }
        if (ix >> 63) { *special = IsNan(x) ? x + x : kNan; return false; }
        *k -= 54;                                      // subnormal: scaled up
        x *= 18014398509481984.0;                      // 2^54
        ix = Bits(x);
    } else if (ix >= 0x7ff0000000000000ULL) {
        *special = x + x; return false;
    } else if (ix == 0x3ff0000000000000ULL) {
        *special = 0.0; return false;
    }
    mu32 hx = (mu32)(ix >> 32);
    hx += 0x3ff00000 - 0x3fe6a09e;
    *k += (int)(hx >> 20) - 0x3ff;
    hx = (hx & 0x000fffff) + 0x3fe6a09e;
    ix = ((mu64)hx << 32) | (ix & 0xffffffffULL);
    *f = FromBits(ix) - 1.0;
    return true;
}

extern "C" double mpf_log(double x)
{
    const double ln2_hi = 6.93147180369123816490e-01, ln2_lo = 1.90821492927058770002e-10;
    int k; double f, sp;
    if (!LogSplit(x, &k, &f, &sp)) return sp;
    double hfsq = 0.5 * f * f, s = f / (2.0 + f), z = s * s, w = z * z;
    double t1 = w * (Lg2 + w * (Lg4 + w * Lg6)), t2 = z * (Lg1 + w * (Lg3 + w * (Lg5 + w * Lg7)));
    double R = t2 + t1, dk = k;
    return s * (hfsq + R) + dk * ln2_lo - hfsq + f + dk * ln2_hi;
}

extern "C" double mpf_log2(double x)
{
    const double ivln2hi = 1.44269504072144627571e+00, ivln2lo = 1.67517131648865118353e-10;
    int k; double f, sp;
    if (!LogSplit(x, &k, &f, &sp)) return sp;
    double hfsq = 0.5 * f * f, s = f / (2.0 + f), z = s * s, w = z * z;
    double t1 = w * (Lg2 + w * (Lg4 + w * Lg6)), t2 = z * (Lg1 + w * (Lg3 + w * (Lg5 + w * Lg7)));
    double R = t2 + t1;
    double hi = ClearLow(f - hfsq);
    double lo = f - hi - hfsq + s * (hfsq + R);
    double val_hi = hi * ivln2hi;
    double val_lo = (lo + hi) * ivln2lo + lo * ivln2hi;
    double y = k;
    double w2 = y + val_hi;
    val_lo += (y - w2) + val_hi;
    val_hi = w2;
    return val_lo + val_hi;
}

extern "C" double mpf_log10(double x)
{
    const double ivln10hi = 4.34294481878168880939e-01, ivln10lo = 2.50829467116452752298e-11,
                 log10_2hi = 3.01029995663611771306e-01, log10_2lo = 3.69423907715893078616e-13;
    int k; double f, sp;
    if (!LogSplit(x, &k, &f, &sp)) return sp;
    double hfsq = 0.5 * f * f, s = f / (2.0 + f), z = s * s, w = z * z;
    double t1 = w * (Lg2 + w * (Lg4 + w * Lg6)), t2 = z * (Lg1 + w * (Lg3 + w * (Lg5 + w * Lg7)));
    double R = t2 + t1;
    double hi = ClearLow(f - hfsq);
    double lo = f - hi - hfsq + s * (hfsq + R);
    double val_hi = hi * ivln10hi;
    double dk = k;
    double y = dk * log10_2hi;
    double val_lo = dk * log10_2lo + (lo + hi) * ivln10lo + lo * ivln10hi;
    double w2 = y + val_hi;
    val_lo += (y - w2) + val_hi;
    val_hi = w2;
    double r = val_lo + val_hi;
    // (an exact power of ten gives its exponent exactly)
    double n = Rint(r);
    if (n != r && n >= 0 && n <= 22 && Abs(r - n) < 1e-14) {
        double p = 1.0;
        for (int i = 0; i < (int)n; i++) p *= 10.0;
        if (p == x) return n;
    }
    return r;
}

// 2^x: 2^n exactly times e^(f ln 2), |f| <= 1/2
extern "C" double mpf_exp2(double x)
{
    if (IsNan(x)) return x + x;
    if (x >= 1024.0) return kInf;
    if (x <= -1075.0) return 0.0;
    double n = Rint(x);
    double f = x - n;
    if (f == 0) return ScaleB(1.0, (int)n);
    return ScaleB(mpf_exp(f * 6.93147180559945286227e-01), (int)n);
}

// ---------------------------------------------------------------- pow (double-double)

// exact a + b = s + e
static inline void TwoSum(double a, double b, double* s, double* e)
{
    double s1 = a + b, bb = s1 - a;
    *e = (a - (s1 - bb)) + (b - bb);
    *s = s1;
}
// exact a * b = p + e (Dekker: no fused multiply-add)
static inline void Split(double a, double* hi, double* lo)
{
    double c = 134217729.0 * a;   // 2^27 + 1
    double h = c - (c - a);
    *hi = h; *lo = a - h;
}
static inline void TwoProd(double a, double b, double* p, double* e)
{
    double p1 = a * b, ah, al, bh, bl;
    Split(a, &ah, &al); Split(b, &bh, &bl);
    *e = ((ah * bh - p1) + ah * bl + al * bh) + al * bl;
    *p = p1;
}
static inline void DdMul(double ah, double al, double bh, double bl, double* h, double* l)
{
    double p, e;
    TwoProd(ah, bh, &p, &e);
    e += ah * bl + al * bh;
    TwoSum(p, e, h, l);
}

// x^n for an integer n, |n| < 2^31, in double-double: exact whenever the result is (false: over- or underflow on the way)
static bool PowInt(double x, mi64 n, double* r)
{
    bool neg = n < 0;
    mu64 m = (mu64)(neg ? -n : n);
    double bh = x, bl = 0, rh = 1, rl = 0;
    while (m) {
        if (m & 1) DdMul(rh, rl, bh, bl, &rh, &rl);
        m >>= 1;
        if (m) DdMul(bh, bl, bh, bl, &bh, &bl);
        if (IsInf(rh) || IsInf(bh) || IsNan(rh) || IsNan(bh) || rh == 0 || bh == 0) return false;
        double ar = Abs(rh), ab = Abs(bh);
        if ((ar != 0 && ar < 1e-290) || (ab != 0 && ab < 1e-290) || ar > 1e290 || ab > 1e290) return false;
    }
    if (neg) {
        // 1 / (rh + rl)
        double q = 1.0 / rh, p, e;
        TwoProd(q, rh, &p, &e);
        double rem = ((1.0 - p) - e) - q * rl;
        *r = q + rem / rh;
    } else {
        *r = rh + rl;
    }
    return true;
}

// log(x) in double-double, x finite and > 0
static void LogDd(double x, double* lh, double* ll)
{
    const double ln2_hi = 6.93147180369123816490e-01, ln2_lo = 1.90821492927058770002e-10;
    int k; double f, sp;
    if (!LogSplit(x, &k, &f, &sp)) { *lh = sp; *ll = 0; return; }
    // s = f / (2 + f) in double-double
    double d = 2.0 + f, dl = f - (d - 2.0);
    double sh = f / d, p, e;
    TwoProd(sh, d, &p, &e);
    double sl = (((f - p) - e) - sh * dl) / d;
    // log(1 + f) = 2 atanh(s) = 2s + 2s^3/3 + 2s (z^2/5 + z^3/7 + ...), z = s^2 (s <= 0.1716): the first two terms in
    // double-double, the rest in double
    double zh, zl, ch, cl;
    TwoProd(sh, sh, &zh, &zl);
    zl += 2.0 * sh * sl;
    DdMul(zh, zl, sh, sl, &ch, &cl);                       // s^3
    double th, tl;
    DdMul(ch, cl, 6.66666666666666629659e-01, 3.70074341541718826848e-17, &th, &tl);   // 2/3 s^3
    double z = zh;
    double q = z * z * (1.0 / 5 + z * (1.0 / 7 + z * (1.0 / 9 + z * (1.0 / 11 + z * (1.0 / 13 + z * (1.0 / 15
             + z * (1.0 / 17 + z * (1.0 / 19 + z * (1.0 / 21 + z * (1.0 / 23 + z * (1.0 / 25)))))))))));
    double mh, ml, uh, ul;
    TwoSum(2.0 * sh, th, &uh, &ul);
    ul += 2.0 * sl + tl + 2.0 * sh * q;
    TwoSum(uh, ul, &mh, &ml);
    double dk = k, ah, al;
    TwoSum(dk * ln2_hi, mh, &ah, &al);   // (k ln2_hi is exact: the low 32 bits of ln2_hi are zero)
    al += ml + dk * ln2_lo;
    TwoSum(ah, al, lh, ll);
}

extern "C" double mpf_pow(double x, double y)
{
    if (y == 0) return 1.0;
    if (x == 1.0) return 1.0;
    if (IsNan(x) || IsNan(y)) return x + y;
    // y: 0 not an integer, 1 an odd integer, 2 an even integer
    int yint = 0;
    double ay = Abs(y);
    if (ay >= 9007199254740992.0) yint = IsInf(y) ? 0 : 2;
    else if (Rint(y) == y) yint = ((mi64)ay & 1) ? 1 : 2;
    double ax = Abs(x);
    if (IsInf(y)) {
        if (ax == 1.0) return 1.0;
        if (ax < 1.0) return y > 0 ? 0.0 : kInf;
        return y > 0 ? kInf : 0.0;
    }
    bool xneg = (Bits(x) >> 63) != 0;
    if (x == 0) {
        if (y < 0) return (yint == 1) ? CopySign(kInf, x) : kInf;
        return (yint == 1) ? x : 0.0;
    }
    if (IsInf(x)) {
        double r = y > 0 ? kInf : 0.0;
        return (xneg && yint == 1) ? -r : r;
    }
    if (xneg && yint == 0) return kNan;
    double sign = (xneg && yint == 1) ? -1.0 : 1.0;
    // an integer power: exact when the result is representable
    if (yint != 0 && ay < 2147483648.0) {
        double r;
        if (PowInt(ax, (mi64)y, &r)) return sign * r;
    }
    if (y == 0.5) return sign * Sqrt(ax);
    // (|y log x| beyond any double: 0 or infinity)
    if (ax == 1.0) return sign;
    if (ay > 1e300) return ((ax < 1.0) == (y > 0)) ? sign * 0.0 : sign * kInf;
    double lh, ll, ph, pl, e;
    LogDd(ax, &lh, &ll);
    double rough = y * lh;
    if (rough > 1000.0) return sign * kInf;
    if (rough < -1000.0) return sign * 0.0;
    TwoProd(y, lh, &ph, &e);
    e += y * ll;
    TwoSum(ph, e, &ph, &pl);
    if (ph > 709.782712893384) return sign * kInf;
    if (ph < -745.1332191019412) return sign * 0.0;
    double r = mpf_exp(ph);
    return sign * (r + r * pl);
}

// ---------------------------------------------------------------- sin, cos, tan (fdlibm k_sin.c, k_cos.c, e_rem_pio2.c)

static double KSin(double x, double y, int iy)
{
    const double S1 = -1.66666666666666324348e-01, S2 = 8.33333333332248946124e-03, S3 = -1.98412698298579493134e-04,
                 S4 = 2.75573137070700676789e-06, S5 = -2.50507602534068634195e-08, S6 = 1.58969099521155010221e-10;
    double z = x * x, w = z * z;
    double r = S2 + z * (S3 + z * S4) + z * w * (S5 + z * S6);
    double v = z * x;
    if (iy == 0) return x + v * (S1 + z * r);
    return x - ((z * (0.5 * y - v * r) - y) - v * S1);
}

static double KCos(double x, double y)
{
    const double C1 = 4.16666666666666019037e-02, C2 = -1.38888888888741095749e-03, C3 = 2.48015872894767294178e-05,
                 C4 = -2.75573143513906633035e-07, C5 = 2.08757232129817482790e-09, C6 = -1.13596475577881948265e-11;
    double z = x * x, w = z * z;
    double r = z * (C1 + z * (C2 + z * C3)) + w * w * (C4 + z * (C5 + z * C6));
    double hz = 0.5 * z;
    w = 1.0 - hz;
    return w + (((1.0 - w) - hz) + (z * r - x * y));
}

// x - n pi/2 = y0 + y1 (Cody and Waite in three steps for |x| < 2^20 pi/2)
static int RemPio2Large(double x, double* y0, double* y1);
static int RemPio2(double x, double* y0, double* y1)
{
    if (Abs(x) >= 1647099.3291652855) return RemPio2Large(x, y0, y1);   // 2^20 pi/2
    const double invpio2 = 6.36619772367581382433e-01,
                 pio2_1 = 1.57079632673412561417e+00, pio2_1t = 6.07710050650619224932e-11,
                 pio2_2 = 6.07710050630396597660e-11, pio2_2t = 2.02226624879595063154e-21,
                 pio2_3 = 2.02226624871116645580e-21, pio2_3t = 8.47842766036889956997e-32;
    double fn = Rint(x * invpio2);
    double r = x - fn * pio2_1;
    double w = fn * pio2_1t;
    int j = (int)((Hi(x) >> 20) & 0x7ff);
    *y0 = r - w;
    int i = j - (int)((Hi(*y0) >> 20) & 0x7ff);
    if (i > 16) {
        double t = r;
        w = fn * pio2_2;
        r = t - w;
        w = fn * pio2_2t - ((t - r) - w);
        *y0 = r - w;
        i = j - (int)((Hi(*y0) >> 20) & 0x7ff);
        if (i > 49) {
            t = r;
            w = fn * pio2_3;
            r = t - w;
            w = fn * pio2_3t - ((t - r) - w);
            *y0 = r - w;
        }
    }
    *y1 = (r - *y0) - w;
    // (the quadrant: fn modulo 4, also for |fn| >= 2^31)
    double q = fn - 4.0 * Rint(fn * 0.25);
    int n = (int)q;
    return n & 3;
}

// x - n pi/2 for |x| >= 2^20 pi/2 (Payne and Hanek): x = M 2^E, x 2/pi modulo 4 from the bits of 2/pi that matter, in 256-bit
// integers; the fraction keeps 128 bits, more than the closest a double comes to a multiple of pi/2 needs
static const mu64 kTwoOverPi[22] = {
    0xa2f9836e4e441529ULL, 0xfc2757d1f534ddc0ULL, 0xdb6295993c439041ULL, 0xfe5163abdebbc561ULL, 0xb7246e3a424dd2e0ULL,
    0x06492eea09d1921cULL, 0xfe1deb1cb129a73eULL, 0xe88235f52ebb4484ULL, 0xe99c7026b45f7e41ULL, 0x3991d639835339f4ULL,
    0x9c845f8bbdf9283bULL, 0x1ff897ffde05980fULL, 0xef2f118b5a0a6d1fULL, 0x6d367ecf27cb09b7ULL, 0x4f463f669e5fea2dULL,
    0x7527bac7ebe5f17bULL, 0x3d0739f78a5292eaULL, 0x6bfb5fb11f8d5d08ULL, 0x56033046fc7b6babULL, 0xf0cfbc209af4361dULL,
    0xa9e391615ee61b08ULL, 0x6599855f14a06840ULL };

static void Mul64(mu64 a, mu64 b, mu64* hi, mu64* lo)
{
    mu64 a0 = a & 0xffffffffULL, a1 = a >> 32, b0 = b & 0xffffffffULL, b1 = b >> 32;
    mu64 p00 = a0 * b0, p01 = a0 * b1, p10 = a1 * b0, p11 = a1 * b1;
    mu64 mid = (p00 >> 32) + (p01 & 0xffffffffULL) + (p10 & 0xffffffffULL);
    *lo = (mid << 32) | (p00 & 0xffffffffULL);
    *hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
}
// 64 bits of 2/pi from bit offset o (0: the first bit after the binary point)
static mu64 TwoOverPiBits(int o)
{
    int j = o >> 6, r = o & 63;
    mu64 a = j < 22 ? kTwoOverPi[j] : 0, b = j + 1 < 22 ? kTwoOverPi[j + 1] : 0;
    return r ? (a << r) | (b >> (64 - r)) : a;
}
// bit i of a 256-bit number (limbs, least significant first)
static inline mu64 Bits64At(const mu64* v, int pos)   // the 64 bits from pos upward
{
    int j = pos >> 6, r = pos & 63;
    mu64 a = (j >= 0 && j < 4) ? v[j] : 0, b = (j + 1 >= 0 && j + 1 < 4) ? v[j + 1] : 0;
    return r ? (a >> r) | (b << (64 - r)) : a;
}
static int RemPio2Large(double x, double* y0, double* y1)
{
    mu64 ix = Bits(x);
    bool neg = (ix >> 63) != 0;
    int e = (int)((ix >> 52) & 0x7ff) - 1023;
    mu64 M = (ix & 0x000fffffffffffffULL) | 0x0010000000000000ULL;
    int E = e - 52;
    int i0 = E - 1 > 1 ? E - 1 : 1;              // the first bit of 2/pi that matters modulo 4
    int shift = i0 + 191 - E;
    mu64 w[3] = { TwoOverPiBits(i0 - 1 + 128), TwoOverPiBits(i0 - 1 + 64), TwoOverPiBits(i0 - 1) };   // least significant first
    mu64 P[4] = { 0, 0, 0, 0 };
    for (int k = 0; k < 3; k++) {
        mu64 h, l;
        Mul64(M, w[k], &h, &l);
        mu64 s0 = P[k] + l, c0 = s0 < l;
        P[k] = s0;
        mu64 s1 = P[k + 1] + h + c0;
        mu64 c1 = (s1 < h) || (c0 && s1 == h);
        P[k + 1] = s1;
        if (k + 2 < 4) P[k + 2] += c1;
    }
    int n = (int)(Bits64At(P, shift) & 3);
    mu64 fhi = Bits64At(P, shift - 64), flo = Bits64At(P, shift - 128);
    double sign = 1.0;
    if (fhi >> 63) {
        // fraction >= 1/2: one quadrant more, and the remainder 1 - fraction, negative
        n = (n + 1) & 3;
        flo = ~flo + 1;
        fhi = ~fhi + (flo == 0 ? 1 : 0);
        sign = -1.0;
    }
    int lz = 0;
    while (lz < 120 && !(fhi >> 63)) { fhi = (fhi << 1) | (flo >> 63); flo <<= 1; lz++; }
    double dh = ScaleB((double)(fhi >> 11), -53 - lz);
    double dl = ScaleB((double)(((fhi & 0x7ffULL) << 42) | (flo >> 22)), -106 - lz);
    double rh, rl, p, e2;
    TwoSum(dh, dl, &rh, &rl);
    // times pi/2 in double-double
    const double pio2h = 1.57079632679489655800e+00, pio2l = 6.12323399573676588614e-17;
    TwoProd(rh, pio2h, &p, &e2);
    e2 += rh * pio2l + rl * pio2h;
    TwoSum(p, e2, y0, y1);
    *y0 *= sign; *y1 *= sign;
    if (neg) { *y0 = -*y0; *y1 = -*y1; n = (4 - n) & 3; }
    return n;
}

extern "C" double mpf_sin(double x)
{
    if (Abs(x) <= 7.85398163397448278999e-01) {
        if (Abs(x) < 7.450580596923828e-09) return x;   // 2^-27
        return KSin(x, 0.0, 0);
    }
    if (IsNan(x) || IsInf(x)) return x - x;
    double y0, y1;
    switch (RemPio2(x, &y0, &y1)) {
    case 0: return KSin(y0, y1, 1);
    case 1: return KCos(y0, y1);
    case 2: return -KSin(y0, y1, 1);
    default: return -KCos(y0, y1);
    }
}

extern "C" double mpf_cos(double x)
{
    if (Abs(x) <= 7.85398163397448278999e-01) {
        if (Abs(x) < 1.4901161193847656e-08) return 1.0;   // 2^-26
        return KCos(x, 0.0);
    }
    if (IsNan(x) || IsInf(x)) return x - x;
    double y0, y1;
    switch (RemPio2(x, &y0, &y1)) {
    case 0: return KCos(y0, y1);
    case 1: return -KSin(y0, y1, 1);
    case 2: return -KCos(y0, y1);
    default: return KSin(y0, y1, 1);
    }
}

extern "C" double mpf_tan(double x)
{
    if (Abs(x) <= 7.85398163397448278999e-01) {
        if (Abs(x) < 7.450580596923828e-09) return x;
        return KSin(x, 0.0, 0) / KCos(x, 0.0);
    }
    if (IsNan(x) || IsInf(x)) return x - x;
    double y0, y1;
    int n = RemPio2(x, &y0, &y1);
    double s = KSin(y0, y1, 1), c = KCos(y0, y1);
    return (n & 1) ? -c / s : s / c;
}

// ---------------------------------------------------------------- asin, acos, atan, atan2 (fdlibm)

static const double pio2_hi = 1.57079632679489655800e+00, pio2_lo = 6.12323399573676603587e-17,
                    pio4_hi = 7.85398163397448278999e-01;
static const double pS0 = 1.66666666666666657415e-01, pS1 = -3.25565818622400915405e-01, pS2 = 2.01212532134862925881e-01,
                    pS3 = -4.00555345006794114027e-02, pS4 = 7.91534994289814532176e-04, pS5 = 3.47933107596021167570e-05,
                    qS1 = -2.40339491173441421878e+00, qS2 = 2.02094576023350569471e+00, qS3 = -6.88283971605453293030e-01,
                    qS4 = 7.70381505559019352791e-02;

static inline double AsinR(double z)
{
    double p = z * (pS0 + z * (pS1 + z * (pS2 + z * (pS3 + z * (pS4 + z * pS5)))));
    double q = 1.0 + z * (qS1 + z * (qS2 + z * (qS3 + z * qS4)));
    return p / q;
}

extern "C" double mpf_asin(double x)
{
    double ax = Abs(x);
    if (ax >= 1.0) {
        if (ax == 1.0) return x * pio2_hi + x * pio2_lo;
        return IsNan(x) ? x + x : kNan;
    }
    if (ax < 0.5) {
        if (ax < 7.450580596923828e-09) return x;
        return x + x * AsinR(x * x);
    }
    double w = 1.0 - ax;
    double t = w * 0.5;
    double r = AsinR(t);
    double s = Sqrt(t);
    if (ax >= 0.975) {
        t = pio2_hi - (2.0 * (s + s * r) - pio2_lo);
    } else {
        double f = ClearLow(s);
        double c = (t - f * f) / (s + f);
        double p = 2.0 * s * r - (pio2_lo - 2.0 * c);
        double q = pio4_hi - 2.0 * f;
        t = pio4_hi - (p - q);
    }
    return x > 0 ? t : -t;
}

extern "C" double mpf_acos(double x)
{
    const double pi = 3.14159265358979311600e+00;
    double ax = Abs(x);
    if (ax >= 1.0) {
        if (x == 1.0) return 0.0;
        if (x == -1.0) return 2.0 * pio2_hi + 2.0 * pio2_lo;
        return IsNan(x) ? x + x : kNan;
    }
    if (ax < 0.5) {
        if (ax <= 6.938893903907228e-18) return pio2_hi + pio2_lo;   // 2^-57
        return pio2_hi - (x - (pio2_lo - x * AsinR(x * x)));
    }
    if (x < 0) {
        double z = (1.0 + x) * 0.5;
        double s = Sqrt(z);
        double w = AsinR(z) * s - pio2_lo;
        return pi - 2.0 * (s + w);
    }
    double z = (1.0 - x) * 0.5;
    double s = Sqrt(z);
    double df = ClearLow(s);
    double c = (z - df * df) / (s + df);
    double w = AsinR(z) * s + c;
    return 2.0 * (df + w);
}

extern "C" double mpf_atan(double x)
{
    static const double atanhi[] = { 4.63647609000806093515e-01, 7.85398163397448278999e-01, 9.82793723247329054082e-01, 1.57079632679489655800e+00 };
    static const double atanlo[] = { 2.26987774529616870924e-17, 3.06161699786838301793e-17, 1.39033110312309984516e-17, 6.12323399573676603587e-17 };
    static const double aT[] = { 3.33333333333329318027e-01, -1.99999999998764832476e-01, 1.42857142725034663711e-01,
                                 -1.11111104054623557880e-01, 9.09088713343650656196e-02, -7.69187620504482999495e-02,
                                 6.66107313738753120669e-02, -5.83357013379057348645e-02, 4.97687799461593236017e-02,
                                 -3.65315727442169155270e-02, 1.62858201153657823623e-02 };
    bool neg = (Bits(x) >> 63) != 0;
    double ax = Abs(x);
    int id;
    if (ax >= 7.378697629483821e+19) {   // 2^66
        if (IsNan(x)) return x + x;
        return neg ? -(atanhi[3] + atanlo[3]) : atanhi[3] + atanlo[3];
    }
    if (ax < 0.4375) {
        if (ax < 7.450580596923828e-09) return x;
        id = -1;
    } else {
        x = ax;
        if (ax < 1.1875) {
            if (ax < 0.6875) { id = 0; x = (2.0 * x - 1.0) / (2.0 + x); }
            else { id = 1; x = (x - 1.0) / (x + 1.0); }
        } else {
            if (ax < 2.4375) { id = 2; x = (x - 1.5) / (1.0 + 1.5 * x); }
            else { id = 3; x = -1.0 / x; }
        }
    }
    double z = x * x, w = z * z;
    double s1 = z * (aT[0] + w * (aT[2] + w * (aT[4] + w * (aT[6] + w * (aT[8] + w * aT[10])))));
    double s2 = w * (aT[1] + w * (aT[3] + w * (aT[5] + w * (aT[7] + w * aT[9]))));
    if (id < 0) return x - x * (s1 + s2);
    z = atanhi[id] - ((x * (s1 + s2) - atanlo[id]) - x);
    return neg ? -z : z;
}

extern "C" double mpf_atan2(double y, double x)
{
    const double pi = 3.1415926535897931160E+00, pi_lo = 1.2246467991473531772E-16, pi_o_2 = 1.5707963267948965580E+00,
                 pi_o_4 = 7.8539816339744827900E-01;
    if (IsNan(x) || IsNan(y)) return x + y;
    if (x == 1.0) return mpf_atan(y);
    int m = (int)(Bits(y) >> 63) | (int)((Bits(x) >> 63) << 1);
    if (y == 0) {
        switch (m) {
        case 0: case 1: return y;
        case 2: return pi;
        default: return -pi;
        }
    }
    if (x == 0) return (m & 1) ? -pi_o_2 : pi_o_2;
    if (IsInf(x)) {
        if (IsInf(y)) {
            switch (m) {
            case 0: return pi_o_4;
            case 1: return -pi_o_4;
            case 2: return 3.0 * pi_o_4;
            default: return -3.0 * pi_o_4;
            }
        }
        switch (m) {
        case 0: return 0.0;
        case 1: return -0.0;
        case 2: return pi;
        default: return -pi;
        }
    }
    if (IsInf(y)) return (m & 1) ? -pi_o_2 : pi_o_2;
    int k = (int)((Hi(y) >> 20) & 0x7ff) - (int)((Hi(x) >> 20) & 0x7ff);
    double z;
    if (k > 60) { z = pi_o_2 + 0.5 * pi_lo; m &= 1; }
    else if ((m & 2) && k < -60) z = 0.0;
    else z = mpf_atan(Abs(y / x));
    switch (m) {
    case 0: return z;
    case 1: return -z;
    case 2: return pi - (z - pi_lo);
    default: return (z - pi_lo) - pi;
    }
}

// ---------------------------------------------------------------- sinh, cosh, tanh

static double ExpM1(double x)
{
    double ax = Abs(x);
    if (ax < 5.551115123125783e-17) return x;   // 2^-54
    if (ax < 0.5) {
        // x + x^2/2! + ... + x^18/18!
        double s = 1.0 / 6402373705728000.0;     // 1/18!
        static const double inv[] = { 1.0 / 355687428096000.0, 1.0 / 20922789888000.0, 1.0 / 1307674368000.0, 1.0 / 87178291200.0,
                                      1.0 / 6227020800.0, 1.0 / 479001600.0, 1.0 / 39916800.0, 1.0 / 3628800.0, 1.0 / 362880.0,
                                      1.0 / 40320.0, 1.0 / 5040.0, 1.0 / 720.0, 1.0 / 120.0, 1.0 / 24.0, 1.0 / 6.0, 0.5 };
        for (int i = 0; i < 16; i++) s = s * x + inv[i];
        return x + x * x * s;
    }
    return mpf_exp(x) - 1.0;
}

extern "C" double mpf_sinh(double x)
{
    if (IsNan(x) || IsInf(x)) return x + x;
    double h = (Bits(x) >> 63) ? -0.5 : 0.5;
    double ax = Abs(x);
    if (ax < 22.0) {
        if (ax < 3.725290298461914e-09) return x;
        double t = ExpM1(ax);
        if (ax < 1.0) return h * (2.0 * t - t * t / (t + 1.0));
        return h * (t + t / (t + 1.0));
    }
    if (ax < 7.09782712893383973096e+02) return h * mpf_exp(ax);
    if (ax <= 7.10475860073943863426e+02) {
        double w = mpf_exp(0.5 * ax);
        double t = h * w;
        return t * w;
    }
    return x * 1e308 * 1e308;   // overflow, with its sign
}

extern "C" double mpf_cosh(double x)
{
    if (IsNan(x)) return x + x;
    double ax = Abs(x);
    if (IsInf(x)) return ax;
    if (ax < 3.46573590279972643113e-01) {
        double t = ExpM1(ax);
        double w = 1.0 + t;
        if (ax < 2.7755575615628914e-17) return w;
        return 1.0 + (t * t) / (w + w);
    }
    if (ax < 22.0) {
        double t = mpf_exp(ax);
        return 0.5 * t + 0.5 / t;
    }
    if (ax < 7.09782712893383973096e+02) return 0.5 * mpf_exp(ax);
    if (ax <= 7.10475860073943863426e+02) {
        double w = mpf_exp(0.5 * ax);
        double t = 0.5 * w;
        return t * w;
    }
    return kInf;
}

extern "C" double mpf_tanh(double x)
{
    if (IsNan(x)) return x + x;
    bool neg = (Bits(x) >> 63) != 0;
    double ax = Abs(x), z;
    if (ax >= 22.0) z = 1.0;
    else if (ax < 2.7755575615628914e-17) return x;
    else if (ax >= 1.0) { double t = ExpM1(2.0 * ax); z = 1.0 - 2.0 / (t + 2.0); }
    else { double t = ExpM1(-2.0 * ax); z = -t / (t + 2.0); }
    return neg ? -z : z;
}

// ---------------------------------------------------------------- the float versions: computed in double, rounded once

extern "C" float mpf_sinf(float x) { return (float)mpf_sin(x); }
extern "C" float mpf_cosf(float x) { return (float)mpf_cos(x); }
extern "C" float mpf_tanf(float x) { return (float)mpf_tan(x); }
extern "C" float mpf_asinf(float x) { return (float)mpf_asin(x); }
extern "C" float mpf_acosf(float x) { return (float)mpf_acos(x); }
extern "C" float mpf_atanf(float x) { return (float)mpf_atan(x); }
extern "C" float mpf_atan2f(float y, float x) { return (float)mpf_atan2(y, x); }
extern "C" float mpf_expf(float x) { return (float)mpf_exp(x); }
extern "C" float mpf_exp2f(float x) { return (float)mpf_exp2(x); }
extern "C" float mpf_logf(float x) { return (float)mpf_log(x); }
extern "C" float mpf_log2f(float x) { return (float)mpf_log2(x); }
extern "C" float mpf_log10f(float x) { return (float)mpf_log10(x); }
extern "C" float mpf_powf(float x, float y) { return (float)mpf_pow(x, y); }
extern "C" float mpf_tanhf(float x) { return (float)mpf_tanh(x); }

// the game's imports these replace (api-ms-win-crt-math-l1-1-0.dll), see PatchMath in mpfever_native.cpp
struct MpfMathEntry { const char* name; void* fn; };
extern "C" const MpfMathEntry g_mpfMath[] = {
    { "sin", (void*)&mpf_sin }, { "cos", (void*)&mpf_cos }, { "tan", (void*)&mpf_tan },
    { "asin", (void*)&mpf_asin }, { "acos", (void*)&mpf_acos }, { "atan", (void*)&mpf_atan }, { "atan2", (void*)&mpf_atan2 },
    { "sinh", (void*)&mpf_sinh }, { "cosh", (void*)&mpf_cosh }, { "tanh", (void*)&mpf_tanh },
    { "exp", (void*)&mpf_exp }, { "exp2", (void*)&mpf_exp2 }, { "log", (void*)&mpf_log }, { "log2", (void*)&mpf_log2 },
    { "log10", (void*)&mpf_log10 }, { "pow", (void*)&mpf_pow },
    { "sinf", (void*)&mpf_sinf }, { "cosf", (void*)&mpf_cosf }, { "tanf", (void*)&mpf_tanf }, { "asinf", (void*)&mpf_asinf },
    { "acosf", (void*)&mpf_acosf }, { "atanf", (void*)&mpf_atanf }, { "atan2f", (void*)&mpf_atan2f },
    { "expf", (void*)&mpf_expf }, { "exp2f", (void*)&mpf_exp2f }, { "logf", (void*)&mpf_logf }, { "log2f", (void*)&mpf_log2f },
    { "log10f", (void*)&mpf_log10f }, { "powf", (void*)&mpf_powf }, { "tanhf", (void*)&mpf_tanhf },
    { 0, 0 }
};
