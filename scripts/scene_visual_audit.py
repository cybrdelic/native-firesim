from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "out" / "scene-visual-audit"
SCENES = {
    "room": {"raw": OUT / "room" / "validation-frame.bmp", "app": OUT / "room" / "validation-app-frame.bmp"},
    "campfire": {"raw": OUT / "campfire" / "validation-frame.bmp", "app": OUT / "campfire" / "validation-app-frame.bmp"},
    "burner": {"raw": OUT / "burner" / "validation-frame.bmp", "app": OUT / "burner" / "validation-app-frame.bmp"},
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
    width_fraction = 0.0
    aspect_ratio = 0.0
    center_x_fraction = 0.0
    center_y_fraction = 0.0
    local_dark_smoke = 0.0
    plume_dark_smoke = 0.0
    if yy.size:
        bbox = [int(xx.min()), int(yy.min()), int(xx.max()), int(yy.max())]
        active_width = xx.max() - xx.min() + 1
        active_height = yy.max() - yy.min() + 1
        height_fraction = float(active_height / image.height)
        width_fraction = float(active_width / image.width)
        aspect_ratio = float(active_width / active_height) if active_height else 0.0
        center_x_fraction = float((xx.min() + xx.max()) * 0.5 / image.width)
        center_y_fraction = float((yy.min() + yy.max()) * 0.5 / image.height)
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
        "activeWidthFraction": width_fraction,
        "activeAspectRatio": aspect_ratio,
        "activeCenter": [center_x_fraction, center_y_fraction],
        "topActiveFraction": top_hot,
        "activeBBox": bbox,
    }

def app_metrics(path: Path) -> dict:
    image = Image.open(path).convert("RGB")
    arr = np.asarray(image, dtype=np.float32) / 255.0
    luma = arr[..., 0] * 0.2126 + arr[..., 1] * 0.7152 + arr[..., 2] * 0.0722
    h, w = luma.shape
    top_bar = luma[12:64, 24 : w - 24]
    left_tools = luma[84 : h - 72, 20:120]
    right_panel = luma[80 : h - 108, w - 230 : w - 24]
    bottom_bar = luma[h - 62 : h - 8, 24 : w - 24]
    center = luma[120 : h - 96, 180 : w - 260]
    vertical_edges = np.abs(np.diff(center, axis=1)) if center.size else np.zeros((1, 1), dtype=np.float32)
    horizontal_edges = np.abs(np.diff(center, axis=0)) if center.size else np.zeros((1, 1), dtype=np.float32)
    warm_smoke = (
        (arr[..., 0] > arr[..., 1] * 1.04)
        & (arr[..., 1] > arr[..., 2] * 1.10)
        & (luma > 0.08)
        & (luma < 0.38)
    )
    return {
        "appPath": str(path),
        "uiTopMean": float(top_bar.mean()) if top_bar.size else 0.0,
        "uiLeftMean": float(left_tools.mean()) if left_tools.size else 0.0,
        "uiRightMean": float(right_panel.mean()) if right_panel.size else 0.0,
        "uiBottomMean": float(bottom_bar.mean()) if bottom_bar.size else 0.0,
        "centerMean": float(center.mean()) if center.size else 0.0,
        "gridArtifactScore": float(max(vertical_edges.mean(), horizontal_edges.mean())),
        "warmSmokeFraction": float(warm_smoke.mean()),
    }


def issues_for(name: str, m: dict) -> list[str]:
    issues: list[str] = []
    if m["maxLuma"] < 0.025:
        issues.append("capture is effectively black")
    if m["meanLuma"] < 0.006:
        issues.append("capture has near-zero scene visibility")
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


def silhouette_issues(report: dict) -> dict[str, list[str]]:
    issues = {name: [] for name in report}
    metrics_by_scene = {name: data for name, data in report.items() if "activeBBox" in data}
    if len(metrics_by_scene) < 3:
        return issues
    room = metrics_by_scene.get("room")
    campfire = metrics_by_scene.get("campfire")
    burner = metrics_by_scene.get("burner")
    if not room or not campfire or not burner:
        return issues

    if room["activeWidthFraction"] <= burner["activeWidthFraction"] * 1.65:
        issues["room"].append("room fire silhouette is not wider than burner source")
    if campfire["activeHeightFraction"] <= room["activeHeightFraction"] * 0.58:
        issues["campfire"].append("campfire silhouette is too similar to low room tray flame")
    if burner["activeHeightFraction"] >= campfire["activeHeightFraction"] * 0.52:
        issues["burner"].append("burner silhouette is too tall compared with campfire")
    if (
        abs(room["activeCenter"][0] - campfire["activeCenter"][0]) < 0.020
        and abs(campfire["activeCenter"][0] - burner["activeCenter"][0]) < 0.020
    ):
        issues["room"].append("scene silhouettes share the same centered plume alignment")
        issues["campfire"].append("scene silhouettes share the same centered plume alignment")
        issues["burner"].append("scene silhouettes share the same centered plume alignment")
    return issues


def app_issues_for(name: str, m: dict) -> list[str]:
    issues: list[str] = []
    if m["uiTopMean"] < 0.010 or m["uiLeftMean"] < 0.010 or m["uiRightMean"] < 0.010 or m["uiBottomMean"] < 0.010:
        issues.append("app frame is missing expected UI chrome")
    if name in {"campfire", "burner"} and m["centerMean"] < 0.010:
        issues.append("app frame center is too dark; GLB or scene content may be missing")
    if m["gridArtifactScore"] > 0.085:
        issues.append("app frame has excessive grid/line artifact score")
    if m["warmSmokeFraction"] > 0.26:
        issues.append("app frame has excessive warm/sepia smoke pixels")
    return issues


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    report = {}
    thumbs = []
    fail = False
    for name, paths in SCENES.items():
        raw_path = paths["raw"]
        app_path = paths["app"]
        if not raw_path.exists():
            report[name] = {"missing": str(raw_path), "issues": ["capture missing"]}
            fail = True
            continue
        m = metrics(raw_path)
        m["issues"] = issues_for(name, m)
        if app_path.exists():
            app = app_metrics(app_path)
            m["app"] = app
            m["issues"].extend(app_issues_for(name, app))
        else:
            m["issues"].append("app-frame capture missing")
            fail = True
        if any("black" in issue or "near-zero" in issue for issue in m["issues"]):
            fail = True
        report[name] = m
        img = Image.open(app_path if app_path.exists() else raw_path).convert("RGB").resize((480, 270))
        draw = ImageDraw.Draw(img, "RGBA")
        draw.rectangle((0, 0, 480, 34), fill=(0, 0, 0, 190))
        draw.text((12, 10), f"{name}: {len(m['issues'])} issues", fill=(255, 220, 170))
        thumbs.append(img)
    for name, scene_issues in silhouette_issues(report).items():
        if scene_issues and name in report:
            report[name].setdefault("issues", []).extend(scene_issues)
    if thumbs:
        sheet = Image.new("RGB", (480 * len(thumbs), 270), (0, 0, 0))
        for i, img in enumerate(thumbs):
            sheet.paste(img, (i * 480, 0))
        sheet.save(OUT / "scene-contact-sheet.png")
    (OUT / "scene-visual-audit.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    if fail:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
