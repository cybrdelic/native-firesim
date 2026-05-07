from __future__ import annotations

import json
import sys
from pathlib import Path


TIMING_KEYS = [
    "averageCudaMs",
    "averageSubmitMs",
    "averagePublishMs",
    "averageFrameMs",
    "averageGpuVelocityMs",
    "averageGpuReactionMs",
    "averageGpuProjectionMs",
    "averageGpuLightingMs",
    "averageGpuRaymarchMs",
    "averageGpuPackMs",
]

BREAKDOWN_KEYS = [
    "averageGpuVelocityMs",
    "averageGpuReactionMs",
    "averageGpuProjectionMs",
    "averageGpuLightingMs",
    "averageGpuRaymarchMs",
    "averageGpuPackMs",
]


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: summarize-gpu-timings.py <worker-benchmark.json> <out.md>")
    source = Path(sys.argv[1])
    out = Path(sys.argv[2])
    data = json.loads(source.read_text(encoding="utf-8"))
    rows = []
    for key in TIMING_KEYS:
        if key in data:
            rows.append((key, float(data[key])))
    rows.sort(key=lambda item: item[1], reverse=True)
    breakdown_total = sum(float(data.get(key, 0.0)) for key in BREAKDOWN_KEYS)
    breakdown_total = max(0.000001, breakdown_total)

    lines = [
        "# Native FireSim GPU Timing Summary",
        "",
        f"- Source: `{source}`",
        f"- Effective FPS: `{float(data.get('effectiveFps', 0.0)):.2f}`",
        f"- Hotspot policy: `{data.get('hotspotPolicy', 'measure before optimizing; do not reduce quality')}`",
        f"- Grid: `{data.get('requestedGrid', [])}`",
        f"- Raymarch steps: `{data.get('raymarchSteps', 'unknown')}`",
        f"- Pressure iterations: `{data.get('pressureIterations', 'unknown')}`",
        "",
        "| Timing field | ms | sampled breakdown share |",
        "| --- | ---: | ---: |",
    ]
    for key, value in rows:
        share = (value / breakdown_total) * 100.0 if key in BREAKDOWN_KEYS else 0.0
        share_text = f"{share:.1f}%" if key in BREAKDOWN_KEYS else "live/frame metric"
        lines.append(f"| `{key}` | {value:.4f} | {share_text} |")
    hotspot_ranking = data.get("hotspotRanking", [])
    if hotspot_ranking:
        lines.extend(
            [
                "",
                "## Hotspot Ranking",
                "",
                "| Rank | CUDA pass | average ms |",
                "| ---: | --- | ---: |",
            ]
        )
        for index, item in enumerate(hotspot_ranking, start=1):
            lines.append(f"| {index} | `{item.get('pass', 'unknown')}` | {float(item.get('averageMs', 0.0)):.4f} |")
    lines.extend(
        [
            "",
            "## Review Notes",
            "",
            "The per-kernel rows are sampled breakdown metrics. They are not summed into the live frame time, so this table reports their share of the sampled kernel breakdown separately from live submit/publish/frame timing.",
            "",
            "Use this summary to decide which kernel or pass deserves optimization work. Do not reduce visual quality unless a separate PR explicitly changes the quality target.",
        ]
    )
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"gpu timing summary: {out}")


if __name__ == "__main__":
    main()
