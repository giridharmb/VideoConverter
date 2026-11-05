#!/usr/bin/env python3
"""Read SQLite telemetry without modifying it; export path-free benchmark summaries."""
import argparse
import csv
import json
import math
from pathlib import Path
import sqlite3
import statistics


def percentile(values, fraction):
    values = sorted(v for v in values if v is not None and math.isfinite(v))
    if not values:
        return None
    position = (len(values) - 1) * fraction
    low, high = math.floor(position), math.ceil(position)
    return values[low] + (values[high] - values[low]) * (position - low)


def distribution(values):
    values = [v for v in values if v is not None and math.isfinite(v)]
    return {"n": len(values), "mean": statistics.mean(values) if values else None,
            "p50": percentile(values, .5), "p95": percentile(values, .95), "max": max(values) if values else None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, default=Path.home() / "Library/Application Support/VideoConverter/telemetry.sqlite")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--prefix", default="")
    args = parser.parse_args()
    db = sqlite3.connect(args.database.resolve().as_uri() + "?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    assert db.execute("PRAGMA quick_check").fetchone()[0] == "ok"
    assert not db.execute("PRAGMA foreign_key_check").fetchall()
    args.output.mkdir(parents=True, exist_ok=True)
    sessions = [dict(row) for row in db.execute("SELECT * FROM sessions WHERE label LIKE ? ORDER BY started_at", (args.prefix + "%",))]
    result = {"sqlite_version": sqlite3.sqlite_version, "integrity": "ok", "sessions": [], "profiles": []}
    profile_rows = []
    for session in sessions:
        sid = session["id"]
        jobs = [dict(row) for row in db.execute("SELECT * FROM jobs WHERE session_id=?", (sid,))]
        metrics = [dict(row) for row in db.execute("SELECT * FROM metrics WHERE session_id=? ORDER BY at", (sid,))]
        operations = [dict(row) for row in db.execute("SELECT * FROM operations WHERE session_id=? ORDER BY at", (sid,))]
        configs = [o for o in operations if o["name"] == "scenario_config"]
        config = json.loads(configs[0]["detail"]) if configs else {}
        executed = [j for j in jobs if j["created_at"] >= session["started_at"] or (j["started_at"] or 0) >= session["started_at"]]
        valid = [job for job in executed if "/negative/" not in job["input_path"]]
        completed = [job for job in valid if job["state"] == "completed"]
        negatives = [job for job in executed if "/negative/" in job["input_path"]]
        wall = next((o["duration_ms"] / 1000 for o in operations if o["name"] == "batch_wall"), None)
        summary = {"label": session["label"], "finished": session["finished_at"] is not None, "logical_cpus": session["logical_cpus"],
                   "parallel": config.get("parallel"), "encoder_threads": config.get("threads"), "mode": config.get("mode"),
                   "chunk_workers": config.get("chunk_workers"), "chunk_seconds": config.get("chunk_seconds"),
                   "valid_jobs": len(valid), "valid_completed": len(completed), "unexpected_failures": len(valid) - len(completed),
                   "restored_jobs": len(jobs) - len(executed),
                   "negative_states": [j["state"] for j in negatives], "wall_seconds": wall,
                   "valid_jobs_per_second": len(completed) / wall if wall else None,
                   "telemetry_samples": len(metrics), "log_rows": db.execute("SELECT count(*) FROM logs WHERE session_id=?", (sid,)).fetchone()[0],
                   "peak_worker_cpu": max((m["worker_cpu"] for m in metrics), default=0),
                   "mean_app_cpu": statistics.mean(m["app_cpu"] for m in metrics) if metrics else None,
                   "peak_total_memory_mib": max(((m["app_memory"] + m["worker_memory"]) / 1048576 for m in metrics), default=0),
                   "peak_threads": max((m["threads"] for m in metrics), default=0),
                   "peak_read_mib_s": max((m["read_bps"] / 1048576 for m in metrics), default=0),
                   "peak_write_mib_s": max((m["write_bps"] / 1048576 for m in metrics), default=0),
                   "thermal_states": sorted({m["thermal"] for m in metrics}),
                   "telemetry_dropped_total": max((json.loads(o["detail"])["dropped_total"] for o in operations if o["name"] == "telemetry_health"), default=None),
                   "operations_ms": {name: distribution([o["duration_ms"] for o in operations if o["name"] == name]) for name in sorted({o["name"] for o in operations})},
                   "phase_totals_ms": {phase: sum(j[phase] for j in completed) for phase in ["inspection_ms", "planning_ms", "preparation_ms", "encoding_ms", "verification_ms", "commit_ms"]}}
        ui_tabs = [o["at"] for o in operations if o["name"] == "ui_tab" and o["detail"] == "Metrics"]
        if ui_tabs and completed and metrics:
            idle_start = max(ui_tabs[0], max(j["finished_at"] for j in completed)) + 3
            idle_end = min(idle_start + 30, metrics[-1]["at"])
            idle_metrics = [m for m in metrics if idle_start <= m["at"] <= idle_end]
            deliveries = [o["duration_ms"] for o in operations if o["name"] == "ui_snapshot_delivery" and idle_start <= o["at"] <= idle_end]
            lags = [o["duration_ms"] for o in operations if o["name"] == "ui_heartbeat_lag" and idle_start <= o["at"] <= idle_end]
            if idle_metrics and idle_end > idle_start:
                summary["ui_idle_window"] = {"seconds": idle_end-idle_start, "samples": len(idle_metrics),
                    "mean_app_cpu": statistics.mean(m["app_cpu"] for m in idle_metrics),
                    "snapshot_deliveries_per_second": len(deliveries)/(idle_end-idle_start),
                    "snapshot_delivery_ms": distribution(deliveries), "heartbeat_lag_ms": distribution(lags)}
        result["sessions"].append(summary)
        for job in completed:
            settings = json.loads(job["settings_json"])
            profile_rows.append({"session": session["label"], "source": Path(job["input_path"]).name,
                "profile": settings["suffix"].removeprefix("_"), "output_format": job["output_format"], "video_codec": job["video_codec"],
                "audio_codec": job["audio_codec"], "crf": job["quality"], "audio_bitrate": settings["audioBitrate"],
                "chunk_workers": (settings.get("chunking") or {}).get("workers", 1),
                "chunk_seconds": (settings.get("chunking") or {}).get("seconds"),
                "input_bytes": job["input_bytes"], "output_bytes": job["output_bytes"],
                "output_input_ratio": job["output_bytes"] / job["input_bytes"] if job["input_bytes"] else None,
                "encoding_ms": job["encoding_ms"], "verification_ms": job["verification_ms"],
                "job_wall_ms": (job["finished_at"] - job["started_at"]) * 1000 if job["finished_at"] and job["started_at"] else None})
    result["profiles"] = profile_rows
    (args.output / "analysis.json").write_text(json.dumps(result, indent=2) + "\n")
    if profile_rows:
        with (args.output / "profiles.csv").open("w", newline="") as file:
            writer = csv.DictWriter(file, fieldnames=profile_rows[0].keys(), lineterminator="\n"); writer.writeheader(); writer.writerows(profile_rows)
    for s in result["sessions"]:
        wall = f"{s['wall_seconds']:.2f}s" if s["wall_seconds"] else "no batch window"
        print(f"{s['label']}: {s['valid_completed']}/{s['valid_jobs']} valid jobs, {wall}, "
              f"peak workers {s['peak_worker_cpu']:.0f}% CPU / {s['peak_total_memory_mib']:.0f} MiB / {s['peak_threads']} threads")
    print(f"Integrity OK. Wrote path-free analysis and profile data to {args.output}")


if __name__ == "__main__":
    main()
