"""Run report: every test with its outcome, duration and measured metrics, written as JSON and as one HTML page.
The KPI thresholds (tests/kpi_thresholds.toml) are checked here too: a metric outside its limit is listed as a KPI
violation and makes the run fail (exit code 1), like a failed test."""
import datetime
import html
import json
import os
import tomllib

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
REPO = os.path.dirname(TESTS)


def load_thresholds(path=os.path.join(TESTS, "kpi_thresholds.toml")):
    if not os.path.exists(path):
        return {}
    with open(path, "rb") as f:
        return tomllib.load(f).get("metric", {})


def check_kpis(results, thresholds):
    """results: [{nodeid, metrics}]; thresholds: {metric: {max=.., min=..}} -> list of violations (text)."""
    out = []
    for r in results:
        if r.get("outcome") in ("xfailed", "skipped"):
            continue            # a known finding (xfail) is reported as such, not twice as a KPI violation
        for name, value in r["metrics"].items():
            t = thresholds.get(name)
            if not t or not isinstance(value, (int, float)):
                continue
            if "max" in t and value > t["max"]:
                out.append("%s: %s = %s > max %s" % (r["nodeid"], name, value, t["max"]))
            if "min" in t and value < t["min"]:
                out.append("%s: %s = %s < min %s" % (r["nodeid"], name, value, t["min"]))
    return out


class Reporter:
    def __init__(self, config):
        self.config = config
        self.results, self.by_id = [], {}
        self.started = datetime.datetime.now()
        d = config.getoption("--report-dir")
        self.dir = d or os.path.join(REPO, "reports", self.started.strftime("%Y%m%d-%H%M%S"))
        self.violations = []

    def pytest_runtest_logreport(self, report):
        metrics = {k[len("metric:"):]: v for k, v in report.user_properties if k.startswith("metric:")}
        entry = self.by_id.get(report.nodeid)
        if report.when == "call" or (report.when == "setup" and report.outcome != "passed"):
            outcome = report.outcome
            if hasattr(report, "wasxfail"):
                outcome = "xfailed" if report.outcome == "skipped" else "xpassed"
            message = ""
            if report.outcome == "failed":
                message = str(report.longrepr)[-4000:]
            elif hasattr(report, "wasxfail"):
                message = report.wasxfail
            elif report.outcome == "skipped" and isinstance(report.longrepr, tuple):
                message = report.longrepr[2]
            entry = {
                "nodeid": report.nodeid,
                "outcome": outcome,
                "duration": round(report.duration, 3),
                "markers": sorted(m for m in ("unit", "sim", "native", "e2e", "soak") if m in report.keywords),
                "metrics": {},
                "message": message,
            }
            self.by_id[report.nodeid] = entry
            self.results.append(entry)
        if entry is not None:
            # the metrics fixture records its values at teardown: they arrive with the teardown report
            entry["metrics"].update(metrics)

    def pytest_sessionfinish(self, session, exitstatus):
        if not self.results:
            return
        self.violations = check_kpis(self.results, load_thresholds())
        if self.violations and session.exitstatus == 0:
            session.exitstatus = 1
        os.makedirs(self.dir, exist_ok=True)
        data = {
            "started": self.started.isoformat(timespec="seconds"),
            "args": self.config.invocation_params.args,
            "summary": {o: sum(1 for r in self.results if r["outcome"] == o) for o in ("passed", "failed", "skipped", "xfailed", "xpassed")},
            "kpi_violations": self.violations,
            "results": self.results,
        }
        with open(os.path.join(self.dir, "results.json"), "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        with open(os.path.join(self.dir, "report.html"), "w", encoding="utf-8") as f:
            f.write(render_html(data))

    def pytest_terminal_summary(self, terminalreporter):
        if not self.results:
            return
        for v in self.violations:
            terminalreporter.write_line("KPI VIOLATION " + v, red=True)
        terminalreporter.write_line("MPFever report: " + os.path.join(self.dir, "report.html"))


def render_html(data):
    color = {"passed": "#1a7f37", "failed": "#cf222e", "skipped": "#9a6700", "xfailed": "#8250df", "xpassed": "#cf222e"}
    rows = []
    for r in data["results"]:
        m = ", ".join("%s=%s" % kv for kv in sorted(r["metrics"].items()))
        rows.append("<tr><td style='color:%s'>%s</td><td><code>%s</code></td><td>%s</td><td>%.2f s</td><td>%s</td></tr>%s" % (
            color.get(r["outcome"], "#000"), r["outcome"], html.escape(r["nodeid"]), " ".join(r["markers"]), r["duration"],
            html.escape(m),
            ("<tr><td></td><td colspan=4><pre>%s</pre></td></tr>" % html.escape(r["message"])) if r["message"] else ""))
    s = data["summary"]
    kpi = "".join("<li>%s</li>" % html.escape(v) for v in data["kpi_violations"]) or "<li>none</li>"
    return """<!doctype html><html lang="en"><head><meta charset="utf-8"><title>MPFever test run</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>body{font:14px system-ui,sans-serif;margin:16px;color:#1f2328;background:#fff}table{border-collapse:collapse;width:100%%}
td,th{border-bottom:1px solid #d0d7de;padding:4px 8px;text-align:left;vertical-align:top}pre{white-space:pre-wrap;font-size:12px;margin:0}
code{font-size:12px}</style></head><body>
<h1>MPFever test run</h1><p>%s &middot; <code>%s</code></p>
<p><b>%d passed</b>, <b>%d failed</b>, %d skipped, %d xfailed (known findings), %d xpassed</p><h2>KPI violations</h2><ul>%s</ul>
<h2>Tests</h2><table><tr><th>outcome</th><th>test</th><th>level</th><th>time</th><th>metrics</th></tr>%s</table></body></html>""" % (
        html.escape(data["started"]), html.escape(" ".join(data["args"])), s["passed"], s["failed"], s["skipped"], s["xfailed"], s["xpassed"], kpi, "".join(rows))
