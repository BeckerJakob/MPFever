"""Old entry point (python tests/test_lockstep.py), kept for the README: runs the lockstep scenario, which now lives in
tests/sim/test_lockstep_scenario.py (N games, network emulation). The whole suite: test.bat (see docs/dev/TESTING.md)."""
import os
import sys

if __name__ == "__main__":
    import pytest
    here = os.path.dirname(os.path.abspath(__file__))
    sys.exit(pytest.main([os.path.join(here, "sim", "test_lockstep_scenario.py"), "-q", "--no-report"] + sys.argv[1:]))
