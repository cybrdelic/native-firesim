#pragma once

#include "render_debug_modes.h"
#include "runtime_state.h"

inline const char* toolName(int tool) {
    switch (tool) {
    case 1: return "Fire";
    case 2: return "Smoke";
    case 3: return "Wind";
    case 4: return "Turb";
    default: return "None";
    }
}

inline const char* renderDebugName(int mode) {
    return renderDebugModeShortName(mode);
}

inline const char* sceneName(int scene) {
    (void)scene;
    return "NIST methanol";
}

inline const char* sceneButtonLabel(int scene) {
    (void)scene;
    return "NIST Methanol";
}

inline const char* transitionReasonName(RuntimeTransitionReason reason) {
    switch (reason) {
    case RuntimeTransitionReason::ProductSceneRefresh: return "product-scene-refresh";
    case RuntimeTransitionReason::UserReset: return "user-reset";
    case RuntimeTransitionReason::WorkerStale: return "worker-stale";
    case RuntimeTransitionReason::WorkerFrameCopied: return "worker-frame-copied";
    case RuntimeTransitionReason::OverlayChanged: return "overlay-changed";
    default: return "startup";
    }
}
