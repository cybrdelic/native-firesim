from __future__ import annotations

import argparse
import csv
import json
import statistics
from pathlib import Path


def number(row: dict[str, str], key: str, default: float = 0.0) -> float:
    try:
        value = row.get(key, default)
        return default if value is None or value == "" else float(value)
    except (TypeError, ValueError):
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
        reader = csv.DictReader(handle)
        field_count = len(reader.fieldnames or [])
        rows = [
            row for row in reader
            if field_count > 0 and len(row) == field_count and None not in row.values()
        ]
    if len(rows) < 8:
        raise SystemExit(f"trace needs at least 8 rows: {path}")

    presented = [int(number(row, "presented")) for row in rows]
    copied = [int(number(row, "copied")) for row in rows]
    reused = [int(number(row, "reusedDisplayFrame")) for row in rows]
    worker_published = [int(number(row, "workerPublishedFrames")) for row in rows]
    worker_physics = [int(number(row, "workerPhysicsFrames")) for row in rows]
    worker_render_only = [int(number(row, "workerRenderOnlyFrames")) for row in rows]
    ring_shared_slots = [int(number(row, "ringSharedSlot", -1)) for row in rows]
    ring_timeouts = [int(number(row, "ringTimeouts")) for row in rows]
    ring_no_candidate = [int(number(row, "ringNoCandidate")) for row in rows]
    ring_starved = [int(number(row, "ringStarved")) for row in rows]
    frame_age_ms = [number(row, "frameAgeMs") for row in rows]
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
    physics_deltas = [max(0, b - a) for a, b in zip(worker_physics, worker_physics[1:])]
    render_only_deltas = [max(0, b - a) for a, b in zip(worker_render_only, worker_render_only[1:])]
    published_deltas = [max(0, b - a) for a, b in zip(worker_published, worker_published[1:])]
    timeout_deltas = [max(0, b - a) for a, b in zip(ring_timeouts, ring_timeouts[1:])]
    no_candidate_deltas = [max(0, b - a) for a, b in zip(ring_no_candidate, ring_no_candidate[1:])]
    starved_deltas = [max(0, b - a) for a, b in zip(ring_starved, ring_starved[1:])]
    physics_steps = sum(physics_deltas)
    render_only_steps = sum(render_only_deltas)
    published_steps = sum(published_deltas)
    simulated_worker_steps = physics_steps + render_only_steps
    worker_physics_ratio = physics_steps / max(1, simulated_worker_steps)
    longest_render_only_run = longest_run([1 if value > 0 else 0 for value in render_only_deltas], 1)
    longest_copy_miss_run = longest_run(copied, 0)
    valid_shared_slots = [slot for slot in ring_shared_slots if slot >= 0]
    slot_coverage = len(set(valid_shared_slots))
    repeated_slot_flags = [
        1 if b >= 0 and a == b and copied[i] == 1 else 0
        for i, (a, b) in enumerate(zip(ring_shared_slots, ring_shared_slots[1:]), start=1)
    ]
    longest_repeated_shared_slot_run = longest_run(repeated_slot_flags, 1)
    max_frame_age_ms = max(frame_age_ms) if frame_age_ms else 0.0
    timeout_events = sum(timeout_deltas)
    no_candidate_events = sum(no_candidate_deltas)
    starved_events = sum(starved_deltas)
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
    if simulated_worker_steps >= 8 and worker_physics_ratio < 0.92:
        issues.append("worker physics cadence is below published frame cadence")
    if longest_render_only_run > 0:
        issues.append("worker emitted render-only frames between physics updates")
    if longest_copy_miss_run > 3 and published_steps > 0:
        issues.append("CUDA fire frames have consecutive copy misses")
    if max_frame_age_ms > 40.0 and copy_rate < 0.75:
        issues.append("CUDA fire frame age exceeded freshness budget")
    if timeout_events > max(2, len(rows) // 12):
        issues.append("shared texture ring has keyed-mutex timeout pressure")
    if no_candidate_events > max(2, len(rows) // 10):
        issues.append("shared texture ring produced no copy candidates")
    if starved_events > 0:
        issues.append("shared texture ring copy path starved")
    if published_steps >= 8 and slot_coverage <= 1:
        issues.append("shared texture producer did not rotate slots")
    if longest_repeated_shared_slot_run > 5 and published_steps >= 8:
        issues.append("shared texture ring repeatedly copied the same slot")

    return {
        "path": str(path),
        "rows": len(rows),
        "presentRate": present_rate,
        "copyRate": copy_rate,
        "reuseRate": reuse_rate,
        "workerPhysicsRatio": worker_physics_ratio,
        "workerPhysicsSteps": physics_steps,
        "workerRenderOnlySteps": render_only_steps,
        "workerPublishedSteps": published_steps,
        "simulatedWorkerSteps": simulated_worker_steps,
        "longestRenderOnlyRun": longest_render_only_run,
        "maxFrameAgeMs": max_frame_age_ms,
        "longestCopyMissRun": longest_copy_miss_run,
        "ringTimeoutEvents": timeout_events,
        "ringNoCandidateEvents": no_candidate_events,
        "ringStarvedEvents": starved_events,
        "sharedSlotCoverage": slot_coverage,
        "longestRepeatedSharedSlotRun": longest_repeated_shared_slot_run,
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
