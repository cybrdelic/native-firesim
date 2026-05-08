#pragma once

#include <windows.h>

#include <cstdio>
#include <cstring>

#include "d3d_render_types.h"
#include "fire_cuda.h"
#include "ui_layout.h"

constexpr DWORD kSharedViewportMagic = 0x46535631u;
constexpr DWORD kSharedViewportVersion = 9u;
constexpr const char* kSharedViewportName = "Local\\NativeFireSimViewportFrameV9";
constexpr DWORD kSharedViewportDisplayFormat = static_cast<DWORD>(DXGI_FORMAT_R16G16B16A16_FLOAT);

constexpr DWORD fnv1a32(const char* text, DWORD hash = 2166136261u) {
    return *text == '\0' ? hash : fnv1a32(text + 1, (hash ^ static_cast<unsigned char>(*text)) * 16777619u);
}

constexpr const char* kSharedViewportBuildStampText = __DATE__ " " __TIME__;
constexpr DWORD kSharedViewportBuildStamp = fnv1a32(kSharedViewportBuildStampText);

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

inline bool sharedViewportContractMatches(const SharedViewportBuffer& shared) {
    return shared.magic == kSharedViewportMagic &&
        shared.version == kSharedViewportVersion &&
        shared.buildStamp == kSharedViewportBuildStamp &&
        shared.width == kFrameWidth &&
        shared.height == kFrameHeight &&
        shared.displayFormat == kSharedViewportDisplayFormat;
}

inline void initializeSharedViewportBuffer(SharedViewportBuffer& shared, LONG sceneEpoch) {
    std::memset(&shared, 0, sizeof(SharedViewportBuffer));
    shared.magic = kSharedViewportMagic;
    shared.version = kSharedViewportVersion;
    shared.buildStamp = kSharedViewportBuildStamp;
    shared.width = kFrameWidth;
    shared.height = kFrameHeight;
    shared.displayFormat = kSharedViewportDisplayFormat;
    shared.workerStatus = 0;
    shared.workerExitCode = 0;
    shared.workerErrorCount = 0;
    shared.workerPublishedFrames = 0;
    shared.workerPhysicsFrames = 0;
    shared.workerRenderOnlyFrames = 0;
    shared.activeSceneEpoch = sceneEpoch;
    std::snprintf(shared.statusText, sizeof(shared.statusText), "shared viewport initialized");
}
