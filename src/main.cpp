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

float clamp01(float v) {
    return std::max(0.0f, std::min(1.0f, v));
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
        "Native FireSim CUDA | %.0f fps | tool %d | wind %.2f | turbulence %.2f | RMB orbit, wheel zoom",
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

int runSmokeTest() {
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

} // namespace

int WINAPI WinMain(HINSTANCE instance, HINSTANCE, LPSTR commandLine, int) {
    const std::string args = commandLine != nullptr ? commandLine : "";
    if (args.find("--smoke-test") != std::string::npos) {
        return runSmokeTest();
    }

    timeBeginPeriod(1);
    g_frame.assign(kFrameWidth * kFrameHeight, 0xff000000u);
    initializeBitmapInfo();

    if (!createMainWindow(instance)) {
        MessageBoxA(nullptr, "Failed to create the Native FireSim window.", "Native FireSim", MB_ICONERROR);
        return 1;
    }

    if (!fireCudaInitialize(kFrameWidth, kFrameHeight, kGridWidth, kGridHeight)) {
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

        if (!fireCudaStepAndRender(g_frame.data(), settings)) {
            MessageBoxA(g_window, fireCudaLastError(), "CUDA render failed", MB_ICONERROR);
            break;
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

    fireCudaShutdown();
    timeEndPeriod(1);
    return 0;
}
