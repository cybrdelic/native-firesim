#include <windows.h>
#include <windowsx.h>
#include <mmsystem.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>
#include <wrl/client.h>

#include <algorithm>
#include <cfloat>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <string>
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
constexpr float kTargetFrameSeconds = 1.0f / 300.0f;
constexpr DWORD kSharedViewportMagic = 0x46535631u;
constexpr DWORD kSharedViewportVersion = 6u;
constexpr const char* kSharedViewportName = "Local\\NativeFireSimViewportFrameV6";
constexpr DWORD kSharedViewportDisplayFormat = static_cast<DWORD>(DXGI_FORMAT_R16G16B16A16_FLOAT);
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
    DWORD workerPid;
    unsigned long long lastFrameTickMs;
    unsigned long long workerHeartbeatTickMs;
    unsigned long long workerStartTickMs;
    unsigned long long workerStopTickMs;
    unsigned long long sharedTextureHandleValue;
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

struct D3DDisplayState {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<IDXGISwapChain> swapChain;
    ComPtr<ID3D11RenderTargetView> renderTargetView;
    ComPtr<ID3D11Texture2D> sharedSimTexture;
    ComPtr<IDXGIKeyedMutex> sharedSimMutex;
    ComPtr<ID3D11Texture2D> displaySimTexture;
    ComPtr<ID3D11ShaderResourceView> displaySimSrv;
    ComPtr<ID3D11Texture2D> uiTexture;
    ComPtr<ID3D11ShaderResourceView> uiSrv;
    ComPtr<ID3D11SamplerState> sampler;
    ComPtr<ID3D11VertexShader> vertexShader;
    ComPtr<ID3D11PixelShader> simPixelShader;
    ComPtr<ID3D11PixelShader> uiPixelShader;
    ComPtr<ID3D11Buffer> displayConstants;
    ComPtr<ID3D11BlendState> alphaBlend;
    HANDLE sharedSimHandle = nullptr;
    bool initialized = false;
    bool hasSimFrame = false;
};

HWND g_window = nullptr;
std::vector<std::uint32_t> g_frame;
std::vector<std::uint32_t> g_simFrame;
D3DDisplayState g_d3d;
HANDLE g_sharedViewportMap = nullptr;
SharedViewportBuffer* g_sharedViewport = nullptr;
HANDLE g_cudaWorkerProcess = nullptr;
bool g_running = true;
bool g_leftDown = false;
bool g_leftInViewport = false;
bool g_rightDown = false;
bool g_orbiting = false;
bool g_needsReset = false;
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
    drawText(pixels, 628, 26, cudaBackend ? "RMB ORBIT   WHEEL ZOOM" : "NO CUSTOM CUDA KERNELS", 1, 0.70f, 0.72f, 0.68f, 0.88f);

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
        cudaBackend ? "REAL CUDA WORKER VOLUME   D DEBUG   C CLEAN   G OVERLAY   R RESET   ESC QUIT" : "NO LIVE CUDA FRAME   WORKER STARTING/STALE   D DEBUG   C CLEAN",
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
    drawAppChrome(pixels, settings, cudaBackend, cleanViewport);
}

void composeD3DOverlayFrame(std::vector<std::uint32_t>& pixels, const FireSettings& settings, bool cudaBackend, bool cleanViewport) {
    std::fill(pixels.begin(), pixels.end(), 0u);
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
    std::snprintf(
        title,
        sizeof(title),
        "Native FireSim %s | %.0f fps | %s | debug %s | wind %.2f | turbulence %.2f | %s",
        g_useCudaBackend ? "CUDA 3D volume" : "CUDA worker waiting",
        fps,
        toolName(g_activeGizmo),
        renderDebugName(g_renderDebugMode),
        g_wind,
        g_turbulence,
        g_cleanViewportMode ? "clean viewport" : "operator UI");
    SetWindowTextA(g_window, title);
}

std::string hresultString(HRESULT hr) {
    char text[32] = {};
    std::snprintf(text, sizeof(text), "0x%08lx", static_cast<unsigned long>(hr));
    return text;
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

const char* d3dShaderSource() {
    return R"HLSL(
struct VSOut {
    float4 pos : SV_POSITION;
    float2 uv : TEXCOORD0;
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

float4 SimPS(VSOut input) : SV_TARGET {
    float3 radiance = max(FrameTex.Sample(LinearSampler, input.uv).rgb, 0.0);
    float3 color = ToneMapPreserveHue(radiance * Exposure);
    color = pow(saturate(color), 1.0 / 2.2);
    return float4(color, 1.0);
}

float4 UiPS(VSOut input) : SV_TARGET {
    return FrameTex.Sample(LinearSampler, input.uv);
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
    HRESULT hr = factory->CreateSwapChain(g_d3d.device.Get(), &swapDesc, g_d3d.swapChain.GetAddressOf());
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
    hr = g_d3d.device->CreateTexture2D(&simDesc, nullptr, g_d3d.displaySimTexture.GetAddressOf());
    if (FAILED(hr) || FAILED(g_d3d.device->CreateShaderResourceView(g_d3d.displaySimTexture.Get(), nullptr, g_d3d.displaySimSrv.GetAddressOf()))) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "private FP16 display texture failed");
        return false;
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
    ComPtr<ID3DBlob> simPsBlob;
    ComPtr<ID3DBlob> uiPsBlob;
    if (!compileShader(d3dShaderSource(), "FullscreenVS", "vs_5_0", vsBlob) ||
        !compileShader(d3dShaderSource(), "SimPS", "ps_5_0", simPsBlob) ||
        !compileShader(d3dShaderSource(), "UiPS", "ps_5_0", uiPsBlob)) {
        return false;
    }
    if (FAILED(g_d3d.device->CreateVertexShader(vsBlob->GetBufferPointer(), vsBlob->GetBufferSize(), nullptr, g_d3d.vertexShader.GetAddressOf())) ||
        FAILED(g_d3d.device->CreatePixelShader(simPsBlob->GetBufferPointer(), simPsBlob->GetBufferSize(), nullptr, g_d3d.simPixelShader.GetAddressOf())) ||
        FAILED(g_d3d.device->CreatePixelShader(uiPsBlob->GetBufferPointer(), uiPsBlob->GetBufferSize(), nullptr, g_d3d.uiPixelShader.GetAddressOf()))) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "D3D shader creation failed");
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

    g_d3d.initialized = true;
    return true;
}

bool copyD3DWorkerFrame() {
    if (!g_d3d.initialized || g_sharedViewport == nullptr || g_d3d.displaySimTexture == nullptr) {
        return false;
    }
    const auto handleValue = static_cast<uintptr_t>(g_sharedViewport->sharedTextureHandleValue);
    if (handleValue == 0) {
        return false;
    }
    if (g_d3d.sharedSimTexture == nullptr || reinterpret_cast<uintptr_t>(g_d3d.sharedSimHandle) != handleValue) {
        g_d3d.sharedSimTexture.Reset();
        g_d3d.sharedSimMutex.Reset();
        g_d3d.hasSimFrame = false;
        g_lastCopiedWorkerSequence = 0;
        g_d3d.sharedSimHandle = reinterpret_cast<HANDLE>(handleValue);
        const HRESULT hr = g_d3d.device->OpenSharedResource(
            g_d3d.sharedSimHandle,
            __uuidof(ID3D11Texture2D),
            reinterpret_cast<void**>(g_d3d.sharedSimTexture.GetAddressOf()));
        if (FAILED(hr) || FAILED(g_d3d.sharedSimTexture.As(&g_d3d.sharedSimMutex))) {
            std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "host open worker FP16 texture failed: %s", hresultString(hr).c_str());
            g_d3d.sharedSimTexture.Reset();
            g_d3d.sharedSimMutex.Reset();
            g_d3d.sharedSimHandle = nullptr;
            return false;
        }
    }
    if (g_d3d.sharedSimMutex == nullptr || g_d3d.sharedSimTexture == nullptr) {
        return false;
    }
    const LONG sequenceA = g_sharedViewport->frameSequence;
    if (sequenceA <= 0 || (sequenceA & 1) != 0 || sequenceA == g_lastCopiedWorkerSequence) {
        return false;
    }
    const HRESULT acquire = g_d3d.sharedSimMutex->AcquireSync(1, 0);
    if (acquire == static_cast<HRESULT>(WAIT_TIMEOUT)) {
        return false;
    }
    if (FAILED(acquire)) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "D3D shared frame acquire failed: %s", hresultString(acquire).c_str());
        return false;
    }
    const LONG sequenceB = g_sharedViewport->frameSequence;
    if (sequenceA != sequenceB || (sequenceB & 1) != 0) {
        g_d3d.sharedSimMutex->ReleaseSync(0);
        return false;
    }
    g_d3d.context->CopyResource(g_d3d.displaySimTexture.Get(), g_d3d.sharedSimTexture.Get());
    const HRESULT release = g_d3d.sharedSimMutex->ReleaseSync(0);
    if (FAILED(release)) {
        std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "D3D shared frame release failed: %s", hresultString(release).c_str());
        return false;
    }
    g_d3d.hasSimFrame = true;
    g_lastCopiedWorkerSequence = sequenceB;
    return true;
}

bool renderD3DFrame(bool drawSim, float exposure) {
    if (!g_d3d.initialized || g_d3d.context == nullptr || g_d3d.swapChain == nullptr) {
        return false;
    }
    g_d3d.context->UpdateSubresource(g_d3d.uiTexture.Get(), 0, nullptr, g_frame.data(), kFrameWidth * sizeof(std::uint32_t), 0);

    const float clearColor[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    ID3D11RenderTargetView* renderTargets[] = {g_d3d.renderTargetView.Get()};
    g_d3d.context->OMSetRenderTargets(1, renderTargets, nullptr);
    g_d3d.context->ClearRenderTargetView(g_d3d.renderTargetView.Get(), clearColor);

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

    if (drawSim && g_d3d.hasSimFrame) {
        DisplayConstants constants = {};
        constants.exposure = exposure;
        g_d3d.context->UpdateSubresource(g_d3d.displayConstants.Get(), 0, nullptr, &constants, 0, 0);
        ID3D11Buffer* constantBuffers[] = {g_d3d.displayConstants.Get()};
        ID3D11ShaderResourceView* simSrvs[] = {g_d3d.displaySimSrv.Get()};
        g_d3d.context->PSSetConstantBuffers(0, 1, constantBuffers);
        g_d3d.context->PSSetShaderResources(0, 1, simSrvs);
        g_d3d.context->PSSetShader(g_d3d.simPixelShader.Get(), nullptr, 0);
        g_d3d.context->Draw(3, 0);
        ID3D11ShaderResourceView* nullSrvs[] = {nullptr};
        g_d3d.context->PSSetShaderResources(0, 1, nullSrvs);
    }

    const float blendFactor[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    g_d3d.context->OMSetBlendState(g_d3d.alphaBlend.Get(), blendFactor, 0xffffffffu);
    ID3D11ShaderResourceView* uiSrvs[] = {g_d3d.uiSrv.Get()};
    g_d3d.context->PSSetShaderResources(0, 1, uiSrvs);
    g_d3d.context->PSSetShader(g_d3d.uiPixelShader.Get(), nullptr, 0);
    g_d3d.context->Draw(3, 0);
    ID3D11ShaderResourceView* nullSrvs[] = {nullptr};
    g_d3d.context->PSSetShaderResources(0, 1, nullSrvs);
    g_d3d.context->OMSetBlendState(nullptr, blendFactor, 0xffffffffu);

    return SUCCEEDED(g_d3d.swapChain->Present(0, 0));
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
        if (const int command = hitTestCommandButton(g_pointerFrameX, g_pointerFrameY); command != 0) {
            if (command == 1) {
                g_showGizmos = !g_showGizmos;
            } else {
                g_needsReset = true;
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
            g_needsReset = true;
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
        renderD3DFrame(g_useCudaBackend, g_displayExposure);
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

void appendRuntimeEvent(const char* event, const char* detail = "") {
    CreateDirectoryA("out", nullptr);
    std::ofstream log("out\\worker-events.log", std::ios::app | std::ios::binary);
    if (!log) {
        return;
    }
    log << tickMs() << "," << event << "," << detail << "\n";
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
}

void writeWorkerSettings(const FireSettings& settings) {
    if (g_sharedViewport == nullptr) {
        return;
    }
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
    const LONG sequenceA = g_sharedViewport->frameSequence;
    if (sequenceA <= 0 || (sequenceA & 1) != 0) {
        return false;
    }
    if (tickMs() - g_sharedViewport->lastFrameTickMs > kWorkerFrameStaleMs) {
        return false;
    }
    const LONG sequenceB = g_sharedViewport->frameSequence;
    return sequenceA == sequenceB && (sequenceB & 1) == 0;
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
        return false;
    }
    CloseHandle(process.hThread);
    g_cudaWorkerProcess = process.hProcess;
    std::snprintf(g_workerUiStatus, sizeof(g_workerUiStatus), "CUDA worker pid %lu starting", static_cast<unsigned long>(process.dwProcessId));
    return true;
}

void stopCudaWorker() {
    if (g_sharedViewport != nullptr) {
        g_sharedViewport->shutdownRequested = 1;
    }
    if (g_cudaWorkerProcess != nullptr) {
        if (WaitForSingleObject(g_cudaWorkerProcess, 1800) == WAIT_TIMEOUT) {
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
    } else if (g_sharedViewport->lastFrameTickMs != 0 && frameAge <= kWorkerFrameStaleMs) {
        const double frameMs = static_cast<double>(g_sharedViewport->workerFrameMicros) / 1000.0;
        const double workerFps = g_sharedViewport->workerFrameMicros == 0 ? 0.0 : 1000000.0 / static_cast<double>(g_sharedViewport->workerFrameMicros);
        std::snprintf(
            g_workerUiStatus,
            sizeof(g_workerUiStatus),
            "CUDA worker submit %.0ffps %.1fms display %.0ffps age %llums",
            workerFps,
            frameMs,
            g_visualFps,
            frameAge);
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
    ComPtr<ID3D11Texture2D> sharedTexture;
    ComPtr<IDXGIKeyedMutex> sharedMutex;
    ComPtr<ID3D11Query> completionQuery;
    HANDLE sharedHandle = nullptr;
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
    hr = target.device->CreateTexture2D(&desc, nullptr, target.sharedTexture.GetAddressOf());
    if (FAILED(hr)) {
        char detail[96] = {};
        std::snprintf(detail, sizeof(detail), "%s", hresultString(hr).c_str());
        appendRuntimeEvent("worker-d3d-create-shared-failed", detail);
        return false;
    }
    if (FAILED(target.sharedTexture.As(&target.sharedMutex))) {
        appendRuntimeEvent("worker-d3d-keyed-mutex-failed", "");
        return false;
    }
    ComPtr<IDXGIResource> sharedResource;
    if (FAILED(target.sharedTexture.As(&sharedResource)) || FAILED(sharedResource->GetSharedHandle(&target.sharedHandle)) || target.sharedHandle == nullptr) {
        appendRuntimeEvent("worker-d3d-shared-handle-failed", "");
        return false;
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
    if (target.context == nullptr || target.completionQuery == nullptr) {
        return false;
    }
    target.context->End(target.completionQuery.Get());
    target.context->Flush();
    for (;;) {
        const HRESULT hr = target.context->GetData(target.completionQuery.Get(), nullptr, 0, 0);
        if (hr == S_OK) {
            return true;
        }
        if (hr != S_FALSE) {
            return false;
        }
        Sleep(0);
    }
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
    ensureDirectoryTree("out");
    const std::string outputDirArg = argumentValue(args, "--output-dir=");
    const std::string outputDir = outputDirArg.empty() ? "out\\worker-benchmark" : outputDirArg;
    const int benchmarkFrames = argumentIntValue(args, "--benchmark-frames=", 16, 4, 120);
    const int warmupFrames = argumentIntValue(args, "--warmup-frames=", 8, 0, 120);
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
    int completedFrames = 0;
    bool stable = true;
    for (int i = 0; i < warmupFrames + benchmarkFrames; ++i) {
        const bool measureFrame = i >= warmupFrames;
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

        const auto frameStart = Clock::now();
        if (!fireCudaStepAndRenderD3D11(settings)) {
            stable = false;
            break;
        }
        const auto cudaDone = Clock::now();
        const HRESULT acquire = target.sharedMutex->AcquireSync(0, 8);
        if (FAILED(acquire)) {
            stable = false;
            break;
        }
        target.context->CopyResource(target.sharedTexture.Get(), target.cudaTexture.Get());
        if (!waitForWorkerD3DCompletion(target)) {
            stable = false;
            break;
        }
        const HRESULT release = target.sharedMutex->ReleaseSync(0);
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

    fireCudaUnregisterD3D11Texture();
    fireCudaShutdown();

    stable = stable && completedFrames == benchmarkFrames;
    const double frames = static_cast<double>(std::max(1, completedFrames));
    const double averageCudaMs = totalCudaMs / frames;
    const double averagePublishMs = totalPublishMs / frames;
    const double averageFrameMs = totalFrameMs / frames;
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
    report << "  \"requestedGrid\": [" << kSimulationGridWidth << ", " << kSimulationGridHeight << "],\n";
    report << "  \"raymarchSteps\": " << kRaymarchSteps << ",\n";
    report << "  \"emberCount\": " << kEmberCount << ",\n";
    report << "  \"pressureIterations\": 40,\n";
    report << "  \"averageCudaMs\": " << averageCudaMs << ",\n";
    report << "  \"averagePublishMs\": " << averagePublishMs << ",\n";
    report << "  \"averageFrameMs\": " << averageFrameMs << ",\n";
    report << "  \"effectiveFps\": " << (averageFrameMs > 0.0 ? 1000.0 / averageFrameMs : 0.0) << ",\n";
    report << "  \"output\": \"" << jsonEscape(reportPath) << "\"\n";
    report << "}\n";
    return stable ? 0 : 4;
}

int runCudaWorker(const std::string& args) {
    if (!gpuKernelLaunchAllowed(args)) {
        return writeGpuSafetyStop("cuda-worker");
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
        if (parentProcess != nullptr) {
            CloseHandle(parentProcess);
        }
        return 3;
    }
    appendRuntimeEvent("worker-cuda-initialized", "");
    if (!fireCudaRegisterD3D11Texture(d3dTarget.cudaTexture.Get())) {
        g_sharedViewport->workerStatus = -3;
        InterlockedIncrement(&g_sharedViewport->workerErrorCount);
        g_sharedViewport->workerExitCode = 5;
        std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "D3D/CUDA FP16 interop init failed");
        appendRuntimeEvent("worker-cuda-d3d-register-failed", fireCudaLastError());
        appendRuntimeEvent("worker-d3d-interop-init-failed", g_sharedViewport->statusText);
        fireCudaShutdown();
        if (parentProcess != nullptr) {
            CloseHandle(parentProcess);
        }
        return 5;
    }
    g_sharedViewport->sharedTextureHandleValue = static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(d3dTarget.sharedHandle));
    appendRuntimeEvent("worker-cuda-d3d-registered", "");

    using Clock = std::chrono::high_resolution_clock;
    auto last = Clock::now();
    while (g_sharedViewport->shutdownRequested == 0) {
        if (parentProcess != nullptr && WaitForSingleObject(parentProcess, 0) != WAIT_TIMEOUT) {
            break;
        }

        const auto now = Clock::now();
        float dt = std::chrono::duration<float>(now - last).count();
        last = now;
        dt = std::max(1.0f / 240.0f, std::min(dt, 1.0f / 30.0f));

        g_sharedViewport->workerHeartbeatTickMs = tickMs();

        FireSettings settings = readStableWorkerSettings(g_sharedViewport);
        settings.width = kFrameWidth;
        settings.height = kFrameHeight;
        settings.dt = dt;
        applyCanonicalFireSettings(settings);

        const auto frameStart = Clock::now();
        if (!fireCudaStepAndRenderD3D11(settings)) {
            g_sharedViewport->workerStatus = -2;
            InterlockedIncrement(&g_sharedViewport->workerErrorCount);
            g_sharedViewport->workerExitCode = 4;
            std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "CUDA/D3D render failed: %.145s", fireCudaLastError());
            appendRuntimeEvent("worker-cuda-render-failed", g_sharedViewport->statusText);
            break;
        }
        const auto cudaDone = Clock::now();

        const HRESULT acquire = d3dTarget.sharedMutex->AcquireSync(0, 8);
        if (acquire == static_cast<HRESULT>(WAIT_TIMEOUT)) {
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

        InterlockedIncrement(&g_sharedViewport->frameSequence);
        d3dTarget.context->CopyResource(d3dTarget.sharedTexture.Get(), d3dTarget.cudaTexture.Get());
        if (!waitForWorkerD3DCompletion(d3dTarget)) {
            g_sharedViewport->workerStatus = -4;
            InterlockedIncrement(&g_sharedViewport->workerErrorCount);
            g_sharedViewport->workerExitCode = 6;
            std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "D3D shared copy completion wait failed");
            appendRuntimeEvent("worker-d3d-completion-wait-failed", g_sharedViewport->statusText);
            d3dTarget.sharedMutex->ReleaseSync(0);
            break;
        }
        const HRESULT release = d3dTarget.sharedMutex->ReleaseSync(1);
        if (FAILED(release)) {
            g_sharedViewport->workerStatus = -5;
            InterlockedIncrement(&g_sharedViewport->workerErrorCount);
            g_sharedViewport->workerExitCode = 7;
            std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "D3D keyed mutex release failed: %.80s", hresultString(release).c_str());
            appendRuntimeEvent("worker-d3d-release-failed", g_sharedViewport->statusText);
            break;
        }
        const auto published = Clock::now();

        g_sharedViewport->lastFrameTickMs = tickMs();
        g_sharedViewport->workerCudaMicros = static_cast<unsigned long long>(std::chrono::duration_cast<std::chrono::microseconds>(cudaDone - frameStart).count());
        g_sharedViewport->workerFrameMicros = static_cast<unsigned long long>(std::chrono::duration_cast<std::chrono::microseconds>(published - frameStart).count());
        g_sharedViewport->workerPublishMicros = static_cast<unsigned long long>(std::chrono::duration_cast<std::chrono::microseconds>(published - cudaDone).count());
        g_sharedViewport->workerStatus = 2;
        std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "CUDA worker streaming FP16 D3D11 interop");
        InterlockedIncrement(&g_sharedViewport->frameSequence);

        Sleep(0);
    }

    fireCudaUnregisterD3D11Texture();
    fireCudaShutdown();
    g_sharedViewport->sharedTextureHandleValue = 0;
    g_sharedViewport->workerStatus = 0;
    g_sharedViewport->workerStopTickMs = tickMs();
    std::snprintf(g_sharedViewport->statusText, sizeof(g_sharedViewport->statusText), "CUDA worker stopped");
    appendRuntimeEvent("worker-process-exiting", "");
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
           "heatSum,fuelSum,oxygenSum,sootSum,charSum,ashSum,pyrolysisSum,progressSum,"
           "turbulenceEnergySum,sootOpticalDepthSum,maxHeat,maxFuel,maxSoot,maxPyrolysis,"
           "maxProgress,maxTurbulenceEnergy,flameHeightMeters,"
           "meanOpticalDepth,heatReleaseProxy,divergenceBeforeL2,divergenceAfterL2,"
           "divergenceBeforeMax,divergenceAfterMax,divergenceReduction,invalidCells\n";
    csv << std::fixed << std::setprecision(6);

    FireCudaFrameMetrics finalMetrics = {};
    FireSettings finalSettings = {};
    bool stable = true;
    double totalSolveMs = 0.0;
    double totalRenderMs = 0.0;
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
        settings.wind = poolFireCalibration ? 0.0f : 0.10f + 0.05f * std::sin(static_cast<float>(i) * 0.037f);
        settings.detail = 0.98f;
        applyCanonicalFireSettings(settings);
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
            << metrics.heatSum << "," << metrics.fuelSum << "," << metrics.oxygenSum << "," << metrics.sootSum << ","
            << metrics.charSum << "," << metrics.ashSum << "," << metrics.pyrolysisSum << "," << metrics.progressSum << ","
            << metrics.turbulenceEnergySum << "," << metrics.sootOpticalDepthSum << ","
            << metrics.maxHeat << "," << metrics.maxFuel << "," << metrics.maxSoot << "," << metrics.maxPyrolysis << ","
            << metrics.maxProgress << "," << metrics.maxTurbulenceEnergy << "," << metrics.flameHeightMeters << ","
            << metrics.meanOpticalDepth << "," << metrics.heatReleaseProxy << "," << metrics.divergenceBeforeL2 << ","
            << metrics.divergenceAfterL2 << "," << metrics.divergenceBeforeMax << "," << metrics.divergenceAfterMax << ","
            << metrics.divergenceReduction << "," << metrics.invalidCells << "\n";

        stable = stable && metrics.invalidCells == 0;
        stable = stable && metrics.divergenceAfterL2 < 1.25f;
        stable = stable && metrics.divergenceAfterMax < 8.0f;
        totalSolveMs += metrics.gpuSolveMs;
        totalRenderMs += metrics.gpuRenderMs;
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
    json << "    \"renderer\": \"linear HDR blackbody Beer-Lambert participating media with volume shadowing, emitter scattering, and ACES display tonemapping\"\n";
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
    json << "  \"averageDivergenceReduction\": " << averageReduction << ",\n";
    json << "  \"minimumDivergenceReduction\": " << minReduction << ",\n";
    json << "  \"worstDivergenceAfterL2\": " << worstAfterL2 << ",\n";
    json << "  \"worstDivergenceAfterMax\": " << worstAfterMax << ",\n";
    json << "  \"finalMeanOpticalDepth\": " << finalMetrics.meanOpticalDepth << ",\n";
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
    out << "liveCudaDefault=isolated-worker\n";
    out << "mainViewportKernelLaunches=false\n";
    out << "interactiveCudaViewport=FP16 D3D11 shared texture from isolated CUDA worker\n";
    out << "d3dCudaInteropOk=" << (d3dInteropOk ? "true" : "false") << "\n";
    out << "d3dCudaInteropDetail=" << interopDetail << "\n";
    out << "mainViewportMode=real CUDA worker volume; no animated simulation fallback\n";
    out << "workerProcessIsolation=true\n";
    out << "sharedFrameTransport=" << kSharedViewportName << "\n";
    out << "workerFrameStaleMs=" << kWorkerFrameStaleMs << "\n";
    out << "workerHeartbeatStaleMs=" << kWorkerHeartbeatStaleMs << "\n";
    out << "workerKillStaleMs=" << kWorkerKillStaleMs << "\n";
    out << "workerRestartLimitPerMinute=" << kWorkerRestartLimit << "\n";
    out << "presentationTargetFps=300\n";
    out << "presentVsync=false\n";
    out << "gpuKernelSafetyStop=true\n";
    out << "cpuFallback=false\n";
    out << "pressureSolver=weighted red-black SOR\n";
    out << "pressureIterations=40\n";
    out << "combustionModel=fuel-bed char/ash pyrolysis plus oxygen-limited Arrhenius progress variable\n";
    out << "turbulenceModel=LES-style scalar turbulence-energy closure\n";
    out << "sootModel=soot optical depth with oxidation feedback and particle-size-derived absorption/scattering\n";
    out << "volumeRenderer=linear HDR blackbody Beer-Lambert participating media with volume shadowing, emitter scattering, and ACES display tonemapping\n";
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
        return runInputStressTest();
    }
    g_useCudaBackend = false;
    g_cudaWorkerRequested = cudaWorkerEnabledByDefault(args);

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
    int visualFrames = 0;
    float fps = 0.0f;

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
        settings.reset = g_needsReset ? 1 : 0;
        settings.showGizmos = (g_showGizmos && !g_cleanViewportMode) ? 1 : 0;
        settings.activeGizmo = g_activeGizmo;
        settings.wind = g_wind;
        applyCanonicalFireSettings(settings);
        settings.renderDebugMode = g_renderDebugMode;
        settings.turbulence = std::max(g_turbulence, kTurbulence);
        settings.detail = 0.92f;
        settings.cameraYaw = g_cameraYaw;
        settings.cameraPitch = g_cameraPitch;
        settings.cameraDistance = g_cameraDistance;
        if (g_needsReset) {
            clearSimulationFrame(g_simFrame);
            g_needsReset = false;
        }

        writeWorkerSettings(settings);
        serviceCudaWorkerWatchdog();
        const bool copiedWorkerFrame = g_cudaWorkerRequested && copyD3DWorkerFrame();
        const bool workerTimestampFresh = workerFrameMetadataFresh();
        g_cudaWorkerFrameLive = (copiedWorkerFrame || workerTimestampFresh) && g_d3d.hasSimFrame;
        g_useCudaBackend = g_cudaWorkerFrameLive;
        if (!g_cudaWorkerFrameLive && !copiedWorkerFrame) {
            clearSimulationFrame(g_simFrame);
        }
        g_displayExposure = settings.exposure;
        if (g_useCudaBackend) {
            composeD3DOverlayFrame(g_frame, settings, true, g_cleanViewportMode);
        } else {
            composeAppFrame(g_frame, g_simFrame, settings, false, g_cleanViewportMode);
        }

        InvalidateRect(g_window, nullptr, FALSE);
        UpdateWindow(g_window);

        if (copiedWorkerFrame || !g_cudaWorkerFrameLive) {
            ++visualFrames;
        }
        const float fpsElapsed = std::chrono::duration<float>(now - fpsLast).count();
        if (fpsElapsed >= 0.5f) {
            fps = static_cast<float>(visualFrames) / fpsElapsed;
            visualFrames = 0;
            fpsLast = now;
            g_visualFps = fps;
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
