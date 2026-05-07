from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops


def load_rgb(path: Path) -> np.ndarray:
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0


def metrics(before: Path, after: Path) -> dict:
    a = load_rgb(before)
    b = load_rgb(after)
    if a.shape != b.shape:
        raise SystemExit(f"image sizes differ: {before}={a.shape}, {after}={b.shape}")
    delta = np.abs(b - a)
    luma_delta = (
        delta[..., 0] * 0.2126
        + delta[..., 1] * 0.7152
        + delta[..., 2] * 0.0722
    )
    changed = luma_delta > 0.025
    return {
        "before": str(before),
        "after": str(after),
        "meanAbsDelta": float(delta.mean()),
        "meanLumaDelta": float(luma_delta.mean()),
        "maxLumaDelta": float(luma_delta.max()),
        "changedPixelFraction": float(changed.mean()),
    }


def write_difference(before: Path, after: Path, out: Path) -> None:
    before_img = Image.open(before).convert("RGB")
    after_img = Image.open(after).convert("RGB")
    diff = ImageChops.difference(before_img, after_img)
    diff.save(out)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", required=True, type=Path)
    parser.add_argument("--after", required=True, type=Path)
    parser.add_argument("--out-dir", default=Path("out/visual-diff"), type=Path)
    parser.add_argument("--min-changed-fraction", default=0.006, type=float)
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    report = metrics(args.before, args.after)
    report["minChangedFraction"] = args.min_changed_fraction
    report["passed"] = report["changedPixelFraction"] >= args.min_changed_fraction
    write_difference(args.before, args.after, args.out_dir / "difference.png")
    (args.out_dir / "visual-diff.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    markdown = [
        "# Visual Before/After Pixel Proof",
        "",
        f"- Before: `{args.before}`",
        f"- After: `{args.after}`",
        f"- Mean abs delta: `{report['meanAbsDelta']:.6f}`",
        f"- Mean luma delta: `{report['meanLumaDelta']:.6f}`",
        f"- Changed pixel fraction: `{report['changedPixelFraction']:.6f}`",
        f"- Required changed fraction: `{args.min_changed_fraction:.6f}`",
        f"- Result: `{'pass' if report['passed'] else 'fail'}`",
    ]
    (args.out_dir / "visual-diff.md").write_text("\n".join(markdown) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    if not report["passed"]:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
