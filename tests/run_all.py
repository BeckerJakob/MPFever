"""Runs every check that needs no game: the repository's checks (check_repo.py), every tests/test_*.py, and with --exe the
launcher's self-test (MPFever.exe --selftest). Called by build.bat before it packs a release, and by the CI on GitHub.

Nothing is skipped: a missing lupa, a test that says it was skipped, a test that runs longer than its time or exits with
anything but 0 fails the whole run.

    python tests/run_all.py                                     the Python checks only
    python tests/run_all.py --exe launcher/bin/Release/MPFever.exe   and the launcher's self-test
"""
import glob
import os
import pathlib
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
TIMEOUT = 600   # seconds per test (test_lockstep.py takes about 30)


def run(name, cmd):
    t0 = time.time()
    try:
        p = subprocess.run(cmd, cwd=HERE.parent, capture_output=True, timeout=TIMEOUT,
                           env=dict(os.environ, PYTHONIOENCODING="utf-8"))
        out = (p.stdout + p.stderr).decode("utf-8", "replace")
        code = p.returncode
    except subprocess.TimeoutExpired as e:
        out = ((e.stdout or b"") + (e.stderr or b"")).decode("utf-8", "replace") + f"\n(more than {TIMEOUT} s)"
        code = "timeout"
    # (a test that cannot run says "test skipped" and exits with 0)
    ok = code == 0 and "test skipped" not in out.lower()
    print(f"{'OK  ' if ok else 'FAIL'} {name} ({time.time() - t0:.0f} s, exit {code})", flush=True)
    if not ok:
        print("\n".join("    " + l for l in out.splitlines()[-60:]), flush=True)
    return ok


def main():
    try:
        import lupa  # noqa: F401  (the Lua tests run the mod's real files through it)
    except ImportError:
        print("FAIL lupa is not installed: pip install lupa")
        return 1
    results = [run("check_repo.py", [sys.executable, str(HERE / "check_repo.py")])]
    for t in sorted(glob.glob(str(HERE / "test_*.py"))):
        results.append(run(os.path.basename(t), [sys.executable, t]))
    if "--exe" in sys.argv:
        exe = pathlib.Path(sys.argv[sys.argv.index("--exe") + 1]).resolve()
        if not exe.is_file():
            print(f"FAIL {exe} not found")
            results.append(False)
        else:
            results.append(run("MPFever.exe --selftest", [str(exe), "--selftest"]))
    n_bad = results.count(False)
    print(f"{len(results) - n_bad}/{len(results)} passed" + ("" if n_bad == 0 else ": TESTS FAILED"))
    return 1 if n_bad else 0


if __name__ == "__main__":
    sys.exit(main())
