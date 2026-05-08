#include "scene_runtime.h"

#include <algorithm>

int clampSceneId(int sceneId) {
    return std::max(0, std::min(kSceneCount - 1, sceneId));
}

ScenePlacement& PlacementCoordinateState::scene(int sceneId) {
    return scenes[clampSceneId(sceneId)];
}

const ScenePlacement& PlacementCoordinateState::scene(int sceneId) const {
    return scenes[clampSceneId(sceneId)];
}

Vec3 sceneSourceWorld(const SceneEmitterParams& emitter, const ScenePlacement& placement, int sceneId) {
    Vec3 source = {
        emitter.centerX + placement.sourceOffset.x,
        emitter.heightNorm * 2.03f + 0.02f + placement.sourceOffset.y,
        emitter.centerZ + placement.sourceOffset.z};
    if (clampSceneId(sceneId) == 2 && emitter.burnerCenterCount > 0) {
        source = {
            emitter.burnerCenterX[0] + placement.sourceOffset.x,
            emitter.burnerCenterY[0] + placement.sourceOffset.y,
            emitter.burnerCenterZ[0] + placement.sourceOffset.z};
    }
    return source;
}

Vec3 meshCenterWorld(float minX, float minY, float minZ, float maxX, float maxY, float maxZ, Vec3 meshOffset) {
    return {
        (minX + maxX) * 0.5f + meshOffset.x,
        (minY + maxY) * 0.5f + meshOffset.y,
        (minZ + maxZ) * 0.5f + meshOffset.z};
}

SceneInstance makeSceneInstance(int sceneId, long sceneEpoch, const SceneEmitterParams& emitter, bool hasImportedMesh) {
    SceneInstance instance;
    instance.sceneId = clampSceneId(sceneId);
    instance.sceneEpoch = static_cast<int>(sceneEpoch);
    instance.emitter = emitter;
    instance.sourceX = emitter.centerX;
    instance.sourceY = emitter.heightNorm * 2.03f + 0.02f;
    instance.sourceZ = emitter.centerZ;
    instance.sourceRadius = emitter.radius;
    instance.sourceHeightBandMeters = emitter.heightBandNorm * 2.03f;
    instance.hasImportedMesh = hasImportedMesh;
    instance.hasSelectedBurner = instance.sceneId == 2 && emitter.burnerCenterCount > 0;
    if (instance.hasSelectedBurner) {
        instance.sourceX = emitter.burnerCenterX[0];
        instance.sourceY = emitter.burnerCenterY[0];
        instance.sourceZ = emitter.burnerCenterZ[0];
    }
    return instance;
}

void applySceneEmitterToSettings(FireSettings& settings, const SceneEmitterParams& emitter, long sceneEpoch, const ScenePlacement& placement) {
    settings.sceneEpoch = static_cast<int>(sceneEpoch);
    settings.emitterCenterX = std::max(-1.05f, std::min(1.05f, emitter.centerX + placement.sourceOffset.x));
    settings.emitterCenterZ = std::max(-0.82f, std::min(0.82f, emitter.centerZ + placement.sourceOffset.z));
    const float emitterY = std::max(0.02f, std::min(1.97f, emitter.heightNorm * 2.03f + 0.02f + placement.sourceOffset.y));
    settings.emitterHeightNorm = std::max(0.0f, std::min(0.96f, (emitterY - 0.02f) / 2.03f));
    settings.emitterHeightBandNorm = emitter.heightBandNorm;
    settings.emitterRadius = emitter.radius;
    settings.burnerCenterCount = emitter.burnerCenterCount;
    for (int i = 0; i < 4; ++i) {
        settings.burnerCenterX[i] = emitter.burnerCenterX[i];
        settings.burnerCenterY[i] = emitter.burnerCenterY[i];
        settings.burnerCenterZ[i] = emitter.burnerCenterZ[i];
    }
    for (int i = 0; i < settings.burnerCenterCount && i < 4; ++i) {
        settings.burnerCenterX[i] = std::max(-1.05f, std::min(1.05f, settings.burnerCenterX[i] + placement.sourceOffset.x));
        settings.burnerCenterY[i] = std::max(0.0f, std::min(2.03f, settings.burnerCenterY[i] + placement.sourceOffset.y));
        settings.burnerCenterZ[i] = std::max(-0.82f, std::min(0.82f, settings.burnerCenterZ[i] + placement.sourceOffset.z));
    }
}
