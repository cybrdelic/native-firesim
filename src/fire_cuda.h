#pragma once

#include <cstdint>

struct FireCudaDiagnostics {
    int driverVersion = 0;
    int runtimeVersion = 0;
    int deviceCount = 0;
    int activeDevice = -1;
    int computeMajor = 0;
    int computeMinor = 0;
    std::uint64_t totalGlobalMem = 0;
    char deviceName[128] = {};
};

struct FireCudaFrameMetrics {
    int frameIndex = 0;
    int gridX = 0;
    int gridY = 0;
    int gridZ = 0;
    int pressureIterations = 0;
    int invalidCells = 0;
    float timeSeconds = 0.0f;
    float gpuSolveMs = 0.0f;
    float gpuRenderMs = 0.0f;
    float heatSum = 0.0f;
    float fuelSum = 0.0f;
    float oxygenSum = 0.0f;
    float sootSum = 0.0f;
    float charSum = 0.0f;
    float ashSum = 0.0f;
    float pyrolysisSum = 0.0f;
    float progressSum = 0.0f;
    float turbulenceEnergySum = 0.0f;
    float sootOpticalDepthSum = 0.0f;
    float maxHeat = 0.0f;
    float maxFuel = 0.0f;
    float maxSoot = 0.0f;
    float maxPyrolysis = 0.0f;
    float maxProgress = 0.0f;
    float maxTurbulenceEnergy = 0.0f;
    float flameHeightMeters = 0.0f;
    float meanOpticalDepth = 0.0f;
    float heatReleaseProxy = 0.0f;
    float divergenceBeforeL2 = 0.0f;
    float divergenceBeforeMax = 0.0f;
    float divergenceAfterL2 = 0.0f;
    float divergenceAfterMax = 0.0f;
    float divergenceReduction = 0.0f;
};

struct FireSettings {
    int width = 1280;
    int height = 720;
    float dt = 1.0f / 60.0f;
    float mouseX = 0.5f;
    float mouseY = 0.12f;
    int leftDown = 0;
    int rightDown = 0;
    int reset = 0;
    int showGizmos = 1;
    int activeGizmo = 1;
    float wind = 0.0f;
    float turbulence = 0.72f;
    float detail = 0.88f;
    float smoke = 0.92f;
    float intensity = 1.0f;
    float cameraYaw = 0.0f;
    float cameraPitch = 0.18f;
    float cameraDistance = 3.35f;
    int cinematicMode = 0;
    int raymarchSteps = 56;
    int emberCount = 96;
    int renderDebugMode = 0;
    float exposure = 1.0f;
    float reflectionGain = 1.0f;
    float smokeDarkness = 1.0f;
};

bool fireCudaInitialize(int frameWidth, int frameHeight, int gridWidth, int gridHeight);
bool fireCudaStepAndRender(std::uint32_t* bgraPixels, const FireSettings& settings);
bool fireCudaStepAndRenderMeasured(std::uint32_t* bgraPixels, const FireSettings& settings, FireCudaFrameMetrics* metrics);
bool fireCudaRegisterD3D11Texture(void* d3d11Texture);
bool fireCudaStepAndRenderD3D11(const FireSettings& settings);
void fireCudaUnregisterD3D11Texture();
bool fireCudaReset();
bool fireCudaGetDiagnostics(FireCudaDiagnostics* diagnostics);
void fireCudaShutdown();
const char* fireCudaLastError();
