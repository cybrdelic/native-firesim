#!/usr/bin/env python3
"""Render emitter-mask debug overlays against an imported runtime mesh."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def as_points(values: list) -> np.ndarray:
    if not values:
        return np.zeros((0, 3), dtype=np.float32)
    if isinstance(values[0], list):
        return np.asarray(values, dtype=np.float32)
    return np.asarray(values, dtype=np.float32).reshape((-1, 3))


def emitter_points(npz_path: Path) -> tuple[np.ndarray, dict]:
    data = np.load(npz_path)
    mask = data["emitter_mask"].astype(bool)
    bounds_min = data["bounds_min_m"].astype(np.float32)
    bounds_max = data["bounds_max_m"].astype(np.float32)
    resolution = np.asarray(mask.shape, dtype=np.float32)
    indices = np.argwhere(mask)
    if len(indices) == 0:
        return np.zeros((0, 3), dtype=np.float32), {
            "bounds_min": bounds_min,
            "bounds_max": bounds_max,
        }
    uvw = (indices.astype(np.float32) + 0.5) / resolution
    points = bounds_min + uvw * (bounds_max - bounds_min)
    return points.astype(np.float32), {
        "bounds_min": bounds_min,
        "bounds_max": bounds_max,
    }


def projector(bounds_min: np.ndarray, bounds_max: np.ndarray, rect: tuple[int, int, int, int], axes: tuple[int, int]):
    left, top, right, bottom = rect
    span = np.maximum(bounds_max - bounds_min, 1.0e-6)

    def project(points: np.ndarray) -> np.ndarray:
        if len(points) == 0:
            return np.zeros((0, 2), dtype=np.float32)
        a, b = axes
        x = left + ((points[:, a] - bounds_min[a]) / span[a]) * (right - left)
        y = bottom - ((points[:, b] - bounds_min[b]) / span[b]) * (bottom - top)
        return np.column_stack((x, y)).astype(np.float32)

    return project


def draw_projected_points(draw: ImageDraw.ImageDraw, projected: np.ndarray, color: tuple[int, int, int, int], radius: int) -> None:
    for x, y in projected:
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=color)


def draw_mesh_edges(
    draw: ImageDraw.ImageDraw,
    points: np.ndarray,
    triangles: np.ndarray,
    project,
    color: tuple[int, int, int, int],
) -> None:
    if len(points) == 0 or len(triangles) == 0:
        return
    projected = project(points)
    for tri in triangles:
        p0 = tuple(projected[int(tri[0])])
        p1 = tuple(projected[int(tri[1])])
        p2 = tuple(projected[int(tri[2])])
        draw.line((p0, p1), fill=color, width=1)
        draw.line((p1, p2), fill=color, width=1)
        draw.line((p2, p0), fill=color, width=1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scene-dir", required=True)
    parser.add_argument("--out", default="")
    args = parser.parse_args()

    scene_dir = Path(args.scene_dir).resolve()
    runtime_mesh = read_json(scene_dir / "runtime-mesh.json")
    emitter_meta = read_json(scene_dir / "emitter-mask.json")
    mesh_points = as_points(runtime_mesh.get("vertices", []))
    triangles = np.asarray(runtime_mesh.get("triangles", []), dtype=np.int32)
    emitter, sdf_meta = emitter_points(scene_dir / "sdf-grid.npz")

    mesh_min = np.asarray(runtime_mesh["boundsMinMeters"], dtype=np.float32)
    mesh_max = np.asarray(runtime_mesh["boundsMaxMeters"], dtype=np.float32)
    bounds_min = np.minimum(mesh_min, sdf_meta["bounds_min"])
    bounds_max = np.maximum(mesh_max, sdf_meta["bounds_max"])

    image = Image.new("RGBA", (1400, 820), (8, 9, 10, 255))
    draw = ImageDraw.Draw(image, "RGBA")
    font = ImageFont.load_default()

    top_rect = (70, 95, 660, 685)
    front_rect = (740, 95, 1330, 685)
    for rect, title in [(top_rect, "TOP VIEW: X/Z"), (front_rect, "FRONT VIEW: X/Y")]:
        draw.rectangle(rect, outline=(90, 96, 106, 255), width=2)
        draw.text((rect[0], rect[1] - 26), title, fill=(220, 228, 236, 255), font=font)

    top_project = projector(bounds_min, bounds_max, top_rect, (0, 2))
    front_project = projector(bounds_min, bounds_max, front_rect, (0, 1))

    draw_mesh_edges(draw, mesh_points, triangles, top_project, (80, 120, 170, 80))
    draw_mesh_edges(draw, mesh_points, triangles, front_project, (80, 120, 170, 80))
    draw_projected_points(draw, top_project(mesh_points), (90, 140, 190, 22), 1)
    draw_projected_points(draw, front_project(mesh_points), (90, 140, 190, 22), 1)
    draw_projected_points(draw, top_project(emitter), (255, 90, 28, 220), 4)
    draw_projected_points(draw, front_project(emitter), (255, 90, 28, 220), 4)

    derived = emitter_meta.get("derivedEmitter", {})
    center = np.asarray([[
        float(derived.get("centerXMeters", 0.0)),
        float(derived.get("centerYMeters", 0.0)),
        float(derived.get("centerZMeters", 0.0)),
    ]], dtype=np.float32)
    draw_projected_points(draw, top_project(center), (255, 245, 145, 255), 8)
    draw_projected_points(draw, front_project(center), (255, 245, 145, 255), 8)

    summary = [
        f"scene: {scene_dir.name}",
        f"active emitter voxels: {emitter_meta.get('activeEmitterVoxels', 0)}",
        f"mode: {emitter_meta.get('emitterMode', '')}",
        "derived center m: "
        f"{derived.get('centerXMeters', 0):.3f}, {derived.get('centerYMeters', 0):.3f}, {derived.get('centerZMeters', 0):.3f}",
        f"derived radius m: {derived.get('radiusMeters', 0):.3f}",
        f"derived height band m: {derived.get('heightBandMeters', 0):.3f}",
        "blue = GLB runtime mesh, orange = active emitter voxels, yellow = derived center",
    ]
    y = 710
    for line in summary:
        draw.text((70, y), line, fill=(210, 218, 226, 255), font=font)
        y += 18

    out = Path(args.out).resolve() if args.out else scene_dir / "emitter-debug-overlay.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").save(out)
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
