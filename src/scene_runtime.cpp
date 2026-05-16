#include "scene_runtime.h"

#include <algorithm>

#include "runtime_quality.h"

namespace {

constexpr SceneValidationEnvelope methanolValidationEnvelope() {
    SceneValidationEnvelope envelope{};
    envelope.minMaxLuma = 0.10f;
    envelope.minMeanLuma = 0.006f;
    envelope.minFlameMassProxy = 1.0f;
    envelope.minBrightPixels = 0;
    envelope.maxFlameHeightMeters = 1.10f;
    envelope.maxSmokeToFlameRatio = 24.0f;
    envelope.maxCharSum = 1.0f;
    envelope.maxAshSum = 1.0f;
    return envelope;
}

constexpr SceneCameraProfile methanolCameraProfile() {
    SceneCameraProfile camera{};
    camera.yaw = 0.12f;
    camera.pitch = 0.10f;
    camera.distance = 2.70f;
    camera.targetX = 0.0f;
    camera.targetY = 0.54f;
    camera.targetZ = 0.0f;
    camera.fovYDegrees = 48.0f;
    return camera;
}

constexpr SceneCudaCoefficients methanolPoolCuda() {
    SceneCudaCoefficients c{};
    c.source.sourceMode = 3;
    c.source.sourceHeightCeiling = 0.078f;
    c.source.charScale = 0.0f;
    c.source.sootScale = 0.10f;
    c.source.initialFuelBase = 0.96f;
    c.source.initialFuelNoise = 0.05f;
    c.combustion.gasFeed = 1.0f;
    c.combustion.pyrolysisGain = 0.96f;
    c.combustion.fuelGain = 0.92f;
    c.combustion.heatGain = 1.42f;
    c.combustion.sootGain = 0.14f;
    c.combustion.charGrowth = 0.0f;
    c.combustion.ashScale = 0.0f;
    c.combustion.bedHeatBase = 9.10f;
    c.combustion.pyrolysisFuelScale = 1.58f;
    c.combustion.pyrolysisSootScale = 0.018f;
    c.combustion.sootYieldScale = 0.014f;
    c.combustion.stoichOxygenFuelMassRatio = kNistMethanolStoichOxygenFuelMassRatio;
    c.combustion.heatOfCombustionProxy = kNistMethanolHeatOfCombustionMjPerKg;
    c.combustion.radiativeFraction = kNistMethanolRadiativeFraction;
    c.combustion.targetMassBurnRateGps = kNistMethanolMeasuredMassBurnRateGps;
    c.combustion.measuredSootYield = kNistMethanolSootYieldKgPerKg;
    c.combustion.ambientTemperatureK = kNistMethanolAmbientTemperatureK;
    c.combustion.curlScale = 0.98f;
    c.combustion.buoyancyScale = 1.16f;
    c.combustion.buoyancyCeiling = 0.84f;
    c.combustion.buoyancyFloor = 0.025f;
    c.render.floorGlowScale = 0.95f;
    c.render.floorTongueScale = 0.14f;
    c.render.wallGlowScale = 0.20f;
    c.render.orangeEmissionScale = 0.88f;
    c.render.filamentEmissionScale = 2.35f;
    c.render.warmScatter = 0.045f;
    c.render.smokeScale = 0.42f;
    c.render.sourcePlaneMode = 2.0f;
    c.render.convectiveHeightTop = 0.92f;
    c.render.flameHeightTop = 0.70f;
    c.render.lowerWhiteHeight = 0.065f;
    c.render.roomCoverageBase = 0.84f;
    c.render.roomCoverageScale = 0.0f;
    c.render.topDissolveTop = 0.88f;
    c.render.topDissolveBottom = 0.36f;
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

constexpr SceneProfile kMethanolProfile = {
    kProductSceneId,
    "methanol-pool",
    "nist-1m-liquid-pool",
    "liquid",
    "low-soot axisymmetric methanol pool flame",
    methanolPoolCuda(),
    methanolValidationEnvelope(),
    methanolCameraProfile(),
};

float emitterSourceY(const SceneEmitterParams& emitter) {
    return emitter.heightNorm * 2.03f + 0.02f;
}

} // namespace

int clampSceneId(int sceneId) {
    (void)sceneId;
    return kProductSceneId;
}

const SceneProfile& sceneProfile(int sceneId) {
    (void)sceneId;
    return kMethanolProfile;
}

const SceneCameraProfile& sceneCameraProfile(int sceneId) {
    (void)sceneId;
    return kMethanolProfile.camera;
}

ScenePlacement& PlacementCoordinateState::scene(int sceneId) {
    (void)sceneId;
    return productScene;
}

const ScenePlacement& PlacementCoordinateState::scene(int sceneId) const {
    (void)sceneId;
    return productScene;
}

Vec3 sceneSourceWorld(const SceneEmitterParams& emitter, const ScenePlacement& placement, int sceneId) {
    (void)sceneId;
    return {
        emitter.centerX + placement.sourceOffset.x,
        emitterSourceY(emitter) + placement.sourceOffset.y,
        emitter.centerZ + placement.sourceOffset.z,
    };
}

SceneInstance makeSceneInstance(int sceneId, long sceneEpoch, const SceneEmitterParams& emitter) {
    (void)sceneId;
    SceneInstance instance;
    instance.sceneId = kProductSceneId;
    instance.sceneEpoch = static_cast<int>(sceneEpoch);
    instance.emitter = emitter;
    instance.sourceX = emitter.centerX;
    instance.sourceY = emitterSourceY(emitter);
    instance.sourceZ = emitter.centerZ;
    instance.sourceRadius = emitter.radius;
    instance.sourceHeightBandMeters = emitter.heightBandNorm * 2.03f;
    return instance;
}

void applySceneEmitterToSettings(FireSettings& settings, const SceneEmitterParams& emitter, long sceneEpoch, const ScenePlacement& placement) {
    const SceneCudaCoefficients& cuda = kMethanolProfile.cuda;
    const SceneSourceCoefficients& source = cuda.source;
    const SceneCombustionCoefficients& combustion = cuda.combustion;
    const SceneRenderCoefficients& render = cuda.render;
    const SceneEmberCoefficients& ember = cuda.ember;
    settings.sceneId = kProductSceneId;
    settings.sceneEpoch = static_cast<int>(sceneEpoch);
    settings.emitterCenterX = std::max(-1.05f, std::min(1.05f, emitter.centerX + placement.sourceOffset.x));
    settings.emitterCenterZ = std::max(-0.82f, std::min(0.82f, emitter.centerZ + placement.sourceOffset.z));
    const float emitterY = std::max(0.02f, std::min(1.97f, emitterSourceY(emitter) + placement.sourceOffset.y));
    settings.emitterHeightNorm = std::max(0.0f, std::min(0.96f, (emitterY - 0.02f) / 2.03f));
    settings.emitterHeightBandNorm = emitter.heightBandNorm;
    settings.emitterRadius = emitter.radius;
    settings.sceneSourceMode = source.sourceMode;
    settings.sceneSourceHeightCeiling = source.sourceHeightCeiling;
    settings.sceneCharScale = source.charScale;
    settings.sceneSootScale = source.sootScale;
    settings.sceneInitialFuelBase = source.initialFuelBase;
    settings.sceneInitialFuelNoise = source.initialFuelNoise;
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
    settings.sceneStoichOxygenFuelMassRatio = combustion.stoichOxygenFuelMassRatio;
    settings.sceneHeatOfCombustionProxy = combustion.heatOfCombustionProxy;
    settings.sceneRadiativeFraction = combustion.radiativeFraction;
    settings.sceneTargetMassBurnRateGps = combustion.targetMassBurnRateGps;
    settings.sceneMeasuredSootYield = combustion.measuredSootYield;
    settings.sceneAmbientTemperatureK = combustion.ambientTemperatureK;
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
    settings.sceneConvectiveHeightTop = render.convectiveHeightTop;
    settings.sceneConvectiveHeightBottom = render.convectiveHeightBottom;
    settings.sceneFlameHeightTop = render.flameHeightTop;
    settings.sceneFlameHeightBottom = render.flameHeightBottom;
    settings.sceneLowerWhiteHeight = render.lowerWhiteHeight;
    settings.sceneRoomCoverageBase = render.roomCoverageBase;
    settings.sceneRoomCoverageScale = render.roomCoverageScale;
    settings.sceneTopDissolveTop = render.topDissolveTop;
    settings.sceneTopDissolveBottom = render.topDissolveBottom;
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
}
