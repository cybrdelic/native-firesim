#pragma once

#include <windows.h>

#include "d3d_render_types.h"
#include "fire_cuda.h"

struct SharedViewportBuffer {
    DWORD magic;
    DWORD version;
    DWORD buildStamp;
    DWORD width;
    DWORD height;
    DWORD displayFormat;
    volatile LONG frameSequence;
    volatile LONG settingsSequence;
    volatile LONG shutdownRequested;
    volatile LONG workerStatus;
    volatile LONG workerExitCode;
    volatile LONG workerErrorCount;
    volatile LONG workerPublishedFrames;
    volatile LONG workerPhysicsFrames;
    volatile LONG workerRenderOnlyFrames;
    DWORD workerPid;
    unsigned long long lastFrameTickMs;
    unsigned long long workerHeartbeatTickMs;
    unsigned long long workerStartTickMs;
    unsigned long long workerStopTickMs;
    unsigned long long sharedTextureHandleValue;
    unsigned long long sharedTextureHandleValues[kD3DSharedFrameSlots];
    volatile LONG latestFrameSlot;
    volatile LONG slotFrameSequences[kD3DSharedFrameSlots];
    volatile LONG slotSceneEpochs[kD3DSharedFrameSlots];
    volatile LONG activeSceneEpoch;
    unsigned long long workerFrameMicros;
    unsigned long long workerCudaMicros;
    unsigned long long workerPublishMicros;
    FireSettings settings;
    char statusText[192];
};
