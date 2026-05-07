from __future__ import annotations

import argparse
import csv
import json
import statistics
from pathlib import Path


def number(row: dict[str, str], key: str, default: float = 0.0) -> float:
    try:
        return float(row.get(key, default))
    except ValueError:
        return default


def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(round((len(ordered) - 1) * p))))
    return ordered[index]


def longest_run(values: list[int], target: int) -> int:
    longest = 0
    current = 0
    for value in values:
        if value == target:
            current += 1
            longest = max(longest, current)
        else:
            current = 0
    return longest


def periodic_skip_score(presented: list[int]) -> float:
    if len(presented) < 12:
        return 0.0
    misses = [1 - value for value in presented]
    if not any(misses):
        return 0.0
    scores: list[float] = []
    for period in (3, 4, 5, 6):
        buckets = [0] * period
        counts = [0] * period
        for i, miss in enumerate(misses):
            buckets[i % period] += miss
            counts[i % period] += 1
        rates = [buckets[i] / max(1, counts[i]) for i in range(period)]
        scores.append(max(rates) - min(rates))
    return max(scores)


def analyze(path: Path) -> dict:
    with path.open("r", newline="", encoding="utf-8-sig") as handle:
        rows = list(csv.DictReader(handle))
    if len(rows) < 8:
        raise SystemExit(f"trace needs at least 8 rows: {path}")

    presented = [int(number(row, "presented")) for row in rows]
    copied = [int(number(row, "copied")) for row in rows]
    reused = [int(number(row, "reusedDisplayFrame")) for row in rows]
    tick_ms = [number(row, "tickMs") for row in rows]
    frame_us = [number(row, "frameUs") for row in rows]
    present_us = [number(row, "presentUs") for row in rows if int(number(row, "presented")) == 1]
    present_ticks = [tick_ms[i] for i, value in enumerate(presented) if value == 1]
    present_intervals = [b - a for a, b in zip(present_ticks, present_ticks[1:]) if b >= a]
    frame_intervals = [b - a for a, b in zip(tick_ms, tick_ms[1:]) if b >= a]

    mean_present_interval = statistics.fmean(present_intervals) if present_intervals else 0.0
    p95_present_interval = percentile(present_intervals, 0.95)
    max_present_interval = max(present_intervals) if present_intervals else 0.0
    present_jitter_ms = p95_present_interval - mean_present_interval if present_intervals else 0.0
    present_rate = sum(presented) / len(presented)
    copy_rate = sum(copied) / len(copied)
    reuse_rate = sum(reused) / len(reused)
    issues: list[str] = []

    if present_rate < 0.70:
        issues.append("presentation cadence dropped too many app frames")
    if present_intervals and max_present_interval > max(18.0, mean_present_interval * 2.25):
        issues.append("presentation has large skipped-frame interval")
    if present_jitter_ms > 8.0:
        issues.append("presentation cadence jitter is above stability budget")
    if longest_run(presented, 0) > 2:
        issues.append("presentation has consecutive missed-frame run")
    if periodic_skip_score(presented) > 0.45:
        issues.append("presentation misses have periodic every-N-frame pattern")
    if copy_rate < 0.02 and reuse_rate < 0.20:
        issues.append("trace lacks copied or intentionally reused CUDA frames")

    return {
        "path": str(path),
        "rows": len(rows),
        "presentRate": present_rate,
        "copyRate": copy_rate,
        "reuseRate": reuse_rate,
        "meanFrameIntervalMs": statistics.fmean(frame_intervals) if frame_intervals else 0.0,
        "meanPresentIntervalMs": mean_present_interval,
        "p95PresentIntervalMs": p95_present_interval,
        "maxPresentIntervalMs": max_present_interval,
        "presentJitterMs": present_jitter_ms,
        "meanFrameUs": statistics.fmean(frame_us) if frame_us else 0.0,
        "meanPresentUs": statistics.fmean(present_us) if present_us else 0.0,
        "longestMissedPresentRun": longest_run(presented, 0),
        "periodicSkipScore": periodic_skip_score(presented),
        "issues": issues,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Analyze Native FireSim live-frame trace cadence for temporal stutter regressions.")
    parser.add_argument("--trace", type=Path, default=Path("out/live-frame-trace.csv"))
    parser.add_argument("--out", type=Path, default=Path("out/live-frame-trace-report.json"))
    parser.add_argument("--fail-on-issues", action="store_true")
    args = parser.parse_args()

    report = analyze(args.trace)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    if args.fail_on_issues and report["issues"]:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
