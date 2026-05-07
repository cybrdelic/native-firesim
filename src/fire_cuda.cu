#include "fire_cuda.h"

#include <cuda_runtime.h>
#include <cuda_d3d11_interop.h>
#include <cuda_fp16.h>
#include <surface_functions.h>
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
    int lightNx;
    int lightNy;
    int lightNz;
    float dt;
    float time;
    float mouseX;
    float mouseY;
    int leftDown;
    int rightDown;
    int showGizmos;
    int activeGizmo;
    int sceneId;
    float wind;
    float turbulence;
    float detail;
    float smokeGain;
    float intensity;
    float cameraYaw;
    float cameraPitch;
    float cameraDistance;
    float3 cameraEye;
    float3 cameraForward;
    float3 cameraRight;
    float3 cameraUp;
    float cameraTanHalfFov;
    float cameraAspect;
    int cinematicMode;
    int raymarchSteps;
    int emberCount;
    int renderDebugMode;
    float exposure;
    float reflectionGain;
    float smokeDarkness;
    float emitterCenterX;
    float emitterCenterZ;
    float emitterHeightNorm;
    float emitterHeightBandNorm;
    float emitterRadius;
    int burnerCenterCount;
    float burnerCenterX[4];
    float burnerCenterY[4];
    float burnerCenterZ[4];
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
    double sceneLightSum;
    double sceneShadowSum;
    double flameMassProxy;
    double smokeMassProxy;
    double flameSmokeOverlapProxy;
    double volumetricShadowSum;
    double roomIrradianceSum;
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
constexpr int kVolumeLaunchDepth = 256;
constexpr int kRenderLaunchRows = 1024;
constexpr int kRenderSnapshotSlots = 2;
constexpr int kSceneCount = 3;

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
float4* g_sceneLight = nullptr;
float4* g_sceneLightNext = nullptr;
float* g_sceneShadow = nullptr;
float* g_renderHeat[kRenderSnapshotSlots] = {};
float* g_renderFuel[kRenderSnapshotSlots] = {};
float* g_renderOxygen[kRenderSnapshotSlots] = {};
float* g_renderSoot[kRenderSnapshotSlots] = {};
float* g_renderChar[kRenderSnapshotSlots] = {};
float* g_renderAsh[kRenderSnapshotSlots] = {};
float* g_renderPyrolysis[kRenderSnapshotSlots] = {};
float* g_renderProgress[kRenderSnapshotSlots] = {};
float* g_renderTurbulenceEnergy[kRenderSnapshotSlots] = {};
float* g_renderSootOptics[kRenderSnapshotSlots] = {};
float* g_renderU[kRenderSnapshotSlots] = {};
float* g_renderV[kRenderSnapshotSlots] = {};
float* g_renderW[kRenderSnapshotSlots] = {};
float4* g_renderSceneLight[kRenderSnapshotSlots] = {};
float* g_renderSceneShadow[kRenderSnapshotSlots] = {};
constexpr int kMaxD3DInteropSlots = 4;
cudaGraphicsResource* g_d3dFp16Resources[kMaxD3DInteropSlots] = {};
int g_activeD3DInteropSlot = 0;
cudaEvent_t g_stepStartEvent = nullptr;
cudaEvent_t g_afterVelocityEvent = nullptr;
cudaEvent_t g_afterReactionEvent = nullptr;
cudaEvent_t g_afterProjectionEvent = nullptr;
cudaEvent_t g_afterLightingEvent = nullptr;
cudaEvent_t g_afterRaymarchEvent = nullptr;
cudaEvent_t g_afterPackEvent = nullptr;
cudaEvent_t g_afterSolveEvent = nullptr;
cudaEvent_t g_afterRenderEvent = nullptr;
int g_nx = 0;
int g_ny = 0;
int g_nz = 0;
int g_cudaDevice = 0;
int g_frameW = 0;
int g_frameH = 0;
int g_lightNx = 0;
int g_lightNy = 0;
int g_lightNz = 0;
int g_frameIndex = 0;
float g_time = 0.0f;
float g_renderTime = 0.0f;
int g_renderSnapshotFront = 0;
int g_renderSnapshotBack = 1;
unsigned long long g_renderSnapshotVersion = 0;
bool g_haveRenderSnapshot = false;
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

__host__ __device__ float3 add3(float3 a, float3 b) {
    return make_float3(a.x + b.x, a.y + b.y, a.z + b.z);
}

__host__ __device__ float3 sub3(float3 a, float3 b) {
    return make_float3(a.x - b.x, a.y - b.y, a.z - b.z);
}

__host__ __device__ float3 mul3(float3 a, float b) {
    return make_float3(a.x * b, a.y * b, a.z * b);
}

__host__ __device__ float3 mul3(float3 a, float3 b) {
    return make_float3(a.x * b.x, a.y * b.y, a.z * b.z);
}

__host__ __device__ float3 lerp3(float3 a, float3 b, float t) {
    return add3(a, mul3(sub3(b, a), t));
}

__host__ __device__ float dot3(float3 a, float3 b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

__host__ __device__ float length3(float3 v) {
    return sqrtf(fmaxf(0.0f, dot3(v, v)));
}

__host__ __device__ float luminance3(float3 color) {
    return color.x * 0.2126f + color.y * 0.7152f + color.z * 0.0722f;
}

__host__ __device__ float3 cross3(float3 a, float3 b) {
    return make_float3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x);
}

__host__ __device__ float3 normalize3(float3 v) {
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

__host__ __device__ CameraState computeCameraFromSettings(const SimParams& p) {
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

__device__ CameraState makeCamera(const SimParams& p) {
    CameraState cam = {};
    cam.eye = p.cameraEye;
    cam.forward = p.cameraForward;
    cam.right = p.cameraRight;
    cam.up = p.cameraUp;
    cam.tanHalfFov = p.cameraTanHalfFov;
    cam.aspect = p.cameraAspect;
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

__device__ int scalarIndexUnchecked(int x, int y, int z, const SimParams& p) {
    return (z * p.ny + y) * p.nx + x;
}

__device__ int uIndex(int x, int y, int z, const SimParams& p) {
    x = min(max(x, 0), p.nx);
    y = min(max(y, 0), p.ny - 1);
    z = min(max(z, 0), p.nz - 1);
    return (z * p.ny + y) * (p.nx + 1) + x;
}

__device__ int uIndexUnchecked(int x, int y, int z, const SimParams& p) {
    return (z * p.ny + y) * (p.nx + 1) + x;
}

__device__ int vIndex(int x, int y, int z, const SimParams& p) {
    x = min(max(x, 0), p.nx - 1);
    y = min(max(y, 0), p.ny);
    z = min(max(z, 0), p.nz - 1);
    return (z * (p.ny + 1) + y) * p.nx + x;
}

__device__ int vIndexUnchecked(int x, int y, int z, const SimParams& p) {
    return (z * (p.ny + 1) + y) * p.nx + x;
}

__device__ int wIndex(int x, int y, int z, const SimParams& p) {
    x = min(max(x, 0), p.nx - 1);
    y = min(max(y, 0), p.ny - 1);
    z = min(max(z, 0), p.nz);
    return (z * p.ny + y) * p.nx + x;
}

__device__ int wIndexUnchecked(int x, int y, int z, const SimParams& p) {
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

    const float c000 = field[scalarIndexUnchecked(x0, y0, z0, p)];
    const float c100 = field[scalarIndexUnchecked(x1, y0, z0, p)];
    const float c010 = field[scalarIndexUnchecked(x0, y1, z0, p)];
    const float c110 = field[scalarIndexUnchecked(x1, y1, z0, p)];
    const float c001 = field[scalarIndexUnchecked(x0, y0, z1, p)];
    const float c101 = field[scalarIndexUnchecked(x1, y0, z1, p)];
    const float c011 = field[scalarIndexUnchecked(x0, y1, z1, p)];
    const float c111 = field[scalarIndexUnchecked(x1, y1, z1, p)];
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
    const float c000 = field[uIndexUnchecked(x0, y0, z0, p)];
    const float c100 = field[uIndexUnchecked(x1, y0, z0, p)];
    const float c010 = field[uIndexUnchecked(x0, y1, z0, p)];
    const float c110 = field[uIndexUnchecked(x1, y1, z0, p)];
    const float c001 = field[uIndexUnchecked(x0, y0, z1, p)];
    const float c101 = field[uIndexUnchecked(x1, y0, z1, p)];
    const float c011 = field[uIndexUnchecked(x0, y1, z1, p)];
    const float c111 = field[uIndexUnchecked(x1, y1, z1, p)];
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
    const float c000 = field[vIndexUnchecked(x0, y0, z0, p)];
    const float c100 = field[vIndexUnchecked(x1, y0, z0, p)];
    const float c010 = field[vIndexUnchecked(x0, y1, z0, p)];
    const float c110 = field[vIndexUnchecked(x1, y1, z0, p)];
    const float c001 = field[vIndexUnchecked(x0, y0, z1, p)];
    const float c101 = field[vIndexUnchecked(x1, y0, z1, p)];
    const float c011 = field[vIndexUnchecked(x0, y1, z1, p)];
    const float c111 = field[vIndexUnchecked(x1, y1, z1, p)];
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
    const float c000 = field[wIndexUnchecked(x0, y0, z0, p)];
    const float c100 = field[wIndexUnchecked(x1, y0, z0, p)];
    const float c010 = field[wIndexUnchecked(x0, y1, z0, p)];
    const float c110 = field[wIndexUnchecked(x1, y1, z0, p)];
    const float c001 = field[wIndexUnchecked(x0, y0, z1, p)];
    const float c101 = field[wIndexUnchecked(x1, y0, z1, p)];
    const float c011 = field[wIndexUnchecked(x0, y1, z1, p)];
    const float c111 = field[wIndexUnchecked(x1, y1, z1, p)];
    return lerpf(lerpf(lerpf(c000, c100, tx), lerpf(c010, c110, tx), ty), lerpf(lerpf(c001, c101, tx), lerpf(c011, c111, tx), ty), tz);
}

__device__ float3 sampleVelocity(const float* uField, const float* vField, const float* wField, const SimParams& p, float u, float v, float w) {
    return make_float3(sampleU(uField, p, u, v, w), sampleV(vField, p, u, v, w), sampleW(wField, p, u, v, w));
}

__device__ int lightIndexUnchecked(int x, int y, int z, const SimParams& p) {
    return (z * p.lightNy + y) * p.lightNx + x;
}

__device__ float4 lerp4(float4 a, float4 b, float t) {
    return make_float4(
        lerpf(a.x, b.x, t),
        lerpf(a.y, b.y, t),
        lerpf(a.z, b.z, t),
        lerpf(a.w, b.w, t));
}

__device__ float4 sampleSceneLight(const float4* field, const SimParams& p, float u, float v, float w) {
    if (field == nullptr || p.lightNx <= 1 || p.lightNy <= 1 || p.lightNz <= 1) {
        return make_float4(0.0f, 0.0f, 0.0f, 0.0f);
    }
    u = saturate(u);
    v = saturate(v);
    w = saturate(w);
    const float fx = u * static_cast<float>(p.lightNx - 1);
    const float fy = v * static_cast<float>(p.lightNy - 1);
    const float fz = w * static_cast<float>(p.lightNz - 1);
    const int x0 = static_cast<int>(floorf(fx));
    const int y0 = static_cast<int>(floorf(fy));
    const int z0 = static_cast<int>(floorf(fz));
    const int x1 = min(x0 + 1, p.lightNx - 1);
    const int y1 = min(y0 + 1, p.lightNy - 1);
    const int z1 = min(z0 + 1, p.lightNz - 1);
    const float tx = fx - static_cast<float>(x0);
    const float ty = fy - static_cast<float>(y0);
    const float tz = fz - static_cast<float>(z0);

    const float4 c000 = field[lightIndexUnchecked(x0, y0, z0, p)];
    const float4 c100 = field[lightIndexUnchecked(x1, y0, z0, p)];
    const float4 c010 = field[lightIndexUnchecked(x0, y1, z0, p)];
    const float4 c110 = field[lightIndexUnchecked(x1, y1, z0, p)];
    const float4 c001 = field[lightIndexUnchecked(x0, y0, z1, p)];
    const float4 c101 = field[lightIndexUnchecked(x1, y0, z1, p)];
    const float4 c011 = field[lightIndexUnchecked(x0, y1, z1, p)];
    const float4 c111 = field[lightIndexUnchecked(x1, y1, z1, p)];
    const float4 c00 = lerp4(c000, c100, tx);
    const float4 c10 = lerp4(c010, c110, tx);
    const float4 c01 = lerp4(c001, c101, tx);
    const float4 c11 = lerp4(c011, c111, tx);
    return lerp4(lerp4(c00, c10, ty), lerp4(c01, c11, ty), tz);
}

__device__ float sampleSceneShadow(const float* field, const SimParams& p, float u, float v, float w) {
    if (field == nullptr || p.lightNx <= 1 || p.lightNy <= 1 || p.lightNz <= 1) {
        return 1.0f;
    }
    u = saturate(u);
    v = saturate(v);
    w = saturate(w);
    const int x = min(max(static_cast<int>(u * static_cast<float>(p.lightNx - 1) + 0.5f), 0), p.lightNx - 1);
    const int y = min(max(static_cast<int>(v * static_cast<float>(p.lightNy - 1) + 0.5f), 0), p.lightNy - 1);
    const int z = min(max(static_cast<int>(w * static_cast<float>(p.lightNz - 1) + 0.5f), 0), p.lightNz - 1);
    return field[lightIndexUnchecked(x, y, z, p)];
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
    float lo = field[scalarIndexUnchecked(x0, y0, z0, p)];
    float hi = lo;
    const float c100 = field[scalarIndexUnchecked(x1, y0, z0, p)];
    const float c010 = field[scalarIndexUnchecked(x0, y1, z0, p)];
    const float c110 = field[scalarIndexUnchecked(x1, y1, z0, p)];
    const float c001 = field[scalarIndexUnchecked(x0, y0, z1, p)];
    const float c101 = field[scalarIndexUnchecked(x1, y0, z1, p)];
    const float c011 = field[scalarIndexUnchecked(x0, y1, z1, p)];
    const float c111 = field[scalarIndexUnchecked(x1, y1, z1, p)];
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
    const SimParams& p,
    float current,
    float3 prevVel,
    float prevU,
    float prevV,
    float prevW,
    float blend) {
    const float firstOrder = sampleScalar(field, p, prevU, prevV, prevW);
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

__device__ float orientedCapsuleMask(float x, float z, float cx, float cz, float angle, float halfLength, float radius) {
    const float ca = cosf(angle);
    const float sa = sinf(angle);
    const float px = x - cx;
    const float pz = z - cz;
    const float qx = px * ca + pz * sa;
    const float qz = -px * sa + pz * ca;
    const float over = fmaxf(fabsf(qx) - halfLength, 0.0f);
    const float dist = sqrtf(over * over + qz * qz);
    return smoothstepf(radius, radius * 0.22f, dist);
}

__device__ float gasBurnerPortSource(float x, float z, const SimParams& p) {
    const float sourceRadius = fmaxf(0.04f, p.emitterRadius * 0.72f);
    const float cx = p.burnerCenterCount > 0 ? p.burnerCenterX[0] : p.emitterCenterX;
    const float cz = p.burnerCenterCount > 0 ? p.burnerCenterZ[0] : p.emitterCenterZ;
    const float px = x - cx;
    const float pz = z - cz;
    const float radius = sqrtf(px * px + pz * pz);
    const float angle = atan2f(pz, px);
    const float outerPortRing = smoothstepf(sourceRadius * 0.110f, sourceRadius * 0.018f, fabsf(radius - sourceRadius * 0.70f));
    const float innerPilotRing = smoothstepf(sourceRadius * 0.070f, sourceRadius * 0.012f, fabsf(radius - sourceRadius * 0.36f));
    const float ports = 0.5f + 0.5f * cosf(angle * 32.0f);
    const float portMask = smoothstepf(0.86f, 0.995f, ports);
    const float attachmentClamp = smoothstepf(sourceRadius * 1.02f, sourceRadius * 0.82f, radius);
    const float noPoolCenter = smoothstepf(sourceRadius * 0.06f, sourceRadius * 0.20f, radius);
    const float pilot = smoothstepf(sourceRadius * 0.12f, 0.000f, radius) * 0.075f;
    return saturate((outerPortRing * (0.18f + portMask * 4.20f) + innerPilotRing * 0.30f) * attachmentClamp * noPoolCenter + pilot);
}

__device__ float fuelBedMaterial(float x, float z, const SimParams& p) {
    if (p.sceneId == 1) {
        const float logA = orientedCapsuleMask(x, z, -0.06f, 0.01f, 0.38f, 0.34f, 0.060f);
        const float logB = orientedCapsuleMask(x, z, 0.07f, -0.02f, -0.58f, 0.33f, 0.058f);
        const float logC = orientedCapsuleMask(x, z, 0.01f, 0.08f, 1.34f, 0.24f, 0.050f);
        const float contactAB = fminf(logA, logB) * 1.25f;
        const float contactBC = fminf(logB, logC) * 1.10f;
        const float contactCA = fminf(logC, logA) * 0.92f;
        const float coalNoise = fbm(make_float2(x * 9.4f + z * 1.7f, z * 11.2f - x * 3.1f));
        const float coalBed = smoothstepf(0.38f, 0.08f, sqrtf(x * x * 1.35f + z * z * 2.40f)) *
            smoothstepf(0.34f, 0.88f, coalNoise);
        const float cracks = smoothstepf(0.65f, 0.93f, fbm(make_float2(x * 21.0f - z * 6.0f, z * 24.0f + x * 4.0f)));
        const float contactPyrolysis = saturate(contactAB + contactBC + contactCA);
        return saturate((logA * 0.72f + logB * 0.70f + logC * 0.54f + coalBed * 0.84f + contactPyrolysis * 1.18f) * (1.0f - cracks * 0.24f));
    }
    if (p.sceneId == 2) {
        return gasBurnerPortSource(x, z, p);
    }
    const float tray = smoothstepf(1.08f, 0.030f, fabsf(x)) * smoothstepf(0.56f, 0.026f, fabsf(z));
    const float emberMat = smoothstepf(1.00f, 0.018f, fabsf(x)) * smoothstepf(0.50f, 0.020f, fabsf(z));
    const float mound = expf(-(x * x * 0.70f + z * z * 2.15f));
    const float logMass = fbm(make_float2(x * 3.7f + z * 0.9f, z * 5.4f - x * 0.6f));
    const float chips = fbm(make_float2(x * 15.0f + z * 4.0f, z * 18.0f - x * 5.0f));
    const float strand = 0.5f + 0.5f * sinf((x * 19.0f + z * 7.0f) + fbm(make_float2(z * 4.0f, x * 3.0f)) * 4.2f);
    const float cracks = smoothstepf(0.44f, 0.74f, chips) * smoothstepf(0.20f, 0.84f, logMass);
    const float voids = smoothstepf(0.70f, 0.93f, chips * 0.72f + strand * 0.34f);
    const float clumps = smoothstepf(0.22f, 0.86f, logMass * 0.82f + chips * 0.36f + strand * 0.18f);
    const float porousFuel = (0.24f + clumps * 0.94f + emberMat * 0.20f) * (0.64f + mound * 0.46f);
    return saturate(tray * porousFuel * (1.0f - cracks * 0.46f) * (1.0f - voids * 0.34f));
}

__device__ float fuelBedSource(float x, float z, float h, const SimParams& p) {
    const float material = fuelBedMaterial(x, z, p);
    const float height = p.sceneId == 2
        ? smoothstepf(fmaxf(0.005f, p.emitterHeightBandNorm * 0.34f), fmaxf(0.0015f, p.emitterHeightBandNorm * 0.055f), fabsf(h - p.emitterHeightNorm))
        : smoothstepf(p.sceneId == 1 ? 0.245f : 0.145f, 0.00f, h);
    const float emberBreathing = 0.84f + 0.16f * fbm(make_float2(x * 9.0f + p.time * 0.035f, z * 11.0f - p.time * 0.025f));
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
    const float material = fuelBedMaterial(worldX, worldZ, p);
    const float chunkNoise = fbm(make_float2(worldX * 18.0f + worldZ * 2.0f, worldZ * 22.0f - worldX * 5.0f));
    const float bed = fuelBedSource(worldX, worldZ, v, p);
    const float charScale = p.sceneId == 2 ? 0.004f : (p.sceneId == 1 ? 1.18f : 1.0f);
    const float sootScale = p.sceneId == 2 ? 0.004f : (p.sceneId == 1 ? 0.92f : 1.0f);
    heat[idx] = bed * (p.sceneId == 2 ? 3.20f : (p.sceneId == 1 ? 0.78f + chunkNoise * 0.26f : 0.86f + chunkNoise * 0.24f));
    fuel[idx] = bed * (p.sceneId == 2 ? 2.40f : (p.sceneId == 1 ? 1.05f + chunkNoise * 0.30f : 1.08f + chunkNoise * 0.26f));
    oxygen[idx] = 1.0f;
    soot[idx] = bed * (p.sceneId == 2 ? 0.00065f : 0.018f) * sootScale;
    charField[idx] = material * (0.92f + chunkNoise * 0.72f) * charScale;
    ash[idx] = material * (0.018f + smoothstepf(0.56f, 0.86f, chunkNoise) * 0.055f) * (p.sceneId == 2 ? 0.10f : 1.0f);
    pyrolysis[idx] = bed * (p.sceneId == 2 ? 0.12f : (p.sceneId == 1 ? 0.060f + chunkNoise * 0.034f : 0.058f + chunkNoise * 0.028f));
    progress[idx] = bed * (p.sceneId == 2 ? 0.35f : (p.sceneId == 1 ? 0.24f : 0.21f));
    turbulenceEnergy[idx] = bed * (p.sceneId == 2 ? 0.050f : (p.sceneId == 1 ? 0.082f : 0.065f));
    sootOptics[idx] = bed * (p.sceneId == 2 ? 0.00050f : 0.018f) * sootScale;
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
    const int idx = scalarIndexUnchecked(x, y, z, p);
    const float currentActivity =
        heatIn[idx] +
        fuelIn[idx] * 0.18f +
        sootIn[idx] * 0.24f +
        pyrolysisIn[idx] * 0.20f +
        progressIn[idx] * 0.14f +
        sootOpticsIn[idx] * 0.08f +
        turbulenceEnergyIn[idx] * 0.06f;
    const float sourceDx = u - p.mouseX;
    const float sourceDy = v - p.mouseY;
    const float sourceDz = w - 0.5f;
    const bool outsideInteractiveSource =
        p.leftDown == 0 ||
        (sourceDx * sourceDx + sourceDy * sourceDy + sourceDz * sourceDz) > 0.090f;
    if (v > 0.18f &&
        currentActivity < 0.00035f &&
        charIn[idx] < 0.00010f &&
        ashIn[idx] < 0.00010f &&
        outsideInteractiveSource &&
        p.rightDown == 0) {
        heatOut[idx] = 0.0f;
        fuelOut[idx] = 0.0f;
        oxygenOut[idx] = fminf(1.0f, oxygenIn[idx] + (1.0f - oxygenIn[idx]) * p.dt * 0.08f);
        sootOut[idx] = 0.0f;
        charOut[idx] = charIn[idx];
        ashOut[idx] = ashIn[idx];
        pyrolysisOut[idx] = 0.0f;
        progressOut[idx] = 0.0f;
        turbulenceEnergyOut[idx] = turbulenceEnergyIn[idx] * fmaxf(0.0f, 1.0f - p.dt * 0.54f);
        sootOpticsOut[idx] = 0.0f;
        return;
    }
    const float3 vel = sampleVelocity(uField, vField, wField, p, u, v, w);
    const float prevU = u - vel.x * p.dt * kAdvectionScale;
    const float prevV = v - vel.y * p.dt * kAdvectionScale;
    const float prevW = w - vel.z * p.dt * kAdvectionScale;
    const float3 prevVel = sampleVelocity(uField, vField, wField, p, prevU, prevV, prevW);

    const float antiDiffusion = saturate(0.30f + p.detail * 0.34f);
    float heat = sampleScalarMacCormack(heatIn, p, heatIn[idx], prevVel, prevU, prevV, prevW, antiDiffusion);
    float fuel = sampleScalarMacCormack(fuelIn, p, fuelIn[idx], prevVel, prevU, prevV, prevW, antiDiffusion * 0.92f);
    float oxygen = sampleScalarMacCormack(oxygenIn, p, oxygenIn[idx], prevVel, prevU, prevV, prevW, antiDiffusion * 0.70f);
    float soot = sampleScalarMacCormack(sootIn, p, sootIn[idx], prevVel, prevU, prevV, prevW, antiDiffusion);
    float charMass = charIn[idx];
    float ash = ashIn[idx];
    float pyrolysisRate = sampleScalarMacCormack(pyrolysisIn, p, pyrolysisIn[idx], prevVel, prevU, prevV, prevW, antiDiffusion * 0.72f) * 0.55f;
    float progress = sampleScalarMacCormack(progressIn, p, progressIn[idx], prevVel, prevU, prevV, prevW, antiDiffusion * 0.82f);
    float turbulenceEnergy = sampleScalarMacCormack(turbulenceEnergyIn, p, turbulenceEnergyIn[idx], prevVel, prevU, prevV, prevW, antiDiffusion * 0.52f);
    float sootOptics = sampleScalarMacCormack(sootOpticsIn, p, sootOpticsIn[idx], prevVel, prevU, prevV, prevW, antiDiffusion * 0.72f);

    const float worldX = (u - 0.50f) * 2.10f;
    const float worldZ = (w - 0.50f) * 1.64f;
    const float material = fuelBedMaterial(worldX, worldZ, p);
    const float sourceNoise = 0.70f + 0.48f * fbm(make_float2(worldX * 13.0f + worldZ * 3.0f + p.time * 0.38f, v * 31.0f + worldZ * 11.0f));
    const float exposedChar = saturate(charMass / fmaxf(0.055f, charMass + ash * 1.75f));
    const float charEdges = smoothstepf(0.06f, 0.78f, material) * smoothstepf(0.92f, 0.02f, ash);
    const float gasFeed = p.sceneId == 2 ? 1.80f : exposedChar * charEdges;
    const float scenePyrolysisGain = p.sceneId == 2 ? 0.90f : (p.sceneId == 1 ? 1.34f : 1.0f);
    const float sceneFuelGain = p.sceneId == 2 ? 1.05f : (p.sceneId == 1 ? 1.18f : 1.0f);
    const float sceneHeatGain = p.sceneId == 2 ? 2.80f : (p.sceneId == 1 ? 1.08f : 1.0f);
    const float sceneSootGain = p.sceneId == 2 ? 0.18f : (p.sceneId == 1 ? 1.22f : 1.0f);
    const float bed = fuelBedSource(worldX, worldZ, v, p) * sourceNoise * gasFeed * p.intensity;
    const float ambientK = 293.0f;
    float tempK = ambientK + heat * 335.0f;
    const float radiativeFeedback = smoothstepf(430.0f, 980.0f, tempK);
    const float solidOxygen = saturate(oxygen * 1.28f - soot * 0.030f);
    const float heatFlux = saturate((tempK - 405.0f) / 900.0f) + bed * 0.34f + sootOptics * 0.024f;
    const float charRelease = fminf(charMass, charMass * heatFlux * solidOxygen * (0.14f + radiativeFeedback * 1.38f) * p.dt);
    pyrolysisRate += (bed * (0.34f + radiativeFeedback * 1.05f) * p.dt + charRelease * (2.45f + sourceNoise * 0.72f)) * scenePyrolysisGain;
    charMass += material * p.dt * (p.sceneId == 2 ? 0.00005f : (p.sceneId == 1 ? 0.050f : 0.026f));
    charMass -= charRelease * 0.92f;
    ash += charRelease * (p.sceneId == 2 ? 0.025f : 0.16f + 0.22f * saturate(1.0f - oxygen));

    heat += (bed * (p.sceneId == 2 ? 14.20f : 6.20f) * p.dt * (1.0f + radiativeFeedback * 1.12f) + charRelease * 3.35f) * sceneHeatGain;
    fuel += pyrolysisRate * (p.sceneId == 2 ? 1.34f : 3.70f) * sceneFuelGain;
    soot += pyrolysisRate * (0.090f + ash * 0.032f + saturate(1.0f - oxygen) * 0.13f) * p.smokeGain * (p.sceneId == 2 ? 0.010f : (p.sceneId == 1 ? 0.92f : 1.0f)) * sceneSootGain;

    if (p.leftDown != 0) {
        const float mx = p.mouseX;
        const float my = p.mouseY;
        const float source = expf(-((u - mx) * (u - mx)) / 0.0180f - ((w - 0.5f) * (w - 0.5f)) / 0.0550f - ((v - my) * (v - my)) / 0.0020f);
        heat += source * p.dt * 2.8f;
        fuel += source * p.dt * 1.4f;
        pyrolysisRate += source * p.dt * 0.45f;
        progress += source * p.dt * 0.75f;
        turbulenceEnergy += source * p.dt * 0.28f;
        oxygen = fmaxf(oxygen, 0.72f + source * 0.20f);
    }
    if (p.rightDown != 0) {
        const float source = expf(-((u - p.mouseX) * (u - p.mouseX) + (w - 0.5f) * (w - 0.5f)) / 0.0100f - (v - p.mouseY) * (v - p.mouseY) / 0.0100f);
        soot += source * p.dt * 8.0f;
        heat *= 1.0f - source * p.dt * 1.2f;
        fuel *= 1.0f - source * p.dt * 0.7f;
    }

    tempK = ambientK + heat * 335.0f;
    const float thermalActivation = smoothstepf(575.0f, 1220.0f, tempK);
    const float arrhenius = expf(-3800.0f / fmaxf(640.0f, tempK));
    const float oxygenLimited = fminf(fuel, oxygen * 1.42f);
    const float burnMass = fminf(oxygenLimited, oxygenLimited * thermalActivation * arrhenius * (118.0f + p.intensity * 34.0f) * p.dt);
    const float incomplete = saturate(1.0f - oxygen * 1.30f + fuel * 0.065f + soot * 0.015f);
    const float heatRelease = burnMass * 7.0f;
    const float sootYield = burnMass * (0.035f + incomplete * 0.34f) * p.smokeGain * (p.sceneId == 2 ? 0.006f : (p.sceneId == 1 ? 0.96f : 1.0f));
    const float sootOxidation = soot * oxygen * smoothstepf(760.0f, 1540.0f, tempK) * p.dt * 0.82f;
    const float frontProduction = burnMass * (9.8f + turbulenceEnergy * 3.4f) + pyrolysisRate * 0.70f + charRelease * 2.10f;
    const float boundaryAir = smoothstepf(0.70f, 0.96f, v) + smoothstepf(0.11f, 0.03f, u) + smoothstepf(0.89f, 0.97f, u) + smoothstepf(0.11f, 0.03f, w) + smoothstepf(0.89f, 0.97f, w);
    const float upperEntrainment = smoothstepf(0.52f, 0.98f, v);

    heat += heatRelease;
    fuel -= burnMass * 1.20f;
    oxygen -= burnMass * 0.98f;
    soot += sootYield;
    soot -= sootOxidation;
    progress += frontProduction;
    progress *= expf(-p.dt * (0.72f + v * 0.45f + oxygen * 0.16f + saturate(boundaryAir) * 1.05f + upperEntrainment * 0.26f));

    oxygen = lerpf(oxygen, 1.0f, saturate(boundaryAir) * p.dt * 1.7f);
    oxygen += (1.0f - oxygen) * p.dt * 0.08f;

    tempK = ambientK + heat * 335.0f;
    const float radiationBase = fmaxf(0.0f, (tempK - ambientK) / 1560.0f);
    const float radiationSq = radiationBase * radiationBase;
    const float radiationLoss = radiationSq * radiationSq;
    heat -= radiationLoss * p.dt * (0.88f + soot * 0.085f + sootOptics * 0.018f);
    heat *= expf(-p.dt * (0.31f + v * 0.64f + soot * 0.022f + saturate(boundaryAir) * 0.26f + upperEntrainment * 0.18f));
    fuel *= expf(-p.dt * (0.58f + heat * 0.20f + v * 0.92f + saturate(boundaryAir) * 0.18f));
    soot *= expf(-p.dt * (0.060f + v * 0.092f + oxygen * 0.028f + saturate(boundaryAir) * 0.96f + upperEntrainment * 0.22f));
    pyrolysisRate *= expf(-p.dt * (1.55f + v * 0.58f + saturate(boundaryAir) * 0.18f));

    const float uL = uField[uIndexUnchecked(x, y, z, p)];
    const float uR = uField[uIndexUnchecked(x + 1, y, z, p)];
    const float vD = vField[vIndexUnchecked(x, y, z, p)];
    const float vU = vField[vIndexUnchecked(x, y + 1, z, p)];
    const float wB = wField[wIndexUnchecked(x, y, z, p)];
    const float wF = wField[wIndexUnchecked(x, y, z + 1, p)];
    const float shear =
        fabsf(uR - uL) +
        fabsf(vU - vD) +
        fabsf(wF - wB);
    const float flameActivity = saturate(progress * 0.64f + burnMass * 5.2f + heat * 0.065f);
    turbulenceEnergy += p.dt * (shear * (0.72f + progress * 0.06f) + flameActivity * p.turbulence * 0.62f + frontProduction * 0.085f + soot * 0.018f);
    turbulenceEnergy *= expf(-p.dt * (0.54f + v * 0.24f + saturate(boundaryAir) * 0.42f + upperEntrainment * 0.16f));
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
    const float gradX = heat[scalarIndex(x + 1, y, z, p)] - heat[scalarIndex(x - 1, y, z, p)];
    const float gradY = heat[scalarIndex(x, y + 1, z, p)] - heat[scalarIndex(x, y - 1, z, p)];
    const float gradZ = heat[scalarIndex(x, y, z + 1, p)] - heat[scalarIndex(x, y, z - 1, p)];
    const float uL = uField[uIndex(x, y, z, p)];
    const float uR = uField[uIndex(x + 1, y, z, p)];
    const float vD = vField[vIndex(x, y, z, p)];
    const float vU = vField[vIndex(x, y + 1, z, p)];
    const float wB = wField[wIndex(x, y, z, p)];
    const float wF = wField[wIndex(x, y, z + 1, p)];
    const float curlX = (wF - wB) - (vU - vD);
    const float curlY = (uR - uL) - (wF - wB);
    const float curlZ = (vU - vD) - (uR - uL);
    const float curlMagnitude = fabsf(curlX) + fabsf(curlY) + fabsf(curlZ);
    const float curlNoiseA = fbm(make_float2(u * 9.0f + w * 3.7f + p.time * 0.22f, v * 13.0f - p.time * 0.31f)) - 0.5f;
    const float curlNoiseB = fbm(make_float2(w * 10.0f - p.time * 0.19f, u * 8.0f + v * 5.5f + p.time * 0.27f)) - 0.5f;
    const float thermalActivity = smoothstepf(0.04f, 4.20f, h + s * 0.28f);
    const float upperDrag = smoothstepf(0.26f, 0.94f, v);
    const float lesGain = sqrtf(fmaxf(0.0f, k)) * (0.30f + c * 0.54f);
    const float sceneCurlScale = p.sceneId == 2 ? 0.38f : (p.sceneId == 1 ? 1.18f : 1.0f);
    const float sceneBuoyancyScale = p.sceneId == 2 ? 0.42f : (p.sceneId == 1 ? 1.06f : 1.0f);
    const float curlGain = p.turbulence * sceneCurlScale * (0.18f + thermalActivity * 0.82f + lesGain * 1.12f);
    const float vortexGain = p.turbulence * sceneCurlScale * thermalActivity * saturate(curlMagnitude * 0.46f) * 0.68f;
    const float buoyancyFade = p.sceneId == 2 ? smoothstepf(0.24f, 0.035f, v) : smoothstepf(0.96f, 0.08f, v);
    const float verticalVelocity = 0.5f * (vD + vU);
    const float verticalDamping = verticalVelocity * (0.10f + upperDrag * 0.72f + s * 0.020f);
    const float buoyancy = h * sceneBuoyancyScale * (1.62f + p.turbulence * 0.34f + c * 0.16f) * buoyancyFade - s * 0.095f - gradY * 0.18f - verticalDamping;

    atomicAdd(&vField[vIndex(x, y + 1, z, p)], p.dt * (buoyancy + curlY * vortexGain * 0.22f));
    atomicAdd(&uField[uIndex(x, y, z, p)], p.dt * (p.wind * (0.34f + v * 0.96f) + (-gradZ * 1.36f + curlNoiseA * (0.20f + upperDrag * 0.16f) + curlX * vortexGain) * curlGain));
    atomicAdd(&uField[uIndex(x + 1, y, z, p)], p.dt * (p.wind * (0.34f + v * 0.96f) + (-gradZ * 1.36f + curlNoiseA * (0.20f + upperDrag * 0.16f) + curlX * vortexGain) * curlGain));
    atomicAdd(&wField[wIndex(x, y, z, p)], p.dt * ((gradX * 1.36f + curlNoiseB * (0.20f + upperDrag * 0.16f) + curlZ * vortexGain) * curlGain));
    atomicAdd(&wField[wIndex(x, y, z + 1, p)], p.dt * ((gradX * 1.36f + curlNoiseB * (0.20f + upperDrag * 0.16f) + curlZ * vortexGain) * curlGain));
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

__global__ void __launch_bounds__(kCudaBlockThreads, 1) sorPressureParityKernel(float* pressure, const float* divergence, SimParams p, int parity, float omega) {
    const int compact = blockIdx.x * blockDim.x + threadIdx.x;
    const int cellsPerRow = (p.nx + 1) / 2;
    const int rowCount = p.ny * (p.launchZEnd - p.launchZStart);
    if (compact >= cellsPerRow * rowCount) {
        return;
    }
    const int row = compact / cellsPerRow;
    const int localX = compact - row * cellsPerRow;
    const int y = row % p.ny;
    const int z = p.launchZStart + row / p.ny;
    const int firstX = (parity ^ y ^ z) & 1;
    const int x = firstX + localX * 2;
    if (x >= p.nx || z >= p.launchZEnd || z >= p.nz) {
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
    const float4* sceneLightField,
    const float* sceneShadowField,
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
    const float u = (static_cast<float>(x) + 0.5f) / static_cast<float>(p.nx);
    const float v = (static_cast<float>(y) + 0.5f) / static_cast<float>(p.ny);
    const float w = (static_cast<float>(z) + 0.5f) / static_cast<float>(p.nz);
    const float4 sceneLight = sampleSceneLight(sceneLightField, p, u, v, w);
    const float sceneShadow = sampleSceneShadow(sceneShadowField, p, u, v, w);

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
    const float flameMass =
        smoothstepf(0.72f, 2.10f, heat + progress * 0.62f + pyrolysis * 0.24f) *
        smoothstepf(0.035f, 0.66f, oxygen) *
        smoothstepf(0.012f, 0.52f, fuel + pyrolysis * 0.36f);
    const float smokeMass =
        smoothstepf(0.035f, 1.16f, sootOptics + soot * 0.38f + ash * 0.12f) *
        smoothstepf(0.08f, 0.88f, normalizedHeight);
    const float overlap = flameMass * smokeMass;
    const float volumetricShadow = sceneShadow * expf(-sceneLight.w * 0.80f);
    const float roomIrradiance = luminance3(make_float3(sceneLight.x, sceneLight.y, sceneLight.z)) * volumetricShadow;
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
    atomicAdd(&metrics->sceneLightSum, static_cast<double>(luminance3(make_float3(sceneLight.x, sceneLight.y, sceneLight.z))));
    atomicAdd(&metrics->sceneShadowSum, static_cast<double>(sceneShadow));
    atomicAdd(&metrics->flameMassProxy, static_cast<double>(flameMass));
    atomicAdd(&metrics->smokeMassProxy, static_cast<double>(smokeMass));
    atomicAdd(&metrics->flameSmokeOverlapProxy, static_cast<double>(overlap));
    atomicAdd(&metrics->volumetricShadowSum, static_cast<double>(volumetricShadow));
    atomicAdd(&metrics->roomIrradianceSum, static_cast<double>(roomIrradiance));
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

__global__ void __launch_bounds__(kCudaBlockThreads, 1) buildSceneLightKernel(
    float4* sceneLight,
    float* sceneShadow,
    const float* heatField,
    const float* fuelField,
    const float* oxygenField,
    const float* sootField,
    const float* charField,
    const float* ashField,
    const float* pyrolysisField,
    const float* progressField,
    const float* sootOpticsField,
    SimParams p) {
    const int lx = blockIdx.x * blockDim.x + threadIdx.x;
    const int ly = blockIdx.y * blockDim.y + threadIdx.y;
    const int lz = blockIdx.z * blockDim.z + threadIdx.z;
    if (lx >= p.lightNx || ly >= p.lightNy || lz >= p.lightNz) {
        return;
    }

    const float u = (static_cast<float>(lx) + 0.5f) / static_cast<float>(p.lightNx);
    const float v = (static_cast<float>(ly) + 0.5f) / static_cast<float>(p.lightNy);
    const float w = (static_cast<float>(lz) + 0.5f) / static_cast<float>(p.lightNz);
    const float domainFade = volumeDomainFade(u, v, w);
    const float heat = sampleScalar(heatField, p, u, v, w);
    const float fuel = sampleScalar(fuelField, p, u, v, w);
    const float oxygen = sampleScalar(oxygenField, p, u, v, w);
    const float soot = sampleScalar(sootField, p, u, v, w);
    const float charMass = sampleScalar(charField, p, u, v, w);
    const float ash = sampleScalar(ashField, p, u, v, w);
    const float pyrolysis = sampleScalar(pyrolysisField, p, u, v, w);
    const float progress = sampleScalar(progressField, p, u, v, w);
    const float sootOptics = sampleScalar(sootOpticsField, p, u, v, w);

    const float cellX = 1.0f / static_cast<float>(p.nx);
    const float cellY = 1.0f / static_cast<float>(p.ny);
    const float cellZ = 1.0f / static_cast<float>(p.nz);
    const float gradHeatX = sampleScalar(heatField, p, u + cellX, v, w) - sampleScalar(heatField, p, u - cellX, v, w);
    const float gradHeatY = sampleScalar(heatField, p, u, v + cellY, w) - sampleScalar(heatField, p, u, v - cellY, w);
    const float gradHeatZ = sampleScalar(heatField, p, u, v, w + cellZ) - sampleScalar(heatField, p, u, v, w - cellZ);
    const float frontGradient = sqrtf(gradHeatX * gradHeatX + gradHeatY * gradHeatY + gradHeatZ * gradHeatZ) + fuel * oxygen * 0.035f + progress * 0.16f;
    const float fineNoise = fbm3(make_float3(u * 34.0f + p.time * 0.45f, v * 42.0f - p.time * 0.82f, w * 34.0f + p.time * 0.22f));
    const float shearNoise = fbm3(make_float3(u * 12.0f - p.time * 0.38f, v * 11.0f - p.time * 0.62f, w * 13.0f + p.time * 0.20f));
    const float reactionFront = smoothstepf(0.035f, 0.54f, frontGradient + pyrolysis * 0.10f);
    const float flameHeightFade = smoothstepf(0.70f, 0.070f, v);
    const float lowerShadowColumn = smoothstepf(0.62f, 0.06f, v);
    const float plumeShadowColumn = smoothstepf(0.12f, 0.88f, v);
    const float sheetGate =
        smoothstepf(0.56f, 0.94f, fineNoise * 0.48f + shearNoise * 0.42f + reactionFront * 0.26f + heat * 0.018f) *
        smoothstepf(0.04f, 0.86f, reactionFront) *
        flameHeightFade;
    const float sheetCore = saturate(sheetGate * (0.42f + progress * 0.22f + pyrolysis * 0.34f));
    const float tempK = 293.0f + heat * 360.0f + fuel * 44.0f + pyrolysis * 120.0f + progress * 70.0f + sheetCore * 1020.0f;
    const float flameEmitter =
        domainFade *
        smoothstepf(820.0f, 1880.0f, tempK) *
        smoothstepf(0.010f, 0.68f, fuel + pyrolysis * 0.30f + heat * 0.040f) *
        smoothstepf(0.030f, 0.82f, oxygen) *
        reactionFront *
        sheetGate *
        (0.24f + sheetCore * 1.42f);
    const float emberEmitter =
        smoothstepf(0.002f, 0.22f, charMass + ash * 0.18f) *
        smoothstepf(0.09f, 0.00f, v) *
        (0.10f + heat * 0.012f + pyrolysis * 0.050f);
    const float sootAttenuation = expf(-(sootOptics * 0.25f + soot * 0.090f + ash * 0.035f));
    const float3 flame = mul3(blackbodyColor(tempK), flameEmitter * sootAttenuation * 3.40f);
    const float3 coal = mul3(make_float3(1.0f, 0.22f, 0.040f), emberEmitter * p.reflectionGain * 0.20f);
    const float extinction = saturate(
        sootOptics * (0.26f + plumeShadowColumn * 0.42f) +
        soot * (0.065f + plumeShadowColumn * 0.20f) +
        ash * 0.050f +
        progress * lowerShadowColumn * 0.020f);

    const int idx = lightIndexUnchecked(lx, ly, lz, p);
    sceneLight[idx] = make_float4(flame.x + coal.x, flame.y + coal.y, flame.z + coal.z, extinction);
    const float verticalDepth = v * (1.0f + plumeShadowColumn * 0.70f);
    const float radialDepth = expf(-((u - 0.50f) * (u - 0.50f) * 5.5f + (w - 0.50f) * (w - 0.50f) * 7.0f));
    const float opticalShadow = sootOptics * (0.62f + plumeShadowColumn * 1.15f) + soot * (0.22f + plumeShadowColumn * 0.46f) + ash * 0.072f;
    sceneShadow[idx] = expf(-(opticalShadow * (0.72f + verticalDepth * 0.42f) + radialDepth * opticalShadow * 0.34f + progress * 0.035f));
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) propagateSceneLightKernel(
    float4* outLight,
    const float4* inLight,
    const float* sceneShadow,
    SimParams p,
    float diffusion,
    float decay) {
    const int lx = blockIdx.x * blockDim.x + threadIdx.x;
    const int ly = blockIdx.y * blockDim.y + threadIdx.y;
    const int lz = blockIdx.z * blockDim.z + threadIdx.z;
    if (lx >= p.lightNx || ly >= p.lightNy || lz >= p.lightNz) {
        return;
    }

    const int idx = lightIndexUnchecked(lx, ly, lz, p);
    const float4 center = inLight[idx];
    float3 neighbor = make_float3(0.0f, 0.0f, 0.0f);
    float weight = 0.0f;
    const int dx[6] = {-1, 1, 0, 0, 0, 0};
    const int dy[6] = {0, 0, -1, 1, 0, 0};
    const int dz[6] = {0, 0, 0, 0, -1, 1};
    for (int i = 0; i < 6; ++i) {
        const int sx = min(max(lx + dx[i], 0), p.lightNx - 1);
        const int sy = min(max(ly + dy[i], 0), p.lightNy - 1);
        const int sz = min(max(lz + dz[i], 0), p.lightNz - 1);
        const float4 sample = inLight[lightIndexUnchecked(sx, sy, sz, p)];
        const float occlusion = expf(-sample.w * 0.42f);
        neighbor = add3(neighbor, mul3(make_float3(sample.x, sample.y, sample.z), occlusion));
        weight += occlusion;
    }
    neighbor = mul3(neighbor, 1.0f / fmaxf(0.0001f, weight));
    const float shadow = sceneShadow[idx];
    const float3 direct = make_float3(center.x, center.y, center.z);
    const float3 bounced = lerp3(direct, neighbor, diffusion);
    const float floorLift = smoothstepf(0.10f, 0.00f, (static_cast<float>(ly) + 0.5f) / static_cast<float>(p.lightNy));
    const float3 contactBounce = mul3(make_float3(1.0f, 0.40f, 0.12f), floorLift * luminance3(direct) * 0.18f);
    const float3 next = add3(mul3(bounced, decay * (0.66f + shadow * 0.34f)), contactBounce);
    outLight[idx] = make_float4(next.x, next.y, next.z, center.w);
}

__device__ float floorGrid(float x, float z, float scale, float width) {
    (void)x;
    (void)z;
    (void)scale;
    (void)width;
    return 0.0f;
}

__device__ float3 fireVolumeUvFromWorld(float3 p) {
    return make_float3(
        saturate((p.x + 1.05f) / 2.10f),
        saturate((p.y - 0.02f) / 2.03f),
        saturate((p.z + 0.82f) / 1.64f));
}

__device__ float3 fireVolumeWorldFromUv(float3 uv) {
    return make_float3(
        uv.x * 2.10f - 1.05f,
        uv.y * 2.03f + 0.02f,
        uv.z * 1.64f - 0.82f);
}

__device__ float3 gatherSceneIrradiance(
    float3 hit,
    float3 normal,
    const float4* sceneLightField,
    const float* sceneShadowField,
    const SimParams& p) {
    float3 irradiance = make_float3(0.0f, 0.0f, 0.0f);

#pragma unroll
    for (int i = 0; i < 3; ++i) {
        float3 sampleUv = make_float3(0.50f, 0.16f, 0.50f);
        if (i == 1) {
            sampleUv = make_float3(0.34f, 0.26f, 0.43f);
        } else if (i == 2) {
            sampleUv = make_float3(0.66f, 0.26f, 0.57f);
        }

        const float4 light = sampleSceneLight(sceneLightField, p, sampleUv.x, sampleUv.y, sampleUv.z);
        const float3 radiance = make_float3(light.x, light.y, light.z);
        const float lum = luminance3(radiance);
        if (lum <= 0.00001f) {
            continue;
        }

        const float3 source = fireVolumeWorldFromUv(sampleUv);
        const float3 toLight = sub3(source, hit);
        const float dist2 = fmaxf(0.045f, dot3(toLight, toLight));
        const float3 wi = mul3(toLight, rsqrtf(dist2));
        const float ndotl = fmaxf(0.0f, dot3(normal, wi));
        const float heightOcclusion = expf(-fmaxf(0.0f, hit.y - source.y) * light.w * 1.15f);
        const float visibility = sampleSceneShadow(sceneShadowField, p, sampleUv.x, sampleUv.y, sampleUv.z) * expf(-light.w * 0.92f) * heightOcclusion;
        const float geometric = (0.12f + ndotl * 0.88f) * expf(-dist2 * 0.22f) / (0.12f + dist2);
        irradiance = add3(irradiance, mul3(radiance, visibility * geometric));
    }

    const float grazingBounce = 1.0f + smoothstepf(0.0f, 0.45f, 1.0f - fmaxf(0.0f, normal.y)) * 0.36f;
    return mul3(irradiance, 4.20f * grazingBounce);
}

__device__ float volumeShadowRay(
    float3 hit,
    const float4* sceneLightField,
    const float* sceneShadowField,
    const SimParams& p) {
    const float3 targetUv = fireVolumeUvFromWorld(hit);
    const float3 sourceUv = make_float3(0.50f, 0.12f, 0.50f);
    float opticalDepth = 0.0f;
#pragma unroll
    for (int i = 1; i <= 5; ++i) {
        const float t = static_cast<float>(i) / 6.0f;
        const float3 uv = lerp3(sourceUv, targetUv, t);
        const float4 light = sampleSceneLight(sceneLightField, p, uv.x, uv.y, uv.z);
        const float shadow = sampleSceneShadow(sceneShadowField, p, uv.x, uv.y, uv.z);
        opticalDepth += light.w * (0.18f + t * 0.22f) + (1.0f - shadow) * (0.08f + t * 0.16f);
    }
    return expf(-opticalDepth);
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

__device__ void sourceModelOverlay(float2 uv, const CameraState& cam, const SimParams& p, float glow, float3* color) {
    if (uv.x < 0.24f || uv.x > 0.76f || uv.y < 0.42f || uv.y > 0.88f) {
        return;
    }
    if (p.sceneId == 1) {
        return;
    }
    float alpha = 0.0f;
    float3 modelColor = make_float3(0.0f, 0.0f, 0.0f);
    const float sourceX = p.sceneId == 2 && p.burnerCenterCount > 0 ? p.burnerCenterX[0] : p.emitterCenterX;
    const float sourceY = p.emitterHeightNorm * 2.03f + 0.02f;
    const float sourceZ = p.sceneId == 2 && p.burnerCenterCount > 0 ? p.burnerCenterZ[0] : p.emitterCenterZ;
    const float3 c = projectPoint(cam, make_float3(sourceX, sourceY, sourceZ));
    const float tray = smoothstepf(0.135f, 0.105f, fabsf(uv.x - c.x)) * smoothstepf(0.050f, 0.036f, fabsf(uv.y - c.y));
    const float inner = smoothstepf(0.112f, 0.086f, fabsf(uv.x - c.x)) * smoothstepf(0.039f, 0.027f, fabsf(uv.y - c.y));
    alpha = saturate((tray - inner * 0.55f) * 0.65f);
    modelColor = lerp3(make_float3(0.015f, 0.013f, 0.011f), make_float3(0.13f, 0.12f, 0.10f), alpha);
    if (alpha > 0.001f) {
        *color = lerp3(*color, modelColor, saturate(alpha));
    }
}

__device__ float3 roomBackgroundRay(
    const CameraState& cam,
    float2 uv,
    float3 rd,
    float glow,
    const float4* sceneLightField,
    const float* sceneShadowField,
    const SimParams& p) {
    const float roomHalf = 2.55f;
    const float ceilingY = 2.18f;
    const bool cinematic = p.cinematicMode != 0;
    float bestT = 1.0e6f;
    float3 hit = make_float3(0.0f, 0.0f, 0.0f);
    float3 surfaceNormal = make_float3(0.0f, 1.0f, 0.0f);
    int surface = 0;

    if (rd.y < -0.0001f) {
        const float t = -cam.eye.y / rd.y;
        const float3 p = add3(cam.eye, mul3(rd, t));
        if (t > 0.0f && fabsf(p.x) <= roomHalf && fabsf(p.z) <= roomHalf && t < bestT) {
            bestT = t;
            hit = p;
            surfaceNormal = make_float3(0.0f, 1.0f, 0.0f);
            surface = 1;
        }
    }
    if (rd.y > 0.0001f) {
        const float t = (ceilingY - cam.eye.y) / rd.y;
        const float3 p = add3(cam.eye, mul3(rd, t));
        if (t > 0.0f && fabsf(p.x) <= roomHalf && fabsf(p.z) <= roomHalf && t < bestT) {
            bestT = t;
            hit = p;
            surfaceNormal = make_float3(0.0f, -1.0f, 0.0f);
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
            surfaceNormal = make_float3(planeX > 0.0f ? -1.0f : 1.0f, 0.0f, 0.0f);
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
            surfaceNormal = make_float3(0.0f, 0.0f, planeZ > 0.0f ? -1.0f : 1.0f);
            surface = 4;
        }
    }

    float3 color = make_float3(0.014f, 0.014f, 0.014f);
    float3 materialAlbedo = make_float3(0.26f, 0.26f, 0.25f);
    float materialGiScale = 0.24f;
    if (surface == 1) {
        const float panelSeam = floorGrid(hit.x, hit.z, 1.18f, 0.010f);
        const float fineSeam = floorGrid(hit.x + 0.09f, hit.z - 0.04f, 5.6f, 0.006f);
        const float slabTone = sinf(hit.x * 2.20f + hit.z * 1.40f) * 0.50f + sinf(hit.z * 3.10f - hit.x * 0.80f) * 0.50f;
        color = cinematic ? make_float3(0.016f, 0.016f, 0.015f) : make_float3(0.014f, 0.014f, 0.013f);
        color = add3(color, mul3(make_float3(0.014f, 0.014f, 0.013f), slabTone * 0.018f));
        color = lerp3(color, make_float3(0.014f, 0.014f, 0.013f), saturate(panelSeam * 0.16f + fineSeam * 0.045f));
        materialAlbedo = make_float3(0.26f, 0.26f, 0.25f);
        materialGiScale = 0.22f;

        if (p.sceneId == 1) {
            const float logMaterial = fuelBedMaterial(hit.x, hit.z, p);
            const float coal = expf(-(hit.x * hit.x * 1.25f + hit.z * hit.z * 2.45f)) *
                smoothstepf(0.28f, 0.90f, fbm(make_float2(hit.x * 13.0f, hit.z * 15.0f)));
            const float scorch = expf(-(hit.x * hit.x * 0.66f + hit.z * hit.z * 1.15f));
            color = lerp3(color, make_float3(0.018f, 0.015f, 0.012f), saturate(logMaterial * 0.78f + scorch * 0.20f));
            color = add3(color, mul3(make_float3(0.090f, 0.020f, 0.004f), coal * glow * 0.026f));
            color = add3(color, mul3(make_float3(0.17f, 0.11f, 0.055f), logMaterial * 0.050f));
            materialAlbedo = lerp3(materialAlbedo, make_float3(0.040f, 0.030f, 0.022f), logMaterial * 0.86f);
            materialGiScale = lerpf(materialGiScale, 0.44f, logMaterial * 0.80f);
        } else if (p.sceneId == 2) {
            const float sourceX = p.burnerCenterCount > 0 ? p.burnerCenterX[0] : p.emitterCenterX;
            const float sourceZ = p.burnerCenterCount > 0 ? p.burnerCenterZ[0] : p.emitterCenterZ;
            const float dx = hit.x - sourceX;
            const float dz = hit.z - sourceZ;
            const float radius = sqrtf(dx * dx + dz * dz);
            const float plate = smoothstepf(0.58f, 0.46f, radius);
            const float burner = fuelBedMaterial(hit.x, hit.z, p);
            const float radialGrooves = floorGrid(radius, 0.0f, 18.0f, 0.005f);
            color = lerp3(color, make_float3(0.022f, 0.025f, 0.030f), plate * 0.62f);
            color = lerp3(color, make_float3(0.008f, 0.010f, 0.014f), burner * 0.46f);
            color = add3(color, mul3(make_float3(0.040f, 0.080f, 0.19f), radialGrooves * plate * 0.040f));
            color = add3(color, mul3(make_float3(0.030f, 0.18f, 0.62f), burner * glow * 0.26f));
            materialAlbedo = lerp3(materialAlbedo, make_float3(0.060f, 0.065f, 0.074f), plate * 0.82f);
            materialGiScale = lerpf(materialGiScale, 0.70f, plate * 0.72f);
        } else {
            const float trayBody = rectMask(make_float2(hit.x, hit.z), make_float2(0.0f, 0.0f), make_float2(1.08f, 0.58f), 0.022f);
            const float trayInner = rectMask(make_float2(hit.x, hit.z), make_float2(0.0f, 0.0f), make_float2(0.96f, 0.47f), 0.020f);
            const float trayRim = saturate(trayBody - trayInner * 0.74f);
            const float emberBed = trayInner * expf(-(hit.x * hit.x * 0.74f + hit.z * hit.z * 2.20f));
            const float trayContact = trayInner * expf(-(hit.x * hit.x * 1.35f + hit.z * hit.z * 3.35f));
            const float scorch = expf(-(hit.x * hit.x * 0.82f + hit.z * hit.z * 1.75f));
            color = lerp3(color, make_float3(0.017f, 0.014f, 0.012f), trayBody * 0.82f);
            color = lerp3(color, make_float3(0.020f, 0.019f, 0.018f), scorch * (1.0f - trayBody) * 0.16f);
            color = lerp3(color, make_float3(0.010f, 0.009f, 0.008f), trayContact * 0.22f);
            color = add3(color, mul3(make_float3(0.056f, 0.014f, 0.003f), emberBed * glow * 0.26f));
            color = add3(color, mul3(make_float3(0.30f, 0.28f, 0.24f), trayRim * 0.10f));
            materialAlbedo = lerp3(materialAlbedo, make_float3(0.030f, 0.024f, 0.020f), trayBody * 0.75f);
            materialGiScale = lerpf(materialGiScale, 0.48f, trayBody * 0.85f);
        }

        const float reflectCore = expf(-(hit.x * hit.x * 2.45f + (hit.z + 0.18f) * (hit.z + 0.18f) * 1.95f)) * glow;
        const float reflectedTongues = smoothstepf(0.82f, 0.00f, fabsf(hit.x)) * smoothstepf(1.18f, 0.00f, fabsf(hit.z + 0.72f));
        const float streaks = floorGrid(hit.x + hit.z * 0.035f, hit.z, 13.0f, 0.010f);
        const float3 floorGlowColor = p.sceneId == 2 ? make_float3(0.030f, 0.12f, 0.44f) : make_float3(0.55f, 0.11f, 0.023f);
        const float3 floorTongueColor = p.sceneId == 2 ? make_float3(0.020f, 0.075f, 0.26f) : make_float3(0.46f, 0.070f, 0.014f);
        color = add3(color, mul3(floorGlowColor, reflectCore * p.reflectionGain * (p.sceneId == 2 ? 0.18f : 0.48f)));
        color = add3(color, mul3(floorTongueColor, reflectedTongues * streaks * glow * p.reflectionGain * (p.sceneId == 2 ? 0.035f : 0.14f)));
    } else if (surface == 2) {
        color = cinematic ? make_float3(0.012f, 0.012f, 0.012f) : make_float3(0.011f, 0.011f, 0.010f);
        materialAlbedo = make_float3(0.24f, 0.24f, 0.23f);
        materialGiScale = 0.20f;
        const float panelA = lineMask(make_float2(hit.x, hit.z), make_float2(-1.2f, -2.0f), make_float2(-1.2f, 2.0f), 0.010f);
        const float panelB = lineMask(make_float2(hit.x, hit.z), make_float2(0.0f, -2.0f), make_float2(0.0f, 2.0f), 0.008f);
        const float ceilingGrid = floorGrid(hit.x + 0.18f, hit.z - 0.10f, 1.02f, 0.007f);
        const float ceilingRib = floorGrid(hit.x - 0.08f, hit.z + 0.22f, 0.42f, 0.004f);
        const float fixtureL = expf(-((hit.x + 1.50f) * (hit.x + 1.50f) + (hit.z - 0.92f) * (hit.z - 0.92f)) * 120.0f);
        const float fixtureR = expf(-((hit.x - 1.72f) * (hit.x - 1.72f) + (hit.z - 0.80f) * (hit.z - 0.80f)) * 120.0f);
        color = lerp3(color, make_float3(0.011f, 0.011f, 0.010f), saturate(ceilingGrid * 0.090f + ceilingRib * 0.035f));
        color = add3(color, mul3(make_float3(0.10f, 0.096f, 0.088f), (panelA + panelB) * 0.08f));
        color = add3(color, mul3(make_float3(0.26f, 0.20f, 0.13f), (fixtureL + fixtureR) * 0.10f));
    } else {
        color = cinematic ? make_float3(0.015f, 0.015f, 0.014f) : color;
        materialAlbedo = make_float3(0.25f, 0.25f, 0.24f);
        materialGiScale = 0.24f;
        const float wallU = surface == 3 ? hit.z : hit.x;
        const float panelSeam = floorGrid(wallU + 0.10f, hit.y - 0.06f, 1.08f, 0.007f);
        const float baseShadow = smoothstepf(0.34f, 0.02f, hit.y);
        const float crownShadow = smoothstepf(ceilingY - 0.32f, ceilingY - 0.02f, hit.y);
        color = lerp3(color, make_float3(0.017f, 0.017f, 0.016f), panelSeam * 0.090f);
        color = lerp3(color, make_float3(0.012f, 0.012f, 0.011f), saturate(baseShadow * 0.30f + crownShadow * 0.20f));
        if (surface == 4 && hit.z > 0.0f) {
            const float recess = rectMask(make_float2(hit.x, hit.y), make_float2(0.0f, 1.00f), make_float2(0.92f, 0.72f), 0.055f);
            const float recessEdge = lineMask(make_float2(hit.x, hit.y), make_float2(-0.92f, 0.28f), make_float2(-0.92f, 1.72f), 0.010f) +
                lineMask(make_float2(hit.x, hit.y), make_float2(0.92f, 0.28f), make_float2(0.92f, 1.72f), 0.010f);
            color = lerp3(color, make_float3(0.015f, 0.015f, 0.014f), recess * 0.42f);
            color = add3(color, mul3(make_float3(0.050f, 0.046f, 0.038f), recessEdge * 0.030f));
        }
        const float soot = expf(-(hit.x * hit.x * 0.82f + hit.z * hit.z * 1.12f)) * smoothstepf(0.36f, 1.92f, hit.y);
        color = lerp3(color, make_float3(0.010f, 0.011f, 0.012f), soot * 0.82f * p.smokeDarkness);
        materialAlbedo = lerp3(materialAlbedo, make_float3(0.030f, 0.032f, 0.034f), soot * 0.75f);
        const float wallGlow = expf(-(hit.x * hit.x * 1.1f + hit.z * hit.z * 1.3f + (hit.y - 0.70f) * (hit.y - 0.70f) * 1.0f)) * glow;
        const float3 wallGlowColor = p.sceneId == 2 ? make_float3(0.020f, 0.060f, 0.18f) : make_float3(0.15f, 0.050f, 0.018f);
        color = add3(color, mul3(wallGlowColor, wallGlow * (p.sceneId == 2 ? 0.035f : 0.090f)));
        if (surface == 3 && hit.x < 0.0f) {
            const float window = rectMask(make_float2(hit.z, hit.y), make_float2(-1.28f, 0.92f), make_float2(0.06f, 0.62f), 0.030f);
            const float glassNoise = 0.55f + 0.25f * sinf(hit.y * 23.0f + hit.z * 15.0f);
            color = lerp3(color, make_float3(0.009f, 0.011f, 0.012f), window * 0.92f);
            color = add3(color, mul3(make_float3(0.10f, 0.12f, 0.13f), window * glassNoise * 0.16f));
        }
    }

    const float3 volumeUv = fireVolumeUvFromWorld(hit);
    const float4 giSample = sampleSceneLight(sceneLightField, p, volumeUv.x, volumeUv.y, volumeUv.z);
    const float sceneShadow = sampleSceneShadow(sceneShadowField, p, volumeUv.x, volumeUv.y, volumeUv.z);
    const float volumeVisibility = volumeShadowRay(hit, sceneLightField, sceneShadowField, p);
    const float3 gatheredIrradiance = gatherSceneIrradiance(hit, surfaceNormal, sceneLightField, sceneShadowField, p);
    const float3 indirect = mul3(add3(mul3(make_float3(giSample.x, giSample.y, giSample.z), 0.42f), gatheredIrradiance), volumeVisibility);
    const float grazingFalloff = surface == 2 ? 0.62f : 1.0f;
    const float contactOcclusion = smoothstepf(0.005f, 0.42f, sceneShadow) * expf(-giSample.w * 0.72f) * (0.30f + volumeVisibility * 0.70f);
    const float irradianceLift = 0.66f + smoothstepf(0.006f, 0.13f, luminance3(indirect)) * 0.72f;
    const float contactWarmth = surface == 1 ? 1.72f : (surface == 2 ? 0.88f : 1.16f);
    color = add3(color, mul3(mul3(indirect, materialAlbedo), materialGiScale * grazingFalloff * contactOcclusion * irradianceLift * contactWarmth));
    const float shadowedSoot = (1.0f - volumeVisibility) * smoothstepf(0.18f, 0.82f, 1.0f - sceneShadow);
    color = lerp3(color, make_float3(0.006f, 0.007f, 0.008f), shadowedSoot * (surface == 2 ? 0.38f : 0.26f));
    const float wallHorizontalEdge = surface == 3 ? roomHalf - fabsf(hit.z) : roomHalf - fabsf(hit.x);
    const float cornerDistance = surface == 1 || surface == 2
        ? fminf(roomHalf - fabsf(hit.x), roomHalf - fabsf(hit.z))
        : fminf(wallHorizontalEdge, fminf(hit.y, ceilingY - hit.y));
    color = mul3(color, 0.84f + smoothstepf(0.0f, 0.54f, cornerDistance) * 0.16f);

    const float grain = (hash21(make_float2(floorf(hit.x * 19.0f + hit.z * 13.0f), floorf(hit.y * 15.0f + p.time * 0.08f))) - 0.5f) * 0.006f;
    color = add3(color, make_float3(grain, grain, grain));
    sourceModelOverlay(uv, cam, p, glow, &color);
    const float fog = smoothstepf(3.8f, 0.2f, bestT);
    const float vignette = smoothstepf(0.78f, 0.20f, sqrtf((uv.x - 0.50f) * (uv.x - 0.50f) + (uv.y - 0.46f) * (uv.y - 0.46f)));
    return mul3(color, (0.12f + fog * 0.56f) * (0.58f + vignette * 0.30f));
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
    const float sourceX = p.sceneId == 2 && p.burnerCenterCount > 0 ? p.burnerCenterX[0] : p.emitterCenterX;
    const float sourceY = p.emitterHeightNorm * 2.03f + 0.02f;
    const float sourceZ = p.sceneId == 2 && p.burnerCenterCount > 0 ? p.burnerCenterZ[0] : p.emitterCenterZ;
    const float3 source = projectPoint(cam, make_float3(sourceX, sourceY, sourceZ));
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
    const float4* sceneLightField,
    const float* sceneShadowField,
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

        for (int i = 0; i < raySteps && trans > 0.018f; ++i) {
            const float t = t0 + (static_cast<float>(i) + rayJitter) * stepT;
            const float3 wp = add3(cam.eye, mul3(rd, t));
            const float fu = saturate((wp.x + 1.05f) / 2.10f);
            const float fv = saturate((wp.y - 0.02f) / 2.03f);
            const float fw = saturate((wp.z + 0.82f) / 1.64f);
            const float domainFade = volumeDomainFade(fu, fv, fw);
            if (domainFade <= 0.001f) {
                continue;
            }
            const float coarseHeat = sampleScalar(heatField, p, fu, fv, fw);
            const float coarseFuel = sampleScalar(fuelField, p, fu, fv, fw);
            const float coarseSoot = sampleScalar(sootField, p, fu, fv, fw);
            const float coarseProgress = sampleScalar(progressField, p, fu, fv, fw);
            const float coarseActive = (coarseHeat + coarseFuel * 0.42f + coarseSoot * 0.34f + coarseProgress * 0.32f) * domainFade;
            if (coarseActive <= 0.00150f) {
                ++i;
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
            const float4 sceneLight = sampleSceneLight(sceneLightField, p, warpedFu, warpedFv, warpedFw);
            const float sceneShadow = sampleSceneShadow(sceneShadowField, p, warpedFu, warpedFv, warpedFw);
            float3 velocity = make_float3(0.0f, 0.0f, 0.0f);
            if (p.renderDebugMode == 6) {
                velocity = sampleVelocity(uField, vField, wField, p, warpedFu, warpedFv, warpedFw);
            }
            const float activeField = (heat + fuel * 0.42f + soot * 0.34f + progress * 0.32f + pyrolysis * 0.18f) * domainFade;
            if (activeField <= 0.0025f) {
                continue;
            }
            debugFuel = fmaxf(debugFuel, domainFade * saturate(fuel * 0.18f + charMass * 0.22f + pyrolysis * 0.30f));
            if (p.renderDebugMode == 6) {
                debugVelocity = fmaxf(debugVelocity, saturate(sqrtf(dot3(velocity, velocity)) * 0.22f));
            }
            const float cellX = 1.0f / static_cast<float>(p.nx);
            const float cellY = 1.0f / static_cast<float>(p.ny);
            const float cellZ = 1.0f / static_cast<float>(p.nz);
            const float gradHeatX = sampleScalar(heatField, p, warpedFu + cellX, warpedFv, warpedFw) - sampleScalar(heatField, p, warpedFu - cellX, warpedFv, warpedFw);
            const float gradHeatY = sampleScalar(heatField, p, warpedFu, warpedFv + cellY, warpedFw) - sampleScalar(heatField, p, warpedFu, warpedFv - cellY, warpedFw);
            const float gradHeatZ = sampleScalar(heatField, p, warpedFu, warpedFv, warpedFw + cellZ) - sampleScalar(heatField, p, warpedFu, warpedFv, warpedFw - cellZ);
            const float frontGradient =
                sqrtf(gradHeatX * gradHeatX + gradHeatY * gradHeatY + gradHeatZ * gradHeatZ) +
                fabsf(fuel - coarseFuel) * 0.62f;
            const float reactionFront = smoothstepf(0.020f, 0.46f, frontGradient * 1.35f + fuel * oxygen * 0.040f + progress * 0.18f + pyrolysis * 0.080f);

            const float fineNoise = fbm3(make_float3(warpedFu * 42.0f + p.time * 0.72f, warpedFv * 54.0f - p.time * 1.28f, warpedFw * 43.0f + p.time * 0.38f));
            const float shearNoise = fbm3(make_float3(warpedFu * 15.0f - p.time * 0.72f, warpedFv * 13.0f - p.time * 1.08f, warpedFw * 17.0f + p.time * 0.32f));
            const float plumeNoise = saturate(fineNoise * 0.58f + shearNoise * 0.42f);
            const float holeNoise = saturate((1.0f - fineNoise) * 0.36f + shearNoise * 0.64f);
            const float lesBreakup = saturate(turbulenceEnergy * 0.48f + progress * 0.28f);
            const float raggedEdge =
                smoothstepf(0.18f, 0.92f, fineNoise * (0.46f + lesBreakup * 0.30f) + shearNoise * 0.38f + plumeNoise * 0.32f + saturate(activeField * 0.08f));
            const float fieldEdge = smoothstepf(0.05f, 2.30f, heat + fuel * 0.32f) * (0.10f + reactionFront * 0.90f);
            const float fieldFilament =
                smoothstepf(0.60f, 1.0f, fineNoise + lesBreakup * 0.10f) *
                smoothstepf(0.38f, 0.92f, shearNoise + (0.72f - fv) * 0.12f + reactionFront * 0.10f) *
                smoothstepf(1.0f, 0.02f, fv) *
                fieldEdge;
            const float sourceSignedV = p.sceneId == 2 ? fv - p.emitterHeightNorm : fv;
            const float sourceAboveV = p.sceneId == 2 ? fmaxf(0.0f, sourceSignedV) : fv;
            const float sourceCellV = 1.0f / static_cast<float>(p.ny);
            const float sourceBelowTolerance = fmaxf(sourceCellV * 0.55f, p.emitterHeightBandNorm * 0.030f);
            const float sourcePlaneGate = p.sceneId == 2
                ? smoothstepf(
                    p.emitterHeightNorm - sourceBelowTolerance,
                    p.emitterHeightNorm + p.emitterHeightBandNorm * 0.03f,
                    fv)
                : 1.0f;
            const float burnerLowJet = p.sceneId == 2 ? smoothstepf(fmaxf(0.012f, p.emitterHeightBandNorm * 0.92f), fmaxf(0.003f, p.emitterHeightBandNorm * 0.12f), fabsf(fv - p.emitterHeightNorm)) * smoothstepf(0.025f, 0.42f, fuel + heat * 0.034f) * smoothstepf(0.42f, 1.0f, oxygen) : 0.0f;
            const float burnerPortJet = p.sceneId == 2 ? burnerLowJet * smoothstepf(0.68f, 0.98f, fineNoise + shearNoise * 0.18f) : 0.0f;
            const float campTongueBias = p.sceneId == 1 ? smoothstepf(0.035f, 0.72f, fuel + pyrolysis * 0.50f + charMass * 0.12f) * smoothstepf(0.76f, 0.035f, fv) : 0.0f;
            const float roomTraySheet = p.sceneId == 0 ? smoothstepf(0.018f, 0.42f, fuel + pyrolysis * 0.72f + charMass * 0.08f) * smoothstepf(0.30f, 0.015f, fv) : 0.0f;
            const float convectiveSheet = smoothstepf(0.42f, 0.88f, shearNoise + heat * 0.040f + plumeNoise * 0.14f + lesBreakup * 0.10f + burnerPortJet * 0.56f + campTongueBias * 0.20f + roomTraySheet * 0.24f) * (p.sceneId == 2 ? smoothstepf(p.emitterHeightNorm + p.emitterHeightBandNorm * 1.20f, p.emitterHeightNorm - p.emitterHeightBandNorm * 0.08f, fv) : smoothstepf(p.sceneId == 1 ? 0.82f : 0.88f, 0.030f, fv)) * fieldEdge;
            const float breakup = smoothstepf(0.34f, 0.88f, fineNoise * 0.48f + shearNoise * 0.42f + holeNoise * 0.24f + heat * 0.026f);
            const float verticalFade = smoothstepf(0.96f, 0.025f, fv);
            const float flameHeightFade = p.sceneId == 2 ? smoothstepf(p.emitterHeightNorm + p.emitterHeightBandNorm * 1.18f, p.emitterHeightNorm - p.emitterHeightBandNorm * 0.05f, fv) : smoothstepf(p.sceneId == 1 ? 0.72f : 0.76f, 0.10f, fv);
            const float lowerWhite = (p.sceneId == 2
                ? smoothstepf(fmaxf(0.012f, p.emitterHeightBandNorm * 0.44f), 0.0f, fabsf(sourceSignedV)) * sourcePlaneGate
                : smoothstepf(0.060f, 0.00f, fv)) *
                smoothstepf(0.05f, 1.30f, pyrolysis + fuel * 0.20f);
            const float tempK = 293.0f + heat * 360.0f + fuel * 44.0f + pyrolysis * 90.0f + fieldFilament * 560.0f + convectiveSheet * 420.0f + lowerWhite * 110.0f + progress * 64.0f;
            const float combustion =
                smoothstepf(740.0f, 1630.0f, tempK) *
                smoothstepf(0.016f, 0.62f, fuel + heat * 0.055f) *
                smoothstepf(0.045f, 0.62f, oxygen) *
                verticalFade *
                flameHeightFade;
            const float thinFront = smoothstepf(0.04f, 0.56f, frontGradient + progress * 0.10f) * smoothstepf(0.02f, 0.92f, reactionFront);
            const float flameSheetTear = smoothstepf(0.52f, 0.88f, holeNoise + shearNoise * 0.18f + lesBreakup * 0.30f + saturate(1.0f - oxygen) * 0.12f);
            const float sheetHole = smoothstepf(0.54f, 0.90f, holeNoise + lesBreakup * 0.26f + saturate(1.0f - oxygen) * 0.12f);
            const float flameSheet = fmaxf(
                smoothstepf(0.55f, 0.94f, fineNoise * 0.46f + shearNoise * 0.44f + plumeNoise * 0.18f + reactionFront * 0.15f + heat * 0.014f - fv * 0.050f) *
                    (1.0f - sheetHole * (0.74f + lesBreakup * 0.12f)) *
                    (1.0f - flameSheetTear * 0.18f),
                smoothstepf(0.18f, 0.030f, sourceAboveV) * sourcePlaneGate * smoothstepf(0.75f, 2.0f, heat) * thinFront * 0.030f);
            const float coherentSheet = saturate(fieldFilament * 0.86f + convectiveSheet * 0.55f + thinFront * 0.74f);
            const float sheetConfinement = saturate(coherentSheet + reactionFront * 0.08f);
            const float roomCoverageBoost = p.sceneId == 0 ? (0.72f + roomTraySheet * 1.24f) : 1.0f;
            float flameDensity = domainFade *
                combustion * reactionFront * flameSheet * (0.010f + fieldFilament * 0.92f + convectiveSheet * 0.24f + thinFront * 1.22f) *
                (0.052f + breakup * 0.78f + raggedEdge * 0.56f + lesBreakup * 0.34f) *
                (0.18f + thinFront * 2.55f) *
                (0.060f + sheetConfinement * 0.94f + burnerPortJet * 0.72f + campTongueBias * 0.34f) *
                flameHeightFade * roomCoverageBoost * sourcePlaneGate;
            if (p.sceneId == 1) {
                const float campHoles = smoothstepf(0.40f, 0.76f, holeNoise + fineNoise * 0.30f + shearNoise * 0.22f);
                const float campTongues = smoothstepf(0.54f, 0.98f, fineNoise * 0.56f + shearNoise * 0.50f + campTongueBias * 0.46f);
                flameDensity *= (0.16f + campTongues * 1.94f) * (1.0f - campHoles * 0.72f);
            }
            const float plumeVoid = smoothstepf(0.54f, 0.90f, holeNoise + fineNoise * 0.26f + shearNoise * 0.22f + fv * 0.20f);
            const float topDissolve = smoothstepf(p.sceneId == 1 ? 0.82f : 0.88f, p.sceneId == 1 ? 0.34f : 0.42f, fv);
            const float raggedPlume = 1.0f - plumeVoid * smoothstepf(0.18f, 0.74f, fv) * 0.96f;
            const float upperPlume =
                smoothstepf(0.14f, 0.48f, fv) *
                smoothstepf(0.030f, 1.20f, sootOptics + soot * 0.42f) *
                (0.025f + fineNoise * 0.035f + shearNoise * 0.034f + plumeNoise * 0.34f + raggedEdge * 0.12f + turbulenceEnergy * 0.035f) *
                topDissolve * raggedPlume;
            const float sceneSmokeScale = p.sceneId == 2 ? 0.035f : (p.sceneId == 1 ? 0.56f : 1.0f);
            const float rawSootDensity = domainFade * sceneSmokeScale * (
                smoothstepf(0.020f, 1.05f, sootOptics + soot * 0.32f) *
                    smoothstepf(0.16f, 0.42f, fv) *
                    (0.028f + fineNoise * 0.040f + shearNoise * 0.052f + plumeNoise * 0.38f + raggedEdge * 0.16f + ash * 0.016f) +
                upperPlume * (0.22f + plumeNoise * 0.30f) + smoothstepf(0.004f, 0.34f, sootOptics) * (0.020f + plumeNoise * 0.034f));
            const float flameFrontMask = saturate(flameDensity * 4.8f + combustion * reactionFront * flameSheet * (0.08f + thinFront * 0.56f + fieldFilament * 0.18f));
            const float emissiveMask = saturate(flameFrontMask);
            const float resolvedFlameSheet = smoothstepf(0.030f, 0.32f, emissiveMask) * smoothstepf(0.035f, 0.72f, oxygen);
            const float smokeOnlyMask = 1.0f - smoothstepf(0.025f, 0.20f, resolvedFlameSheet);
            const float scatterSeparation = saturate(smokeOnlyMask * (1.0f - smoothstepf(0.02f, 0.16f, emissiveMask) * 0.58f));
            const float nearFlameSootCleanout = 1.0f - smoothstepf(0.025f, 0.34f, resolvedFlameSheet) * 0.82f;
            const float smokeOnlyHeight = smoothstepf(0.20f, 0.70f, fv) * (1.0f - smoothstepf(0.02f, 0.20f, emissiveMask));
            const float upperSootNeutrality = smoothstepf(0.18f, 0.78f, fv) * scatterSeparation;
            const float absorptionDensity = rawSootDensity * nearFlameSootCleanout * (1.10f + smokeOnlyHeight * 2.20f + upperSootNeutrality * 2.40f);
            const float scatterDensity = rawSootDensity * scatterSeparation * smoothstepf(0.10f, 0.55f, fv + sootOptics * 0.10f) * (0.24f + (1.0f - smokeOnlyHeight) * 0.34f);

            const float particleRadius = saturate(0.08f + sootOptics * 0.028f + ash * 0.085f + saturate(1.0f - oxygen) * 0.12f);
            const float sootAbsorption = absorptionDensity * (3.10f + particleRadius * 4.60f + sootOptics * 0.70f + upperSootNeutrality * 2.85f) * p.smokeDarkness;
            const float sootScattering = scatterDensity * (0.018f + (1.0f - particleRadius) * 0.050f) * (0.20f + p.smokeGain * 0.10f);
            const float sootExtinction = sootAbsorption + sootScattering;
            const float flameExtinction = flameDensity * (0.12f + (1.0f - resolvedFlameSheet) * 0.12f);
            const float extinction = (sootExtinction + flameExtinction) * stepT;
            const float smokeAlpha = 1.0f - expf(-sootAbsorption * stepT);
            const float scatterAlpha = 1.0f - expf(-sootScattering * stepT);
            const float lightVisibility = sceneShadow * (0.35f + sceneShadow * 0.65f);
            const float3 localIrradiance = make_float3(sceneLight.x, sceneLight.y, sceneLight.z);
            const float sootLoad = saturate(sootOptics * 0.74f + soot * 0.20f + upperPlume * 0.46f);
            const float whiteCore =
                smoothstepf(2450.0f, 3450.0f, tempK) *
                combustion *
                smoothstepf(0.32f, 0.90f, oxygen) *
                smoothstepf(0.72f, 0.02f, fv) *
                (0.02f + thinFront * 0.48f + fieldFilament * 0.18f) *
                (1.0f - smoothstepf(0.16f, 0.74f, sootLoad) * 0.68f);
            const float radiantBase = saturate((tempK - 760.0f) / 2000.0f);
            const float radiantCurve = radiantBase * radiantBase * (0.82f + radiantBase * 0.18f);
            const float radiantPower = radiantCurve * (1.42f + fieldFilament * 3.15f + convectiveSheet * 1.60f + progress * 0.26f + whiteCore * 0.92f);
            const float blackbodyCoreStructure = saturate(whiteCore * (0.080f + fieldFilament * 0.28f + thinFront * 0.32f));
            const float whiteFilament = blackbodyCoreStructure * (0.55f + fineNoise * 0.30f + shearNoise * 0.18f);
            const float orangeEdge = (1.0f - whiteFilament * 0.72f) * thinFront * reactionFront * flameSheet * (0.52f + breakup * 0.95f) * smoothstepf(0.08f, 0.80f, oxygen);
            float3 flameColor = lerp3(make_float3(1.32f, 0.27f, 0.038f), blackbodyColor(tempK), saturate(whiteCore * 0.92f + whiteFilament * 0.82f));
            if (p.sceneId == 2) {
                const float blueBase = burnerPortJet * smoothstepf(0.010f, 0.11f, flameDensity + combustion * 0.18f);
                flameColor = lerp3(make_float3(0.020f, 0.18f, 2.40f), make_float3(0.36f, 0.58f, 1.95f), saturate(whiteCore * 0.34f + blueBase * 0.20f));
            } else if (p.sceneId == 1) {
                flameColor = lerp3(flameColor, make_float3(1.52f, 0.24f, 0.028f), saturate(campTongueBias * (1.0f - whiteCore) * 0.58f));
            }
            float3 flameEmission = mul3(flameColor, flameDensity * radiantPower * stepT * (1.10f + whiteCore * 0.38f));
            if (p.sceneId == 2) {
                flameEmission = mul3(flameEmission, 2.45f);
                flameEmission = add3(flameEmission, mul3(make_float3(0.020f, 0.54f, 9.20f), burnerPortJet * sourcePlaneGate * stepT * 86.00f));
            }
            flameEmission = add3(flameEmission, mul3(make_float3(1.10f, 1.02f, 0.86f), whiteFilament * whiteFilament * flameDensity * radiantPower * stepT * 0.82f));
            flameEmission = add3(flameEmission, mul3(make_float3(1.70f, 0.30f, 0.040f), orangeEdge * flameDensity * radiantPower * stepT * (p.sceneId == 2 ? 0.06f : (p.sceneId == 1 ? 3.20f : 3.10f))));
            flameEmission = add3(flameEmission, mul3(make_float3(1.36f, 0.070f, 0.008f), fieldFilament * (1.0f + flameSheetTear * 0.55f) * flameDensity * radiantPower * stepT * (p.sceneId == 2 ? 0.035f : (p.sceneId == 1 ? 1.55f : 1.10f)) * (1.0f - whiteCore * 0.62f)));
            const float upperSmokeMask = smoothstepf(0.18f, 0.72f, fv) * scatterSeparation;
            const float ashVeil = saturate(ash * 0.014f + smoothstepf(0.30f, 0.88f, fv) * (1.0f - sootLoad) * 0.003f);
            const float3 smokeBlack = make_float3(0.0018f, 0.0020f, 0.0024f);
            const float3 smokeCoal = make_float3(0.008f, 0.0092f, 0.0115f);
            const float3 smokeAsh = make_float3(0.014f, 0.0165f, 0.0210f);
            float3 smokeColor = lerp3(smokeCoal, smokeBlack, sootLoad);
            smokeColor = lerp3(smokeColor, smokeAsh, ashVeil);
            smokeColor = mul3(smokeColor, smokeOnlyMask);
            const float localIrradianceLuma = luminance3(localIrradiance);
            const float warmScatterDamp = 1.0f - upperSootNeutrality * 0.985f;
            const float nearFlameWarmLeak = (1.0f - upperSootNeutrality) * (1.0f - smokeOnlyHeight) * 0.18f;
            const float sceneWarmScatter = p.sceneId == 2 ? 0.002f : (p.sceneId == 1 ? 0.18f : 0.30f);
            const float backScatter = scatterAlpha * lightVisibility * (0.00085f + localIrradianceLuma * 0.0011f * warmScatterDamp + baseGlow * 0.00010f * sceneWarmScatter) * (0.018f + (1.0f - particleRadius) * 0.018f) * scatterSeparation;
            smokeColor = add3(smokeColor, mul3(make_float3(0.010f, 0.012f, 0.016f), backScatter));
            const float scatterGain = scatterAlpha * (0.00046f + lightVisibility * 0.00072f * warmScatterDamp + flameDensity * 0.00008f * sceneWarmScatter + turbulenceEnergy * 0.00018f) * (0.038f + (1.0f - particleRadius) * 0.045f) * scatterSeparation;
            const float sceneScatter = scatterAlpha * scatterSeparation * (0.0065f + (1.0f - particleRadius) * 0.014f) * lightVisibility;
            const float3 neutralScatterLight = make_float3(localIrradianceLuma * 0.052f, localIrradianceLuma * 0.064f, localIrradianceLuma * 0.086f);
            const float3 smokeScatterLight = lerp3(neutralScatterLight, localIrradiance, nearFlameWarmLeak);
            const float coalGlow = smoothstepf(0.004f, 0.18f, charMass) * smoothstepf(0.54f, 0.02f, fv) * (0.070f + pyrolysis * 0.12f + heat * 0.009f);

            debugFlame = fmaxf(debugFlame, saturate(flameDensity * radiantPower * 0.26f));
            debugOpticalDepth = saturate(debugOpticalDepth + sootExtinction * stepT);
            debugTemperature = fmaxf(debugTemperature, saturate((tempK - 520.0f) / 1900.0f));
            accum = add3(accum, mul3(flameEmission, trans));
            accum = add3(accum, mul3(make_float3(1.0f, 0.24f, 0.035f), trans * coalGlow * stepT));
            accum = add3(accum, mul3(smokeColor, trans * scatterGain * smokeOnlyMask));
            accum = add3(accum, mul3(smokeScatterLight, trans * sceneScatter * (0.18f + warmScatterDamp * 0.42f)));
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

    float3 color = accum;
    if (trans > 0.006f) {
        const float3 roomColor = roomBackgroundRay(cam, uv, rd, baseGlow, sceneLightField, sceneShadowField, p);
        color = add3(mul3(roomColor, trans), accum);
    }

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

__device__ float3 cameraResponse(float3 radiance, float exposure) {
    float3 color = acesToneMapPreserveHue(mul3(make_float3(fmaxf(0.0f, radiance.x), fmaxf(0.0f, radiance.y), fmaxf(0.0f, radiance.z)), exposure));
    const float luma = luminance3(color);
    const float toe = smoothstepf(0.000f, 0.055f, luma);
    const float hdrShoulderPreserve = smoothstepf(0.78f, 1.08f, luma);
    color = lerp3(mul3(color, 0.82f), color, toe);
    color = lerp3(color, mul3(color, 1.0f / fmaxf(1.0f, luma / 0.94f)), hdrShoulderPreserve * 0.10f);
    const float blackbodyHighlightLift = smoothstepf(0.56f, 0.90f, luma);
    color = mul3(color, 1.0f + blackbodyHighlightLift * 0.28f);
    return make_float3(
        powf(saturate(color.x), 1.0f / 2.2f),
        powf(saturate(color.y), 1.0f / 2.2f),
        powf(saturate(color.z), 1.0f / 2.2f));
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
    color = cameraResponse(color, p.exposure);

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

__global__ void __launch_bounds__(kCudaBlockThreads, 1) packFp16SurfaceKernel(
    cudaSurfaceObject_t outSurface,
    const float4* hdr,
    SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = p.launchFrameYStart + blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.frameW || y >= p.launchFrameYEnd || y >= p.frameH) {
        return;
    }

    const int pixelIndex = y * p.frameW + x;
    const float4 radiance = hdr[pixelIndex];
    const ushort4 value = make_ushort4(
        halfBits(radiance.x),
        halfBits(radiance.y),
        halfBits(radiance.z),
        halfBits(1.0f));
    surf2Dwrite(value, outSurface, x * static_cast<int>(sizeof(ushort4)), y);
}

__global__ void __launch_bounds__(kCudaBlockThreads, 1) emberHdrKernel(
    float4* hdr,
    const float* heatField,
    const float* charField,
    const float* pyrolysisField,
    const float* turbulenceEnergyField,
    const float* uField,
    const float* vField,
    const float* wField,
    SimParams p) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    const int emberCount = min(max(p.emberCount, 0), kMaxEmberCount);
    if (i >= emberCount || p.renderDebugMode != 0) {
        return;
    }

    const CameraState cam = makeCamera(p);
    const float baseGlow = saturate(sampleScalar(heatField, p, 0.50f, 0.06f, 0.50f) * 0.42f);
    const float sparkGate = smoothstepf(0.02f, 0.30f, baseGlow);
    if (sparkGate <= 0.0001f) {
        return;
    }

    const float seed = static_cast<float>(i);
    const float h0 = hash21(make_float2(seed, 3.7f));
    const float h1 = hash21(make_float2(seed, 9.1f));
    const float h2 = hash21(make_float2(seed, 19.4f));
    const float h3 = hash21(make_float2(seed, 31.6f));
    if (p.sceneId == 1 && h2 > 0.34f) {
        return;
    }
    if (p.sceneId == 2 && h0 > 0.14f) {
        return;
    }
    const float life = fracf(p.time * (0.20f + h2 * 0.18f + (p.sceneId == 2 ? 0.36f : 0.0f)) + h0);
    const float spawnAngle = h0 * 6.2831853f;
    float startX = 0.0f;
    float startZ = 0.0f;
    if (p.sceneId == 2) {
        const float sourceRadius = fmaxf(0.04f, p.emitterRadius);
        const float cx = p.burnerCenterCount > 0 ? p.burnerCenterX[0] : p.emitterCenterX;
        const float cz = p.burnerCenterCount > 0 ? p.burnerCenterZ[0] : p.emitterCenterZ;
        startX = cx + cosf(spawnAngle) * sourceRadius * (0.82f + h1 * 0.18f);
        startZ = cz + sinf(spawnAngle) * sourceRadius * (0.82f + h1 * 0.18f);
    } else if (p.sceneId == 1) {
        const float logA = orientedCapsuleMask(cosf(spawnAngle) * 0.34f, sinf(spawnAngle) * 0.25f, -0.06f, 0.01f, 0.38f, 0.34f, 0.095f);
        const float logB = orientedCapsuleMask(cosf(spawnAngle + 1.7f) * 0.35f, sinf(spawnAngle + 1.7f) * 0.25f, 0.07f, -0.02f, -0.58f, 0.33f, 0.092f);
        const float contactBlend = saturate(logA + logB + h3 * 0.35f);
        const float spawnRadius = lerpf(0.16f, 0.46f, sqrtf(h1));
        startX = cosf(spawnAngle) * spawnRadius * (0.64f + contactBlend * 0.36f);
        startZ = sinf(spawnAngle) * spawnRadius * (0.46f + contactBlend * 0.26f);
    } else {
        const float spawnRadius = 0.48f;
        const float ringBias = sqrtf(h1);
        startX = cosf(spawnAngle) * spawnRadius * ringBias;
        startZ = sinf(spawnAngle) * spawnRadius * ringBias;
    }
    const float startU = saturate((startX / 2.10f) + 0.50f);
    const float startW = saturate((startZ / 1.64f) + 0.50f);
    const float startV = p.sceneId == 2 ? p.emitterHeightNorm : (p.sceneId == 1 ? 0.035f + h2 * 0.055f : 0.045f);
    const float localHeat = sampleScalar(heatField, p, startU, startV, startW);
    const float localChar = sampleScalar(charField, p, startU, startV, startW);
    const float localPyrolysis = sampleScalar(pyrolysisField, p, startU, startV, startW);
    const float localTurbulence = sampleScalar(turbulenceEnergyField, p, startU, startV, startW);
    const float3 localVelocity = sampleVelocity(uField, vField, wField, p, startU, startV, startW);
    const float materialGate = smoothstepf(0.018f, 0.40f, localChar + localPyrolysis * 0.34f + localHeat * 0.075f);
    if (materialGate <= 0.0001f) {
        return;
    }
    const float temperatureK = 620.0f + localHeat * 330.0f + localPyrolysis * 210.0f + localChar * 42.0f;
    const float sceneLift = p.sceneId == 1 ? 0.86f : (p.sceneId == 2 ? 0.16f : 0.80f);
    const float t = life * (p.sceneId == 1 ? 1.24f : (p.sceneId == 2 ? 0.34f : 1.10f));
    const float drag = expf(-t * (p.sceneId == 2 ? 4.8f : 1.35f));
    const float buoyantRise = (0.26f + h3 * 0.62f + localTurbulence * 0.11f) * t * sceneLift;
    const float3 sparkWorld = make_float3(
        startX + (localVelocity.x * 0.34f + (h1 - 0.5f) * 0.20f + p.wind * 0.26f) * t * drag,
        startV * 2.03f + 0.02f + buoyantRise - (0.22f + h2 * 0.16f) * t * t,
        startZ + (localVelocity.z * 0.28f + (h2 - 0.5f) * 0.18f) * t * drag);
    const float prevT = fmaxf(0.0f, t - 0.045f);
    const float prevDrag = expf(-prevT * (p.sceneId == 2 ? 4.8f : 1.35f));
    const float3 prevWorld = make_float3(
        startX + (localVelocity.x * 0.34f + (h1 - 0.5f) * 0.20f + p.wind * 0.26f) * prevT * prevDrag,
        startV * 2.03f + 0.02f + (0.26f + h3 * 0.62f + localTurbulence * 0.11f) * prevT * sceneLift - (0.22f + h2 * 0.16f) * prevT * prevT,
        startZ + (localVelocity.z * 0.28f + (h2 - 0.5f) * 0.18f) * prevT * prevDrag);
    const float3 sparkScreen = projectPoint(cam, sparkWorld);
    const float3 prevScreen = projectPoint(cam, prevWorld);
    if (sparkScreen.z <= 0.0f || sparkScreen.x < -0.05f || sparkScreen.x > 1.05f || sparkScreen.y < -0.05f || sparkScreen.y > 1.05f) {
        return;
    }

    const float emberSize = smoothstepf(720.0f, 1580.0f, temperatureK) * materialGate;
    const float radius = ((p.sceneId == 2 ? 0.00042f : 0.00086f) + h3 * (p.sceneId == 2 ? 0.00042f : 0.00145f)) * (0.72f + emberSize * 0.90f) / fmaxf(0.55f, sparkScreen.z);
    const float centerX = sparkScreen.x * static_cast<float>(p.frameW) - 0.5f;
    const float centerY = sparkScreen.y * static_cast<float>(p.frameH) - 0.5f;
    const float2 rawTrail = sub2(make_float2(sparkScreen.x, sparkScreen.y), make_float2(prevScreen.x, prevScreen.y));
    const float rawTrailLen = sqrtf(dot2(rawTrail, rawTrail));
    const float cappedTrailLen = fminf(rawTrailLen, p.sceneId == 1 ? 0.016f : 0.005f);
    const float2 trailDir = rawTrailLen > 0.000001f ? mul2(rawTrail, 1.0f / rawTrailLen) : make_float2(0.0f, -1.0f);
    const int pad = max(2, static_cast<int>(ceilf((radius + cappedTrailLen) * static_cast<float>(max(p.frameW, p.frameH)) * 3.0f)));
    const int minX = max(0, static_cast<int>(floorf(centerX)) - pad);
    const int maxX = min(p.frameW - 1, static_cast<int>(ceilf(centerX)) + pad);
    const int minY = max(0, static_cast<int>(floorf(centerY)) - pad);
    const int maxY = min(p.frameH - 1, static_cast<int>(ceilf(centerY)) + pad);
    const float3 hotCore = p.sceneId == 2 ? make_float3(0.36f, 0.58f, 1.04f) : make_float3(1.0f, 0.42f, 0.090f);
    const float3 cooled = p.sceneId == 2 ? make_float3(0.055f, 0.10f, 0.18f) : make_float3(0.18f, 0.026f, 0.008f);
    const float cooling = smoothstepf(0.16f, 0.92f, life) * (1.0f - saturate(localHeat * 0.045f));
    const float3 sparkColor = lerp3(hotCore, cooled, cooling);
    const float lifeFade = smoothstepf(1.0f, 0.08f, life) * smoothstepf(0.0f, 0.16f, life) * sparkGate * materialGate * emberSize * (p.sceneId == 2 ? 0.055f : (p.sceneId == 1 ? 0.58f : 0.82f));

    for (int y = minY; y <= maxY; ++y) {
        const float uy = (static_cast<float>(y) + 0.5f) / static_cast<float>(p.frameH);
        for (int x = minX; x <= maxX; ++x) {
            const float ux = (static_cast<float>(x) + 0.5f) / static_cast<float>(p.frameW);
            const float2 d = sub2(make_float2(ux, uy), make_float2(sparkScreen.x, sparkScreen.y));
            const float along = dot2(d, trailDir);
            const float2 acrossVec = sub2(d, mul2(trailDir, along));
            const float across2 = dot2(acrossVec, acrossVec);
            const float streakRadius = radius * (1.0f + cappedTrailLen * 130.0f);
            const float emberCore = expf(-(across2 / fmaxf(0.0000002f, radius * radius) + along * along / fmaxf(0.0000002f, streakRadius * streakRadius)));
            const float emberHalo = expf(-dot2(d, d) / fmaxf(0.0000002f, radius * radius * 8.0f)) * 0.16f;
            const float spark = (emberCore + emberHalo) * lifeFade;
            if (spark > 0.00001f) {
                const int pixelIndex = y * p.frameW + x;
                atomicAdd(&hdr[pixelIndex].x, sparkColor.x * spark);
                atomicAdd(&hdr[pixelIndex].y, sparkColor.y * spark);
                atomicAdd(&hdr[pixelIndex].z, sparkColor.z * spark);
            }
        }
    }
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
    if (p.showGizmos == 0) {
        return;
    }

    const int pixelIndex = y * p.frameW + x;
    float3 color = unpackBgra(frame[pixelIndex]);
    const float2 uv = make_float2(
        (static_cast<float>(x) + 0.5f) / static_cast<float>(p.frameW),
        (static_cast<float>(y) + 0.5f) / static_cast<float>(p.frameH));
    const CameraState cam = makeCamera(p);
    (void)heatField;

    drawGizmos(&color, uv, cam, p);
    frame[pixelIndex] = packBgra(color);
}

void freeDeviceMemory() {
    for (cudaGraphicsResource*& resource : g_d3dFp16Resources) {
        if (resource != nullptr) {
            cudaGraphicsUnregisterResource(resource);
            resource = nullptr;
        }
    }
    g_activeD3DInteropSlot = 0;
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
    cudaFree(g_sceneLight);
    cudaFree(g_sceneLightNext);
    cudaFree(g_sceneShadow);
    for (int slot = 0; slot < kRenderSnapshotSlots; ++slot) {
        cudaFree(g_renderHeat[slot]);
        cudaFree(g_renderFuel[slot]);
        cudaFree(g_renderOxygen[slot]);
        cudaFree(g_renderSoot[slot]);
        cudaFree(g_renderChar[slot]);
        cudaFree(g_renderAsh[slot]);
        cudaFree(g_renderPyrolysis[slot]);
        cudaFree(g_renderProgress[slot]);
        cudaFree(g_renderTurbulenceEnergy[slot]);
        cudaFree(g_renderSootOptics[slot]);
        cudaFree(g_renderU[slot]);
        cudaFree(g_renderV[slot]);
        cudaFree(g_renderW[slot]);
        cudaFree(g_renderSceneLight[slot]);
        cudaFree(g_renderSceneShadow[slot]);
    }
    if (g_stepStartEvent != nullptr) {
        cudaEventDestroy(g_stepStartEvent);
    }
    if (g_afterVelocityEvent != nullptr) {
        cudaEventDestroy(g_afterVelocityEvent);
    }
    if (g_afterReactionEvent != nullptr) {
        cudaEventDestroy(g_afterReactionEvent);
    }
    if (g_afterProjectionEvent != nullptr) {
        cudaEventDestroy(g_afterProjectionEvent);
    }
    if (g_afterLightingEvent != nullptr) {
        cudaEventDestroy(g_afterLightingEvent);
    }
    if (g_afterRaymarchEvent != nullptr) {
        cudaEventDestroy(g_afterRaymarchEvent);
    }
    if (g_afterPackEvent != nullptr) {
        cudaEventDestroy(g_afterPackEvent);
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
    g_sceneLight = nullptr;
    g_sceneLightNext = nullptr;
    g_sceneShadow = nullptr;
    for (int slot = 0; slot < kRenderSnapshotSlots; ++slot) {
        g_renderHeat[slot] = nullptr;
        g_renderFuel[slot] = nullptr;
        g_renderOxygen[slot] = nullptr;
        g_renderSoot[slot] = nullptr;
        g_renderChar[slot] = nullptr;
        g_renderAsh[slot] = nullptr;
        g_renderPyrolysis[slot] = nullptr;
        g_renderProgress[slot] = nullptr;
        g_renderTurbulenceEnergy[slot] = nullptr;
        g_renderSootOptics[slot] = nullptr;
        g_renderU[slot] = nullptr;
        g_renderV[slot] = nullptr;
        g_renderW[slot] = nullptr;
        g_renderSceneLight[slot] = nullptr;
        g_renderSceneShadow[slot] = nullptr;
    }
    g_renderSnapshotFront = 0;
    g_renderSnapshotBack = 1;
    g_renderSnapshotVersion = 0;
    g_haveRenderSnapshot = false;
    g_renderTime = g_time;
    g_stepStartEvent = nullptr;
    g_afterVelocityEvent = nullptr;
    g_afterReactionEvent = nullptr;
    g_afterProjectionEvent = nullptr;
    g_afterLightingEvent = nullptr;
    g_afterRaymarchEvent = nullptr;
    g_afterPackEvent = nullptr;
    g_afterSolveEvent = nullptr;
    g_afterRenderEvent = nullptr;
    g_time = 0.0f;
    g_renderTime = 0.0f;
}

SimParams makeParams(float dt = 1.0f / 60.0f) {
    SimParams params = {};
    params.nx = g_nx;
    params.ny = g_ny;
    params.nz = g_nz;
    params.frameW = g_frameW;
    params.frameH = g_frameH;
    params.lightNx = g_lightNx;
    params.lightNy = g_lightNy;
    params.lightNz = g_lightNz;
    params.dt = dt;
    params.time = g_time;
    params.mouseX = 0.5f;
    params.mouseY = 0.12f;
    params.sceneId = 0;
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
    params.emitterCenterX = 0.0f;
    params.emitterCenterZ = 0.0f;
    params.emitterHeightNorm = 0.0f;
    params.emitterHeightBandNorm = 0.06f;
    params.emitterRadius = 0.48f;
    params.burnerCenterCount = 0;
    params.launchZStart = 0;
    params.launchZEnd = g_nz;
    params.launchFrameYStart = 0;
    params.launchFrameYEnd = g_frameH;
    return params;
}

void updateCameraCache(SimParams& params) {
    const CameraState cam = computeCameraFromSettings(params);
    params.cameraEye = cam.eye;
    params.cameraForward = cam.forward;
    params.cameraRight = cam.right;
    params.cameraUp = cam.up;
    params.cameraTanHalfFov = cam.tanHalfFov;
    params.cameraAspect = cam.aspect;
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

std::size_t scalarByteCount() {
    return static_cast<std::size_t>(g_nx) * static_cast<std::size_t>(g_ny) * static_cast<std::size_t>(g_nz) * sizeof(float);
}

std::size_t uByteCount() {
    return static_cast<std::size_t>(g_nx + 1) * static_cast<std::size_t>(g_ny) * static_cast<std::size_t>(g_nz) * sizeof(float);
}

std::size_t vByteCount() {
    return static_cast<std::size_t>(g_nx) * static_cast<std::size_t>(g_ny + 1) * static_cast<std::size_t>(g_nz) * sizeof(float);
}

std::size_t wByteCount() {
    return static_cast<std::size_t>(g_nx) * static_cast<std::size_t>(g_ny) * static_cast<std::size_t>(g_nz + 1) * sizeof(float);
}

std::size_t lightByteCount() {
    return static_cast<std::size_t>(g_lightNx) * static_cast<std::size_t>(g_lightNy) * static_cast<std::size_t>(g_lightNz) * sizeof(float4);
}

std::size_t shadowByteCount() {
    return static_cast<std::size_t>(g_lightNx) * static_cast<std::size_t>(g_lightNy) * static_cast<std::size_t>(g_lightNz) * sizeof(float);
}

enum class FieldOwner {
    PhysicalScalar,
    OpticalScalar,
    Velocity,
    Lighting
};

struct SnapshotFloatField {
    const char* label;
    float** slots;
    std::size_t bytes;
    FieldOwner owner;
};

struct SnapshotFloat4Field {
    const char* label;
    float4** slots;
    std::size_t bytes;
    FieldOwner owner;
};

struct SnapshotFloatCopy {
    const char* label;
    float** slots;
    const float* source;
    std::size_t bytes;
    FieldOwner owner;
};

struct SnapshotFloat4Copy {
    const char* label;
    float4** slots;
    const float4* source;
    std::size_t bytes;
    FieldOwner owner;
};

bool copyRenderSnapshotField(const char* label, void* dst, const void* src, std::size_t bytes) {
    return check(label, cudaMemcpyAsync(dst, src, bytes, cudaMemcpyDeviceToDevice, 0));
}

bool allocateSnapshotFloatFields(const SnapshotFloatField* fields, int count, int slot) {
    for (int i = 0; i < count; ++i) {
        char label[96];
        std::snprintf(label, sizeof(label), "cudaMalloc render snapshot %s", fields[i].label);
        if (!check(label, cudaMalloc(&fields[i].slots[slot], fields[i].bytes))) {
            return false;
        }
    }
    return true;
}

bool allocateSnapshotFloat4Fields(const SnapshotFloat4Field* fields, int count, int slot) {
    for (int i = 0; i < count; ++i) {
        char label[96];
        std::snprintf(label, sizeof(label), "cudaMalloc render snapshot %s", fields[i].label);
        if (!check(label, cudaMalloc(&fields[i].slots[slot], fields[i].bytes))) {
            return false;
        }
    }
    return true;
}

bool copySnapshotFloatFields(const SnapshotFloatCopy* fields, int count, int slot) {
    for (int i = 0; i < count; ++i) {
        char label[96];
        std::snprintf(label, sizeof(label), "snapshot %s", fields[i].label);
        if (!copyRenderSnapshotField(label, fields[i].slots[slot], fields[i].source, fields[i].bytes)) {
            return false;
        }
    }
    return true;
}

bool copySnapshotFloat4Fields(const SnapshotFloat4Copy* fields, int count, int slot) {
    for (int i = 0; i < count; ++i) {
        char label[96];
        std::snprintf(label, sizeof(label), "snapshot %s", fields[i].label);
        if (!copyRenderSnapshotField(label, fields[i].slots[slot], fields[i].source, fields[i].bytes)) {
            return false;
        }
    }
    return true;
}

bool allocateRenderSnapshotSlot(
    int slot,
    std::size_t scalarBytes,
    std::size_t uBytes,
    std::size_t vBytes,
    std::size_t wBytes,
    std::size_t lightBytes,
    std::size_t shadowBytes) {
    const SnapshotFloatField scalarSnapshots[] = {
        {"heat", g_renderHeat, scalarBytes, FieldOwner::PhysicalScalar},
        {"fuel", g_renderFuel, scalarBytes, FieldOwner::PhysicalScalar},
        {"oxygen", g_renderOxygen, scalarBytes, FieldOwner::PhysicalScalar},
        {"soot", g_renderSoot, scalarBytes, FieldOwner::PhysicalScalar},
        {"char", g_renderChar, scalarBytes, FieldOwner::PhysicalScalar},
        {"ash", g_renderAsh, scalarBytes, FieldOwner::PhysicalScalar},
        {"pyrolysis", g_renderPyrolysis, scalarBytes, FieldOwner::PhysicalScalar},
        {"progress", g_renderProgress, scalarBytes, FieldOwner::PhysicalScalar},
        {"turbulence energy", g_renderTurbulenceEnergy, scalarBytes, FieldOwner::PhysicalScalar},
        {"soot optics", g_renderSootOptics, scalarBytes, FieldOwner::OpticalScalar},
        {"u", g_renderU, uBytes, FieldOwner::Velocity},
        {"v", g_renderV, vBytes, FieldOwner::Velocity},
        {"w", g_renderW, wBytes, FieldOwner::Velocity},
        {"scene shadow", g_renderSceneShadow, shadowBytes, FieldOwner::Lighting},
    };
    const SnapshotFloat4Field vectorSnapshots[] = {
        {"scene light", g_renderSceneLight, lightBytes, FieldOwner::Lighting},
    };
    return allocateSnapshotFloatFields(scalarSnapshots, static_cast<int>(sizeof(scalarSnapshots) / sizeof(scalarSnapshots[0])), slot) &&
        allocateSnapshotFloat4Fields(vectorSnapshots, static_cast<int>(sizeof(vectorSnapshots) / sizeof(vectorSnapshots[0])), slot);
}

bool publishRenderSnapshot() {
    const int slot = g_renderSnapshotBack;
    if (g_renderHeat[slot] == nullptr || g_renderSceneLight[slot] == nullptr) {
        std::snprintf(g_lastError, sizeof(g_lastError), "CUDA render snapshot buffers are not initialized.");
        return false;
    }

    const std::size_t scalarBytes = scalarByteCount();
    const SnapshotFloatCopy scalarCopies[] = {
        {"heat", g_renderHeat, g_heat, scalarBytes, FieldOwner::PhysicalScalar},
        {"fuel", g_renderFuel, g_fuel, scalarBytes, FieldOwner::PhysicalScalar},
        {"oxygen", g_renderOxygen, g_oxygen, scalarBytes, FieldOwner::PhysicalScalar},
        {"soot", g_renderSoot, g_soot, scalarBytes, FieldOwner::PhysicalScalar},
        {"char", g_renderChar, g_char, scalarBytes, FieldOwner::PhysicalScalar},
        {"ash", g_renderAsh, g_ash, scalarBytes, FieldOwner::PhysicalScalar},
        {"pyrolysis", g_renderPyrolysis, g_pyrolysis, scalarBytes, FieldOwner::PhysicalScalar},
        {"progress", g_renderProgress, g_progress, scalarBytes, FieldOwner::PhysicalScalar},
        {"turbulence energy", g_renderTurbulenceEnergy, g_turbulenceEnergy, scalarBytes, FieldOwner::PhysicalScalar},
        {"soot optics", g_renderSootOptics, g_sootOptics, scalarBytes, FieldOwner::OpticalScalar},
        {"u", g_renderU, g_u, uByteCount(), FieldOwner::Velocity},
        {"v", g_renderV, g_v, vByteCount(), FieldOwner::Velocity},
        {"w", g_renderW, g_w, wByteCount(), FieldOwner::Velocity},
        {"scene shadow", g_renderSceneShadow, g_sceneShadow, shadowByteCount(), FieldOwner::Lighting},
    };
    const SnapshotFloat4Copy vectorCopies[] = {
        {"scene light", g_renderSceneLight, g_sceneLight, lightByteCount(), FieldOwner::Lighting},
    };
    if (!copySnapshotFloatFields(scalarCopies, static_cast<int>(sizeof(scalarCopies) / sizeof(scalarCopies[0])), slot) ||
        !copySnapshotFloat4Fields(vectorCopies, static_cast<int>(sizeof(vectorCopies) / sizeof(vectorCopies[0])), slot)) {
        return false;
    }

    g_renderSnapshotFront = slot;
    g_renderSnapshotBack = 1 - slot;
    g_haveRenderSnapshot = true;
    ++g_renderSnapshotVersion;
    return true;
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
    g_lightNx = clampHost((g_nx + 3) / 4, 18, 48);
    g_lightNy = clampHost((g_ny + 3) / 4, 20, 56);
    g_lightNz = clampHost((g_nz + 3) / 4, 16, 36);
    g_time = 0.0f;
    g_renderTime = 0.0f;
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
    const std::size_t lightCount = static_cast<std::size_t>(g_lightNx) * static_cast<std::size_t>(g_lightNy) * static_cast<std::size_t>(g_lightNz);
    const std::size_t lightBytes = lightCount * sizeof(float4);
    const std::size_t shadowBytes = lightCount * sizeof(float);

    if (!check("cudaSetDevice", cudaSetDevice(g_cudaDevice))) {
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
        !check("cudaMalloc scene light", cudaMalloc(&g_sceneLight, lightBytes)) ||
        !check("cudaMalloc scene light next", cudaMalloc(&g_sceneLightNext, lightBytes)) ||
        !check("cudaMalloc scene shadow", cudaMalloc(&g_sceneShadow, shadowBytes))) {
        freeDeviceMemory();
        return false;
    }
    for (int slot = 0; slot < kRenderSnapshotSlots; ++slot) {
        if (!allocateRenderSnapshotSlot(slot, scalarBytes, uBytes, vBytes, wBytes, lightBytes, shadowBytes)) {
            freeDeviceMemory();
            return false;
        }
    }
    if (!check("cudaEventCreate stepStart", cudaEventCreate(&g_stepStartEvent)) ||
        !check("cudaEventCreate afterVelocity", cudaEventCreate(&g_afterVelocityEvent)) ||
        !check("cudaEventCreate afterReaction", cudaEventCreate(&g_afterReactionEvent)) ||
        !check("cudaEventCreate afterProjection", cudaEventCreate(&g_afterProjectionEvent)) ||
        !check("cudaEventCreate afterLighting", cudaEventCreate(&g_afterLightingEvent)) ||
        !check("cudaEventCreate afterRaymarch", cudaEventCreate(&g_afterRaymarchEvent)) ||
        !check("cudaEventCreate afterPack", cudaEventCreate(&g_afterPackEvent)) ||
        !check("cudaEventCreate afterSolve", cudaEventCreate(&g_afterSolveEvent)) ||
        !check("cudaEventCreate afterRender", cudaEventCreate(&g_afterRenderEvent))) {
        freeDeviceMemory();
        return false;
    }

    return fireCudaReset();
}

bool resetSimulationFields(const SimParams& params) {
    if (g_heat == nullptr) {
        std::snprintf(g_lastError, sizeof(g_lastError), "CUDA renderer is not initialized.");
        return false;
    }

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
    const std::size_t lightCount = static_cast<std::size_t>(g_lightNx) * static_cast<std::size_t>(g_lightNy) * static_cast<std::size_t>(g_lightNz);
    if (!check("reset scene light", cudaMemset(g_sceneLight, 0, lightCount * sizeof(float4))) ||
        !check("reset scene light next", cudaMemset(g_sceneLightNext, 0, lightCount * sizeof(float4))) ||
        !check("reset scene shadow", cudaMemset(g_sceneShadow, 0, lightCount * sizeof(float)))) {
        return false;
    }
    g_renderSnapshotFront = 0;
    g_renderSnapshotBack = 1;
    g_renderSnapshotVersion = 0;
    g_haveRenderSnapshot = false;
    g_time = 0.0f;
    g_renderTime = 0.0f;
    g_frameIndex = 0;
    if (!publishRenderSnapshot()) {
        return false;
    }
    return check("reset kernels sync", cudaDeviceSynchronize());
}

bool fireCudaReset() {
    return resetSimulationFields(makeParams());
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

bool stepAndRenderInternal(
    std::uint32_t* bgraPixels,
    const FireSettings& settings,
    FireCudaFrameMetrics* metrics,
    bool writeD3DInterop,
    bool advanceSimulation,
    bool renderOutput) {
    if (g_heat == nullptr || g_frameDevice == nullptr || g_hdrFrameDevice == nullptr) {
        std::snprintf(g_lastError, sizeof(g_lastError), "CUDA renderer is not initialized.");
        return false;
    }
    if (renderOutput && !writeD3DInterop && bgraPixels == nullptr) {
        std::snprintf(g_lastError, sizeof(g_lastError), "Output pixel pointer was null.");
        return false;
    }
    cudaGraphicsResource* activeD3DResource =
        (g_activeD3DInteropSlot >= 0 && g_activeD3DInteropSlot < kMaxD3DInteropSlots)
            ? g_d3dFp16Resources[g_activeD3DInteropSlot]
            : nullptr;
    if (renderOutput && writeD3DInterop && activeD3DResource == nullptr) {
        std::snprintf(g_lastError, sizeof(g_lastError), "D3D11 FP16 interop texture is not registered.");
        return false;
    }
    if (!renderOutput && !advanceSimulation) {
        std::snprintf(g_lastError, sizeof(g_lastError), "Step-only path requires simulation advancement.");
        return false;
    }

    const bool collectMetrics = metrics != nullptr;
    const float stepDt = std::max(0.001f, std::min(settings.dt, 1.0f / 30.0f));
    g_renderTime += stepDt;
    if (advanceSimulation) {
        g_time += stepDt;
    }

    SimParams params = makeParams(stepDt);
    params.time = advanceSimulation ? g_time : g_renderTime;
    params.mouseX = std::max(0.0f, std::min(1.0f, settings.mouseX));
    params.mouseY = std::max(0.0f, std::min(1.0f, settings.mouseY));
    params.leftDown = settings.leftDown;
    params.rightDown = settings.rightDown;
    params.showGizmos = settings.showGizmos;
    params.activeGizmo = settings.activeGizmo;
    params.sceneId = std::max(0, std::min(kSceneCount - 1, settings.sceneId));
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
    params.emitterCenterX = std::max(-1.05f, std::min(1.05f, settings.emitterCenterX));
    params.emitterCenterZ = std::max(-0.82f, std::min(0.82f, settings.emitterCenterZ));
    params.emitterHeightNorm = std::max(0.0f, std::min(0.96f, settings.emitterHeightNorm));
    params.emitterHeightBandNorm = std::max(0.006f, std::min(0.20f, settings.emitterHeightBandNorm));
    params.emitterRadius = std::max(0.035f, std::min(0.80f, settings.emitterRadius));
    params.burnerCenterCount = std::max(0, std::min(4, settings.burnerCenterCount));
    for (int i = 0; i < 4; ++i) {
        params.burnerCenterX[i] = std::max(-1.05f, std::min(1.05f, settings.burnerCenterX[i]));
        params.burnerCenterY[i] = std::max(0.0f, std::min(2.03f, settings.burnerCenterY[i]));
        params.burnerCenterZ[i] = std::max(-0.82f, std::min(0.82f, settings.burnerCenterZ[i]));
    }
    if (params.sceneId == 2 && params.burnerCenterCount > 0) {
        const float burnerExitY = params.burnerCenterY[0] + params.emitterHeightBandNorm * 2.03f * 0.42f;
        params.emitterHeightNorm = std::max(0.0f, std::min(0.96f, (burnerExitY - 0.02f) / 2.03f));
    }
    updateCameraCache(params);

    if (settings.reset != 0 && !resetSimulationFields(params)) {
        return false;
    }

    const dim3 fieldBlock(8, 8, 4);
    const dim3 scalarGrid((g_nx + fieldBlock.x - 1) / fieldBlock.x, (g_ny + fieldBlock.y - 1) / fieldBlock.y, (g_nz + fieldBlock.z - 1) / fieldBlock.z);

    if (collectMetrics && !check("cudaEventRecord step start", cudaEventRecord(g_stepStartEvent))) {
        return false;
    }

    const int velocityMax = std::max(std::max((g_nx + 1) * g_ny * g_nz, g_nx * (g_ny + 1) * g_nz), g_nx * g_ny * (g_nz + 1));
    const dim3 lightBlock(8, 8, 4);
    const dim3 lightGrid = gridFor3d(g_lightNx, g_lightNy, g_lightNz, lightBlock);

    if (advanceSimulation) {
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
        if (collectMetrics && !check("cudaEventRecord after velocity", cudaEventRecord(g_afterVelocityEvent))) {
            return false;
        }

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
        if (collectMetrics && !check("cudaEventRecord after reaction", cudaEventRecord(g_afterReactionEvent))) {
            return false;
        }

        velocityBoundaryKernel<<<(velocityMax + 255) / 256, 256>>>(g_u, g_v, g_w, params);
        divergenceKernel<<<scalarGrid, fieldBlock>>>(g_divergence, g_pressure, g_u, g_v, g_w, params);
        if (!check("projection setup launch", cudaGetLastError())) {
            return false;
        }

        const int pressureParityCells = ((g_nx + 1) / 2) * g_ny * g_nz;
        for (int i = 0; i < kPressureIterations; ++i) {
            sorPressureParityKernel<<<(pressureParityCells + kCudaBlockThreads - 1) / kCudaBlockThreads, kCudaBlockThreads>>>(g_pressure, g_divergence, params, 0, kPressureOmega);
            sorPressureParityKernel<<<(pressureParityCells + kCudaBlockThreads - 1) / kCudaBlockThreads, kCudaBlockThreads>>>(g_pressure, g_divergence, params, 1, kPressureOmega);
        }
        if (!check("pressure SOR launch", cudaGetLastError())) {
            return false;
        }
        subtractPressureKernel<<<scalarGrid, fieldBlock>>>(g_u, g_v, g_w, g_pressure, params);
        velocityWallBoundaryKernel<<<(velocityMax + 255) / 256, 256>>>(g_u, g_v, g_w, params);
        if (!check("pressure subtract launch", cudaGetLastError())) {
            return false;
        }
        if (collectMetrics && !check("cudaEventRecord after projection", cudaEventRecord(g_afterProjectionEvent))) {
            return false;
        }
        if (collectMetrics && !check("cudaEventRecord after solve", cudaEventRecord(g_afterSolveEvent))) {
            return false;
        }

        buildSceneLightKernel<<<lightGrid, lightBlock>>>(
            g_sceneLight,
            g_sceneShadow,
            g_heat,
            g_fuel,
            g_oxygen,
            g_soot,
            g_char,
            g_ash,
            g_pyrolysis,
            g_progress,
            g_sootOptics,
            params);
        propagateSceneLightKernel<<<lightGrid, lightBlock>>>(g_sceneLightNext, g_sceneLight, g_sceneShadow, params, 0.48f, 0.92f);
        propagateSceneLightKernel<<<lightGrid, lightBlock>>>(g_sceneLight, g_sceneLightNext, g_sceneShadow, params, 0.34f, 0.96f);
        if (!check("scene lighting launch", cudaGetLastError())) {
            return false;
        }
        if (!publishRenderSnapshot()) {
            return false;
        }
        if (collectMetrics && !check("cudaEventRecord after lighting", cudaEventRecord(g_afterLightingEvent))) {
            return false;
        }
    } else {
        if (collectMetrics) {
            std::snprintf(g_lastError, sizeof(g_lastError), "Render-only measured path is not supported.");
            return false;
        }
    }

    if (!renderOutput) {
        return true;
    }

    if (!g_haveRenderSnapshot && !publishRenderSnapshot()) {
        return false;
    }
    params.time = g_renderTime;
    const int renderSlot = g_renderSnapshotFront;
    const dim3 frameBlock(16, 16);
    for (int yStart = 0; yStart < g_frameH; yStart += kRenderLaunchRows) {
        const int yEnd = std::min(g_frameH, yStart + kRenderLaunchRows);
        const SimParams slice = withFrameWindow(params, yStart, yEnd);
        renderKernel<<<gridForFrameRows(g_frameW, yEnd - yStart, frameBlock), frameBlock>>>(
            g_hdrFrameDevice,
            g_renderHeat[renderSlot],
            g_renderFuel[renderSlot],
            g_renderOxygen[renderSlot],
            g_renderSoot[renderSlot],
            g_renderChar[renderSlot],
            g_renderAsh[renderSlot],
            g_renderPyrolysis[renderSlot],
            g_renderProgress[renderSlot],
            g_renderTurbulenceEnergy[renderSlot],
            g_renderSootOptics[renderSlot],
            g_renderSceneLight[renderSlot],
            g_renderSceneShadow[renderSlot],
            g_renderU[renderSlot],
            g_renderV[renderSlot],
            g_renderW[renderSlot],
            slice);
    }
    if (!check("renderKernel launch", cudaGetLastError())) {
        return false;
    }
    if (params.emberCount > 0 && params.renderDebugMode == 0) {
        emberHdrKernel<<<(params.emberCount + kCudaBlockThreads - 1) / kCudaBlockThreads, kCudaBlockThreads>>>(
            g_hdrFrameDevice,
            g_renderHeat[renderSlot],
            g_renderChar[renderSlot],
            g_renderPyrolysis[renderSlot],
            g_renderTurbulenceEnergy[renderSlot],
            g_renderU[renderSlot],
            g_renderV[renderSlot],
            g_renderW[renderSlot],
            params);
        if (!check("emberHdrKernel launch", cudaGetLastError())) {
            return false;
        }
    }
    if (collectMetrics && !check("cudaEventRecord after raymarch", cudaEventRecord(g_afterRaymarchEvent))) {
        return false;
    }
    if (writeD3DInterop) {
        if (!check("cudaGraphicsMapResources d3d fp16", cudaGraphicsMapResources(1, &activeD3DResource, 0))) {
            return false;
        }
        cudaArray_t d3dArray = nullptr;
        bool wroteToD3D = check("cudaGraphicsSubResourceGetMappedArray d3d fp16", cudaGraphicsSubResourceGetMappedArray(&d3dArray, activeD3DResource, 0, 0));
        cudaSurfaceObject_t surface = 0;
        if (wroteToD3D) {
            cudaResourceDesc surfaceDesc = {};
            surfaceDesc.resType = cudaResourceTypeArray;
            surfaceDesc.res.array.array = d3dArray;
            wroteToD3D = check("cudaCreateSurfaceObject d3d fp16", cudaCreateSurfaceObject(&surface, &surfaceDesc));
        }
        if (wroteToD3D) {
            for (int yStart = 0; yStart < g_frameH; yStart += kRenderLaunchRows) {
                const int yEnd = std::min(g_frameH, yStart + kRenderLaunchRows);
                const SimParams slice = withFrameWindow(params, yStart, yEnd);
                packFp16SurfaceKernel<<<gridForFrameRows(g_frameW, yEnd - yStart, frameBlock), frameBlock>>>(surface, g_hdrFrameDevice, slice);
            }
            wroteToD3D = check("packFp16SurfaceKernel launch", cudaGetLastError());
        }
        if (surface != 0) {
            wroteToD3D = check("cudaDestroySurfaceObject d3d fp16", cudaDestroySurfaceObject(surface)) && wroteToD3D;
        }
        const bool unmappedD3D = check("cudaGraphicsUnmapResources d3d fp16", cudaGraphicsUnmapResources(1, &activeD3DResource, 0));
        if (!wroteToD3D || !unmappedD3D) {
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
            overlayKernel<<<gridForFrameRows(g_frameW, yEnd - yStart, frameBlock), frameBlock>>>(g_frameDevice, g_renderHeat[renderSlot], slice);
        }
        if (!check("overlayKernel launch", cudaGetLastError())) {
            return false;
        }
    }
    if (collectMetrics && !check("cudaEventRecord after pack", cudaEventRecord(g_afterPackEvent))) {
        return false;
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
        divergenceOnlyKernel<<<scalarGrid, fieldBlock>>>(g_divergenceAfter, g_u, g_v, g_w, params);
        if (!check("post-projection divergence launch", cudaGetLastError())) {
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
            g_sceneLight,
            g_sceneShadow,
            g_divergence,
            g_divergenceAfter,
            params);
        if (!check("metrics accumulation launch", cudaGetLastError())) {
            return false;
        }

        MetricAccumulator deviceMetrics = {};
        if (!check("cudaMemcpy metrics", cudaMemcpy(&deviceMetrics, g_metricsDevice, sizeof(deviceMetrics), cudaMemcpyDeviceToHost))) {
            return false;
        }
        float solveMs = 0.0f;
        float renderMs = 0.0f;
        float velocityMs = 0.0f;
        float reactionMs = 0.0f;
        float projectionMs = 0.0f;
        float lightingMs = 0.0f;
        float raymarchMs = 0.0f;
        float packMs = 0.0f;
        if (!check("cudaEventElapsedTime solve", cudaEventElapsedTime(&solveMs, g_stepStartEvent, g_afterSolveEvent)) ||
            !check("cudaEventElapsedTime render", cudaEventElapsedTime(&renderMs, g_afterSolveEvent, g_afterRenderEvent)) ||
            !check("cudaEventElapsedTime velocity", cudaEventElapsedTime(&velocityMs, g_stepStartEvent, g_afterVelocityEvent)) ||
            !check("cudaEventElapsedTime reaction", cudaEventElapsedTime(&reactionMs, g_afterVelocityEvent, g_afterReactionEvent)) ||
            !check("cudaEventElapsedTime projection", cudaEventElapsedTime(&projectionMs, g_afterReactionEvent, g_afterProjectionEvent)) ||
            !check("cudaEventElapsedTime lighting", cudaEventElapsedTime(&lightingMs, g_afterProjectionEvent, g_afterLightingEvent)) ||
            !check("cudaEventElapsedTime raymarch", cudaEventElapsedTime(&raymarchMs, g_afterLightingEvent, g_afterRaymarchEvent)) ||
            !check("cudaEventElapsedTime pack", cudaEventElapsedTime(&packMs, g_afterRaymarchEvent, g_afterPackEvent))) {
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
        out.gpuVelocityMs = velocityMs;
        out.gpuReactionMs = reactionMs;
        out.gpuProjectionMs = projectionMs;
        out.gpuLightingMs = lightingMs;
        out.gpuRaymarchMs = raymarchMs;
        out.gpuPackMs = packMs;
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
        out.meanSceneLight = static_cast<float>(deviceMetrics.sceneLightSum / std::max(1.0, cellCount));
        out.meanSceneShadow = static_cast<float>(deviceMetrics.sceneShadowSum / std::max(1.0, cellCount));
        out.flameMassProxy = static_cast<float>(deviceMetrics.flameMassProxy);
        out.smokeMassProxy = static_cast<float>(deviceMetrics.smokeMassProxy);
        out.flameSmokeOverlapProxy = static_cast<float>(deviceMetrics.flameSmokeOverlapProxy);
        out.meanVolumetricShadow = static_cast<float>(deviceMetrics.volumetricShadowSum / std::max(1.0, cellCount));
        out.meanRoomIrradiance = static_cast<float>(deviceMetrics.roomIrradianceSum / std::max(1.0, cellCount));
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
    return stepAndRenderInternal(bgraPixels, settings, nullptr, false, true, true);
}

bool fireCudaStepAndRenderMeasured(std::uint32_t* bgraPixels, const FireSettings& settings, FireCudaFrameMetrics* metrics) {
    if (metrics == nullptr) {
        std::snprintf(g_lastError, sizeof(g_lastError), "Metrics output pointer was null.");
        return false;
    }
    return stepAndRenderInternal(bgraPixels, settings, metrics, false, true, true);
}

bool fireCudaSelectDeviceForD3D11(void* d3d11Device) {
    if (d3d11Device == nullptr) {
        std::snprintf(g_lastError, sizeof(g_lastError), "D3D11 device pointer was null.");
        return false;
    }
    auto* device = static_cast<ID3D11Device*>(d3d11Device);
    unsigned int deviceCount = 0;
    int devices[8] = {};
    const cudaError_t err = cudaD3D11GetDevices(&deviceCount, devices, 8, device, cudaD3D11DeviceListAll);
    if (err != cudaSuccess || deviceCount == 0) {
        std::snprintf(g_lastError, sizeof(g_lastError), "D3D11 device has no CUDA-compatible adapter: %s", cudaGetErrorString(err));
        return false;
    }
    g_cudaDevice = devices[0];
    return check("cudaSetDevice for D3D11 interop", cudaSetDevice(g_cudaDevice));
}

bool fireCudaRegisterD3D11Texture(void* d3d11Texture) {
    return fireCudaRegisterD3D11TextureSlot(0, d3d11Texture) && fireCudaSetD3D11TextureSlot(0);
}

bool fireCudaRegisterD3D11TextureSlot(int slot, void* d3d11Texture) {
    if (slot < 0 || slot >= kMaxD3DInteropSlots) {
        std::snprintf(g_lastError, sizeof(g_lastError), "D3D11 texture slot %d is outside the supported interop slot range.", slot);
        return false;
    }
    if (d3d11Texture == nullptr) {
        std::snprintf(g_lastError, sizeof(g_lastError), "D3D11 texture pointer was null.");
        return false;
    }
    if (g_d3dFp16Resources[slot] != nullptr) {
        cudaGraphicsUnregisterResource(g_d3dFp16Resources[slot]);
        g_d3dFp16Resources[slot] = nullptr;
    }
    auto* resource = static_cast<ID3D11Resource*>(d3d11Texture);
    return check(
        "cudaGraphicsD3D11RegisterResource fp16 texture",
        cudaGraphicsD3D11RegisterResource(&g_d3dFp16Resources[slot], resource, cudaGraphicsRegisterFlagsSurfaceLoadStore));
}

bool fireCudaSetD3D11TextureSlot(int slot) {
    if (slot < 0 || slot >= kMaxD3DInteropSlots || g_d3dFp16Resources[slot] == nullptr) {
        std::snprintf(g_lastError, sizeof(g_lastError), "D3D11 texture slot %d is not registered.", slot);
        return false;
    }
    g_activeD3DInteropSlot = slot;
    return true;
}

bool fireCudaStepAndRenderD3D11(const FireSettings& settings) {
    return stepAndRenderInternal(nullptr, settings, nullptr, true, true, true);
}

bool fireCudaStepAndRenderD3D11Measured(const FireSettings& settings, FireCudaFrameMetrics* metrics) {
    if (metrics == nullptr) {
        std::snprintf(g_lastError, sizeof(g_lastError), "Metrics output pointer was null.");
        return false;
    }
    return stepAndRenderInternal(nullptr, settings, metrics, true, true, true);
}

bool fireCudaStepD3D11(const FireSettings& settings) {
    return stepAndRenderInternal(nullptr, settings, nullptr, false, true, false);
}

bool fireCudaRenderD3D11(const FireSettings& settings) {
    return stepAndRenderInternal(nullptr, settings, nullptr, true, false, true);
}

void fireCudaUnregisterD3D11Texture() {
    for (cudaGraphicsResource*& resource : g_d3dFp16Resources) {
        if (resource != nullptr) {
            cudaGraphicsUnregisterResource(resource);
            resource = nullptr;
        }
    }
    g_activeD3DInteropSlot = 0;
}

bool fireCudaSynchronize() {
    return check("cudaDeviceSynchronize", cudaDeviceSynchronize());
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
