#pragma once

#include <cstring>

struct FrameHealthInput {
    bool cudaWorkerBlockedBySafetyGate = false;
    bool cudaWorkerRequested = false;
    bool cudaWorkerFrameLive = false;
    int workerStatus = 0;
    double liveCopiedHz = 0.0;
    double workerPublishedHz = 0.0;
    double workerPhysicsHz = 0.0;
    unsigned long long displayFrameAgeMs = 0;
    unsigned long long workerFrameStaleMs = 0;
    unsigned long long sharedRingCopyStarvationFrames = 0;
    unsigned long long sharedRingAcquireTimeouts = 0;
};

inline const char* classifyFrameHealthState(const FrameHealthInput& input) {
    if (input.cudaWorkerBlockedBySafetyGate) {
        return "blocked";
    }
    if (!input.cudaWorkerRequested) {
        return "disabled";
    }
    if (input.workerStatus < 0) {
        return "error";
    }
    if (!input.cudaWorkerFrameLive) {
        return "stale";
    }
    if (input.liveCopiedHz < 45.0 || input.workerPublishedHz < 45.0) {
        return "degraded";
    }
    return "healthy";
}

inline const char* classifyFireStreamHealthLabel(const FrameHealthInput& input) {
    if (!input.cudaWorkerRequested) {
        return "fire-stream disabled";
    }
    if (input.workerStatus < 0) {
        return "fire-stream worker error";
    }
    if (input.displayFrameAgeMs > input.workerFrameStaleMs ||
        input.sharedRingCopyStarvationFrames > 0) {
        return "fire-stream stale";
    }
    if (input.workerPhysicsHz > 1.0 &&
        input.liveCopiedHz > 1.0 &&
        input.liveCopiedHz < input.workerPhysicsHz * 0.45) {
        return "fire-stream copy lag";
    }
    if (input.sharedRingAcquireTimeouts > 12) {
        return "fire-stream ring pressure";
    }
    return "fire-stream healthy";
}

inline bool fireStreamHealthNeedsOperatorWarning(const char* label) {
    return std::strcmp(label, "fire-stream healthy") != 0 &&
           std::strcmp(label, "fire-stream disabled") != 0;
}
