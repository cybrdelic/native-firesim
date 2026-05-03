#include "fire_cuda.h"

#include <cuda_runtime.h>
#include <cuda_d3d11_interop.h>
#include <cuda_fp16.h>
#include <d3d11.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

namespace {

struct SimParams {
    int nx;
    int ny;
    int nz;
    int frameW;
    int frameH;
    float dt;
    float time;
    float mouseX;
    float mouseY;
    int leftDown;
    int rightDown;
    int showGizmos;
    int activeGizmo;
    float wind;
    float turbulence;
    float detail;
    float smokeGain;
    float intensity;
    float cameraYaw;
    float cameraPitch;
    float cameraDistance;
    int cinematicMode;
    int raymarchSteps;
    int emberCount;
    int renderDebugMode;
    float exposure;
    float reflectionGain;
    float smokeDarkness;
    int launchZStart;
    int launchZEnd;
    int launchFrameYStart;
    int launchFrameYEnd;
};

struct MetricAccumulator {
    double heatSum;
    double fuelSum;
    double oxygenSum;
    double sootSum;
    double charSum;
    double ashSum;
    double pyrolysisSum;
    double progressSum;
    double turbulenceEnergySum;
    double sootOpticalDepthSum;
    double opticalDepthSum;
    double heatReleaseProxy;
    double divergenceBeforeSq;
    double divergenceAfterSq;
    int maxHeatBits;
    int maxFuelBits;
    int maxSootBits;
    int maxPyrolysisBits;
    int maxProgressBits;
    int maxTurbulenceEnergyBits;
    int flameHeightBits;
    int divergenceBeforeMaxBits;
    int divergenceAfterMaxBits;
    int invalidCells;
};

constexpr int kPressureIterations = 40;
constexpr float kPressureOmega = 1.52f;
constexpr float kRoomHeightMeters = 2.03f;
constexpr float kAdvectionScale = 0.62f;
constexpr int kCudaBlockThreads = 256;
constexpr int kMaxRaymarchSteps = 120;
constexpr int kMaxEmberCount = 192;
constexpr int kVolumeLaunchDepth = 12;
constexpr int kRenderLaunchRows = 36;

float* g_heat = nullptr;
float* g_heatNext = nullptr;
float* g_fuel = nullptr;
float* g_fuelNext = nullptr;
float* g_oxygen = nullptr;
float* g_oxygenNext = nullptr;
float* g_soot = nullptr;
float* g_sootNext = nullptr;
float* g_char = nullptr;
float* g_charNext = nullptr;
float* g_ash = nullptr;
float* g_ashNext = nullptr;
float* g_pyrolysis = nullptr;
float* g_pyrolysisNext = nullptr;
float* g_progress = nullptr;
float* g_progressNext = nullptr;
float* g_turbulenceEnergy = nullptr;
float* g_turbulenceEnergyNext = nullptr;
float* g_sootOptics = nullptr;
float* g_sootOpticsNext = nullptr;
float* g_pressure = nullptr;
float* g_pressureNext = nullptr;
float* g_divergence = nullptr;
float* g_divergenceAfter = nullptr;
float* g_u = nullptr;
float* g_uNext = nullptr;
float* g_v = nullptr;
float* g_vNext = nullptr;
float* g_w = nullptr;
float* g_wNext = nullptr;
MetricAccumulator* g_metricsDevice = nullptr;
std::uint32_t* g_frameDevice = nullptr;
float4* g_hdrFrameDevice = nullptr;
ushort4* g_fp16FrameDevice = nullptr;
cudaGraphicsResource* g_d3dFp16Resource = nullptr;
cudaEvent_t g_stepStartEvent = nullptr;
cudaEvent_t g_afterSolveEvent = nullptr;
cudaEvent_t g_afterRenderEvent = nullptr;
int g_nx = 0;
int g_ny = 0;
int g_nz = 0;
int g_frameW = 0;
int g_frameH = 0;
int g_frameIndex = 0;
float g_time = 0.0f;
char g_lastError[512] = "No CUDA error.";

bool fail(const char* label, cudaError_t err) {
    std::snprintf(g_lastError, sizeof(g_lastError), "%s: %s", label, cudaGetErrorString(err));
    return false;
}

bool check(const char* label, cudaError_t err) {
    if (err != cudaSuccess) {
        return fail(label, err);
    }
    return true;
}

int clampHost(int v, int lo, int hi) {
    return std::max(lo, std::min(hi, v));
}

float floatFromBits(int bits) {
    float value = 0.0f;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

__host__ __device__ float saturate(float v) {
    return fminf(1.0f, fmaxf(0.0f, v));
}

__host__ __device__ float lerpf(float a, float b, float t) {
    return a + (b - a) * t;
}

__device__ float smoothstepf(float edge0, float edge1, float x) {
    const bool inverted = edge1 < edge0;
    const float lo = inverted ? edge1 : edge0;
    const float hi = inverted ? edge0 : edge1;
    const float t = saturate((x - lo) / fmaxf(0.000001f, hi - lo));
    const float value = t * t * (3.0f - 2.0f * t);
    return inverted ? 1.0f - value : value;
}

__device__ float fracf(float v) {
    return v - floorf(v);
}

__device__ void atomicMaxPositiveFloat(int* address, float value) {
    if (value > 0.0f && isfinite(value)) {
        atomicMax(address, __float_as_int(value));
    }
}

__device__ float3 add3(float3 a, float3 b) {
    return make_float3(a.x + b.x, a.y + b.y, a.z + b.z);
}

__device__ float3 sub3(float3 a, float3 b) {
    return make_float3(a.x - b.x, a.y - b.y, a.z - b.z);
}

__device__ float3 mul3(float3 a, float b) {
    return make_float3(a.x * b, a.y * b, a.z * b);
}

__device__ float3 lerp3(float3 a, float3 b, float t) {
    return add3(a, mul3(sub3(b, a), t));
}

__device__ float dot3(float3 a, float3 b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

__device__ float luminance3(float3 color) {
    return color.x * 0.2126f + color.y * 0.7152f + color.z * 0.0722f;
}

__device__ float3 cross3(float3 a, float3 b) {
    return make_float3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x);
}

__device__ float3 normalize3(float3 v) {
    const float len = sqrtf(fmaxf(0.000001f, dot3(v, v)));
    return make_float3(v.x / len, v.y / len, v.z / len);
}

__device__ float2 add2(float2 a, float2 b) {
    return make_float2(a.x + b.x, a.y + b.y);
}

__device__ float2 sub2(float2 a, float2 b) {
    return make_float2(a.x - b.x, a.y - b.y);
}

__device__ float2 mul2(float2 a, float s) {
    return make_float2(a.x * s, a.y * s);
}

__device__ float dot2(float2 a, float2 b) {
    return a.x * b.x + a.y * b.y;
}

struct CameraState {
    float3 eye;
    float3 forward;
    float3 right;
    float3 up;
    float tanHalfFov;
    float aspect;
};

__device__ CameraState makeCamera(const SimParams& p) {
    CameraState cam = {};
    const float3 target = make_float3(0.0f, 0.72f, 0.0f);
    const float cp = cosf(p.cameraPitch);
    cam.eye = make_float3(
        sinf(p.cameraYaw) * p.cameraDistance * cp,
        target.y + sinf(p.cameraPitch) * p.cameraDistance,
        cosf(p.cameraYaw) * p.cameraDistance * cp);
    cam.forward = normalize3(sub3(target, cam.eye));
    cam.right = normalize3(cross3(cam.forward, make_float3(0.0f, 1.0f, 0.0f)));
    cam.up = normalize3(cross3(cam.right, cam.forward));
    cam.tanHalfFov = 0.50f;
    cam.aspect = static_cast<float>(p.frameW) / static_cast<float>(p.frameH);
    return cam;
}

__device__ float3 cameraRayDirection(const CameraState& cam, float2 uv) {
    const float sx = (uv.x * 2.0f - 1.0f) * cam.aspect * cam.tanHalfFov;
    const float sy = (1.0f - uv.y * 2.0f) * cam.tanHalfFov;
    return normalize3(add3(add3(cam.forward, mul3(cam.right, sx)), mul3(cam.up, sy)));
}

__device__ float3 projectPoint(const CameraState& cam, float3 point) {
    const float3 view = sub3(point, cam.eye);
    const float depth = dot3(view, cam.forward);
    if (depth <= 0.02f) {
        return make_float3(-10.0f, -10.0f, -1.0f);
    }
    const float px = dot3(view, cam.right) / (depth * cam.tanHalfFov * cam.aspect);
    const float py = dot3(view, cam.up) / (depth * cam.tanHalfFov);
    return make_float3(0.5f + px * 0.5f, 0.5f - py * 0.5f, depth);
}

__device__ float volumeDomainFade(float u, float v, float w) {
    const float side =
        smoothstepf(0.000f, 0.095f, u) *
        smoothstepf(1.000f, 0.905f, u) *
        smoothstepf(0.000f, 0.100f, w) *
        smoothstepf(1.000f, 0.900f, w);
    const float floorFade = smoothstepf(0.000f, 0.018f, v);
    const float topFade = smoothstepf(1.000f, 0.520f, v);
    return saturate(side * floorFade * topFade);
}

__device__ float3 debugHeatColor(float value) {
    value = saturate(value);
    const float red = smoothstepf(0.05f, 0.45f, value);
    const float orange = smoothstepf(0.24f, 0.78f, value);
    const float white = smoothstepf(0.72f, 1.0f, value);
    return make_float3(
        saturate(red + white * 0.70f),
        saturate(orange * 0.58f + white * 0.78f),
        saturate(white * 0.62f));
}

__device__ float hash21(float2 p) {
    p = make_float2(p.x * 127.1f + p.y * 311.7f, p.x * 269.5f + p.y * 183.3f);
    return fracf(sinf(p.x + p.y) * 43758.5453123f);
}

__device__ float hash31(float3 p) {
    return fracf(sinf(p.x * 127.1f + p.y * 311.7f + p.z * 74.7f) * 43758.5453123f);
}

__device__ float valueNoise(float2 p) {
    const float2 i = make_float2(floorf(p.x), floorf(p.y));
    const float2 f = make_float2(fracf(p.x), fracf(p.y));
    const float a = hash21(i);
    const float b = hash21(make_float2(i.x + 1.0f, i.y));
    const float c = hash21(make_float2(i.x, i.y + 1.0f));
    const float d = hash21(make_float2(i.x + 1.0f, i.y + 1.0f));
    const float2 u = make_float2(f.x * f.x * (3.0f - 2.0f * f.x), f.y * f.y * (3.0f - 2.0f * f.y));
    return lerpf(lerpf(a, b, u.x), lerpf(c, d, u.x), u.y);
}

__device__ float valueNoise3(float3 p) {
    const float3 i = make_float3(floorf(p.x), floorf(p.y), floorf(p.z));
    const float3 f = make_float3(fracf(p.x), fracf(p.y), fracf(p.z));
    const float3 u = make_float3(
        f.x * f.x * (3.0f - 2.0f * f.x),
        f.y * f.y * (3.0f - 2.0f * f.y),
        f.z * f.z * (3.0f - 2.0f * f.z));
    const float c000 = hash31(i);
    const float c100 = hash31(make_float3(i.x + 1.0f, i.y, i.z));
    const float c010 = hash31(make_float3(i.x, i.y + 1.0f, i.z));
    const float c110 = hash31(make_float3(i.x + 1.0f, i.y + 1.0f, i.z));
    const float c001 = hash31(make_float3(i.x, i.y, i.z + 1.0f));
    const float c101 = hash31(make_float3(i.x + 1.0f, i.y, i.z + 1.0f));
    const float c011 = hash31(make_float3(i.x, i.y + 1.0f, i.z + 1.0f));
    const float c111 = hash31(make_float3(i.x + 1.0f, i.y + 1.0f, i.z + 1.0f));
    const float c00 = lerpf(c000, c100, u.x);
    const float c10 = lerpf(c010, c110, u.x);
    const float c01 = lerpf(c001, c101, u.x);
    const float c11 = lerpf(c011, c111, u.x);
    return lerpf(lerpf(c00, c10, u.y), lerpf(c01, c11, u.y), u.z);
}

__device__ float fbm(float2 p) {
    float sum = 0.0f;
    float amp = 0.5f;
    for (int i = 0; i < 5; ++i) {
        sum += amp * valueNoise(p);
        p = make_float2(p.x * 2.03f + 17.7f, p.y * 2.01f - 9.2f);
        amp *= 0.5f;
    }
    return sum;
}

__device__ float fbm3(float3 p) {
    float sum = 0.0f;
    float amp = 0.5f;
    for (int i = 0; i < 3; ++i) {
        sum += amp * valueNoise3(p);
        p = make_float3(p.x * 2.03f + 17.7f, p.y * 2.01f - 9.2f, p.z * 2.07f + 5.1f);
        amp *= 0.5f;
    }
    return saturate(sum * 1.142857f);
}

__device__ int scalarIndex(int x, int y, int z, const SimParams& p) {
    x = min(max(x, 0), p.nx - 1);
    y = min(max(y, 0), p.ny - 1);
    z = min(max(z, 0), p.nz - 1);
    return (z * p.ny + y) * p.nx + x;
}

__device__ int uIndex(int x, int y, int z, const SimParams& p) {
    x = min(max(x, 0), p.nx);
    y = min(max(y, 0), p.ny - 1);
    z = min(max(z, 0), p.nz - 1);
    return (z * p.ny + y) * (p.nx + 1) + x;
}

__device__ int vIndex(int x, int y, int z, const SimParams& p) {
    x = min(max(x, 0), p.nx - 1);
    y = min(max(y, 0), p.ny);
    z = min(max(z, 0), p.nz - 1);
    return (z * (p.ny + 1) + y) * p.nx + x;
}

__device__ int wIndex(int x, int y, int z, const SimParams& p) {
    x = min(max(x, 0), p.nx - 1);
    y = min(max(y, 0), p.ny - 1);
    z = min(max(z, 0), p.nz);
    return (z * p.ny + y) * p.nx + x;
}

__device__ float sampleScalar(const float* field, const SimParams& p, float u, float v, float w) {
    u = saturate(u);
    v = saturate(v);
    w = saturate(w);
    const float fx = u * static_cast<float>(p.nx - 1);
    const float fy = v * static_cast<float>(p.ny - 1);
    const float fz = w * static_cast<float>(p.nz - 1);
    const int x0 = static_cast<int>(floorf(fx));
    const int y0 = static_cast<int>(floorf(fy));
    const int z0 = static_cast<int>(floorf(fz));
    const int x1 = min(x0 + 1, p.nx - 1);
    const int y1 = min(y0 + 1, p.ny - 1);
    const int z1 = min(z0 + 1, p.nz - 1);
    const float tx = fx - static_cast<float>(x0);
    const float ty = fy - static_cast<float>(y0);
    const float tz = fz - static_cast<float>(z0);

    const float c000 = field[scalarIndex(x0, y0, z0, p)];
    const float c100 = field[scalarIndex(x1, y0, z0, p)];
    const float c010 = field[scalarIndex(x0, y1, z0, p)];
    const float c110 = field[scalarIndex(x1, y1, z0, p)];
    const float c001 = field[scalarIndex(x0, y0, z1, p)];
    const float c101 = field[scalarIndex(x1, y0, z1, p)];
    const float c011 = field[scalarIndex(x0, y1, z1, p)];
    const float c111 = field[scalarIndex(x1, y1, z1, p)];
    const float c00 = lerpf(c000, c100, tx);
    const float c10 = lerpf(c010, c110, tx);
    const float c01 = lerpf(c001, c101, tx);
    const float c11 = lerpf(c011, c111, tx);
    return lerpf(lerpf(c00, c10, ty), lerpf(c01, c11, ty), tz);
}

__device__ float sampleU(const float* field, const SimParams& p, float u, float v, float w) {
    u = saturate(u);
    v = saturate(v);
    w = saturate(w);
    const float fx = u * static_cast<float>(p.nx);
    const float fy = v * static_cast<float>(p.ny - 1);
    const float fz = w * static_cast<float>(p.nz - 1);
    const int x0 = static_cast<int>(floorf(fx));
    const int y0 = static_cast<int>(floorf(fy));
    const int z0 = static_cast<int>(floorf(fz));
    const int x1 = min(x0 + 1, p.nx);
    const int y1 = min(y0 + 1, p.ny - 1);
    const int z1 = min(z0 + 1, p.nz - 1);
    const float tx = fx - static_cast<float>(x0);
    const float ty = fy - static_cast<float>(y0);
    const float tz = fz - static_cast<float>(z0);
    const float c000 = field[uIndex(x0, y0, z0, p)];
    const float c100 = field[uIndex(x1, y0, z0, p)];
    const float c010 = field[uIndex(x0, y1, z0, p)];
    const float c110 = field[uIndex(x1, y1, z0, p)];
    const float c001 = field[uIndex(x0, y0, z1, p)];
    const float c101 = field[uIndex(x1, y0, z1, p)];
    const float c011 = field[uIndex(x0, y1, z1, p)];
    const float c111 = field[uIndex(x1, y1, z1, p)];
    return lerpf(lerpf(lerpf(c000, c100, tx), lerpf(c010, c110, tx), ty), lerpf(lerpf(c001, c101, tx), lerpf(c011, c111, tx), ty), tz);
}

__device__ float sampleV(const float* field, const SimParams& p, float u, float v, float w) {
    u = saturate(u);
    v = saturate(v);
    w = saturate(w);
    const float fx = u * static_cast<float>(p.nx - 1);
    const float fy = v * static_cast<float>(p.ny);
    const float fz = w * static_cast<float>(p.nz - 1);
    const int x0 = static_cast<int>(floorf(fx));
    const int y0 = static_cast<int>(floorf(fy));
    const int z0 = static_cast<int>(floorf(fz));
    const int x1 = min(x0 + 1, p.nx - 1);
    const int y1 = min(y0 + 1, p.ny);
    const int z1 = min(z0 + 1, p.nz - 1);
    const float tx = fx - static_cast<float>(x0);
    const float ty = fy - static_cast<float>(y0);
    const float tz = fz - static_cast<float>(z0);
    const float c000 = field[vIndex(x0, y0, z0, p)];
    const float c100 = field[vIndex(x1, y0, z0, p)];
    const float c010 = field[vIndex(x0, y1, z0, p)];
    const float c110 = field[vIndex(x1, y1, z0, p)];
    const float c001 = field[vIndex(x0, y0, z1, p)];
    const float c101 = field[vIndex(x1, y0, z1, p)];
    const float c011 = field[vIndex(x0, y1, z1, p)];
    const float c111 = field[vIndex(x1, y1, z1, p)];
    return lerpf(lerpf(lerpf(c000, c100, tx), lerpf(c010, c110, tx), ty), lerpf(lerpf(c001, c101, tx), lerpf(c011, c111, tx), ty), tz);
}

__device__ float sampleW(const float* field, const SimParams& p, float u, float v, float w) {
    u = saturate(u);
    v = saturate(v);
    w = saturate(w);
    const float fx = u * static_cast<float>(p.nx - 1);
    const float fy = v * static_cast<float>(p.ny - 1);
    const float fz = w * static_cast<float>(p.nz);
    const int x0 = static_cast<int>(floorf(fx));
    const int y0 = static_cast<int>(floorf(fy));
    const int z0 = static_cast<int>(floorf(fz));
    const int x1 = min(x0 + 1, p.nx - 1);
    const int y1 = min(y0 + 1, p.ny - 1);
    const int z1 = min(z0 + 1, p.nz);
    const float tx = fx - static_cast<float>(x0);
    const float ty = fy - static_cast<float>(y0);
    const float tz = fz - static_cast<float>(z0);
    const float c000 = field[wIndex(x0, y0, z0, p)];
    const float c100 = field[wIndex(x1, y0, z0, p)];
    const float c010 = field[wIndex(x0, y1, z0, p)];
    const float c110 = field[wIndex(x1, y1, z0, p)];
    const float c001 = field[wIndex(x0, y0, z1, p)];
    const float c101 = field[wIndex(x1, y0, z1, p)];
    const float c011 = field[wIndex(x0, y1, z1, p)];
    const float c111 = field[wIndex(x1, y1, z1, p)];
    return lerpf(lerpf(lerpf(c000, c100, tx), lerpf(c010, c110, tx), ty), lerpf(lerpf(c001, c101, tx), lerpf(c011, c111, tx), ty), tz);
}

__device__ float3 sampleVelocity(const float* uField, const float* vField, const float* wField, const SimParams& p, float u, float v, float w) {
    return make_float3(sampleU(uField, p, u, v, w), sampleV(vField, p, u, v, w), sampleW(wField, p, u, v, w));
}

__device__ void scalarNeighborhoodBounds(
    const float* field,
    const SimParams& p,
    float u,
    float v,
    float w,
    float* outMin,
    float* outMax) {
    u = saturate(u);
    v = saturate(v);
    w = saturate(w);
    const float fx = u * static_cast<float>(p.nx - 1);
    const float fy = v * static_cast<float>(p.ny - 1);
    const float fz = w * static_cast<float>(p.nz - 1);
    const int x0 = static_cast<int>(floorf(fx));
    const int y0 = static_cast<int>(floorf(fy));
    const int z0 = static_cast<int>(floorf(fz));
    const int x1 = min(x0 + 1, p.nx - 1);
    const int y1 = min(y0 + 1, p.ny - 1);
    const int z1 = min(z0 + 1, p.nz - 1);
    float lo = field[scalarIndex(x0, y0, z0, p)];
    float hi = lo;
    const float c100 = field[scalarIndex(x1, y0, z0, p)];
    const float c010 = field[scalarIndex(x0, y1, z0, p)];
    const float c110 = field[scalarIndex(x1, y1, z0, p)];
    const float c001 = field[scalarIndex(x0, y0, z1, p)];
    const float c101 = field[scalarIndex(x1, y0, z1, p)];
    const float c011 = field[scalarIndex(x0, y1, z1, p)];
    const float c111 = field[scalarIndex(x1, y1, z1, p)];
    lo = fminf(lo, c100);
    lo = fminf(lo, c010);
    lo = fminf(lo, c110);
    lo = fminf(lo, c001);
    lo = fminf(lo, c101);
    lo = fminf(lo, c011);
    lo = fminf(lo, c111);
    hi = fmaxf(hi, c100);
    hi = fmaxf(hi, c010);
    hi = fmaxf(hi, c110);
    hi = fmaxf(hi, c001);
    hi = fmaxf(hi, c101);
    hi = fmaxf(hi, c011);
    hi = fmaxf(hi, c111);
    *outMin = lo;
    *outMax = hi;
}

__device__ float sampleScalarMacCormack(
    const float* field,
    const float* uField,
    const float* vField,
    const float* wField,
    const SimParams& p,
    float u,
    float v,
    float w,
    float prevU,
    float prevV,
    float prevW,
    float blend) {
    const float firstOrder = sampleScalar(field, p, prevU, prevV, prevW);
    const float current = sampleScalar(field, p, u, v, w);
    const float3 prevVel = sampleVelocity(uField, vField, wField, p, prevU, prevV, prevW);
    const float fwdU = prevU + prevVel.x * p.dt * kAdvectionScale;
    const float fwdV = prevV + prevVel.y * p.dt * kAdvectionScale;
    const float fwdW = prevW + prevVel.z * p.dt * kAdvectionScale;
    const float roundTrip = sampleScalar(field, p, fwdU, fwdV, fwdW);
    float lo = 0.0f;
    float hi = 0.0f;
    scalarNeighborhoodBounds(field, p, prevU, prevV, prevW, &lo, &hi);
    const float corrected = fminf(hi, fmaxf(lo, firstOrder + 0.5f * (current - roundTrip)));
    return lerpf(firstOrder, corrected, saturate(blend));
}

__device__ float fuelBedMaterial(float x, float z) {
    const float tray = smoothstepf(0.98f, 0.040f, fabsf(x)) * smoothstepf(0.48f, 0.034f, fabsf(z));
    const float mound = expf(-(x * x * 0.70f + z * z * 2.15f));
    const float logMass = fbm(make_float2(x * 3.7f + z * 0.9f, z * 5.4f - x * 0.6f));
    const float chips = fbm(make_float2(x * 15.0f + z * 4.0f, z * 18.0f - x * 5.0f));
    const float strand = 0.5f + 0.5f * sinf((x * 19.0f + z * 7.0f) + fbm(make_float2(z * 4.0f, x * 3.0f)) * 4.2f);
    const float cracks = smoothstepf(0.44f, 0.74f, chips) * smoothstepf(0.20f, 0.84f, logMass);
    const float voids = smoothstepf(0.70f, 0.93f, chips * 0.72f + strand * 0.34f);
    const float clumps = smoothstepf(0.22f, 0.86f, logMass * 0.82f + chips * 0.36f + strand * 0.18f);
    return saturate(tray * (0.18f + clumps * 0.92f) * (0.62f + mound * 0.44f) * (1.0f - cracks * 0.62f) * (1.0f - voids * 0.48f));
}

__device__ float fuelBedSource(float x, float z, float h, float time) {
    const float material = fuelBedMaterial(x, z);
    const float height = smoothstepf(0.105f, 0.00f, h);
    const float emberBreathing = 0.84f + 0.16f * fbm(make_float2(x * 9.0f + time * 0.035f, z * 11.0f - time * 0.025f));
    const float exposedFuel = saturate(material * emberBreathing);
    return saturate(height * exposedFuel);
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) resetScalarsKernel(
    float* heat,
    float* fuel,
    float* oxygen,
    float* soot,
    float* charField,
    float* ash,
    float* pyrolysis,
    float* progress,
    float* turbulenceEnergy,
    float* sootOptics,
    float* pressure,
    float* divergence,
    SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = p.launchZStart + blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= p.nx || y >= p.ny || z >= p.launchZEnd || z >= p.nz) {
        return;
    }
    const int idx = scalarIndex(x, y, z, p);
    const float u = (static_cast<float>(x) + 0.5f) / static_cast<float>(p.nx);
    const float v = (static_cast<float>(y) + 0.5f) / static_cast<float>(p.ny);
    const float w = (static_cast<float>(z) + 0.5f) / static_cast<float>(p.nz);
    const float worldX = (u - 0.50f) * 2.10f;
    const float worldZ = (w - 0.50f) * 1.64f;
    const float material = fuelBedMaterial(worldX, worldZ);
    const float chunkNoise = fbm(make_float2(worldX * 18.0f + worldZ * 2.0f, worldZ * 22.0f - worldX * 5.0f));
    const float bed = fuelBedSource(worldX, worldZ, v, p.time);
    heat[idx] = bed * (0.42f + chunkNoise * 0.18f);
    fuel[idx] = bed * (0.84f + chunkNoise * 0.32f);
    oxygen[idx] = 1.0f;
    soot[idx] = bed * 0.065f;
    charField[idx] = material * (0.92f + chunkNoise * 0.72f);
    ash[idx] = material * (0.018f + smoothstepf(0.56f, 0.86f, chunkNoise) * 0.055f);
    pyrolysis[idx] = 0.0f;
    progress[idx] = bed * 0.10f;
    turbulenceEnergy[idx] = bed * 0.055f;
    sootOptics[idx] = bed * 0.080f;
    pressure[idx] = 0.0f;
    divergence[idx] = 0.0f;
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) resetUKernel(float* field, SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = p.launchZStart + blockIdx.z * blockDim.z + threadIdx.z;
    if (x > p.nx || y >= p.ny || z >= p.launchZEnd || z >= p.nz) {
        return;
    }
    field[uIndex(x, y, z, p)] = 0.0f;
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) resetVKernel(float* field, SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = p.launchZStart + blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= p.nx || y > p.ny || z >= p.launchZEnd || z >= p.nz) {
        return;
    }
    field[vIndex(x, y, z, p)] = 0.0f;
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) resetWKernel(float* field, SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = p.launchZStart + blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= p.nx || y >= p.ny || z >= p.launchZEnd || z > p.nz) {
        return;
    }
    field[wIndex(x, y, z, p)] = 0.0f;
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) advectUKernel(float* out, const float* inU, const float* inV, const float* inW, SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = p.launchZStart + blockIdx.z * blockDim.z + threadIdx.z;
    if (x > p.nx || y >= p.ny || z >= p.launchZEnd || z >= p.nz) {
        return;
    }
    if (x == 0 || x == p.nx) {
        out[uIndex(x, y, z, p)] = 0.0f;
        return;
    }
    const float fu = static_cast<float>(x) / static_cast<float>(p.nx);
    const float fv = (static_cast<float>(y) + 0.5f) / static_cast<float>(p.ny);
    const float fw = (static_cast<float>(z) + 0.5f) / static_cast<float>(p.nz);
    const float3 vel = sampleVelocity(inU, inV, inW, p, fu, fv, fw);
    out[uIndex(x, y, z, p)] = sampleU(inU, p, fu - vel.x * p.dt * kAdvectionScale, fv - vel.y * p.dt * kAdvectionScale, fw - vel.z * p.dt * kAdvectionScale) * 0.995f;
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) advectVKernel(float* out, const float* inU, const float* inV, const float* inW, SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = p.launchZStart + blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= p.nx || y > p.ny || z >= p.launchZEnd || z >= p.nz) {
        return;
    }
    if (y == 0) {
        out[vIndex(x, y, z, p)] = 0.0f;
        return;
    }
    const float fu = (static_cast<float>(x) + 0.5f) / static_cast<float>(p.nx);
    const float fv = static_cast<float>(y) / static_cast<float>(p.ny);
    const float fw = (static_cast<float>(z) + 0.5f) / static_cast<float>(p.nz);
    const float3 vel = sampleVelocity(inU, inV, inW, p, fu, fv, fw);
    out[vIndex(x, y, z, p)] = sampleV(inV, p, fu - vel.x * p.dt * kAdvectionScale, fv - vel.y * p.dt * kAdvectionScale, fw - vel.z * p.dt * kAdvectionScale) * 0.996f;
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) advectWKernel(float* out, const float* inU, const float* inV, const float* inW, SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = p.launchZStart + blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= p.nx || y >= p.ny || z >= p.launchZEnd || z > p.nz) {
        return;
    }
    if (z == 0 || z == p.nz) {
        out[wIndex(x, y, z, p)] = 0.0f;
        return;
    }
    const float fu = (static_cast<float>(x) + 0.5f) / static_cast<float>(p.nx);
    const float fv = (static_cast<float>(y) + 0.5f) / static_cast<float>(p.ny);
    const float fw = static_cast<float>(z) / static_cast<float>(p.nz);
    const float3 vel = sampleVelocity(inU, inV, inW, p, fu, fv, fw);
    out[wIndex(x, y, z, p)] = sampleW(inW, p, fu - vel.x * p.dt * kAdvectionScale, fv - vel.y * p.dt * kAdvectionScale, fw - vel.z * p.dt * kAdvectionScale) * 0.995f;
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) advectReactKernel(
    float* heatOut,
    float* fuelOut,
    float* oxygenOut,
    float* sootOut,
    float* charOut,
    float* ashOut,
    float* pyrolysisOut,
    float* progressOut,
    float* turbulenceEnergyOut,
    float* sootOpticsOut,
    const float* heatIn,
    const float* fuelIn,
    const float* oxygenIn,
    const float* sootIn,
    const float* charIn,
    const float* ashIn,
    const float* pyrolysisIn,
    const float* progressIn,
    const float* turbulenceEnergyIn,
    const float* sootOpticsIn,
    const float* uField,
    const float* vField,
    const float* wField,
    SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = p.launchZStart + blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= p.nx || y >= p.ny || z >= p.launchZEnd || z >= p.nz) {
        return;
    }

    const float u = (static_cast<float>(x) + 0.5f) / static_cast<float>(p.nx);
    const float v = (static_cast<float>(y) + 0.5f) / static_cast<float>(p.ny);
    const float w = (static_cast<float>(z) + 0.5f) / static_cast<float>(p.nz);
    const float3 vel = sampleVelocity(uField, vField, wField, p, u, v, w);
    const float prevU = u - vel.x * p.dt * kAdvectionScale;
    const float prevV = v - vel.y * p.dt * kAdvectionScale;
    const float prevW = w - vel.z * p.dt * kAdvectionScale;

    const float antiDiffusion = saturate(0.30f + p.detail * 0.34f);
    float heat = sampleScalarMacCormack(heatIn, uField, vField, wField, p, u, v, w, prevU, prevV, prevW, antiDiffusion);
    float fuel = sampleScalarMacCormack(fuelIn, uField, vField, wField, p, u, v, w, prevU, prevV, prevW, antiDiffusion * 0.92f);
    float oxygen = sampleScalarMacCormack(oxygenIn, uField, vField, wField, p, u, v, w, prevU, prevV, prevW, antiDiffusion * 0.70f);
    float soot = sampleScalarMacCormack(sootIn, uField, vField, wField, p, u, v, w, prevU, prevV, prevW, antiDiffusion);
    const int idx = scalarIndex(x, y, z, p);
    float charMass = charIn[idx];
    float ash = ashIn[idx];
    float pyrolysisRate = sampleScalarMacCormack(pyrolysisIn, uField, vField, wField, p, u, v, w, prevU, prevV, prevW, antiDiffusion * 0.72f) * 0.55f;
    float progress = sampleScalarMacCormack(progressIn, uField, vField, wField, p, u, v, w, prevU, prevV, prevW, antiDiffusion * 0.82f);
    float turbulenceEnergy = sampleScalarMacCormack(turbulenceEnergyIn, uField, vField, wField, p, u, v, w, prevU, prevV, prevW, antiDiffusion * 0.52f);
    float sootOptics = sampleScalarMacCormack(sootOpticsIn, uField, vField, wField, p, u, v, w, prevU, prevV, prevW, antiDiffusion * 0.72f);

    const float worldX = (u - 0.50f) * 2.10f;
    const float worldZ = (w - 0.50f) * 1.64f;
    const float material = fuelBedMaterial(worldX, worldZ);
    const float sourceNoise = 0.70f + 0.48f * fbm(make_float2(worldX * 13.0f + worldZ * 3.0f + p.time * 0.38f, v * 31.0f + worldZ * 11.0f));
    const float exposedChar = saturate(charMass / fmaxf(0.055f, charMass + ash * 1.75f));
    const float charEdges = smoothstepf(0.06f, 0.78f, material) * smoothstepf(0.92f, 0.02f, ash);
    const float bed = fuelBedSource(worldX, worldZ, v, p.time) * sourceNoise * exposedChar * charEdges * p.intensity;
    const float ambientK = 293.0f;
    float tempK = ambientK + heat * 335.0f;
    const float radiativeFeedback = smoothstepf(430.0f, 980.0f, tempK);
    const float solidOxygen = saturate(oxygen * 1.28f - soot * 0.030f);
    const float heatFlux = saturate((tempK - 405.0f) / 900.0f) + bed * 0.34f + sootOptics * 0.024f;
    const float charRelease = fminf(charMass, charMass * heatFlux * solidOxygen * (0.14f + radiativeFeedback * 1.38f) * p.dt);
    pyrolysisRate += bed * (0.15f + radiativeFeedback * 0.92f) * p.dt + charRelease * (2.30f + sourceNoise * 0.70f);
    charMass += material * p.dt * 0.026f;
    charMass -= charRelease * 0.92f;
    ash += charRelease * (0.16f + 0.22f * saturate(1.0f - oxygen));

    heat += bed * 4.65f * p.dt * (1.0f + radiativeFeedback * 1.18f) + charRelease * 3.10f;
    fuel += pyrolysisRate * 3.75f;
    soot += pyrolysisRate * (0.090f + ash * 0.032f + saturate(1.0f - oxygen) * 0.13f) * p.smokeGain;

    if (p.leftDown != 0) {
        const float mx = p.mouseX;
        const float my = p.mouseY;
        const float source = expf(-((u - mx) * (u - mx) + (w - 0.5f) * (w - 0.5f)) / 0.0110f - (v - my) * (v - my) / 0.0100f);
        heat += source * p.dt * 5.8f;
        fuel += source * p.dt * 4.0f;
    }
    if (p.rightDown != 0) {
        const float source = expf(-((u - p.mouseX) * (u - p.mouseX) + (w - 0.5f) * (w - 0.5f)) / 0.0100f - (v - p.mouseY) * (v - p.mouseY) / 0.0100f);
        soot += source * p.dt * 8.0f;
        heat *= 1.0f - source * p.dt * 1.2f;
        fuel *= 1.0f - source * p.dt * 0.7f;
    }

    tempK = ambientK + heat * 335.0f;
    const float thermalActivation = smoothstepf(610.0f, 1280.0f, tempK);
    const float arrhenius = expf(-4150.0f / fmaxf(650.0f, tempK));
    const float oxygenLimited = fminf(fuel, oxygen * 1.42f);
    const float burnMass = fminf(oxygenLimited, oxygenLimited * thermalActivation * arrhenius * (104.0f + p.intensity * 28.0f) * p.dt);
    const float incomplete = saturate(1.0f - oxygen * 1.30f + fuel * 0.065f + soot * 0.015f);
    const float heatRelease = burnMass * 7.25f;
    const float sootYield = burnMass * (0.035f + incomplete * 0.34f) * p.smokeGain;
    const float sootOxidation = soot * oxygen * smoothstepf(760.0f, 1540.0f, tempK) * p.dt * 0.82f;
    const float frontProduction = burnMass * (9.5f + turbulenceEnergy * 3.2f) + pyrolysisRate * 0.68f + charRelease * 2.10f;

    heat += heatRelease;
    fuel -= burnMass * 1.20f;
    oxygen -= burnMass * 0.98f;
    soot += sootYield;
    soot -= sootOxidation;
    progress += frontProduction;
    progress *= expf(-p.dt * (0.72f + v * 0.45f + oxygen * 0.16f));

    const float boundaryAir = smoothstepf(0.70f, 0.96f, v) + smoothstepf(0.11f, 0.03f, u) + smoothstepf(0.89f, 0.97f, u) + smoothstepf(0.11f, 0.03f, w) + smoothstepf(0.89f, 0.97f, w);
    oxygen = lerpf(oxygen, 1.0f, saturate(boundaryAir) * p.dt * 1.7f);
    oxygen += (1.0f - oxygen) * p.dt * 0.08f;

    tempK = ambientK + heat * 335.0f;
    const float radiationLoss = powf(fmaxf(0.0f, (tempK - ambientK) / 1560.0f), 4.0f);
    heat -= radiationLoss * p.dt * (0.88f + soot * 0.085f + sootOptics * 0.018f);
    heat *= expf(-p.dt * (0.31f + v * 0.64f + soot * 0.022f));
    fuel *= expf(-p.dt * (0.58f + heat * 0.20f + v * 0.92f));
    soot *= expf(-p.dt * (0.060f + v * 0.092f + oxygen * 0.028f + saturate(boundaryAir) * 0.42f));
    pyrolysisRate *= expf(-p.dt * (1.55f + v * 0.58f));

    const float cellX = 1.0f / static_cast<float>(p.nx);
    const float cellY = 1.0f / static_cast<float>(p.ny);
    const float cellZ = 1.0f / static_cast<float>(p.nz);
    const float3 velL = sampleVelocity(uField, vField, wField, p, u - cellX, v, w);
    const float3 velR = sampleVelocity(uField, vField, wField, p, u + cellX, v, w);
    const float3 velD = sampleVelocity(uField, vField, wField, p, u, v - cellY, w);
    const float3 velU = sampleVelocity(uField, vField, wField, p, u, v + cellY, w);
    const float3 velB = sampleVelocity(uField, vField, wField, p, u, v, w - cellZ);
    const float3 velF = sampleVelocity(uField, vField, wField, p, u, v, w + cellZ);
    const float shear =
        fabsf(velR.x - velL.x) +
        fabsf(velU.y - velD.y) +
        fabsf(velF.z - velB.z) +
        fabsf(velR.y - velL.y) * 0.5f +
        fabsf(velU.x - velD.x) * 0.5f +
        fabsf(velF.x - velB.x) * 0.35f;
    const float flameActivity = saturate(progress * 0.64f + burnMass * 5.2f + heat * 0.065f);
    turbulenceEnergy += p.dt * (shear * (0.72f + progress * 0.06f) + flameActivity * p.turbulence * 0.62f + frontProduction * 0.085f + soot * 0.018f);
    turbulenceEnergy *= expf(-p.dt * (0.54f + v * 0.24f));
    const float particleGrowth = saturate(incomplete * 0.36f + ash * 0.13f + soot * 0.055f + smoothstepf(0.65f, 1.55f, tempK / 1000.0f) * 0.18f);
    sootOptics = soot * (1.04f + 0.28f * sqrtf(fmaxf(0.0f, heat)) + 0.24f * ash + 0.46f * particleGrowth);
    sootOptics = lerpf(sootOptics, sootOptics * 0.48f, saturate(sootOxidation * 0.92f));

    heatOut[idx] = fminf(8.8f, fmaxf(0.0f, heat));
    fuelOut[idx] = fminf(5.5f, fmaxf(0.0f, fuel));
    oxygenOut[idx] = fminf(1.0f, fmaxf(0.0f, oxygen));
    sootOut[idx] = fminf(7.4f, fmaxf(0.0f, soot));
    charOut[idx] = fminf(2.8f, fmaxf(0.0f, charMass));
    ashOut[idx] = fminf(1.9f, fmaxf(0.0f, ash));
    pyrolysisOut[idx] = fminf(3.6f, fmaxf(0.0f, pyrolysisRate));
    progressOut[idx] = fminf(3.4f, fmaxf(0.0f, progress));
    turbulenceEnergyOut[idx] = fminf(4.2f, fmaxf(0.0f, turbulenceEnergy));
    sootOpticsOut[idx] = fminf(10.0f, fmaxf(0.0f, sootOptics));
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) forceVelocityKernel(
    float* uField,
    float* vField,
    float* wField,
    const float* heat,
    const float* soot,
    const float* turbulenceEnergy,
    const float* progress,
    SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = p.launchZStart + blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= p.nx || y >= p.ny || z >= p.launchZEnd || z >= p.nz) {
        return;
    }
    const int idx = scalarIndex(x, y, z, p);
    const float h = heat[idx];
    const float s = soot[idx];
    const float k = turbulenceEnergy[idx];
    const float c = progress[idx];
    const float u = (static_cast<float>(x) + 0.5f) / static_cast<float>(p.nx);
    const float v = (static_cast<float>(y) + 0.5f) / static_cast<float>(p.ny);
    const float w = (static_cast<float>(z) + 0.5f) / static_cast<float>(p.nz);
    const float cellX = 1.0f / static_cast<float>(p.nx);
    const float cellY = 1.0f / static_cast<float>(p.ny);
    const float cellZ = 1.0f / static_cast<float>(p.nz);
    const float3 velL = sampleVelocity(uField, vField, wField, p, u - cellX, v, w);
    const float3 velR = sampleVelocity(uField, vField, wField, p, u + cellX, v, w);
    const float3 velD = sampleVelocity(uField, vField, wField, p, u, v - cellY, w);
    const float3 velU = sampleVelocity(uField, vField, wField, p, u, v + cellY, w);
    const float3 velB = sampleVelocity(uField, vField, wField, p, u, v, w - cellZ);
    const float3 velF = sampleVelocity(uField, vField, wField, p, u, v, w + cellZ);
    const float gradX = sampleScalar(heat, p, u + cellX, v, w) - sampleScalar(heat, p, u - cellX, v, w);
    const float gradY = sampleScalar(heat, p, u, v + cellY, w) - sampleScalar(heat, p, u, v - cellY, w);
    const float gradZ = sampleScalar(heat, p, u, v, w + cellZ) - sampleScalar(heat, p, u, v, w - cellZ);
    const float curlX = (velU.z - velD.z) - (velF.y - velB.y);
    const float curlY = (velF.x - velB.x) - (velR.z - velL.z);
    const float curlZ = (velR.y - velL.y) - (velU.x - velD.x);
    const float curlMagnitude = sqrtf(curlX * curlX + curlY * curlY + curlZ * curlZ);
    const float curlNoiseA = fbm(make_float2(u * 9.0f + w * 3.7f + p.time * 0.22f, v * 13.0f - p.time * 0.31f)) - 0.5f;
    const float curlNoiseB = fbm(make_float2(w * 10.0f - p.time * 0.19f, u * 8.0f + v * 5.5f + p.time * 0.27f)) - 0.5f;
    const float thermalActivity = smoothstepf(0.04f, 4.20f, h + s * 0.28f);
    const float lesGain = sqrtf(fmaxf(0.0f, k)) * (0.30f + c * 0.54f);
    const float curlGain = p.turbulence * (0.18f + thermalActivity * 0.82f + lesGain * 1.12f);
    const float vortexGain = p.turbulence * thermalActivity * saturate(curlMagnitude * 0.46f) * 0.68f;
    const float buoyancy = h * (2.36f + p.turbulence * 0.42f + c * 0.20f) - s * 0.075f - gradY * 0.14f;

    atomicAdd(&vField[vIndex(x, y + 1, z, p)], p.dt * buoyancy);
    atomicAdd(&uField[uIndex(x, y, z, p)], p.dt * (p.wind * (0.34f + v * 0.96f) + (-gradZ * 1.62f + curlNoiseA * 0.18f + curlX * vortexGain) * curlGain));
    atomicAdd(&uField[uIndex(x + 1, y, z, p)], p.dt * (p.wind * (0.34f + v * 0.96f) + (-gradZ * 1.62f + curlNoiseA * 0.18f + curlX * vortexGain) * curlGain));
    atomicAdd(&wField[wIndex(x, y, z, p)], p.dt * ((gradX * 1.62f + curlNoiseB * 0.18f + curlZ * vortexGain) * curlGain));
    atomicAdd(&wField[wIndex(x, y, z + 1, p)], p.dt * ((gradX * 1.62f + curlNoiseB * 0.18f + curlZ * vortexGain) * curlGain));
    atomicAdd(&vField[vIndex(x, y + 1, z, p)], p.dt * curlY * vortexGain * 0.22f);
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) divergenceKernel(float* divergence, float* pressure, const float* uField, const float* vField, const float* wField, SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = p.launchZStart + blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= p.nx || y >= p.ny || z >= p.launchZEnd || z >= p.nz) {
        return;
    }
    const float div =
        uField[uIndex(x + 1, y, z, p)] - uField[uIndex(x, y, z, p)] +
        vField[vIndex(x, y + 1, z, p)] - vField[vIndex(x, y, z, p)] +
        wField[wIndex(x, y, z + 1, p)] - wField[wIndex(x, y, z, p)];
    const int idx = scalarIndex(x, y, z, p);
    divergence[idx] = -div;
    pressure[idx] = 0.0f;
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) sorPressureKernel(float* pressure, const float* divergence, SimParams p, int parity, float omega) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = p.launchZStart + blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= p.nx || y >= p.ny || z >= p.launchZEnd || z >= p.nz) {
        return;
    }
    if (((x + y + z) & 1) != parity) {
        return;
    }
    const int idx = scalarIndex(x, y, z, p);
    const float pL = pressure[scalarIndex(x - 1, y, z, p)];
    const float pR = pressure[scalarIndex(x + 1, y, z, p)];
    const float pD = pressure[scalarIndex(x, y - 1, z, p)];
    const float pU = pressure[scalarIndex(x, y + 1, z, p)];
    const float pB = pressure[scalarIndex(x, y, z - 1, p)];
    const float pF = pressure[scalarIndex(x, y, z + 1, p)];
    const float projected = (divergence[idx] + pL + pR + pD + pU + pB + pF) * (1.0f / 6.0f);
    pressure[idx] = pressure[idx] + omega * (projected - pressure[idx]);
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) subtractPressureKernel(float* uField, float* vField, float* wField, const float* pressure, SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = p.launchZStart + blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= p.nx || y >= p.ny || z >= p.launchZEnd || z >= p.nz) {
        return;
    }
    if (x > 0) {
        uField[uIndex(x, y, z, p)] -= pressure[scalarIndex(x, y, z, p)] - pressure[scalarIndex(x - 1, y, z, p)];
    }
    if (y > 0) {
        vField[vIndex(x, y, z, p)] -= pressure[scalarIndex(x, y, z, p)] - pressure[scalarIndex(x, y - 1, z, p)];
    }
    if (z > 0) {
        wField[wIndex(x, y, z, p)] -= pressure[scalarIndex(x, y, z, p)] - pressure[scalarIndex(x, y, z - 1, p)];
    }
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) divergenceOnlyKernel(float* divergence, const float* uField, const float* vField, const float* wField, SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = p.launchZStart + blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= p.nx || y >= p.ny || z >= p.launchZEnd || z >= p.nz) {
        return;
    }
    const float div =
        uField[uIndex(x + 1, y, z, p)] - uField[uIndex(x, y, z, p)] +
        vField[vIndex(x, y + 1, z, p)] - vField[vIndex(x, y, z, p)] +
        wField[wIndex(x, y, z + 1, p)] - wField[wIndex(x, y, z, p)];
    divergence[scalarIndex(x, y, z, p)] = -div;
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) velocityBoundaryKernel(float* uField, float* vField, float* wField, SimParams p) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    const int maxCount = max(max((p.nx + 1) * p.ny * p.nz, p.nx * (p.ny + 1) * p.nz), p.nx * p.ny * (p.nz + 1));
    if (i >= maxCount) {
        return;
    }
    if (i < (p.nx + 1) * p.ny * p.nz) {
        const int x = i % (p.nx + 1);
        if (x == 0 || x == p.nx) {
            uField[i] = 0.0f;
        } else {
            uField[i] = fminf(4.0f, fmaxf(-4.0f, uField[i]));
        }
    }
    if (i < p.nx * (p.ny + 1) * p.nz) {
        const int y = (i / p.nx) % (p.ny + 1);
        if (y == 0) {
            vField[i] = 0.0f;
        } else {
            vField[i] = fminf(6.4f, fmaxf(-0.9f, vField[i]));
        }
    }
    if (i < p.nx * p.ny * (p.nz + 1)) {
        const int z = i / (p.nx * p.ny);
        if (z == 0 || z == p.nz) {
            wField[i] = 0.0f;
        } else {
            wField[i] = fminf(4.0f, fmaxf(-4.0f, wField[i]));
        }
    }
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) velocityWallBoundaryKernel(float* uField, float* vField, float* wField, SimParams p) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    const int maxCount = max(max((p.nx + 1) * p.ny * p.nz, p.nx * (p.ny + 1) * p.nz), p.nx * p.ny * (p.nz + 1));
    if (i >= maxCount) {
        return;
    }
    if (i < (p.nx + 1) * p.ny * p.nz) {
        const int x = i % (p.nx + 1);
        if (x == 0 || x == p.nx) {
            uField[i] = 0.0f;
        }
    }
    if (i < p.nx * (p.ny + 1) * p.nz) {
        const int y = (i / p.nx) % (p.ny + 1);
        if (y == 0) {
            vField[i] = 0.0f;
        }
    }
    if (i < p.nx * p.ny * (p.nz + 1)) {
        const int z = i / (p.nx * p.ny);
        if (z == 0 || z == p.nz) {
            wField[i] = 0.0f;
        }
    }
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) accumulateMetricsKernel(
    MetricAccumulator* metrics,
    const float* heatField,
    const float* fuelField,
    const float* oxygenField,
    const float* sootField,
    const float* charField,
    const float* ashField,
    const float* pyrolysisField,
    const float* progressField,
    const float* turbulenceEnergyField,
    const float* sootOpticsField,
    const float* divergenceBefore,
    const float* divergenceAfter,
    SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = p.launchZStart + blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= p.nx || y >= p.ny || z >= p.launchZEnd || z >= p.nz) {
        return;
    }

    const int idx = scalarIndex(x, y, z, p);
    const float heat = heatField[idx];
    const float fuel = fuelField[idx];
    const float oxygen = oxygenField[idx];
    const float soot = sootField[idx];
    const float charMass = charField[idx];
    const float ash = ashField[idx];
    const float pyrolysis = pyrolysisField[idx];
    const float progress = progressField[idx];
    const float turbulenceEnergy = turbulenceEnergyField[idx];
    const float sootOptics = sootOpticsField[idx];
    const float divBefore = fabsf(divergenceBefore[idx]);
    const float divAfter = fabsf(divergenceAfter[idx]);

    if (!isfinite(heat) || !isfinite(fuel) || !isfinite(oxygen) || !isfinite(soot) || !isfinite(charMass) ||
        !isfinite(ash) || !isfinite(pyrolysis) || !isfinite(progress) || !isfinite(turbulenceEnergy) ||
        !isfinite(sootOptics) || !isfinite(divBefore) || !isfinite(divAfter)) {
        atomicAdd(&metrics->invalidCells, 1);
        return;
    }

    const float tempK = 293.0f + heat * 335.0f;
    const float hrr = (fuel + pyrolysis * 0.42f) * oxygen * smoothstepf(610.0f, 1280.0f, tempK) * expf(-5200.0f / fmaxf(650.0f, tempK));
    const float opticalDepth = sootOptics + soot * (0.24f + 0.05f * sqrtf(fmaxf(0.0f, heat)));
    const float normalizedHeight = (static_cast<float>(y) + 0.5f) / static_cast<float>(p.ny);
    const float flameMarker = heat + fuel * 0.24f + progress * 0.55f;

    atomicAdd(&metrics->heatSum, static_cast<double>(heat));
    atomicAdd(&metrics->fuelSum, static_cast<double>(fuel));
    atomicAdd(&metrics->oxygenSum, static_cast<double>(oxygen));
    atomicAdd(&metrics->sootSum, static_cast<double>(soot));
    atomicAdd(&metrics->charSum, static_cast<double>(charMass));
    atomicAdd(&metrics->ashSum, static_cast<double>(ash));
    atomicAdd(&metrics->pyrolysisSum, static_cast<double>(pyrolysis));
    atomicAdd(&metrics->progressSum, static_cast<double>(progress));
    atomicAdd(&metrics->turbulenceEnergySum, static_cast<double>(turbulenceEnergy));
    atomicAdd(&metrics->sootOpticalDepthSum, static_cast<double>(sootOptics));
    atomicAdd(&metrics->opticalDepthSum, static_cast<double>(opticalDepth));
    atomicAdd(&metrics->heatReleaseProxy, static_cast<double>(hrr));
    atomicAdd(&metrics->divergenceBeforeSq, static_cast<double>(divBefore) * static_cast<double>(divBefore));
    atomicAdd(&metrics->divergenceAfterSq, static_cast<double>(divAfter) * static_cast<double>(divAfter));

    atomicMaxPositiveFloat(&metrics->maxHeatBits, heat);
    atomicMaxPositiveFloat(&metrics->maxFuelBits, fuel);
    atomicMaxPositiveFloat(&metrics->maxSootBits, soot);
    atomicMaxPositiveFloat(&metrics->maxPyrolysisBits, pyrolysis);
    atomicMaxPositiveFloat(&metrics->maxProgressBits, progress);
    atomicMaxPositiveFloat(&metrics->maxTurbulenceEnergyBits, turbulenceEnergy);
    atomicMaxPositiveFloat(&metrics->divergenceBeforeMaxBits, divBefore);
    atomicMaxPositiveFloat(&metrics->divergenceAfterMaxBits, divAfter);
    if (flameMarker > 0.74f) {
        atomicMaxPositiveFloat(&metrics->flameHeightBits, normalizedHeight * kRoomHeightMeters);
    }
}

__device__ float3 blackbodyColor(float tempK) {
    const float t = fmaxf(1000.0f, fminf(12000.0f, tempK)) / 100.0f;
    float r = 0.0f;
    float g = 0.0f;
    float b = 0.0f;

    if (t <= 66.0f) {
        r = 1.0f;
        g = saturate((99.4708025861f * logf(t) - 161.1195681661f) / 255.0f);
    } else {
        r = saturate(329.698727446f * powf(t - 60.0f, -0.1332047592f) / 255.0f);
        g = saturate(288.1221695283f * powf(t - 60.0f, -0.0755148492f) / 255.0f);
    }

    if (t >= 66.0f) {
        b = 1.0f;
    } else if (t <= 19.0f) {
        b = 0.0f;
    } else {
        b = saturate((138.5177312231f * logf(t - 10.0f) - 305.0447927307f) / 255.0f);
    }

    return make_float3(r, g, b);
}

__device__ float floorGrid(float x, float z, float scale, float width) {
    const float gx = fabsf(fracf(x * scale + 0.5f) - 0.5f);
    const float gz = fabsf(fracf(z * scale + 0.5f) - 0.5f);
    return smoothstepf(width, 0.0f, fminf(gx, gz));
}

__device__ float rectMask(float2 p, float2 center, float2 halfSize, float feather) {
    const float2 d = make_float2(fabsf(p.x - center.x) - halfSize.x, fabsf(p.y - center.y) - halfSize.y);
    const float outside = fmaxf(d.x, d.y);
    return smoothstepf(feather, -feather, outside);
}

__device__ float lineMask(float2 p, float2 a, float2 b, float thickness) {
    const float2 pa = sub2(p, a);
    const float2 ba = sub2(b, a);
    const float h = saturate(dot2(pa, ba) / fmaxf(0.000001f, dot2(ba, ba)));
    const float2 d = sub2(pa, mul2(ba, h));
    return smoothstepf(thickness, thickness * 0.25f, sqrtf(dot2(d, d)));
}

__device__ float3 roomBackgroundRay(const CameraState& cam, float2 uv, float3 rd, float glow, const SimParams& p) {
    const float roomHalf = 2.55f;
    const float ceilingY = 2.18f;
    const bool cinematic = p.cinematicMode != 0;
    float bestT = 1.0e6f;
    float3 hit = make_float3(0.0f, 0.0f, 0.0f);
    int surface = 0;

    if (rd.y < -0.0001f) {
        const float t = -cam.eye.y / rd.y;
        const float3 p = add3(cam.eye, mul3(rd, t));
        if (t > 0.0f && fabsf(p.x) <= roomHalf && fabsf(p.z) <= roomHalf && t < bestT) {
            bestT = t;
            hit = p;
            surface = 1;
        }
    }
    if (rd.y > 0.0001f) {
        const float t = (ceilingY - cam.eye.y) / rd.y;
        const float3 p = add3(cam.eye, mul3(rd, t));
        if (t > 0.0f && fabsf(p.x) <= roomHalf && fabsf(p.z) <= roomHalf && t < bestT) {
            bestT = t;
            hit = p;
            surface = 2;
        }
    }
    if (fabsf(rd.x) > 0.0001f) {
        const float planeX = rd.x > 0.0f ? roomHalf : -roomHalf;
        const float t = (planeX - cam.eye.x) / rd.x;
        const float3 p = add3(cam.eye, mul3(rd, t));
        if (t > 0.0f && p.y >= 0.0f && p.y <= ceilingY && fabsf(p.z) <= roomHalf && t < bestT) {
            bestT = t;
            hit = p;
            surface = 3;
        }
    }
    if (fabsf(rd.z) > 0.0001f) {
        const float planeZ = rd.z > 0.0f ? roomHalf : -roomHalf;
        const float t = (planeZ - cam.eye.z) / rd.z;
        const float3 p = add3(cam.eye, mul3(rd, t));
        if (t > 0.0f && p.y >= 0.0f && p.y <= ceilingY && fabsf(p.x) <= roomHalf && t < bestT) {
            bestT = t;
            hit = p;
            surface = 4;
        }
    }

    float3 color = make_float3(0.062f, 0.062f, 0.061f);
    if (surface == 1) {
        const float marble = fbm(make_float2(hit.x * 8.5f + hit.z * 1.3f, hit.z * 7.0f - hit.x * 0.8f));
        color = cinematic ? make_float3(0.050f, 0.050f, 0.049f) : make_float3(0.046f, 0.046f, 0.045f);
        color = add3(color, mul3(make_float3(0.045f, 0.045f, 0.044f), (marble - 0.5f) * 0.13f));

        const float trayBody = rectMask(make_float2(hit.x, hit.z), make_float2(0.0f, 0.0f), make_float2(1.08f, 0.58f), 0.022f);
        const float trayInner = rectMask(make_float2(hit.x, hit.z), make_float2(0.0f, 0.0f), make_float2(0.96f, 0.47f), 0.020f);
        const float trayRim = saturate(trayBody - trayInner * 0.74f);
        const float emberBed = trayInner * expf(-(hit.x * hit.x * 0.74f + hit.z * hit.z * 2.20f));
        color = lerp3(color, make_float3(0.017f, 0.014f, 0.012f), trayBody * 0.82f);
        color = add3(color, mul3(make_float3(0.085f, 0.019f, 0.004f), emberBed * glow * 0.24f));
        color = add3(color, mul3(make_float3(0.30f, 0.28f, 0.24f), trayRim * 0.10f));

        const float reflectCore = expf(-(hit.x * hit.x * 2.45f + (hit.z + 0.18f) * (hit.z + 0.18f) * 1.95f)) * glow;
        const float reflectedTongues = smoothstepf(0.82f, 0.00f, fabsf(hit.x)) * smoothstepf(1.18f, 0.00f, fabsf(hit.z + 0.72f));
        const float streaks = floorGrid(hit.x + fbm(make_float2(hit.z * 2.0f, hit.x * 1.2f)) * 0.08f, hit.z, 14.0f, 0.012f);
        color = add3(color, mul3(make_float3(0.82f, 0.15f, 0.026f), reflectCore * p.reflectionGain * 0.070f));
        color = add3(color, mul3(make_float3(0.62f, 0.095f, 0.016f), reflectedTongues * streaks * glow * p.reflectionGain * 0.038f));
    } else if (surface == 2) {
        color = cinematic ? make_float3(0.042f, 0.042f, 0.041f) : make_float3(0.038f, 0.038f, 0.038f);
        const float panelA = lineMask(make_float2(hit.x, hit.z), make_float2(-1.2f, -2.0f), make_float2(-1.2f, 2.0f), 0.010f);
        const float panelB = lineMask(make_float2(hit.x, hit.z), make_float2(0.0f, -2.0f), make_float2(0.0f, 2.0f), 0.008f);
        const float fixtureL = expf(-((hit.x + 1.50f) * (hit.x + 1.50f) + (hit.z - 0.92f) * (hit.z - 0.92f)) * 120.0f);
        const float fixtureR = expf(-((hit.x - 1.72f) * (hit.x - 1.72f) + (hit.z - 0.80f) * (hit.z - 0.80f)) * 120.0f);
        color = add3(color, mul3(make_float3(0.16f, 0.155f, 0.145f), (panelA + panelB) * 0.10f));
        color = add3(color, mul3(make_float3(0.46f, 0.39f, 0.30f), (fixtureL + fixtureR) * 0.18f));
    } else {
        color = cinematic ? make_float3(0.058f, 0.058f, 0.056f) : color;
        const float soot = expf(-(hit.x * hit.x * 0.82f + hit.z * hit.z * 1.12f)) * smoothstepf(0.36f, 1.92f, hit.y);
        color = lerp3(color, make_float3(0.010f, 0.011f, 0.012f), soot * 0.82f * p.smokeDarkness);
        const float wallGlow = expf(-(hit.x * hit.x * 1.1f + hit.z * hit.z * 1.3f + (hit.y - 0.70f) * (hit.y - 0.70f) * 1.0f)) * glow;
        color = add3(color, mul3(make_float3(0.22f, 0.075f, 0.024f), wallGlow * 0.020f));
        if (surface == 3 && hit.x < 0.0f) {
            const float window = rectMask(make_float2(hit.z, hit.y), make_float2(-1.28f, 0.92f), make_float2(0.06f, 0.62f), 0.030f);
            const float glassNoise = fbm(make_float2(hit.y * 11.0f, hit.z * 8.0f));
            color = lerp3(color, make_float3(0.009f, 0.011f, 0.012f), window * 0.92f);
            color = add3(color, mul3(make_float3(0.10f, 0.12f, 0.13f), window * glassNoise * 0.16f));
        }
    }

    const float grain = (fbm(make_float2(hit.x * 12.0f + hit.z * 9.0f + p.time * 0.02f, hit.y * 8.0f + hit.z * 3.0f)) - 0.5f) * 0.014f;
    color = add3(color, make_float3(grain, grain, grain));
    const float fog = smoothstepf(3.8f, 0.2f, bestT);
    const float vignette = smoothstepf(0.78f, 0.20f, sqrtf((uv.x - 0.50f) * (uv.x - 0.50f) + (uv.y - 0.46f) * (uv.y - 0.46f)));
    return mul3(color, (0.34f + fog * 0.66f) * (0.76f + vignette * 0.24f));
}

__device__ bool intersectBox(float3 ro, float3 rd, float3 bmin, float3 bmax, float* outNear, float* outFar) {
    float tNear = 0.0f;
    float tFar = 1.0e6f;
    const float3 inv = make_float3(
        1.0f / (fabsf(rd.x) < 0.00001f ? copysignf(0.00001f, rd.x) : rd.x),
        1.0f / (fabsf(rd.y) < 0.00001f ? copysignf(0.00001f, rd.y) : rd.y),
        1.0f / (fabsf(rd.z) < 0.00001f ? copysignf(0.00001f, rd.z) : rd.z));

    float t0 = (bmin.x - ro.x) * inv.x;
    float t1 = (bmax.x - ro.x) * inv.x;
    if (t0 > t1) {
        const float tmp = t0;
        t0 = t1;
        t1 = tmp;
    }
    tNear = fmaxf(tNear, t0);
    tFar = fminf(tFar, t1);

    t0 = (bmin.y - ro.y) * inv.y;
    t1 = (bmax.y - ro.y) * inv.y;
    if (t0 > t1) {
        const float tmp = t0;
        t0 = t1;
        t1 = tmp;
    }
    tNear = fmaxf(tNear, t0);
    tFar = fminf(tFar, t1);

    t0 = (bmin.z - ro.z) * inv.z;
    t1 = (bmax.z - ro.z) * inv.z;
    if (t0 > t1) {
        const float tmp = t0;
        t0 = t1;
        t1 = tmp;
    }
    tNear = fmaxf(tNear, t0);
    tFar = fminf(tFar, t1);
    *outNear = tNear;
    *outFar = tFar;
    return tFar > tNear;
}

__device__ float lineAlpha(float2 p, float2 a, float2 b, float thickness) {
    const float2 pa = sub2(p, a);
    const float2 ba = sub2(b, a);
    const float h = saturate(dot2(pa, ba) / fmaxf(0.000001f, dot2(ba, ba)));
    const float2 d = sub2(pa, mul2(ba, h));
    return smoothstepf(thickness, thickness * 0.35f, sqrtf(dot2(d, d)));
}

__device__ float ringAlpha(float2 p, float2 c, float radius, float thickness) {
    const float2 d = sub2(p, c);
    return smoothstepf(thickness, thickness * 0.25f, fabsf(sqrtf(dot2(d, d)) - radius));
}

__device__ float diskAlpha(float2 p, float2 c, float radius) {
    const float2 d = sub2(p, c);
    return smoothstepf(radius, radius * 0.45f, sqrtf(dot2(d, d)));
}

__device__ void blendGizmo(float3* color, float3 gizmoColor, float alpha) {
    *color = lerp3(*color, gizmoColor, saturate(alpha));
}

__device__ void drawGizmos(float3* color, float2 uv, const CameraState& cam, const SimParams& p) {
    if (p.showGizmos == 0) {
        return;
    }
    const float3 source = projectPoint(cam, make_float3(0.0f, 0.055f, 0.0f));
    if (source.z > 0.0f) {
        const float2 c = make_float2(source.x, source.y);
        const float a = ringAlpha(uv, c, 0.125f / source.z, 0.006f) + diskAlpha(uv, c, 0.012f);
        blendGizmo(color, p.activeGizmo == 1 ? make_float3(1.0f, 0.34f, 0.055f) : make_float3(0.45f, 0.18f, 0.055f), a * 0.85f);
    }
    const float2 axisBase = make_float2(0.90f, 0.84f);
    const float2 xAxis = add2(axisBase, mul2(make_float2(dot3(make_float3(1.0f, 0.0f, 0.0f), cam.right), -dot3(make_float3(1.0f, 0.0f, 0.0f), cam.up)), 0.070f));
    const float2 yAxis = add2(axisBase, mul2(make_float2(dot3(make_float3(0.0f, 1.0f, 0.0f), cam.right), -dot3(make_float3(0.0f, 1.0f, 0.0f), cam.up)), 0.070f));
    const float2 zAxis = add2(axisBase, mul2(make_float2(dot3(make_float3(0.0f, 0.0f, 1.0f), cam.right), -dot3(make_float3(0.0f, 0.0f, 1.0f), cam.up)), 0.070f));
    blendGizmo(color, make_float3(1.0f, 0.12f, 0.08f), lineAlpha(uv, axisBase, xAxis, 0.005f));
    blendGizmo(color, make_float3(0.22f, 1.0f, 0.30f), lineAlpha(uv, axisBase, yAxis, 0.005f));
    blendGizmo(color, make_float3(0.20f, 0.48f, 1.0f), lineAlpha(uv, axisBase, zAxis, 0.005f));
}

__device__ float volumeShadow(const float* sootOpticsField, const float* progressField, const SimParams& p, float u, float v, float w) {
    float tau = 0.0f;
    for (int i = 0; i < 8; ++i) {
        const float s = static_cast<float>(i + 1) / 8.0f;
        const float su = saturate(u + 0.10f * s);
        const float sv = saturate(v + 0.22f * s);
        const float sw = saturate(w - 0.06f * s);
        const float sootOptics = sampleScalar(sootOpticsField, p, su, sv, sw);
        const float progress = sampleScalar(progressField, p, su, sv, sw);
        tau += sootOptics * 0.31f + progress * 0.052f;
    }
    return expf(-tau);
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) renderKernel(
    float4* out,
    const float* heatField,
    const float* fuelField,
    const float* oxygenField,
    const float* sootField,
    const float* charField,
    const float* ashField,
    const float* pyrolysisField,
    const float* progressField,
    const float* turbulenceEnergyField,
    const float* sootOpticsField,
    const float* uField,
    const float* vField,
    const float* wField,
    SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = p.launchFrameYStart + blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.frameW || y >= p.launchFrameYEnd || y >= p.frameH) {
        return;
    }

    const float2 uv = make_float2(
        (static_cast<float>(x) + 0.5f) / static_cast<float>(p.frameW),
        (static_cast<float>(y) + 0.5f) / static_cast<float>(p.frameH));
    const CameraState cam = makeCamera(p);
    const float3 rd = cameraRayDirection(cam, uv);
    const float baseGlow = saturate(sampleScalar(heatField, p, 0.50f, 0.06f, 0.50f) * 0.42f);
    float3 color = roomBackgroundRay(cam, uv, rd, baseGlow, p);

    float boxNear = 0.0f;
    float boxFar = 0.0f;
    float3 accum = make_float3(0.0f, 0.0f, 0.0f);
    float trans = 1.0f;
    float flameGlow = 0.0f;
    float smokeOcclusion = 0.0f;
    float debugFlame = 0.0f;
    float debugOpticalDepth = 0.0f;
    float debugTemperature = 0.0f;
    float debugFuel = 0.0f;
    float debugVelocity = 0.0f;

    if (intersectBox(cam.eye, rd, make_float3(-1.05f, 0.02f, -0.82f), make_float3(1.05f, 2.05f, 0.82f), &boxNear, &boxFar)) {
        const int raySteps = min(max(p.raymarchSteps, 24), kMaxRaymarchSteps);
        const float t0 = fmaxf(0.0f, boxNear);
        const float t1 = fminf(boxFar, t0 + 3.05f);
        const float stepT = (t1 - t0) / static_cast<float>(raySteps);
        const float rayJitter = hash21(make_float2(
            (static_cast<float>(x) + 0.5f) * 0.754877f,
            (static_cast<float>(y) + 0.5f) * 0.569840f));

        for (int i = 0; i < kMaxRaymarchSteps && i < raySteps && trans > 0.018f; ++i) {
            const float t = t0 + (static_cast<float>(i) + rayJitter) * stepT;
            const float3 wp = add3(cam.eye, mul3(rd, t));
            const float fu = saturate((wp.x + 1.05f) / 2.10f);
            const float fv = saturate((wp.y - 0.02f) / 2.03f);
            const float fw = saturate((wp.z + 0.82f) / 1.64f);
            const float domainFade = volumeDomainFade(fu, fv, fw);
            if (domainFade <= 0.001f) {
                continue;
            }

            const float warpA = fbm3(make_float3(fu * 7.0f + p.time * 0.18f, fv * 5.0f - p.time * 0.11f, fw * 9.0f + p.time * 0.07f)) - 0.5f;
            const float warpB = fbm3(make_float3(fw * 8.0f - p.time * 0.14f, fu * 8.0f + p.time * 0.10f, fv * 6.0f - p.time * 0.08f)) - 0.5f;
            const float warpGain = 0.028f + fv * 0.060f;
            const float warpedFu = saturate(fu + warpA * warpGain);
            const float warpedFv = saturate(fv + (warpA - warpB) * 0.020f);
            const float warpedFw = saturate(fw + warpB * warpGain);

            const float heat = sampleScalar(heatField, p, warpedFu, warpedFv, warpedFw);
            const float fuel = sampleScalar(fuelField, p, warpedFu, warpedFv, warpedFw);
            const float oxygen = sampleScalar(oxygenField, p, warpedFu, warpedFv, warpedFw);
            const float soot = sampleScalar(sootField, p, warpedFu, warpedFv, warpedFw);
            const float charMass = sampleScalar(charField, p, warpedFu, warpedFv, warpedFw);
            const float ash = sampleScalar(ashField, p, warpedFu, warpedFv, warpedFw);
            const float pyrolysis = sampleScalar(pyrolysisField, p, warpedFu, warpedFv, warpedFw);
            const float progress = sampleScalar(progressField, p, warpedFu, warpedFv, warpedFw);
            const float turbulenceEnergy = sampleScalar(turbulenceEnergyField, p, warpedFu, warpedFv, warpedFw);
            const float sootOptics = sampleScalar(sootOpticsField, p, warpedFu, warpedFv, warpedFw);
            const float3 velocity = sampleVelocity(uField, vField, wField, p, warpedFu, warpedFv, warpedFw);
            const float activeField = (heat + fuel * 0.42f + soot * 0.34f + progress * 0.32f + pyrolysis * 0.18f) * domainFade;
            if (activeField <= 0.0025f) {
                continue;
            }
            debugFuel = fmaxf(debugFuel, domainFade * saturate(fuel * 0.18f + charMass * 0.22f + pyrolysis * 0.30f));
            debugVelocity = fmaxf(debugVelocity, saturate(sqrtf(dot3(velocity, velocity)) * 0.22f));
            const float cellX = 1.0f / static_cast<float>(p.nx);
            const float cellY = 1.0f / static_cast<float>(p.ny);
            const float cellZ = 1.0f / static_cast<float>(p.nz);
            const float gradHeatX = sampleScalar(heatField, p, warpedFu + cellX, warpedFv, warpedFw) - sampleScalar(heatField, p, warpedFu - cellX, warpedFv, warpedFw);
            const float gradHeatY = sampleScalar(heatField, p, warpedFu, warpedFv + cellY, warpedFw) - sampleScalar(heatField, p, warpedFu, warpedFv - cellY, warpedFw);
            const float gradHeatZ = sampleScalar(heatField, p, warpedFu, warpedFv, warpedFw + cellZ) - sampleScalar(heatField, p, warpedFu, warpedFv, warpedFw - cellZ);
            const float gradFuelX = sampleScalar(fuelField, p, warpedFu + cellX, warpedFv, warpedFw) - sampleScalar(fuelField, p, warpedFu - cellX, warpedFv, warpedFw);
            const float gradFuelY = sampleScalar(fuelField, p, warpedFu, warpedFv + cellY, warpedFw) - sampleScalar(fuelField, p, warpedFu, warpedFv - cellY, warpedFw);
            const float gradFuelZ = sampleScalar(fuelField, p, warpedFu, warpedFv, warpedFw + cellZ) - sampleScalar(fuelField, p, warpedFu, warpedFv, warpedFw - cellZ);
            const float frontGradient =
                sqrtf(gradHeatX * gradHeatX + gradHeatY * gradHeatY + gradHeatZ * gradHeatZ) +
                sqrtf(gradFuelX * gradFuelX + gradFuelY * gradFuelY + gradFuelZ * gradFuelZ) * 0.32f;
            const float reactionFront = smoothstepf(0.020f, 0.46f, frontGradient * 1.35f + fuel * oxygen * 0.040f + progress * 0.18f + pyrolysis * 0.080f);

            const float fineNoise = fbm3(make_float3(warpedFu * 42.0f + p.time * 0.72f, warpedFv * 54.0f - p.time * 1.28f, warpedFw * 43.0f + p.time * 0.38f));
            const float shearNoise = fbm3(make_float3(warpedFu * 15.0f - p.time * 0.72f, warpedFv * 13.0f - p.time * 1.08f, warpedFw * 17.0f + p.time * 0.32f));
            const float plumeNoise = fbm3(make_float3(warpedFu * 18.0f - p.time * 0.20f, warpedFv * 12.0f + p.time * 0.12f, warpedFw * 20.0f + p.time * 0.16f));
            const float holeNoise = fbm3(make_float3(warpedFu * 63.0f - p.time * 1.18f, warpedFv * 47.0f + p.time * 0.72f, warpedFw * 57.0f - p.time * 0.92f));
            const float lesBreakup = saturate(turbulenceEnergy * 0.48f + progress * 0.28f);
            const float raggedEdge =
                smoothstepf(0.18f, 0.92f, fineNoise * (0.46f + lesBreakup * 0.30f) + shearNoise * 0.38f + plumeNoise * 0.32f + saturate(activeField * 0.08f));
            const float fieldEdge = smoothstepf(0.05f, 2.30f, heat + fuel * 0.32f) * (0.10f + reactionFront * 0.90f);
            const float fieldFilament =
                smoothstepf(0.60f, 1.0f, fineNoise + lesBreakup * 0.10f) *
                smoothstepf(0.38f, 0.92f, shearNoise + (0.72f - fv) * 0.12f + reactionFront * 0.10f) *
                smoothstepf(1.0f, 0.02f, fv) *
                fieldEdge;
            const float convectiveSheet = smoothstepf(0.36f, 0.84f, shearNoise + heat * 0.046f + plumeNoise * 0.18f + lesBreakup * 0.12f) * smoothstepf(0.96f, 0.035f, fv) * fieldEdge;
            const float breakup = smoothstepf(0.34f, 0.88f, fineNoise * 0.48f + shearNoise * 0.42f + holeNoise * 0.24f + heat * 0.026f);
            const float verticalFade = smoothstepf(0.96f, 0.025f, fv);
            const float lowerWhite = smoothstepf(0.060f, 0.00f, fv) * smoothstepf(0.05f, 1.30f, pyrolysis + fuel * 0.20f);
            const float tempK = 293.0f + heat * 390.0f + fuel * 48.0f + pyrolysis * 110.0f + fieldFilament * 980.0f + convectiveSheet * 740.0f + lowerWhite * 190.0f + progress * 80.0f;
            const float combustion =
                smoothstepf(760.0f, 1690.0f, tempK) *
                smoothstepf(0.016f, 0.62f, fuel + heat * 0.055f) *
                smoothstepf(0.045f, 0.62f, oxygen) *
                verticalFade;
            const float sheetHole = smoothstepf(0.60f, 0.93f, holeNoise + lesBreakup * 0.18f + saturate(1.0f - oxygen) * 0.10f);
            const float flameSheet = fmaxf(
                smoothstepf(0.55f, 0.94f, fineNoise * 0.46f + shearNoise * 0.44f + plumeNoise * 0.18f + reactionFront * 0.15f + heat * 0.014f - fv * 0.050f) *
                    (1.0f - sheetHole * (0.56f + lesBreakup * 0.28f)),
                smoothstepf(0.30f, 0.035f, fv) * smoothstepf(0.55f, 1.9f, heat) * 0.12f);
            const float thinFront = smoothstepf(0.04f, 0.56f, frontGradient + progress * 0.10f) * smoothstepf(0.02f, 0.92f, reactionFront);
            const float flameDensity = domainFade *
                combustion * reactionFront * flameSheet * (0.010f + fieldFilament * 2.05f + convectiveSheet * 1.45f + thinFront * 0.55f + progress * 0.10f) *
                (0.055f + breakup * 1.20f + raggedEdge * 0.50f + lesBreakup * 0.44f) *
                (0.62f + thinFront * 1.55f);
            const float plumeVoid = smoothstepf(0.54f, 0.90f, holeNoise + fineNoise * 0.26f + shearNoise * 0.22f + fv * 0.20f);
            const float topDissolve = smoothstepf(0.94f, 0.48f, fv);
            const float raggedPlume = 1.0f - plumeVoid * smoothstepf(0.20f, 0.86f, fv) * 0.88f;
            const float upperPlume =
                smoothstepf(0.14f, 0.48f, fv) *
                smoothstepf(0.030f, 1.20f, sootOptics + soot * 0.42f) *
                (0.06f + fineNoise * 0.070f + shearNoise * 0.060f + plumeNoise * 0.62f + raggedEdge * 0.18f + turbulenceEnergy * 0.06f) *
                topDissolve * raggedPlume;
            const float rawSootDensity = domainFade * (
                smoothstepf(0.020f, 1.05f, sootOptics + soot * 0.32f) *
                    smoothstepf(0.16f, 0.42f, fv) *
                    (0.028f + fineNoise * 0.040f + shearNoise * 0.052f + plumeNoise * 0.38f + raggedEdge * 0.16f + ash * 0.016f) +
                upperPlume * (0.16f + plumeNoise * 0.22f) + smoothstepf(0.004f, 0.34f, sootOptics) * (0.018f + plumeNoise * 0.030f));
            const float emissiveMask = saturate(combustion * reactionFront * (0.35f + flameSheet * 0.65f) + flameDensity * 2.4f);
            const float scatterSeparation = 1.0f - smoothstepf(0.04f, 0.44f, emissiveMask) * 0.88f;
            const float nearFlameSootCleanout = 1.0f - smoothstepf(0.12f, 0.72f, emissiveMask) * 0.34f;
            const float absorptionDensity = rawSootDensity * nearFlameSootCleanout * (0.94f + (1.0f - scatterSeparation) * 0.10f);
            const float scatterDensity = rawSootDensity * scatterSeparation * smoothstepf(0.10f, 0.55f, fv + sootOptics * 0.10f);

            const float particleRadius = saturate(0.08f + sootOptics * 0.028f + ash * 0.085f + saturate(1.0f - oxygen) * 0.12f);
            const float sootAbsorption = absorptionDensity * (2.36f + particleRadius * 3.70f + sootOptics * 0.52f) * p.smokeDarkness;
            const float sootScattering = scatterDensity * (0.045f + (1.0f - particleRadius) * 0.15f) * (0.34f + p.smokeGain * 0.18f);
            const float sootExtinction = sootAbsorption + sootScattering;
            const float flameExtinction = flameDensity * 0.24f;
            const float extinction = (sootExtinction + flameExtinction) * stepT;
            const float smokeAlpha = 1.0f - expf(-sootAbsorption * stepT);
            const float scatterAlpha = 1.0f - expf(-sootScattering * stepT);
            const float shadow = volumeShadow(sootOpticsField, progressField, p, warpedFu, warpedFv, warpedFw);
            const float sootLoad = saturate(sootOptics * 0.74f + soot * 0.20f + upperPlume * 0.46f);
            const float whiteCore =
                smoothstepf(2250.0f, 3250.0f, tempK) *
                combustion *
                smoothstepf(0.32f, 0.90f, oxygen) *
                (0.10f + thinFront * 0.36f + fieldFilament * 0.30f) *
                (1.0f - smoothstepf(0.16f, 0.74f, sootLoad) * 0.68f);
            const float radiantPower = powf(saturate((tempK - 800.0f) / 1960.0f), 2.18f) * (1.78f + fieldFilament * 3.55f + convectiveSheet * 1.90f + progress * 0.38f + whiteCore * 0.86f);
            const float whiteFilament = saturate(whiteCore * (0.045f + fieldFilament * 0.14f + thinFront * 0.11f));
            const float orangeEdge = (1.0f - whiteFilament * 0.72f) * thinFront * reactionFront * (0.40f + breakup * 0.82f) * smoothstepf(0.08f, 0.80f, oxygen);
            float3 flameColor = lerp3(blackbodyColor(tempK), make_float3(1.0f, 0.70f, 0.34f), saturate(whiteFilament * 0.070f));
            float3 flameEmission = mul3(flameColor, flameDensity * radiantPower * stepT * (1.16f + shadow * 0.90f + whiteCore * 0.42f));
            flameEmission = add3(flameEmission, mul3(make_float3(1.04f, 0.94f, 0.76f), whiteFilament * whiteFilament * flameDensity * radiantPower * stepT * (0.18f + shadow * 0.13f)));
            flameEmission = add3(flameEmission, mul3(make_float3(1.34f, 0.17f, 0.025f), orangeEdge * heat * stepT * (0.18f + shadow * 0.12f)));
            flameEmission = add3(flameEmission, mul3(make_float3(1.12f, 0.090f, 0.010f), fieldFilament * heat * stepT * (0.10f + shadow * 0.070f) * (1.0f - whiteCore * 0.46f)));
            const float ashVeil = saturate(ash * 0.045f + smoothstepf(0.24f, 0.86f, fv) * (1.0f - sootLoad) * 0.012f);
            const float3 smokeBlack = make_float3(0.0018f, 0.0020f, 0.0024f);
            const float3 smokeCoal = make_float3(0.011f, 0.0118f, 0.0135f);
            const float3 smokeAsh = make_float3(0.046f, 0.049f, 0.054f);
            float3 smokeColor = lerp3(smokeCoal, smokeBlack, sootLoad);
            smokeColor = lerp3(smokeColor, smokeAsh, ashVeil);
            const float backScatter = scatterAlpha * shadow * baseGlow * (0.0016f + flameDensity * 0.0007f) * (0.020f + (1.0f - particleRadius) * 0.030f) * scatterSeparation;
            smokeColor = add3(smokeColor, mul3(make_float3(0.036f, 0.038f, 0.042f), backScatter));
            const float scatterGain = scatterAlpha * (0.0035f + shadow * 0.0080f + flameDensity * 0.0012f + turbulenceEnergy * 0.0014f) * (0.10f + (1.0f - particleRadius) * 0.16f) * scatterSeparation;
            const float coalGlow = smoothstepf(0.004f, 0.18f, charMass) * smoothstepf(0.64f, 0.02f, fv) * (0.13f + pyrolysis * 0.30f + heat * 0.018f);

            debugFlame = fmaxf(debugFlame, saturate(flameDensity * radiantPower * 0.26f));
            debugOpticalDepth = saturate(debugOpticalDepth + sootExtinction * stepT);
            debugTemperature = fmaxf(debugTemperature, saturate((tempK - 520.0f) / 1900.0f));
            accum = add3(accum, mul3(flameEmission, trans));
            accum = add3(accum, mul3(make_float3(1.0f, 0.24f, 0.035f), trans * coalGlow * stepT));
            accum = add3(accum, mul3(smokeColor, trans * scatterGain));
            flameGlow = fmaxf(flameGlow, flameDensity * radiantPower * (0.12f + fieldFilament * 0.18f + whiteFilament * 0.20f));
            smokeOcclusion = saturate(smokeOcclusion + smokeAlpha * trans);
            trans *= expf(-extinction);
        }
    }

    if (p.renderDebugMode != 0) {
        float3 debugColor = make_float3(0.0f, 0.0f, 0.0f);
        if (p.renderDebugMode == 1) {
            debugColor = debugHeatColor(debugFlame);
        } else if (p.renderDebugMode == 2) {
            const float od = saturate(debugOpticalDepth);
            debugColor = make_float3(od, od * 0.90f, od * 0.78f);
        } else if (p.renderDebugMode == 3) {
            debugColor = make_float3(trans, trans, trans);
        } else if (p.renderDebugMode == 4) {
            debugColor = debugHeatColor(debugTemperature);
        } else if (p.renderDebugMode == 5) {
            debugColor = make_float3(debugFuel * 0.82f, debugFuel * 0.48f, debugFuel * 0.18f);
        } else {
            debugColor = make_float3(debugVelocity * 0.20f, debugVelocity * 0.72f, debugVelocity);
        }
        out[y * p.frameW + x] = make_float4(debugColor.x, debugColor.y, debugColor.z, 1.0f);
        return;
    }

    color = add3(mul3(color, trans), accum);

    const float bloom = saturate(flameGlow * 0.10f) * (1.0f - saturate(smokeOcclusion * 0.95f));
    color = add3(color, mul3(make_float3(1.0f, 0.25f, 0.045f), bloom * bloom * 0.017f * p.reflectionGain));
    out[y * p.frameW + x] = make_float4(
        fmaxf(0.0f, color.x),
        fmaxf(0.0f, color.y),
        fmaxf(0.0f, color.z),
        1.0f);
}

__device__ float acesToneCurve(float value) {
    const float a = 2.51f;
    const float b = 0.03f;
    const float c = 2.43f;
    const float d = 0.59f;
    const float e = 0.14f;
    return saturate((value * (a * value + b)) / (value * (c * value + d) + e));
}

__device__ float3 acesToneMapPreserveHue(float3 color) {
    const float luma = fmaxf(0.000001f, luminance3(color));
    const float mappedLuma = acesToneCurve(luma);
    return mul3(color, mappedLuma / luma);
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) tonemapKernel(
    std::uint32_t* out,
    const float4* hdr,
    SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = p.launchFrameYStart + blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.frameW || y >= p.launchFrameYEnd || y >= p.frameH) {
        return;
    }

    const int pixelIndex = y * p.frameW + x;
    const float4 radiance = hdr[pixelIndex];
    float3 color = make_float3(radiance.x, radiance.y, radiance.z);
    const float exposure = p.exposure;
    color = acesToneMapPreserveHue(mul3(color, exposure));
    color = make_float3(
        powf(saturate(color.x), 1.0f / 2.2f),
        powf(saturate(color.y), 1.0f / 2.2f),
        powf(saturate(color.z), 1.0f / 2.2f));

    const float dither = (hash21(make_float2(static_cast<float>(x) * 0.754877f, static_cast<float>(y) * 0.569840f)) - 0.5f) / 255.0f;
    color = add3(color, make_float3(dither, dither, dither));
    const std::uint32_t r = static_cast<std::uint32_t>(saturate(color.x) * 255.0f);
    const std::uint32_t g = static_cast<std::uint32_t>(saturate(color.y) * 255.0f);
    const std::uint32_t b = static_cast<std::uint32_t>(saturate(color.z) * 255.0f);
    out[pixelIndex] = 0xff000000u | (r << 16) | (g << 8) | b;
}

__device__ unsigned short halfBits(float value) {
    return __half_as_ushort(__float2half_rn(fmaxf(0.0f, value)));
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) packFp16Kernel(
    ushort4* out,
    const float4* hdr,
    SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = p.launchFrameYStart + blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.frameW || y >= p.launchFrameYEnd || y >= p.frameH) {
        return;
    }

    const int pixelIndex = y * p.frameW + x;
    const float4 radiance = hdr[pixelIndex];
    out[pixelIndex] = make_ushort4(
        halfBits(radiance.x),
        halfBits(radiance.y),
        halfBits(radiance.z),
        halfBits(1.0f));
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) emberHdrKernel(
    float4* hdr,
    const float* heatField,
    SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = p.launchFrameYStart + blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.frameW || y >= p.launchFrameYEnd || y >= p.frameH || p.renderDebugMode != 0) {
        return;
    }

    const int emberCount = min(max(p.emberCount, 0), kMaxEmberCount);
    if (emberCount <= 0) {
        return;
    }

    const int pixelIndex = y * p.frameW + x;
    float4 radiance = hdr[pixelIndex];
    float3 color = make_float3(radiance.x, radiance.y, radiance.z);
    const float2 uv = make_float2(
        (static_cast<float>(x) + 0.5f) / static_cast<float>(p.frameW),
        (static_cast<float>(y) + 0.5f) / static_cast<float>(p.frameH));
    const CameraState cam = makeCamera(p);
    const float baseGlow = saturate(sampleScalar(heatField, p, 0.50f, 0.06f, 0.50f) * 0.42f);
    const float sparkGate = smoothstepf(0.02f, 0.30f, baseGlow);

    for (int i = 0; i < kMaxEmberCount && i < emberCount; ++i) {
        const float seed = static_cast<float>(i);
        const float h0 = hash21(make_float2(seed, 3.7f));
        const float h1 = hash21(make_float2(seed, 9.1f));
        const float h2 = hash21(make_float2(seed, 19.4f));
        const float h3 = hash21(make_float2(seed, 31.6f));
        const float life = fracf(p.time * (0.42f + h2 * 0.34f) + h0);
        const float t = life * 1.42f;
        const float3 sparkWorld = make_float3(
            (h0 - 0.5f) * 1.10f + ((h1 - 0.5f) * 0.38f + p.wind * 0.58f) * t,
            0.04f + (0.92f + h3 * 1.42f) * t - 0.30f * t * t,
            (h1 - 0.5f) * 0.72f + (h2 - 0.5f) * 0.34f * t);
        const float3 sparkScreen = projectPoint(cam, sparkWorld);
        if (sparkScreen.z > 0.0f && sparkScreen.x > -0.05f && sparkScreen.x < 1.05f && sparkScreen.y > -0.05f && sparkScreen.y < 1.05f) {
            const float2 d = sub2(uv, make_float2(sparkScreen.x, sparkScreen.y));
            const float radius = (0.0015f + h3 * 0.0021f) / fmaxf(0.55f, sparkScreen.z);
            const float spark = expf(-dot2(d, d) / fmaxf(0.0000002f, radius * radius)) * smoothstepf(1.0f, 0.10f, life) * sparkGate;
            color = add3(color, mul3(lerp3(make_float3(1.0f, 0.42f, 0.08f), make_float3(0.62f, 0.10f, 0.025f), life), spark * 1.20f));
        }
    }

    hdr[pixelIndex] = make_float4(color.x, color.y, color.z, radiance.w);
}

__device__ float3 unpackBgra(std::uint32_t pixel) {
    return make_float3(
        static_cast<float>((pixel >> 16) & 0xff) / 255.0f,
        static_cast<float>((pixel >> 8) & 0xff) / 255.0f,
        static_cast<float>(pixel & 0xff) / 255.0f);
}

__device__ std::uint32_t packBgra(float3 color) {
    const std::uint32_t r = static_cast<std::uint32_t>(saturate(color.x) * 255.0f);
    const std::uint32_t g = static_cast<std::uint32_t>(saturate(color.y) * 255.0f);
    const std::uint32_t b = static_cast<std::uint32_t>(saturate(color.z) * 255.0f);
    return 0xff000000u | (r << 16) | (g << 8) | b;
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) overlayKernel(
    std::uint32_t* frame,
    const float* heatField,
    SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = p.launchFrameYStart + blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.frameW || y >= p.launchFrameYEnd || y >= p.frameH) {
        return;
    }
    if (p.renderDebugMode != 0) {
        return;
    }
    if (p.showGizmos == 0 && p.emberCount <= 0) {
        return;
    }

    const int pixelIndex = y * p.frameW + x;
    float3 color = unpackBgra(frame[pixelIndex]);
    const float2 uv = make_float2(
        (static_cast<float>(x) + 0.5f) / static_cast<float>(p.frameW),
        (static_cast<float>(y) + 0.5f) / static_cast<float>(p.frameH));
    const CameraState cam = makeCamera(p);
    const float baseGlow = saturate(sampleScalar(heatField, p, 0.50f, 0.06f, 0.50f) * 0.42f);

    const int emberCount = min(max(p.emberCount, 0), kMaxEmberCount);
    const float sparkGate = smoothstepf(0.02f, 0.30f, baseGlow);
    for (int i = 0; i < kMaxEmberCount && i < emberCount; ++i) {
        const float seed = static_cast<float>(i);
        const float h0 = hash21(make_float2(seed, 3.7f));
        const float h1 = hash21(make_float2(seed, 9.1f));
        const float h2 = hash21(make_float2(seed, 19.4f));
        const float h3 = hash21(make_float2(seed, 31.6f));
        const float life = fracf(p.time * (0.42f + h2 * 0.34f) + h0);
        const float t = life * 1.42f;
        const float3 sparkWorld = make_float3(
            (h0 - 0.5f) * 1.10f + ((h1 - 0.5f) * 0.38f + p.wind * 0.58f) * t,
            0.04f + (0.92f + h3 * 1.42f) * t - 0.30f * t * t,
            (h1 - 0.5f) * 0.72f + (h2 - 0.5f) * 0.34f * t);
        const float3 sparkScreen = projectPoint(cam, sparkWorld);
        if (sparkScreen.z > 0.0f && sparkScreen.x > -0.05f && sparkScreen.x < 1.05f && sparkScreen.y > -0.05f && sparkScreen.y < 1.05f) {
            const float2 d = sub2(uv, make_float2(sparkScreen.x, sparkScreen.y));
            const float radius = (0.0015f + h3 * 0.0021f) / fmaxf(0.55f, sparkScreen.z);
            const float spark = expf(-dot2(d, d) / fmaxf(0.0000002f, radius * radius)) * smoothstepf(1.0f, 0.10f, life) * sparkGate;
            color = add3(color, mul3(lerp3(make_float3(1.0f, 0.42f, 0.08f), make_float3(0.62f, 0.10f, 0.025f), life), spark * 0.76f));
        }
    }

    drawGizmos(&color, uv, cam, p);
    frame[pixelIndex] = packBgra(color);
}

void freeDeviceMemory() {
    if (g_d3dFp16Resource != nullptr) {
        cudaGraphicsUnregisterResource(g_d3dFp16Resource);
        g_d3dFp16Resource = nullptr;
    }
    cudaFree(g_heat);
    cudaFree(g_heatNext);
    cudaFree(g_fuel);
    cudaFree(g_fuelNext);
    cudaFree(g_oxygen);
    cudaFree(g_oxygenNext);
    cudaFree(g_soot);
    cudaFree(g_sootNext);
    cudaFree(g_char);
    cudaFree(g_charNext);
    cudaFree(g_ash);
    cudaFree(g_ashNext);
    cudaFree(g_pyrolysis);
    cudaFree(g_pyrolysisNext);
    cudaFree(g_progress);
    cudaFree(g_progressNext);
    cudaFree(g_turbulenceEnergy);
    cudaFree(g_turbulenceEnergyNext);
    cudaFree(g_sootOptics);
    cudaFree(g_sootOpticsNext);
    cudaFree(g_pressure);
    cudaFree(g_pressureNext);
    cudaFree(g_divergence);
    cudaFree(g_divergenceAfter);
    cudaFree(g_u);
    cudaFree(g_uNext);
    cudaFree(g_v);
    cudaFree(g_vNext);
    cudaFree(g_w);
    cudaFree(g_wNext);
    cudaFree(g_metricsDevice);
    cudaFree(g_frameDevice);
    cudaFree(g_hdrFrameDevice);
    cudaFree(g_fp16FrameDevice);
    if (g_stepStartEvent != nullptr) {
        cudaEventDestroy(g_stepStartEvent);
    }
    if (g_afterSolveEvent != nullptr) {
        cudaEventDestroy(g_afterSolveEvent);
    }
    if (g_afterRenderEvent != nullptr) {
        cudaEventDestroy(g_afterRenderEvent);
    }
    g_heat = nullptr;
    g_heatNext = nullptr;
    g_fuel = nullptr;
    g_fuelNext = nullptr;
    g_oxygen = nullptr;
    g_oxygenNext = nullptr;
    g_soot = nullptr;
    g_sootNext = nullptr;
    g_char = nullptr;
    g_charNext = nullptr;
    g_ash = nullptr;
    g_ashNext = nullptr;
    g_pyrolysis = nullptr;
    g_pyrolysisNext = nullptr;
    g_progress = nullptr;
    g_progressNext = nullptr;
    g_turbulenceEnergy = nullptr;
    g_turbulenceEnergyNext = nullptr;
    g_sootOptics = nullptr;
    g_sootOpticsNext = nullptr;
    g_pressure = nullptr;
    g_pressureNext = nullptr;
    g_divergence = nullptr;
    g_divergenceAfter = nullptr;
    g_u = nullptr;
    g_uNext = nullptr;
    g_v = nullptr;
    g_vNext = nullptr;
    g_w = nullptr;
    g_wNext = nullptr;
    g_metricsDevice = nullptr;
    g_frameDevice = nullptr;
    g_hdrFrameDevice = nullptr;
    g_fp16FrameDevice = nullptr;
    g_stepStartEvent = nullptr;
    g_afterSolveEvent = nullptr;
    g_afterRenderEvent = nullptr;
}

SimParams makeParams(float dt = 1.0f / 60.0f) {
    SimParams params = {};
    params.nx = g_nx;
    params.ny = g_ny;
    params.nz = g_nz;
    params.frameW = g_frameW;
    params.frameH = g_frameH;
    params.dt = dt;
    params.time = g_time;
    params.mouseX = 0.5f;
    params.mouseY = 0.12f;
    params.turbulence = 0.72f;
    params.detail = 0.88f;
    params.smokeGain = 0.92f;
    params.intensity = 1.0f;
    params.cameraPitch = 0.18f;
    params.cameraDistance = 3.35f;
    params.cinematicMode = 1;
    params.raymarchSteps = 56;
    params.emberCount = 96;
    params.renderDebugMode = 0;
    params.exposure = 1.0f;
    params.reflectionGain = 1.0f;
    params.smokeDarkness = 1.0f;
    params.launchZStart = 0;
    params.launchZEnd = g_nz;
    params.launchFrameYStart = 0;
    params.launchFrameYEnd = g_frameH;
    return params;
}

SimParams withVolumeWindow(SimParams params, int zStart, int zEnd) {
    params.launchZStart = zStart;
    params.launchZEnd = zEnd;
    return params;
}

SimParams withFrameWindow(SimParams params, int yStart, int yEnd) {
    params.launchFrameYStart = yStart;
    params.launchFrameYEnd = yEnd;
    return params;
}

dim3 gridFor3d(int xCount, int yCount, int zCount, dim3 block) {
    return dim3(
        (xCount + block.x - 1) / block.x,
        (yCount + block.y - 1) / block.y,
        (zCount + block.z - 1) / block.z);
}

dim3 gridForFrameRows(int width, int rowCount, dim3 block) {
    return dim3(
        (width + block.x - 1) / block.x,
        (rowCount + block.y - 1) / block.y);
}

} // namespace

bool fireCudaInitialize(int frameWidth, int frameHeight, int gridWidth, int gridHeight) {
    fireCudaShutdown();
    g_frameW = frameWidth;
    g_frameH = frameHeight;
    const bool highQualityRequest = gridWidth >= 320 || gridHeight >= 220;
    g_nx = clampHost(gridWidth / 2, 72, highQualityRequest ? 176 : 104);
    g_ny = clampHost(gridHeight - 32, 80, highQualityRequest ? 208 : 112);
    g_nz = clampHost(gridWidth / 3, 48, highQualityRequest ? 132 : 72);
    g_time = 0.0f;
    g_frameIndex = 0;
    std::strcpy(g_lastError, "No CUDA error.");

    const std::size_t scalarCount = static_cast<std::size_t>(g_nx) * static_cast<std::size_t>(g_ny) * static_cast<std::size_t>(g_nz);
    const std::size_t uCount = static_cast<std::size_t>(g_nx + 1) * static_cast<std::size_t>(g_ny) * static_cast<std::size_t>(g_nz);
    const std::size_t vCount = static_cast<std::size_t>(g_nx) * static_cast<std::size_t>(g_ny + 1) * static_cast<std::size_t>(g_nz);
    const std::size_t wCount = static_cast<std::size_t>(g_nx) * static_cast<std::size_t>(g_ny) * static_cast<std::size_t>(g_nz + 1);
    const std::size_t scalarBytes = scalarCount * sizeof(float);
    const std::size_t uBytes = uCount * sizeof(float);
    const std::size_t vBytes = vCount * sizeof(float);
    const std::size_t wBytes = wCount * sizeof(float);
    const std::size_t frameBytes = static_cast<std::size_t>(frameWidth) * static_cast<std::size_t>(frameHeight) * sizeof(std::uint32_t);
    const std::size_t hdrFrameBytes = static_cast<std::size_t>(frameWidth) * static_cast<std::size_t>(frameHeight) * sizeof(float4);
    const std::size_t fp16FrameBytes = static_cast<std::size_t>(frameWidth) * static_cast<std::size_t>(frameHeight) * sizeof(ushort4);

    if (!check("cudaSetDevice", cudaSetDevice(0))) {
        return false;
    }
    if (!check("cudaMalloc heat", cudaMalloc(&g_heat, scalarBytes)) ||
        !check("cudaMalloc heatNext", cudaMalloc(&g_heatNext, scalarBytes)) ||
        !check("cudaMalloc fuel", cudaMalloc(&g_fuel, scalarBytes)) ||
        !check("cudaMalloc fuelNext", cudaMalloc(&g_fuelNext, scalarBytes)) ||
        !check("cudaMalloc oxygen", cudaMalloc(&g_oxygen, scalarBytes)) ||
        !check("cudaMalloc oxygenNext", cudaMalloc(&g_oxygenNext, scalarBytes)) ||
        !check("cudaMalloc soot", cudaMalloc(&g_soot, scalarBytes)) ||
        !check("cudaMalloc sootNext", cudaMalloc(&g_sootNext, scalarBytes)) ||
        !check("cudaMalloc char", cudaMalloc(&g_char, scalarBytes)) ||
        !check("cudaMalloc charNext", cudaMalloc(&g_charNext, scalarBytes)) ||
        !check("cudaMalloc ash", cudaMalloc(&g_ash, scalarBytes)) ||
        !check("cudaMalloc ashNext", cudaMalloc(&g_ashNext, scalarBytes)) ||
        !check("cudaMalloc pyrolysis", cudaMalloc(&g_pyrolysis, scalarBytes)) ||
        !check("cudaMalloc pyrolysisNext", cudaMalloc(&g_pyrolysisNext, scalarBytes)) ||
        !check("cudaMalloc progress", cudaMalloc(&g_progress, scalarBytes)) ||
        !check("cudaMalloc progressNext", cudaMalloc(&g_progressNext, scalarBytes)) ||
        !check("cudaMalloc turbulenceEnergy", cudaMalloc(&g_turbulenceEnergy, scalarBytes)) ||
        !check("cudaMalloc turbulenceEnergyNext", cudaMalloc(&g_turbulenceEnergyNext, scalarBytes)) ||
        !check("cudaMalloc sootOptics", cudaMalloc(&g_sootOptics, scalarBytes)) ||
        !check("cudaMalloc sootOpticsNext", cudaMalloc(&g_sootOpticsNext, scalarBytes)) ||
        !check("cudaMalloc pressure", cudaMalloc(&g_pressure, scalarBytes)) ||
        !check("cudaMalloc pressureNext", cudaMalloc(&g_pressureNext, scalarBytes)) ||
        !check("cudaMalloc divergence", cudaMalloc(&g_divergence, scalarBytes)) ||
        !check("cudaMalloc divergenceAfter", cudaMalloc(&g_divergenceAfter, scalarBytes)) ||
        !check("cudaMalloc u", cudaMalloc(&g_u, uBytes)) ||
        !check("cudaMalloc uNext", cudaMalloc(&g_uNext, uBytes)) ||
        !check("cudaMalloc v", cudaMalloc(&g_v, vBytes)) ||
        !check("cudaMalloc vNext", cudaMalloc(&g_vNext, vBytes)) ||
        !check("cudaMalloc w", cudaMalloc(&g_w, wBytes)) ||
        !check("cudaMalloc wNext", cudaMalloc(&g_wNext, wBytes)) ||
        !check("cudaMalloc metrics", cudaMalloc(&g_metricsDevice, sizeof(MetricAccumulator))) ||
        !check("cudaMalloc frame", cudaMalloc(&g_frameDevice, frameBytes)) ||
        !check("cudaMalloc hdr frame", cudaMalloc(&g_hdrFrameDevice, hdrFrameBytes)) ||
        !check("cudaMalloc fp16 frame", cudaMalloc(&g_fp16FrameDevice, fp16FrameBytes))) {
        freeDeviceMemory();
        return false;
    }
    if (!check("cudaEventCreate stepStart", cudaEventCreate(&g_stepStartEvent)) ||
        !check("cudaEventCreate afterSolve", cudaEventCreate(&g_afterSolveEvent)) ||
        !check("cudaEventCreate afterRender", cudaEventCreate(&g_afterRenderEvent))) {
        freeDeviceMemory();
        return false;
    }

    return fireCudaReset();
}

bool fireCudaReset() {
    if (g_heat == nullptr) {
        std::snprintf(g_lastError, sizeof(g_lastError), "CUDA renderer is not initialized.");
        return false;
    }

    const SimParams params = makeParams();
    const dim3 scalarBlock(8, 8, 4);
    for (int zStart = 0; zStart < g_nz; zStart += kVolumeLaunchDepth) {
        const int zEnd = std::min(g_nz, zStart + kVolumeLaunchDepth);
        const SimParams slice = withVolumeWindow(params, zStart, zEnd);
        const dim3 scalarGrid = gridFor3d(g_nx, g_ny, zEnd - zStart, scalarBlock);
        const dim3 uGrid = gridFor3d(g_nx + 1, g_ny, zEnd - zStart, scalarBlock);
        const dim3 vGrid = gridFor3d(g_nx, g_ny + 1, zEnd - zStart, scalarBlock);

        resetScalarsKernel<<<scalarGrid, scalarBlock>>>(
            g_heat, g_fuel, g_oxygen, g_soot,
            g_char, g_ash, g_pyrolysis, g_progress, g_turbulenceEnergy, g_sootOptics,
            g_pressure, g_divergence, slice);
        resetScalarsKernel<<<scalarGrid, scalarBlock>>>(
            g_heatNext, g_fuelNext, g_oxygenNext, g_sootNext,
            g_charNext, g_ashNext, g_pyrolysisNext, g_progressNext, g_turbulenceEnergyNext, g_sootOpticsNext,
            g_pressureNext, g_divergenceAfter, slice);
        resetUKernel<<<uGrid, scalarBlock>>>(g_u, slice);
        resetUKernel<<<uGrid, scalarBlock>>>(g_uNext, slice);
        resetVKernel<<<vGrid, scalarBlock>>>(g_v, slice);
        resetVKernel<<<vGrid, scalarBlock>>>(g_vNext, slice);
    }
    for (int zStart = 0; zStart < g_nz + 1; zStart += kVolumeLaunchDepth) {
        const int zEnd = std::min(g_nz + 1, zStart + kVolumeLaunchDepth);
        const SimParams slice = withVolumeWindow(params, zStart, zEnd);
        const dim3 wGrid = gridFor3d(g_nx, g_ny, zEnd - zStart, scalarBlock);
        resetWKernel<<<wGrid, scalarBlock>>>(g_w, slice);
        resetWKernel<<<wGrid, scalarBlock>>>(g_wNext, slice);
    }
    if (!check("reset kernels launch", cudaGetLastError())) {
        return false;
    }
    return check("reset kernels sync", cudaDeviceSynchronize());
}

bool fireCudaGetDiagnostics(FireCudaDiagnostics* diagnostics) {
    if (diagnostics == nullptr) {
        std::snprintf(g_lastError, sizeof(g_lastError), "Diagnostics output pointer was null.");
        return false;
    }

    FireCudaDiagnostics out = {};
    if (!check("cudaDriverGetVersion", cudaDriverGetVersion(&out.driverVersion))) {
        return false;
    }
    if (!check("cudaRuntimeGetVersion", cudaRuntimeGetVersion(&out.runtimeVersion))) {
        return false;
    }
    if (!check("cudaGetDeviceCount", cudaGetDeviceCount(&out.deviceCount))) {
        return false;
    }
    if (out.deviceCount <= 0) {
        std::snprintf(g_lastError, sizeof(g_lastError), "No CUDA-capable device was found.");
        return false;
    }
    if (out.deviceCount > 0) {
        int device = 0;
        if (!check("cudaGetDevice", cudaGetDevice(&device))) {
            return false;
        }
        cudaDeviceProp props = {};
        if (!check("cudaGetDeviceProperties", cudaGetDeviceProperties(&props, device))) {
            return false;
        }
        out.activeDevice = device;
        out.computeMajor = props.major;
        out.computeMinor = props.minor;
        out.totalGlobalMem = static_cast<std::uint64_t>(props.totalGlobalMem);
        std::snprintf(out.deviceName, sizeof(out.deviceName), "%s", props.name);
    }

    *diagnostics = out;
    return true;
}

bool stepAndRenderInternal(std::uint32_t* bgraPixels, const FireSettings& settings, FireCudaFrameMetrics* metrics, bool writeD3DInterop) {
    if (g_heat == nullptr || g_frameDevice == nullptr || g_hdrFrameDevice == nullptr || g_fp16FrameDevice == nullptr) {
        std::snprintf(g_lastError, sizeof(g_lastError), "CUDA renderer is not initialized.");
        return false;
    }
    if (!writeD3DInterop && bgraPixels == nullptr) {
        std::snprintf(g_lastError, sizeof(g_lastError), "Output pixel pointer was null.");
        return false;
    }
    if (writeD3DInterop && g_d3dFp16Resource == nullptr) {
        std::snprintf(g_lastError, sizeof(g_lastError), "D3D11 FP16 interop texture is not registered.");
        return false;
    }

    const bool collectMetrics = metrics != nullptr;
    const float stepDt = std::max(0.001f, std::min(settings.dt, 1.0f / 30.0f));
    g_time += stepDt;

    SimParams params = makeParams(stepDt);
    params.time = g_time;
    params.mouseX = std::max(0.0f, std::min(1.0f, settings.mouseX));
    params.mouseY = std::max(0.0f, std::min(1.0f, settings.mouseY));
    params.leftDown = settings.leftDown;
    params.rightDown = settings.rightDown;
    params.showGizmos = settings.showGizmos;
    params.activeGizmo = settings.activeGizmo;
    params.wind = std::max(-1.0f, std::min(1.0f, settings.wind));
    params.turbulence = std::max(0.05f, std::min(1.8f, settings.turbulence));
    params.detail = std::max(0.1f, std::min(1.5f, settings.detail));
    params.smokeGain = std::max(0.0f, std::min(1.6f, settings.smoke));
    params.intensity = std::max(0.2f, std::min(2.4f, settings.intensity));
    params.cameraYaw = settings.cameraYaw;
    params.cameraPitch = std::max(-0.75f, std::min(0.75f, settings.cameraPitch));
    params.cameraDistance = std::max(1.5f, std::min(6.0f, settings.cameraDistance));
    params.cinematicMode = settings.cinematicMode != 0 ? 1 : 0;
    params.raymarchSteps = std::max(24, std::min(kMaxRaymarchSteps, settings.raymarchSteps));
    params.emberCount = std::max(0, std::min(kMaxEmberCount, settings.emberCount));
    params.renderDebugMode = std::max(0, std::min(6, settings.renderDebugMode));
    params.exposure = std::max(0.45f, std::min(2.40f, settings.exposure));
    params.reflectionGain = std::max(0.0f, std::min(2.2f, settings.reflectionGain));
    params.smokeDarkness = std::max(0.35f, std::min(2.4f, settings.smokeDarkness));

    if (settings.reset != 0 && !fireCudaReset()) {
        return false;
    }

    const dim3 fieldBlock(8, 8, 4);
    const dim3 scalarGrid((g_nx + fieldBlock.x - 1) / fieldBlock.x, (g_ny + fieldBlock.y - 1) / fieldBlock.y, (g_nz + fieldBlock.z - 1) / fieldBlock.z);

    if (collectMetrics && !check("cudaEventRecord step start", cudaEventRecord(g_stepStartEvent))) {
        return false;
    }

    for (int zStart = 0; zStart < g_nz; zStart += kVolumeLaunchDepth) {
        const int zEnd = std::min(g_nz, zStart + kVolumeLaunchDepth);
        const SimParams slice = withVolumeWindow(params, zStart, zEnd);
        advectUKernel<<<gridFor3d(g_nx + 1, g_ny, zEnd - zStart, fieldBlock), fieldBlock>>>(g_uNext, g_u, g_v, g_w, slice);
        advectVKernel<<<gridFor3d(g_nx, g_ny + 1, zEnd - zStart, fieldBlock), fieldBlock>>>(g_vNext, g_u, g_v, g_w, slice);
    }
    for (int zStart = 0; zStart < g_nz + 1; zStart += kVolumeLaunchDepth) {
        const int zEnd = std::min(g_nz + 1, zStart + kVolumeLaunchDepth);
        const SimParams slice = withVolumeWindow(params, zStart, zEnd);
        advectWKernel<<<gridFor3d(g_nx, g_ny, zEnd - zStart, fieldBlock), fieldBlock>>>(g_wNext, g_u, g_v, g_w, slice);
    }
    if (!check("velocity advection launch", cudaGetLastError())) {
        return false;
    }
    std::swap(g_u, g_uNext);
    std::swap(g_v, g_vNext);
    std::swap(g_w, g_wNext);

    for (int zStart = 0; zStart < g_nz; zStart += kVolumeLaunchDepth) {
        const int zEnd = std::min(g_nz, zStart + kVolumeLaunchDepth);
        const SimParams slice = withVolumeWindow(params, zStart, zEnd);
        advectReactKernel<<<gridFor3d(g_nx, g_ny, zEnd - zStart, fieldBlock), fieldBlock>>>(
            g_heatNext,
            g_fuelNext,
            g_oxygenNext,
            g_sootNext,
            g_charNext,
            g_ashNext,
            g_pyrolysisNext,
            g_progressNext,
            g_turbulenceEnergyNext,
            g_sootOpticsNext,
            g_heat,
            g_fuel,
            g_oxygen,
            g_soot,
            g_char,
            g_ash,
            g_pyrolysis,
            g_progress,
            g_turbulenceEnergy,
            g_sootOptics,
            g_u,
            g_v,
            g_w,
            slice);
    }
    if (!check("advect/react launch", cudaGetLastError())) {
        return false;
    }
    std::swap(g_heat, g_heatNext);
    std::swap(g_fuel, g_fuelNext);
    std::swap(g_oxygen, g_oxygenNext);
    std::swap(g_soot, g_sootNext);
    std::swap(g_char, g_charNext);
    std::swap(g_ash, g_ashNext);
    std::swap(g_pyrolysis, g_pyrolysisNext);
    std::swap(g_progress, g_progressNext);
    std::swap(g_turbulenceEnergy, g_turbulenceEnergyNext);
    std::swap(g_sootOptics, g_sootOpticsNext);

    for (int zStart = 0; zStart < g_nz; zStart += kVolumeLaunchDepth) {
        const int zEnd = std::min(g_nz, zStart + kVolumeLaunchDepth);
        const SimParams slice = withVolumeWindow(params, zStart, zEnd);
        forceVelocityKernel<<<gridFor3d(g_nx, g_ny, zEnd - zStart, fieldBlock), fieldBlock>>>(
            g_u, g_v, g_w, g_heat, g_soot, g_turbulenceEnergy, g_progress, slice);
    }
    if (!check("force velocity launch", cudaGetLastError())) {
        return false;
    }

    const int velocityMax = std::max(std::max((g_nx + 1) * g_ny * g_nz, g_nx * (g_ny + 1) * g_nz), g_nx * g_ny * (g_nz + 1));
    velocityBoundaryKernel<<<(velocityMax + 255) / 256, 256>>>(g_u, g_v, g_w, params);
    divergenceKernel<<<scalarGrid, fieldBlock>>>(g_divergence, g_pressure, g_u, g_v, g_w, params);
    if (!check("projection setup launch", cudaGetLastError())) {
        return false;
    }

    for (int i = 0; i < kPressureIterations; ++i) {
        sorPressureKernel<<<scalarGrid, fieldBlock>>>(g_pressure, g_divergence, params, 0, kPressureOmega);
        sorPressureKernel<<<scalarGrid, fieldBlock>>>(g_pressure, g_divergence, params, 1, kPressureOmega);
    }
    if (!check("pressure SOR launch", cudaGetLastError())) {
        return false;
    }
    subtractPressureKernel<<<scalarGrid, fieldBlock>>>(g_u, g_v, g_w, g_pressure, params);
    velocityWallBoundaryKernel<<<(velocityMax + 255) / 256, 256>>>(g_u, g_v, g_w, params);
    if (!check("pressure subtract launch", cudaGetLastError())) {
        return false;
    }
    if (collectMetrics) {
        divergenceOnlyKernel<<<scalarGrid, fieldBlock>>>(g_divergenceAfter, g_u, g_v, g_w, params);
        if (!check("post-projection divergence launch", cudaGetLastError())) {
            return false;
        }
        if (!check("cudaEventRecord after solve", cudaEventRecord(g_afterSolveEvent))) {
            return false;
        }
        if (!check("metrics reset", cudaMemset(g_metricsDevice, 0, sizeof(MetricAccumulator)))) {
            return false;
        }
        accumulateMetricsKernel<<<scalarGrid, fieldBlock>>>(
            g_metricsDevice,
            g_heat,
            g_fuel,
            g_oxygen,
            g_soot,
            g_char,
            g_ash,
            g_pyrolysis,
            g_progress,
            g_turbulenceEnergy,
            g_sootOptics,
            g_divergence,
            g_divergenceAfter,
            params);
        if (!check("metrics accumulation launch", cudaGetLastError())) {
            return false;
        }
    }

    const dim3 frameBlock(16, 16);
    for (int yStart = 0; yStart < g_frameH; yStart += kRenderLaunchRows) {
        const int yEnd = std::min(g_frameH, yStart + kRenderLaunchRows);
        const SimParams slice = withFrameWindow(params, yStart, yEnd);
        renderKernel<<<gridForFrameRows(g_frameW, yEnd - yStart, frameBlock), frameBlock>>>(
            g_hdrFrameDevice,
            g_heat,
            g_fuel,
            g_oxygen,
            g_soot,
            g_char,
            g_ash,
            g_pyrolysis,
            g_progress,
            g_turbulenceEnergy,
            g_sootOptics,
            g_u,
            g_v,
            g_w,
            slice);
    }
    if (!check("renderKernel launch", cudaGetLastError())) {
        return false;
    }
    if (writeD3DInterop) {
        for (int yStart = 0; yStart < g_frameH; yStart += kRenderLaunchRows) {
            const int yEnd = std::min(g_frameH, yStart + kRenderLaunchRows);
            const SimParams slice = withFrameWindow(params, yStart, yEnd);
            emberHdrKernel<<<gridForFrameRows(g_frameW, yEnd - yStart, frameBlock), frameBlock>>>(g_hdrFrameDevice, g_heat, slice);
        }
        if (!check("emberHdrKernel launch", cudaGetLastError())) {
            return false;
        }
        for (int yStart = 0; yStart < g_frameH; yStart += kRenderLaunchRows) {
            const int yEnd = std::min(g_frameH, yStart + kRenderLaunchRows);
            const SimParams slice = withFrameWindow(params, yStart, yEnd);
            packFp16Kernel<<<gridForFrameRows(g_frameW, yEnd - yStart, frameBlock), frameBlock>>>(g_fp16FrameDevice, g_hdrFrameDevice, slice);
        }
        if (!check("packFp16Kernel launch", cudaGetLastError())) {
            return false;
        }
        if (!check("cudaGraphicsMapResources d3d fp16", cudaGraphicsMapResources(1, &g_d3dFp16Resource, 0))) {
            return false;
        }
        cudaArray_t d3dArray = nullptr;
        bool copiedToD3D = check("cudaGraphicsSubResourceGetMappedArray d3d fp16", cudaGraphicsSubResourceGetMappedArray(&d3dArray, g_d3dFp16Resource, 0, 0));
        if (copiedToD3D) {
            const std::size_t pitch = static_cast<std::size_t>(g_frameW) * sizeof(ushort4);
            copiedToD3D = check(
                "cudaMemcpy2DToArray d3d fp16",
                cudaMemcpy2DToArray(d3dArray, 0, 0, g_fp16FrameDevice, pitch, pitch, static_cast<std::size_t>(g_frameH), cudaMemcpyDeviceToDevice));
        }
        const bool unmappedD3D = check("cudaGraphicsUnmapResources d3d fp16", cudaGraphicsUnmapResources(1, &g_d3dFp16Resource, 0));
        if (!copiedToD3D || !unmappedD3D) {
            return false;
        }
    } else {
        for (int yStart = 0; yStart < g_frameH; yStart += kRenderLaunchRows) {
            const int yEnd = std::min(g_frameH, yStart + kRenderLaunchRows);
            const SimParams slice = withFrameWindow(params, yStart, yEnd);
            tonemapKernel<<<gridForFrameRows(g_frameW, yEnd - yStart, frameBlock), frameBlock>>>(g_frameDevice, g_hdrFrameDevice, slice);
        }
        if (!check("tonemapKernel launch", cudaGetLastError())) {
            return false;
        }
        for (int yStart = 0; yStart < g_frameH; yStart += kRenderLaunchRows) {
            const int yEnd = std::min(g_frameH, yStart + kRenderLaunchRows);
            const SimParams slice = withFrameWindow(params, yStart, yEnd);
            overlayKernel<<<gridForFrameRows(g_frameW, yEnd - yStart, frameBlock), frameBlock>>>(g_frameDevice, g_heat, slice);
        }
        if (!check("overlayKernel launch", cudaGetLastError())) {
            return false;
        }
    }
    if (collectMetrics && !check("cudaEventRecord after render", cudaEventRecord(g_afterRenderEvent))) {
        return false;
    }

    if (!writeD3DInterop) {
        const std::size_t frameBytes = static_cast<std::size_t>(g_frameW) * static_cast<std::size_t>(g_frameH) * sizeof(std::uint32_t);
        if (!check("cudaMemcpy frame", cudaMemcpy(bgraPixels, g_frameDevice, frameBytes, cudaMemcpyDeviceToHost))) {
            return false;
        }
    }
    if (collectMetrics) {
        MetricAccumulator deviceMetrics = {};
        if (!check("cudaMemcpy metrics", cudaMemcpy(&deviceMetrics, g_metricsDevice, sizeof(deviceMetrics), cudaMemcpyDeviceToHost))) {
            return false;
        }
        float solveMs = 0.0f;
        float renderMs = 0.0f;
        if (!check("cudaEventElapsedTime solve", cudaEventElapsedTime(&solveMs, g_stepStartEvent, g_afterSolveEvent)) ||
            !check("cudaEventElapsedTime render", cudaEventElapsedTime(&renderMs, g_afterSolveEvent, g_afterRenderEvent))) {
            return false;
        }

        const double cellCount = static_cast<double>(g_nx) * static_cast<double>(g_ny) * static_cast<double>(g_nz);
        const float divBeforeL2 = static_cast<float>(std::sqrt(deviceMetrics.divergenceBeforeSq / std::max(1.0, cellCount)));
        const float divAfterL2 = static_cast<float>(std::sqrt(deviceMetrics.divergenceAfterSq / std::max(1.0, cellCount)));
        FireCudaFrameMetrics out = {};
        out.frameIndex = g_frameIndex;
        out.gridX = g_nx;
        out.gridY = g_ny;
        out.gridZ = g_nz;
        out.pressureIterations = kPressureIterations;
        out.invalidCells = deviceMetrics.invalidCells;
        out.timeSeconds = g_time;
        out.gpuSolveMs = solveMs;
        out.gpuRenderMs = renderMs;
        out.heatSum = static_cast<float>(deviceMetrics.heatSum);
        out.fuelSum = static_cast<float>(deviceMetrics.fuelSum);
        out.oxygenSum = static_cast<float>(deviceMetrics.oxygenSum);
        out.sootSum = static_cast<float>(deviceMetrics.sootSum);
        out.charSum = static_cast<float>(deviceMetrics.charSum);
        out.ashSum = static_cast<float>(deviceMetrics.ashSum);
        out.pyrolysisSum = static_cast<float>(deviceMetrics.pyrolysisSum);
        out.progressSum = static_cast<float>(deviceMetrics.progressSum);
        out.turbulenceEnergySum = static_cast<float>(deviceMetrics.turbulenceEnergySum);
        out.sootOpticalDepthSum = static_cast<float>(deviceMetrics.sootOpticalDepthSum);
        out.maxHeat = floatFromBits(deviceMetrics.maxHeatBits);
        out.maxFuel = floatFromBits(deviceMetrics.maxFuelBits);
        out.maxSoot = floatFromBits(deviceMetrics.maxSootBits);
        out.maxPyrolysis = floatFromBits(deviceMetrics.maxPyrolysisBits);
        out.maxProgress = floatFromBits(deviceMetrics.maxProgressBits);
        out.maxTurbulenceEnergy = floatFromBits(deviceMetrics.maxTurbulenceEnergyBits);
        out.flameHeightMeters = floatFromBits(deviceMetrics.flameHeightBits);
        out.meanOpticalDepth = static_cast<float>(deviceMetrics.opticalDepthSum / std::max(1.0, cellCount));
        out.heatReleaseProxy = static_cast<float>(deviceMetrics.heatReleaseProxy);
        out.divergenceBeforeL2 = divBeforeL2;
        out.divergenceBeforeMax = floatFromBits(deviceMetrics.divergenceBeforeMaxBits);
        out.divergenceAfterL2 = divAfterL2;
        out.divergenceAfterMax = floatFromBits(deviceMetrics.divergenceAfterMaxBits);
        out.divergenceReduction = divBeforeL2 > 0.000001f ? 1.0f - divAfterL2 / divBeforeL2 : 0.0f;
        *metrics = out;
    }
    ++g_frameIndex;
    return true;
}

bool fireCudaStepAndRender(std::uint32_t* bgraPixels, const FireSettings& settings) {
    return stepAndRenderInternal(bgraPixels, settings, nullptr, false);
}

bool fireCudaStepAndRenderMeasured(std::uint32_t* bgraPixels, const FireSettings& settings, FireCudaFrameMetrics* metrics) {
    if (metrics == nullptr) {
        std::snprintf(g_lastError, sizeof(g_lastError), "Metrics output pointer was null.");
        return false;
    }
    return stepAndRenderInternal(bgraPixels, settings, metrics, false);
}

bool fireCudaRegisterD3D11Texture(void* d3d11Texture) {
    if (d3d11Texture == nullptr) {
        std::snprintf(g_lastError, sizeof(g_lastError), "D3D11 texture pointer was null.");
        return false;
    }
    fireCudaUnregisterD3D11Texture();
    auto* resource = static_cast<ID3D11Resource*>(d3d11Texture);
    return check(
        "cudaGraphicsD3D11RegisterResource fp16 texture",
        cudaGraphicsD3D11RegisterResource(&g_d3dFp16Resource, resource, cudaGraphicsRegisterFlagsWriteDiscard));
}

bool fireCudaStepAndRenderD3D11(const FireSettings& settings) {
    return stepAndRenderInternal(nullptr, settings, nullptr, true);
}

void fireCudaUnregisterD3D11Texture() {
    if (g_d3dFp16Resource != nullptr) {
        cudaGraphicsUnregisterResource(g_d3dFp16Resource);
        g_d3dFp16Resource = nullptr;
    }
}

void fireCudaShutdown() {
    freeDeviceMemory();
    g_nx = 0;
    g_ny = 0;
    g_nz = 0;
    g_frameW = 0;
    g_frameH = 0;
    g_frameIndex = 0;
    g_time = 0.0f;
}

const char* fireCudaLastError() {
    return g_lastError;
}
