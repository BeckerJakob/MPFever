"""python -m tools.mpftest analyze <autotest_result.txt> [launcher.log]   - KPIs of an existing run, as JSON
   python -m tools.mpftest run <scenario,...> [savegame]                   - a new autotest run (starts the game twice)"""
import json
import sys

from . import analyze, kpi, runner


def main(argv):
    if len(argv) >= 2 and argv[0] == "analyze":
        run = analyze.analyze_run(argv[1], argv[2] if len(argv) > 2 else None)
        print(json.dumps({"kpi": kpi.compute(run), "analysis": run}, indent=2, ensure_ascii=False))
        return 0
    if len(argv) >= 2 and argv[0] == "run":
        exe = runner.find_exe()
        if not exe:
            print("MPFever.exe not found: build it (build.bat) or set MPF_EXE")
            return 2
        out = runner.run_autotest(exe, argv[1].split(","), argv[2] if len(argv) > 2 else runner.DEFAULT_SAVE)
        print(json.dumps(out, indent=2, ensure_ascii=False))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
