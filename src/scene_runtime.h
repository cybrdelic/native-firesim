#pragma once

#include <array>

#include "fire_cuda.h"

constexpr int kSceneCount = 3;

struct Vec3 {
    float x;
    float y;
    float z;
};

struct SceneEmitterParams {
    float centerX = 0.0f;
    float centerZ = 0.0f;
    float heightNorm = 0.0f;
    float heightBandNorm = 0.06f;
    float radius = 0.48f;
    int burnerCenterCount = 0;
    float burnerCenterX[4] = {};
    float burnerCenterY[4] = {};
    float burnerCenterZ[4] = {};
};

struct SceneInstance {
    int sceneId = 0;
    int sceneEpoch = 0;
    SceneEmitterParams emitter;
    float sourceX = 0.0f;
    float sourceY = 0.02f;
    float sourceZ = 0.0f;
    float sourceRadius = 0.48f;
    float sourceHeightBandMeters = 0.12f;
    bool hasImportedMesh = false;
    bool hasSelectedBurner = false;
};

struct ScenePlacement {
    Vec3 sourceOffset = {};
    Vec3 meshOffset = {};
};

struct PlacementCoordinateState {
    int target = 0;
    std::array<ScenePlacement, kSceneCount> scenes = {};

    ScenePlacement& scene(int sceneId);
    const ScenePlacement& scene(int sceneId) const;
};

int clampSceneId(int sceneId);
Vec3 sceneSourceWorld(const SceneEmitterParams& emitter, const ScenePlacement& placement, int sceneId);
Vec3 meshCenterWorld(float minX, float minY, float minZ, float maxX, float maxY, float maxZ, Vec3 meshOffset);
SceneInstance makeSceneInstance(int sceneId, long sceneEpoch, const SceneEmitterParams& emitter, bool hasImportedMesh);
void applySceneEmitterToSettings(FireSettings& settings, const SceneEmitterParams& emitter, long sceneEpoch, const ScenePlacement& placement);
