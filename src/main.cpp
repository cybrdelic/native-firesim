#include <windows.h>
#include <windowsx.h>
#include <mmsystem.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <cfloat>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include "fire_cuda.h"

namespace {

using Microsoft::WRL::ComPtr;

constexpr int kFrameWidth = 960;
constexpr int kFrameHeight = 540;
constexpr int kSimulationGridWidth = 384;
constexpr int kSimulationGridHeight = 240;
constexpr int kRaymarchSteps = 104;
constexpr int kEmberCount = 176;
constexpr float kExposure = 0.84f;
constexpr float kReflectionGain = 0.54f;
constexpr float kSmokeDarkness = 1.26f;
constexpr float kFireIntensity = 1.42f;
constexpr float kSmokeGain = 0.96f;
constexpr float kTurbulence = 1.34f;
constexpr double kAppPumpFps = 360.0;
constexpr float kWorkerMaxPublishFps = 180.0f;
constexpr double kDisplayMaxPresentFps = 180.0;
constexpr float kTargetFrameSeconds = static_cast<float>(1.0 / kAppPumpFps);
static_assert(static_cast<int>(kAppPumpFps) == static_cast<int>(kDisplayMaxPresentFps) * 2, "display pacing expects a 2:1 app pump to present cadence");
constexpr unsigned long long kWorkerStatusUiUpdateMs = 250ull;
constexpr DWORD kSharedViewportMagic = 0x46535631u;
constexpr DWORD kSharedViewportVersion = 9u;
constexpr int kSharedFrameSlots = 3;
constexpr int kDisplayFrameSlots = 3;
constexpr const char* kSharedViewportName = "Local\\NativeFireSimViewportFrameV9";
constexpr DWORD kSharedViewportDisplayFormat = static_cast<DWORD>(DXGI_FORMAT_R16G16B16A16_FLOAT);
constexpr DXGI_FORMAT kSceneRadianceFormat = DXGI_FORMAT_R16G16B16A16_FLOAT;
constexpr const char* kRenderGraphPasses = "clear,volume-hdr-camera,lit-scene-mesh,ui-overlay,present";
constexpr const char* kHdrCameraPipeline =
    "CUDA float4 scene radiance -> FP16 D3D texture -> single ACES camera response -> FP16 swapchain -> UI overlay";
constexpr DWORD fnv1a32(const char* text, DWORD hash = 2166136261u) {
    return *text == '\0' ? hash : fnv1a32(text + 1, (hash ^ static_cast<unsigned char>(*text)) * 16777619u);
}
constexpr const char* kSharedViewportBuildStampText = __DATE__ " " __TIME__;
constexpr DWORD kSharedViewportBuildStamp = fnv1a32(kSharedViewportBuildStampText);
constexpr unsigned long long kWorkerFrameStaleMs = 2200ull;
constexpr unsigned long long kWorkerHeartbeatStaleMs = 3400ull;
constexpr unsigned long long kWorkerKillStaleMs = 7200ull;
constexpr unsigned long long kWorkerRestartWindowMs = 60000ull;
constexpr int kWorkerRestartLimit = 3;
constexpr int kWorkerPhysicsFrameInterval = 1;
constexpr int kSceneCount = 3;

struct UiRect {
    int x;
    int y;
    int w;
    int h;
};

constexpr UiRect kRailRect = {14, 70, 76, 398};
constexpr UiRect kTopBarRect = {14, 14, 932, 36};
constexpr UiRect kViewportRect = {0, 0, kFrameWidth, kFrameHeight};
constexpr UiRect kInspectorRect = {762, 70, 184, 340};
constexpr UiRect kStatusRect = {14, 480, 932, 44};
constexpr UiRect kToolButtonRects[4] = {
    {22, 96, 60, 64},
    {22, 176, 60, 64},
    {22, 256, 60, 64},
    {22, 336, 60, 64},
};
constexpr UiRect kOverlayButtonRect = {104, 486, 72, 28};
constexpr UiRect kResetButtonRect = {184, 486, 72, 28};
constexpr UiRect kSceneButtonRects[kSceneCount] = {
    {336, 20, 74, 24},
    {418, 20, 74, 24},
    {500, 20, 90, 24},
};
constexpr UiRect kWindSliderRect = {790, 214, 130, 16};
constexpr UiRect kTurbulenceSliderRect = {790, 304, 130, 16};

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
    unsigned long long sharedTextureHandleValues[kSharedFrameSlots];
    volatile LONG latestFrameSlot;
    volatile LONG slotFrameSequences[kSharedFrameSlots];
    unsigned long long workerFrameMicros;
    unsigned long long workerCudaMicros;
    unsigned long long workerPublishMicros;
    FireSettings settings;
    char statusText[192];
};

struct DisplayConstants {
    float exposure;
    float padding[3];
};

struct MeshVertex {
    float px;
    float py;
    float pz;
    float nx;
    float ny;
    float nz;
    float cr;
    float cg;
    float cb;
};

struct MeshConstants {
    float viewProj[16];
    float lightPos[4];
    float baseColor[4];
    float fireColor[4];
    float fireParams[4];
};

struct RuntimeSceneMesh {
    std::vector<MeshVertex> vertices;
    std::vector<std::uint32_t> indices;
    ComPtr<ID3D11Buffer> vertexBuffer;
    ComPtr<ID3D11Buffer> indexBuffer;
    float minX = 0.0f;
    float minY = 0.0f;
    float minZ = 0.0f;
    float maxX = 0.0f;
    float maxY = 0.0f;
    float maxZ = 0.0f;
    bool loaded = false;
};

struct SceneEmitterParams {
    float centerX = 0.0f;
    float centerZ = 0.0f;
    float heightNorm = 0.0f;
    float heightBandNorm = 0.06f;
    float radius = 0.48f;
    int burnerCenterCount = 0;
    float burnerCenterX[4] = {};
    float burnerCenterY[4] = {};
    float burnerCenterZ[4] = {};
};

struct D3DDisplayState {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<IDXGISwapChain> swapChain;
    ComPtr<ID3D11RenderTargetView> renderTargetView;
    std::array<ComPtr<ID3D11Texture2D>, kSharedFrameSlots> sharedSimTextures;
    std::array<ComPtr<IDXGIKeyedMutex>, kSharedFrameSlots> sharedSimMutexes;
    std::array<HANDLE, kSharedFrameSlots> sharedSimHandles = {};
    std::array<ComPtr<ID3D11Texture2D>, kDisplayFrameSlots> displaySimTextures;
    std::array<ComPtr<ID3D11ShaderResourceView>, kDisplayFrameSlots> displaySimSrvs;
    ComPtr<ID3D11Texture2D> uiTexture;
    ComPtr<ID3D11ShaderResourceView> uiSrv;
    ComPtr<ID3D11SamplerState> sampler;
    ComPtr<ID3D11VertexShader> vertexShader;
    ComPtr<ID3D11VertexShader> meshVertexShader;
    ComPtr<ID3D11PixelShader> simPixelShader;
    ComPtr<ID3D11PixelShader> uiPixelShader;
    ComPtr<ID3D11PixelShader> meshPixelShader;
    ComPtr<ID3D11InputLayout> meshInputLayout;
    ComPtr<ID3D11Buffer> displayConstants;
    ComPtr<ID3D11Buffer> meshConstants;
    ComPtr<ID3D11BlendState> alphaBlend;
    ComPtr<ID3D11DepthStencilState> meshDepthState;
    ComPtr<ID3D11RasterizerState> meshRasterizerState;
    ComPtr<ID3D11Query> copyCompletionQuery;
    int activeDisplaySimSlot = -1;
    int nextDisplaySimSlot = 0;
    bool initialized = false;
    bool hasSimFrame = false;
};

struct RenderGraphStats {
    unsigned long long frameIndex = 0;
    unsigned long long clearPasses = 0;
    unsigned long long volumeCameraPasses = 0;
    unsigned long long sceneMeshPasses = 0;
    unsigned long long uiOverlayPasses = 0;
    unsigned long long presentPasses = 0;
    unsigned long long skippedPresentPasses = 0;
    bool lastFrameHadVolume = false;
    bool lastFrameHadMesh = false;
    bool lastFrameHadUi = false;
};

enum class RuntimeTransitionReason {
    Startup,
    SceneSwitch,
    UserReset,
    WorkerStale,
    WorkerFrameCopied,
    OverlayChanged
};

enum class WorkerLifecycleReason {
    StartRequested,
    CreateProcessFailed,
    RestartBlocked,
    StaleHeartbeatKill,
    StopRequested,
    ForcedTerminate,
    Exited,
    GpuInitFailed,
    InteropFailed,
    RenderFailed,
    CleanExit
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

HWND g_window = nullptr;
std::vector<std::uint32_t> g_frame;
std::vector<std::uint32_t> g_simFrame;
D3DDisplayState g_d3d;
RenderGraphStats g_renderGraphStats;
CanonicalRuntimeState g_runtimeState;
std::array<RuntimeSceneMesh, kSceneCount> g_sceneMeshes;
std::array<SceneEmitterParams, kSceneCount> g_sceneEmitters;
HANDLE g_sharedViewportMap = nullptr;
SharedViewportBuffer* g_sharedViewport = nullptr;
HANDLE g_cudaWorkerProcess = nullptr;
bool g_running = true;
bool g_leftDown = false;
bool g_leftInViewport = false;
bool g_rightDown = false;
bool g_orbiting = false;
bool g_needsReset = false;
int g_resetFramesRemaining = 0;
bool g_showGizmos = true;
bool g_cleanViewportMode = false;
bool g_useCudaBackend = false;
float g_mouseX = 0.5f;
float g_mouseY = 0.10f;
int g_lastMouseX = 0;
int g_lastMouseY = 0;
int g_pointerFrameX = 0;
int g_pointerFrameY = 0;
bool g_pointerInViewport = false;
int g_dragControl = 0;
float g_wind = 0.0f;
float g_turbulence = 1.00f;
float g_cameraYaw = 0.0f;
float g_cameraPitch = 0.08f;
float g_cameraDistance = 2.62f;
float g_displayExposure = kExposure;
int g_activeGizmo = 1;
int g_activeScene = 0;
int g_renderDebugMode = 0;
int g_clientW = kFrameWidth;
int g_clientH = kFrameHeight;
bool g_cudaWorkerRequested = false;
bool g_cudaWorkerFrameLive = false;
LONG g_lastCopiedWorkerSequence = 0;
float g_visualFps = 0.0f;
unsigned long long g_lastWorkerStartTickMs = 0;
unsigned long long g_workerRestartWindowStartMs = 0;
unsigned long long g_workerRestartBlockedUntilMs = 0;
int g_workerRestartCount = 0;
int g_workerLastExitCode = 0;
char g_workerUiStatus[192] = "worker not started";
unsigned long long g_lastWorkerStatusFormatTickMs = 0;
bool g_haveLastWorkerSettings = false;
FireSettings g_lastWorkerSettings;
bool g_haveLastOverlaySettings = false;
FireSettings g_lastOverlaySettings;
bool g_lastOverlayCudaBackend = false;
bool g_lastOverlayCleanViewport = false;
char g_lastOverlayStatus[sizeof(g_workerUiStatus)] = {};
unsigned long long g_liveCopyCalls = 0;
unsigned long long g_liveCopiedFrames = 0;
unsigned long long g_livePresentCalls = 0;
unsigned long long g_livePresentFailures = 0;
unsigned long long g_liveReusedPresents = 0;
bool g_lastPresentSkippedWouldBlock = false;
unsigned long long g_liveCopyMicros = 0;
unsigned long long g_livePresentMicros = 0;
double g_liveCopyCallHz = 0.0;
double g_liveCopiedHz = 0.0;
double g_livePresentHz = 0.0;
double g_liveReusedPresentHz = 0.0;
double g_liveIntervalCopyMs = 0.0;
double g_liveIntervalPresentMs = 0.0;
double g_workerPublishedHz = 0.0;
double g_workerPhysicsHz = 0.0;
double g_workerRenderOnlyHz = 0.0;
unsigned long long g_displayFrameAgeMs = 0;
unsigned long long g_sharedRingAcquireTimeouts = 0;
unsigned long long g_sharedRingNoCandidateFrames = 0;
unsigned long long g_sharedRingCopyStarvationFrames = 0;
unsigned long long g_sharedRingSkippedActiveDisplaySlot = 0;
LONG g_sharedRingLastCopiedSharedSlot = -1;
LONG g_sharedRingLastCopiedDisplaySlot = -1;
LONG g_sharedRingLastCopiedSequence = 0;
bool g_uiTextureUploaded = false;

void stopCudaWorker();

bool sameFireSettings(const FireSettings& a, const FireSettings& b) {
    bool burnerCentersSame = a.burnerCenterCount == b.burnerCenterCount;
    for (int i = 0; i < 4; ++i) {
        burnerCentersSame = burnerCentersSame &&
            a.burnerCenterX[i] == b.burnerCenterX[i] &&
            a.burnerCenterY[i] == b.burnerCenterY[i] &&
            a.burnerCenterZ[i] == b.burnerCenterZ[i];
    }
    return a.width == b.width &&
        a.height == b.height &&
        a.mouseX == b.mouseX &&
        a.mouseY == b.mouseY &&
        a.leftDown == b.leftDown &&
        a.rightDown == b.rightDown &&
        a.reset == b.reset &&
        a.showGizmos == b.showGizmos &&
        a.activeGizmo == b.activeGizmo &&
        a.sceneId == b.sceneId &&
        a.wind == b.wind &&
        a.turbulence == b.turbulence &&
        a.detail == b.detail &&
        a.smoke == b.smoke &&
        a.intensity == b.intensity &&
        a.cameraYaw == b.cameraYaw &&
        a.cameraPitch == b.cameraPitch &&
        a.cameraDistance == b.cameraDistance &&
        a.cinematicMode == b.cinematicMode &&
        a.raymarchSteps == b.raymarchSteps &&
        a.emberCount == b.emberCount &&
        a.renderDebugMode == b.renderDebugMode &&
        a.exposure == b.exposure &&
        a.reflectionGain == b.reflectionGain &&
        a.smokeDarkness == b.smokeDarkness &&
        a.emitterCenterX == b.emitterCenterX &&
        a.emitterCenterZ == b.emitterCenterZ &&
        a.emitterHeightNorm == b.emitterHeightNorm &&
        a.emitterHeightBandNorm == b.emitterHeightBandNorm &&
        a.emitterRadius == b.emitterRadius &&
        burnerCentersSame;
}

const char* fireStreamHealthLabel() {
    if (!g_cudaWorkerRequested || g_sharedViewport == nullptr) {
        return "fire-stream disabled";
    }
    if (g_sharedViewport->workerStatus < 0) {
        return "fire-stream worker error";
    }
    if (g_displayFrameAgeMs > kWorkerFrameStaleMs ||
        g_sharedRingCopyStarvationFrames > 0 ||
        g_sharedRingNoCandidateFrames > 12) {
        return "fire-stream stale";
    }
    if (g_workerPhysicsHz > 1.0 && g_liveCopiedHz > 1.0 && g_liveCopiedHz < g_workerPhysicsHz * 0.45) {
        return "fire-stream copy lag";
    }
    if (g_sharedRingAcquireTimeouts > 12) {
        return "fire-stream ring pressure";
    }
    return "fire-stream healthy";
}

bool fireStreamNeedsOperatorWarning() {
    const char* health = fireStreamHealthLabel();
    return std::strcmp(health, "fire-stream healthy") != 0 &&
           std::strcmp(health, "fire-stream disabled") != 0;
}

bool overlayStateDirty(const FireSettings& settings, bool cudaBackend, bool cleanViewport) {
    return !g_haveLastOverlaySettings ||
        !sameFireSettings(g_lastOverlaySettings, settings) ||
        g_lastOverlayCudaBackend != cudaBackend ||
        g_lastOverlayCleanViewport != cleanViewport;
}

void rememberOverlayState(const FireSettings& settings, bool cudaBackend, bool cleanViewport) {
    g_lastOverlaySettings = settings;
    g_lastOverlayCudaBackend = cudaBackend;
    g_lastOverlayCleanViewport = cleanViewport;
    std::snprintf(g_lastOverlayStatus, sizeof(g_lastOverlayStatus), "%s", g_workerUiStatus);
    g_haveLastOverlaySettings = true;
}

void applySceneEmitterParams(FireSettings& settings) {
    const int scene = std::max(0, std::min(kSceneCount - 1, settings.sceneId));
    const SceneEmitterParams& emitter = g_sceneEmitters[scene];
    settings.emitterCenterX = emitter.centerX;
    settings.emitterCenterZ = emitter.centerZ;
    settings.emitterHeightNorm = emitter.heightNorm;
    settings.emitterHeightBandNorm = emitter.heightBandNorm;
    settings.emitterRadius = emitter.radius;
    settings.burnerCenterCount = emitter.burnerCenterCount;
    for (int i = 0; i < 4; ++i) {
        settings.burnerCenterX[i] = emitter.burnerCenterX[i];
        settings.burnerCenterY[i] = emitter.burnerCenterY[i];
        settings.burnerCenterZ[i] = emitter.burnerCenterZ[i];
    }
}

float clamp01(float v) {
    return std::max(0.0f, std::min(1.0f, v));
}

float clampf(float v, float lo, float hi) {
    return std::max(lo, std::min(hi, v));
}

float mixf(float a, float b, float t) {
    return a + (b - a) * t;
}

float smoothstepf(float edge0, float edge1, float x) {
    const bool inverted = edge1 < edge0;
    const float lo = inverted ? edge1 : edge0;
    const float hi = inverted ? edge0 : edge1;
    const float t = clamp01((x - lo) / std::max(0.000001f, hi - lo));
    const float value = t * t * (3.0f - 2.0f * t);
    return inverted ? 1.0f - value : value;
}

std::uint32_t packBgra(float r, float g, float b, float alpha = 1.0f) {
    const auto ri = static_cast<std::uint32_t>(clamp01(r) * 255.0f);
    const auto gi = static_cast<std::uint32_t>(clamp01(g) * 255.0f);
    const auto bi = static_cast<std::uint32_t>(clamp01(b) * 255.0f);
    const auto ai = static_cast<std::uint32_t>(clamp01(alpha) * 255.0f);
    return (ai << 24) | (ri << 16) | (gi << 8) | bi;
}

void clearSimulationFrame(std::vector<std::uint32_t>& pixels) {
    pixels.assign(static_cast<std::size_t>(kFrameWidth) * kFrameHeight, packBgra(0.006f, 0.007f, 0.008f));
}

void invalidateDisplayedCudaFrame() {
    g_d3d.hasSimFrame = false;
    g_d3d.activeDisplaySimSlot = -1;
    g_d3d.nextDisplaySimSlot = 0;
    g_cudaWorkerFrameLive = false;
    g_useCudaBackend = false;
    g_lastCopiedWorkerSequence = g_sharedViewport == nullptr ? 0 : g_sharedViewport->frameSequence;
    g_sharedRingLastCopiedSharedSlot = -1;
    g_sharedRingLastCopiedDisplaySlot = -1;
    g_sharedRingLastCopiedSequence = 0;
    clearSimulationFrame(g_simFrame);
}

void blendPixel(std::vector<std::uint32_t>& pixels, int x, int y, float r, float g, float b, float alpha) {
    if (x < 0 || y < 0 || x >= kFrameWidth || y >= kFrameHeight || alpha <= 0.0f) {
        return;
    }
    const std::uint32_t dst = pixels[static_cast<std::size_t>(y) * kFrameWidth + x];
    const float da = static_cast<float>((dst >> 24) & 0xff) / 255.0f;
    const float dr = static_cast<float>((dst >> 16) & 0xff) / 255.0f;
    const float dg = static_cast<float>((dst >> 8) & 0xff) / 255.0f;
    const float db = static_cast<float>(dst & 0xff) / 255.0f;
    alpha = clamp01(alpha);
    const float outA = alpha + da * (1.0f - alpha);
    const float invOutA = outA > 0.000001f ? 1.0f / outA : 0.0f;
    pixels[static_cast<std::size_t>(y) * kFrameWidth + x] = packBgra(
        (r * alpha + dr * da * (1.0f - alpha)) * invOutA,
        (g * alpha + dg * da * (1.0f - alpha)) * invOutA,
        (b * alpha + db * da * (1.0f - alpha)) * invOutA,
        outA);
}

bool contains(const UiRect& rect, int x, int y) {
    return x >= rect.x && y >= rect.y && x < rect.x + rect.w && y < rect.y + rect.h;
}

void fillRect(std::vector<std::uint32_t>& pixels, const UiRect& rect, float r, float g, float b, float alpha = 1.0f) {
    const int x0 = std::max(0, rect.x);
    const int y0 = std::max(0, rect.y);
    const int x1 = std::min(kFrameWidth, rect.x + rect.w);
    const int y1 = std::min(kFrameHeight, rect.y + rect.h);
    if (alpha >= 0.999f) {
        const std::uint32_t packed = packBgra(r, g, b, alpha);
        for (int y = y0; y < y1; ++y) {
            std::fill(
                pixels.begin() + static_cast<std::ptrdiff_t>(y * kFrameWidth + x0),
                pixels.begin() + static_cast<std::ptrdiff_t>(y * kFrameWidth + x1),
                packed);
        }
        return;
    }
    for (int y = y0; y < y1; ++y) {
        for (int x = x0; x < x1; ++x) {
            blendPixel(pixels, x, y, r, g, b, alpha);
        }
    }
}

void strokeRect(std::vector<std::uint32_t>& pixels, const UiRect& rect, float r, float g, float b, float alpha = 1.0f) {
    fillRect(pixels, {rect.x, rect.y, rect.w, 1}, r, g, b, alpha);
    fillRect(pixels, {rect.x, rect.y + rect.h - 1, rect.w, 1}, r, g, b, alpha);
    fillRect(pixels, {rect.x, rect.y, 1, rect.h}, r, g, b, alpha);
    fillRect(pixels, {rect.x + rect.w - 1, rect.y, 1, rect.h}, r, g, b, alpha);
}

void drawCirclePx(std::vector<std::uint32_t>& pixels, int cx, int cy, int radius, float r, float g, float b, float alpha) {
    for (int y = cy - radius - 2; y <= cy + radius + 2; ++y) {
        for (int x = cx - radius - 2; x <= cx + radius + 2; ++x) {
            const float dx = static_cast<float>(x - cx);
            const float dy = static_cast<float>(y - cy);
            const float d = std::sqrt(dx * dx + dy * dy);
            const float ring = 1.0f - clampf(std::fabs(d - static_cast<float>(radius)) / 2.0f, 0.0f, 1.0f);
            blendPixel(pixels, x, y, r, g, b, alpha * ring);
        }
    }
}

void drawLinePx(std::vector<std::uint32_t>& pixels, int ax, int ay, int bx, int by, float r, float g, float b, float alpha) {
    const int minX = std::min(ax, bx) - 5;
    const int maxX = std::max(ax, bx) + 5;
    const int minY = std::min(ay, by) - 5;
    const int maxY = std::max(ay, by) + 5;
    const float vx = static_cast<float>(bx - ax);
    const float vy = static_cast<float>(by - ay);
    const float vv = std::max(0.000001f, vx * vx + vy * vy);
    for (int y = minY; y <= maxY; ++y) {
        for (int x = minX; x <= maxX; ++x) {
            const float h = clampf(((static_cast<float>(x - ax) * vx) + (static_cast<float>(y - ay) * vy)) / vv, 0.0f, 1.0f);
            const float dx = static_cast<float>(x) - (static_cast<float>(ax) + vx * h);
            const float dy = static_cast<float>(y) - (static_cast<float>(ay) + vy * h);
            const float d = std::sqrt(dx * dx + dy * dy);
            blendPixel(pixels, x, y, r, g, b, alpha * (1.0f - clampf(d / 2.0f, 0.0f, 1.0f)));
        }
    }
}

struct Glyph {
    const char* rows[7];
};

Glyph glyphFor(char c) {
    if (c >= 'a' && c <= 'z') {
        c = static_cast<char>(c - 'a' + 'A');
    }
    switch (c) {
    case 'A': return {{" ### ", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"}};
    case 'B': return {{"#### ", "#   #", "#   #", "#### ", "#   #", "#   #", "#### "}};
    case 'C': return {{" ####", "#    ", "#    ", "#    ", "#    ", "#    ", " ####"}};
    case 'D': return {{"#### ", "#   #", "#   #", "#   #", "#   #", "#   #", "#### "}};
    case 'E': return {{"#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#####"}};
    case 'F': return {{"#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#    "}};
    case 'G': return {{" ####", "#    ", "#    ", "#  ##", "#   #", "#   #", " ####"}};
    case 'H': return {{"#   #", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"}};
    case 'I': return {{"#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "#####"}};
    case 'J': return {{"#####", "   # ", "   # ", "   # ", "   # ", "#  # ", " ##  "}};
    case 'K': return {{"#   #", "#  # ", "# #  ", "##   ", "# #  ", "#  # ", "#   #"}};
    case 'L': return {{"#    ", "#    ", "#    ", "#    ", "#    ", "#    ", "#####"}};
    case 'M': return {{"#   #", "## ##", "# # #", "#   #", "#   #", "#   #", "#   #"}};
    case 'N': return {{"#   #", "##  #", "# # #", "#  ##", "#   #", "#   #", "#   #"}};
    case 'O': return {{" ### ", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "}};
    case 'P': return {{"#### ", "#   #", "#   #", "#### ", "#    ", "#    ", "#    "}};
    case 'Q': return {{" ### ", "#   #", "#   #", "#   #", "# # #", "#  # ", " ## #"}};
    case 'R': return {{"#### ", "#   #", "#   #", "#### ", "# #  ", "#  # ", "#   #"}};
    case 'S': return {{" ####", "#    ", "#    ", " ### ", "    #", "    #", "#### "}};
    case 'T': return {{"#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  "}};
    case 'U': return {{"#   #", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "}};
    case 'V': return {{"#   #", "#   #", "#   #", "#   #", "#   #", " # # ", "  #  "}};
    case 'W': return {{"#   #", "#   #", "#   #", "# # #", "# # #", "## ##", "#   #"}};
    case 'X': return {{"#   #", "#   #", " # # ", "  #  ", " # # ", "#   #", "#   #"}};
    case 'Y': return {{"#   #", "#   #", " # # ", "  #  ", "  #  ", "  #  ", "  #  "}};
    case 'Z': return {{"#####", "    #", "   # ", "  #  ", " #   ", "#    ", "#####"}};
    case '0': return {{" ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### "}};
    case '1': return {{"  #  ", " ##  ", "# #  ", "  #  ", "  #  ", "  #  ", "#####"}};
    case '2': return {{" ### ", "#   #", "    #", "   # ", "  #  ", " #   ", "#####"}};
    case '3': return {{"#### ", "    #", "    #", " ### ", "    #", "    #", "#### "}};
    case '4': return {{"#   #", "#   #", "#   #", "#####", "    #", "    #", "    #"}};
    case '5': return {{"#####", "#    ", "#    ", "#### ", "    #", "    #", "#### "}};
    case '6': return {{" ### ", "#    ", "#    ", "#### ", "#   #", "#   #", " ### "}};
    case '7': return {{"#####", "    #", "   # ", "  #  ", " #   ", " #   ", " #   "}};
    case '8': return {{" ### ", "#   #", "#   #", " ### ", "#   #", "#   #", " ### "}};
    case '9': return {{" ### ", "#   #", "#   #", " ####", "    #", "    #", " ### "}};
    case '.': return {{"     ", "     ", "     ", "     ", "     ", " ##  ", " ##  "}};
    case ':': return {{"     ", " ##  ", " ##  ", "     ", " ##  ", " ##  ", "     "}};
    case '-': return {{"     ", "     ", "     ", "#####", "     ", "     ", "     "}};
    case '+': return {{"     ", "  #  ", "  #  ", "#####", "  #  ", "  #  ", "     "}};
    case '/': return {{"    #", "    #", "   # ", "  #  ", " #   ", "#    ", "#    "}};
    case '%': return {{"##  #", "## # ", "  #  ", " #   ", "#    ", "#  ##", "   ##"}};
    default: return {{"     ", "     ", "     ", "     ", "     ", "     ", "     "}};
    }
}

int textWidth(const char* text, int scale) {
    int count = 0;
    while (text[count] != '\0') {
        ++count;
    }
    return count > 0 ? count * 6 * scale - scale : 0;
}

void drawText(std::vector<std::uint32_t>& pixels, int x, int y, const char* text, int scale, float r, float g, float b, float alpha = 1.0f) {
    int cursorX = x;
    for (int i = 0; text[i] != '\0'; ++i) {
        const Glyph glyph = glyphFor(text[i]);
        for (int row = 0; row < 7; ++row) {
            for (int col = 0; col < 5; ++col) {
                if (glyph.rows[row][col] != ' ') {
                    for (int py = 0; py < scale; ++py) {
                        for (int px = 0; px < scale; ++px) {
                            blendPixel(pixels, cursorX + col * scale + px, y + row * scale + py, r, g, b, alpha);
                        }
                    }
                }
            }
        }
        cursorX += 6 * scale;
    }
}

void drawClippedText(std::vector<std::uint32_t>& pixels, int x, int y, const char* text, int maxChars, int scale, float r, float g, float b, float alpha = 1.0f) {
    char clipped[160] = {};
    const int limit = std::max(0, std::min(maxChars, static_cast<int>(sizeof(clipped)) - 1));
    std::memcpy(clipped, text, static_cast<std::size_t>(limit));
    clipped[limit] = '\0';
    drawText(pixels, x, y, clipped, scale, r, g, b, alpha);
}

void drawCenteredText(std::vector<std::uint32_t>& pixels, const UiRect& rect, const char* text, int scale, float r, float g, float b, float alpha = 1.0f) {
    const int x = rect.x + (rect.w - textWidth(text, scale)) / 2;
    const int y = rect.y + (rect.h - 7 * scale) / 2;
    drawText(pixels, x, y, text, scale, r, g, b, alpha);
}

void drawCircle(std::vector<std::uint32_t>& pixels, float cx, float cy, float radius, float r, float g, float b, float alpha) {
    const int minX = static_cast<int>(std::floor((cx - radius - 0.004f) * kFrameWidth));
    const int maxX = static_cast<int>(std::ceil((cx + radius + 0.004f) * kFrameWidth));
    const int minY = static_cast<int>(std::floor((cy - radius - 0.004f) * kFrameHeight));
    const int maxY = static_cast<int>(std::ceil((cy + radius + 0.004f) * kFrameHeight));
    for (int y = minY; y <= maxY; ++y) {
        for (int x = minX; x <= maxX; ++x) {
            const float ux = (static_cast<float>(x) + 0.5f) / static_cast<float>(kFrameWidth);
            const float uy = (static_cast<float>(y) + 0.5f) / static_cast<float>(kFrameHeight);
            const float dx = ux - cx;
            const float dy = uy - cy;
            const float d = std::sqrt(dx * dx + dy * dy);
            const float ring = 1.0f - clampf(std::fabs(d - radius) / 0.006f, 0.0f, 1.0f);
            blendPixel(pixels, x, y, r, g, b, alpha * ring);
        }
    }
}

void drawLine(std::vector<std::uint32_t>& pixels, float ax, float ay, float bx, float by, float r, float g, float b, float alpha) {
    const int minX = static_cast<int>(std::floor(std::min(ax, bx) * kFrameWidth)) - 8;
    const int maxX = static_cast<int>(std::ceil(std::max(ax, bx) * kFrameWidth)) + 8;
    const int minY = static_cast<int>(std::floor(std::min(ay, by) * kFrameHeight)) - 8;
    const int maxY = static_cast<int>(std::ceil(std::max(ay, by) * kFrameHeight)) + 8;
    const float vx = bx - ax;
    const float vy = by - ay;
    const float vv = std::max(0.000001f, vx * vx + vy * vy);
    for (int y = minY; y <= maxY; ++y) {
        for (int x = minX; x <= maxX; ++x) {
            const float ux = (static_cast<float>(x) + 0.5f) / static_cast<float>(kFrameWidth);
            const float uy = (static_cast<float>(y) + 0.5f) / static_cast<float>(kFrameHeight);
            const float h = clampf(((ux - ax) * vx + (uy - ay) * vy) / vv, 0.0f, 1.0f);
            const float dx = ux - (ax + vx * h);
            const float dy = uy - (ay + vy * h);
            const float d = std::sqrt(dx * dx + dy * dy);
            blendPixel(pixels, x, y, r, g, b, alpha * (1.0f - clampf(d / 0.006f, 0.0f, 1.0f)));
        }
    }
}

const char* toolName(int tool) {
    switch (tool) {
    case 1: return "FIRE";
    case 2: return "SMOKE";
    case 3: return "WIND";
    case 4: return "TURB";
    default: return "NONE";
    }
}

const char* renderDebugName(int mode) {
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

const char* sceneName(int scene) {
    switch (scene) {
    case 1: return "CAMPFIRE";
    case 2: return "GAS BURNER";
    default: return "ROOM";
    }
}

const char* transitionReasonName(RuntimeTransitionReason reason) {
    switch (reason) {
    case RuntimeTransitionReason::SceneSwitch: return "scene-switch";
    case RuntimeTransitionReason::UserReset: return "user-reset";
    case RuntimeTransitionReason::WorkerStale: return "worker-stale";
    case RuntimeTransitionReason::WorkerFrameCopied: return "worker-frame-copied";
    case RuntimeTransitionReason::OverlayChanged: return "overlay-changed";
    default: return "startup";
    }
}

void applyRuntimeTransition(RuntimeTransitionReason reason) {
    g_runtimeState.sceneId = g_activeScene;
    g_runtimeState.debugMode = g_renderDebugMode;
    g_runtimeState.activeGizmo = g_activeGizmo;
    g_runtimeState.needsReset = g_needsReset || g_resetFramesRemaining > 0;
    g_runtimeState.cudaWorkerLive = g_cudaWorkerFrameLive;
    g_runtimeState.uiOverlayDirty = !g_haveLastOverlaySettings || !g_uiTextureUploaded;
    g_runtimeState.lastReason = reason;
    ++g_runtimeState.transitionCount;
}

void requestSimulationReset() {
    g_needsReset = true;
    g_resetFramesRemaining = 3;
    invalidateDisplayedCudaFrame();
    g_haveLastWorkerSettings = false;
    g_haveLastOverlaySettings = false;
    g_uiTextureUploaded = false;
    applyRuntimeTransition(RuntimeTransitionReason::UserReset);
}

void switchScene(int scene) {
    const int nextScene = std::max(0, std::min(kSceneCount - 1, scene));
    if (g_activeScene == nextScene) {
        return;
    }
    g_activeScene = nextScene;
    stopCudaWorker();
    g_lastWorkerStartTickMs = 0;
    requestSimulationReset();
    applyRuntimeTransition(RuntimeTransitionReason::SceneSwitch);
}

void drawSceneDebugOverlay(std::vector<std::uint32_t>& pixels, const FireSettings& settings, bool cleanViewport);

void drawToolButton(std::vector<std::uint32_t>& pixels, const UiRect& rect, int tool, const char* label, int activeTool) {
    const bool active = activeTool == tool;
    fillRect(pixels, rect, active ? 0.105f : 0.048f, active ? 0.059f : 0.050f, active ? 0.037f : 0.052f, 1.0f);
    strokeRect(pixels, rect, active ? 1.0f : 0.20f, active ? 0.42f : 0.22f, active ? 0.08f : 0.24f, active ? 0.95f : 0.70f);

    const int cx = rect.x + rect.w / 2;
    const int cy = rect.y + 20;
    if (tool == 1) {
        drawCirclePx(pixels, cx, cy, 11, 1.0f, 0.30f, 0.05f, active ? 1.0f : 0.70f);
        drawLinePx(pixels, cx - 5, cy + 10, cx + 4, cy - 12, 1.0f, 0.65f, 0.08f, active ? 0.85f : 0.45f);
    } else if (tool == 2) {
        drawCirclePx(pixels, cx - 8, cy + 2, 9, 0.78f, 0.80f, 0.82f, active ? 0.95f : 0.58f);
        drawCirclePx(pixels, cx + 8, cy - 3, 12, 0.60f, 0.62f, 0.65f, active ? 0.80f : 0.42f);
    } else if (tool == 3) {
        drawLinePx(pixels, rect.x + 13, cy, rect.x + rect.w - 14, cy, 0.05f, 0.86f, 1.0f, active ? 0.95f : 0.55f);
        drawLinePx(pixels, rect.x + rect.w - 14, cy, rect.x + rect.w - 23, cy - 8, 0.05f, 0.86f, 1.0f, active ? 0.95f : 0.55f);
        drawLinePx(pixels, rect.x + rect.w - 14, cy, rect.x + rect.w - 23, cy + 8, 0.05f, 0.86f, 1.0f, active ? 0.95f : 0.55f);
    } else {
        drawCirclePx(pixels, cx, cy, 12, 0.85f, 0.25f, 0.96f, active ? 0.95f : 0.55f);
        drawLinePx(pixels, cx - 12, cy + 8, cx + 12, cy - 9, 0.95f, 0.48f, 1.0f, active ? 0.90f : 0.48f);
    }

    drawCenteredText(pixels, {rect.x, rect.y + 42, rect.w, 18}, label, 1, 0.88f, 0.90f, 0.86f, active ? 0.98f : 0.70f);
}

void drawCommandButton(std::vector<std::uint32_t>& pixels, const UiRect& rect, const char* label, bool active) {
    fillRect(pixels, rect, active ? 0.080f : 0.046f, active ? 0.078f : 0.048f, active ? 0.064f : 0.050f, 1.0f);
    strokeRect(pixels, rect, active ? 0.78f : 0.22f, active ? 0.74f : 0.24f, active ? 0.55f : 0.25f, active ? 0.90f : 0.70f);
    drawCenteredText(pixels, rect, label, 1, 0.84f, 0.85f, 0.80f, 0.92f);
}

void drawSceneButton(std::vector<std::uint32_t>& pixels, const UiRect& rect, const char* label, bool active) {
    fillRect(pixels, rect, active ? 0.036f : 0.023f, active ? 0.052f : 0.026f, active ? 0.070f : 0.028f, active ? 0.95f : 0.76f);
    strokeRect(pixels, rect, active ? 0.38f : 0.16f, active ? 0.66f : 0.18f, active ? 1.00f : 0.20f, active ? 0.92f : 0.68f);
    drawCenteredText(pixels, rect, label, 1, active ? 0.62f : 0.54f, active ? 0.78f : 0.58f, active ? 1.0f : 0.62f, active ? 0.96f : 0.78f);
}

void drawSlider(std::vector<std::uint32_t>& pixels, const UiRect& rect, float normalized, float cr, float cg, float cb) {
    normalized = clamp01(normalized);
    fillRect(pixels, rect, 0.030f, 0.032f, 0.033f, 1.0f);
    fillRect(pixels, {rect.x, rect.y, static_cast<int>(static_cast<float>(rect.w) * normalized), rect.h}, cr * 0.45f, cg * 0.45f, cb * 0.45f, 1.0f);
    strokeRect(pixels, rect, 0.20f, 0.21f, 0.20f, 0.82f);
    const int thumbX = rect.x + static_cast<int>(static_cast<float>(rect.w) * normalized);
    fillRect(pixels, {thumbX - 3, rect.y - 5, 6, rect.h + 10}, cr, cg, cb, 0.96f);
}

void blitViewport(std::vector<std::uint32_t>& pixels, const std::vector<std::uint32_t>& simPixels) {
    if (simPixels.size() < static_cast<std::size_t>(kFrameWidth * kFrameHeight)) {
        return;
    }
    for (int y = 0; y < kViewportRect.h; ++y) {
        const int srcY = y * kFrameHeight / std::max(1, kViewportRect.h);
        for (int x = 0; x < kViewportRect.w; ++x) {
            const int srcX = x * kFrameWidth / std::max(1, kViewportRect.w);
            pixels[static_cast<std::size_t>(kViewportRect.y + y) * kFrameWidth + kViewportRect.x + x] =
                simPixels[static_cast<std::size_t>(srcY) * kFrameWidth + srcX];
        }
    }
}

void drawViewportOverlays(std::vector<std::uint32_t>& pixels, const FireSettings& settings) {
    if (settings.showGizmos == 0) {
        return;
    }

    const int cx = kViewportRect.x + static_cast<int>(clamp01(settings.mouseX) * static_cast<float>(kViewportRect.w));
    const int cy = kViewportRect.y + static_cast<int>((1.0f - clamp01(settings.mouseY)) * static_cast<float>(kViewportRect.h));
    if (settings.activeGizmo == 1) {
        drawCirclePx(pixels, cx, cy, 13, 1.0f, 0.32f, 0.04f, 0.78f);
    } else if (settings.activeGizmo == 2) {
        drawCirclePx(pixels, cx, cy, 13, 0.72f, 0.74f, 0.76f, 0.68f);
    }

    const int ax = kViewportRect.x + kViewportRect.w - 78;
    const int ay = kViewportRect.y + kViewportRect.h - 36;
    drawLinePx(pixels, ax, ay, ax + 44, ay, 1.0f, 0.12f, 0.08f, 0.86f);
    drawLinePx(pixels, ax, ay, ax, ay - 42, 0.18f, 1.0f, 0.25f, 0.86f);
    drawLinePx(pixels, ax, ay, ax - 30, ay + 20, 0.20f, 0.42f, 1.0f, 0.86f);
}

void drawAppChrome(std::vector<std::uint32_t>& pixels, const FireSettings& settings, bool cudaBackend, bool cleanViewport) {
    if (cleanViewport) {
        return;
    }

    fillRect(pixels, kRailRect, 0.020f, 0.022f, 0.022f, 0.74f);
    fillRect(pixels, kTopBarRect, 0.018f, 0.019f, 0.019f, 0.70f);
    fillRect(pixels, kInspectorRect, 0.020f, 0.022f, 0.022f, 0.72f);
    fillRect(pixels, kStatusRect, 0.018f, 0.020f, 0.020f, 0.68f);
    strokeRect(pixels, kRailRect, 0.15f, 0.16f, 0.15f, 0.75f);
    strokeRect(pixels, kTopBarRect, 0.15f, 0.16f, 0.15f, 0.75f);
    strokeRect(pixels, kInspectorRect, 0.15f, 0.16f, 0.15f, 0.75f);
    strokeRect(pixels, kStatusRect, 0.15f, 0.16f, 0.15f, 0.75f);

    drawViewportOverlays(pixels, settings);

    drawText(pixels, 30, 26, "NATIVE FIRESIM", 1, 0.88f, 0.90f, 0.84f, 0.96f);
    drawText(pixels, 224, 26, cudaBackend ? "CUDA 3D FP16 D3D" : "NO LIVE CUDA FRAME", 1, cudaBackend ? 0.55f : 0.46f, cudaBackend ? 0.76f : 0.88f, cudaBackend ? 1.0f : 0.58f, 0.92f);
    drawSceneButton(pixels, kSceneButtonRects[0], "ROOM", settings.sceneId == 0);
    drawSceneButton(pixels, kSceneButtonRects[1], "CAMP", settings.sceneId == 1);
    drawSceneButton(pixels, kSceneButtonRects[2], "BURNER", settings.sceneId == 2);
    drawText(pixels, 640, 26, cudaBackend ? "RMB ORBIT   WHEEL ZOOM" : "NO CUSTOM CUDA KERNELS", 1, 0.70f, 0.72f, 0.68f, 0.88f);

    drawCenteredText(pixels, {kRailRect.x, 78, kRailRect.w, 14}, "TOOLS", 1, 0.60f, 0.62f, 0.58f, 0.82f);
    drawToolButton(pixels, kToolButtonRects[0], 1, "FIRE", settings.activeGizmo);
    drawToolButton(pixels, kToolButtonRects[1], 2, "SMOKE", settings.activeGizmo);
    drawToolButton(pixels, kToolButtonRects[2], 3, "WIND", settings.activeGizmo);
    drawToolButton(pixels, kToolButtonRects[3], 4, "TURB", settings.activeGizmo);
    drawCommandButton(pixels, kOverlayButtonRect, "OVERLAY", settings.showGizmos != 0);
    drawCommandButton(pixels, kResetButtonRect, "RESET", false);

    drawText(pixels, 790, 92, "FIELD", 2, 0.86f, 0.88f, 0.82f, 0.95f);
    drawText(pixels, 790, 132, "ACTIVE", 1, 0.50f, 0.52f, 0.50f, 0.86f);
    drawText(pixels, 790, 150, toolName(settings.activeGizmo), 2, 0.96f, 0.65f, 0.26f, 0.95f);
    drawText(pixels, 790, 172, sceneName(settings.sceneId), 1, 0.54f, 0.74f, 1.0f, 0.86f);

    char value[32] = {};
    drawText(pixels, 790, 194, "WIND", 1, 0.64f, 0.82f, 0.88f, 0.88f);
    std::snprintf(value, sizeof(value), "%.2f", settings.wind);
    drawText(pixels, 866, 194, value, 1, 0.64f, 0.82f, 0.88f, 0.80f);
    drawSlider(pixels, kWindSliderRect, (settings.wind + 1.0f) * 0.5f, 0.05f, 0.86f, 1.0f);

    drawText(pixels, 790, 284, "TURBULENCE", 1, 0.86f, 0.60f, 0.95f, 0.88f);
    std::snprintf(value, sizeof(value), "%.2f", settings.turbulence);
    drawText(pixels, 876, 284, value, 1, 0.86f, 0.60f, 0.95f, 0.80f);
    drawSlider(pixels, kTurbulenceSliderRect, (settings.turbulence - 0.05f) / 1.45f, 0.85f, 0.25f, 0.96f);

    drawText(pixels, 790, 360, "DRAG SLIDERS", 1, 0.54f, 0.56f, 0.53f, 0.78f);
    drawText(pixels, 790, 378, "OR KEYS 1-4", 1, 0.54f, 0.56f, 0.53f, 0.78f);

    drawText(
        pixels,
        276,
        486,
        cudaBackend ? "REAL CUDA WORKER VOLUME   S SCENE   D DEBUG   C CLEAN   G OVERLAY   R RESET   ESC QUIT" : "NO LIVE CUDA FRAME   S SCENE   WORKER STARTING/STALE   D DEBUG   C CLEAN",
        1,
        0.76f,
        0.78f,
        0.72f,
        0.88f);
    drawText(pixels, 276, 506, renderDebugName(settings.renderDebugMode), 1, 0.86f, 0.84f, 0.62f, 0.88f);
    drawClippedText(pixels, 330, 506, g_workerUiStatus, 74, 1, cudaBackend ? 0.46f : 0.90f, cudaBackend ? 0.80f : 0.60f, cudaBackend ? 0.58f : 0.34f, 0.88f);
}

void composeAppFrame(std::vector<std::uint32_t>& pixels, const std::vector<std::uint32_t>& simPixels, const FireSettings& settings, bool cudaBackend, bool cleanViewport = false) {
    std::fill(pixels.begin(), pixels.end(), packBgra(0.015f, 0.016f, 0.016f));
    blitViewport(pixels, simPixels);
    drawSceneDebugOverlay(pixels, settings, cleanViewport);
    drawAppChrome(pixels, settings, cudaBackend, cleanViewport);
}

void composeD3DOverlayFrame(std::vector<std::uint32_t>& pixels, const FireSettings& settings, bool cudaBackend, bool cleanViewport) {
    std::fill(pixels.begin(), pixels.end(), 0u);
    drawSceneDebugOverlay(pixels, settings, cleanViewport);
    drawAppChrome(pixels, settings, cudaBackend, cleanViewport);
}

int hitTestToolButton(int frameX, int frameY) {
    for (int i = 0; i < 4; ++i) {
        if (contains(kToolButtonRects[i], frameX, frameY)) {
            return i + 1;
        }
    }
    return 0;
}

int hitTestCommandButton(int frameX, int frameY) {
    if (contains(kOverlayButtonRect, frameX, frameY)) {
        return 1;
    }
    if (contains(kResetButtonRect, frameX, frameY)) {
        return 2;
    }
    return 0;
}

int hitTestSceneButton(int frameX, int frameY) {
    for (int i = 0; i < kSceneCount; ++i) {
        if (contains(kSceneButtonRects[i], frameX, frameY)) {
            return i;
        }
    }
    return -1;
}

int hitTestSlider(int frameX, int frameY) {
    const UiRect windHit = {kWindSliderRect.x - 8, kWindSliderRect.y - 14, kWindSliderRect.w + 16, kWindSliderRect.h + 28};
    const UiRect turbulenceHit = {kTurbulenceSliderRect.x - 8, kTurbulenceSliderRect.y - 14, kTurbulenceSliderRect.w + 16, kTurbulenceSliderRect.h + 28};
    if (contains(windHit, frameX, frameY)) {
        return 3;
    }
    if (contains(turbulenceHit, frameX, frameY)) {
        return 4;
    }
    return 0;
}

void applyPanelDrag() {
    if (g_dragControl == 3) {
        const float t = clamp01(static_cast<float>(g_pointerFrameX - kWindSliderRect.x) / static_cast<float>(std::max(1, kWindSliderRect.w)));
        g_wind = t * 2.0f - 1.0f;
    } else if (g_dragControl == 4) {
        const float t = clamp01(static_cast<float>(g_pointerFrameX - kTurbulenceSliderRect.x) / static_cast<float>(std::max(1, kTurbulenceSliderRect.w)));
        g_turbulence = 0.05f + t * 1.45f;
    }
}

void updateMouseFromLParam(LPARAM lParam) {
    const int x = GET_X_LPARAM(lParam);
    const int y = GET_Y_LPARAM(lParam);
    g_lastMouseX = x;
    g_lastMouseY = y;
    g_pointerFrameX = static_cast<int>(static_cast<float>(x) * static_cast<float>(kFrameWidth) / static_cast<float>(std::max(1, g_clientW)));
    g_pointerFrameY = static_cast<int>(static_cast<float>(y) * static_cast<float>(kFrameHeight) / static_cast<float>(std::max(1, g_clientH)));
    g_pointerInViewport = contains(kViewportRect, g_pointerFrameX, g_pointerFrameY);
    g_mouseX = clamp01(static_cast<float>(g_pointerFrameX - kViewportRect.x) / static_cast<float>(std::max(1, kViewportRect.w)));
    g_mouseY = clamp01(1.0f - static_cast<float>(g_pointerFrameY - kViewportRect.y) / static_cast<float>(std::max(1, kViewportRect.h)));
}

void updateTitle(float fps) {
    char title[256] = {};
    const double displayedFps = g_useCudaBackend
        ? (g_visualFps > 0.0f ? static_cast<double>(g_visualFps) : static_cast<double>(fps))
        : static_cast<double>(fps);
    std::snprintf(
        title,
        sizeof(title),
        "Native FireSim %s | %s | present %.0fhz | worker %.0fhz | copy %.0fhz | reuse %.0fhz | ring %ld>%ld | age %llums | %s | %.44s",
        g_useCudaBackend ? "CUDA 3D volume" : "CUDA worker waiting",
        fireStreamHealthLabel(),
        displayedFps,
        g_workerPublishedHz,
        g_liveCopiedHz,
        g_liveReusedPresentHz,
        static_cast<long>(g_sharedRingLastCopiedSharedSlot),
        static_cast<long>(g_sharedRingLastCopiedDisplaySlot),
        g_displayFrameAgeMs,
        sceneName(g_activeScene),
        g_workerUiStatus);
    SetWindowTextA(g_window, title);
}

std::string hresultString(HRESULT hr) {
    char text[32] = {};
    std::snprintf(text, sizeof(text), "0x%08lx", static_cast<unsigned long>(hr));
    return text;
}

bool waitForD3DCompletion(ID3D11DeviceContext* context, ID3D11Query* query) {
    if (context == nullptr || query == nullptr) {
        return false;
    }
    context->End(query);
    context->Flush();
    for (;;) {
        const HRESULT hr = context->GetData(query, nullptr, 0, 0);
        if (hr == S_OK) {
            return true;
        }
        if (hr != S_FALSE) {
            return false;
        }
        Sleep(0);
    }
}

bool createD3DDevice(ComPtr<ID3D11Device>& device, ComPtr<ID3D11DeviceContext>& context) {
    ComPtr<IDXGIFactory1> factory;
    if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void**>(factory.GetAddressOf())))) {
        return false;
    }

    ComPtr<IDXGIAdapter1> bestAdapter;
    SIZE_T bestMemory = 0;
    for (UINT i = 0;; ++i) {
        ComPtr<IDXGIAdapter1> adapter;
        if (factory->EnumAdapters1(i, adapter.GetAddressOf()) == DXGI_ERROR_NOT_FOUND) {
            break;
        }
        DXGI_ADAPTER_DESC1 desc = {};
        if (FAILED(adapter->GetDesc1(&desc)) || (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0) {
            continue;
        }
        if (desc.DedicatedVideoMemory >= bestMemory) {
            bestMemory = desc.DedicatedVideoMemory;
            bestAdapter = adapter;
        }
    }

    constexpr D3D_FEATURE_LEVEL kFeatureLevels[] = {
        D3D_FEATURE_LEVEL_11_1,
        D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1,
        D3D_FEATURE_LEVEL_10_0,
    };
    D3D_FEATURE_LEVEL createdLevel = D3D_FEATURE_LEVEL_10_0;
    const UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    HRESULT hr = E_FAIL;
    if (bestAdapter != nullptr) {
        hr = D3D11CreateDevice(
            bestAdapter.Get(),
            D3D_DRIVER_TYPE_UNKNOWN,
            nullptr,
            flags,
            kFeatureLevels,
            static_cast<UINT>(sizeof(kFeatureLevels) / sizeof(kFeatureLevels[0])),
            D3D11_SDK_VERSION,
            device.GetAddressOf(),
            &createdLevel,
            context.GetAddressOf());
    }
    if (FAILED(hr)) {
        hr = D3D11CreateDevice(
            nullptr,
            D3D_DRIVER_TYPE_HARDWARE,
            nullptr,
            flags,
            kFeatureLevels,
            static_cast<UINT>(sizeof(kFeatureLevels) / sizeof(kFeatureLevels[0])),
            D3D11_SDK_VERSION,
            device.GetAddressOf(),
            &createdLevel,
            context.GetAddressOf());
    }
    return SUCCEEDED(hr);
}

bool compileShader(const char* source, const char* entry, const char* target, ComPtr<ID3DBlob>& blob) {
    ComPtr<ID3DBlob> errors;
    const UINT flags = D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3;
    const HRESULT hr = D3DCompile(
        source,
        std::strlen(source),
        nullptr,
        nullptr,
        nullptr,
        entry,
        target,
        flags,
        0,
        blob.GetAddressOf(),
        errors.GetAddressOf());
    if (FAILED(hr)) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "D3D shader compile failed: %s", hresultString(hr).c_str());
        return false;
    }
    return true;
}

std::string readTextFile(const std::filesystem::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return {};
    }
    std::ostringstream buffer;
    buffer << in.rdbuf();
    return buffer.str();
}

std::string jsonArrayForKey(const std::string& text, const char* key) {
    const std::string needle = std::string("\"") + key + "\"";
    const std::size_t keyPos = text.find(needle);
    if (keyPos == std::string::npos) {
        return {};
    }
    const std::size_t start = text.find('[', keyPos);
    if (start == std::string::npos) {
        return {};
    }
    int depth = 0;
    for (std::size_t i = start; i < text.size(); ++i) {
        if (text[i] == '[') {
            ++depth;
        } else if (text[i] == ']') {
            --depth;
            if (depth == 0) {
                return text.substr(start, i - start + 1);
            }
        }
    }
    return {};
}

std::string jsonObjectForKey(const std::string& text, const char* key) {
    const std::string needle = std::string("\"") + key + "\"";
    const std::size_t keyPos = text.find(needle);
    if (keyPos == std::string::npos) {
        return {};
    }
    const std::size_t start = text.find('{', keyPos);
    if (start == std::string::npos) {
        return {};
    }
    int depth = 0;
    bool inString = false;
    bool escaped = false;
    for (std::size_t i = start; i < text.size(); ++i) {
        const char c = text[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = inString;
            continue;
        }
        if (c == '"') {
            inString = !inString;
            continue;
        }
        if (inString) {
            continue;
        }
        if (c == '{') {
            ++depth;
        } else if (c == '}') {
            --depth;
            if (depth == 0) {
                return text.substr(start, i - start + 1);
            }
        }
    }
    return {};
}

std::vector<float> parseJsonFloats(const std::string& text) {
    std::vector<float> values;
    const char* ptr = text.c_str();
    char* end = nullptr;
    while (*ptr != '\0') {
        const float value = std::strtof(ptr, &end);
        if (end != ptr) {
            values.push_back(value);
            ptr = end;
        } else {
            ++ptr;
        }
    }
    return values;
}

std::vector<std::uint32_t> parseJsonUInts(const std::string& text) {
    std::vector<std::uint32_t> values;
    const char* ptr = text.c_str();
    char* end = nullptr;
    while (*ptr != '\0') {
        const unsigned long value = std::strtoul(ptr, &end, 10);
        if (end != ptr) {
            values.push_back(static_cast<std::uint32_t>(value));
            ptr = end;
        } else {
            ++ptr;
        }
    }
    return values;
}

bool jsonNumberForKey(const std::string& text, const char* key, float& out) {
    const std::string needle = std::string("\"") + key + "\"";
    const std::size_t keyPos = text.find(needle);
    if (keyPos == std::string::npos) {
        return false;
    }
    const std::size_t colon = text.find(':', keyPos + needle.size());
    if (colon == std::string::npos) {
        return false;
    }
    const char* start = text.c_str() + colon + 1;
    char* end = nullptr;
    const float value = std::strtof(start, &end);
    if (end == start) {
        return false;
    }
    out = value;
    return true;
}

const char* runtimeMeshAssetId(int sceneId) {
    switch (sceneId) {
    case 1: return "campfire";
    case 2: return "gas-burner-aver1";
    case 0: return "room";
    default: return "";
    }
}

std::filesystem::path runtimeSceneDirectory(int sceneId) {
    const char* assetId = runtimeMeshAssetId(sceneId);
    if (assetId[0] == '\0') {
        return {};
    }
    return std::filesystem::path("assets") / "fire-scenes" / assetId;
}

std::string readSceneContract(int sceneId) {
    const std::filesystem::path dir = runtimeSceneDirectory(sceneId);
    if (dir.empty()) {
        return {};
    }
    return readTextFile(dir / "scene.json");
}

std::array<float, 3> jsonTripletForKey(const std::string& text, const char* key, std::array<float, 3> fallback) {
    const std::vector<float> values = parseJsonFloats(jsonArrayForKey(text, key));
    if (values.size() >= 3) {
        return {values[0], values[1], values[2]};
    }
    return fallback;
}

std::array<float, 3> sceneMeshTranslationMeters(int sceneId, const std::string& sceneContract) {
    return jsonTripletForKey(sceneContract, "translationMeters", {0.0f, sceneId == 2 ? -0.24f : 0.0f, 0.0f});
}

std::array<float, 3> applySceneMeshTranslation(const std::array<float, 3>& point, const std::array<float, 3>& translation) {
    return {
        point[0] + translation[0],
        point[1] + translation[1],
        point[2] + translation[2],
    };
}

bool loadRuntimeSceneMesh(int sceneId, RuntimeSceneMesh& mesh) {
    mesh = {};
    const char* assetId = runtimeMeshAssetId(sceneId);
    if (assetId[0] == '\0' || sceneId == 0) {
        return false;
    }
    const std::filesystem::path sceneDir = runtimeSceneDirectory(sceneId);
    const std::filesystem::path path = sceneDir / "runtime-mesh.json";
    const std::string text = readTextFile(path);
    if (text.empty()) {
        return false;
    }
    const std::string sceneContract = readSceneContract(sceneId);
    const std::array<float, 3> meshTranslation = sceneMeshTranslationMeters(sceneId, sceneContract);
    const std::vector<float> positions = parseJsonFloats(jsonArrayForKey(text, "vertices"));
    const std::vector<float> normals = parseJsonFloats(jsonArrayForKey(text, "normals"));
    const std::vector<float> colors = parseJsonFloats(jsonArrayForKey(text, "colors"));
    const std::vector<std::uint32_t> indices = parseJsonUInts(jsonArrayForKey(text, "triangles"));
    if (positions.size() < 9 || positions.size() % 3 != 0 || indices.size() < 3 || indices.size() % 3 != 0) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "runtime mesh parse failed for scene %d", sceneId);
        return false;
    }
    const std::size_t vertexCount = positions.size() / 3;
    mesh.vertices.resize(vertexCount);
    for (std::size_t i = 0; i < vertexCount; ++i) {
        const std::array<float, 3> simPoint = applySceneMeshTranslation(
            {positions[i * 3 + 0], positions[i * 3 + 1], positions[i * 3 + 2]},
            meshTranslation);
        mesh.vertices[i].px = simPoint[0];
        mesh.vertices[i].py = simPoint[1];
        mesh.vertices[i].pz = simPoint[2];
        mesh.vertices[i].nx = normals.size() >= positions.size() ? normals[i * 3 + 0] : 0.0f;
        mesh.vertices[i].ny = normals.size() >= positions.size() ? normals[i * 3 + 1] : 1.0f;
        mesh.vertices[i].nz = normals.size() >= positions.size() ? normals[i * 3 + 2] : 0.0f;
        mesh.vertices[i].cr = colors.size() >= positions.size() ? colors[i * 3 + 0] : 0.55f;
        mesh.vertices[i].cg = colors.size() >= positions.size() ? colors[i * 3 + 1] : 0.55f;
        mesh.vertices[i].cb = colors.size() >= positions.size() ? colors[i * 3 + 2] : 0.55f;
        if (sceneId == 2) {
            mesh.vertices[i].cr = 0.035f;
            mesh.vertices[i].cg = 0.036f;
            mesh.vertices[i].cb = 0.039f;
        }
        if (i == 0) {
            mesh.minX = mesh.maxX = mesh.vertices[i].px;
            mesh.minY = mesh.maxY = mesh.vertices[i].py;
            mesh.minZ = mesh.maxZ = mesh.vertices[i].pz;
        } else {
            mesh.minX = std::min(mesh.minX, mesh.vertices[i].px);
            mesh.minY = std::min(mesh.minY, mesh.vertices[i].py);
            mesh.minZ = std::min(mesh.minZ, mesh.vertices[i].pz);
            mesh.maxX = std::max(mesh.maxX, mesh.vertices[i].px);
            mesh.maxY = std::max(mesh.maxY, mesh.vertices[i].py);
            mesh.maxZ = std::max(mesh.maxZ, mesh.vertices[i].pz);
        }
    }
    mesh.indices = indices;
    mesh.loaded = true;
    return true;
}

bool createMeshBuffers(RuntimeSceneMesh& mesh) {
    if (!mesh.loaded || mesh.vertices.empty() || mesh.indices.empty()) {
        return false;
    }
    D3D11_BUFFER_DESC vbDesc = {};
    vbDesc.ByteWidth = static_cast<UINT>(mesh.vertices.size() * sizeof(MeshVertex));
    vbDesc.Usage = D3D11_USAGE_DEFAULT;
    vbDesc.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    D3D11_SUBRESOURCE_DATA vbData = {};
    vbData.pSysMem = mesh.vertices.data();
    if (FAILED(g_d3d.device->CreateBuffer(&vbDesc, &vbData, mesh.vertexBuffer.GetAddressOf()))) {
        return false;
    }
    D3D11_BUFFER_DESC ibDesc = {};
    ibDesc.ByteWidth = static_cast<UINT>(mesh.indices.size() * sizeof(std::uint32_t));
    ibDesc.Usage = D3D11_USAGE_DEFAULT;
    ibDesc.BindFlags = D3D11_BIND_INDEX_BUFFER;
    D3D11_SUBRESOURCE_DATA ibData = {};
    ibData.pSysMem = mesh.indices.data();
    if (FAILED(g_d3d.device->CreateBuffer(&ibDesc, &ibData, mesh.indexBuffer.GetAddressOf()))) {
        mesh.vertexBuffer.Reset();
        return false;
    }
    return true;
}

SceneEmitterParams loadSceneEmitterParams(int sceneId) {
    SceneEmitterParams params;
    const std::string sceneContract = readSceneContract(sceneId);
    if (!sceneContract.empty()) {
        const std::string emitterContract = jsonObjectForKey(sceneContract, "emitter");
        const std::string& emitterSource = emitterContract.empty() ? sceneContract : emitterContract;
        const std::array<float, 3> center = jsonTripletForKey(emitterSource, "centerMeters", {0.0f, 0.02f, 0.0f});
        params.centerX = center[0];
        params.centerZ = center[2];
        params.heightNorm = (center[1] - 0.02f) / 2.03f;
        float value = 0.0f;
        if (jsonNumberForKey(emitterSource, "radiusMeters", value)) {
            params.radius = value;
        }
        if (jsonNumberForKey(emitterSource, "heightBandMeters", value)) {
            params.heightBandNorm = value / 2.03f;
        }
    } else if (sceneId == 1) {
        params.radius = 0.32f;
        params.heightNorm = (0.045f - 0.02f) / 2.03f;
        params.heightBandNorm = 0.20f / 2.03f;
    } else if (sceneId == 2) {
        params.radius = 0.24f;
        params.heightNorm = (0.138f - 0.02f) / 2.03f;
        params.heightBandNorm = 0.105f / 2.03f;
    }

    const char* assetId = runtimeMeshAssetId(sceneId);
    if (assetId[0] == '\0' || sceneId == 0) {
        return params;
    }
    const std::filesystem::path path = runtimeSceneDirectory(sceneId) / "emitter-mask.json";
    const std::string text = readTextFile(path);
    if (text.empty()) {
        return params;
    }
    const std::array<float, 3> meshTranslation = sceneMeshTranslationMeters(sceneId, sceneContract);
    float value = 0.0f;
    if (jsonNumberForKey(text, "centerXMeters", value)) {
        params.centerX = value;
    }
    if (jsonNumberForKey(text, "centerZMeters", value)) {
        params.centerZ = value;
    }
    if (jsonNumberForKey(text, "centerYMeters", value)) {
        params.heightNorm = (value - 0.02f) / 2.03f;
    } else if (jsonNumberForKey(text, "worldHeightMeters", value)) {
        params.heightNorm = (value - 0.02f) / 2.03f;
    }
    if (jsonNumberForKey(text, "heightBandMeters", value)) {
        params.heightBandNorm = value / 2.03f;
    }
    if (jsonNumberForKey(text, "radiusMeters", value)) {
        params.radius = value;
    } else if (jsonNumberForKey(text, "radiusFraction", value)) {
        float width = 0.0f;
        float depth = 0.0f;
        if (jsonNumberForKey(text, "width", width) && jsonNumberForKey(text, "depth", depth)) {
            params.radius = value * std::max(width, depth);
        }
    }
    const std::vector<float> burnerCenters = parseJsonFloats(jsonArrayForKey(text, "burnerCentersMeters"));
    params.burnerCenterCount = static_cast<int>(std::min<std::size_t>(4, burnerCenters.size() / 3));
    for (int i = 0; i < params.burnerCenterCount; ++i) {
        const std::array<float, 3> burnerPoint = applySceneMeshTranslation(
            {
                burnerCenters[static_cast<std::size_t>(i) * 3 + 0],
                burnerCenters[static_cast<std::size_t>(i) * 3 + 1],
                burnerCenters[static_cast<std::size_t>(i) * 3 + 2],
            },
            meshTranslation);
        params.burnerCenterX[i] = burnerPoint[0];
        params.burnerCenterY[i] = burnerPoint[1];
        params.burnerCenterZ[i] = burnerPoint[2];
    }
    if (sceneId == 2 && params.burnerCenterCount > 0) {
        params.heightNorm = (params.burnerCenterY[0] - 0.02f) / 2.03f;
    }
    return params;
}

void loadRuntimeSceneMeshes() {
    for (int scene = 0; scene < kSceneCount; ++scene) {
        g_sceneEmitters[scene] = loadSceneEmitterParams(scene);
        RuntimeSceneMesh mesh;
        if (scene != 0 && (!loadRuntimeSceneMesh(scene, mesh) || !createMeshBuffers(mesh))) {
            std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "missing imported mesh for %s", runtimeMeshAssetId(scene));
            mesh = {};
        }
        g_sceneMeshes[scene] = std::move(mesh);
    }
}

const char* d3dShaderSource() {
    return R"HLSL(
#pragma pack_matrix(row_major)

struct VSOut {
    float4 pos : SV_POSITION;
    float2 uv : TEXCOORD0;
};

struct MeshVSIn {
    float3 pos : POSITION;
    float3 normal : NORMAL;
    float3 color : COLOR0;
};

struct MeshVSOut {
    float4 pos : SV_POSITION;
    float3 worldPos : TEXCOORD0;
    float3 normal : TEXCOORD1;
    float3 color : TEXCOORD2;
};

VSOut FullscreenVS(uint id : SV_VertexID) {
    float2 pos[3] = {
        float2(-1.0, -1.0),
        float2(-1.0,  3.0),
        float2( 3.0, -1.0)
    };
    VSOut outp;
    outp.pos = float4(pos[id], 0.0, 1.0);
    outp.uv = float2(pos[id].x * 0.5 + 0.5, 0.5 - pos[id].y * 0.5);
    return outp;
}

Texture2D<float4> FrameTex : register(t0);
SamplerState LinearSampler : register(s0);

cbuffer DisplayConstants : register(b0) {
    float Exposure;
    float3 _Padding;
}

cbuffer MeshConstants : register(b1) {
    float4x4 MeshViewProj;
    float4 MeshLightPos;
    float4 MeshBaseColor;
    float4 MeshFireColor;
    float4 MeshFireParams;
}

float Luma(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

float AcesCurve(float v) {
    return saturate((v * (2.51 * v + 0.03)) / (v * (2.43 * v + 0.59) + 0.14));
}

float3 ToneMapPreserveHue(float3 c) {
    float l = max(0.000001, Luma(c));
    return c * (AcesCurve(l) / l);
}

float3 CameraResponse(float3 radiance) {
    // This is the only display transform. UI and mesh passes stay outside this response.
    float3 color = ToneMapPreserveHue(max(radiance, 0.0) * Exposure);
    float l = Luma(color);
    float toe = smoothstep(0.000, 0.055, l);
    float shoulder = smoothstep(0.74, 1.0, l);
    color = lerp(color * 0.82, color, toe);
    color = lerp(color, color / max(1.0, l / 0.88), shoulder * 0.18);
    return pow(saturate(color), 1.0 / 2.2);
}

float4 SimPS(VSOut input) : SV_TARGET {
    float3 radiance = max(FrameTex.Sample(LinearSampler, input.uv).rgb, 0.0);
    return float4(CameraResponse(radiance), 1.0);
}

float4 UiPS(VSOut input) : SV_TARGET {
    return FrameTex.Sample(LinearSampler, input.uv);
}

MeshVSOut MeshVS(MeshVSIn input) {
    MeshVSOut outp;
    float4 wp = float4(input.pos, 1.0);
    outp.pos = mul(wp, MeshViewProj);
    outp.worldPos = input.pos;
    outp.normal = normalize(input.normal);
    outp.color = saturate(input.color);
    return outp;
}

float4 MeshPS(MeshVSOut input) : SV_TARGET {
    float3 n = normalize(input.normal);
    float3 l = normalize(MeshLightPos.xyz - input.worldPos);
    float3 v = normalize(float3(0.0, 0.85, 2.4) - input.worldPos);
    float ndl = saturate(dot(n, l));
    float rim = pow(saturate(1.0 - dot(n, v)), 2.2);
    float radial = length(input.worldPos.xz);
    float sourceRadius = max(MeshFireParams.x, 0.01);
    float sourceFalloff = exp(-(radial * radial) / (sourceRadius * sourceRadius));
    float lowSource = saturate(1.0 - input.worldPos.y * MeshFireParams.z);
    float3 toFire = normalize(float3(-input.worldPos.x, MeshLightPos.y - input.worldPos.y, -input.worldPos.z));
    float fireFacing = saturate(dot(n, toFire));
    float3 fireBounce = MeshFireColor.rgb * sourceFalloff * MeshFireParams.y * (0.30 + lowSource * 0.66 + fireFacing * 0.54);
    float3 coolFill = float3(0.015, 0.018, 0.024) * (0.22 + rim * 0.54);
    float3 material = max(input.color, MeshBaseColor.rgb);
    float3 color = material * (0.038 + ndl * 0.24 + rim * 0.04) + fireBounce + coolFill;
    float2 screenUv = saturate(input.pos.xy / float2(960.0, 540.0));
    float sceneLuma = Luma(FrameTex.Sample(LinearSampler, screenUv).rgb);
    float hotVolume = smoothstep(0.12, 0.55, sceneLuma);
    float alpha = MeshBaseColor.a * (1.0 - hotVolume * 0.82);
    return float4(color, alpha);
}
)HLSL";
}

bool initializeD3D(HWND hwnd) {
    if (g_d3d.initialized) {
        return true;
    }
    if (!createD3DDevice(g_d3d.device, g_d3d.context)) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "D3D11 device creation failed");
        return false;
    }

    ComPtr<IDXGIDevice> dxgiDevice;
    ComPtr<IDXGIAdapter> adapter;
    ComPtr<IDXGIFactory> factory;
    if (FAILED(g_d3d.device.As(&dxgiDevice)) ||
        FAILED(dxgiDevice->GetAdapter(adapter.GetAddressOf())) ||
        FAILED(adapter->GetParent(__uuidof(IDXGIFactory), reinterpret_cast<void**>(factory.GetAddressOf())))) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "D3D11 DXGI factory lookup failed");
        return false;
    }

    HRESULT hr = E_FAIL;
    ComPtr<IDXGIFactory2> factory2;
    if (SUCCEEDED(factory.As(&factory2))) {
        DXGI_SWAP_CHAIN_DESC1 flipDesc = {};
        flipDesc.Width = kFrameWidth;
        flipDesc.Height = kFrameHeight;
        flipDesc.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
        flipDesc.SampleDesc.Count = 1;
        flipDesc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        flipDesc.BufferCount = 3;
        flipDesc.Scaling = DXGI_SCALING_STRETCH;
        flipDesc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        flipDesc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
        ComPtr<IDXGISwapChain1> swapChain1;
        hr = factory2->CreateSwapChainForHwnd(
            g_d3d.device.Get(),
            hwnd,
            &flipDesc,
            nullptr,
            nullptr,
            swapChain1.GetAddressOf());
        if (SUCCEEDED(hr)) {
            hr = swapChain1.As(&g_d3d.swapChain);
        }
    }
    if (FAILED(hr)) {
        DXGI_SWAP_CHAIN_DESC swapDesc = {};
        swapDesc.BufferDesc.Width = kFrameWidth;
        swapDesc.BufferDesc.Height = kFrameHeight;
        swapDesc.BufferDesc.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
        swapDesc.BufferDesc.RefreshRate.Numerator = 0;
        swapDesc.BufferDesc.RefreshRate.Denominator = 1;
        swapDesc.SampleDesc.Count = 1;
        swapDesc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        swapDesc.BufferCount = 2;
        swapDesc.OutputWindow = hwnd;
        swapDesc.Windowed = TRUE;
        swapDesc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
        hr = factory->CreateSwapChain(g_d3d.device.Get(), &swapDesc, g_d3d.swapChain.GetAddressOf());
    }
    if (FAILED(hr)) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "FP16 swapchain failed: %s", hresultString(hr).c_str());
        return false;
    }
    factory->MakeWindowAssociation(hwnd, DXGI_MWA_NO_ALT_ENTER);

    ComPtr<ID3D11Texture2D> backBuffer;
    hr = g_d3d.swapChain->GetBuffer(0, __uuidof(ID3D11Texture2D), reinterpret_cast<void**>(backBuffer.GetAddressOf()));
    if (FAILED(hr) || FAILED(g_d3d.device->CreateRenderTargetView(backBuffer.Get(), nullptr, g_d3d.renderTargetView.GetAddressOf()))) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "D3D11 render target setup failed");
        return false;
    }

    D3D11_TEXTURE2D_DESC simDesc = {};
    simDesc.Width = kFrameWidth;
    simDesc.Height = kFrameHeight;
    simDesc.MipLevels = 1;
    simDesc.ArraySize = 1;
    simDesc.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
    simDesc.SampleDesc.Count = 1;
    simDesc.Usage = D3D11_USAGE_DEFAULT;
    simDesc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    for (int slot = 0; slot < kDisplayFrameSlots; ++slot) {
        hr = g_d3d.device->CreateTexture2D(&simDesc, nullptr, g_d3d.displaySimTextures[slot].GetAddressOf());
        if (FAILED(hr) || FAILED(g_d3d.device->CreateShaderResourceView(g_d3d.displaySimTextures[slot].Get(), nullptr, g_d3d.displaySimSrvs[slot].GetAddressOf()))) {
            std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "private FP16 display texture ring failed");
            return false;
        }
    }

    D3D11_TEXTURE2D_DESC uiDesc = {};
    uiDesc.Width = kFrameWidth;
    uiDesc.Height = kFrameHeight;
    uiDesc.MipLevels = 1;
    uiDesc.ArraySize = 1;
    uiDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    uiDesc.SampleDesc.Count = 1;
    uiDesc.Usage = D3D11_USAGE_DEFAULT;
    uiDesc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    hr = g_d3d.device->CreateTexture2D(&uiDesc, nullptr, g_d3d.uiTexture.GetAddressOf());
    if (FAILED(hr) || FAILED(g_d3d.device->CreateShaderResourceView(g_d3d.uiTexture.Get(), nullptr, g_d3d.uiSrv.GetAddressOf()))) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "D3D UI texture failed");
        return false;
    }

    D3D11_SAMPLER_DESC samplerDesc = {};
    samplerDesc.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    samplerDesc.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
    samplerDesc.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
    samplerDesc.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    samplerDesc.MaxLOD = D3D11_FLOAT32_MAX;
    if (FAILED(g_d3d.device->CreateSamplerState(&samplerDesc, g_d3d.sampler.GetAddressOf()))) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "D3D sampler creation failed");
        return false;
    }

    ComPtr<ID3DBlob> vsBlob;
    ComPtr<ID3DBlob> meshVsBlob;
    ComPtr<ID3DBlob> simPsBlob;
    ComPtr<ID3DBlob> uiPsBlob;
    ComPtr<ID3DBlob> meshPsBlob;
    if (!compileShader(d3dShaderSource(), "FullscreenVS", "vs_5_0", vsBlob) ||
        !compileShader(d3dShaderSource(), "MeshVS", "vs_5_0", meshVsBlob) ||
        !compileShader(d3dShaderSource(), "SimPS", "ps_5_0", simPsBlob) ||
        !compileShader(d3dShaderSource(), "UiPS", "ps_5_0", uiPsBlob) ||
        !compileShader(d3dShaderSource(), "MeshPS", "ps_5_0", meshPsBlob)) {
        return false;
    }
    if (FAILED(g_d3d.device->CreateVertexShader(vsBlob->GetBufferPointer(), vsBlob->GetBufferSize(), nullptr, g_d3d.vertexShader.GetAddressOf())) ||
        FAILED(g_d3d.device->CreateVertexShader(meshVsBlob->GetBufferPointer(), meshVsBlob->GetBufferSize(), nullptr, g_d3d.meshVertexShader.GetAddressOf())) ||
        FAILED(g_d3d.device->CreatePixelShader(simPsBlob->GetBufferPointer(), simPsBlob->GetBufferSize(), nullptr, g_d3d.simPixelShader.GetAddressOf())) ||
        FAILED(g_d3d.device->CreatePixelShader(uiPsBlob->GetBufferPointer(), uiPsBlob->GetBufferSize(), nullptr, g_d3d.uiPixelShader.GetAddressOf())) ||
        FAILED(g_d3d.device->CreatePixelShader(meshPsBlob->GetBufferPointer(), meshPsBlob->GetBufferSize(), nullptr, g_d3d.meshPixelShader.GetAddressOf()))) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "D3D shader creation failed");
        return false;
    }
    const D3D11_INPUT_ELEMENT_DESC meshInput[] = {
        {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"NORMAL", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 12, D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"COLOR", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 24, D3D11_INPUT_PER_VERTEX_DATA, 0},
    };
    if (FAILED(g_d3d.device->CreateInputLayout(
            meshInput,
            static_cast<UINT>(sizeof(meshInput) / sizeof(meshInput[0])),
            meshVsBlob->GetBufferPointer(),
            meshVsBlob->GetBufferSize(),
            g_d3d.meshInputLayout.GetAddressOf()))) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "D3D mesh input layout failed");
        return false;
    }

    D3D11_BUFFER_DESC constantsDesc = {};
    constantsDesc.ByteWidth = sizeof(DisplayConstants);
    constantsDesc.Usage = D3D11_USAGE_DEFAULT;
    constantsDesc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    if (FAILED(g_d3d.device->CreateBuffer(&constantsDesc, nullptr, g_d3d.displayConstants.GetAddressOf()))) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "D3D constants buffer failed");
        return false;
    }
    D3D11_BUFFER_DESC meshConstantsDesc = {};
    meshConstantsDesc.ByteWidth = sizeof(MeshConstants);
    meshConstantsDesc.Usage = D3D11_USAGE_DEFAULT;
    meshConstantsDesc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    if (FAILED(g_d3d.device->CreateBuffer(&meshConstantsDesc, nullptr, g_d3d.meshConstants.GetAddressOf()))) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "D3D mesh constants buffer failed");
        return false;
    }

    D3D11_BLEND_DESC blendDesc = {};
    blendDesc.RenderTarget[0].BlendEnable = TRUE;
    blendDesc.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC_ALPHA;
    blendDesc.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    blendDesc.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    blendDesc.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    blendDesc.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
    blendDesc.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    blendDesc.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    if (FAILED(g_d3d.device->CreateBlendState(&blendDesc, g_d3d.alphaBlend.GetAddressOf()))) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "D3D alpha blend creation failed");
        return false;
    }
    D3D11_DEPTH_STENCIL_DESC depthDesc = {};
    depthDesc.DepthEnable = FALSE;
    depthDesc.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ZERO;
    depthDesc.DepthFunc = D3D11_COMPARISON_LESS_EQUAL;
    if (FAILED(g_d3d.device->CreateDepthStencilState(&depthDesc, g_d3d.meshDepthState.GetAddressOf()))) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "D3D mesh depth state failed");
        return false;
    }
    D3D11_RASTERIZER_DESC rasterDesc = {};
    rasterDesc.FillMode = D3D11_FILL_SOLID;
    rasterDesc.CullMode = D3D11_CULL_BACK;
    rasterDesc.DepthClipEnable = TRUE;
    if (FAILED(g_d3d.device->CreateRasterizerState(&rasterDesc, g_d3d.meshRasterizerState.GetAddressOf()))) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "D3D mesh rasterizer state failed");
        return false;
    }

    D3D11_QUERY_DESC queryDesc = {};
    queryDesc.Query = D3D11_QUERY_EVENT;
    if (FAILED(g_d3d.device->CreateQuery(&queryDesc, g_d3d.copyCompletionQuery.GetAddressOf()))) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "D3D copy completion query creation failed");
        return false;
    }

    g_d3d.initialized = true;
    loadRuntimeSceneMeshes();
    return true;
}

bool copyD3DWorkerFrame() {
    if (!g_d3d.initialized || g_sharedViewport == nullptr || g_d3d.displaySimTextures[0] == nullptr) {
        return false;
    }

    bool openedAny = false;
    for (int slot = 0; slot < kSharedFrameSlots; ++slot) {
        const auto handleValue = static_cast<uintptr_t>(g_sharedViewport->sharedTextureHandleValues[slot]);
        if (handleValue == 0) {
            continue;
        }
        if (g_d3d.sharedSimTextures[slot] != nullptr &&
            reinterpret_cast<uintptr_t>(g_d3d.sharedSimHandles[slot]) == handleValue) {
            openedAny = true;
            continue;
        }
        g_d3d.sharedSimTextures[slot].Reset();
        g_d3d.sharedSimMutexes[slot].Reset();
        g_d3d.sharedSimHandles[slot] = reinterpret_cast<HANDLE>(handleValue);
        const HRESULT hr = g_d3d.device->OpenSharedResource(
            g_d3d.sharedSimHandles[slot],
            __uuidof(ID3D11Texture2D),
            reinterpret_cast<void**>(g_d3d.sharedSimTextures[slot].GetAddressOf()));
        if (FAILED(hr) || FAILED(g_d3d.sharedSimTextures[slot].As(&g_d3d.sharedSimMutexes[slot]))) {
            std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "host open worker FP16 slot %d failed: %s", slot, hresultString(hr).c_str());
            g_d3d.sharedSimTextures[slot].Reset();
            g_d3d.sharedSimMutexes[slot].Reset();
            g_d3d.sharedSimHandles[slot] = nullptr;
            return false;
        }
        openedAny = true;
        g_d3d.hasSimFrame = false;
        g_lastCopiedWorkerSequence = 0;
    }
    if (!openedAny) {
        return false;
    }

    int copiedSlot = -1;
    int copiedDisplaySlot = -1;
    LONG copiedSequence = g_lastCopiedWorkerSequence;
    bool sawReadyNewerSequence = false;
    bool skipped[kSharedFrameSlots] = {};
    for (int attempt = 0; attempt < kSharedFrameSlots; ++attempt) {
        int newestSlot = -1;
        LONG newestSequence = g_lastCopiedWorkerSequence;
        for (int slot = 0; slot < kSharedFrameSlots; ++slot) {
            const LONG sequence = g_sharedViewport->slotFrameSequences[slot];
            if (skipped[slot] ||
                sequence <= 0 ||
                (sequence & 1) != 0 ||
                g_d3d.sharedSimMutexes[slot] == nullptr ||
                g_d3d.sharedSimTextures[slot] == nullptr) {
                continue;
            }
            if (sequence > newestSequence) {
                sawReadyNewerSequence = true;
                newestSlot = slot;
                newestSequence = sequence;
            }
        }
        if (newestSlot < 0) {
            break;
        }

        const HRESULT acquire = g_d3d.sharedSimMutexes[newestSlot]->AcquireSync(1, 0);
        if (acquire == static_cast<HRESULT>(WAIT_TIMEOUT)) {
            ++g_sharedRingAcquireTimeouts;
            skipped[newestSlot] = true;
            continue;
        }
        if (FAILED(acquire)) {
            std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "D3D shared frame acquire failed: %s", hresultString(acquire).c_str());
            return false;
        }

        const LONG sequenceB = g_sharedViewport->slotFrameSequences[newestSlot];
        const bool copyCandidate = sequenceB == newestSequence && (sequenceB & 1) == 0 && sequenceB > g_lastCopiedWorkerSequence;
        if (copyCandidate) {
            int targetSlot = g_d3d.nextDisplaySimSlot;
            if (targetSlot == g_d3d.activeDisplaySimSlot) {
                ++g_sharedRingSkippedActiveDisplaySlot;
                targetSlot = (targetSlot + 1) % kDisplayFrameSlots;
            }
            g_d3d.context->CopyResource(g_d3d.displaySimTextures[targetSlot].Get(), g_d3d.sharedSimTextures[newestSlot].Get());
            g_d3d.activeDisplaySimSlot = targetSlot;
            g_d3d.nextDisplaySimSlot = (targetSlot + 1) % kDisplayFrameSlots;
            copiedSlot = newestSlot;
            copiedDisplaySlot = targetSlot;
            copiedSequence = sequenceB;
        }

        const HRESULT release = g_d3d.sharedSimMutexes[newestSlot]->ReleaseSync(0);
        if (FAILED(release)) {
            std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "D3D shared frame release failed: %s", hresultString(release).c_str());
            return false;
        }
        if (copyCandidate) {
            break;
        }
        skipped[newestSlot] = true;
    }
    if (copiedSlot < 0) {
        if (sawReadyNewerSequence) {
            ++g_sharedRingCopyStarvationFrames;
        } else {
            ++g_sharedRingNoCandidateFrames;
        }
        return false;
    }

    g_lastCopiedWorkerSequence = copiedSequence;
    g_sharedRingLastCopiedSharedSlot = copiedSlot;
    g_sharedRingLastCopiedDisplaySlot = copiedDisplaySlot;
    g_sharedRingLastCopiedSequence = copiedSequence;
    g_d3d.hasSimFrame = true;
    return true;
}

struct Vec3 {
    float x;
    float y;
    float z;
};

Vec3 sub3(Vec3 a, Vec3 b) {
    return {a.x - b.x, a.y - b.y, a.z - b.z};
}

Vec3 cross3(Vec3 a, Vec3 b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

float dot3(Vec3 a, Vec3 b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

Vec3 normalize3(Vec3 v) {
    const float invLen = 1.0f / std::max(0.000001f, std::sqrt(dot3(v, v)));
    return {v.x * invLen, v.y * invLen, v.z * invLen};
}

bool projectWorldToViewport(Vec3 world, int& sx, int& sy, float& depth) {
    const Vec3 target = {0.0f, 0.48f, 0.0f};
    const float cp = std::cos(g_cameraPitch);
    const Vec3 eye = {
        std::sin(g_cameraYaw) * g_cameraDistance * cp,
        target.y + std::sin(g_cameraPitch) * g_cameraDistance,
        std::cos(g_cameraYaw) * g_cameraDistance * cp};
    const Vec3 z = normalize3(sub3(eye, target));
    const Vec3 x = normalize3(cross3({0.0f, 1.0f, 0.0f}, z));
    const Vec3 y = cross3(z, x);
    const Vec3 rel = sub3(world, eye);
    depth = -dot3(z, rel);
    if (depth <= 0.03f) {
        return false;
    }

    const float fovY = 50.0f * 3.1415926535f / 180.0f;
    const float aspect = static_cast<float>(kFrameWidth) / static_cast<float>(kFrameHeight);
    const float f = 1.0f / std::tan(fovY * 0.5f);
    const float ndcX = (dot3(x, rel) * f / aspect) / depth;
    const float ndcY = (dot3(y, rel) * f) / depth;
    if (!std::isfinite(ndcX) || !std::isfinite(ndcY) || ndcX < -1.4f || ndcX > 1.4f || ndcY < -1.4f || ndcY > 1.4f) {
        return false;
    }

    sx = kViewportRect.x + static_cast<int>((ndcX * 0.5f + 0.5f) * static_cast<float>(kViewportRect.w));
    sy = kViewportRect.y + static_cast<int>((0.5f - ndcY * 0.5f) * static_cast<float>(kViewportRect.h));
    return contains(kViewportRect, sx, sy);
}

void drawProjectedEmitterMarker(
    std::vector<std::uint32_t>& pixels,
    Vec3 center,
    float radiusMeters,
    const char* label,
    float cr,
    float cg,
    float cb) {
    int cx = 0;
    int cy = 0;
    float depth = 0.0f;
    if (!projectWorldToViewport(center, cx, cy, depth)) {
        return;
    }

    int rx = 0;
    int ry = 0;
    float edgeDepth = 0.0f;
    float radiusPx = 18.0f;
    if (projectWorldToViewport({center.x + std::max(0.03f, radiusMeters), center.y, center.z}, rx, ry, edgeDepth)) {
        const float dx = static_cast<float>(rx - cx);
        const float dy = static_cast<float>(ry - cy);
        radiusPx = std::sqrt(dx * dx + dy * dy);
    }
    radiusPx = std::max(8.0f, std::min(70.0f, radiusPx));

    drawCirclePx(pixels, cx, cy, static_cast<int>(radiusPx), cr, cg, cb, 0.88f);
    drawCirclePx(pixels, cx, cy, 3, cr, cg, cb, 0.95f);
    drawLinePx(pixels, cx - 10, cy, cx + 10, cy, cr, cg, cb, 0.76f);
    drawLinePx(pixels, cx, cy - 10, cx, cy + 10, cr, cg, cb, 0.76f);
    drawText(pixels, cx + 10, cy - 18, label, 1, cr, cg, cb, 0.88f);
}

void drawProjectedBoxOverlay(std::vector<std::uint32_t>& pixels, Vec3 minCorner, Vec3 maxCorner, const char* label, float r, float g, float b) {
    const Vec3 corners[8] = {
        {minCorner.x, minCorner.y, minCorner.z},
        {maxCorner.x, minCorner.y, minCorner.z},
        {maxCorner.x, maxCorner.y, minCorner.z},
        {minCorner.x, maxCorner.y, minCorner.z},
        {minCorner.x, minCorner.y, maxCorner.z},
        {maxCorner.x, minCorner.y, maxCorner.z},
        {maxCorner.x, maxCorner.y, maxCorner.z},
        {minCorner.x, maxCorner.y, maxCorner.z},
    };
    int sx[8] = {};
    int sy[8] = {};
    bool visible[8] = {};
    for (int i = 0; i < 8; ++i) {
        float depth = 0.0f;
        visible[i] = projectWorldToViewport(corners[i], sx[i], sy[i], depth);
    }
    const int edges[12][2] = {
        {0, 1}, {1, 2}, {2, 3}, {3, 0},
        {4, 5}, {5, 6}, {6, 7}, {7, 4},
        {0, 4}, {1, 5}, {2, 6}, {3, 7},
    };
    for (const auto& edge : edges) {
        if (visible[edge[0]] && visible[edge[1]]) {
            drawLinePx(pixels, sx[edge[0]], sy[edge[0]], sx[edge[1]], sy[edge[1]], r, g, b, 0.62f);
        }
    }
    for (int i = 0; i < 8; ++i) {
        if (visible[i]) {
            drawText(pixels, sx[i] + 4, sy[i] - 10, label, 1, r, g, b, 0.72f);
            break;
        }
    }
}

void drawSceneDebugOverlay(std::vector<std::uint32_t>& pixels, const FireSettings& settings, bool cleanViewport) {
    if (cleanViewport || (settings.showGizmos == 0 && settings.renderDebugMode == 0)) {
        return;
    }

    drawProjectedBoxOverlay(pixels, {-1.05f, 0.02f, -0.82f}, {1.05f, 2.03f, 0.82f}, "VOLUME", 0.14f, 0.58f, 1.0f);
    drawProjectedBoxOverlay(pixels, {-0.92f, 0.0f, -0.66f}, {0.92f, 0.16f, 0.66f}, "FUEL BED", 1.0f, 0.54f, 0.10f);
    drawLinePx(pixels, 900, 478, 950, 478, 1.0f, 0.10f, 0.08f, 0.86f);
    drawLinePx(pixels, 900, 478, 900, 428, 0.08f, 1.0f, 0.18f, 0.86f);
    drawLinePx(pixels, 900, 478, 866, 504, 0.20f, 0.50f, 1.0f, 0.86f);
    char frameLabel[96] = {};
    std::snprintf(frameLabel, sizeof(frameLabel), "FRAME AGE %llums  RING %ld>%ld", g_displayFrameAgeMs, static_cast<long>(g_sharedRingLastCopiedSharedSlot), static_cast<long>(g_sharedRingLastCopiedDisplaySlot));
    drawText(pixels, kViewportRect.x + 18, kViewportRect.y + kViewportRect.h - 28, frameLabel, 1, 0.58f, 0.92f, 0.72f, 0.92f);
    drawText(pixels, kViewportRect.x + 18, kViewportRect.y + kViewportRect.h - 46, "OVERLAY: SOURCE / VOLUME / FUEL BED / AXES / FRESHNESS", 1, 0.76f, 0.80f, 0.72f, 0.86f);

    const RuntimeSceneMesh& mesh = g_sceneMeshes[std::max(0, std::min(kSceneCount - 1, settings.sceneId))];
    if (mesh.loaded) {
        drawProjectedBoxOverlay(pixels, {mesh.minX, mesh.minY, mesh.minZ}, {mesh.maxX, mesh.maxY, mesh.maxZ}, "GLB BOUNDS", 0.82f, 0.72f, 1.0f);
    }

    const float emitterY = std::max(0.02f, settings.emitterHeightNorm * 2.03f + 0.02f);
    if (settings.sceneId == 2 && settings.burnerCenterCount > 0) {
        const int count = std::min(4, settings.burnerCenterCount);
        for (int i = 0; i < count; ++i) {
            char label[24] = {};
            std::snprintf(label, sizeof(label), i == 0 ? "SRC ACTIVE" : "PORT %d", i);
            const float alphaBias = i == 0 ? 1.0f : 0.72f;
            const float burnerY = settings.burnerCenterY[i] > 0.0f ? settings.burnerCenterY[i] : emitterY;
            drawProjectedEmitterMarker(
                pixels,
                {settings.burnerCenterX[i], burnerY, settings.burnerCenterZ[i]},
                settings.emitterRadius,
                label,
                0.18f * alphaBias,
                0.72f * alphaBias,
                1.0f);
        }
        return;
    }

    drawProjectedEmitterMarker(
        pixels,
        {settings.emitterCenterX, emitterY, settings.emitterCenterZ},
        settings.emitterRadius,
        "SRC",
        1.0f,
        0.42f,
        0.08f);
}

void mulMat4(const float a[16], const float b[16], float out[16]) {
    float r[16] = {};
    for (int row = 0; row < 4; ++row) {
        for (int col = 0; col < 4; ++col) {
            r[row * 4 + col] =
                a[row * 4 + 0] * b[0 * 4 + col] +
                a[row * 4 + 1] * b[1 * 4 + col] +
                a[row * 4 + 2] * b[2 * 4 + col] +
                a[row * 4 + 3] * b[3 * 4 + col];
        }
    }
    std::memcpy(out, r, sizeof(r));
}

MeshConstants meshConstantsForScene(int sceneId, float exposure) {
    MeshConstants constants = {};
    const Vec3 target = {0.0f, 0.48f, 0.0f};
    const float cp = std::cos(g_cameraPitch);
    const Vec3 eye = {
        std::sin(g_cameraYaw) * g_cameraDistance * cp,
        target.y + std::sin(g_cameraPitch) * g_cameraDistance,
        std::cos(g_cameraYaw) * g_cameraDistance * cp};
    const Vec3 z = normalize3(sub3(eye, target));
    const Vec3 x = normalize3(cross3({0.0f, 1.0f, 0.0f}, z));
    const Vec3 y = cross3(z, x);
    const float view[16] = {
        x.x, y.x, z.x, 0.0f,
        x.y, y.y, z.y, 0.0f,
        x.z, y.z, z.z, 0.0f,
        -dot3(x, eye), -dot3(y, eye), -dot3(z, eye), 1.0f};
    const float fovY = 50.0f * 3.1415926535f / 180.0f;
    const float aspect = static_cast<float>(kFrameWidth) / static_cast<float>(kFrameHeight);
    const float f = 1.0f / std::tan(fovY * 0.5f);
    const float zn = 0.03f;
    const float zf = 18.0f;
    const float proj[16] = {
        f / aspect, 0.0f, 0.0f, 0.0f,
        0.0f, f, 0.0f, 0.0f,
        0.0f, 0.0f, zf / (zn - zf), -1.0f,
        0.0f, 0.0f, (zn * zf) / (zn - zf), 0.0f};
    mulMat4(view, proj, constants.viewProj);
    constants.lightPos[0] = 0.0f;
    constants.lightPos[1] = sceneId == 2 ? 0.20f : 0.50f;
    constants.lightPos[2] = 0.0f;
    constants.lightPos[3] = 1.0f;
    if (sceneId == 1) {
        constants.baseColor[0] = 0.052f * exposure;
        constants.baseColor[1] = 0.030f * exposure;
        constants.baseColor[2] = 0.017f * exposure;
        constants.baseColor[3] = 0.70f;
        constants.fireColor[0] = 1.18f * exposure;
        constants.fireColor[1] = 0.42f * exposure;
        constants.fireColor[2] = 0.070f * exposure;
        constants.fireColor[3] = 1.0f;
        constants.fireParams[0] = 0.62f;
        constants.fireParams[1] = 0.18f;
        constants.fireParams[2] = 4.0f;
        constants.fireParams[3] = 1.0f;
    } else if (sceneId == 2) {
        constants.baseColor[0] = 0.017f * exposure;
        constants.baseColor[1] = 0.019f * exposure;
        constants.baseColor[2] = 0.023f * exposure;
        constants.baseColor[3] = 0.90f;
        constants.fireColor[0] = 0.040f * exposure;
        constants.fireColor[1] = 0.13f * exposure;
        constants.fireColor[2] = 0.42f * exposure;
        constants.fireColor[3] = 1.0f;
        constants.fireParams[0] = 0.26f;
        constants.fireParams[1] = 0.055f;
        constants.fireParams[2] = 8.5f;
        constants.fireParams[3] = 2.0f;
    } else {
        constants.baseColor[0] = 0.020f * exposure;
        constants.baseColor[1] = 0.022f * exposure;
        constants.baseColor[2] = 0.024f * exposure;
        constants.baseColor[3] = 0.88f;
        constants.fireColor[0] = 1.05f * exposure;
        constants.fireColor[1] = 0.36f * exposure;
        constants.fireColor[2] = 0.060f * exposure;
        constants.fireColor[3] = 1.0f;
        constants.fireParams[0] = 0.54f;
        constants.fireParams[1] = 0.24f;
        constants.fireParams[2] = 5.0f;
        constants.fireParams[3] = 0.0f;
    }
    return constants;
}

void renderRuntimeSceneMesh(float exposure) {
    if (g_activeScene < 0 || g_activeScene >= kSceneCount) {
        return;
    }
    RuntimeSceneMesh& mesh = g_sceneMeshes[g_activeScene];
    if (!mesh.loaded || mesh.vertexBuffer == nullptr || mesh.indexBuffer == nullptr || mesh.indices.empty()) {
        return;
    }
    MeshConstants constants = meshConstantsForScene(g_activeScene, exposure);
    g_d3d.context->UpdateSubresource(g_d3d.meshConstants.Get(), 0, nullptr, &constants, 0, 0);
    const UINT stride = sizeof(MeshVertex);
    const UINT offset = 0;
    ID3D11Buffer* vertexBuffers[] = {mesh.vertexBuffer.Get()};
    ID3D11Buffer* constantBuffers[] = {g_d3d.meshConstants.Get()};
    g_d3d.context->IASetInputLayout(g_d3d.meshInputLayout.Get());
    g_d3d.context->IASetVertexBuffers(0, 1, vertexBuffers, &stride, &offset);
    g_d3d.context->IASetIndexBuffer(mesh.indexBuffer.Get(), DXGI_FORMAT_R32_UINT, 0);
    g_d3d.context->VSSetShader(g_d3d.meshVertexShader.Get(), nullptr, 0);
    g_d3d.context->VSSetConstantBuffers(1, 1, constantBuffers);
    g_d3d.context->PSSetShader(g_d3d.meshPixelShader.Get(), nullptr, 0);
    g_d3d.context->PSSetConstantBuffers(1, 1, constantBuffers);
    g_d3d.context->RSSetState(g_d3d.meshRasterizerState.Get());
    g_d3d.context->OMSetDepthStencilState(g_d3d.meshDepthState.Get(), 0);
    g_d3d.context->DrawIndexed(static_cast<UINT>(mesh.indices.size()), 0, 0);
    g_d3d.context->RSSetState(nullptr);
    g_d3d.context->OMSetDepthStencilState(nullptr, 0);
    g_d3d.context->IASetInputLayout(nullptr);
}

void beginD3DRenderGraphFrame() {
    ++g_renderGraphStats.frameIndex;
    g_renderGraphStats.lastFrameHadVolume = false;
    g_renderGraphStats.lastFrameHadMesh = false;
    g_renderGraphStats.lastFrameHadUi = false;
    const float clearColor[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    ID3D11RenderTargetView* renderTargets[] = {g_d3d.renderTargetView.Get()};
    g_d3d.context->OMSetRenderTargets(1, renderTargets, nullptr);
    g_d3d.context->ClearRenderTargetView(g_d3d.renderTargetView.Get(), clearColor);
    ++g_renderGraphStats.clearPasses;

    D3D11_VIEWPORT viewport = {};
    viewport.Width = static_cast<float>(kFrameWidth);
    viewport.Height = static_cast<float>(kFrameHeight);
    viewport.MinDepth = 0.0f;
    viewport.MaxDepth = 1.0f;
    g_d3d.context->RSSetViewports(1, &viewport);
    g_d3d.context->IASetInputLayout(nullptr);
    g_d3d.context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    g_d3d.context->VSSetShader(g_d3d.vertexShader.Get(), nullptr, 0);
    ID3D11SamplerState* samplers[] = {g_d3d.sampler.Get()};
    g_d3d.context->PSSetSamplers(0, 1, samplers);
}

void renderD3DVolumeCameraPass(float exposure) {
    DisplayConstants constants = {};
    constants.exposure = exposure;
    g_d3d.context->UpdateSubresource(g_d3d.displayConstants.Get(), 0, nullptr, &constants, 0, 0);
    ID3D11Buffer* constantBuffers[] = {g_d3d.displayConstants.Get()};
    ID3D11ShaderResourceView* simView =
        g_d3d.activeDisplaySimSlot >= 0 && g_d3d.activeDisplaySimSlot < kDisplayFrameSlots
            ? g_d3d.displaySimSrvs[g_d3d.activeDisplaySimSlot].Get()
            : nullptr;
    ID3D11ShaderResourceView* simSrvs[] = {simView};
    g_d3d.context->PSSetConstantBuffers(0, 1, constantBuffers);
    g_d3d.context->PSSetShaderResources(0, 1, simSrvs);
    g_d3d.context->PSSetShader(g_d3d.simPixelShader.Get(), nullptr, 0);
    g_d3d.context->Draw(3, 0);
    ++g_renderGraphStats.volumeCameraPasses;
    g_renderGraphStats.lastFrameHadVolume = simView != nullptr;
}

void bindD3DFullscreenPass() {
    ID3D11Buffer* nullVertexBuffers[] = {nullptr};
    UINT nullStride = 0;
    UINT nullOffset = 0;
    g_d3d.context->IASetInputLayout(nullptr);
    g_d3d.context->IASetVertexBuffers(0, 1, nullVertexBuffers, &nullStride, &nullOffset);
    g_d3d.context->IASetIndexBuffer(nullptr, DXGI_FORMAT_UNKNOWN, 0);
    g_d3d.context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    g_d3d.context->VSSetShader(g_d3d.vertexShader.Get(), nullptr, 0);
}

void renderD3DSceneMeshPass(float exposure) {
    const bool hasMesh =
        g_activeScene >= 0 &&
        g_activeScene < kSceneCount &&
        g_sceneMeshes[g_activeScene].loaded &&
        g_sceneMeshes[g_activeScene].vertexBuffer != nullptr &&
        g_sceneMeshes[g_activeScene].indexBuffer != nullptr &&
        !g_sceneMeshes[g_activeScene].indices.empty();
    const float blendFactor[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    g_d3d.context->OMSetBlendState(g_d3d.alphaBlend.Get(), blendFactor, 0xffffffffu);
    renderRuntimeSceneMesh(exposure);
    ++g_renderGraphStats.sceneMeshPasses;
    g_renderGraphStats.lastFrameHadMesh = hasMesh;
    bindD3DFullscreenPass();
}

void renderD3DUiOverlayPass() {
    ID3D11ShaderResourceView* uiSrvs[] = {g_d3d.uiSrv.Get()};
    g_d3d.context->PSSetShaderResources(0, 1, uiSrvs);
    g_d3d.context->PSSetShader(g_d3d.uiPixelShader.Get(), nullptr, 0);
    g_d3d.context->Draw(3, 0);
    ID3D11ShaderResourceView* nullSrvs[] = {nullptr};
    const float blendFactor[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    g_d3d.context->PSSetShaderResources(0, 1, nullSrvs);
    g_d3d.context->OMSetBlendState(nullptr, blendFactor, 0xffffffffu);
    ++g_renderGraphStats.uiOverlayPasses;
    g_renderGraphStats.lastFrameHadUi = true;
}

bool presentD3DRenderGraphFrame() {
    HRESULT present = g_d3d.swapChain->Present(0, DXGI_PRESENT_DO_NOT_WAIT);
    if (present == DXGI_ERROR_WAS_STILL_DRAWING) {
        g_lastPresentSkippedWouldBlock = true;
        ++g_renderGraphStats.skippedPresentPasses;
        return false;
    }
    ++g_renderGraphStats.presentPasses;
    return SUCCEEDED(present);
}

bool renderD3DFrame(bool drawSim, float exposure, bool uploadUi) {
    g_lastPresentSkippedWouldBlock = false;
    if (!g_d3d.initialized || g_d3d.context == nullptr || g_d3d.swapChain == nullptr) {
        return false;
    }
    if (uploadUi || !g_uiTextureUploaded) {
        g_d3d.context->UpdateSubresource(g_d3d.uiTexture.Get(), 0, nullptr, g_frame.data(), kFrameWidth * sizeof(std::uint32_t), 0);
        g_uiTextureUploaded = true;
    }

    beginD3DRenderGraphFrame();
    if (drawSim && g_d3d.hasSimFrame) {
        renderD3DVolumeCameraPass(exposure);
    }
    renderD3DSceneMeshPass(exposure);
    renderD3DUiOverlayPass();
    return presentD3DRenderGraphFrame();
}

LRESULT CALLBACK windowProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_SIZE:
        g_clientW = LOWORD(lParam);
        g_clientH = HIWORD(lParam);
        return 0;
    case WM_LBUTTONDOWN:
        SetCapture(hwnd);
        g_leftDown = true;
        g_leftInViewport = false;
        g_dragControl = 0;
        updateMouseFromLParam(lParam);
        if (const int tool = hitTestToolButton(g_pointerFrameX, g_pointerFrameY); tool != 0) {
            g_activeGizmo = tool;
            return 0;
        }
        if (const int scene = hitTestSceneButton(g_pointerFrameX, g_pointerFrameY); scene >= 0) {
            switchScene(scene);
            return 0;
        }
        if (const int command = hitTestCommandButton(g_pointerFrameX, g_pointerFrameY); command != 0) {
            if (command == 1) {
                g_showGizmos = !g_showGizmos;
            } else {
                requestSimulationReset();
            }
            return 0;
        }
        if (const int slider = hitTestSlider(g_pointerFrameX, g_pointerFrameY); slider != 0) {
            g_activeGizmo = slider;
            g_dragControl = slider;
            applyPanelDrag();
            return 0;
        }
        if (g_pointerInViewport) {
            g_leftInViewport = true;
        }
        return 0;
    case WM_LBUTTONUP:
        g_leftDown = false;
        g_leftInViewport = false;
        g_dragControl = 0;
        if (!g_rightDown) {
            ReleaseCapture();
        }
        return 0;
    case WM_RBUTTONDOWN:
        SetCapture(hwnd);
        g_rightDown = true;
        updateMouseFromLParam(lParam);
        g_orbiting = g_pointerInViewport;
        return 0;
    case WM_RBUTTONUP:
        g_rightDown = false;
        g_orbiting = false;
        if (!g_leftDown) {
            ReleaseCapture();
        }
        return 0;
    case WM_MOUSEMOVE: {
        const int prevX = g_lastMouseX;
        const int prevY = g_lastMouseY;
        updateMouseFromLParam(lParam);
        if (g_orbiting) {
            const int dx = g_lastMouseX - prevX;
            const int dy = g_lastMouseY - prevY;
            g_cameraYaw += static_cast<float>(dx) * 0.0085f;
            g_cameraPitch += static_cast<float>(dy) * 0.0060f;
            g_cameraPitch = std::max(-0.55f, std::min(0.52f, g_cameraPitch));
        } else if (g_dragControl != 0) {
            applyPanelDrag();
        }
        return 0;
    }
    case WM_MOUSEWHEEL: {
        const short delta = GET_WHEEL_DELTA_WPARAM(wParam);
        const float steps = static_cast<float>(delta) / static_cast<float>(WHEEL_DELTA);
        g_cameraDistance = std::max(1.7f, std::min(5.5f, g_cameraDistance - steps * 0.18f));
        return 0;
    }
    case WM_KEYDOWN:
        if (wParam == VK_ESCAPE) {
            DestroyWindow(hwnd);
            return 0;
        }
        if (wParam == 'R') {
            requestSimulationReset();
            return 0;
        }
        if (wParam == 'G') {
            g_showGizmos = !g_showGizmos;
            return 0;
        }
        if (wParam == 'C') {
            g_cleanViewportMode = !g_cleanViewportMode;
            return 0;
        }
        if (wParam == 'D') {
            g_renderDebugMode = (g_renderDebugMode + 1) % 7;
            return 0;
        }
        if (wParam == 'S') {
            switchScene((g_activeScene + 1) % kSceneCount);
            return 0;
        }
        if (wParam >= '1' && wParam <= '4') {
            g_activeGizmo = static_cast<int>(wParam - '0');
            return 0;
        }
        if (wParam == VK_LEFT) {
            g_wind = std::max(-1.0f, g_wind - 0.08f);
            return 0;
        }
        if (wParam == VK_RIGHT) {
            g_wind = std::min(1.0f, g_wind + 0.08f);
            return 0;
        }
        if (wParam == VK_UP) {
            g_turbulence = std::min(1.5f, g_turbulence + 0.06f);
            return 0;
        }
        if (wParam == VK_DOWN) {
            g_turbulence = std::max(0.05f, g_turbulence - 0.06f);
            return 0;
        }
        return 0;
    case WM_PAINT: {
        PAINTSTRUCT ps = {};
        BeginPaint(hwnd, &ps);
        renderD3DFrame(g_useCudaBackend, g_displayExposure, true);
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_DESTROY:
        g_running = false;
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }
}

bool createMainWindow(HINSTANCE instance) {
    WNDCLASSA wc = {};
    wc.style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC;
    wc.lpfnWndProc = windowProc;
    wc.hInstance = instance;
    wc.hCursor = LoadCursor(nullptr, IDC_CROSS);
    wc.lpszClassName = "NativeFireSimWindow";

    if (!RegisterClassA(&wc)) {
        return false;
    }

    RECT rect = {0, 0, kFrameWidth, kFrameHeight};
    AdjustWindowRect(&rect, WS_OVERLAPPEDWINDOW, FALSE);

    g_window = CreateWindowExA(
        0,
        wc.lpszClassName,
        "Native FireSim Safe Main Viewport",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        rect.right - rect.left,
        rect.bottom - rect.top,
        nullptr,
        nullptr,
        instance,
        nullptr);

    return g_window != nullptr;
}

bool writeBmp(const char* path, const std::vector<std::uint32_t>& pixels, int width, int height) {
    BITMAPFILEHEADER fileHeader = {};
    BITMAPINFOHEADER infoHeader = {};
    const DWORD pixelBytes = static_cast<DWORD>(pixels.size() * sizeof(std::uint32_t));

    fileHeader.bfType = 0x4d42;
    fileHeader.bfOffBits = sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER);
    fileHeader.bfSize = fileHeader.bfOffBits + pixelBytes;

    infoHeader.biSize = sizeof(BITMAPINFOHEADER);
    infoHeader.biWidth = width;
    infoHeader.biHeight = -height;
    infoHeader.biPlanes = 1;
    infoHeader.biBitCount = 32;
    infoHeader.biCompression = BI_RGB;
    infoHeader.biSizeImage = pixelBytes;

    std::ofstream out(path, std::ios::binary);
    if (!out) {
        return false;
    }
    out.write(reinterpret_cast<const char*>(&fileHeader), sizeof(fileHeader));
    out.write(reinterpret_cast<const char*>(&infoHeader), sizeof(infoHeader));
    out.write(reinterpret_cast<const char*>(pixels.data()), pixelBytes);
    return out.good();
}

std::string normalizePathSeparators(std::string path) {
    for (char& c : path) {
        if (c == '/') {
            c = '\\';
        }
    }
    while (path.size() > 1 && (path.back() == '\\' || path.back() == '/')) {
        path.pop_back();
    }
    return path;
}

bool ensureDirectoryTree(const std::string& directory) {
    if (directory.empty()) {
        return false;
    }
    const std::string path = normalizePathSeparators(directory);
    std::string partial;
    std::size_t start = 0;
    if (path.size() >= 3 && path[1] == ':' && path[2] == '\\') {
        partial = path.substr(0, 3);
        start = 3;
    }
    while (start < path.size()) {
        const std::size_t slash = path.find('\\', start);
        const std::size_t end = slash == std::string::npos ? path.size() : slash;
        if (end > start) {
            if (!partial.empty() && partial.back() != '\\') {
                partial += '\\';
            }
            partial += path.substr(start, end - start);
            if (!CreateDirectoryA(partial.c_str(), nullptr)) {
                const DWORD error = GetLastError();
                if (error != ERROR_ALREADY_EXISTS) {
                    return false;
                }
            }
        }
        if (slash == std::string::npos) {
            break;
        }
        start = slash + 1;
    }
    return true;
}

std::string joinPath(const std::string& directory, const char* filename) {
    if (directory.empty()) {
        return filename;
    }
    std::string path = normalizePathSeparators(directory);
    if (!path.empty() && path.back() != '\\') {
        path += '\\';
    }
    path += filename;
    return path;
}

bool gpuKernelLaunchAllowed(const std::string& args) {
    char envValue[16] = {};
    const bool explicitKernelAllow = args.find("--allow-gpu-kernels") != std::string::npos;
    const DWORD allowSize = GetEnvironmentVariableA("FIRESIM_ALLOW_GPU_KERNELS", envValue, static_cast<DWORD>(sizeof(envValue)));
    const bool envKernelAllow = allowSize > 0 && std::string(envValue) == "1";

    char riskValue[16] = {};
    const bool explicitRiskAllow = args.find("--accept-bugcheck-risk") != std::string::npos;
    const DWORD riskSize = GetEnvironmentVariableA("FIRESIM_ACCEPT_BUGCHECK_RISK", riskValue, static_cast<DWORD>(sizeof(riskValue)));
    const bool envRiskAllow = riskSize > 0 && std::string(riskValue) == "1";

    return (explicitKernelAllow || envKernelAllow) && (explicitRiskAllow || envRiskAllow);
}

int writeGpuSafetyStop(const char* requestedMode) {
    CreateDirectoryA("out", nullptr);
    std::ofstream out("out\\gpu-safety-stop.txt", std::ios::binary);
    if (out) {
        out << "Native FireSim blocked a CUDA kernel launch.\n";
        out << "requestedMode=" << requestedMode << "\n";
        out << "reason=Recent runs caused Windows bugcheck 0xD1 DRIVER_IRQL_NOT_LESS_OR_EQUAL.\n";
        out << "latestDump=C:\\Windows\\Minidump\\050126-21062-01.dmp\n";
        out << "override=Pass --allow-gpu-kernels --accept-bugcheck-risk only for explicit smoke-test or validation lab runs.\n";
    }
    return 6;
}

struct ImageStats {
    float meanLuma = 0.0f;
    float maxLuma = 0.0f;
    float meanSaturation = 0.0f;
    float warmFireFraction = 0.0f;
    float tanSmokeFraction = 0.0f;
    float blackSmokeFraction = 0.0f;
    float whiteCoreFraction = 0.0f;
    float brightFraction = 0.0f;
    int brightPixels = 0;
};

ImageStats computeImageStats(const std::vector<std::uint32_t>& pixels) {
    ImageStats stats;
    if (pixels.empty()) {
        return stats;
    }
    double total = 0.0;
    double totalSaturation = 0.0;
    int warmFirePixels = 0;
    int tanSmokePixels = 0;
    int blackSmokePixels = 0;
    int whiteCorePixels = 0;
    for (const std::uint32_t pixel : pixels) {
        const float r = static_cast<float>((pixel >> 16) & 0xff) / 255.0f;
        const float g = static_cast<float>((pixel >> 8) & 0xff) / 255.0f;
        const float b = static_cast<float>(pixel & 0xff) / 255.0f;
        const float luma = r * 0.2126f + g * 0.7152f + b * 0.0722f;
        const float maxChannel = std::max(r, std::max(g, b));
        const float minChannel = std::min(r, std::min(g, b));
        const float saturation = maxChannel > 0.0001f ? (maxChannel - minChannel) / maxChannel : 0.0f;
        const bool warm = r > g * 1.05f && r > b * 1.55f && luma > 0.20f;
        total += luma;
        totalSaturation += saturation;
        stats.maxLuma = std::max(stats.maxLuma, luma);
        if (luma > 0.68f) {
            ++stats.brightPixels;
        }
        if (warm) {
            ++warmFirePixels;
        }
        if (r > g * 1.03f && g > b * 1.35f && saturation < 0.58f && luma > 0.20f && luma < 0.68f) {
            ++tanSmokePixels;
        }
        if (luma < 0.16f && saturation < 0.42f) {
            ++blackSmokePixels;
        }
        if (warm && luma > 0.82f && saturation < 0.40f) {
            ++whiteCorePixels;
        }
    }
    const double pixelCount = static_cast<double>(pixels.size());
    stats.meanLuma = static_cast<float>(total / pixelCount);
    stats.meanSaturation = static_cast<float>(totalSaturation / pixelCount);
    stats.warmFireFraction = static_cast<float>(static_cast<double>(warmFirePixels) / pixelCount);
    stats.tanSmokeFraction = static_cast<float>(static_cast<double>(tanSmokePixels) / pixelCount);
    stats.blackSmokeFraction = static_cast<float>(static_cast<double>(blackSmokePixels) / pixelCount);
    stats.whiteCoreFraction = static_cast<float>(static_cast<double>(whiteCorePixels) / pixelCount);
    stats.brightFraction = static_cast<float>(static_cast<double>(stats.brightPixels) / pixelCount);
    return stats;
}

struct TargetEnvelope {
    std::string metric;
    float minimum = 0.0f;
    float maximum = 0.0f;
    float observed = 0.0f;
    bool matched = false;
    bool passed = false;
};

std::string trim(std::string value) {
    const std::size_t begin = value.find_first_not_of(" \t\r\n");
    if (begin == std::string::npos) {
        return {};
    }
    const std::size_t end = value.find_last_not_of(" \t\r\n");
    return value.substr(begin, end - begin + 1);
}

std::string jsonEscape(const std::string& value) {
    std::string escaped;
    escaped.reserve(value.size());
    for (const char c : value) {
        if (c == '\\') {
            escaped += "\\\\";
        } else if (c == '"') {
            escaped += "\\\"";
        } else if (c == '\n') {
            escaped += "\\n";
        } else if (c == '\r') {
            escaped += "\\r";
        } else if (c == '\t') {
            escaped += "\\t";
        } else {
            escaped += c;
        }
    }
    return escaped;
}

std::string argumentValue(const std::string& args, const char* prefix) {
    const std::size_t pos = args.find(prefix);
    if (pos == std::string::npos) {
        return {};
    }
    const std::size_t valueStart = pos + std::strlen(prefix);
    if (valueStart >= args.size()) {
        return {};
    }
    if (args[valueStart] == '"') {
        const std::size_t valueEnd = args.find('"', valueStart + 1);
        if (valueEnd == std::string::npos) {
            return args.substr(valueStart + 1);
        }
        return args.substr(valueStart + 1, valueEnd - valueStart - 1);
    }
    const std::size_t valueEnd = args.find(' ', valueStart);
    std::string value = args.substr(valueStart, valueEnd == std::string::npos ? std::string::npos : valueEnd - valueStart);
    return value;
}

int argumentIntValue(const std::string& args, const char* prefix, int fallback, int minimum, int maximum) {
    const std::string value = argumentValue(args, prefix);
    if (value.empty()) {
        return fallback;
    }
    char* end = nullptr;
    const long parsed = std::strtol(value.c_str(), &end, 10);
    if (end == value.c_str()) {
        return fallback;
    }
    return static_cast<int>(std::max<long>(minimum, std::min<long>(maximum, parsed)));
}

void applyCanonicalFireSettings(FireSettings& settings) {
    settings.sceneId = std::max(0, std::min(kSceneCount - 1, settings.sceneId));
    settings.cinematicMode = 1;
    settings.raymarchSteps = kRaymarchSteps;
    settings.emberCount = kEmberCount;
    settings.exposure = kExposure;
    settings.reflectionGain = kReflectionGain;
    settings.smokeDarkness = kSmokeDarkness;
    settings.intensity = kFireIntensity;
    settings.smoke = kSmokeGain;
    settings.turbulence = kTurbulence;
    settings.renderDebugMode = 0;
}

unsigned long long tickMs() {
    return static_cast<unsigned long long>(GetTickCount64());
}

struct TimerResolutionScope {
    bool active = false;

    TimerResolutionScope() : active(timeBeginPeriod(1) == TIMERR_NOERROR) {}

    ~TimerResolutionScope() {
        if (active) {
            timeEndPeriod(1);
        }
    }
};

void appendRuntimeEvent(const char* event, const char* detail = "") {
    CreateDirectoryA("out", nullptr);
    std::ofstream log("out\\worker-events.log", std::ios::app | std::ios::binary);
    if (!log) {
        return;
    }
    log << tickMs() << "," << event << "," << detail << "\n";
}

const char* workerLifecycleReasonName(WorkerLifecycleReason reason) {
    switch (reason) {
    case WorkerLifecycleReason::StartRequested: return "start-requested";
    case WorkerLifecycleReason::CreateProcessFailed: return "createprocess-failed";
    case WorkerLifecycleReason::RestartBlocked: return "restart-blocked";
    case WorkerLifecycleReason::StaleHeartbeatKill: return "stale-heartbeat-kill";
    case WorkerLifecycleReason::StopRequested: return "stop-requested";
    case WorkerLifecycleReason::ForcedTerminate: return "forced-terminate";
    case WorkerLifecycleReason::Exited: return "exited";
    case WorkerLifecycleReason::GpuInitFailed: return "gpu-init-failed";
    case WorkerLifecycleReason::InteropFailed: return "interop-failed";
    case WorkerLifecycleReason::RenderFailed: return "render-failed";
    default: return "clean-exit";
    }
}

void appendWorkerLifecycleEvent(WorkerLifecycleReason reason, const char* detail = "") {
    char event[96] = {};
    std::snprintf(event, sizeof(event), "worker-lifecycle:%s", workerLifecycleReasonName(reason));
    appendRuntimeEvent(event, detail);
}

bool initializeSharedViewport(bool reset) {
    if (g_sharedViewport != nullptr) {
        return true;
    }
    g_sharedViewportMap = CreateFileMappingA(
        INVALID_HANDLE_VALUE,
        nullptr,
        PAGE_READWRITE,
        0,
        static_cast<DWORD>(sizeof(SharedViewportBuffer)),
        kSharedViewportName);
    if (g_sharedViewportMap == nullptr) {
        return false;
    }

    g_sharedViewport = static_cast<SharedViewportBuffer*>(
        MapViewOfFile(g_sharedViewportMap, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(SharedViewportBuffer)));
    if (g_sharedViewport == nullptr) {
        CloseHandle(g_sharedViewportMap);
        g_sharedViewportMap = nullptr;
        return false;
    }

    if (reset ||
        g_sharedViewport->magic != kSharedViewportMagic ||
        g_sharedViewport->version != kSharedViewportVersion ||
        g_sharedViewport->buildStamp != kSharedViewportBuildStamp ||
        g_sharedViewport->width != kFrameWidth ||
        g_sharedViewport->height != kFrameHeight ||
        g_sharedViewport->displayFormat != kSharedViewportDisplayFormat) {
        std::memset(g_sharedViewport, 0, sizeof(SharedViewportBuffer));
        g_sharedViewport->magic = kSharedViewportMagic;
        g_sharedViewport->version = kSharedViewportVersion;
        g_sharedViewport->buildStamp = kSharedViewportBuildStamp;
        g_sharedViewport->width = kFrameWidth;
        g_sharedViewport->height = kFrameHeight;
        g_sharedViewport->displayFormat = kSharedViewportDisplayFormat;
        g_sharedViewport->workerStatus = 0;
        g_sharedViewport->workerExitCode = 0;
        g_sharedViewport->workerErrorCount = 0;
        g_sharedViewport->workerPublishedFrames = 0;
        g_sharedViewport->workerPhysicsFrames = 0;
        g_sharedViewport->workerRenderOnlyFrames = 0;
        g_haveLastWorkerSettings = false;
        std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "shared viewport initialized");
    }
    return true;
}

void closeSharedViewport() {
    if (g_sharedViewport != nullptr) {
        UnmapViewOfFile(g_sharedViewport);
        g_sharedViewport = nullptr;
    }
    if (g_sharedViewportMap != nullptr) {
        CloseHandle(g_sharedViewportMap);
        g_sharedViewportMap = nullptr;
    }
    g_haveLastWorkerSettings = false;
}

void writeWorkerSettings(const FireSettings& settings) {
    if (g_sharedViewport == nullptr) {
        return;
    }
    if (g_haveLastWorkerSettings && sameFireSettings(g_lastWorkerSettings, settings)) {
        return;
    }
    g_lastWorkerSettings = settings;
    g_haveLastWorkerSettings = true;
    InterlockedIncrement(&g_sharedViewport->settingsSequence);
    g_sharedViewport->settings = settings;
    InterlockedIncrement(&g_sharedViewport->settingsSequence);
}

FireSettings readStableWorkerSettings(const SharedViewportBuffer* shared) {
    FireSettings settings;
    for (int attempt = 0; attempt < 4; ++attempt) {
        const LONG sequenceA = shared->settingsSequence;
        if ((sequenceA & 1) != 0) {
            Sleep(0);
            continue;
        }
        settings = shared->settings;
        const LONG sequenceB = shared->settingsSequence;
        if (sequenceA == sequenceB && (sequenceB & 1) == 0) {
            return settings;
        }
    }
    return shared->settings;
}

bool workerFrameMetadataFresh() {
    if (g_sharedViewport == nullptr ||
        g_sharedViewport->magic != kSharedViewportMagic ||
        g_sharedViewport->version != kSharedViewportVersion ||
        g_sharedViewport->buildStamp != kSharedViewportBuildStamp ||
        g_sharedViewport->width != kFrameWidth ||
        g_sharedViewport->height != kFrameHeight ||
        g_sharedViewport->displayFormat != kSharedViewportDisplayFormat) {
        return false;
    }
    if (tickMs() - g_sharedViewport->lastFrameTickMs > kWorkerFrameStaleMs) {
        return false;
    }
    const LONG latestSlot = g_sharedViewport->latestFrameSlot;
    if (latestSlot >= 0 && latestSlot < kSharedFrameSlots) {
        const LONG latestSequence = g_sharedViewport->slotFrameSequences[latestSlot];
        if (latestSequence > 0 && (latestSequence & 1) == 0) {
            return true;
        }
    }
    return g_lastCopiedWorkerSequence > 0;
}

bool cudaWorkerProcessAlive() {
    if (g_cudaWorkerProcess == nullptr) {
        return false;
    }
    const DWORD wait = WaitForSingleObject(g_cudaWorkerProcess, 0);
    if (wait == WAIT_TIMEOUT) {
        return true;
    }
    DWORD exitCode = 0;
    if (GetExitCodeProcess(g_cudaWorkerProcess, &exitCode)) {
        g_workerLastExitCode = static_cast<int>(exitCode);
        char detail[96] = {};
        std::snprintf(detail, sizeof(detail), "exitCode=%lu", static_cast<unsigned long>(exitCode));
        appendRuntimeEvent("worker-exited", detail);
        appendWorkerLifecycleEvent(WorkerLifecycleReason::Exited, detail);
        if (g_sharedViewport != nullptr) {
            g_sharedViewport->workerExitCode = static_cast<LONG>(exitCode);
            std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "CUDA worker exited: %lu", static_cast<unsigned long>(exitCode));
        }
    }
    CloseHandle(g_cudaWorkerProcess);
    g_cudaWorkerProcess = nullptr;
    return false;
}

bool startCudaWorker() {
    if (cudaWorkerProcessAlive()) {
        return true;
    }
    const unsigned long long now = tickMs();
    if (now < g_workerRestartBlockedUntilMs) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "CUDA worker restart paused after repeated failures");
        return false;
    }
    if (g_workerRestartWindowStartMs == 0 || now - g_workerRestartWindowStartMs > kWorkerRestartWindowMs) {
        g_workerRestartWindowStartMs = now;
        g_workerRestartCount = 0;
    }
    if (g_workerRestartCount >= kWorkerRestartLimit) {
        g_workerRestartBlockedUntilMs = now + kWorkerRestartWindowMs;
        appendRuntimeEvent("worker-restart-blocked", "restart limit reached");
        appendWorkerLifecycleEvent(WorkerLifecycleReason::RestartBlocked, "restart limit reached");
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "CUDA worker disabled for cooldown after repeated exits");
        return false;
    }
    if (now - g_lastWorkerStartTickMs < 2500ull) {
        return false;
    }
    if (!initializeSharedViewport(false)) {
        return false;
    }

    g_lastWorkerStartTickMs = now;
    ++g_workerRestartCount;
    g_sharedViewport->shutdownRequested = 0;
    g_sharedViewport->workerStatus = 0;
    g_sharedViewport->workerStartTickMs = now;
    std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "starting CUDA worker");
    appendRuntimeEvent("worker-starting", "");
    appendWorkerLifecycleEvent(WorkerLifecycleReason::StartRequested);

    char exePath[MAX_PATH] = {};
    if (GetModuleFileNameA(nullptr, exePath, static_cast<DWORD>(sizeof(exePath))) == 0) {
        return false;
    }
    char commandLine[1024] = {};
    std::snprintf(
        commandLine,
        sizeof(commandLine),
        "\"%s\" --cuda-worker --allow-gpu-kernels --accept-bugcheck-risk --parent-pid=%lu",
        exePath,
        static_cast<unsigned long>(GetCurrentProcessId()));

    STARTUPINFOA startup = {};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process = {};
    const BOOL created = CreateProcessA(
        nullptr,
        commandLine,
        nullptr,
        nullptr,
        FALSE,
        CREATE_NO_WINDOW,
        nullptr,
        nullptr,
        &startup,
        &process);
    if (!created) {
        std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "CreateProcess failed: %lu", static_cast<unsigned long>(GetLastError()));
        appendRuntimeEvent("worker-createprocess-failed", g_sharedViewport->statusText);
        appendWorkerLifecycleEvent(WorkerLifecycleReason::CreateProcessFailed, g_sharedViewport->statusText);
        return false;
    }
    CloseHandle(process.hThread);
    g_cudaWorkerProcess = process.hProcess;
    std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "CUDA worker pid %lu starting", static_cast<unsigned long>(process.dwProcessId));
    return true;
}

void stopCudaWorker() {
    appendWorkerLifecycleEvent(WorkerLifecycleReason::StopRequested);
    if (g_sharedViewport != nullptr) {
        g_sharedViewport->shutdownRequested = 1;
    }
    if (g_cudaWorkerProcess != nullptr) {
        if (WaitForSingleObject(g_cudaWorkerProcess, 1800) == WAIT_TIMEOUT) {
            appendWorkerLifecycleEvent(WorkerLifecycleReason::ForcedTerminate, "stop timeout");
            TerminateProcess(g_cudaWorkerProcess, 0);
        }
        CloseHandle(g_cudaWorkerProcess);
        g_cudaWorkerProcess = nullptr;
    }
}

void serviceCudaWorkerWatchdog() {
    if (!g_cudaWorkerRequested || g_sharedViewport == nullptr) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "CUDA worker disabled");
        return;
    }

    const bool alive = cudaWorkerProcessAlive();
    const unsigned long long now = tickMs();
    const unsigned long long heartbeatAge =
        g_sharedViewport->workerHeartbeatTickMs == 0 ? 0 : now - g_sharedViewport->workerHeartbeatTickMs;
    const unsigned long long frameAge =
        g_sharedViewport->lastFrameTickMs == 0 ? 0 : now - g_sharedViewport->lastFrameTickMs;

    if (alive && g_sharedViewport->workerHeartbeatTickMs != 0 && heartbeatAge > kWorkerKillStaleMs) {
        appendRuntimeEvent("worker-stale-kill", "heartbeat exceeded kill threshold");
        appendWorkerLifecycleEvent(WorkerLifecycleReason::StaleHeartbeatKill, "heartbeat exceeded kill threshold");
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "CUDA worker heartbeat stale; restarting");
        g_sharedViewport->shutdownRequested = 1;
        if (g_cudaWorkerProcess != nullptr) {
            TerminateProcess(g_cudaWorkerProcess, 0);
            CloseHandle(g_cudaWorkerProcess);
            g_cudaWorkerProcess = nullptr;
        }
        return;
    }

    if (!alive) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "CUDA worker stopped; restart pending");
        startCudaWorker();
        return;
    }

    const LONG status = g_sharedViewport->workerStatus;
    if (status < 0) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "CUDA worker error: %.120s", g_sharedViewport->statusText);
        g_lastWorkerStatusFormatTickMs = now;
    } else if (g_sharedViewport->lastFrameTickMs != 0 && frameAge <= kWorkerFrameStaleMs) {
        if (now - g_lastWorkerStatusFormatTickMs >= kWorkerStatusUiUpdateMs) {
            std::snprintf(
                g_workerUiStatus,
                sizeof(g_workerUiStatus),
                "%s app %.0f present %.0f copy %.0f physics %.0f pub %.0f ring %ld>%ld age %llums starved %llu",
                fireStreamNeedsOperatorWarning() ? "WARN" : "OK",
                g_visualFps,
                g_livePresentHz,
                g_liveCopiedHz,
                g_workerPhysicsHz,
                g_workerPublishedHz,
                static_cast<long>(g_sharedRingLastCopiedSharedSlot),
                static_cast<long>(g_sharedRingLastCopiedDisplaySlot),
                frameAge,
                g_sharedRingCopyStarvationFrames);
            g_lastWorkerStatusFormatTickMs = now;
        }
    } else if (g_sharedViewport->workerHeartbeatTickMs != 0 && heartbeatAge <= kWorkerHeartbeatStaleMs) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "CUDA worker running; waiting for fresh frame");
    } else {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "CUDA worker starting");
    }
}

bool cudaWorkerEnabledByDefault(const std::string& args) {
    if (args.find("--disable-cuda-worker") != std::string::npos) {
        return false;
    }
    char disabled[16] = {};
    const DWORD disabledSize = GetEnvironmentVariableA("FIRESIM_DISABLE_CUDA_WORKER", disabled, static_cast<DWORD>(sizeof(disabled)));
    return !(disabledSize > 0 && std::string(disabled) == "1");
}

struct WorkerD3DTarget {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<ID3D11Texture2D> cudaTexture;
    std::array<ComPtr<ID3D11Texture2D>, kSharedFrameSlots> sharedTextures;
    std::array<ComPtr<IDXGIKeyedMutex>, kSharedFrameSlots> sharedMutexes;
    std::array<HANDLE, kSharedFrameSlots> sharedHandles = {};
    ComPtr<ID3D11Query> completionQuery;
};

bool initializeWorkerD3DTarget(WorkerD3DTarget& target) {
    if (!createD3DDevice(target.device, target.context)) {
        appendRuntimeEvent("worker-d3d-device-failed", "");
        return false;
    }

    D3D11_TEXTURE2D_DESC desc = {};
    desc.Width = kFrameWidth;
    desc.Height = kFrameHeight;
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = 0;
    desc.MiscFlags = 0;
    HRESULT hr = target.device->CreateTexture2D(&desc, nullptr, target.cudaTexture.GetAddressOf());
    if (FAILED(hr)) {
        char detail[96] = {};
        std::snprintf(detail, sizeof(detail), "%s", hresultString(hr).c_str());
        appendRuntimeEvent("worker-d3d-create-cuda-target-failed", detail);
        return false;
    }

    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX;
    for (int slot = 0; slot < kSharedFrameSlots; ++slot) {
        hr = target.device->CreateTexture2D(&desc, nullptr, target.sharedTextures[slot].GetAddressOf());
        if (FAILED(hr)) {
            char detail[96] = {};
            std::snprintf(detail, sizeof(detail), "slot=%d %s", slot, hresultString(hr).c_str());
            appendRuntimeEvent("worker-d3d-create-shared-failed", detail);
            return false;
        }
        if (FAILED(target.sharedTextures[slot].As(&target.sharedMutexes[slot]))) {
            appendRuntimeEvent("worker-d3d-keyed-mutex-failed", "");
            return false;
        }
        ComPtr<IDXGIResource> sharedResource;
        if (FAILED(target.sharedTextures[slot].As(&sharedResource)) ||
            FAILED(sharedResource->GetSharedHandle(&target.sharedHandles[slot])) ||
            target.sharedHandles[slot] == nullptr) {
            appendRuntimeEvent("worker-d3d-shared-handle-failed", "");
            return false;
        }
    }
    D3D11_QUERY_DESC queryDesc = {};
    queryDesc.Query = D3D11_QUERY_EVENT;
    hr = target.device->CreateQuery(&queryDesc, target.completionQuery.GetAddressOf());
    if (FAILED(hr)) {
        appendRuntimeEvent("worker-d3d-completion-query-failed", hresultString(hr).c_str());
        return false;
    }
    return true;
}

bool waitForWorkerD3DCompletion(WorkerD3DTarget& target) {
    return waitForD3DCompletion(target.context.Get(), target.completionQuery.Get());
}

bool runD3DInteropProbe(std::string& detail) {
    WorkerD3DTarget target;
    if (!initializeWorkerD3DTarget(target)) {
        detail = "D3D FP16 target init failed";
        return false;
    }
    if (!fireCudaSelectDeviceForD3D11(target.device.Get())) {
        detail = fireCudaLastError();
        return false;
    }
    if (!fireCudaRegisterD3D11Texture(target.cudaTexture.Get())) {
        detail = fireCudaLastError();
        return false;
    }
    fireCudaUnregisterD3D11Texture();
    detail = "ok";
    return true;
}

int runWorkerBenchmark(const std::string& args) {
    if (!gpuKernelLaunchAllowed(args)) {
        return writeGpuSafetyStop("worker-benchmark");
    }
    for (int scene = 0; scene < kSceneCount; ++scene) {
        g_sceneEmitters[scene] = loadSceneEmitterParams(scene);
    }
    ensureDirectoryTree("out");
    const std::string outputDirArg = argumentValue(args, "--output-dir=");
    const std::string outputDir = outputDirArg.empty() ? "out\\worker-benchmark" : outputDirArg;
    const int benchmarkFrames = argumentIntValue(args, "--benchmark-frames=", 16, 4, 120);
    const int warmupFrames = argumentIntValue(args, "--warmup-frames=", 8, 0, 120);
    const int simEveryFrames = argumentIntValue(args, "--sim-every-frames=", 1, 0, 600);
    const bool renderOnlyMode = args.find("--render-only") != std::string::npos || simEveryFrames == 0;
    if (!ensureDirectoryTree(outputDir)) {
        return 3;
    }

    WorkerD3DTarget target;
    bool ok = initializeWorkerD3DTarget(target);
    if (ok) {
        ok = fireCudaSelectDeviceForD3D11(target.device.Get());
    }
    if (ok) {
        ok = fireCudaInitialize(kFrameWidth, kFrameHeight, kSimulationGridWidth, kSimulationGridHeight);
    }
    if (ok) {
        ok = fireCudaRegisterD3D11Texture(target.cudaTexture.Get());
    }
    if (!ok) {
        const std::string reportPath = joinPath(outputDir, "worker-benchmark.json");
        std::ofstream report(reportPath, std::ios::binary);
        if (report) {
            report << "{\n";
            report << "  \"workerBenchmarkOk\": false,\n";
            report << "  \"error\": \"" << jsonEscape(fireCudaLastError()) << "\"\n";
            report << "}\n";
        }
        fireCudaUnregisterD3D11Texture();
        fireCudaShutdown();
        return 4;
    }

    using Clock = std::chrono::high_resolution_clock;
    double totalCudaMs = 0.0;
    double totalPublishMs = 0.0;
    double totalFrameMs = 0.0;
    double totalVelocityMs = 0.0;
    double totalReactionMs = 0.0;
    double totalProjectionMs = 0.0;
    double totalLightingMs = 0.0;
    double totalRaymarchMs = 0.0;
    double totalPackMs = 0.0;
    int completedFrames = 0;
    int metricFrames = 0;
    int physicsFrames = 0;
    int renderOnlyFrames = 0;
    bool stable = true;

    const auto makeBenchmarkSettings = [](int i) {
        FireSettings settings;
        settings.width = kFrameWidth;
        settings.height = kFrameHeight;
        settings.dt = 1.0f / 60.0f;
        settings.mouseX = 0.50f + 0.04f * std::sin(static_cast<float>(i) * 0.11f);
        settings.mouseY = 0.12f + 0.02f * std::sin(static_cast<float>(i) * 0.07f);
        settings.leftDown = 1;
        settings.rightDown = 0;
        settings.showGizmos = 0;
        settings.activeGizmo = 1;
        settings.wind = 0.0f;
        settings.cameraYaw = 0.18f;
        settings.cameraPitch = 0.08f;
        settings.cameraDistance = 2.62f;
        applyCanonicalFireSettings(settings);
        applySceneEmitterParams(settings);
        return settings;
    };

    if (renderOnlyMode) {
        FireSettings settings = makeBenchmarkSettings(0);
        if (!fireCudaStepAndRenderD3D11(settings)) {
            stable = false;
        } else {
            ++physicsFrames;
        }
    }

    for (int i = 0; i < warmupFrames + benchmarkFrames; ++i) {
        if (!stable) {
            break;
        }
        const bool measureFrame = i >= warmupFrames;
        FireSettings settings = makeBenchmarkSettings(i);
        const bool advancePhysics = !renderOnlyMode && (i == 0 || (simEveryFrames > 0 && (i % simEveryFrames) == 0));
        const auto frameStart = Clock::now();
        if (advancePhysics) {
            ++physicsFrames;
        } else {
            ++renderOnlyFrames;
        }
        if (!(advancePhysics ? fireCudaStepAndRenderD3D11(settings) : fireCudaRenderD3D11(settings))) {
            stable = false;
            break;
        }
        const auto cudaDone = Clock::now();
        const HRESULT acquire = target.sharedMutexes[0]->AcquireSync(0, 8);
        if (FAILED(acquire)) {
            stable = false;
            break;
        }
        target.context->CopyResource(target.sharedTextures[0].Get(), target.cudaTexture.Get());
        if (!waitForWorkerD3DCompletion(target)) {
            stable = false;
            break;
        }
        const HRESULT release = target.sharedMutexes[0]->ReleaseSync(0);
        if (FAILED(release)) {
            stable = false;
            break;
        }
        const auto published = Clock::now();
        if (measureFrame) {
            totalCudaMs += std::chrono::duration<double, std::milli>(cudaDone - frameStart).count();
            totalPublishMs += std::chrono::duration<double, std::milli>(published - cudaDone).count();
            totalFrameMs += std::chrono::duration<double, std::milli>(published - frameStart).count();
            ++completedFrames;
        }
    }

    if (stable) {
        const int requestedMetricFrames = std::min(3, std::max(1, benchmarkFrames));
        for (int j = 0; j < requestedMetricFrames; ++j) {
            FireSettings settings = makeBenchmarkSettings(warmupFrames + benchmarkFrames + j);
            FireCudaFrameMetrics metrics = {};
            if (!fireCudaStepAndRenderD3D11Measured(settings, &metrics)) {
                stable = false;
                break;
            }
            totalVelocityMs += metrics.gpuVelocityMs;
            totalReactionMs += metrics.gpuReactionMs;
            totalProjectionMs += metrics.gpuProjectionMs;
            totalLightingMs += metrics.gpuLightingMs;
            totalRaymarchMs += metrics.gpuRaymarchMs;
            totalPackMs += metrics.gpuPackMs;
            ++metricFrames;
        }
    }

    fireCudaUnregisterD3D11Texture();
    fireCudaShutdown();

    stable = stable && completedFrames == benchmarkFrames;
    const double frames = static_cast<double>(std::max(1, completedFrames));
    const double measuredMetricFrames = static_cast<double>(std::max(1, metricFrames));
    const double averageSubmitMs = totalCudaMs / frames;
    const double averagePublishMs = totalPublishMs / frames;
    const double averageFrameMs = totalFrameMs / frames;
    const double averageCudaMs = averageSubmitMs;
    const double averageVelocityMs = totalVelocityMs / measuredMetricFrames;
    const double averageReactionMs = totalReactionMs / measuredMetricFrames;
    const double averageProjectionMs = totalProjectionMs / measuredMetricFrames;
    const double averageLightingMs = totalLightingMs / measuredMetricFrames;
    const double averageRaymarchMs = totalRaymarchMs / measuredMetricFrames;
    const double averagePackMs = totalPackMs / measuredMetricFrames;
    std::array<std::pair<const char*, double>, 6> hotspots = {{
        {"velocity", averageVelocityMs},
        {"reaction", averageReactionMs},
        {"projection", averageProjectionMs},
        {"lighting", averageLightingMs},
        {"raymarch", averageRaymarchMs},
        {"pack", averagePackMs},
    }};
    std::sort(hotspots.begin(), hotspots.end(), [](const auto& a, const auto& b) {
        return a.second > b.second;
    });
    const std::string reportPath = joinPath(outputDir, "worker-benchmark.json");
    std::ofstream report(reportPath, std::ios::binary);
    if (!report) {
        return 3;
    }
    report << std::fixed << std::setprecision(6);
    report << "{\n";
    report << "  \"workerBenchmarkOk\": " << (stable ? "true" : "false") << ",\n";
    report << "  \"frames\": " << completedFrames << ",\n";
    report << "  \"requestedFrames\": " << benchmarkFrames << ",\n";
    report << "  \"warmupFrames\": " << warmupFrames << ",\n";
    report << "  \"metricFrames\": " << metricFrames << ",\n";
    report << "  \"physicsFramesSubmitted\": " << physicsFrames << ",\n";
    report << "  \"renderOnlyFramesSubmitted\": " << renderOnlyFrames << ",\n";
    report << "  \"simEveryFrames\": " << simEveryFrames << ",\n";
    report << "  \"timingMode\": \"live frames timed without metrics; GPU breakdown sampled after live timing\",\n";
    report << "  \"requestedGrid\": [" << kSimulationGridWidth << ", " << kSimulationGridHeight << "],\n";
    report << "  \"raymarchSteps\": " << kRaymarchSteps << ",\n";
    report << "  \"emberCount\": " << kEmberCount << ",\n";
    report << "  \"pressureIterations\": 40,\n";
    report << "  \"averageCudaMs\": " << averageCudaMs << ",\n";
    report << "  \"averageSubmitMs\": " << averageSubmitMs << ",\n";
    report << "  \"averagePublishMs\": " << averagePublishMs << ",\n";
    report << "  \"averageFrameMs\": " << averageFrameMs << ",\n";
    report << "  \"averageGpuVelocityMs\": " << averageVelocityMs << ",\n";
    report << "  \"averageGpuReactionMs\": " << averageReactionMs << ",\n";
    report << "  \"averageGpuProjectionMs\": " << averageProjectionMs << ",\n";
    report << "  \"averageGpuLightingMs\": " << averageLightingMs << ",\n";
    report << "  \"averageGpuRaymarchMs\": " << averageRaymarchMs << ",\n";
    report << "  \"averageGpuPackMs\": " << averagePackMs << ",\n";
    report << "  \"effectiveFps\": " << (averageFrameMs > 0.0 ? 1000.0 / averageFrameMs : 0.0) << ",\n";
    report << "  \"hotspotRanking\": [\n";
    for (std::size_t i = 0; i < hotspots.size(); ++i) {
        report << "    {\"pass\": \"" << hotspots[i].first << "\", \"averageMs\": " << hotspots[i].second << "}";
        report << (i + 1 == hotspots.size() ? "\n" : ",\n");
    }
    report << "  ],\n";
    report << "  \"hotspotPolicy\": \"rank measured CUDA passes before optimizing; do not lower quality to improve FPS in this pass\",\n";
    report << "  \"output\": \"" << jsonEscape(reportPath) << "\"\n";
    report << "}\n";
    return stable ? 0 : 4;
}

int runCudaWorker(const std::string& args) {
    if (!gpuKernelLaunchAllowed(args)) {
        return writeGpuSafetyStop("cuda-worker");
    }
    TimerResolutionScope timerResolution;
    for (int scene = 0; scene < kSceneCount; ++scene) {
        g_sceneEmitters[scene] = loadSceneEmitterParams(scene);
    }
    if (!initializeSharedViewport(false)) {
        return 2;
    }

    const std::string parentPidText = argumentValue(args, "--parent-pid=");
    HANDLE parentProcess = nullptr;
    if (!parentPidText.empty()) {
        const DWORD parentPid = static_cast<DWORD>(std::strtoul(parentPidText.c_str(), nullptr, 10));
        parentProcess = OpenProcess(SYNCHRONIZE, FALSE, parentPid);
    }

    g_sharedViewport->workerStatus = 1;
    g_sharedViewport->magic = kSharedViewportMagic;
    g_sharedViewport->version = kSharedViewportVersion;
    g_sharedViewport->buildStamp = kSharedViewportBuildStamp;
    g_sharedViewport->width = kFrameWidth;
    g_sharedViewport->height = kFrameHeight;
    g_sharedViewport->displayFormat = kSharedViewportDisplayFormat;
    g_sharedViewport->workerPid = GetCurrentProcessId();
    g_sharedViewport->workerStartTickMs = tickMs();
    g_sharedViewport->workerHeartbeatTickMs = tickMs();
    std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "initializing CUDA worker");
    appendRuntimeEvent("worker-process-entered", "");

    WorkerD3DTarget d3dTarget;
    if (!initializeWorkerD3DTarget(d3dTarget)) {
        g_sharedViewport->workerStatus = -3;
        InterlockedIncrement(&g_sharedViewport->workerErrorCount);
        g_sharedViewport->workerExitCode = 5;
        std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "D3D FP16 target init failed");
            appendRuntimeEvent("worker-d3d-target-init-failed", g_sharedViewport->statusText);
            appendWorkerLifecycleEvent(WorkerLifecycleReason::InteropFailed, g_sharedViewport->statusText);
        if (parentProcess != nullptr) {
            CloseHandle(parentProcess);
        }
        return 5;
    }
    if (!fireCudaSelectDeviceForD3D11(d3dTarget.device.Get())) {
        g_sharedViewport->workerStatus = -3;
        InterlockedIncrement(&g_sharedViewport->workerErrorCount);
        g_sharedViewport->workerExitCode = 5;
        std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "D3D device CUDA selection failed: %.130s", fireCudaLastError());
        appendRuntimeEvent("worker-cuda-d3d-device-select-failed", g_sharedViewport->statusText);
        if (parentProcess != nullptr) {
            CloseHandle(parentProcess);
        }
        return 5;
    }
    if (!fireCudaInitialize(kFrameWidth, kFrameHeight, kSimulationGridWidth, kSimulationGridHeight)) {
        g_sharedViewport->workerStatus = -1;
        InterlockedIncrement(&g_sharedViewport->workerErrorCount);
        g_sharedViewport->workerExitCode = 3;
        std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "CUDA init failed: %.150s", fireCudaLastError());
        appendRuntimeEvent("worker-cuda-init-failed", g_sharedViewport->statusText);
        appendWorkerLifecycleEvent(WorkerLifecycleReason::GpuInitFailed, g_sharedViewport->statusText);
        if (parentProcess != nullptr) {
            CloseHandle(parentProcess);
        }
        return 3;
    }
    appendRuntimeEvent("worker-cuda-initialized", "");
    bool registeredSharedInterop = true;
    for (int slot = 0; slot < kSharedFrameSlots; ++slot) {
        if (!fireCudaRegisterD3D11TextureSlot(slot, d3dTarget.sharedTextures[slot].Get())) {
            registeredSharedInterop = false;
            break;
        }
    }
    if (!registeredSharedInterop || !fireCudaSetD3D11TextureSlot(0)) {
        g_sharedViewport->workerStatus = -3;
        InterlockedIncrement(&g_sharedViewport->workerErrorCount);
        g_sharedViewport->workerExitCode = 5;
        std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "D3D/CUDA FP16 interop init failed");
        appendRuntimeEvent("worker-cuda-d3d-register-failed", fireCudaLastError());
        appendRuntimeEvent("worker-d3d-interop-init-failed", g_sharedViewport->statusText);
        appendWorkerLifecycleEvent(WorkerLifecycleReason::InteropFailed, g_sharedViewport->statusText);
        fireCudaShutdown();
        if (parentProcess != nullptr) {
            CloseHandle(parentProcess);
        }
        return 5;
    }
    g_sharedViewport->sharedTextureHandleValue = static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(d3dTarget.sharedHandles[0]));
    for (int slot = 0; slot < kSharedFrameSlots; ++slot) {
        g_sharedViewport->sharedTextureHandleValues[slot] = static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(d3dTarget.sharedHandles[slot]));
        g_sharedViewport->slotFrameSequences[slot] = 0;
    }
    g_sharedViewport->latestFrameSlot = -1;
    appendRuntimeEvent("worker-cuda-d3d-registered", "");

    using Clock = std::chrono::high_resolution_clock;
    auto last = Clock::now();
    int framesSincePhysics = kWorkerPhysicsFrameInterval;
    float accumulatedPhysicsDt = 0.0f;
    int nextPublishSlot = 0;
    while (g_sharedViewport->shutdownRequested == 0) {
        if (parentProcess != nullptr && WaitForSingleObject(parentProcess, 0) != WAIT_TIMEOUT) {
            break;
        }

        g_sharedViewport->workerHeartbeatTickMs = tickMs();

        const auto now = Clock::now();
        float dt = std::chrono::duration<float>(now - last).count();
        last = now;
        dt = std::max(1.0f / 240.0f, std::min(dt, 1.0f / 30.0f));
        accumulatedPhysicsDt = std::min(accumulatedPhysicsDt + dt, 0.25f);

        FireSettings settings = readStableWorkerSettings(g_sharedViewport);
        settings.width = kFrameWidth;
        settings.height = kFrameHeight;

        const bool advancePhysics = settings.reset != 0 || framesSincePhysics >= kWorkerPhysicsFrameInterval;
        settings.dt = advancePhysics ? std::max(dt, accumulatedPhysicsDt) : dt;
        applyCanonicalFireSettings(settings);
        applySceneEmitterParams(settings);
        int publishSlot = -1;
        const auto frameStart = Clock::now();
        HRESULT acquire = static_cast<HRESULT>(WAIT_TIMEOUT);
        for (int attempt = 0; attempt < kSharedFrameSlots; ++attempt) {
            const int candidate = (nextPublishSlot + attempt) % kSharedFrameSlots;
            acquire = d3dTarget.sharedMutexes[candidate]->AcquireSync(0, 0);
            if (acquire != static_cast<HRESULT>(WAIT_TIMEOUT)) {
                publishSlot = candidate;
                break;
            }
        }
        if (publishSlot < 0) {
            g_sharedViewport->workerHeartbeatTickMs = tickMs();
            g_sharedViewport->workerCudaMicros = 0;
            g_sharedViewport->workerFrameMicros = 0;
            g_sharedViewport->workerPublishMicros = 0;
            g_sharedViewport->workerStatus = 2;
            std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "CUDA worker publish slot busy");
            Sleep(0);
            continue;
        }
        if (FAILED(acquire)) {
            g_sharedViewport->workerStatus = -4;
            InterlockedIncrement(&g_sharedViewport->workerErrorCount);
            g_sharedViewport->workerExitCode = 6;
            std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "D3D keyed mutex acquire failed: %.80s", hresultString(acquire).c_str());
            appendRuntimeEvent("worker-d3d-acquire-failed", g_sharedViewport->statusText);
            break;
        }

        const LONG writingSequence = InterlockedIncrement(&g_sharedViewport->frameSequence);
        g_sharedViewport->slotFrameSequences[publishSlot] = writingSequence;
        if (!fireCudaSetD3D11TextureSlot(publishSlot)) {
            d3dTarget.sharedMutexes[publishSlot]->ReleaseSync(0);
            g_sharedViewport->workerStatus = -3;
            InterlockedIncrement(&g_sharedViewport->workerErrorCount);
            g_sharedViewport->workerExitCode = 5;
            std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "CUDA select FP16 shared slot failed: %.120s", fireCudaLastError());
            appendRuntimeEvent("worker-cuda-d3d-select-failed", g_sharedViewport->statusText);
            break;
        }
        if (!(advancePhysics ? fireCudaStepAndRenderD3D11(settings) : fireCudaRenderD3D11(settings))) {
            d3dTarget.sharedMutexes[publishSlot]->ReleaseSync(0);
            g_sharedViewport->workerStatus = -2;
            InterlockedIncrement(&g_sharedViewport->workerErrorCount);
            g_sharedViewport->workerExitCode = 4;
            std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "CUDA %s failed: %.142s", advancePhysics ? "step" : "render", fireCudaLastError());
            appendRuntimeEvent("worker-cuda-render-failed", g_sharedViewport->statusText);
            appendWorkerLifecycleEvent(WorkerLifecycleReason::RenderFailed, g_sharedViewport->statusText);
            break;
        }
        if (!fireCudaSynchronize()) {
            d3dTarget.sharedMutexes[publishSlot]->ReleaseSync(0);
            g_sharedViewport->workerStatus = -2;
            InterlockedIncrement(&g_sharedViewport->workerErrorCount);
            g_sharedViewport->workerExitCode = 4;
            std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "CUDA synchronize failed: %.142s", fireCudaLastError());
            appendRuntimeEvent("worker-cuda-sync-failed", g_sharedViewport->statusText);
            break;
        }
        if (advancePhysics) {
            accumulatedPhysicsDt = 0.0f;
            framesSincePhysics = 0;
        } else {
            framesSincePhysics += 1;
        }
        const auto cudaDone = Clock::now();
        const HRESULT release = d3dTarget.sharedMutexes[publishSlot]->ReleaseSync(1);
        if (FAILED(release)) {
            g_sharedViewport->workerStatus = -5;
            InterlockedIncrement(&g_sharedViewport->workerErrorCount);
            g_sharedViewport->workerExitCode = 7;
            std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "D3D keyed mutex release failed: %.80s", hresultString(release).c_str());
            appendRuntimeEvent("worker-d3d-release-failed", g_sharedViewport->statusText);
            break;
        }
        const auto submitted = Clock::now();
        const LONG readySequence = InterlockedIncrement(&g_sharedViewport->frameSequence);
        g_sharedViewport->slotFrameSequences[publishSlot] = readySequence;
        g_sharedViewport->latestFrameSlot = publishSlot;
        nextPublishSlot = (publishSlot + 1) % kSharedFrameSlots;
        InterlockedIncrement(&g_sharedViewport->workerPublishedFrames);
        if (advancePhysics) {
            InterlockedIncrement(&g_sharedViewport->workerPhysicsFrames);
        } else {
            InterlockedIncrement(&g_sharedViewport->workerRenderOnlyFrames);
        }

        const auto targetFrameDuration = std::chrono::duration<double>(1.0 / static_cast<double>(kWorkerMaxPublishFps));
        const auto nextPublishTime = frameStart + std::chrono::duration_cast<Clock::duration>(targetFrameDuration);
        while (Clock::now() < nextPublishTime) {
            const auto remaining = std::chrono::duration<double, std::milli>(nextPublishTime - Clock::now()).count();
            Sleep(remaining > 1.8 ? 1 : 0);
        }
        const auto published = Clock::now();

        g_sharedViewport->lastFrameTickMs = tickMs();
        g_sharedViewport->workerCudaMicros = static_cast<unsigned long long>(std::chrono::duration_cast<std::chrono::microseconds>(cudaDone - frameStart).count());
        g_sharedViewport->workerFrameMicros = static_cast<unsigned long long>(std::chrono::duration_cast<std::chrono::microseconds>(published - frameStart).count());
        g_sharedViewport->workerPublishMicros = static_cast<unsigned long long>(std::chrono::duration_cast<std::chrono::microseconds>(submitted - cudaDone).count());
        g_sharedViewport->workerStatus = 2;
        std::snprintf(
            g_sharedViewport->statusText,
            sizeof(g_sharedViewport->statusText),
            "CUDA worker streaming FP16 D3D11 ring slot %d %s",
            publishSlot,
            advancePhysics ? "physics" : "render");
    }

    fireCudaUnregisterD3D11Texture();
    fireCudaShutdown();
    g_sharedViewport->sharedTextureHandleValue = 0;
    for (int slot = 0; slot < kSharedFrameSlots; ++slot) {
        g_sharedViewport->sharedTextureHandleValues[slot] = 0;
        g_sharedViewport->slotFrameSequences[slot] = 0;
    }
    g_sharedViewport->latestFrameSlot = -1;
    g_sharedViewport->workerStatus = 0;
    g_sharedViewport->workerStopTickMs = tickMs();
    std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "CUDA worker stopped");
    appendRuntimeEvent("worker-process-exiting", "");
    appendWorkerLifecycleEvent(WorkerLifecycleReason::CleanExit);
    if (parentProcess != nullptr) {
        CloseHandle(parentProcess);
    }
    closeSharedViewport();
    return 0;
}

std::vector<TargetEnvelope> loadTargetEnvelopes(const std::string& path) {
    std::vector<TargetEnvelope> targets;
    if (path.empty()) {
        return targets;
    }
    std::ifstream in(path);
    if (!in) {
        return targets;
    }
    std::string line;
    while (std::getline(in, line)) {
        line = trim(line);
        if (line.empty() || line[0] == '#') {
            continue;
        }
        const std::size_t firstComma = line.find(',');
        const std::size_t secondComma = firstComma == std::string::npos ? std::string::npos : line.find(',', firstComma + 1);
        if (firstComma == std::string::npos || secondComma == std::string::npos) {
            continue;
        }
        TargetEnvelope target;
        target.metric = trim(line.substr(0, firstComma));
        if (target.metric == "metric") {
            continue;
        }
        target.minimum = std::strtof(trim(line.substr(firstComma + 1, secondComma - firstComma - 1)).c_str(), nullptr);
        target.maximum = std::strtof(trim(line.substr(secondComma + 1)).c_str(), nullptr);
        targets.push_back(target);
    }
    return targets;
}

struct CalibrationSample {
    float timeSeconds = 0.0f;
    float hrrKw = 0.0f;
    float massRemainingKg = 0.0f;
    float smokeOpticalDepth = 0.0f;
    float smokeExtinctionCoefficientPerM = 0.0f;
    float radiantHeatFluxKwPerM2 = 0.0f;
    float thermocoupleMeanC = 0.0f;
    float irMeanC = 0.0f;
    float irMaxC = 0.0f;
    float plumeHeightMeters = 0.0f;
    bool hasHrr = false;
    bool hasMass = false;
    bool hasSmokeOpticalDepth = false;
    bool hasSmokeExtinctionCoefficient = false;
    bool hasRadiantHeatFlux = false;
    bool hasThermocouple = false;
    bool hasIrMean = false;
    bool hasIrMax = false;
    bool hasPlumeHeight = false;
};

struct CalibrationReport {
    bool calibrationProvided = false;
    bool calibrationReadable = false;
    bool geometryProvided = false;
    bool geometryReadable = false;
    int sampleCount = 0;
    float hrrShapeRmse = -1.0f;
    float massShapeRmse = -1.0f;
    float thermocoupleShapeRmse = -1.0f;
    float irMeanShapeRmse = -1.0f;
    float irMaxShapeRmse = -1.0f;
    float plumeHeightRmseMeters = -1.0f;
    float smokeOpticalDepthShapeRmse = -1.0f;
    float smokeExtinctionShapeRmse = -1.0f;
    float radiantHeatFluxShapeRmse = -1.0f;
    int hrrSamplesCompared = 0;
    int massSamplesCompared = 0;
    int smokeOpticalDepthSamplesCompared = 0;
    int smokeExtinctionSamplesCompared = 0;
    int radiantHeatFluxSamplesCompared = 0;
};

std::vector<std::string> splitCsvLine(const std::string& line) {
    std::vector<std::string> values;
    std::string current;
    bool quoted = false;
    for (const char c : line) {
        if (c == '"') {
            quoted = !quoted;
        } else if (c == ',' && !quoted) {
            values.push_back(trim(current));
            current.clear();
        } else {
            current += c;
        }
    }
    values.push_back(trim(current));
    return values;
}

float parseOptionalFloat(const std::string& value, bool* ok) {
    const std::string clean = trim(value);
    if (clean.empty()) {
        *ok = false;
        return 0.0f;
    }
    char* end = nullptr;
    const float parsed = std::strtof(clean.c_str(), &end);
    *ok = end != clean.c_str();
    return parsed;
}

bool fileReadable(const std::string& path) {
    if (path.empty()) {
        return false;
    }
    std::ifstream in(path, std::ios::binary);
    return in.good();
}

std::vector<CalibrationSample> loadCalibrationSamples(const std::string& path) {
    std::vector<CalibrationSample> samples;
    if (path.empty()) {
        return samples;
    }
    std::ifstream in(path);
    if (!in) {
        return samples;
    }
    std::string line;
    if (!std::getline(in, line)) {
        return samples;
    }
    std::vector<std::string> headers = splitCsvLine(line);
    for (std::string& header : headers) {
        header = trim(header);
    }

    while (std::getline(in, line)) {
        line = trim(line);
        if (line.empty() || line[0] == '#') {
            continue;
        }
        const std::vector<std::string> values = splitCsvLine(line);
        CalibrationSample sample;
        float tcSum = 0.0f;
        int tcCount = 0;
        for (std::size_t i = 0; i < headers.size() && i < values.size(); ++i) {
            bool ok = false;
            const float parsed = parseOptionalFloat(values[i], &ok);
            if (!ok) {
                continue;
            }
            const std::string& header = headers[i];
            if (header == "timeSeconds") {
                sample.timeSeconds = parsed;
            } else if (header == "hrrKW") {
                sample.hrrKw = parsed;
                sample.hasHrr = true;
            } else if (header == "massRemainingKg") {
                sample.massRemainingKg = parsed;
                sample.hasMass = true;
            } else if (header == "smokeOpticalDepth") {
                sample.smokeOpticalDepth = parsed;
                sample.hasSmokeOpticalDepth = true;
            } else if (header == "smokeExtinctionCoefficientPerM") {
                sample.smokeExtinctionCoefficientPerM = parsed;
                sample.hasSmokeExtinctionCoefficient = true;
            } else if (header == "radiantHeatFluxKWPerM2") {
                sample.radiantHeatFluxKwPerM2 = parsed;
                sample.hasRadiantHeatFlux = true;
            } else if (header == "irMeanC") {
                sample.irMeanC = parsed;
                sample.hasIrMean = true;
            } else if (header == "irMaxC") {
                sample.irMaxC = parsed;
                sample.hasIrMax = true;
            } else if (header == "plumeHeightM") {
                sample.plumeHeightMeters = parsed;
                sample.hasPlumeHeight = true;
            } else if (header.rfind("tc_", 0) == 0) {
                tcSum += parsed;
                ++tcCount;
            }
        }
        if (tcCount > 0) {
            sample.thermocoupleMeanC = tcSum / static_cast<float>(tcCount);
            sample.hasThermocouple = true;
        }
        samples.push_back(sample);
    }
    return samples;
}

float normalizedValue(float value, float minValue, float maxValue) {
    const float span = maxValue - minValue;
    if (span <= 0.000001f) {
        return 0.0f;
    }
    return (value - minValue) / span;
}

float simMassProxy(const FireCudaFrameMetrics& frame) {
    return frame.fuelSum + frame.charSum;
}

float simRadiantEnergyProxy(const FireCudaFrameMetrics& frame) {
    const float cellCount = static_cast<float>(std::max(1, frame.gridX * frame.gridY * frame.gridZ));
    return frame.heatSum / cellCount;
}

CalibrationReport compareCalibrationSeries(
    const std::string& calibrationPath,
    const std::string& geometryPath,
    const std::vector<FireCudaFrameMetrics>& frames) {
    CalibrationReport report;
    report.calibrationProvided = !calibrationPath.empty();
    report.geometryProvided = !geometryPath.empty();
    report.geometryReadable = geometryPath.empty() || fileReadable(geometryPath);
    if (calibrationPath.empty()) {
        return report;
    }

    const std::vector<CalibrationSample> samples = loadCalibrationSamples(calibrationPath);
    report.calibrationReadable = !samples.empty();
    report.sampleCount = static_cast<int>(samples.size());
    if (samples.empty() || frames.empty()) {
        return report;
    }

    float hrrMin = FLT_MAX;
    float hrrMax = -FLT_MAX;
    float simHrrMin = FLT_MAX;
    float simHrrMax = -FLT_MAX;
    float massMin = FLT_MAX;
    float massMax = -FLT_MAX;
    float simMassMin = FLT_MAX;
    float simMassMax = -FLT_MAX;
    float tcMin = FLT_MAX;
    float tcMax = -FLT_MAX;
    float simThermalMin = FLT_MAX;
    float simThermalMax = -FLT_MAX;
    float irMeanMin = FLT_MAX;
    float irMeanMax = -FLT_MAX;
    float simIrMeanMin = FLT_MAX;
    float simIrMeanMax = -FLT_MAX;
    float irMaxMin = FLT_MAX;
    float irMaxMax = -FLT_MAX;
    float simIrMaxMin = FLT_MAX;
    float simIrMaxMax = -FLT_MAX;
    float smokeOpticalDepthMin = FLT_MAX;
    float smokeOpticalDepthMax = -FLT_MAX;
    float simSmokeOpticalDepthMin = FLT_MAX;
    float simSmokeOpticalDepthMax = -FLT_MAX;
    float smokeExtinctionMin = FLT_MAX;
    float smokeExtinctionMax = -FLT_MAX;
    float simSmokeExtinctionMin = FLT_MAX;
    float simSmokeExtinctionMax = -FLT_MAX;
    float radiantHeatFluxMin = FLT_MAX;
    float radiantHeatFluxMax = -FLT_MAX;
    float simRadiantHeatFluxMin = FLT_MAX;
    float simRadiantHeatFluxMax = -FLT_MAX;

    for (std::size_t i = 0; i < samples.size(); ++i) {
        const std::size_t frameIndex = samples.size() <= 1 ? 0 : (i * (frames.size() - 1)) / (samples.size() - 1);
        const FireCudaFrameMetrics& frame = frames[frameIndex];
        const float cellCount = static_cast<float>(std::max(1, frame.gridX * frame.gridY * frame.gridZ));
        if (samples[i].hasHrr) {
            hrrMin = std::min(hrrMin, samples[i].hrrKw);
            hrrMax = std::max(hrrMax, samples[i].hrrKw);
            simHrrMin = std::min(simHrrMin, frame.heatReleaseProxy);
            simHrrMax = std::max(simHrrMax, frame.heatReleaseProxy);
        }
        if (samples[i].hasMass) {
            massMin = std::min(massMin, samples[i].massRemainingKg);
            massMax = std::max(massMax, samples[i].massRemainingKg);
            simMassMin = std::min(simMassMin, simMassProxy(frame));
            simMassMax = std::max(simMassMax, simMassProxy(frame));
        }
        if (samples[i].hasThermocouple) {
            tcMin = std::min(tcMin, samples[i].thermocoupleMeanC);
            tcMax = std::max(tcMax, samples[i].thermocoupleMeanC);
            simThermalMin = std::min(simThermalMin, frame.heatSum / cellCount);
            simThermalMax = std::max(simThermalMax, frame.heatSum / cellCount);
        }
        if (samples[i].hasIrMean) {
            irMeanMin = std::min(irMeanMin, samples[i].irMeanC);
            irMeanMax = std::max(irMeanMax, samples[i].irMeanC);
            simIrMeanMin = std::min(simIrMeanMin, frame.heatSum / cellCount);
            simIrMeanMax = std::max(simIrMeanMax, frame.heatSum / cellCount);
        }
        if (samples[i].hasIrMax) {
            irMaxMin = std::min(irMaxMin, samples[i].irMaxC);
            irMaxMax = std::max(irMaxMax, samples[i].irMaxC);
            simIrMaxMin = std::min(simIrMaxMin, frame.maxHeat);
            simIrMaxMax = std::max(simIrMaxMax, frame.maxHeat);
        }
        if (samples[i].hasSmokeOpticalDepth) {
            smokeOpticalDepthMin = std::min(smokeOpticalDepthMin, samples[i].smokeOpticalDepth);
            smokeOpticalDepthMax = std::max(smokeOpticalDepthMax, samples[i].smokeOpticalDepth);
            simSmokeOpticalDepthMin = std::min(simSmokeOpticalDepthMin, frame.meanOpticalDepth);
            simSmokeOpticalDepthMax = std::max(simSmokeOpticalDepthMax, frame.meanOpticalDepth);
        }
        if (samples[i].hasSmokeExtinctionCoefficient) {
            smokeExtinctionMin = std::min(smokeExtinctionMin, samples[i].smokeExtinctionCoefficientPerM);
            smokeExtinctionMax = std::max(smokeExtinctionMax, samples[i].smokeExtinctionCoefficientPerM);
            simSmokeExtinctionMin = std::min(simSmokeExtinctionMin, frame.meanOpticalDepth);
            simSmokeExtinctionMax = std::max(simSmokeExtinctionMax, frame.meanOpticalDepth);
        }
        if (samples[i].hasRadiantHeatFlux) {
            radiantHeatFluxMin = std::min(radiantHeatFluxMin, samples[i].radiantHeatFluxKwPerM2);
            radiantHeatFluxMax = std::max(radiantHeatFluxMax, samples[i].radiantHeatFluxKwPerM2);
            simRadiantHeatFluxMin = std::min(simRadiantHeatFluxMin, simRadiantEnergyProxy(frame));
            simRadiantHeatFluxMax = std::max(simRadiantHeatFluxMax, simRadiantEnergyProxy(frame));
        }
    }

    double hrrError = 0.0;
    double massError = 0.0;
    double tcError = 0.0;
    double irMeanError = 0.0;
    double irMaxError = 0.0;
    double plumeError = 0.0;
    double smokeOpticalDepthError = 0.0;
    double smokeExtinctionError = 0.0;
    double radiantHeatFluxError = 0.0;
    int hrrCount = 0;
    int massCount = 0;
    int tcCount = 0;
    int irMeanCount = 0;
    int irMaxCount = 0;
    int plumeCount = 0;
    int smokeOpticalDepthCount = 0;
    int smokeExtinctionCount = 0;
    int radiantHeatFluxCount = 0;
    for (std::size_t i = 0; i < samples.size(); ++i) {
        const std::size_t frameIndex = samples.size() <= 1 ? 0 : (i * (frames.size() - 1)) / (samples.size() - 1);
        const FireCudaFrameMetrics& frame = frames[frameIndex];
        const float cellCount = static_cast<float>(std::max(1, frame.gridX * frame.gridY * frame.gridZ));
        if (samples[i].hasHrr && hrrMax > hrrMin && simHrrMax > simHrrMin) {
            const float d = normalizedValue(frame.heatReleaseProxy, simHrrMin, simHrrMax) - normalizedValue(samples[i].hrrKw, hrrMin, hrrMax);
            hrrError += static_cast<double>(d * d);
            ++hrrCount;
        }
        if (samples[i].hasMass && massMax > massMin && simMassMax > simMassMin) {
            const float d = normalizedValue(simMassProxy(frame), simMassMin, simMassMax) - normalizedValue(samples[i].massRemainingKg, massMin, massMax);
            massError += static_cast<double>(d * d);
            ++massCount;
        }
        if (samples[i].hasThermocouple && tcMax > tcMin && simThermalMax > simThermalMin) {
            const float simThermal = frame.heatSum / cellCount;
            const float d = normalizedValue(simThermal, simThermalMin, simThermalMax) - normalizedValue(samples[i].thermocoupleMeanC, tcMin, tcMax);
            tcError += static_cast<double>(d * d);
            ++tcCount;
        }
        if (samples[i].hasIrMean && irMeanMax > irMeanMin && simIrMeanMax > simIrMeanMin) {
            const float simIrMean = frame.heatSum / cellCount;
            const float d = normalizedValue(simIrMean, simIrMeanMin, simIrMeanMax) - normalizedValue(samples[i].irMeanC, irMeanMin, irMeanMax);
            irMeanError += static_cast<double>(d * d);
            ++irMeanCount;
        }
        if (samples[i].hasIrMax && irMaxMax > irMaxMin && simIrMaxMax > simIrMaxMin) {
            const float d = normalizedValue(frame.maxHeat, simIrMaxMin, simIrMaxMax) - normalizedValue(samples[i].irMaxC, irMaxMin, irMaxMax);
            irMaxError += static_cast<double>(d * d);
            ++irMaxCount;
        }
        if (samples[i].hasPlumeHeight) {
            const float d = frame.flameHeightMeters - samples[i].plumeHeightMeters;
            plumeError += static_cast<double>(d * d);
            ++plumeCount;
        }
        if (samples[i].hasSmokeOpticalDepth && smokeOpticalDepthMax > smokeOpticalDepthMin && simSmokeOpticalDepthMax > simSmokeOpticalDepthMin) {
            const float d =
                normalizedValue(frame.meanOpticalDepth, simSmokeOpticalDepthMin, simSmokeOpticalDepthMax) -
                normalizedValue(samples[i].smokeOpticalDepth, smokeOpticalDepthMin, smokeOpticalDepthMax);
            smokeOpticalDepthError += static_cast<double>(d * d);
            ++smokeOpticalDepthCount;
        }
        if (samples[i].hasSmokeExtinctionCoefficient && smokeExtinctionMax > smokeExtinctionMin && simSmokeExtinctionMax > simSmokeExtinctionMin) {
            const float d =
                normalizedValue(frame.meanOpticalDepth, simSmokeExtinctionMin, simSmokeExtinctionMax) -
                normalizedValue(samples[i].smokeExtinctionCoefficientPerM, smokeExtinctionMin, smokeExtinctionMax);
            smokeExtinctionError += static_cast<double>(d * d);
            ++smokeExtinctionCount;
        }
        if (samples[i].hasRadiantHeatFlux && radiantHeatFluxMax > radiantHeatFluxMin && simRadiantHeatFluxMax > simRadiantHeatFluxMin) {
            const float d =
                normalizedValue(simRadiantEnergyProxy(frame), simRadiantHeatFluxMin, simRadiantHeatFluxMax) -
                normalizedValue(samples[i].radiantHeatFluxKwPerM2, radiantHeatFluxMin, radiantHeatFluxMax);
            radiantHeatFluxError += static_cast<double>(d * d);
            ++radiantHeatFluxCount;
        }
    }

    if (hrrCount > 0) {
        report.hrrShapeRmse = static_cast<float>(std::sqrt(hrrError / static_cast<double>(hrrCount)));
    }
    if (massCount > 0) {
        report.massShapeRmse = static_cast<float>(std::sqrt(massError / static_cast<double>(massCount)));
    }
    if (tcCount > 0) {
        report.thermocoupleShapeRmse = static_cast<float>(std::sqrt(tcError / static_cast<double>(tcCount)));
    }
    if (irMeanCount > 0) {
        report.irMeanShapeRmse = static_cast<float>(std::sqrt(irMeanError / static_cast<double>(irMeanCount)));
    }
    if (irMaxCount > 0) {
        report.irMaxShapeRmse = static_cast<float>(std::sqrt(irMaxError / static_cast<double>(irMaxCount)));
    }
    if (plumeCount > 0) {
        report.plumeHeightRmseMeters = static_cast<float>(std::sqrt(plumeError / static_cast<double>(plumeCount)));
    }
    if (smokeOpticalDepthCount > 0) {
        report.smokeOpticalDepthShapeRmse = static_cast<float>(std::sqrt(smokeOpticalDepthError / static_cast<double>(smokeOpticalDepthCount)));
    }
    if (smokeExtinctionCount > 0) {
        report.smokeExtinctionShapeRmse = static_cast<float>(std::sqrt(smokeExtinctionError / static_cast<double>(smokeExtinctionCount)));
    }
    if (radiantHeatFluxCount > 0) {
        report.radiantHeatFluxShapeRmse = static_cast<float>(std::sqrt(radiantHeatFluxError / static_cast<double>(radiantHeatFluxCount)));
    }
    report.hrrSamplesCompared = hrrCount;
    report.massSamplesCompared = massCount;
    report.smokeOpticalDepthSamplesCompared = smokeOpticalDepthCount;
    report.smokeExtinctionSamplesCompared = smokeExtinctionCount;
    report.radiantHeatFluxSamplesCompared = radiantHeatFluxCount;
    return report;
}

void writeOptionalCsvFloat(std::ofstream& out, bool hasValue, float value) {
    if (hasValue) {
        out << value;
    }
}

bool writeCalibrationComparisonCsv(
    const std::string& outputPath,
    const std::string& calibrationPath,
    const std::vector<FireCudaFrameMetrics>& frames) {
    if (calibrationPath.empty()) {
        return true;
    }
    const std::vector<CalibrationSample> samples = loadCalibrationSamples(calibrationPath);
    if (samples.empty() || frames.empty()) {
        return false;
    }
    std::ofstream out(outputPath, std::ios::binary);
    if (!out) {
        return false;
    }
    out << std::fixed << std::setprecision(6);
    out << "sampleIndex,measuredTimeSeconds,simFrameIndex,simTimeSeconds,"
           "measuredHrrKW,simHrrProxy,"
           "measuredMassRemainingKg,simMassProxy,"
           "measuredSmokeOpticalDepth,simSmokeOpticalDepthProxy,"
           "measuredSmokeExtinctionCoefficientPerM,simSmokeExtinctionProxy,"
           "measuredRadiantHeatFluxKWPerM2,simRadiantEnergyProxy\n";
    for (std::size_t i = 0; i < samples.size(); ++i) {
        const std::size_t frameIndex = samples.size() <= 1 ? 0 : (i * (frames.size() - 1)) / (samples.size() - 1);
        const CalibrationSample& sample = samples[i];
        const FireCudaFrameMetrics& frame = frames[frameIndex];
        out << i << "," << sample.timeSeconds << "," << frame.frameIndex << "," << frame.timeSeconds << ",";
        writeOptionalCsvFloat(out, sample.hasHrr, sample.hrrKw);
        out << "," << frame.heatReleaseProxy << ",";
        writeOptionalCsvFloat(out, sample.hasMass, sample.massRemainingKg);
        out << "," << simMassProxy(frame) << ",";
        writeOptionalCsvFloat(out, sample.hasSmokeOpticalDepth, sample.smokeOpticalDepth);
        out << "," << frame.meanOpticalDepth << ",";
        writeOptionalCsvFloat(out, sample.hasSmokeExtinctionCoefficient, sample.smokeExtinctionCoefficientPerM);
        out << "," << frame.meanOpticalDepth << ",";
        writeOptionalCsvFloat(out, sample.hasRadiantHeatFlux, sample.radiantHeatFluxKwPerM2);
        out << "," << simRadiantEnergyProxy(frame) << "\n";
    }
    return out.good();
}

int runInputStressTest() {
    std::vector<std::uint32_t> frame(kFrameWidth * kFrameHeight, 0xff000000u);
    std::vector<std::uint32_t> simFrame(kFrameWidth * kFrameHeight, packBgra(0.020f, 0.022f, 0.022f));
    for (int i = 0; i < 80; ++i) {
        FireSettings settings;
        settings.mouseX = (i % 2) == 0 ? -4.0f : 5.0f;
        settings.mouseY = (i % 3) == 0 ? -3.0f : 4.0f;
        settings.showGizmos = 1;
        settings.activeGizmo = (i % 8) - 2;
        settings.sceneId = i % kSceneCount;
        settings.wind = -2.0f + static_cast<float>(i % 17) * 0.25f;
        settings.turbulence = -1.0f + static_cast<float>(i % 23) * 0.15f;
        settings.smoke = -0.5f + static_cast<float>(i % 11) * 0.24f;
        settings.cameraYaw = -20.0f + static_cast<float>(i) * 0.5f;
        settings.cameraPitch = -5.0f + static_cast<float>(i % 30) * 0.32f;
        settings.cameraDistance = -2.0f + static_cast<float>(i % 18) * 0.55f;
        composeAppFrame(frame, simFrame, settings, false);
    }
    return 0;
}

int runCudaSmokeTest() {
    CreateDirectoryA("out", nullptr);
    for (int scene = 0; scene < kSceneCount; ++scene) {
        g_sceneEmitters[scene] = loadSceneEmitterParams(scene);
    }
    std::vector<std::uint32_t> frame(kFrameWidth * kFrameHeight, 0xff000000u);
    std::vector<std::uint32_t> simFrame(kFrameWidth * kFrameHeight, 0xff000000u);

    if (!fireCudaInitialize(kFrameWidth, kFrameHeight, kSimulationGridWidth, kSimulationGridHeight)) {
        return 2;
    }

    bool ok = true;
    constexpr int kSmokeFrames = 64;
    for (int i = 0; i < kSmokeFrames; ++i) {
        FireSettings settings;
        settings.width = kFrameWidth;
        settings.height = kFrameHeight;
        settings.dt = 1.0f / 60.0f;
        settings.mouseX = 0.50f + 0.08f * std::sin(static_cast<float>(i) * 0.08f);
        settings.mouseY = 0.13f + 0.04f * std::sin(static_cast<float>(i) * 0.045f);
        settings.leftDown = 0;
        settings.showGizmos = 1;
        settings.activeGizmo = 1;
        settings.wind = 0.08f;
        settings.detail = 0.92f;
        applyCanonicalFireSettings(settings);
        applySceneEmitterParams(settings);
        settings.turbulence = std::max(settings.turbulence, 1.08f);
        settings.smoke = std::max(settings.smoke, 1.05f);
        settings.intensity = std::max(settings.intensity, 1.05f);
        settings.cameraYaw = 0.18f;
        settings.cameraPitch = 0.08f;
        settings.cameraDistance = 2.62f;
        FireSettings simSettings = settings;
        simSettings.showGizmos = 0;
        if (!fireCudaStepAndRender(simFrame.data(), simSettings)) {
            ok = false;
            break;
        }
        composeAppFrame(frame, simFrame, settings, true);
    }

    if (ok) {
        ok = writeBmp("out\\cuda-smoke-test-frame.bmp", frame, kFrameWidth, kFrameHeight);
    }
    fireCudaShutdown();
    return ok ? 0 : 3;
}

int runValidation(const std::string& args) {
    ensureDirectoryTree("out");
    const std::string targetPath = argumentValue(args, "--targets=");
    const std::string calibrationPath = argumentValue(args, "--calibration=");
    const std::string geometryPath = argumentValue(args, "--geometry=");
    const std::string manifestPath = argumentValue(args, "--manifest=");
    const std::string datasetId = argumentValue(args, "--dataset-id=");
    const std::string outputDirArg = argumentValue(args, "--output-dir=");
    const std::string outputDir = outputDirArg.empty() ? "out" : outputDirArg;
    const int validationFrames = argumentIntValue(args, "--validation-frames=", 96, 8, 240);
    const int validationScene = argumentIntValue(args, "--scene=", 0, 0, kSceneCount - 1);
    g_sceneEmitters[validationScene] = loadSceneEmitterParams(validationScene);
    const bool poolFireCalibration = args.find("--pool-fire-calibration") != std::string::npos;
    if (!ensureDirectoryTree(outputDir)) {
        return 3;
    }
    const std::string metricsPath = joinPath(outputDir, "validation-metrics.csv");
    const std::string comparisonPath = joinPath(outputDir, "calibration-comparison.csv");
    const std::string reportPath = joinPath(outputDir, "validation-report.json");
    const std::string rawFramePath = joinPath(outputDir, "validation-frame.bmp");
    const std::string appFramePath = joinPath(outputDir, "validation-app-frame.bmp");
    std::vector<std::uint32_t> simFrame(kFrameWidth * kFrameHeight, 0xff000000u);
    std::vector<std::uint32_t> appFrame(kFrameWidth * kFrameHeight, 0xff000000u);

    if (!fireCudaInitialize(kFrameWidth, kFrameHeight, kSimulationGridWidth, kSimulationGridHeight)) {
        return 2;
    }

    std::ofstream csv(metricsPath, std::ios::binary);
    if (!csv) {
        fireCudaShutdown();
        return 3;
    }

    csv << "frame,timeSeconds,gridX,gridY,gridZ,pressureIterations,gpuSolveMs,gpuRenderMs,"
           "gpuVelocityMs,gpuReactionMs,gpuProjectionMs,gpuLightingMs,gpuRaymarchMs,gpuPackMs,"
           "heatSum,fuelSum,oxygenSum,sootSum,charSum,ashSum,pyrolysisSum,progressSum,"
           "turbulenceEnergySum,sootOpticalDepthSum,maxHeat,maxFuel,maxSoot,maxPyrolysis,"
           "maxProgress,maxTurbulenceEnergy,flameHeightMeters,"
           "meanOpticalDepth,meanSceneLight,meanSceneShadow,flameMassProxy,smokeMassProxy,flameSmokeOverlapProxy,"
           "meanVolumetricShadow,meanRoomIrradiance,heatReleaseProxy,divergenceBeforeL2,divergenceAfterL2,"
           "divergenceBeforeMax,divergenceAfterMax,divergenceReduction,invalidCells\n";
    csv << std::fixed << std::setprecision(6);

    FireCudaFrameMetrics finalMetrics = {};
    FireSettings finalSettings = {};
    bool stable = true;
    double totalSolveMs = 0.0;
    double totalRenderMs = 0.0;
    double totalVelocityMs = 0.0;
    double totalReactionMs = 0.0;
    double totalProjectionMs = 0.0;
    double totalLightingMs = 0.0;
    double totalRaymarchMs = 0.0;
    double totalPackMs = 0.0;
    double totalReduction = 0.0;
    float worstAfterL2 = 0.0f;
    float worstAfterMax = 0.0f;
    float minReduction = 1.0f;
    float maxHeat = 0.0f;
    float maxFlameHeight = 0.0f;
    std::vector<FireCudaFrameMetrics> metricFrames;
    metricFrames.reserve(static_cast<std::size_t>(validationFrames));

    for (int i = 0; i < validationFrames; ++i) {
        FireSettings settings;
        settings.width = kFrameWidth;
        settings.height = kFrameHeight;
        settings.dt = 1.0f / 60.0f;
        if (poolFireCalibration) {
            settings.mouseX = 0.50f;
            settings.mouseY = 0.12f;
        } else {
            settings.mouseX = 0.50f + 0.07f * std::sin(static_cast<float>(i) * 0.071f);
            settings.mouseY = 0.12f + 0.035f * std::sin(static_cast<float>(i) * 0.053f);
        }
        settings.leftDown = 0;
        settings.rightDown = 0;
        settings.showGizmos = 0;
        settings.activeGizmo = 1;
        settings.sceneId = validationScene;
        settings.reset = i == 0 ? 1 : 0;
        settings.wind = poolFireCalibration ? 0.0f : 0.10f + 0.05f * std::sin(static_cast<float>(i) * 0.037f);
        settings.detail = 0.98f;
        applyCanonicalFireSettings(settings);
        applySceneEmitterParams(settings);
        settings.turbulence = std::max(settings.turbulence, 1.08f);
        settings.smoke = std::max(settings.smoke, 1.02f);
        settings.intensity = std::max(settings.intensity, 1.18f);
        settings.cameraYaw = 0.18f;
        settings.cameraPitch = 0.08f;
        settings.cameraDistance = 2.62f;

        FireCudaFrameMetrics metrics;
        if (!fireCudaStepAndRenderMeasured(simFrame.data(), settings, &metrics)) {
            stable = false;
            break;
        }

        csv << metrics.frameIndex << "," << metrics.timeSeconds << "," << metrics.gridX << "," << metrics.gridY << ","
            << metrics.gridZ << "," << metrics.pressureIterations << "," << metrics.gpuSolveMs << "," << metrics.gpuRenderMs << ","
            << metrics.gpuVelocityMs << "," << metrics.gpuReactionMs << "," << metrics.gpuProjectionMs << ","
            << metrics.gpuLightingMs << "," << metrics.gpuRaymarchMs << "," << metrics.gpuPackMs << ","
            << metrics.heatSum << "," << metrics.fuelSum << "," << metrics.oxygenSum << "," << metrics.sootSum << ","
            << metrics.charSum << "," << metrics.ashSum << "," << metrics.pyrolysisSum << "," << metrics.progressSum << ","
            << metrics.turbulenceEnergySum << "," << metrics.sootOpticalDepthSum << ","
            << metrics.maxHeat << "," << metrics.maxFuel << "," << metrics.maxSoot << "," << metrics.maxPyrolysis << ","
            << metrics.maxProgress << "," << metrics.maxTurbulenceEnergy << "," << metrics.flameHeightMeters << ","
            << metrics.meanOpticalDepth << "," << metrics.meanSceneLight << "," << metrics.meanSceneShadow << ","
            << metrics.flameMassProxy << "," << metrics.smokeMassProxy << "," << metrics.flameSmokeOverlapProxy << ","
            << metrics.meanVolumetricShadow << "," << metrics.meanRoomIrradiance << "," << metrics.heatReleaseProxy << "," << metrics.divergenceBeforeL2 << ","
            << metrics.divergenceAfterL2 << "," << metrics.divergenceBeforeMax << "," << metrics.divergenceAfterMax << ","
            << metrics.divergenceReduction << "," << metrics.invalidCells << "\n";

        stable = stable && metrics.invalidCells == 0;
        stable = stable && metrics.divergenceAfterL2 < 1.25f;
        stable = stable && metrics.divergenceAfterMax < 8.0f;
        totalSolveMs += metrics.gpuSolveMs;
        totalRenderMs += metrics.gpuRenderMs;
        totalVelocityMs += metrics.gpuVelocityMs;
        totalReactionMs += metrics.gpuReactionMs;
        totalProjectionMs += metrics.gpuProjectionMs;
        totalLightingMs += metrics.gpuLightingMs;
        totalRaymarchMs += metrics.gpuRaymarchMs;
        totalPackMs += metrics.gpuPackMs;
        totalReduction += metrics.divergenceReduction;
        worstAfterL2 = std::max(worstAfterL2, metrics.divergenceAfterL2);
        worstAfterMax = std::max(worstAfterMax, metrics.divergenceAfterMax);
        minReduction = std::min(minReduction, metrics.divergenceReduction);
        maxHeat = std::max(maxHeat, metrics.maxHeat);
        maxFlameHeight = std::max(maxFlameHeight, metrics.flameHeightMeters);
        finalMetrics = metrics;
        finalSettings = settings;
        metricFrames.push_back(metrics);
    }

    const ImageStats imageStats = computeImageStats(simFrame);
    const double frames = std::max(1, finalMetrics.frameIndex + 1);
    const double averageSolveMs = totalSolveMs / frames;
    const double averageRenderMs = totalRenderMs / frames;
    const double averageVelocityMs = totalVelocityMs / frames;
    const double averageReactionMs = totalReactionMs / frames;
    const double averageProjectionMs = totalProjectionMs / frames;
    const double averageLightingMs = totalLightingMs / frames;
    const double averageRaymarchMs = totalRaymarchMs / frames;
    const double averagePackMs = totalPackMs / frames;
    const double averageReduction = totalReduction / frames;
    std::vector<TargetEnvelope> targets = loadTargetEnvelopes(targetPath);
    const CalibrationReport calibration = compareCalibrationSeries(calibrationPath, geometryPath, metricFrames);
    stable = stable && (targetPath.empty() || !targets.empty());
    stable = stable && (calibrationPath.empty() || calibration.calibrationReadable);
    stable = stable && (geometryPath.empty() || calibration.geometryReadable);

    for (TargetEnvelope& target : targets) {
        target.matched = true;
        if (target.metric == "averageDivergenceReduction") {
            target.observed = static_cast<float>(averageReduction);
        } else if (target.metric == "worstDivergenceAfterL2") {
            target.observed = worstAfterL2;
        } else if (target.metric == "worstDivergenceAfterMax") {
            target.observed = worstAfterMax;
        } else if (target.metric == "maxFlameHeightMeters") {
            target.observed = maxFlameHeight;
        } else if (target.metric == "finalMeanOpticalDepth") {
            target.observed = finalMetrics.meanOpticalDepth;
        } else if (target.metric == "finalMeanSceneLight") {
            target.observed = finalMetrics.meanSceneLight;
        } else if (target.metric == "finalMeanSceneShadow") {
            target.observed = finalMetrics.meanSceneShadow;
        } else if (target.metric == "finalHeatReleaseProxy") {
            target.observed = finalMetrics.heatReleaseProxy;
        } else if (target.metric == "finalCharSum") {
            target.observed = finalMetrics.charSum;
        } else if (target.metric == "finalAshSum") {
            target.observed = finalMetrics.ashSum;
        } else if (target.metric == "finalPyrolysisSum") {
            target.observed = finalMetrics.pyrolysisSum;
        } else if (target.metric == "finalProgressSum") {
            target.observed = finalMetrics.progressSum;
        } else if (target.metric == "finalTurbulenceEnergySum") {
            target.observed = finalMetrics.turbulenceEnergySum;
        } else if (target.metric == "finalSootOpticalDepthSum") {
            target.observed = finalMetrics.sootOpticalDepthSum;
        } else if (target.metric == "maxHeat") {
            target.observed = maxHeat;
        } else if (target.metric == "maxPyrolysis") {
            target.observed = finalMetrics.maxPyrolysis;
        } else if (target.metric == "maxProgress") {
            target.observed = finalMetrics.maxProgress;
        } else if (target.metric == "maxTurbulenceEnergy") {
            target.observed = finalMetrics.maxTurbulenceEnergy;
        } else if (target.metric == "imageMeanLuma") {
            target.observed = imageStats.meanLuma;
        } else if (target.metric == "imageMaxLuma") {
            target.observed = imageStats.maxLuma;
        } else if (target.metric == "imageMeanSaturation") {
            target.observed = imageStats.meanSaturation;
        } else if (target.metric == "imageWarmFireFraction") {
            target.observed = imageStats.warmFireFraction;
        } else if (target.metric == "imageTanSmokeFraction") {
            target.observed = imageStats.tanSmokeFraction;
        } else if (target.metric == "imageBlackSmokeFraction") {
            target.observed = imageStats.blackSmokeFraction;
        } else if (target.metric == "imageWhiteCoreFraction") {
            target.observed = imageStats.whiteCoreFraction;
        } else if (target.metric == "imageBrightPixels") {
            target.observed = static_cast<float>(imageStats.brightPixels);
        } else if (target.metric == "imageBrightFraction") {
            target.observed = imageStats.brightFraction;
        } else if (target.metric == "averageGpuSolveMs") {
            target.observed = static_cast<float>(averageSolveMs);
        } else if (target.metric == "averageGpuRenderMs") {
            target.observed = static_cast<float>(averageRenderMs);
        } else if (target.metric == "averageGpuLightingMs") {
            target.observed = static_cast<float>(averageLightingMs);
        } else if (target.metric == "calibrationHrrShapeRmse") {
            target.observed = calibration.hrrShapeRmse;
        } else if (target.metric == "calibrationMassShapeRmse") {
            target.observed = calibration.massShapeRmse;
        } else if (target.metric == "calibrationThermocoupleShapeRmse") {
            target.observed = calibration.thermocoupleShapeRmse;
        } else if (target.metric == "calibrationIrMeanShapeRmse") {
            target.observed = calibration.irMeanShapeRmse;
        } else if (target.metric == "calibrationIrMaxShapeRmse") {
            target.observed = calibration.irMaxShapeRmse;
        } else if (target.metric == "calibrationPlumeHeightRmseMeters") {
            target.observed = calibration.plumeHeightRmseMeters;
        } else if (target.metric == "calibrationSmokeOpticalDepthShapeRmse") {
            target.observed = calibration.smokeOpticalDepthShapeRmse;
        } else if (target.metric == "calibrationSmokeExtinctionShapeRmse") {
            target.observed = calibration.smokeExtinctionShapeRmse;
        } else if (target.metric == "calibrationRadiantHeatFluxShapeRmse") {
            target.observed = calibration.radiantHeatFluxShapeRmse;
        } else {
            target.matched = false;
        }
        target.passed = target.matched && target.observed >= target.minimum && target.observed <= target.maximum;
        stable = stable && target.passed;
    }

    const bool wroteComparison = writeCalibrationComparisonCsv(comparisonPath, calibrationPath, metricFrames);

    stable = stable && finalMetrics.frameIndex >= validationFrames - 1;
    stable = stable && maxHeat > 0.50f;
    stable = stable && maxFlameHeight > 0.20f;
    stable = stable && imageStats.maxLuma > 0.12f;
    stable = stable && imageStats.brightPixels > 32;
    stable = stable && (averageReduction > 0.02 || worstAfterL2 < 0.02f);

    composeAppFrame(appFrame, simFrame, finalSettings, true);
    const bool wroteRaw = writeBmp(rawFramePath.c_str(), simFrame, kFrameWidth, kFrameHeight);
    const bool wroteApp = writeBmp(appFramePath.c_str(), appFrame, kFrameWidth, kFrameHeight);

    std::ofstream json(reportPath, std::ios::binary);
    if (!json) {
        fireCudaShutdown();
        return 3;
    }

    json << std::fixed << std::setprecision(6);
    json << "{\n";
    json << "  \"validationOk\": " << (stable && wroteRaw && wroteApp ? "true" : "false") << ",\n";
    json << "  \"model\": {\n";
    json << "    \"runtime\": \"CUDA-only\",\n";
    json << "    \"pressureSolver\": \"weighted red-black SOR\",\n";
    json << "    \"scalarTransport\": \"clamped MacCormack/BFECC correction over semi-Lagrangian backtraces\",\n";
    json << "    \"combustion\": \"fuel-bed char/ash pyrolysis plus oxygen-limited Arrhenius progress variable\",\n";
    json << "    \"turbulence\": \"LES-style scalar turbulence-energy closure\",\n";
    json << "    \"soot\": \"soot optical depth with oxidation feedback and particle-size-derived absorption/scattering\",\n";
    json << "    \"renderer\": \"linear HDR blackbody Beer-Lambert participating media with scene radiance volume GI, volume shadowing, emitter scattering, and ACES display tonemapping\"\n";
    json << "  },\n";
    json << "  \"runtimeConfig\": \"" << (poolFireCalibration ? "nist-pool-fire-calibration" : "canonical") << "\",\n";
    json << "  \"datasetId\": \"" << jsonEscape(datasetId) << "\",\n";
    json << "  \"manifestPath\": \"" << jsonEscape(manifestPath) << "\",\n";
    json << "  \"outputDir\": \"" << jsonEscape(outputDir) << "\",\n";
    json << "  \"requestedGrid\": [" << kSimulationGridWidth << ", " << kSimulationGridHeight << "],\n";
    json << "  \"raymarchSteps\": " << kRaymarchSteps << ",\n";
    json << "  \"emberCount\": " << kEmberCount << ",\n";
    json << "  \"frames\": " << validationFrames << ",\n";
    json << "  \"grid\": [" << finalMetrics.gridX << ", " << finalMetrics.gridY << ", " << finalMetrics.gridZ << "],\n";
    json << "  \"pressureIterations\": " << finalMetrics.pressureIterations << ",\n";
    json << "  \"targetEnvelopePath\": \"" << jsonEscape(targetPath) << "\",\n";
    json << "  \"calibrationPath\": \"" << jsonEscape(calibrationPath) << "\",\n";
    json << "  \"geometryPath\": \"" << jsonEscape(geometryPath) << "\",\n";
    json << "  \"calibration\": {\n";
    json << "    \"provided\": " << (calibration.calibrationProvided ? "true" : "false") << ",\n";
    json << "    \"readable\": " << (calibration.calibrationReadable ? "true" : "false") << ",\n";
    json << "    \"geometryProvided\": " << (calibration.geometryProvided ? "true" : "false") << ",\n";
    json << "    \"geometryReadable\": " << (calibration.geometryReadable ? "true" : "false") << ",\n";
    json << "    \"sampleCount\": " << calibration.sampleCount << ",\n";
    json << "    \"hrrShapeRmse\": " << calibration.hrrShapeRmse << ",\n";
    json << "    \"massShapeRmse\": " << calibration.massShapeRmse << ",\n";
    json << "    \"thermocoupleShapeRmse\": " << calibration.thermocoupleShapeRmse << ",\n";
    json << "    \"irMeanShapeRmse\": " << calibration.irMeanShapeRmse << ",\n";
    json << "    \"irMaxShapeRmse\": " << calibration.irMaxShapeRmse << ",\n";
    json << "    \"plumeHeightRmseMeters\": " << calibration.plumeHeightRmseMeters << ",\n";
    json << "    \"smokeOpticalDepthShapeRmse\": " << calibration.smokeOpticalDepthShapeRmse << ",\n";
    json << "    \"smokeExtinctionShapeRmse\": " << calibration.smokeExtinctionShapeRmse << ",\n";
    json << "    \"radiantHeatFluxShapeRmse\": " << calibration.radiantHeatFluxShapeRmse << ",\n";
    json << "    \"hrrSamplesCompared\": " << calibration.hrrSamplesCompared << ",\n";
    json << "    \"massSamplesCompared\": " << calibration.massSamplesCompared << ",\n";
    json << "    \"smokeOpticalDepthSamplesCompared\": " << calibration.smokeOpticalDepthSamplesCompared << ",\n";
    json << "    \"smokeExtinctionSamplesCompared\": " << calibration.smokeExtinctionSamplesCompared << ",\n";
    json << "    \"radiantHeatFluxSamplesCompared\": " << calibration.radiantHeatFluxSamplesCompared << "\n";
    json << "  },\n";
    json << "  \"averageGpuSolveMs\": " << averageSolveMs << ",\n";
    json << "  \"averageGpuRenderMs\": " << averageRenderMs << ",\n";
    json << "  \"averageGpuVelocityMs\": " << averageVelocityMs << ",\n";
    json << "  \"averageGpuReactionMs\": " << averageReactionMs << ",\n";
    json << "  \"averageGpuProjectionMs\": " << averageProjectionMs << ",\n";
    json << "  \"averageGpuLightingMs\": " << averageLightingMs << ",\n";
    json << "  \"averageGpuRaymarchMs\": " << averageRaymarchMs << ",\n";
    json << "  \"averageGpuPackMs\": " << averagePackMs << ",\n";
    json << "  \"averageDivergenceReduction\": " << averageReduction << ",\n";
    json << "  \"minimumDivergenceReduction\": " << minReduction << ",\n";
    json << "  \"worstDivergenceAfterL2\": " << worstAfterL2 << ",\n";
    json << "  \"worstDivergenceAfterMax\": " << worstAfterMax << ",\n";
    json << "  \"finalMeanOpticalDepth\": " << finalMetrics.meanOpticalDepth << ",\n";
    json << "  \"finalMeanSceneLight\": " << finalMetrics.meanSceneLight << ",\n";
    json << "  \"finalMeanSceneShadow\": " << finalMetrics.meanSceneShadow << ",\n";
    json << "  \"finalFlameMassProxy\": " << finalMetrics.flameMassProxy << ",\n";
    json << "  \"finalSmokeMassProxy\": " << finalMetrics.smokeMassProxy << ",\n";
    json << "  \"finalFlameSmokeOverlapProxy\": " << finalMetrics.flameSmokeOverlapProxy << ",\n";
    json << "  \"finalMeanVolumetricShadow\": " << finalMetrics.meanVolumetricShadow << ",\n";
    json << "  \"finalMeanRoomIrradiance\": " << finalMetrics.meanRoomIrradiance << ",\n";
    json << "  \"finalHeatReleaseProxy\": " << finalMetrics.heatReleaseProxy << ",\n";
    json << "  \"finalCharSum\": " << finalMetrics.charSum << ",\n";
    json << "  \"finalAshSum\": " << finalMetrics.ashSum << ",\n";
    json << "  \"finalPyrolysisSum\": " << finalMetrics.pyrolysisSum << ",\n";
    json << "  \"finalProgressSum\": " << finalMetrics.progressSum << ",\n";
    json << "  \"finalTurbulenceEnergySum\": " << finalMetrics.turbulenceEnergySum << ",\n";
    json << "  \"finalSootOpticalDepthSum\": " << finalMetrics.sootOpticalDepthSum << ",\n";
    json << "  \"maxHeat\": " << maxHeat << ",\n";
    json << "  \"maxPyrolysis\": " << finalMetrics.maxPyrolysis << ",\n";
    json << "  \"maxProgress\": " << finalMetrics.maxProgress << ",\n";
    json << "  \"maxTurbulenceEnergy\": " << finalMetrics.maxTurbulenceEnergy << ",\n";
    json << "  \"maxFlameHeightMeters\": " << maxFlameHeight << ",\n";
    json << "  \"imageMeanLuma\": " << imageStats.meanLuma << ",\n";
    json << "  \"imageMaxLuma\": " << imageStats.maxLuma << ",\n";
    json << "  \"imageMeanSaturation\": " << imageStats.meanSaturation << ",\n";
    json << "  \"imageWarmFireFraction\": " << imageStats.warmFireFraction << ",\n";
    json << "  \"imageTanSmokeFraction\": " << imageStats.tanSmokeFraction << ",\n";
    json << "  \"imageBlackSmokeFraction\": " << imageStats.blackSmokeFraction << ",\n";
    json << "  \"imageWhiteCoreFraction\": " << imageStats.whiteCoreFraction << ",\n";
    json << "  \"imageBrightPixels\": " << imageStats.brightPixels << ",\n";
    json << "  \"imageBrightFraction\": " << imageStats.brightFraction << ",\n";
    json << "  \"targetEnvelopes\": [\n";
    for (std::size_t i = 0; i < targets.size(); ++i) {
        const TargetEnvelope& target = targets[i];
        json << "    {\"metric\": \"" << jsonEscape(target.metric) << "\", \"min\": " << target.minimum
             << ", \"max\": " << target.maximum << ", \"observed\": " << target.observed
             << ", \"matched\": " << (target.matched ? "true" : "false")
             << ", \"passed\": " << (target.passed ? "true" : "false") << "}";
        json << (i + 1 == targets.size() ? "\n" : ",\n");
    }
    json << "  ],\n";
    json << "  \"outputs\": [\"" << jsonEscape(metricsPath) << "\", \"" << jsonEscape(comparisonPath) << "\", \"" << jsonEscape(reportPath)
         << "\", \"" << jsonEscape(rawFramePath) << "\", \"" << jsonEscape(appFramePath) << "\"]\n";
    json << "}\n";

    const bool ok = stable && wroteComparison && wroteRaw && wroteApp && json.good() && csv.good();
    fireCudaShutdown();
    return ok ? 0 : 4;
}

int runDiagnostics() {
    CreateDirectoryA("out", nullptr);
    FireCudaDiagnostics diagnostics;
    const bool cudaOk = fireCudaGetDiagnostics(&diagnostics);
    std::string interopDetail = "skipped";
    const bool d3dInteropOk = cudaOk && runD3DInteropProbe(interopDetail);

    std::ofstream out("out\\diagnostics.txt", std::ios::binary);
    if (!out) {
        return 3;
    }

    out << "Native FireSim diagnostics\n";
    out << "cudaDiagnosticsOk=" << (cudaOk ? "true" : "false") << "\n";
    if (cudaOk) {
        out << "driverVersion=" << diagnostics.driverVersion << "\n";
        out << "runtimeVersion=" << diagnostics.runtimeVersion << "\n";
        out << "deviceCount=" << diagnostics.deviceCount << "\n";
        out << "activeDevice=" << diagnostics.activeDevice << "\n";
        out << "deviceName=" << diagnostics.deviceName << "\n";
        out << "computeCapability=" << diagnostics.computeMajor << "." << diagnostics.computeMinor << "\n";
        out << "totalGlobalMemMiB=" << (diagnostics.totalGlobalMem / (1024ull * 1024ull)) << "\n";
    } else {
        out << "cudaError=" << fireCudaLastError() << "\n";
    }

    out << "runtimeBackend=CUDA\n";
    out << "canonicalRuntimeState=scene,camera,controls,worker,frame,debug,and overlay transitions flow through CanonicalRuntimeState\n";
    out << "runtimeTransitionReasons=startup,scene-switch,user-reset,worker-stale,worker-frame-copied,overlay-changed\n";
    out << "liveCudaDefault=isolated-worker\n";
    out << "mainViewportKernelLaunches=false\n";
    out << "interactiveCudaViewport=FP16 D3D11 shared texture from isolated CUDA worker\n";
    out << "d3dCudaInteropOk=" << (d3dInteropOk ? "true" : "false") << "\n";
    out << "d3dCudaInteropDetail=" << interopDetail << "\n";
    out << "mainViewportMode=real CUDA worker volume; no animated simulation fallback\n";
    out << "workerProcessIsolation=true\n";
    out << "sharedFrameTransport=" << kSharedViewportName << "\n";
    out << "sharedTextureRingAudit=nonblocking keyed mutex acquire, newest-even sequence selection, display-slot rotation, timeout/no-candidate/starvation telemetry\n";
    out << "sharedTextureRingSlots=" << kSharedFrameSlots << "\n";
    out << "displayTextureRingSlots=" << kDisplayFrameSlots << "\n";
    out << "workerFrameStaleMs=" << kWorkerFrameStaleMs << "\n";
    out << "workerHeartbeatStaleMs=" << kWorkerHeartbeatStaleMs << "\n";
    out << "workerKillStaleMs=" << kWorkerKillStaleMs << "\n";
    out << "workerRestartLimitPerMinute=" << kWorkerRestartLimit << "\n";
    out << "workerLifecycleReasons=start-requested,createprocess-failed,restart-blocked,stale-heartbeat-kill,stop-requested,forced-terminate,exited,gpu-init-failed,interop-failed,render-failed,clean-exit\n";
    out << "workerLifecycleEvents=worker-lifecycle:<reason> entries in out/worker-events.log\n";
    out << "appPumpFps=" << static_cast<int>(kAppPumpFps) << "\n";
    out << "presentationTargetFps=" << static_cast<int>(kDisplayMaxPresentFps) << "\n";
    out << "presentationPacing=2:1 fixed app pump to present cadence with intentional display-frame reuse\n";
    out << "presentVsync=false\n";
    out << "kernelHotspotProfiling=worker benchmark reports true CUDA submit time, publish time, frame time, and sorted measured pass hotspots without quality reduction\n";
    out << "sceneRadianceFormat=DXGI_FORMAT_R16G16B16A16_FLOAT\n";
    out << "swapchainFormat=DXGI_FORMAT_R16G16B16A16_FLOAT\n";
    out << "renderGraphPasses=" << kRenderGraphPasses << "\n";
    out << "debugOverlaySystem=source markers, selected burner ports, GLB bounds, volume bounds, fuel-bed bounds, origin axes, frame age, and texture ring freshness\n";
    out << "renderGraphOwnsCameraResponse=true\n";
    out << "hdrCameraPipeline=" << kHdrCameraPipeline << "\n";
    out << "uiOverlayAfterCameraResponse=true\n";
    out << "meshLightingPass=lit-scene-mesh\n";
    out << "volumeSmokeFlameSeparation=resolved flame-sheet mask suppresses soot absorption and scattering inside emissive samples\n";
    out << "volumetricShadowing=scene shadow volume stores soot optical transmittance and room rays sample source-to-surface visibility\n";
    out << "roomLightingLayer=room surfaces receive flame-fed irradiance gated by volumetric shadow and material albedo\n";
    out << "sceneSourceModels=gas selected low-soot burner ring; campfire log-contact char bed; room tray fuel bed\n";
    out << "emberSystem=field-spawned char/pyrolysis particles with local velocity advection, drag, cooling, and lifetimes\n";
    out << "fieldOwnership=simulation physical scalars, renderer optical scalars, MAC velocity, and lighting snapshots are copied through explicit ownership tables\n";
    out << "gpuKernelSafetyStop=true\n";
    out << "cpuFallback=false\n";
    out << "pressureSolver=weighted red-black SOR\n";
    out << "pressureIterations=40\n";
    out << "combustionModel=fuel-bed char/ash pyrolysis plus oxygen-limited Arrhenius progress variable\n";
    out << "turbulenceModel=LES-style scalar turbulence-energy closure\n";
    out << "sootModel=soot optical depth with oxidation feedback and particle-size-derived absorption/scattering\n";
    out << "volumeRenderer=linear HDR blackbody Beer-Lambert participating media with scene radiance volume GI, volume shadowing, emitter scattering, and ACES display tonemapping\n";
    out << "rendererStorage=CUDA float4 HDR radiance written directly to mapped FP16 D3D11 surface for live display\n";
    out << "renderDebugModes=final,flame,soot,transmittance,temperature,fuel-char,velocity\n";
    out << "cleanViewportMode=C key hides app chrome and CUDA gizmos for visual judging\n";
    out << "scalarTransport=clamped MacCormack/BFECC correction for transported scalar fields\n";
    out << "calibrationInputs=HRR,mass loss,thermocouple,IR,video-derived plume height,geometry sidecar\n";
    out << "runtimeConfig=canonical\n";
    out << "requestedGrid=" << kSimulationGridWidth << "x" << kSimulationGridHeight << "\n";
    out << "raymarchSteps=" << kRaymarchSteps << "\n";
    out << "emberCount=" << kEmberCount << "\n";
    return out.good() && cudaOk && d3dInteropOk ? 0 : 2;
}

} // namespace

int WINAPI WinMain(HINSTANCE instance, HINSTANCE, LPSTR commandLine, int) {
    const std::string args = commandLine != nullptr ? commandLine : "";
    if (args.find("--diagnostics") != std::string::npos) {
        return runDiagnostics();
    }
    if (args.find("--worker-benchmark") != std::string::npos) {
        return runWorkerBenchmark(args);
    }
    if (args.find("--cuda-worker") != std::string::npos) {
        return runCudaWorker(args);
    }
    if (args.find("--validation") != std::string::npos || args.find("--validate") != std::string::npos) {
        if (!gpuKernelLaunchAllowed(args)) {
            return writeGpuSafetyStop("validation");
        }
        return runValidation(args);
    }
    if (args.find("--cuda-smoke-test") != std::string::npos || args.find("--smoke-test") != std::string::npos) {
        if (!gpuKernelLaunchAllowed(args)) {
            return writeGpuSafetyStop("smoke-test");
        }
        return runCudaSmokeTest();
    }
    if (args.find("--input-stress-test") != std::string::npos) {
        const int code = runInputStressTest();
        ExitProcess(static_cast<UINT>(code));
    }
    g_useCudaBackend = false;
    g_cudaWorkerRequested = cudaWorkerEnabledByDefault(args);
    g_activeScene = argumentIntValue(args, "--scene=", 0, 0, kSceneCount - 1);
    if (g_activeScene != 0) {
        g_needsReset = true;
        g_resetFramesRemaining = 3;
    }

    timeBeginPeriod(1);
    g_frame.assign(kFrameWidth * kFrameHeight, 0xff000000u);
    clearSimulationFrame(g_simFrame);
    initializeSharedViewport(true);

    if (!createMainWindow(instance)) {
        MessageBoxA(nullptr, "Failed to create the Native FireSim window.", "Native FireSim", MB_ICONERROR);
        return 1;
    }
    if (!initializeD3D(g_window)) {
        MessageBoxA(nullptr, g_workerUiStatus, "Native FireSim D3D11", MB_ICONERROR);
        return 1;
    }
    if (g_cudaWorkerRequested) {
        startCudaWorker();
    } else {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "CUDA worker disabled by launch flag");
    }

    using Clock = std::chrono::high_resolution_clock;
    auto last = Clock::now();
    auto fpsLast = last;
    auto nextDisplayPresent = last;
    const auto displayPresentStep = std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(1.0 / kDisplayMaxPresentFps));
    unsigned long long lastProfileCopyCalls = 0;
    unsigned long long lastProfileCopiedFrames = 0;
    unsigned long long lastProfilePresentCalls = 0;
    unsigned long long lastProfileReusedPresents = 0;
    unsigned long long lastProfileCopyMicros = 0;
    unsigned long long lastProfilePresentMicros = 0;
    LONG lastProfileWorkerPublishedFrames = 0;
    LONG lastProfileWorkerPhysicsFrames = 0;
    LONG lastProfileWorkerRenderOnlyFrames = 0;
    int visualFrames = 0;
    float fps = 0.0f;
    const bool traceFrames = GetEnvironmentVariableA("FIRESIM_TRACE_FRAMES", nullptr, 0) > 0;
    std::ofstream frameTrace;
    if (traceFrames) {
        CreateDirectoryA("out", nullptr);
        frameTrace.open("out\\live-frame-trace.csv", std::ios::binary);
        if (frameTrace) {
            frameTrace << "tickMs,dtMs,copyUs,presentUs,frameUs,copied,presented,reusedDisplayFrame,uploadUi,backend,seq,slot,frameAgeMs,ringSharedSlot,ringDisplaySlot,ringTimeouts,ringNoCandidate,ringStarved,workerPublishedFrames,workerPhysicsFrames,workerRenderOnlyFrames,workerFrameUs,workerCudaUs,workerPublishUs\n";
        }
    }

    MSG msg = {};
    while (g_running) {
        while (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }

        const auto now = Clock::now();
        float dt = std::chrono::duration<float>(now - last).count();
        last = now;
        dt = std::max(1.0f / 240.0f, std::min(dt, 1.0f / 25.0f));

        FireSettings settings;
        settings.width = kFrameWidth;
        settings.height = kFrameHeight;
        settings.dt = dt;
        settings.mouseX = g_mouseX;
        settings.mouseY = g_mouseY;
        settings.leftDown = (g_leftDown && g_leftInViewport && g_activeGizmo == 1) ? 1 : 0;
        settings.rightDown = (g_leftDown && g_leftInViewport && g_activeGizmo == 2) ? 1 : 0;
        settings.reset = (g_needsReset || g_resetFramesRemaining > 0) ? 1 : 0;
        settings.showGizmos = (g_showGizmos && !g_cleanViewportMode) ? 1 : 0;
        settings.activeGizmo = g_activeGizmo;
        settings.sceneId = g_activeScene;
        settings.wind = g_wind;
        applyCanonicalFireSettings(settings);
        applySceneEmitterParams(settings);
        settings.renderDebugMode = g_renderDebugMode;
        settings.turbulence = std::max(g_turbulence, kTurbulence);
        settings.detail = 0.92f;
        settings.cameraYaw = g_cameraYaw;
        settings.cameraPitch = g_cameraPitch;
        settings.cameraDistance = g_cameraDistance;
        if (settings.reset != 0) {
            invalidateDisplayedCudaFrame();
            g_needsReset = false;
            if (g_resetFramesRemaining > 0) {
                --g_resetFramesRemaining;
            }
        }

        FireSettings workerSettings = settings;
        workerSettings.showGizmos = 0;
        writeWorkerSettings(workerSettings);
        serviceCudaWorkerWatchdog();
        const bool presentBudgetDue = now >= nextDisplayPresent;
        const auto copyStart = Clock::now();
        bool copiedWorkerFrame = false;
        if (presentBudgetDue) {
            ++g_liveCopyCalls;
            copiedWorkerFrame = g_cudaWorkerRequested && copyD3DWorkerFrame();
        }
        const auto copyEnd = Clock::now();
        const auto copyMicros = static_cast<unsigned long long>(std::chrono::duration_cast<std::chrono::microseconds>(copyEnd - copyStart).count());
        g_liveCopyMicros += copyMicros;
        if (copiedWorkerFrame) {
            ++g_liveCopiedFrames;
        }
        const bool workerTimestampFresh = workerFrameMetadataFresh();
        g_displayFrameAgeMs =
            g_sharedViewport == nullptr || g_sharedViewport->lastFrameTickMs == 0
                ? 0
                : tickMs() - g_sharedViewport->lastFrameTickMs;
        g_cudaWorkerFrameLive = (copiedWorkerFrame || workerTimestampFresh) && g_d3d.hasSimFrame;
        g_useCudaBackend = g_cudaWorkerFrameLive;
        if (!g_cudaWorkerFrameLive && !copiedWorkerFrame && settings.reset == 0) {
            clearSimulationFrame(g_simFrame);
            applyRuntimeTransition(RuntimeTransitionReason::WorkerStale);
        } else if (copiedWorkerFrame) {
            applyRuntimeTransition(RuntimeTransitionReason::WorkerFrameCopied);
        }
        g_displayExposure = settings.exposure;
        const bool overlayDirty = overlayStateDirty(settings, g_useCudaBackend, g_cleanViewportMode);
        if (overlayDirty) {
            applyRuntimeTransition(RuntimeTransitionReason::OverlayChanged);
        }
        const bool presentDirty = copiedWorkerFrame || overlayDirty || !g_cudaWorkerFrameLive;
        bool presented = false;
        bool reusedDisplayFrame = false;
        bool uploadUi = false;
        unsigned long long presentMicros = 0;
        if (presentBudgetDue && (presentDirty || g_cudaWorkerFrameLive)) {
            reusedDisplayFrame = g_cudaWorkerFrameLive && !copiedWorkerFrame;
            uploadUi = overlayDirty || !g_useCudaBackend || !g_uiTextureUploaded;
            if (g_useCudaBackend) {
                if (uploadUi) {
                    composeD3DOverlayFrame(g_frame, settings, true, g_cleanViewportMode);
                }
            } else {
                composeAppFrame(g_frame, g_simFrame, settings, false, g_cleanViewportMode);
            }
            if (uploadUi) {
                rememberOverlayState(settings, g_useCudaBackend, g_cleanViewportMode);
            }
            const auto presentStart = Clock::now();
            presented = renderD3DFrame(g_useCudaBackend, g_displayExposure, uploadUi);
            presentMicros = static_cast<unsigned long long>(std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - presentStart).count());
            g_livePresentMicros += presentMicros;
            ++g_livePresentCalls;
            if (!presented && !g_lastPresentSkippedWouldBlock) {
                ++g_livePresentFailures;
            }
            if (presented && reusedDisplayFrame) {
                ++g_liveReusedPresents;
            }
            do {
                nextDisplayPresent += displayPresentStep;
            } while (nextDisplayPresent <= Clock::now());
        }

        if (presented) {
            ++visualFrames;
        }
        const auto frameEnd = Clock::now();
        if (frameTrace) {
            frameTrace << tickMs() << ","
                << std::chrono::duration<double, std::milli>(frameEnd - now).count() << ","
                << copyMicros << ","
                << presentMicros << ","
                << std::chrono::duration_cast<std::chrono::microseconds>(frameEnd - now).count() << ","
                << (copiedWorkerFrame ? 1 : 0) << ","
                << (presented ? 1 : 0) << ","
                << (reusedDisplayFrame ? 1 : 0) << ","
                << (uploadUi ? 1 : 0) << ","
                << (g_useCudaBackend ? 1 : 0) << ","
                << static_cast<long>(g_lastCopiedWorkerSequence) << ","
                << (g_sharedViewport == nullptr ? -1L : static_cast<long>(g_sharedViewport->latestFrameSlot)) << ","
                << g_displayFrameAgeMs << ","
                << static_cast<long>(g_sharedRingLastCopiedSharedSlot) << ","
                << static_cast<long>(g_sharedRingLastCopiedDisplaySlot) << ","
                << g_sharedRingAcquireTimeouts << ","
                << g_sharedRingNoCandidateFrames << ","
                << g_sharedRingCopyStarvationFrames << ","
                << (g_sharedViewport == nullptr ? 0L : static_cast<long>(g_sharedViewport->workerPublishedFrames)) << ","
                << (g_sharedViewport == nullptr ? 0L : static_cast<long>(g_sharedViewport->workerPhysicsFrames)) << ","
                << (g_sharedViewport == nullptr ? 0L : static_cast<long>(g_sharedViewport->workerRenderOnlyFrames)) << ","
                << (g_sharedViewport == nullptr ? 0ull : g_sharedViewport->workerFrameMicros) << ","
                << (g_sharedViewport == nullptr ? 0ull : g_sharedViewport->workerCudaMicros) << ","
                << (g_sharedViewport == nullptr ? 0ull : g_sharedViewport->workerPublishMicros) << "\n";
        }
        const float fpsElapsed = std::chrono::duration<float>(frameEnd - fpsLast).count();
        if (fpsElapsed >= 0.5f) {
            fps = static_cast<float>(visualFrames) / fpsElapsed;
            visualFrames = 0;
            fpsLast = frameEnd;
            g_visualFps = fps;
            const unsigned long long copyCallsDelta = g_liveCopyCalls - lastProfileCopyCalls;
            const unsigned long long copiedDelta = g_liveCopiedFrames - lastProfileCopiedFrames;
            const unsigned long long presentDelta = g_livePresentCalls - lastProfilePresentCalls;
            const unsigned long long reusedPresentDelta = g_liveReusedPresents - lastProfileReusedPresents;
            const unsigned long long copyMicrosDelta = g_liveCopyMicros - lastProfileCopyMicros;
            const unsigned long long presentMicrosDelta = g_livePresentMicros - lastProfilePresentMicros;
            const LONG workerPublishedFrames =
                g_sharedViewport == nullptr ? 0 : g_sharedViewport->workerPublishedFrames;
            const LONG workerPhysicsFrames =
                g_sharedViewport == nullptr ? 0 : g_sharedViewport->workerPhysicsFrames;
            const LONG workerRenderOnlyFrames =
                g_sharedViewport == nullptr ? 0 : g_sharedViewport->workerRenderOnlyFrames;
            const LONG workerPublishedDelta = std::max(0L, workerPublishedFrames - lastProfileWorkerPublishedFrames);
            const LONG workerPhysicsDelta = std::max(0L, workerPhysicsFrames - lastProfileWorkerPhysicsFrames);
            const LONG workerRenderOnlyDelta = std::max(0L, workerRenderOnlyFrames - lastProfileWorkerRenderOnlyFrames);
            g_liveCopyCallHz = static_cast<double>(copyCallsDelta) / static_cast<double>(fpsElapsed);
            g_liveCopiedHz = static_cast<double>(copiedDelta) / static_cast<double>(fpsElapsed);
            g_livePresentHz = static_cast<double>(presentDelta) / static_cast<double>(fpsElapsed);
            g_liveReusedPresentHz = static_cast<double>(reusedPresentDelta) / static_cast<double>(fpsElapsed);
            g_workerPublishedHz = static_cast<double>(workerPublishedDelta) / static_cast<double>(fpsElapsed);
            g_workerPhysicsHz = static_cast<double>(workerPhysicsDelta) / static_cast<double>(fpsElapsed);
            g_workerRenderOnlyHz = static_cast<double>(workerRenderOnlyDelta) / static_cast<double>(fpsElapsed);
            g_liveIntervalCopyMs = copyCallsDelta == 0 ? 0.0 : static_cast<double>(copyMicrosDelta) / (1000.0 * static_cast<double>(copyCallsDelta));
            g_liveIntervalPresentMs = presentDelta == 0 ? 0.0 : static_cast<double>(presentMicrosDelta) / (1000.0 * static_cast<double>(presentDelta));
            lastProfileCopyCalls = g_liveCopyCalls;
            lastProfileCopiedFrames = g_liveCopiedFrames;
            lastProfilePresentCalls = g_livePresentCalls;
            lastProfileReusedPresents = g_liveReusedPresents;
            lastProfileCopyMicros = g_liveCopyMicros;
            lastProfilePresentMicros = g_livePresentMicros;
            lastProfileWorkerPublishedFrames = workerPublishedFrames;
            lastProfileWorkerPhysicsFrames = workerPhysicsFrames;
            lastProfileWorkerRenderOnlyFrames = workerRenderOnlyFrames;
            char profileDetail[256] = {};
            std::snprintf(
                profileDetail,
                sizeof(profileDetail),
                "health=%s appFps=%.1f presentHz=%.1f copiedHz=%.1f reusedPresentHz=%.1f workerPublishHz=%.1f physicsHz=%.1f renderOnlyHz=%.1f frameAgeMs=%llu ringTimeouts=%llu ringNoCandidate=%llu ringStarved=%llu copyMs=%.3f presentMs=%.3f seq=%ld slot=%ld",
                fireStreamHealthLabel(),
                g_visualFps,
                g_livePresentHz,
                g_liveCopiedHz,
                g_liveReusedPresentHz,
                g_workerPublishedHz,
                g_workerPhysicsHz,
                g_workerRenderOnlyHz,
                g_displayFrameAgeMs,
                g_sharedRingAcquireTimeouts,
                g_sharedRingNoCandidateFrames,
                g_sharedRingCopyStarvationFrames,
                g_liveIntervalCopyMs,
                g_liveIntervalPresentMs,
                static_cast<long>(g_lastCopiedWorkerSequence),
                g_sharedViewport == nullptr ? -1L : static_cast<long>(g_sharedViewport->latestFrameSlot));
            appendRuntimeEvent("live-profile", profileDetail);
            updateTitle(fps);
        }

        const float renderElapsed = std::chrono::duration<float>(Clock::now() - now).count();
        if (renderElapsed < kTargetFrameSeconds) {
            const auto sleepMs = static_cast<DWORD>((kTargetFrameSeconds - renderElapsed) * 1000.0f);
            if (sleepMs > 0) {
                Sleep(sleepMs);
            }
        } else {
            Sleep(0);
        }
    }

    stopCudaWorker();
    closeSharedViewport();
    timeEndPeriod(1);
    return 0;
}
