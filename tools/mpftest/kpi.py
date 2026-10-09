"""KPIs of a real run (docs/dev/PLAN.md, section 1) from analyze.analyze_run()."""
STEP = 200


def compute(run):
    games = run["games"].values()
    held = [h for g in games for h in g["held"]]
    late = [x for g in games for x in g["late"]]
    margins = [m["steps"] for g in games for m in g["margins"]]
    slowed = [s for g in games for s in g["slowed"]]
    frames = sum(s["frames"] for s in slowed)
    k = {
        # K1: game time between the click (build held by the DLL) and its stamp, in simulation steps
        "native_delay_steps_max": max(((h["at"] - h["now"]) // STEP for h in held), default=None),
        "native_builds": len(held),
        "late_actions": len(late),
        # a build released after its own stamp on the builder's game (the others then get it late or just in time)
        "released_late_steps_max": max((x["late_steps"] for g in games for x in g["released"]), default=0),
        "autotest_builds": sum(len(g["auto_builds"]) for g in games),
        "autotest_build_wall_seconds_max": max((b["wall_seconds"] for g in games for b in g["auto_builds"]), default=None),
        "late_steps_max": max((x["steps"] for x in late), default=0),
        "margin_steps_min": min(margins, default=None),
        "stamp_distance_steps": next((g["stamp_distance"] for g in games if g["stamp_distance"]), None),
        "barrier_stall_ratio": round(sum(s["by_clocks"] for s in slowed) / frames, 4) if frames else None,
        "failed_lines": sum(len(g["failed"]) for g in games),
        # K6 / K8: resynchronisations
        "resyncs": run["launcher"]["resyncs_started"],
        "resync_seconds_max": max(run["launcher"]["resync_seconds"], default=None),
        "desyncs": run["autotest"]["desyncs"],
        "scenario_timeouts": sum(1 for s in run["autotest"]["scenarios"] if s["timeout"]),
        # a scenario that ran but could not build (map-dependent: e.g. no tram here): not a sync failure
        "scenario_errors": sum(1 for s in run["autotest"]["scenarios"]
                               if any(w in s["result"].lower() for w in ("exception", "failed", "error"))),
        # K11: one state checksum, in seconds of standstill (the launcher logs the expensive ones)
        "checksum_seconds_max": max(run["launcher"]["checksum_seconds"], default=None),
        "checksums_expensive": len(run["launcher"]["checksum_seconds"]),
        "speed_changes": len(run["launcher"]["speed_changes"]),
        # engine assertions during the run (the asserting game stops with a 'Fatal error' dialog)
        "engine_assertions": len(run.get("engine_errors", [])),
    }
    return {name: v for name, v in k.items() if v is not None}
