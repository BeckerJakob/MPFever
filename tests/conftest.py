"""pytest setup for MPFever: test levels (markers), switches for the levels that need the game, metrics and the run
report (reports/<date>-<time>/results.json + report.html, see harness/reporting.py)."""
import locale
import os
import sys

import pytest

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TESTS)
sys.path.insert(0, os.path.dirname(TESTS))     # tools.mpftest

from harness import reporting  # noqa: E402

LEVELS = {
    "unit": "L1: single modules, no game",
    "sim": "L2: several mocked games running the real Lua files",
    "native": "L3: offline checks against the installed game executable (read only)",
    "e2e": "L4: two real game instances on this PC (needs --run-e2e)",
    "soak": "L5: long runs with real games (needs --run-soak)",
}


def pytest_addoption(parser):
    parser.addoption("--run-e2e", action="store_true", help="run the e2e tests (starts the game twice)")
    parser.addoption("--run-soak", action="store_true", help="run the soak tests (hours)")
    parser.addoption("--report-dir", default=None, help="where the run report goes (default reports/<timestamp>)")
    parser.addoption("--no-report", action="store_true", help="do not write a run report")


def pytest_sessionstart(session):
    # Python sets LC_CTYPE to the user's code page (German_Germany.1252 here) at startup; Lua's %c (C.ser escapes
    # control characters) follows it. The tests use the "C" locale, the one a process has unless it calls setlocale.
    # Finding F2 (test_serializer.py) shows what changes under a code page.
    locale.setlocale(locale.LC_CTYPE, "C")


def pytest_configure(config):
    for name, text in LEVELS.items():
        config.addinivalue_line("markers", "%s: %s" % (name, text))
    if not config.getoption("--no-report"):
        config.pluginmanager.register(reporting.Reporter(config), "mpf_reporter")


def pytest_collection_modifyitems(config, items):
    for item in items:
        if "e2e" in item.keywords and not config.getoption("--run-e2e"):
            item.add_marker(pytest.mark.skip(reason="e2e: starts the game, run with --run-e2e (test.bat e2e)"))
        if "soak" in item.keywords and not config.getoption("--run-soak"):
            item.add_marker(pytest.mark.skip(reason="soak: hours of game time, run with --run-soak (test.bat soak)"))


@pytest.fixture
def metrics(request):
    """dict of numbers a test measured; they go to the run report (and are compared with tests/kpi_thresholds.toml)."""
    m = {}
    yield m
    for k, v in m.items():
        request.node.user_properties.append(("metric:" + k, v))
