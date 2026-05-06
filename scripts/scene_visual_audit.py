from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "out" / "scene-visual-audit"
SCENES = {
    "room": OUT / "room" / "validation-frame.bmp",
    "campfire": OUT / "campfire" / "validation-frame.bmp",
    "burner": OUT / "burner" / "validation-frame.bmp",
}


def metrics(path: Path) -> dict:
    image = Image.open(path).convert("RGB")
    arr = np.asarray(image, dtype=np.float32) / 255.0
    luma = arr[..., 0] * 0.2126 + arr[..., 1] * 0.7152 + arr[..., 2] * 0.0722
    maxc = arr.max(axis=2)
    minc = arr.min(axis=2)
    sat = np.divide(maxc - minc, maxc, out=np.zeros_like(maxc), where=maxc > 0.0001)
    warm = (arr[..., 0] > arr[..., 1] * 1.08) & (arr[..., 0] > arr[..., 2] * 1.55) & (luma > 0.18)
    blue = (arr[..., 2] > arr[..., 0] * 1.08) & (arr[..., 2] > arr[..., 1] * 1.02) & (luma > 0.10)
    hot = luma > 0.64
    dark_smoke = (luma < 0.18) & (sat < 0.45)
    yy, xx = np.where(warm | blue | hot)
    bbox = [0, 0, 0, 0]
    height_fraction = 0.0
    local_dark_smoke = 0.0
    plume_dark_smoke = 0.0
    if yy.size:
        bbox = [int(xx.min()), int(yy.min()), int(xx.max()), int(yy.max())]
        height_fraction = float((yy.max() - yy.min() + 1) / image.height)
        pad = 42
        x0 = max(0, bbox[0] - pad)
        y0 = max(0, bbox[1] - pad)
        x1 = min(image.width, bbox[2] + pad + 1)
        y1 = min(image.height, bbox[3] + pad + 1)
        region = dark_smoke[y0:y1, x0:x1]
        local_dark_smoke = float(region.mean()) if region.size else 0.0
        plume_y0 = max(0, bbox[1] - 120)
        plume_y1 = max(0, bbox[1] - 8)
        plume_x0 = max(0, bbox[0] - 18)
        plume_x1 = min(image.width, bbox[2] + 19)
        plume_region = dark_smoke[plume_y0:plume_y1, plume_x0:plume_x1]
        plume_dark_smoke = float(plume_region.mean()) if plume_region.size else 0.0
    top_hot = float(((warm | blue | hot) & (np.indices(luma.shape)[0] < image.height * 0.30)).mean())
    return {
        "path": str(path),
        "meanLuma": float(luma.mean()),
        "maxLuma": float(luma.max()),
        "warmFraction": float(warm.mean()),
        "blueFraction": float(blue.mean()),
        "hotFraction": float(hot.mean()),
        "darkSmokeFraction": float(dark_smoke.mean()),
        "localDarkSmokeFraction": local_dark_smoke,
        "plumeDarkSmokeFraction": plume_dark_smoke,
        "activeHeightFraction": height_fraction,
        "topActiveFraction": top_hot,
        "activeBBox": bbox,
    }


def issues_for(name: str, m: dict) -> list[str]:
    issues: list[str] = []
    if name == "burner":
        if m["activeHeightFraction"] > 0.34:
            issues.append("burner flame is too tall for a stove source")
        if m["topActiveFraction"] > 0.003:
            issues.append("burner has high active pixels in upper plume region")
        if m["blueFraction"] < m["warmFraction"] * 0.15:
            issues.append("burner still reads too orange/warm instead of blue port jets")
    elif name == "campfire":
        if m["darkSmokeFraction"] < 0.18:
            issues.append("campfire smoke is too weak or not dark enough")
        if m["activeHeightFraction"] < 0.22:
            issues.append("campfire flame body is too short or underdeveloped")
    elif name == "room":
        if m["warmFraction"] < 0.015:
            issues.append("room fire has too little warm flame coverage")
        if m["activeHeightFraction"] > 0.70:
            issues.append("room fire/plume still reads as an oversized vertical slab")
    return issues


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    report = {}
    thumbs = []
    for name, path in SCENES.items():
        if not path.exists():
            report[name] = {"missing": str(path), "issues": ["capture missing"]}
            continue
        m = metrics(path)
        m["issues"] = issues_for(name, m)
        report[name] = m
        img = Image.open(path).convert("RGB").resize((480, 270))
        draw = ImageDraw.Draw(img, "RGBA")
        draw.rectangle((0, 0, 480, 34), fill=(0, 0, 0, 190))
        draw.text((12, 10), f"{name}: {len(m['issues'])} issues", fill=(255, 220, 170))
        thumbs.append(img)
    if thumbs:
        sheet = Image.new("RGB", (480 * len(thumbs), 270), (0, 0, 0))
        for i, img in enumerate(thumbs):
            sheet.paste(img, (i * 480, 0))
        sheet.save(OUT / "scene-contact-sheet.png")
    (OUT / "scene-visual-audit.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
