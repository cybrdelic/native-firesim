#pragma once

#if defined(__CUDACC__)
#define FIRESIM_HOST_DEVICE __host__ __device__
#else
#define FIRESIM_HOST_DEVICE
#endif

enum RenderDebugMode : int {
    kRenderDebugFinal = 0,
    kRenderDebugFlame = 1,
    kRenderDebugSoot = 2,
    kRenderDebugTransmittance = 3,
    kRenderDebugTemperature = 4,
    kRenderDebugFuel = 5,
    kRenderDebugVelocity = 6,
    kRenderDebugGas = 7,
    kRenderDebugFlow = 8,
    kRenderDebugSource = 9,
    kRenderDebugOxygen = 10,
    kRenderDebugActiveBricks = 11,
    kRenderDebugSkippedBricks = 12,
    kRenderDebugEmission = 13,
    kRenderDebugExtinction = 14,
    kRenderDebugReaction = 15,
    kRenderDebugProduct = 16,
    kRenderDebugModeCount = 17,
};

FIRESIM_HOST_DEVICE inline int clampRenderDebugMode(int mode) {
    return mode < kRenderDebugFinal ? kRenderDebugFinal : (mode >= kRenderDebugModeCount ? kRenderDebugModeCount - 1 : mode);
}

FIRESIM_HOST_DEVICE inline int nextRenderDebugMode(int mode) {
    return (clampRenderDebugMode(mode) + 1) % kRenderDebugModeCount;
}

FIRESIM_HOST_DEVICE inline bool renderDebugModeIsFinal(int mode) {
    return clampRenderDebugMode(mode) == kRenderDebugFinal;
}

FIRESIM_HOST_DEVICE inline bool renderDebugModeNeedsVelocity(int mode) {
    const int clamped = clampRenderDebugMode(mode);
    return clamped == kRenderDebugVelocity || clamped == kRenderDebugFlow;
}

FIRESIM_HOST_DEVICE inline bool renderDebugModeNeedsSourceProbe(int mode) {
    return clampRenderDebugMode(mode) == kRenderDebugSource;
}

FIRESIM_HOST_DEVICE inline bool renderDebugModeNeedsGasProbe(int mode) {
    const int clamped = clampRenderDebugMode(mode);
    return clamped == kRenderDebugGas || clamped == kRenderDebugFlow || clamped == kRenderDebugOxygen;
}

FIRESIM_HOST_DEVICE inline bool renderDebugModeKeepsSparseVolumeSamples(int mode) {
    const int clamped = clampRenderDebugMode(mode);
    return (clamped >= kRenderDebugGas && clamped < kRenderDebugActiveBricks) ||
        clamped == kRenderDebugReaction ||
        clamped == kRenderDebugProduct;
}

FIRESIM_HOST_DEVICE inline bool renderDebugModeNeedsBrickProbe(int mode) {
    const int clamped = clampRenderDebugMode(mode);
    return clamped == kRenderDebugActiveBricks || clamped == kRenderDebugSkippedBricks;
}

FIRESIM_HOST_DEVICE inline bool renderDebugModeNeedsOpticsProbe(int mode) {
    const int clamped = clampRenderDebugMode(mode);
    return clamped == kRenderDebugEmission || clamped == kRenderDebugExtinction;
}

inline const char* renderDebugModeShortName(int mode) {
    switch (clampRenderDebugMode(mode)) {
    case kRenderDebugFlame: return "FLAME";
    case kRenderDebugSoot: return "SOOT";
    case kRenderDebugTransmittance: return "TRANS";
    case kRenderDebugTemperature: return "TEMP";
    case kRenderDebugFuel: return "FUEL";
    case kRenderDebugVelocity: return "VEL";
    case kRenderDebugGas: return "GAS";
    case kRenderDebugFlow: return "FLOW";
    case kRenderDebugSource: return "SRC";
    case kRenderDebugOxygen: return "OXY";
    case kRenderDebugActiveBricks: return "BRICK";
    case kRenderDebugSkippedBricks: return "SKIP";
    case kRenderDebugEmission: return "EMIT";
    case kRenderDebugExtinction: return "EXT";
    case kRenderDebugReaction: return "REACT";
    case kRenderDebugProduct: return "PROD";
    default: return "FINAL";
    }
}

inline const char* renderDebugModeDiagnosticsList() {
    return "final,flame,soot,transmittance,temperature,fuel-char,vertical-velocity,gas,flow,source,oxygen,active-bricks,skipped-bricks,emission,extinction,reaction,product";
}

#undef FIRESIM_HOST_DEVICE
