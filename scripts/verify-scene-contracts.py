from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCENES = ROOT / "assets" / "fire-scenes"
SCENE_DIRS = ["methanol-pool"]
EMITTER_POLICIES = {"authored", "mask-derived", "authored-with-mask-debug"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def number_triplet(value: object, name: str) -> None:
    require(isinstance(value, list) and len(value) == 3, f"{name} must be a 3-number array")
    for item in value:
        require(isinstance(item, (int, float)), f"{name} must contain only numbers")


def main() -> None:
    schema = json.loads((SCENES / "scene.schema.json").read_text(encoding="utf-8"))
    required = schema["required"]
    for scene_dir in SCENE_DIRS:
        path = SCENES / scene_dir / "scene.json"
        require(path.exists(), f"missing scene contract: {path}")
        scene = json.loads(path.read_text(encoding="utf-8"))
        for key in required:
            require(key in scene, f"{scene_dir} missing required key {key}")
        require(scene["schemaVersion"] == schema["schemaVersion"], f"{scene_dir} schemaVersion mismatch")

        require("mesh" not in scene, f"{scene_dir} must not declare imported mesh payloads")
        require("meshTransform" not in scene, f"{scene_dir} must not declare imported mesh transforms")

        emitter = scene["emitter"]
        number_triplet(emitter["centerMeters"], f"{scene_dir}.emitter.centerMeters")
        require(emitter["emitterSourcePolicy"] in EMITTER_POLICIES, f"{scene_dir} emitterSourcePolicy is invalid")
        require(emitter["radiusMeters"] > 0.0, f"{scene_dir} emitter radius must be positive")
        require(emitter["heightBandMeters"] > 0.0, f"{scene_dir} emitter height band must be positive")
        if emitter.get("sourceFile"):
            require((path.parent / emitter["sourceFile"]).exists(), f"{scene_dir} missing emitter source file")
        if emitter["emitterSourcePolicy"] == "mask-derived":
            require(emitter.get("sourceFile"), f"{scene_dir} mask-derived emitters must name sourceFile")

        bounds = scene["volumeBounds"]
        number_triplet(bounds["minMeters"], f"{scene_dir}.volumeBounds.minMeters")
        number_triplet(bounds["maxMeters"], f"{scene_dir}.volumeBounds.maxMeters")
        require(bounds["maxMeters"][1] > bounds["minMeters"][1], f"{scene_dir} volume height is invalid")

        require(scene["lighting"]["temperatureKelvin"] > 1000, f"{scene_dir} lighting temperature is not fire-like")
        require(scene["material"]["fuelClass"], f"{scene_dir} material fuelClass is empty")
        require(scene["expectedBehavior"]["mustAvoidBlackFrame"] is True, f"{scene_dir} must guard black frames")
    print("scene contract check: methanol product manifest is present and valid")


if __name__ == "__main__":
    main()
