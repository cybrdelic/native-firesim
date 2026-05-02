from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "out" / "visual-audit"
TARGET = ROOT / "assets" / "reference-fire-room.png"
RENDER = ROOT / "out" / "validation-frame.bmp"
APP_RENDER = ROOT / "out" / "validation-app-frame.bmp"


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [
        Path("C:/Windows/Fonts/arialbd.ttf" if bold else "C:/Windows/Fonts/arial.ttf"),
        Path("C:/Windows/Fonts/segoeuib.ttf" if bold else "C:/Windows/Fonts/segoeui.ttf"),
    ]
    for candidate in candidates:
        if candidate.exists():
            return ImageFont.truetype(str(candidate), size)
    return ImageFont.load_default()


FONT_TITLE = font(34, True)
FONT_SUB = font(20)
FONT_SMALL = font(16)
FONT_TINY = font(13)


def cover_16x9(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    image = image.convert("RGB")
    src_w, src_h = image.size
    dst_w, dst_h = size
    src_ratio = src_w / src_h
    dst_ratio = dst_w / dst_h
    if src_ratio > dst_ratio:
        new_w = int(src_h * dst_ratio)
        left = (src_w - new_w) // 2
        image = image.crop((left, 0, left + new_w, src_h))
    else:
        new_h = int(src_w / dst_ratio)
        top = max(0, (src_h - new_h) // 2)
        image = image.crop((0, top, src_w, top + new_h))
    return image.resize(size, Image.Resampling.LANCZOS)


def luma_array(image: Image.Image) -> np.ndarray:
    arr = np.asarray(image.convert("RGB"), dtype=np.float32) / 255.0
    return arr[..., 0] * 0.2126 + arr[..., 1] * 0.7152 + arr[..., 2] * 0.0722


def image_metrics(name: str, image: Image.Image) -> dict[str, float | str | list[int]]:
    arr = np.asarray(image.convert("RGB"), dtype=np.float32) / 255.0
    luma = arr[..., 0] * 0.2126 + arr[..., 1] * 0.7152 + arr[..., 2] * 0.0722
    maxc = arr.max(axis=2)
    minc = arr.min(axis=2)
    sat = np.divide(maxc - minc, maxc, out=np.zeros_like(maxc), where=maxc > 0.0001)
    warm = (arr[..., 0] > arr[..., 1] * 1.05) & (arr[..., 0] > arr[..., 2] * 1.55) & (luma > 0.20)
    hot = warm & (luma > 0.62)
    dark_smoke = (luma < 0.18) & (sat < 0.45)
    dx = np.abs(np.diff(luma, axis=1)).mean()
    dy = np.abs(np.diff(luma, axis=0)).mean()
    entropy_hist, _ = np.histogram(luma, bins=64, range=(0.0, 1.0))
    probability = entropy_hist.astype(np.float64) / max(1, entropy_hist.sum())
    probability = probability[probability > 0]
    entropy = float(-(probability * np.log2(probability)).sum())
    bbox = [0, 0, 0, 0]
    if hot.any():
        yy, xx = np.where(hot)
        bbox = [int(xx.min()), int(yy.min()), int(xx.max()), int(yy.max())]
    return {
        "name": name,
        "size": list(image.size),
        "meanLuma": float(luma.mean()),
        "maxLuma": float(luma.max()),
        "brightFractionLumaGt068": float((luma > 0.68).mean()),
        "warmFireFraction": float(warm.mean()),
        "hotFireFraction": float(hot.mean()),
        "darkNeutralSmokeFraction": float(dark_smoke.mean()),
        "meanSaturation": float(sat.mean()),
        "edgeEnergy": float(dx + dy),
        "lumaEntropy": entropy,
        "hotFireBBox": bbox,
    }


def edge_view(image: Image.Image) -> Image.Image:
    gray = image.convert("L")
    edges = gray.filter(ImageFilter.FIND_EDGES)
    edges = ImageEnhance.Contrast(edges).enhance(2.6)
    return Image.merge("RGB", (edges, edges, edges))


def warm_mask_view(image: Image.Image) -> Image.Image:
    arr = np.asarray(image.convert("RGB"), dtype=np.float32) / 255.0
    luma = arr[..., 0] * 0.2126 + arr[..., 1] * 0.7152 + arr[..., 2] * 0.0722
    warm = (arr[..., 0] > arr[..., 1] * 1.05) & (arr[..., 0] > arr[..., 2] * 1.55) & (luma > 0.20)
    hot = warm & (luma > 0.62)
    out = np.zeros_like(arr)
    out[..., 0] = warm * 0.75 + hot * 0.25
    out[..., 1] = hot * 0.72
    out[..., 2] = 0.02
    return Image.fromarray(np.uint8(np.clip(out, 0, 1) * 255), "RGB")


def smoke_mask_view(image: Image.Image) -> Image.Image:
    arr = np.asarray(image.convert("RGB"), dtype=np.float32) / 255.0
    luma = arr[..., 0] * 0.2126 + arr[..., 1] * 0.7152 + arr[..., 2] * 0.0722
    maxc = arr.max(axis=2)
    minc = arr.min(axis=2)
    sat = np.divide(maxc - minc, maxc, out=np.zeros_like(maxc), where=maxc > 0.0001)
    smoke = ((luma < 0.34) & (sat < 0.52)) | ((arr[..., 0] > arr[..., 1] * 0.92) & (arr[..., 1] > arr[..., 2] * 0.90) & (luma < 0.52))
    out = np.zeros_like(arr)
    out[..., 0] = smoke * 0.42
    out[..., 1] = smoke * 0.42
    out[..., 2] = smoke * 0.42
    return Image.fromarray(np.uint8(np.clip(out, 0, 1) * 255), "RGB")


def draw_label(draw: ImageDraw.ImageDraw, xy: tuple[int, int], title: str, body: str = "") -> None:
    x, y = xy
    pad = 12
    lines = [title] + ([body] if body else [])
    widths = [draw.textbbox((0, 0), line, font=FONT_SUB if i == 0 else FONT_SMALL)[2] for i, line in enumerate(lines)]
    box_w = max(widths) + pad * 2
    box_h = 38 + (24 if body else 0)
    draw.rounded_rectangle((x, y, x + box_w, y + box_h), radius=6, fill=(0, 0, 0, 190), outline=(255, 122, 36, 210))
    draw.text((x + pad, y + 8), title, font=FONT_SUB, fill=(255, 214, 160))
    if body:
        draw.text((x + pad, y + 34), body, font=FONT_SMALL, fill=(230, 230, 220))


def text_frame(title: str, bullets: list[str]) -> Image.Image:
    frame = Image.new("RGB", (1280, 720), (10, 10, 9))
    draw = ImageDraw.Draw(frame, "RGBA")
    draw.text((50, 44), title, font=FONT_TITLE, fill=(255, 226, 190))
    y = 118
    for bullet in bullets:
        draw.text((74, y), "- " + bullet, font=FONT_SUB, fill=(226, 224, 214))
        y += 42
    return frame


def two_panel(title: str, left: Image.Image, right: Image.Image, left_label: str, right_label: str, notes: list[str]) -> Image.Image:
    frame = Image.new("RGB", (1280, 720), (11, 11, 10))
    draw = ImageDraw.Draw(frame, "RGBA")
    draw.text((40, 28), title, font=FONT_TITLE, fill=(255, 226, 190))
    panel_w, panel_h = 575, 324
    left_img = cover_16x9(left, (panel_w, panel_h))
    right_img = cover_16x9(right, (panel_w, panel_h))
    frame.paste(left_img, (40, 96))
    frame.paste(right_img, (665, 96))
    draw.rectangle((40, 96, 40 + panel_w, 96 + panel_h), outline=(255, 255, 255, 90), width=1)
    draw.rectangle((665, 96, 665 + panel_w, 96 + panel_h), outline=(255, 255, 255, 90), width=1)
    draw_label(draw, (56, 112), left_label)
    draw_label(draw, (681, 112), right_label)
    y = 455
    for note in notes[:5]:
        draw.text((70, y), "- " + note, font=FONT_SUB, fill=(230, 228, 216))
        y += 38
    return frame


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    target = cover_16x9(Image.open(TARGET), (960, 540))
    render = Image.open(RENDER).convert("RGB")
    app_render = Image.open(APP_RENDER).convert("RGB") if APP_RENDER.exists() else render

    target.save(OUT / "target-16x9.png")
    render.save(OUT / "current-render.png")
    app_render.save(OUT / "current-app-render.png")
    edge_target = edge_view(target)
    edge_render = edge_view(render)
    warm_target = warm_mask_view(target)
    warm_render = warm_mask_view(render)
    smoke_target = smoke_mask_view(target)
    smoke_render = smoke_mask_view(render)
    edge_target.save(OUT / "target-edge-map.png")
    edge_render.save(OUT / "current-edge-map.png")
    warm_target.save(OUT / "target-warm-mask.png")
    warm_render.save(OUT / "current-warm-mask.png")
    smoke_target.save(OUT / "target-smoke-mask.png")
    smoke_render.save(OUT / "current-smoke-mask.png")

    metrics = {
        "target": image_metrics("target", target),
        "currentRender": image_metrics("currentRender", render),
        "appRender": image_metrics("appRender", app_render),
        "inputs": {
            "target": str(TARGET),
            "render": str(RENDER),
            "appRender": str(APP_RENDER),
        },
    }
    (OUT / "visual-metrics.json").write_text(json.dumps(metrics, indent=2), encoding="utf-8")

    frames = [
        two_panel(
            "Visual Gap Audit: target vs current render",
            target,
            render,
            "TARGET",
            "CURRENT",
            [
                "Target has separated flame tongues; current render has a tan plume slab.",
                "Target has black rolling smoke; current render is uniformly amber.",
                "Target has ember bed, tray edge, and reflected fire; current floor response is flat.",
            ],
        ),
        two_panel(
            "Fire mask: hot structure and tongues",
            warm_target,
            warm_render,
            "TARGET WARM/HOT",
            "CURRENT WARM/HOT",
            [
                "Hot pixels should form thin branching sheets.",
                "Current hot mask is mostly base glow and sparse streaks.",
                "The flame body lacks inner voids, pinching, and turbulent roll-up.",
            ],
        ),
        two_panel(
            "Smoke mask: mass and breakup",
            smoke_target,
            smoke_render,
            "TARGET SMOKE",
            "CURRENT SMOKE",
            [
                "Target smoke has billows, lobes, entrainment, and dark core regions.",
                "Current smoke reads as a smooth translucent column.",
                "Soot rendering is chromatically warm instead of black/gray particulate.",
            ],
        ),
        two_panel(
            "Edge map: high-frequency visual evidence",
            edge_target,
            edge_render,
            "TARGET EDGES",
            "CURRENT EDGES",
            [
                "Target edges are dense around flame fronts and smoke curls.",
                "Current edges cluster into bands and soft silhouettes.",
                "The renderer adds procedural detail but not physical flame-front detail.",
            ],
        ),
        text_frame(
            "Top architectural causes",
            [
                "Combustion now has char, ash, pyrolysis, and progress fields, but constants are not calibrated.",
                "Turbulence now has a transported LES-style scalar, but the pressure solve is still fixed SOR.",
                "Soot optics and shadowing exist, but not a particle size distribution or measured optical table.",
                "Radiation still lacks coupled heat transfer back to fuel bed, walls, and room materials.",
                "Visual proof still uses existing frames because live CUDA kernels are gated after bugchecks.",
            ],
        ),
        text_frame(
            "Systems added and remaining",
            [
                "Added GPU char/ash/pyrolysis, progress variable, and turbulence-energy fields.",
                "Added clamped MacCormack/BFECC scalar transport and soot optical-depth coupling.",
                "Added volume self-shadowing, emitter scattering, and calibration sidecar ingestion.",
                "Still missing real burn calibration data, particle-distribution soot, and radiation coupling.",
                "Still need residual-target pressure solve and sparse volume scheduling before larger grids.",
            ],
        ),
    ]

    frame_paths = []
    for i, frame in enumerate(frames):
        path = OUT / f"gif-frame-{i:02d}.png"
        frame.save(path)
        frame_paths.append(path)

    frames[0].save(
        OUT / "fire-visual-gap-audit.gif",
        save_all=True,
        append_images=frames[1:],
        duration=[2800, 2500, 2500, 2500, 3100, 3100],
        loop=0,
        optimize=True,
    )

    contact = Image.new("RGB", (1280, 1440), (10, 10, 9))
    for i, frame in enumerate(frames):
        thumb = frame.resize((640, 360), Image.Resampling.LANCZOS)
        x = 0 if i % 2 == 0 else 640
        y = (i // 2) * 360
        contact.paste(thumb, (x, y))
    contact.save(OUT / "visual-audit-contact-sheet.png")

    manifest = {
        "generated": [str(p) for p in frame_paths]
        + [
            str(OUT / "fire-visual-gap-audit.gif"),
            str(OUT / "fire-visual-gap-audit.mp4"),
            str(OUT / "visual-audit-contact-sheet.png"),
            str(OUT / "visual-metrics.json"),
        ],
        "sourceFrames": [str(TARGET), str(RENDER), str(APP_RENDER)],
        "note": "Generated from existing render artifacts only; no live CUDA kernels were launched.",
    }
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
