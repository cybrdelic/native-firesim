#pragma once

#include <array>

#include "fire_cuda.h"

constexpr int kSceneCount = 4;

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
    bool hasSelectedBurner = false;
};

struct SceneValidationEnvelope {
    float minMaxLuma = 0.12f;
    float minMeanLuma = 0.010f;
    float minFlameMassProxy = 0.0f;
    int minBrightPixels = 32;
    float maxFlameHeightMeters = 1.25f;
    float maxSmokeToFlameRatio = 8.0f;
    float maxCharSum = 10000000.0f;
    float maxAshSum = 10000000.0f;
};

struct SceneSourceCoefficients {
    int sourceMode = 0;
    float sourceHeightCeiling = 0.145f;
    float charScale = 1.0f;
    float sootScale = 1.0f;
    float initialFuelBase = 1.08f;
    float initialFuelNoise = 0.26f;
};

struct SceneCombustionCoefficients {
    float gasFeed = 0.0f;
    float pyrolysisGain = 1.0f;
    float fuelGain = 1.0f;
    float heatGain = 1.0f;
    float sootGain = 1.0f;
    float charGrowth = 0.026f;
    float ashScale = 1.0f;
    float bedHeatBase = 6.20f;
    float pyrolysisFuelScale = 3.70f;
    float pyrolysisSootScale = 1.0f;
    float sootYieldScale = 1.0f;
    float curlScale = 1.0f;
    float buoyancyScale = 1.0f;
    float buoyancyCeiling = 0.96f;
    float buoyancyFloor = 0.08f;
};

struct SceneRenderCoefficients {
    float floorGlowR = 0.55f;
    float floorGlowG = 0.11f;
    float floorGlowB = 0.023f;
    float floorTongueR = 0.46f;
    float floorTongueG = 0.070f;
    float floorTongueB = 0.014f;
    float floorGlowScale = 0.48f;
    float floorTongueScale = 0.14f;
    float wallGlowR = 0.15f;
    float wallGlowG = 0.050f;
    float wallGlowB = 0.018f;
    float wallGlowScale = 0.090f;
    float orangeEmissionScale = 3.10f;
    float filamentEmissionScale = 1.10f;
    float warmScatter = 0.30f;
    float smokeScale = 1.0f;
    float sourcePlaneMode = 0.0f;
    float burnerJetScale = 0.0f;
    float campTongueScale = 0.0f;
    float roomTrayScale = 1.0f;
    float convectiveHeightTop = 0.88f;
    float convectiveHeightBottom = 0.030f;
    float flameHeightTop = 0.76f;
    float flameHeightBottom = 0.10f;
    float lowerWhiteHeight = 0.060f;
    float roomCoverageBase = 0.72f;
    float roomCoverageScale = 1.24f;
    float topDissolveTop = 0.88f;
    float topDissolveBottom = 0.42f;
    float campHoleScale = 0.0f;
    float campTongueDensityScale = 0.0f;
    float blueEmissionScale = 0.0f;
    float blueJetEmissionScale = 0.0f;
    float flameColorR = 1.32f;
    float flameColorG = 0.27f;
    float flameColorB = 0.038f;
    float alternateFlameColorR = 1.52f;
    float alternateFlameColorG = 0.24f;
    float alternateFlameColorB = 0.028f;
    float alternateFlameColorScale = 0.0f;
};

struct SceneEmberCoefficients {
    float emberRejectAbove = 1.01f;
    float emberLifeRateBase = 0.20f;
    float emberLifeRateJitter = 0.18f;
    float emberLifeRateAdd = 0.0f;
    float emberSpawnMode = 0.0f;
    float emberStartVBase = 0.045f;
    float emberStartVJitter = 0.0f;
    float emberLift = 0.80f;
    float emberLifeScale = 1.10f;
    float emberDrag = 1.35f;
    float emberRadiusBase = 0.00086f;
    float emberRadiusJitter = 0.00145f;
    float emberTrailCap = 0.005f;
    float emberHotR = 1.0f;
    float emberHotG = 0.42f;
    float emberHotB = 0.090f;
    float emberCoolR = 0.18f;
    float emberCoolG = 0.026f;
    float emberCoolB = 0.008f;
    float emberAlphaScale = 0.82f;
};

struct SceneCudaCoefficients {
    SceneSourceCoefficients source;
    SceneCombustionCoefficients combustion;
    SceneRenderCoefficients render;
    SceneEmberCoefficients ember;
};

struct SceneProfile {
    int sceneId = 0;
    const char* key = "room";
    const char* sourceModel = "tray-fuel-bed";
    const char* fuelPhase = "solid";
    const char* flameEnvelope = "broad turbulent plume";
    bool expectsSelectedBurner = false;
    SceneCudaCoefficients cuda;
    SceneValidationEnvelope validation;
};

struct ScenePlacement {
    Vec3 sourceOffset = {};
};

struct PlacementCoordinateState {
    int target = 0;
    std::array<ScenePlacement, kSceneCount> scenes = {};

    ScenePlacement& scene(int sceneId);
    const ScenePlacement& scene(int sceneId) const;
};

int clampSceneId(int sceneId);
const SceneProfile& sceneProfile(int sceneId);
Vec3 sceneSourceWorld(const SceneEmitterParams& emitter, const ScenePlacement& placement, int sceneId);
SceneInstance makeSceneInstance(int sceneId, long sceneEpoch, const SceneEmitterParams& emitter);
void applySceneEmitterToSettings(FireSettings& settings, const SceneEmitterParams& emitter, long sceneEpoch, const ScenePlacement& placement);
