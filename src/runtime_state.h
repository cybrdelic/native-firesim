#pragma once

enum class RuntimeTransitionReason {
    Startup,
    ProductSceneRefresh,
    UserReset,
    WorkerStale,
    WorkerFrameCopied,
    OverlayChanged
};

struct CanonicalRuntimeState {
    int sceneId = 0;
    int debugMode = 0;
    int activeGizmo = 1;
    bool needsReset = false;
    bool cudaWorkerLive = false;
    bool uiOverlayDirty = true;
    unsigned long long transitionCount = 0;
    RuntimeTransitionReason lastReason = RuntimeTransitionReason::Startup;
};
