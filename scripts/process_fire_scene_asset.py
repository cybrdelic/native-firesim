#!/usr/bin/env python3
"""Normalize a fire-source mesh and emit FireSim sidecars.

This script intentionally keeps downloaded third-party archives outside git.
It consumes a local Sketchfab archive/folder/model file, exports a clean GLB,
and writes attribution, geometry, emitter, and coarse SDF outputs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

import numpy as np
from scipy.spatial import cKDTree
import trimesh


MODEL_EXTENSIONS = (".gltf", ".glb", ".obj")


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=False) + "\n", encoding="utf-8", newline="\n")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_by_id(manifest: dict, asset_id: str) -> dict:
    for source in manifest.get("sources", []):
        if source.get("id") == asset_id:
            return source
    raise SystemExit(f"Unknown asset id '{asset_id}' in {manifest}")


def unpack_input(input_path: Path, work_dir: Path) -> Path:
    if input_path.is_dir():
        return input_path
    if input_path.suffix.lower() == ".zip":
        with zipfile.ZipFile(input_path, "r") as archive:
            archive.extractall(work_dir)
        return work_dir
    return input_path.parent


def find_model(root: Path) -> Path:
    if root.is_file() and root.suffix.lower() in MODEL_EXTENSIONS:
        return root

    candidates = [p for p in root.rglob("*") if p.is_file() and p.suffix.lower() in MODEL_EXTENSIONS]
    if not candidates:
        raise SystemExit(f"No supported model file found under {root}")

    def score(path: Path) -> tuple[int, int, str]:
        name = path.name.lower()
        ext_score = {".gltf": 0, ".glb": 1, ".obj": 2}.get(path.suffix.lower(), 9)
        name_score = 0 if name in {"scene.gltf", "scene.glb", "model.gltf", "model.glb"} else 1
        return (ext_score, name_score, str(path).lower())

    return sorted(candidates, key=score)[0]


def mesh_base_color(mesh: trimesh.Trimesh) -> np.ndarray:
    material = getattr(mesh.visual, "material", None)
    color = getattr(material, "baseColorFactor", None)
    if color is None:
        return np.array([0.55, 0.55, 0.55, 1.0], dtype=np.float32)
    color = np.array(color, dtype=np.float32).reshape(-1)
    if color.size < 3:
        return np.array([0.55, 0.55, 0.55, 1.0], dtype=np.float32)
    if color.max(initial=1.0) > 1.0:
        color = color / 255.0
    if color.size == 3:
        color = np.concatenate([color, np.array([1.0], dtype=np.float32)])
    return color[:4].astype(np.float32)


def convert_up_axis(mesh: trimesh.Trimesh, source: dict) -> trimesh.Trimesh:
    if source.get("upAxis", "y").lower() != "z":
        return mesh
    converted = mesh.copy()
    vertices = converted.vertices.copy()
    converted.vertices = np.column_stack((vertices[:, 0], vertices[:, 2], -vertices[:, 1]))
    converted.remove_unreferenced_vertices()
    return converted


def load_as_mesh(model_path: Path, source: dict) -> tuple[trimesh.Trimesh, dict]:
    loaded = trimesh.load(model_path, force="scene", process=False)
    excluded_materials = {str(v).lower() for v in source.get("excludeMaterialNames", [])}
    if isinstance(loaded, trimesh.Scene):
        pieces = []
        colors = []
        for name, geom in loaded.geometry.items():
            material_name = str(getattr(getattr(geom.visual, "material", None), "name", "")).lower()
            if material_name in excluded_materials:
                continue
            part = convert_up_axis(geom.copy(), source)
            color = mesh_base_color(geom)
            pieces.append(part)
            colors.append(np.repeat(color.reshape(1, 4), len(part.vertices), axis=0))
        if not pieces:
            raise SystemExit(f"Scene had no mesh geometry: {model_path}")
        mesh = trimesh.util.concatenate(pieces)
        mesh.visual.vertex_colors = np.vstack(colors)
        scene_stats = {
            "nodeCount": len(loaded.graph.nodes_geometry),
            "geometryCount": len(loaded.geometry),
            "runtimeGeometryCount": len(pieces),
        }
    elif isinstance(loaded, trimesh.Trimesh):
        mesh = convert_up_axis(loaded, source)
        mesh.visual.vertex_colors = np.repeat(mesh_base_color(loaded).reshape(1, 4), len(mesh.vertices), axis=0)
        scene_stats = {"nodeCount": 1, "geometryCount": 1, "runtimeGeometryCount": 1}
    else:
        raise SystemExit(f"Unsupported loaded asset type: {type(loaded).__name__}")

    mesh.remove_unreferenced_vertices()
    if mesh.faces is None or len(mesh.faces) == 0:
        raise SystemExit(f"Mesh has no faces: {model_path}")
    return mesh, scene_stats


def normalize_mesh(mesh: trimesh.Trimesh, scale: float) -> trimesh.Trimesh:
    normalized = mesh.copy()
    normalized.apply_scale(float(scale))
    post_scale = getattr(normalize_mesh, "post_scale", None)
    if post_scale is not None:
        normalized.apply_scale(post_scale)
    bounds = normalized.bounds
    center_xz = np.array([(bounds[0, 0] + bounds[1, 0]) * 0.5, bounds[0, 1], (bounds[0, 2] + bounds[1, 2]) * 0.5])
    normalized.apply_translation(-center_xz)
    normalized.remove_unreferenced_vertices()
    return normalized


def crop_mesh_height(mesh: trimesh.Trimesh, source: dict) -> trimesh.Trimesh:
    crop = source.get("runtimeCrop", {})
    if not crop:
        return mesh
    bounds = mesh.bounds
    height = max(float(bounds[1, 1] - bounds[0, 1]), 1e-6)
    centers_y = mesh.triangles_center[:, 1]
    keep = np.ones(len(mesh.faces), dtype=bool)
    if "maxHeightFraction" in crop:
        max_y = bounds[0, 1] + height * float(crop["maxHeightFraction"])
        keep &= centers_y <= max_y
    if "minHeightFraction" in crop:
        min_y = bounds[0, 1] + height * float(crop["minHeightFraction"])
        keep &= centers_y >= min_y
    if np.count_nonzero(keep) == 0:
        raise SystemExit(f"Runtime crop removed all faces for {source.get('id', source.get('title', 'asset'))}")
    cropped = mesh.copy()
    cropped.update_faces(keep)
    cropped.remove_unreferenced_vertices()
    return cropped


def derive_burner_centers(mesh: trimesh.Trimesh) -> np.ndarray:
    bounds = mesh.bounds.astype(np.float32)
    extents = np.maximum(bounds[1] - bounds[0], 1e-6)
    vertices = mesh.vertices.astype(np.float32)
    y_norm = (vertices[:, 1] - bounds[0, 1]) / extents[1]
    edge_margin_x = extents[0] * 0.12
    edge_margin_z = extents[2] * 0.12
    candidates = vertices[
        (y_norm > 0.45)
        & (vertices[:, 0] > bounds[0, 0] + edge_margin_x)
        & (vertices[:, 0] < bounds[1, 0] - edge_margin_x)
        & (vertices[:, 2] > bounds[0, 2] + edge_margin_z)
        & (vertices[:, 2] < bounds[1, 2] - edge_margin_z)
        & (np.abs(vertices[:, 0]) > extents[0] * 0.10)
        & (np.abs(vertices[:, 2]) > extents[2] * 0.10)
    ]
    centers: list[list[float]] = []
    for sx in (-1.0, 1.0):
        for sz in (-1.0, 1.0):
            q = candidates[(candidates[:, 0] * sx > 0.0) & (candidates[:, 2] * sz > 0.0)]
            if len(q) >= 6:
                centers.append([
                    float(np.median(q[:, 0])),
                    float(np.percentile(q[:, 1], 70)),
                    float(np.median(q[:, 2])),
                ])
    return np.asarray(centers, dtype=np.float32)


def emitter_mask(points: np.ndarray, bounds: np.ndarray, distances: np.ndarray, source: dict, burner_centers: np.ndarray) -> np.ndarray:
    hint = source.get("emitterHint", {})
    mode = hint.get("mode", "low-center-bed")
    extents = np.maximum(bounds[1] - bounds[0], 1e-6)
    y_norm = (points[:, 1] - bounds[0, 1]) / extents[1]
    radius = float(hint.get("radiusFraction", 0.35)) * max(extents[0], extents[2])
    height = float(hint.get("heightFraction", 0.30))
    radial = np.sqrt(points[:, 0] ** 2 + points[:, 2] ** 2)
    near_surface = distances <= (max(extents) / 18.0)

    if mode == "burner-ring":
        centers = burner_centers if len(burner_centers) > 0 else np.zeros((1, 3), dtype=np.float32)
        ring_radius = radius * 0.45 if len(burner_centers) > 0 else radius
        inner = ring_radius * 0.58
        outer = ring_radius * 1.12
        if "worldHeightMeters" in hint:
            center_y = float(hint["worldHeightMeters"])
            band = float(hint.get("heightBandMeters", max(extents[1] * 0.20, 0.04)))
            height_mask = np.abs(points[:, 1] - center_y) <= band * 0.5
        else:
            height_mask = y_norm <= height
        distances_to_centers = np.full(len(points), np.inf, dtype=np.float32)
        for center in centers:
            center_radial = np.sqrt((points[:, 0] - center[0]) ** 2 + (points[:, 2] - center[2]) ** 2)
            distances_to_centers = np.minimum(distances_to_centers, center_radial)
        return height_mask & (distances_to_centers >= inner) & (distances_to_centers <= outer)

    return (y_norm <= height) & (radial <= radius) & near_surface


def build_sdf_and_emitter(mesh: trimesh.Trimesh, source: dict, resolution: int) -> tuple[dict, np.ndarray, np.ndarray]:
    bounds = mesh.bounds.astype(np.float32)
    extents = np.maximum(bounds[1] - bounds[0], 1e-6)
    pad = max(float(np.max(extents)) * 0.04, 0.01)
    bounds = np.array([bounds[0] - pad, bounds[1] + pad], dtype=np.float32)

    axes = [np.linspace(bounds[0, i], bounds[1, i], resolution, dtype=np.float32) for i in range(3)]
    grid = np.stack(np.meshgrid(axes[0], axes[1], axes[2], indexing="ij"), axis=-1).reshape(-1, 3)

    sample_count = min(60000, max(4096, len(mesh.faces) * 6))
    surface_points, _ = trimesh.sample.sample_surface(mesh, sample_count)
    tree = cKDTree(surface_points)
    distances, _ = tree.query(grid, workers=-1)
    distances = distances.astype(np.float32)

    sign_mode = "unsigned"
    signed_distance = distances.copy()
    if mesh.is_watertight:
        try:
            inside = mesh.contains(grid)
            signed_distance[inside] *= -1.0
            sign_mode = "signed"
        except Exception:
            sign_mode = "unsigned"

    all_burner_centers = derive_burner_centers(mesh) if source.get("emitterHint", {}).get("mode") == "burner-ring" else np.zeros((0, 3), dtype=np.float32)
    hint = source.get("emitterHint", {})
    selected_burner_index = int(hint.get("selectedBurnerIndex", -1))
    if len(all_burner_centers) > 0 and 0 <= selected_burner_index < len(all_burner_centers):
        active_burner_centers = all_burner_centers[selected_burner_index:selected_burner_index + 1]
    else:
        active_burner_centers = all_burner_centers
        selected_burner_index = -1
    emitter = emitter_mask(grid, bounds, distances, source, active_burner_centers)
    active_points = grid[emitter]
    if len(active_points) > 0:
        center = active_points.mean(axis=0)
        if len(active_burner_centers) > 0:
            nearest = np.full(len(active_points), np.inf, dtype=np.float32)
            for burner_center in active_burner_centers:
                d = np.sqrt((active_points[:, 0] - burner_center[0]) ** 2 + (active_points[:, 2] - burner_center[2]) ** 2)
                nearest = np.minimum(nearest, d)
            radial = nearest
        else:
            radial = np.sqrt((active_points[:, 0] - center[0]) ** 2 + (active_points[:, 2] - center[2]) ** 2)
        derived = {
            "centerXMeters": float(center[0]),
            "centerYMeters": float(center[1]),
            "centerZMeters": float(center[2]),
            "radiusMeters": float(np.percentile(radial, 85)) if len(radial) > 1 else 0.05,
            "heightBandMeters": float(max(active_points[:, 1].max() - active_points[:, 1].min(), max(extents[1] / resolution, 0.02))),
        }
    else:
        derived = {
            "centerXMeters": 0.0,
            "centerYMeters": float(source.get("emitterHint", {}).get("worldHeightMeters", bounds[0, 1])),
            "centerZMeters": 0.0,
            "radiusMeters": float(source.get("emitterHint", {}).get("radiusFraction", 0.35)) * max(extents[0], extents[2]),
            "heightBandMeters": float(source.get("emitterHint", {}).get("heightBandMeters", max(extents[1] / 8.0, 0.04))),
        }
    payload = {
        "schemaVersion": 1,
        "coordinateSystem": "meters, +Y up, centered X/Z, minY grounded",
        "gridResolution": [resolution, resolution, resolution],
        "boundsMinMeters": bounds[0].round(6).tolist(),
        "boundsMaxMeters": bounds[1].round(6).tolist(),
        "sdfSignMode": sign_mode,
        "activeEmitterVoxels": int(np.count_nonzero(emitter)),
        "emitterMode": source.get("emitterHint", {}).get("mode", "low-center-bed"),
        "emitterHint": source.get("emitterHint", {}),
        "burnerCentersMeters": active_burner_centers.round(6).tolist(),
        "allBurnerCentersMeters": all_burner_centers.round(6).tolist(),
        "selectedBurnerIndex": selected_burner_index,
        "derivedEmitter": derived,
        "sdfGrid": "sdf-grid.npz",
    }
    return payload, signed_distance.reshape((resolution, resolution, resolution)), emitter.reshape((resolution, resolution, resolution))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-manifest", required=True)
    parser.add_argument("--asset-id", required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output-root", required=True)
    parser.add_argument("--grid-resolution", type=int, default=32)
    args = parser.parse_args()

    manifest_path = Path(args.source_manifest).resolve()
    source_manifest = read_json(manifest_path)
    source = source_by_id(source_manifest, args.asset_id)
    input_path = Path(args.input).resolve()
    if not input_path.exists():
        raise SystemExit(f"Missing input asset archive/folder/model: {input_path}")

    output_dir = Path(args.output_root).resolve() / args.asset_id
    output_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix=f"firesim-{args.asset_id}-") as temp_name:
        root = unpack_input(input_path, Path(temp_name))
        model_path = find_model(root if input_path.suffix.lower() == ".zip" else input_path)
        mesh, scene_stats = load_as_mesh(model_path, source)
        mesh = crop_mesh_height(mesh, source)
        normalize_mesh.post_scale = np.array(source.get("postNormalizeScale", [1.0, 1.0, 1.0]), dtype=np.float64)
        mesh = normalize_mesh(mesh, float(source.get("importScaleMeters", 1.0)))
        normalize_mesh.post_scale = None

        scene_path = output_dir / "scene.glb"
        mesh.export(scene_path)

        emitter_payload, sdf, emitter = build_sdf_and_emitter(mesh, source, max(12, min(80, args.grid_resolution)))
        np.savez_compressed(
            output_dir / "sdf-grid.npz",
            signed_distance_m=sdf.astype(np.float32),
            emitter_mask=emitter.astype(np.uint8),
            bounds_min_m=np.array(emitter_payload["boundsMinMeters"], dtype=np.float32),
            bounds_max_m=np.array(emitter_payload["boundsMaxMeters"], dtype=np.float32),
        )
        write_json(output_dir / "emitter-mask.json", emitter_payload)

        bounds = mesh.bounds
        extents = bounds[1] - bounds[0]
        mesh_stats = {
            "vertices": int(len(mesh.vertices)),
            "faces": int(len(mesh.faces)),
            "boundsMinMeters": bounds[0].round(6).tolist(),
            "boundsMaxMeters": bounds[1].round(6).tolist(),
            "extentsMeters": extents.round(6).tolist(),
            "watertight": bool(mesh.is_watertight),
            **scene_stats,
        }
        normals = mesh.vertex_normals if mesh.vertex_normals is not None and len(mesh.vertex_normals) == len(mesh.vertices) else np.zeros_like(mesh.vertices)
        colors = getattr(mesh.visual, "vertex_colors", None)
        if colors is None or len(colors) != len(mesh.vertices):
            base = np.array(source.get("runtimeBaseColor", [0.55, 0.55, 0.55]), dtype=np.float32)
            colors = np.repeat(base.reshape(1, 3), len(mesh.vertices), axis=0)
        colors = colors[:, :3].astype(np.float32)
        if colors.max(initial=1.0) > 1.0:
            colors = colors / 255.0
        runtime_mesh = {
            "schemaVersion": 1,
            "assetId": args.asset_id,
            "coordinateSystem": "meters, +Y up, centered X/Z, minY grounded",
            "boundsMinMeters": bounds[0].round(6).tolist(),
            "boundsMaxMeters": bounds[1].round(6).tolist(),
            "vertices": mesh.vertices.astype(np.float32).round(6).tolist(),
            "normals": normals.astype(np.float32).round(6).tolist(),
            "colors": colors.round(6).tolist(),
            "triangles": mesh.faces.astype(np.uint32).tolist(),
            "material": {
                "sourceType": source.get("fireSourceType", ""),
                "fuelMaterial": source.get("fuelMaterial", ""),
            },
        }
        write_json(output_dir / "runtime-mesh.json", runtime_mesh)

        geometry = {
            "schemaVersion": 1,
            "units": "meters",
            "room": {
                "width": 3.0,
                "height": 2.4,
                "depth": 3.0,
                "ventilation": {"type": "open-front lab viewport"}
            },
            "fuelBed": {
                "material": source.get("fuelMaterial", ""),
                "initialMassKg": 1.0 if source.get("fireSourceType") == "solid-fuel-bed" else 0.0,
                "width": float(extents[0]),
                "depth": float(extents[2]),
                "height": float(extents[1]),
                "geometryMesh": "scene.glb",
                "runtimeMesh": "runtime-mesh.json",
                "emitterMask": "emitter-mask.json",
                "sdfGrid": "sdf-grid.npz",
                "sourceType": source.get("fireSourceType", "")
            },
            "sensors": {
                "thermocouples": [],
                "cameras": [{"id": "authoring-camera", "type": "RGB", "position": [0.0, 1.1, 2.6], "target": [0.0, 0.45, 0.0]}]
            },
            "source": {
                "title": source.get("title", ""),
                "url": source.get("url", ""),
                "author": source.get("author", ""),
                "license": source.get("license", ""),
                "licenseUrl": source.get("licenseUrl", "")
            }
        }
        write_json(output_dir / "geometry.json", geometry)

        generated = {
            "sceneGlbSha256": sha256_file(scene_path),
            "runtimeMeshSha256": sha256_file(output_dir / "runtime-mesh.json"),
            "sdfGridSha256": sha256_file(output_dir / "sdf-grid.npz"),
            "geometrySha256": sha256_file(output_dir / "geometry.json"),
            "emitterMaskSha256": sha256_file(output_dir / "emitter-mask.json"),
        }
        asset_manifest = {
            "schemaVersion": 1,
            "assetId": args.asset_id,
            "source": source,
            "input": {
                "path": str(input_path),
                "sha256": sha256_file(input_path) if input_path.is_file() else "",
                "modelFile": str(model_path),
            },
            "outputs": {
                "sceneGlb": "scene.glb",
                "runtimeMesh": "runtime-mesh.json",
                "geometry": "geometry.json",
                "emitterMask": "emitter-mask.json",
                "sdfGrid": "sdf-grid.npz",
            },
            "generated": generated,
            "mesh": mesh_stats,
            "attribution": f"{source.get('title')} by {source.get('author')} ({source.get('url')}), licensed {source.get('license')} ({source.get('licenseUrl')})."
        }
        write_json(output_dir / "asset-manifest.json", asset_manifest)
        (output_dir / "ATTRIBUTION.txt").write_text(asset_manifest["attribution"] + "\n", encoding="utf-8", newline="\n")
        overlay_script = Path(__file__).resolve().parent / "render_emitter_debug_overlay.py"
        if overlay_script.exists():
            subprocess.run(
                [sys.executable, str(overlay_script), "--scene-dir", str(output_dir)],
                check=True,
            )

    print(f"imported {args.asset_id} -> {output_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
