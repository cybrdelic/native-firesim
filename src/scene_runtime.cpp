#include "scene_runtime.h"

#include <algorithm>

namespace {

constexpr SceneValidationEnvelope validationEnvelope(
    float minMaxLuma,
    float minMeanLuma,
    float minFlameMassProxy,
    int minBrightPixels,
    float maxFlameHeightMeters,
    float maxSmokeToFlameRatio,
    float maxCharSum,
    float maxAshSum) {
    SceneValidationEnvelope envelope{};
    envelope.minMaxLuma = minMaxLuma;
    envelope.minMeanLuma = minMeanLuma;
    envelope.minFlameMassProxy = minFlameMassProxy;
    envelope.minBrightPixels = minBrightPixels;
    envelope.maxFlameHeightMeters = maxFlameHeightMeters;
    envelope.maxSmokeToFlameRatio = maxSmokeToFlameRatio;
    envelope.maxCharSum = maxCharSum;
    envelope.maxAshSum = maxAshSum;
    return envelope;
}

constexpr SceneCudaCoefficients campfireCuda() {
    SceneCudaCoefficients c{};
    c.source.sourceMode = 1;
    c.source.sourceHeightCeiling = 0.210f;
    c.source.charScale = 1.18f;
    c.source.sootScale = 0.54f;
    c.source.initialHeatBase = 1.08f;
    c.source.initialHeatNoise = 0.36f;
    c.source.initialFuelBase = 1.18f;
    c.source.initialFuelNoise = 0.34f;
    c.source.initialPyrolysisBase = 0.064f;
    c.source.initialPyrolysisNoise = 0.038f;
    c.source.initialProgress = 0.27f;
    c.source.initialTurbulence = 0.094f;
    c.combustion.pyrolysisGain = 1.42f;
    c.combustion.fuelGain = 1.22f;
    c.combustion.heatGain = 1.34f;
    c.combustion.sootGain = 0.72f;
    c.combustion.charGrowth = 0.050f;
    c.combustion.pyrolysisSootScale = 0.46f;
    c.combustion.sootYieldScale = 0.48f;
    c.combustion.curlScale = 1.26f;
    c.combustion.buoyancyScale = 0.80f;
    c.combustion.buoyancyCeiling = 0.68f;
    c.render.orangeEmissionScale = 8.00f;
    c.render.filamentEmissionScale = 5.00f;
    c.render.warmScatter = 0.08f;
    c.render.smokeScale = 0.24f;
    c.render.campTongueScale = 1.24f;
    c.render.roomTrayScale = 0.0f;
    c.render.convectiveHeightTop = 0.72f;
    c.render.flameHeightTop = 0.64f;
    c.render.roomCoverageBase = 0.86f;
    c.render.roomCoverageScale = 0.0f;
    c.render.topDissolveTop = 0.72f;
    c.render.topDissolveBottom = 0.30f;
    c.render.campHoleScale = 1.34f;
    c.render.campTongueDensityScale = 1.20f;
    c.render.alternateFlameColorScale = 0.66f;
    c.ember.emberRejectAbove = 0.34f;
    c.ember.emberSpawnMode = 1.0f;
    c.ember.emberStartVBase = 0.035f;
    c.ember.emberStartVJitter = 0.055f;
    c.ember.emberLift = 0.86f;
    c.ember.emberLifeScale = 1.24f;
    c.ember.emberTrailCap = 0.016f;
    c.ember.emberAlphaScale = 0.58f;
    return c;
}

constexpr SceneCudaCoefficients burnerCuda() {
    SceneCudaCoefficients c{};
    c.source.sourceMode = 2;
    c.source.sourceHeightCeiling = 0.0f;
    c.source.charScale = 0.0f;
    c.source.sootScale = 0.004f;
    c.source.initialHeatBase = 3.20f;
    c.source.initialFuelBase = 2.40f;
    c.source.initialSoot = 0.00065f;
    c.source.initialAshScale = 0.0f;
    c.source.initialPyrolysisBase = 0.12f;
    c.source.initialProgress = 0.35f;
    c.source.initialTurbulence = 0.050f;
    c.source.initialSootOptics = 0.00050f;
    c.combustion.gasFeed = 1.80f;
    c.combustion.pyrolysisGain = 0.90f;
    c.combustion.fuelGain = 1.05f;
    c.combustion.heatGain = 2.80f;
    c.combustion.sootGain = 0.18f;
    c.combustion.charGrowth = 0.0f;
    c.combustion.ashScale = 0.0f;
    c.combustion.bedHeatBase = 14.20f;
    c.combustion.pyrolysisFuelScale = 1.34f;
    c.combustion.pyrolysisSootScale = 0.010f;
    c.combustion.sootYieldScale = 0.006f;
    c.combustion.curlScale = 0.38f;
    c.combustion.buoyancyScale = 0.42f;
    c.combustion.buoyancyCeiling = 0.24f;
    c.combustion.buoyancyFloor = 0.035f;
    c.render.floorGlowR = 0.035f;
    c.render.floorGlowG = 0.16f;
    c.render.floorGlowB = 0.58f;
    c.render.floorTongueR = 0.020f;
    c.render.floorTongueG = 0.095f;
    c.render.floorTongueB = 0.34f;
    c.render.floorGlowScale = 0.32f;
    c.render.floorTongueScale = 0.055f;
    c.render.wallGlowR = 0.026f;
    c.render.wallGlowG = 0.090f;
    c.render.wallGlowB = 0.28f;
    c.render.wallGlowScale = 0.070f;
    c.render.orangeEmissionScale = 0.06f;
    c.render.filamentEmissionScale = 0.035f;
    c.render.warmScatter = 0.002f;
    c.render.smokeScale = 0.035f;
    c.render.sourcePlaneMode = 1.0f;
    c.render.burnerJetScale = 1.0f;
    c.render.roomTrayScale = 0.0f;
    c.render.convectiveHeightTop = 1.20f;
    c.render.convectiveHeightBottom = -0.08f;
    c.render.flameHeightTop = 1.18f;
    c.render.flameHeightBottom = -0.05f;
    c.render.lowerWhiteHeight = 0.0f;
    c.render.roomCoverageBase = 1.0f;
    c.render.roomCoverageScale = 0.0f;
    c.render.blueEmissionScale = 1.0f;
    c.render.blueJetEmissionScale = 1.45f;
    c.render.flameColorR = 0.020f;
    c.render.flameColorG = 0.18f;
    c.render.flameColorB = 2.40f;
    c.render.alternateFlameColorR = 0.36f;
    c.render.alternateFlameColorG = 0.58f;
    c.render.alternateFlameColorB = 1.95f;
    c.ember.emberRejectAbove = 0.14f;
    c.ember.emberLifeRateAdd = 0.36f;
    c.ember.emberSpawnMode = 2.0f;
    c.ember.emberStartVBase = 0.0f;
    c.ember.emberLift = 0.16f;
    c.ember.emberLifeScale = 0.34f;
    c.ember.emberDrag = 4.8f;
    c.ember.emberRadiusBase = 0.00042f;
    c.ember.emberRadiusJitter = 0.00042f;
    c.ember.emberHotR = 0.36f;
    c.ember.emberHotG = 0.58f;
    c.ember.emberHotB = 1.04f;
    c.ember.emberCoolR = 0.055f;
    c.ember.emberCoolG = 0.10f;
    c.ember.emberCoolB = 0.18f;
    c.ember.emberAlphaScale = 0.055f;
    return c;
}

constexpr SceneCudaCoefficients methanolPoolCuda() {
    SceneCudaCoefficients c{};
    c.source.sourceMode = 0;
    c.source.sourceHeightCeiling = 0.105f;
    c.source.charScale = 0.0f;
    c.source.sootScale = 0.16f;
    c.source.initialHeatBase = 1.34f;
    c.source.initialHeatNoise = 0.11f;
    c.source.initialFuelBase = 1.22f;
    c.source.initialFuelNoise = 0.08f;
    c.source.initialSoot = 0.0022f;
    c.source.initialAshScale = 0.0f;
    c.source.initialPyrolysisBase = 0.050f;
    c.source.initialPyrolysisNoise = 0.012f;
    c.source.initialProgress = 0.20f;
    c.source.initialTurbulence = 0.045f;
    c.source.initialSootOptics = 0.0020f;
    c.combustion.gasFeed = 1.0f;
    c.combustion.pyrolysisGain = 0.82f;
    c.combustion.fuelGain = 1.12f;
    c.combustion.heatGain = 1.28f;
    c.combustion.sootGain = 0.22f;
    c.combustion.charGrowth = 0.0f;
    c.combustion.ashScale = 0.0f;
    c.combustion.bedHeatBase = 7.80f;
    c.combustion.pyrolysisFuelScale = 2.10f;
    c.combustion.pyrolysisSootScale = 0.035f;
    c.combustion.sootYieldScale = 0.030f;
    c.combustion.curlScale = 0.82f;
    c.combustion.buoyancyScale = 0.74f;
    c.combustion.buoyancyCeiling = 0.58f;
    c.render.floorGlowScale = 0.30f;
    c.render.floorTongueScale = 0.050f;
    c.render.wallGlowScale = 0.050f;
    c.render.orangeEmissionScale = 3.80f;
    c.render.filamentEmissionScale = 1.90f;
    c.render.warmScatter = 0.060f;
    c.render.smokeScale = 0.16f;
    c.render.sourcePlaneMode = 2.0f;
    c.render.roomTrayScale = 0.0f;
    c.render.convectiveHeightTop = 0.62f;
    c.render.flameHeightTop = 0.56f;
    c.render.lowerWhiteHeight = 0.045f;
    c.render.roomCoverageBase = 0.84f;
    c.render.roomCoverageScale = 0.0f;
    c.render.topDissolveTop = 0.62f;
    c.render.topDissolveBottom = 0.25f;
    c.render.flameColorR = 1.42f;
    c.render.flameColorG = 0.40f;
    c.render.flameColorB = 0.070f;
    c.render.alternateFlameColorR = 1.65f;
    c.render.alternateFlameColorG = 0.31f;
    c.render.alternateFlameColorB = 0.045f;
    c.render.alternateFlameColorScale = 0.22f;
    c.ember.emberRejectAbove = 0.22f;
    c.ember.emberLifeRateAdd = 0.08f;
    c.ember.emberSpawnMode = 3.0f;
    c.ember.emberStartVBase = 0.012f;
    c.ember.emberStartVJitter = 0.008f;
    c.ember.emberLift = 0.32f;
    c.ember.emberLifeScale = 0.42f;
    c.ember.emberDrag = 3.20f;
    c.ember.emberRadiusBase = 0.00032f;
    c.ember.emberRadiusJitter = 0.00032f;
    c.ember.emberTrailCap = 0.002f;
    c.ember.emberAlphaScale = 0.050f;
    return c;
}

constexpr SceneProfile sceneProfileValue(
    int sceneId,
    const char* key,
    const char* sourceModel,
    const char* fuelPhase,
    const char* flameEnvelope,
    bool expectsImportedMesh,
    bool expectsSelectedBurner,
    SceneCudaCoefficients cuda,
    SceneValidationEnvelope validation) {
    SceneProfile profile{};
    profile.sceneId = sceneId;
    profile.key = key;
    profile.sourceModel = sourceModel;
    profile.fuelPhase = fuelPhase;
    profile.flameEnvelope = flameEnvelope;
    profile.expectsImportedMesh = expectsImportedMesh;
    profile.expectsSelectedBurner = expectsSelectedBurner;
    profile.cuda = cuda;
    profile.validation = validation;
    return profile;
}

constexpr SceneProfile kSceneProfiles[kSceneCount] = {
    sceneProfileValue(0, "room", "tray-fuel-bed", "solid", "wide room tray flame with soot plume", false, false, {}, validationEnvelope(0.12f, 0.010f, 0.0f, 32, 1.25f, 8.0f, 10000000.0f, 10000000.0f)),
    sceneProfileValue(1, "campfire", "log-contact-char-bed", "solid", "irregular separated warm tongues over fuel bed", false, false, campfireCuda(), validationEnvelope(0.12f, 0.010f, 0.0f, 16, 1.25f, 8.0f, 10000000.0f, 10000000.0f)),
    sceneProfileValue(2, "burner", "selected-gas-burner-ring", "gas", "low tight blue-white port jets", false, true, burnerCuda(), validationEnvelope(0.12f, 0.006f, 1.0f, 0, 0.36f, 0.22f, 1.0f, 1.0f)),
    sceneProfileValue(3, "methanol-pool", "nist-1m-liquid-pool", "liquid", "low-soot axisymmetric methanol pool flame", false, false, methanolPoolCuda(), validationEnvelope(0.10f, 0.006f, 1.0f, 0, 1.10f, 24.0f, 1.0f, 1.0f)),
};

float selectedBurnerExitY(const SceneEmitterParams& emitter) {
    return emitter.burnerCenterY[0] + emitter.heightBandNorm * 2.03f * 0.42f;
}

} // namespace

int clampSceneId(int sceneId) {
    return std::max(0, std::min(kSceneCount - 1, sceneId));
}

const SceneProfile& sceneProfile(int sceneId) {
    return kSceneProfiles[clampSceneId(sceneId)];
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
            selectedBurnerExitY(emitter) + placement.sourceOffset.y,
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
        instance.sourceY = selectedBurnerExitY(emitter);
        instance.sourceZ = emitter.burnerCenterZ[0];
    }
    return instance;
}

void applySceneEmitterToSettings(FireSettings& settings, const SceneEmitterParams& emitter, long sceneEpoch, const ScenePlacement& placement) {
    const SceneCudaCoefficients& cuda = sceneProfile(settings.sceneId).cuda;
    const SceneSourceCoefficients& source = cuda.source;
    const SceneCombustionCoefficients& combustion = cuda.combustion;
    const SceneRenderCoefficients& render = cuda.render;
    const SceneEmberCoefficients& ember = cuda.ember;
    settings.sceneEpoch = static_cast<int>(sceneEpoch);
    settings.emitterCenterX = std::max(-1.05f, std::min(1.05f, emitter.centerX + placement.sourceOffset.x));
    settings.emitterCenterZ = std::max(-0.82f, std::min(0.82f, emitter.centerZ + placement.sourceOffset.z));
    const float emitterY = std::max(0.02f, std::min(1.97f, emitter.heightNorm * 2.03f + 0.02f + placement.sourceOffset.y));
    settings.emitterHeightNorm = std::max(0.0f, std::min(0.96f, (emitterY - 0.02f) / 2.03f));
    settings.emitterHeightBandNorm = emitter.heightBandNorm;
    settings.emitterRadius = emitter.radius;
    settings.sceneSourceMode = source.sourceMode;
    settings.sceneSourceHeightCeiling = source.sourceHeightCeiling;
    settings.sceneCharScale = source.charScale;
    settings.sceneSootScale = source.sootScale;
    settings.sceneInitialHeatBase = source.initialHeatBase;
    settings.sceneInitialHeatNoise = source.initialHeatNoise;
    settings.sceneInitialFuelBase = source.initialFuelBase;
    settings.sceneInitialFuelNoise = source.initialFuelNoise;
    settings.sceneInitialSoot = source.initialSoot;
    settings.sceneInitialAshScale = source.initialAshScale;
    settings.sceneInitialPyrolysisBase = source.initialPyrolysisBase;
    settings.sceneInitialPyrolysisNoise = source.initialPyrolysisNoise;
    settings.sceneInitialProgress = source.initialProgress;
    settings.sceneInitialTurbulence = source.initialTurbulence;
    settings.sceneInitialSootOptics = source.initialSootOptics;
    settings.sceneGasFeed = combustion.gasFeed;
    settings.scenePyrolysisGain = combustion.pyrolysisGain;
    settings.sceneFuelGain = combustion.fuelGain;
    settings.sceneHeatGain = combustion.heatGain;
    settings.sceneSootGain = combustion.sootGain;
    settings.sceneCharGrowth = combustion.charGrowth;
    settings.sceneAshScale = combustion.ashScale;
    settings.sceneBedHeatBase = combustion.bedHeatBase;
    settings.scenePyrolysisFuelScale = combustion.pyrolysisFuelScale;
    settings.scenePyrolysisSootScale = combustion.pyrolysisSootScale;
    settings.sceneSootYieldScale = combustion.sootYieldScale;
    settings.sceneCurlScale = combustion.curlScale;
    settings.sceneBuoyancyScale = combustion.buoyancyScale;
    settings.sceneBuoyancyCeiling = combustion.buoyancyCeiling;
    settings.sceneBuoyancyFloor = combustion.buoyancyFloor;
    settings.sceneFloorGlowR = render.floorGlowR;
    settings.sceneFloorGlowG = render.floorGlowG;
    settings.sceneFloorGlowB = render.floorGlowB;
    settings.sceneFloorTongueR = render.floorTongueR;
    settings.sceneFloorTongueG = render.floorTongueG;
    settings.sceneFloorTongueB = render.floorTongueB;
    settings.sceneFloorGlowScale = render.floorGlowScale;
    settings.sceneFloorTongueScale = render.floorTongueScale;
    settings.sceneWallGlowR = render.wallGlowR;
    settings.sceneWallGlowG = render.wallGlowG;
    settings.sceneWallGlowB = render.wallGlowB;
    settings.sceneWallGlowScale = render.wallGlowScale;
    settings.sceneOrangeEmissionScale = render.orangeEmissionScale;
    settings.sceneFilamentEmissionScale = render.filamentEmissionScale;
    settings.sceneWarmScatter = render.warmScatter;
    settings.sceneSmokeScale = render.smokeScale;
    settings.sceneSourcePlaneMode = render.sourcePlaneMode;
    settings.sceneBurnerJetScale = render.burnerJetScale;
    settings.sceneCampTongueScale = render.campTongueScale;
    settings.sceneRoomTrayScale = render.roomTrayScale;
    settings.sceneConvectiveHeightTop = render.convectiveHeightTop;
    settings.sceneConvectiveHeightBottom = render.convectiveHeightBottom;
    settings.sceneFlameHeightTop = render.flameHeightTop;
    settings.sceneFlameHeightBottom = render.flameHeightBottom;
    settings.sceneLowerWhiteHeight = render.lowerWhiteHeight;
    settings.sceneRoomCoverageBase = render.roomCoverageBase;
    settings.sceneRoomCoverageScale = render.roomCoverageScale;
    settings.sceneTopDissolveTop = render.topDissolveTop;
    settings.sceneTopDissolveBottom = render.topDissolveBottom;
    settings.sceneCampHoleScale = render.campHoleScale;
    settings.sceneCampTongueDensityScale = render.campTongueDensityScale;
    settings.sceneBlueEmissionScale = render.blueEmissionScale;
    settings.sceneBlueJetEmissionScale = render.blueJetEmissionScale;
    settings.sceneFlameColorR = render.flameColorR;
    settings.sceneFlameColorG = render.flameColorG;
    settings.sceneFlameColorB = render.flameColorB;
    settings.sceneAlternateFlameColorR = render.alternateFlameColorR;
    settings.sceneAlternateFlameColorG = render.alternateFlameColorG;
    settings.sceneAlternateFlameColorB = render.alternateFlameColorB;
    settings.sceneAlternateFlameColorScale = render.alternateFlameColorScale;
    settings.sceneEmberRejectAbove = ember.emberRejectAbove;
    settings.sceneEmberLifeRateBase = ember.emberLifeRateBase;
    settings.sceneEmberLifeRateJitter = ember.emberLifeRateJitter;
    settings.sceneEmberLifeRateAdd = ember.emberLifeRateAdd;
    settings.sceneEmberSpawnMode = ember.emberSpawnMode;
    settings.sceneEmberStartVBase = ember.emberStartVBase;
    settings.sceneEmberStartVJitter = ember.emberStartVJitter;
    settings.sceneEmberLift = ember.emberLift;
    settings.sceneEmberLifeScale = ember.emberLifeScale;
    settings.sceneEmberDrag = ember.emberDrag;
    settings.sceneEmberRadiusBase = ember.emberRadiusBase;
    settings.sceneEmberRadiusJitter = ember.emberRadiusJitter;
    settings.sceneEmberTrailCap = ember.emberTrailCap;
    settings.sceneEmberHotR = ember.emberHotR;
    settings.sceneEmberHotG = ember.emberHotG;
    settings.sceneEmberHotB = ember.emberHotB;
    settings.sceneEmberCoolR = ember.emberCoolR;
    settings.sceneEmberCoolG = ember.emberCoolG;
    settings.sceneEmberCoolB = ember.emberCoolB;
    settings.sceneEmberAlphaScale = ember.emberAlphaScale;
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
