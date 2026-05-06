from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCENES = ROOT / "assets" / "fire-scenes"
SCENE_DIRS = ["room", "campfire", "gas-burner-aver1"]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def number_triplet(value: object, name: str) -> None:
    require(isinstance(value, list) and len(value) == 3, f"{name} must be a 3-number array")
    for item in value:
        require(isinstance(item, (int, float)), f"{name} must contain only numbers")


def main() -> None:
    schema = json.loads((SCENES / "scene.schema.json").read_text(encoding="utf-8"))
    baselines_path = SCENES / "visual-baselines.json"
    require(baselines_path.exists(), "missing visual-baselines.json")
    baselines = json.loads(baselines_path.read_text(encoding="utf-8"))
    require(baselines["schemaVersion"] == 1, "visual baseline schemaVersion mismatch")
    required = schema["required"]
    for scene_dir in SCENE_DIRS:
        path = SCENES / scene_dir / "scene.json"
        require(path.exists(), f"missing scene contract: {path}")
        scene = json.loads(path.read_text(encoding="utf-8"))
        for key in required:
            require(key in scene, f"{scene_dir} missing required key {key}")
        require(scene["schemaVersion"] == schema["schemaVersion"], f"{scene_dir} schemaVersion mismatch")

        mesh = scene["mesh"]
        if mesh["runtimeMesh"]:
            require((path.parent / mesh["runtimeMesh"]).exists(), f"{scene_dir} missing runtime mesh payload")
        if mesh["sceneGlb"]:
            require((path.parent / mesh["sceneGlb"]).exists(), f"{scene_dir} missing scene GLB")

        transform = scene["meshTransform"]
        number_triplet(transform["translationMeters"], f"{scene_dir}.meshTransform.translationMeters")
        number_triplet(transform["rotationDegrees"], f"{scene_dir}.meshTransform.rotationDegrees")
        number_triplet(transform["scale"], f"{scene_dir}.meshTransform.scale")

        emitter = scene["emitter"]
        number_triplet(emitter["centerMeters"], f"{scene_dir}.emitter.centerMeters")
        require(emitter["radiusMeters"] > 0.0, f"{scene_dir} emitter radius must be positive")
        require(emitter["heightBandMeters"] > 0.0, f"{scene_dir} emitter height band must be positive")
        if emitter["sourceFile"]:
            require((path.parent / emitter["sourceFile"]).exists(), f"{scene_dir} missing emitter source file")

        bounds = scene["volumeBounds"]
        number_triplet(bounds["minMeters"], f"{scene_dir}.volumeBounds.minMeters")
        number_triplet(bounds["maxMeters"], f"{scene_dir}.volumeBounds.maxMeters")
        require(bounds["maxMeters"][1] > bounds["minMeters"][1], f"{scene_dir} volume height is invalid")

        require(scene["lighting"]["temperatureKelvin"] > 1000, f"{scene_dir} lighting temperature is not fire-like")
        require(scene["material"]["fuelClass"], f"{scene_dir} material fuelClass is empty")
        require(scene["expectedBehavior"]["mustAvoidBlackFrame"] is True, f"{scene_dir} must guard black frames")
        baseline_key = "burner" if scene_dir == "gas-burner-aver1" else scene_dir
        require(baseline_key in baselines["scenes"], f"{scene_dir} missing visual baseline entry")
        require(len(baselines["scenes"][baseline_key]["mustHave"]) >= 3, f"{scene_dir} baseline is under-specified")

    print("scene contract check: scene manifests are present and valid")


if __name__ == "__main__":
    main()
