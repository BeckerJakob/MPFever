"""T0.15 (soak) - the games only run (MPFEVER_SCENARIO=soak) for MPF_SOAK_SECONDS (default 1800); the state checks
every 10 s show what drifts. Baseline of K8 (resynchronisations per hour) and the barrier stalls."""
import os

import pytest

from tools.mpftest import runner

pytestmark = pytest.mark.soak


@pytest.mark.parametrize("speed", [1, 4])
def test_soak(speed, metrics):
    exe = runner.find_exe()
    if not exe:
        pytest.skip("MPFever.exe not built: run build.bat or set MPF_EXE")
    secs = int(os.environ.get("MPF_SOAK_SECONDS", "1800"))
    out = runner.run_autotest(exe, ["soak"], os.environ.get("MPF_SAVE", "MPF-Test-Busy"), timeout=secs + 900,
                              extra_env={"MPFEVER_SOAK_SECONDS": str(secs), "MPFEVER_SOAK_SPEED": str(speed)})
    for k, v in out["kpi"].items():
        metrics[k] = v
    metrics["soak_seconds"] = secs
    metrics["resyncs_per_hour"] = round(out["kpi"].get("resyncs", 0) * 3600 / secs, 2)
    assert out["analysis"]["autotest"]["ready"], out["analysis"]["autotest"]["errors"]
