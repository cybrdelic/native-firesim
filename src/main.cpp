#include <windows.h>
#include <windowsx.h>
#include <mmsystem.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include "fire_cuda.h"

namespace {

constexpr int kFrameWidth = 960;
constexpr int kFrameHeight = 540;
constexpr int kGridWidth = 224;
constexpr int kGridHeight = 144;
constexpr float kTargetFrameSeconds = 1.0f / 30.0f;

HWND g_window = nullptr;
std::vector<std::uint32_t> g_frame;
BITMAPINFO g_bitmap = {};
bool g_running = true;
bool g_leftDown = false;
bool g_rightDown = false;
bool g_orbiting = false;
bool g_needsReset = false;
bool g_showGizmos = true;
bool g_useCudaBackend = false;
float g_mouseX = 0.5f;
float g_mouseY = 0.10f;
int g_lastMouseX = 0;
int g_lastMouseY = 0;
float g_wind = 0.0f;
float g_turbulence = 0.72f;
float g_cameraYaw = 0.0f;
float g_cameraPitch = 0.18f;
float g_cameraDistance = 3.35f;
int g_activeGizmo = 1;
int g_clientW = kFrameWidth;
int g_clientH = kFrameHeight;
float g_cpuTime = 0.0f;

float clamp01(float v) {
    return std::max(0.0f, std::min(1.0f, v));
}

float clampf(float v, float lo, float hi) {
    return std::max(lo, std::min(hi, v));
}

float mixf(float a, float b, float t) {
    return a + (b - a) * t;
}

float hash2(float x, float y) {
    const float v = std::sin(x * 127.1f + y * 311.7f) * 43758.5453f;
    return v - std::floor(v);
}

float valueNoise(float x, float y) {
    const float ix = std::floor(x);
    const float iy = std::floor(y);
    const float fx = x - ix;
    const float fy = y - iy;
    const float ux = fx * fx * (3.0f - 2.0f * fx);
    const float uy = fy * fy * (3.0f - 2.0f * fy);
    const float a = hash2(ix, iy);
    const float b = hash2(ix + 1.0f, iy);
    const float c = hash2(ix, iy + 1.0f);
    const float d = hash2(ix + 1.0f, iy + 1.0f);
    return mixf(mixf(a, b, ux), mixf(c, d, ux), uy);
}

float fbm(float x, float y) {
    float sum = 0.0f;
    float amp = 0.5f;
    for (int i = 0; i < 5; ++i) {
        sum += amp * valueNoise(x, y);
        x = x * 2.03f + 13.7f;
        y = y * 2.01f - 7.4f;
        amp *= 0.5f;
    }
    return sum;
}

std::uint32_t packBgra(float r, float g, float b) {
    const auto ri = static_cast<std::uint32_t>(clamp01(r) * 255.0f);
    const auto gi = static_cast<std::uint32_t>(clamp01(g) * 255.0f);
    const auto bi = static_cast<std::uint32_t>(clamp01(b) * 255.0f);
    return 0xff000000u | (ri << 16) | (gi << 8) | bi;
}

void blendPixel(std::vector<std::uint32_t>& pixels, int x, int y, float r, float g, float b, float alpha) {
    if (x < 0 || y < 0 || x >= kFrameWidth || y >= kFrameHeight || alpha <= 0.0f) {
        return;
    }
    const std::uint32_t dst = pixels[static_cast<std::size_t>(y) * kFrameWidth + x];
    const float dr = static_cast<float>((dst >> 16) & 0xff) / 255.0f;
    const float dg = static_cast<float>((dst >> 8) & 0xff) / 255.0f;
    const float db = static_cast<float>(dst & 0xff) / 255.0f;
    alpha = clamp01(alpha);
    pixels[static_cast<std::size_t>(y) * kFrameWidth + x] = packBgra(
        mixf(dr, r, alpha),
        mixf(dg, g, alpha),
        mixf(db, b, alpha));
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

float screenDistance(float ax, float ay, float bx, float by) {
    const float dx = ax - bx;
    const float dy = ay - by;
    return std::sqrt(dx * dx + dy * dy);
}

int hitTestGizmo(float mouseX, float mouseScreenY) {
    if (!g_showGizmos) {
        return 0;
    }
    if (screenDistance(mouseX, mouseScreenY, 0.50f, 0.69f) < 0.075f) {
        return 1;
    }
    if (screenDistance(mouseX, mouseScreenY, 0.37f, 0.46f) < 0.052f) {
        return 2;
    }
    if (mouseScreenY > 0.62f && mouseScreenY < 0.70f && mouseX > 0.20f && mouseX < 0.47f) {
        return 3;
    }
    if (screenDistance(mouseX, mouseScreenY, 0.64f, 0.59f) < 0.058f) {
        return 4;
    }
    return 0;
}

void renderCpuSafeFrame(std::vector<std::uint32_t>& pixels, const FireSettings& settings, float time) {
    const float yaw = settings.cameraYaw;
    const float pitch = clampf(settings.cameraPitch, -0.55f, 0.55f);
    const float zoom = clampf(3.35f / std::max(1.7f, settings.cameraDistance), 0.62f, 1.95f);
    const float horizon = clampf(0.55f + pitch * 0.22f, 0.36f, 0.72f);
    const float centerX = 0.5f + std::sin(yaw) * 0.10f;
    const float sourceY = clampf(horizon + 0.20f * zoom, 0.62f, 0.84f);
    const float plumeHeight = 0.56f * zoom;
    const float baseWidth = 0.13f * zoom;
    const float smokeGain = clampf(settings.smoke, 0.0f, 1.6f);
    const float turbulence = clampf(settings.turbulence, 0.05f, 1.8f);

    for (int y = 0; y < kFrameHeight; ++y) {
        const float v = (static_cast<float>(y) + 0.5f) / static_cast<float>(kFrameHeight);
        for (int x = 0; x < kFrameWidth; ++x) {
            const float u = (static_cast<float>(x) + 0.5f) / static_cast<float>(kFrameWidth);
            const float floorMask = v > horizon ? 1.0f : 0.0f;
            float r = mixf(0.062f, 0.038f, floorMask);
            float g = mixf(0.064f, 0.036f, floorMask);
            float b = mixf(0.065f, 0.034f, floorMask);

            if (floorMask > 0.0f) {
                const float depth = std::max(0.001f, v - horizon);
                const float perspective = 0.16f + depth * (1.8f / zoom);
                const float yawSkew = std::sin(yaw) * depth * 0.28f;
                const float gx = std::fabs((u - 0.5f + yawSkew) / perspective * 10.0f - std::floor((u - 0.5f + yawSkew) / perspective * 10.0f + 0.5f));
                const float gy = std::fabs(depth * 15.0f / zoom - std::floor(depth * 15.0f / zoom + 0.5f));
                const float grid = (gx < 0.015f || gy < 0.015f) ? 0.095f : 0.0f;
                r += grid;
                g += grid;
                b += grid;
            }

            const float above = clamp01((sourceY - v) / plumeHeight);
            const float windLean = settings.wind * above * 0.18f;
            const float swirl = (fbm(u * 7.0f + time * 0.35f, v * 9.0f - time * 0.62f) - 0.5f) * 0.11f * turbulence * above;
            const float x0 = u - centerX - windLean - swirl;
            const float flameWidth = baseWidth * (0.30f + above * 0.58f);
            const float smokeWidth = baseWidth * (0.82f + above * 1.55f);
            const float flameRadial = std::exp(-(x0 * x0) / std::max(0.00001f, flameWidth * flameWidth));
            const float smokeRadial = std::exp(-(x0 * x0) / std::max(0.00001f, smokeWidth * smokeWidth));
            const float lickNoise = fbm(u * 30.0f + time * 2.4f, v * 42.0f - time * 3.1f + yaw);
            const float filament = clamp01((lickNoise - 0.48f) * 2.4f) * clamp01((0.86f - above) * 2.3f);
            const float flameMask = clamp01(above * 4.6f) * clamp01((0.76f - above) * 3.2f);
            float flame = flameRadial * flameMask * (0.55f + lickNoise * 0.92f + filament * 0.90f);
            const float baseGlow = std::exp(-(x0 * x0 * 18.0f + (v - sourceY) * (v - sourceY) * 170.0f));
            float smoke = smokeRadial * clamp01((above - 0.20f) * 1.35f) * clamp01((1.08f - above) * 1.3f) * smokeGain;

            if (settings.leftDown != 0) {
                const float sx = settings.mouseX;
                const float sy = 1.0f - settings.mouseY;
                const float d2 = (u - sx) * (u - sx) * 70.0f + (v - sy) * (v - sy) * 120.0f;
                flame += std::exp(-d2) * 1.8f;
            }
            if (settings.rightDown != 0) {
                const float sx = settings.mouseX;
                const float sy = 1.0f - settings.mouseY;
                const float d2 = (u - sx) * (u - sx) * 46.0f + (v - sy) * (v - sy) * 72.0f;
                smoke += std::exp(-d2) * 1.3f;
            }

            const float tray = (std::fabs(u - centerX) < 0.24f * zoom && std::fabs(v - sourceY) < 0.040f * zoom) ? 1.0f : 0.0f;
            r = mixf(r, 0.040f, tray * 0.55f);
            g = mixf(g, 0.028f, tray * 0.55f);
            b = mixf(b, 0.018f, tray * 0.55f);

            r += baseGlow * 0.35f + flame * 1.85f;
            g += baseGlow * 0.12f + flame * (0.66f + flame * 0.19f);
            b += baseGlow * 0.030f + flame * flame * 0.085f;

            const float smokeAlpha = clamp01(smoke * 0.62f);
            r = mixf(r, 0.030f, smokeAlpha);
            g = mixf(g, 0.028f, smokeAlpha);
            b = mixf(b, 0.026f, smokeAlpha);

            const float core = flameRadial * clamp01(above * 7.0f) * clamp01((0.46f - above) * 3.4f);
            r += core * 1.25f;
            g += core * 0.74f;
            b += core * 0.16f;

            pixels[static_cast<std::size_t>(y) * kFrameWidth + x] = packBgra(r, g, b);
        }
    }

    for (int i = 0; i < 48; ++i) {
        const float seed = static_cast<float>(i);
        const float age = hash2(seed, std::floor(time * 2.0f)) + std::fmod(time * (0.22f + hash2(seed, 3.0f) * 0.25f), 1.0f);
        const float life = age - std::floor(age);
        const float sx = centerX + (hash2(seed, 9.0f) - 0.5f) * 0.30f * zoom + settings.wind * life * 0.16f;
        const float sy = sourceY - life * (0.36f + hash2(seed, 11.0f) * 0.26f) + life * life * 0.12f;
        const int px = static_cast<int>(sx * kFrameWidth);
        const int py = static_cast<int>(sy * kFrameHeight);
        const float hot = (1.0f - life) * hash2(seed, 15.0f);
        blendPixel(pixels, px, py, 1.0f, 0.38f, 0.055f, hot);
        blendPixel(pixels, px + 1, py, 1.0f, 0.22f, 0.035f, hot * 0.42f);
    }

    if (settings.showGizmos != 0) {
        drawCircle(pixels, 0.50f, 0.69f, 0.052f, settings.activeGizmo == 1 ? 1.0f : 0.45f, 0.22f, 0.04f, 0.95f);
        drawCircle(pixels, 0.37f, 0.46f, 0.030f, 0.72f, 0.72f, 0.74f, settings.activeGizmo == 2 ? 0.95f : 0.55f);
        drawCircle(pixels, 0.64f, 0.59f, 0.033f, 0.82f, 0.22f, 0.96f, settings.activeGizmo == 4 ? 0.95f : 0.55f);
        drawLine(pixels, 0.30f, 0.66f, 0.30f + settings.wind * 0.16f, 0.66f, 0.0f, 0.82f, 1.0f, settings.activeGizmo == 3 ? 0.95f : 0.55f);
        drawLine(pixels, 0.88f, 0.86f, 0.94f, 0.86f, 1.0f, 0.10f, 0.08f, 0.95f);
        drawLine(pixels, 0.88f, 0.86f, 0.88f, 0.78f, 0.18f, 1.0f, 0.25f, 0.95f);
        drawLine(pixels, 0.88f, 0.86f, 0.84f, 0.89f, 0.20f, 0.42f, 1.0f, 0.95f);
    }
}

void updateMouseFromLParam(LPARAM lParam) {
    const int x = GET_X_LPARAM(lParam);
    const int y = GET_Y_LPARAM(lParam);
    g_lastMouseX = x;
    g_lastMouseY = y;
    g_mouseX = clamp01(static_cast<float>(x) / static_cast<float>(std::max(1, g_clientW)));
    g_mouseY = clamp01(1.0f - static_cast<float>(y) / static_cast<float>(std::max(1, g_clientH)));
}

void applyActiveGizmo() {
    if (!g_leftDown) {
        return;
    }
    if (g_activeGizmo == 3) {
        g_wind = std::max(-1.0f, std::min(1.0f, (g_mouseX - 0.5f) * 2.0f));
    } else if (g_activeGizmo == 4) {
        g_turbulence = std::max(0.05f, std::min(1.5f, 0.12f + g_mouseY * 1.38f));
    }
}

void updateTitle(float fps) {
    char title[256] = {};
    std::snprintf(
        title,
        sizeof(title),
        "Native FireSim %s | %.0f fps | tool %d | wind %.2f | turbulence %.2f | RMB orbit, wheel zoom",
        g_useCudaBackend ? "CUDA opt-in" : "safe CPU preview",
        fps,
        g_activeGizmo,
        g_wind,
        g_turbulence);
    SetWindowTextA(g_window, title);
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
        updateMouseFromLParam(lParam);
        if (!g_useCudaBackend) {
            const int hit = hitTestGizmo(g_mouseX, 1.0f - g_mouseY);
            if (hit != 0) {
                g_activeGizmo = hit;
            }
        }
        applyActiveGizmo();
        return 0;
    case WM_LBUTTONUP:
        g_leftDown = false;
        if (!g_rightDown) {
            ReleaseCapture();
        }
        return 0;
    case WM_RBUTTONDOWN:
        SetCapture(hwnd);
        g_rightDown = true;
        g_orbiting = true;
        updateMouseFromLParam(lParam);
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
        } else {
            applyActiveGizmo();
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
        HDC dc = BeginPaint(hwnd, &ps);
        SetStretchBltMode(dc, HALFTONE);
        StretchDIBits(
            dc,
            0,
            0,
            std::max(1, g_clientW),
            std::max(1, g_clientH),
            0,
            0,
            kFrameWidth,
            kFrameHeight,
            g_frame.data(),
            &g_bitmap,
            DIB_RGB_COLORS,
            SRCCOPY);
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
        "Native FireSim CUDA",
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

void initializeBitmapInfo() {
    g_bitmap.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    g_bitmap.bmiHeader.biWidth = kFrameWidth;
    g_bitmap.bmiHeader.biHeight = -kFrameHeight;
    g_bitmap.bmiHeader.biPlanes = 1;
    g_bitmap.bmiHeader.biBitCount = 32;
    g_bitmap.bmiHeader.biCompression = BI_RGB;
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

int runCpuSmokeTest() {
    CreateDirectoryA("out", nullptr);
    std::vector<std::uint32_t> frame(kFrameWidth * kFrameHeight, 0xff000000u);
    FireSettings settings;
    settings.showGizmos = 1;
    settings.activeGizmo = 1;
    settings.wind = 0.15f;
    settings.turbulence = 0.82f;
    settings.smoke = 0.96f;
    renderCpuSafeFrame(frame, settings, 2.5f);
    return writeBmp("out\\cpu-smoke-test-frame.bmp", frame, kFrameWidth, kFrameHeight) ? 0 : 3;
}

int runInputStressTest() {
    std::vector<std::uint32_t> frame(kFrameWidth * kFrameHeight, 0xff000000u);
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
        renderCpuSafeFrame(frame, settings, static_cast<float>(i) / 24.0f);
    }
    return 0;
}

int runCudaSmokeTest() {
    CreateDirectoryA("out", nullptr);
    std::vector<std::uint32_t> frame(kFrameWidth * kFrameHeight, 0xff000000u);

    if (!fireCudaInitialize(kFrameWidth, kFrameHeight, kGridWidth, kGridHeight)) {
        return 2;
    }

    bool ok = true;
    for (int i = 0; i < 150; ++i) {
        FireSettings settings;
        settings.width = kFrameWidth;
        settings.height = kFrameHeight;
        settings.dt = 1.0f / 60.0f;
        settings.mouseX = 0.50f + 0.08f * std::sin(static_cast<float>(i) * 0.08f);
        settings.mouseY = 0.13f + 0.04f * std::sin(static_cast<float>(i) * 0.045f);
        settings.leftDown = i > 12 && i < 84 ? 1 : 0;
        settings.showGizmos = 1;
        settings.activeGizmo = 3;
        settings.wind = 0.08f;
        settings.turbulence = 0.82f;
        settings.detail = 0.92f;
        settings.smoke = 0.96f;
        settings.cameraYaw = 0.34f;
        settings.cameraPitch = 0.18f;
        settings.cameraDistance = 3.35f;
        if (!fireCudaStepAndRender(frame.data(), settings)) {
            ok = false;
            break;
        }
    }

    if (ok) {
        ok = writeBmp("out\\smoke-test-frame.bmp", frame, kFrameWidth, kFrameHeight);
    }
    fireCudaShutdown();
    return ok ? 0 : 3;
}

int runDiagnostics() {
    CreateDirectoryA("out", nullptr);
    FireCudaDiagnostics diagnostics;
    const bool cudaOk = fireCudaGetDiagnostics(&diagnostics);

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

    out << "liveCudaDefault=false\n";
    out << "liveCudaFlag=--allow-live-cuda\n";
    return out.good() && cudaOk ? 0 : 2;
}

} // namespace

int WINAPI WinMain(HINSTANCE instance, HINSTANCE, LPSTR commandLine, int) {
    const std::string args = commandLine != nullptr ? commandLine : "";
    if (args.find("--diagnostics") != std::string::npos) {
        return runDiagnostics();
    }
    if (args.find("--cuda-smoke-test") != std::string::npos) {
        return runCudaSmokeTest();
    }
    if (args.find("--input-stress-test") != std::string::npos) {
        return runInputStressTest();
    }
    if (args.find("--smoke-test") != std::string::npos || args.find("--cpu-smoke-test") != std::string::npos) {
        return runCpuSmokeTest();
    }

    g_useCudaBackend = args.find("--allow-live-cuda") != std::string::npos;

    timeBeginPeriod(1);
    g_frame.assign(kFrameWidth * kFrameHeight, 0xff000000u);
    initializeBitmapInfo();

    if (!createMainWindow(instance)) {
        MessageBoxA(nullptr, "Failed to create the Native FireSim window.", "Native FireSim", MB_ICONERROR);
        return 1;
    }

    if (g_useCudaBackend && !fireCudaInitialize(kFrameWidth, kFrameHeight, kGridWidth, kGridHeight)) {
        MessageBoxA(g_window, fireCudaLastError(), "CUDA initialization failed", MB_ICONERROR);
        return 1;
    }

    using Clock = std::chrono::high_resolution_clock;
    auto last = Clock::now();
    auto fpsLast = last;
    int frames = 0;
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
        settings.leftDown = (g_leftDown && g_activeGizmo == 1) ? 1 : 0;
        settings.rightDown = (g_leftDown && g_activeGizmo == 2) ? 1 : 0;
        settings.reset = g_needsReset ? 1 : 0;
        settings.showGizmos = g_showGizmos ? 1 : 0;
        settings.activeGizmo = g_activeGizmo;
        settings.wind = g_wind;
        settings.turbulence = g_turbulence;
        settings.detail = 0.92f;
        settings.smoke = 0.96f;
        settings.intensity = 1.0f;
        settings.cameraYaw = g_cameraYaw;
        settings.cameraPitch = g_cameraPitch;
        settings.cameraDistance = g_cameraDistance;
        g_needsReset = false;

        if (g_useCudaBackend && !fireCudaStepAndRender(g_frame.data(), settings)) {
            MessageBoxA(g_window, fireCudaLastError(), "CUDA render failed", MB_ICONERROR);
            break;
        }
        if (!g_useCudaBackend) {
            g_cpuTime += dt;
            renderCpuSafeFrame(g_frame, settings, g_cpuTime);
        }

        InvalidateRect(g_window, nullptr, FALSE);
        UpdateWindow(g_window);

        ++frames;
        const float fpsElapsed = std::chrono::duration<float>(now - fpsLast).count();
        if (fpsElapsed >= 0.5f) {
            fps = static_cast<float>(frames) / fpsElapsed;
            frames = 0;
            fpsLast = now;
            updateTitle(fps);
        }

        const float renderElapsed = std::chrono::duration<float>(Clock::now() - now).count();
        if (renderElapsed < kTargetFrameSeconds) {
            const auto sleepMs = static_cast<DWORD>((kTargetFrameSeconds - renderElapsed) * 1000.0f);
            if (sleepMs > 0) {
                Sleep(sleepMs);
            }
        } else {
            Sleep(1);
        }
    }

    if (g_useCudaBackend) {
        fireCudaShutdown();
    }
    timeEndPeriod(1);
    return 0;
}
