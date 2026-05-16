#pragma once

constexpr int kSimulationGridWidth = 384;
constexpr int kSimulationGridHeight = 240;
constexpr int kRaymarchSteps = 104;
constexpr int kSparseRaymarchMaxSteps = kRaymarchSteps;
constexpr int kSparseRaymarchMaxEmptyStride = 8;
constexpr int kSparseRaymarchMediumEmptyStride = 2;
constexpr float kSparseRaymarchActiveThreshold = 0.0009f;
constexpr float kSparseRaymarchFineThreshold = 0.012f;
constexpr int kTemporalVolumeHistoryFrames = 4;
constexpr int kTemporalBlueNoisePhases = 16;
constexpr int kRadianceCacheUpdateIntervalFrames = 2;
constexpr int kEmberCount = 64;
constexpr float kExposure = 0.84f;
constexpr float kReflectionGain = 0.54f;
constexpr float kSmokeDarkness = 1.26f;
constexpr float kFireIntensity = 1.42f;
constexpr float kSmokeGain = 0.96f;
constexpr float kTurbulence = 0.82f;
constexpr double kAppPumpFps = 360.0;
constexpr float kWorkerMaxPublishFps = 180.0f;
constexpr double kDisplayMaxPresentFps = 180.0;

constexpr double kEngineMinWorkerEffectiveFps = 45.0;
constexpr double kEngineMaxWorkerFrameMs = 24.0;
constexpr double kEngineMaxProjectionMs = 26.0;
constexpr double kEngineMaxReactionMs = 16.0;
constexpr double kEngineMaxRaymarchMs = 14.0;
constexpr double kEngineMaxLightingMs = 6.0;

constexpr float kEngineMinRoomMeanLuma = 0.030f;
constexpr float kEngineMinRoomMaxLuma = 0.500f;
constexpr float kEngineMinMeanRoomIrradiance = 0.0010f;
constexpr int kRoomIrradianceProbeCount = 5;
constexpr int kRoomShadowRaySteps = 7;

constexpr float kNistMethanolPoolDiameterMeters = 1.0f;
constexpr float kNistMethanolInitialFuelMassKg = 37.8f;
constexpr float kNistMethanolMeasuredMassBurnRateGps = 12.8f;
constexpr float kNistMethanolMassBurnRateUncertaintyGps = 0.9f;
constexpr float kNistMethanolHeatOfCombustionMjPerKg = 19.92f;
constexpr float kNistMethanolRadiativeFraction = 0.22f;
constexpr float kNistMethanolSootYieldKgPerKg = 0.0f;
constexpr float kNistMethanolAmbientTemperatureK = 298.0f;
constexpr float kNistMethanolStoichOxygenFuelMassRatio = 1.50f;
constexpr float kNistMethanolMaxSmokeOpticalDepth = 0.018f;

constexpr float kNistMethanolMaxHrrShapeRmse = 0.35f;
constexpr float kNistMethanolMaxMassShapeRmse = 0.20f;
constexpr float kNistMethanolMaxSmokeShapeRmse = 0.18f;
constexpr float kNistMethanolMaxRadiantHeatFluxShapeRmse = 0.22f;
constexpr double kNistMethanolMaxAverageSolveMs = 30.0;
constexpr double kNistMethanolMaxAverageRenderMs = 30.0;
constexpr double kNistMethanolMaxAverageRaymarchMs = 18.0;
constexpr int kNistMethanolMinBrightPixels = 256;
constexpr float kNistMethanolMinWhiteCoreFraction = 0.00010f;
