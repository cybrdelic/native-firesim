#pragma once

#include "runtime_state.h"

inline const char* toolName(int tool) {
    switch (tool) {
    case 1: return "FIRE";
    case 2: return "SMOKE";
    case 3: return "WIND";
    case 4: return "TURB";
    default: return "NONE";
    }
}

inline const char* renderDebugName(int mode) {
    switch (mode) {
    case 1: return "FLAME";
    case 2: return "SOOT";
    case 3: return "TRANS";
    case 4: return "TEMP";
    case 5: return "FUEL";
    case 6: return "VEL";
    default: return "FINAL";
    }
}

inline const char* sceneName(int scene) {
    switch (scene) {
    case 1: return "CAMPFIRE";
    case 2: return "GAS BURNER";
    case 3: return "NIST METHANOL";
    default: return "ROOM";
    }
}

inline const char* transitionReasonName(RuntimeTransitionReason reason) {
    switch (reason) {
    case RuntimeTransitionReason::SceneSwitch: return "scene-switch";
    case RuntimeTransitionReason::UserReset: return "user-reset";
    case RuntimeTransitionReason::WorkerStale: return "worker-stale";
    case RuntimeTransitionReason::WorkerFrameCopied: return "worker-frame-copied";
    case RuntimeTransitionReason::OverlayChanged: return "overlay-changed";
    default: return "startup";
    }
}
