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


def load_as_mesh(model_path: Path) -> tuple[trimesh.Trimesh, dict]:
    loaded = trimesh.load(model_path, force="scene", process=False)
    if isinstance(loaded, trimesh.Scene):
        mesh = loaded.to_geometry() if hasattr(loaded, "to_geometry") else None
        if not isinstance(mesh, trimesh.Trimesh):
            raise SystemExit(f"Scene had no mesh geometry: {model_path}")
        scene_stats = {
            "nodeCount": len(loaded.graph.nodes_geometry),
            "geometryCount": len(loaded.geometry),
        }
    elif isinstance(loaded, trimesh.Trimesh):
        mesh = loaded
        scene_stats = {"nodeCount": 1, "geometryCount": 1}
    else:
        raise SystemExit(f"Unsupported loaded asset type: {type(loaded).__name__}")

    mesh.remove_unreferenced_vertices()
    if mesh.faces is None or len(mesh.faces) == 0:
        raise SystemExit(f"Mesh has no faces: {model_path}")
    return mesh, scene_stats


def normalize_mesh(mesh: trimesh.Trimesh, scale: float) -> trimesh.Trimesh:
    normalized = mesh.copy()
    normalized.apply_scale(float(scale))
    bounds = normalized.bounds
    center_xz = np.array([(bounds[0, 0] + bounds[1, 0]) * 0.5, bounds[0, 1], (bounds[0, 2] + bounds[1, 2]) * 0.5])
    normalized.apply_translation(-center_xz)
    normalized.remove_unreferenced_vertices()
    return normalized


def emitter_mask(points: np.ndarray, bounds: np.ndarray, distances: np.ndarray, source: dict) -> np.ndarray:
    hint = source.get("emitterHint", {})
    mode = hint.get("mode", "low-center-bed")
    extents = np.maximum(bounds[1] - bounds[0], 1e-6)
    y_norm = (points[:, 1] - bounds[0, 1]) / extents[1]
    radius = float(hint.get("radiusFraction", 0.35)) * max(extents[0], extents[2])
    height = float(hint.get("heightFraction", 0.30))
    radial = np.sqrt(points[:, 0] ** 2 + points[:, 2] ** 2)
    near_surface = distances <= (max(extents) / 18.0)

    if mode == "burner-ring":
        inner = radius * 0.58
        outer = radius * 1.12
        return (y_norm <= height) & (radial >= inner) & (radial <= outer) & near_surface

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

    emitter = emitter_mask(grid, bounds, distances, source)
    payload = {
        "schemaVersion": 1,
        "coordinateSystem": "meters, +Y up, centered X/Z, minY grounded",
        "gridResolution": [resolution, resolution, resolution],
        "boundsMinMeters": bounds[0].round(6).tolist(),
        "boundsMaxMeters": bounds[1].round(6).tolist(),
        "sdfSignMode": sign_mode,
        "activeEmitterVoxels": int(np.count_nonzero(emitter)),
        "emitterMode": source.get("emitterHint", {}).get("mode", "low-center-bed"),
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
        mesh, scene_stats = load_as_mesh(model_path)
        mesh = normalize_mesh(mesh, float(source.get("importScaleMeters", 1.0)))

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
        runtime_mesh = {
            "schemaVersion": 1,
            "assetId": args.asset_id,
            "coordinateSystem": "meters, +Y up, centered X/Z, minY grounded",
            "boundsMinMeters": bounds[0].round(6).tolist(),
            "boundsMaxMeters": bounds[1].round(6).tolist(),
            "vertices": mesh.vertices.astype(np.float32).round(6).tolist(),
            "normals": normals.astype(np.float32).round(6).tolist(),
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

    print(f"imported {args.asset_id} -> {output_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
