#include "fire_cuda.h"

#include <cuda_runtime.h>

#include <algorithm>
#include <cstdio>
#include <cstring>

namespace {

struct SimParams {
    int gridW;
    int gridH;
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
};

float* g_heat = nullptr;
float* g_heatNext = nullptr;
float* g_smoke = nullptr;
float* g_smokeNext = nullptr;
float* g_fuel = nullptr;
float* g_fuelNext = nullptr;
std::uint32_t* g_frameDevice = nullptr;
int g_gridW = 0;
int g_gridH = 0;
int g_frameW = 0;
int g_frameH = 0;
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

__device__ float saturate(float v) {
    return fminf(1.0f, fmaxf(0.0f, v));
}

__device__ float smoothstepf(float edge0, float edge1, float x) {
    const float t = saturate((x - edge0) / (edge1 - edge0));
    return t * t * (3.0f - 2.0f * t);
}

__device__ float lerpf(float a, float b, float t) {
    return a + (b - a) * t;
}

__device__ float fracf(float v) {
    return v - floorf(v);
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
    const float3 target = make_float3(0.0f, 0.70f, 0.0f);
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

__device__ float hash21(float2 p) {
    p = make_float2(
        p.x * 127.1f + p.y * 311.7f,
        p.x * 269.5f + p.y * 183.3f);
    return fracf(sinf(p.x + p.y) * 43758.5453123f);
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

__device__ int fieldIndex(int x, int y, int w) {
    return y * w + x;
}

__device__ float sampleField(const float* field, int w, int h, float u, float v) {
    u = saturate(u);
    v = saturate(v);
    const float fx = u * static_cast<float>(w - 1);
    const float fy = v * static_cast<float>(h - 1);
    const int x0 = static_cast<int>(floorf(fx));
    const int y0 = static_cast<int>(floorf(fy));
    const int x1 = min(x0 + 1, w - 1);
    const int y1 = min(y0 + 1, h - 1);
    const float tx = fx - static_cast<float>(x0);
    const float ty = fy - static_cast<float>(y0);

    const float a = field[fieldIndex(x0, y0, w)];
    const float b = field[fieldIndex(x1, y0, w)];
    const float c = field[fieldIndex(x0, y1, w)];
    const float d = field[fieldIndex(x1, y1, w)];
    return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), ty);
}

__global__ void resetKernel(float* heat, float* smoke, float* fuel, int w, int h) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= w || y >= h) {
        return;
    }
    const int idx = fieldIndex(x, y, w);
    heat[idx] = 0.0f;
    smoke[idx] = 0.0f;
    fuel[idx] = 0.0f;
}

__global__ void updateKernel(
    float* heatOut,
    float* smokeOut,
    float* fuelOut,
    const float* heatIn,
    const float* smokeIn,
    const float* fuelIn,
    SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.gridW || y >= p.gridH) {
        return;
    }

    const float u = (static_cast<float>(x) + 0.5f) / static_cast<float>(p.gridW);
    const float v = (static_cast<float>(y) + 0.5f) / static_cast<float>(p.gridH);

    const float localHeat = heatIn[fieldIndex(x, y, p.gridW)];
    const float curlA = fbm(make_float2(u * 5.0f + p.time * 0.22f, v * 7.0f - p.time * 0.31f));
    const float curlB = fbm(make_float2(u * 12.0f - p.time * 0.35f, v * 10.0f + p.time * 0.19f));
    const float lift = p.dt * (0.11f + localHeat * 0.42f + p.turbulence * 0.10f) * (1.0f - v * 0.38f);
    const float lateral = p.dt * (p.wind * (0.12f + v * 0.32f) + (curlA - 0.5f) * 0.34f * p.turbulence);
    const float shear = (curlB - 0.5f) * p.dt * 0.10f * p.detail;

    const float prevU = u - lateral - shear;
    const float prevV = v - lift;
    float heat = sampleField(heatIn, p.gridW, p.gridH, prevU, prevV);
    float smoke = sampleField(smokeIn, p.gridW, p.gridH, prevU, prevV);
    float fuel = sampleField(fuelIn, p.gridW, p.gridH, prevU, prevV);

    const float logA = expf(-powf((u - 0.36f) / 0.11f, 2.0f) - powf((v - 0.042f) / 0.030f, 2.0f));
    const float logB = expf(-powf((u - 0.50f) / 0.16f, 2.0f) - powf((v - 0.038f) / 0.034f, 2.0f));
    const float logC = expf(-powf((u - 0.64f) / 0.11f, 2.0f) - powf((v - 0.044f) / 0.031f, 2.0f));
    const float emberBed = expf(-powf((u - 0.50f) / 0.36f, 2.0f) - powf((v - 0.030f) / 0.046f, 2.0f));
    const float bedNoise = 0.70f + 0.55f * fbm(make_float2(u * 42.0f + p.time * 0.9f, v * 21.0f));
    const float bed = (logA * 0.50f + logB * 0.62f + logC * 0.50f + emberBed * 0.92f) * bedNoise;

    heat += bed * p.dt * 3.55f * p.intensity;
    fuel += bed * p.dt * 2.35f * p.intensity;
    smoke += bed * p.dt * 0.72f * p.smokeGain;

    if (p.leftDown != 0) {
        const float d2 = powf((u - p.mouseX) / 0.055f, 2.0f) + powf((v - p.mouseY) / 0.055f, 2.0f);
        const float source = expf(-d2);
        heat += source * p.dt * 8.5f;
        fuel += source * p.dt * 4.2f;
        smoke += source * p.dt * 0.25f;
    }

    if (p.rightDown != 0) {
        const float d2 = powf((u - p.mouseX) / 0.075f, 2.0f) + powf((v - p.mouseY) / 0.075f, 2.0f);
        const float source = expf(-d2);
        smoke += source * p.dt * 6.0f;
        heat *= 1.0f - source * p.dt * 1.7f;
    }

    const float reaction = saturate(fuel) * smoothstepf(0.06f, 0.78f, heat + bed * 0.55f);
    heat += reaction * p.dt * 1.08f;
    fuel -= reaction * p.dt * 0.72f;
    smoke += reaction * p.dt * (0.38f + 1.10f * smoothstepf(0.16f, 1.0f, v)) * p.smokeGain;

    const float detailBreakup = 0.82f + 0.33f * fbm(make_float2(u * 20.0f + p.time * 0.55f, v * 24.0f - p.time * 1.2f));
    heat *= detailBreakup;
    heat *= expf(-p.dt * (0.72f + v * 1.22f));
    smoke *= expf(-p.dt * (0.12f + v * 0.05f));
    fuel *= expf(-p.dt * (0.58f + heat * 0.34f));

    smoke += smoothstepf(0.08f, 0.90f, v) * heat * p.dt * 0.20f * p.smokeGain;

    const int idx = fieldIndex(x, y, p.gridW);
    heatOut[idx] = fminf(3.65f, fmaxf(0.0f, heat));
    smokeOut[idx] = fminf(5.0f, fmaxf(0.0f, smoke));
    fuelOut[idx] = fminf(3.0f, fmaxf(0.0f, fuel));
}

__device__ float3 fireColor(float t) {
    t = saturate(t);
    const float3 deepRed = make_float3(0.82f, 0.045f, 0.012f);
    const float3 orange = make_float3(1.62f, 0.34f, 0.030f);
    const float3 yellow = make_float3(2.00f, 0.92f, 0.18f);
    const float3 whiteHot = make_float3(2.35f, 1.78f, 0.86f);
    const float3 blueCore = make_float3(0.22f, 0.42f, 0.95f);

    if (t < 0.18f) {
        return lerp3(deepRed, orange, t / 0.18f);
    }
    if (t < 0.58f) {
        return lerp3(orange, yellow, (t - 0.18f) / 0.40f);
    }
    if (t < 0.90f) {
        return lerp3(yellow, whiteHot, (t - 0.58f) / 0.32f);
    }
    return lerp3(whiteHot, blueCore, (t - 0.90f) / 0.10f);
}

__device__ float3 roomBackground(float2 uv, float glow, float time) {
    const float horizon = 0.60f;
    float3 wall = make_float3(0.072f, 0.078f, 0.084f);
    const float wallLift = expf(-powf((uv.x - 0.50f) / 0.52f, 2.0f) - powf((uv.y - 0.30f) / 0.36f, 2.0f));
    wall = add3(wall, make_float3(wallLift * 0.12f, wallLift * 0.13f, wallLift * 0.14f));
    const float ceiling = smoothstepf(0.30f, 0.02f, uv.y);
    wall = add3(wall, mul3(make_float3(-0.040f, -0.038f, -0.036f), ceiling));
    const float leftWindow = smoothstepf(0.155f, 0.135f, uv.x) * smoothstepf(0.15f, 0.58f, uv.y);
    wall = lerp3(wall, make_float3(0.018f, 0.022f, 0.025f), leftWindow * 0.75f);
    const float roomCorner = smoothstepf(0.012f, 0.003f, fabsf(uv.x - 0.86f)) * smoothstepf(0.18f, 0.64f, uv.y);
    wall = add3(wall, mul3(make_float3(-0.030f, -0.028f, -0.026f), roomCorner));

    float3 floor = make_float3(0.050f, 0.047f, 0.046f);
    const float fy = saturate((uv.y - horizon) / (1.0f - horizon));
    const float perspective = 0.18f + fy * 1.8f;
    const float gx = fabsf(fracf((uv.x - 0.5f) / perspective * 9.0f + 0.5f) - 0.5f);
    const float gy = fabsf(fracf((fy + 0.04f / (perspective + 0.04f)) * 9.0f) - 0.5f);
    const float grout = smoothstepf(0.018f, 0.004f, fminf(gx, gy));
    floor = add3(floor, make_float3(grout * 0.038f, grout * 0.037f, grout * 0.035f));

    const float trayX = smoothstepf(0.405f, 0.355f, fabsf(uv.x - 0.5f));
    const float trayY = smoothstepf(0.875f, 0.825f, uv.y) * smoothstepf(0.700f, 0.735f, uv.y);
    const float trayInside = trayX * trayY;
    floor = lerp3(floor, make_float3(0.026f, 0.023f, 0.021f), trayInside * 0.82f);
    const float trayFront = smoothstepf(0.010f, 0.001f, fabsf(uv.y - 0.845f)) * trayX;
    const float trayBack = smoothstepf(0.009f, 0.001f, fabsf(uv.y - 0.720f)) * trayX;
    const float traySides = smoothstepf(0.010f, 0.001f, fabsf(fabsf(uv.x - 0.5f) - 0.36f)) * trayY;
    floor = add3(floor, mul3(make_float3(0.010f, 0.008f, 0.006f), trayFront + trayBack + traySides));

    const float flameGlow = expf(-powf((uv.x - 0.50f) / 0.34f, 2.0f) - powf((uv.y - 0.78f) / 0.18f, 2.0f)) * glow;
    floor = add3(floor, mul3(make_float3(1.05f, 0.34f, 0.075f), flameGlow * 0.34f));
    wall = add3(wall, mul3(make_float3(0.70f, 0.22f, 0.055f), flameGlow * 0.14f));

    const float grain = (fbm(make_float2(uv.x * 900.0f + time * 0.04f, uv.y * 520.0f)) - 0.5f) * 0.018f;
    float3 color = uv.y < horizon ? wall : floor;
    color = add3(color, make_float3(grain, grain, grain));

    const float dx = uv.x - 0.5f;
    const float dy = uv.y - 0.50f;
    const float vignette = smoothstepf(1.10f, 0.18f, sqrtf(dx * dx + dy * dy));
    return mul3(color, 0.30f + 0.70f * vignette);
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

__device__ float floorGrid(float x, float z, float scale, float width) {
    const float gx = fabsf(fracf(x * scale + 0.5f) - 0.5f);
    const float gz = fabsf(fracf(z * scale + 0.5f) - 0.5f);
    return smoothstepf(width, 0.0f, fminf(gx, gz));
}

__device__ float3 roomBackgroundRay(const CameraState& cam, float2 uv, float3 rd, float glow, float time) {
    const float roomHalf = 2.25f;
    const float ceilingY = 2.15f;
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

    if (surface == 0) {
        return roomBackground(uv, glow, time);
    }

    float3 color = make_float3(0.060f, 0.062f, 0.064f);
    if (surface == 1) {
        color = make_float3(0.045f, 0.041f, 0.039f);
        const float grid = floorGrid(hit.x, hit.z, 4.2f, 0.035f);
        color = add3(color, mul3(make_float3(0.090f, 0.085f, 0.080f), grid * 0.38f));

        const float tray = smoothstepf(0.66f, 0.58f, fabsf(hit.x)) * smoothstepf(0.44f, 0.34f, fabsf(hit.z));
        color = lerp3(color, make_float3(0.020f, 0.017f, 0.014f), tray * 0.80f);
        const float trayEdge =
            smoothstepf(0.025f, 0.004f, fabsf(fabsf(hit.x) - 0.62f)) * smoothstepf(0.43f, 0.34f, fabsf(hit.z)) +
            smoothstepf(0.025f, 0.004f, fabsf(fabsf(hit.z) - 0.39f)) * smoothstepf(0.66f, 0.57f, fabsf(hit.x));
        color = add3(color, mul3(make_float3(0.11f, 0.075f, 0.035f), saturate(trayEdge)));
        const float reflect = expf(-(hit.x * hit.x * 2.1f + hit.z * hit.z * 1.4f)) * glow;
        color = add3(color, mul3(make_float3(1.40f, 0.35f, 0.055f), reflect * 0.20f));
    } else if (surface == 2) {
        color = make_float3(0.034f, 0.033f, 0.032f);
    } else {
        color = make_float3(0.070f, 0.073f, 0.074f);
        const float soot = expf(-(hit.x * hit.x * 1.9f + hit.z * hit.z * 1.9f)) * smoothstepf(0.30f, 1.85f, hit.y);
        color = lerp3(color, make_float3(0.018f, 0.016f, 0.015f), soot * 0.72f);
        const float wallGlow = expf(-(hit.x * hit.x * 1.6f + hit.z * hit.z * 1.6f + (hit.y - 0.75f) * (hit.y - 0.75f) * 1.1f)) * glow;
        color = add3(color, mul3(make_float3(0.78f, 0.22f, 0.045f), wallGlow * 0.16f));
    }

    const float grain = (fbm(make_float2(hit.x * 12.0f + hit.z * 9.0f + time * 0.02f, hit.y * 8.0f + hit.z * 3.0f)) - 0.5f) * 0.014f;
    color = add3(color, make_float3(grain, grain, grain));
    const float fog = smoothstepf(3.8f, 0.2f, bestT);
    return mul3(color, 0.38f + fog * 0.62f);
}

__device__ float lineAlpha(float2 p, float2 a, float2 b, float thickness) {
    const float2 pa = sub2(p, a);
    const float2 ba = sub2(b, a);
    const float h = saturate(dot2(pa, ba) / fmaxf(0.000001f, dot2(ba, ba)));
    const float2 d = sub2(pa, mul2(ba, h));
    const float dist = sqrtf(dot2(d, d));
    return smoothstepf(thickness, thickness * 0.35f, dist);
}

__device__ float ringAlpha(float2 p, float2 c, float radius, float thickness) {
    const float2 d = sub2(p, c);
    const float dist = fabsf(sqrtf(dot2(d, d)) - radius);
    return smoothstepf(thickness, thickness * 0.25f, dist);
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
        const float r = 0.125f / source.z;
        const float a = ringAlpha(uv, c, r, 0.006f) + diskAlpha(uv, c, 0.012f);
        const float3 col = p.activeGizmo == 1 ? make_float3(1.0f, 0.34f, 0.055f) : make_float3(0.45f, 0.18f, 0.055f);
        blendGizmo(color, col, a * 0.85f);
    }

    const float3 smoke = projectPoint(cam, make_float3(-0.42f, 0.78f, 0.0f));
    if (smoke.z > 0.0f) {
        const float2 c = make_float2(smoke.x, smoke.y);
        const float a = ringAlpha(uv, c, 0.060f / smoke.z, 0.004f);
        const float3 col = p.activeGizmo == 2 ? make_float3(0.78f, 0.80f, 0.82f) : make_float3(0.34f, 0.35f, 0.36f);
        blendGizmo(color, col, a * 0.78f);
    }

    const float3 windA3 = projectPoint(cam, make_float3(-0.82f, 0.15f, -0.55f));
    const float3 windB3 = projectPoint(cam, make_float3(-0.82f + p.wind * 0.82f, 0.15f, -0.55f));
    if (windA3.z > 0.0f && windB3.z > 0.0f) {
        const float2 a2 = make_float2(windA3.x, windA3.y);
        const float2 b2 = make_float2(windB3.x, windB3.y);
        const float a = lineAlpha(uv, a2, b2, 0.006f) + diskAlpha(uv, b2, 0.015f);
        const float3 col = p.activeGizmo == 3 ? make_float3(0.05f, 0.85f, 1.0f) : make_float3(0.04f, 0.36f, 0.44f);
        blendGizmo(color, col, a * 0.92f);
    }

    const float3 turb = projectPoint(cam, make_float3(0.70f, 0.30f, -0.40f));
    if (turb.z > 0.0f) {
        const float2 c = make_float2(turb.x, turb.y);
        const float a = ringAlpha(uv, c, (0.040f + p.turbulence * 0.020f) / turb.z, 0.004f);
        const float3 col = p.activeGizmo == 4 ? make_float3(0.92f, 0.36f, 1.0f) : make_float3(0.40f, 0.18f, 0.44f);
        blendGizmo(color, col, a * 0.86f);
    }

    const float2 axisBase = make_float2(0.90f, 0.84f);
    const float2 xAxis = add2(axisBase, mul2(make_float2(dot3(make_float3(1.0f, 0.0f, 0.0f), cam.right), -dot3(make_float3(1.0f, 0.0f, 0.0f), cam.up)), 0.070f));
    const float2 yAxis = add2(axisBase, mul2(make_float2(dot3(make_float3(0.0f, 1.0f, 0.0f), cam.right), -dot3(make_float3(0.0f, 1.0f, 0.0f), cam.up)), 0.070f));
    const float2 zAxis = add2(axisBase, mul2(make_float2(dot3(make_float3(0.0f, 0.0f, 1.0f), cam.right), -dot3(make_float3(0.0f, 0.0f, 1.0f), cam.up)), 0.070f));
    blendGizmo(color, make_float3(1.0f, 0.12f, 0.08f), lineAlpha(uv, axisBase, xAxis, 0.005f));
    blendGizmo(color, make_float3(0.22f, 1.0f, 0.30f), lineAlpha(uv, axisBase, yAxis, 0.005f));
    blendGizmo(color, make_float3(0.20f, 0.48f, 1.0f), lineAlpha(uv, axisBase, zAxis, 0.005f));
}

__global__ void renderKernel(
    std::uint32_t* out,
    const float* heatField,
    const float* smokeField,
    const float* fuelField,
    SimParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.frameW || y >= p.frameH) {
        return;
    }

    const float2 uv = make_float2(
        (static_cast<float>(x) + 0.5f) / static_cast<float>(p.frameW),
        (static_cast<float>(y) + 0.5f) / static_cast<float>(p.frameH));

    const CameraState cam = makeCamera(p);
    const float3 rd = cameraRayDirection(cam, uv);
    const float baseGlow = saturate(sampleField(heatField, p.gridW, p.gridH, 0.50f, 0.06f) * 0.58f);
    float3 color = roomBackgroundRay(cam, uv, rd, baseGlow, p.time);

    float boxNear = 0.0f;
    float boxFar = 0.0f;
    float3 accum = make_float3(0.0f, 0.0f, 0.0f);
    float trans = 1.0f;
    float maxHeat = 0.0f;

    if (intersectBox(cam.eye, rd, make_float3(-0.88f, 0.02f, -0.68f), make_float3(0.88f, 1.92f, 0.68f), &boxNear, &boxFar)) {
        constexpr int kRaySteps = 42;
        const float t0 = fmaxf(0.0f, boxNear);
        const float t1 = fminf(boxFar, t0 + 3.2f);
        const float stepT = (t1 - t0) / static_cast<float>(kRaySteps);

        for (int i = 0; i < kRaySteps; ++i) {
            const float t = t0 + (static_cast<float>(i) + 0.5f) * stepT;
            const float3 wp = add3(cam.eye, mul3(rd, t));
            const float v = saturate((wp.y - 0.02f) / 1.84f);

            const float flameRadius = 0.33f + 0.34f * smoothstepf(0.02f, 0.80f, v);
            const float smokeRadius = 0.45f + 0.72f * smoothstepf(0.05f, 1.00f, v);
            const float radialFlame = sqrtf((wp.x * wp.x + wp.z * wp.z)) / flameRadius;
            const float radialSmoke = sqrtf((wp.x * wp.x + wp.z * wp.z)) / smokeRadius;

            const float swirlNoise = fbm(make_float2(wp.x * 2.8f + wp.z * 4.1f + p.time * 0.24f, v * 7.4f - p.time * 0.42f));
            const float twist = (swirlNoise - 0.5f) * (0.22f + v * 0.52f) * p.turbulence;
            const float advectedX = wp.x + wp.z * (0.18f + twist) + p.wind * v * 0.18f;
            float u = 0.50f + advectedX / (flameRadius * 2.75f);
            u += (fbm(make_float2(wp.z * 8.0f + p.time * 0.75f, v * 13.0f)) - 0.5f) * 0.10f * p.detail;

            float heat = sampleField(heatField, p.gridW, p.gridH, u, v);
            float smoke = sampleField(smokeField, p.gridW, p.gridH, u + wp.z * 0.08f, v);
            float fuel = sampleField(fuelField, p.gridW, p.gridH, u, v);

            const float flameMask = smoothstepf(1.12f, 0.10f, radialFlame);
            const float smokeMask = smoothstepf(1.18f, 0.06f, radialSmoke);
            heat *= flameMask;
            fuel *= flameMask;
            smoke *= smokeMask;
            maxHeat = fmaxf(maxHeat, heat);

            const float lickNoise = fbm(make_float2(u * 34.0f + wp.z * 5.0f + p.time * 2.05f, v * 46.0f - p.time * 2.75f));
            const float filament = smoothstepf(0.58f, 1.0f, lickNoise) * smoothstepf(0.98f, 0.08f, v) * flameMask;
            const float baseFade = smoothstepf(0.010f, 0.082f, v);
            const float flameDensity =
                smoothstepf(0.055f, 1.12f, heat + fuel * 0.30f) *
                smoothstepf(1.00f, 0.08f, v) *
                baseFade *
                (0.30f + 0.90f * lickNoise + filament * 0.55f);
            const float smokeDensity =
                smoothstepf(0.010f, 0.95f, smoke + heat * 0.32f * smoothstepf(0.12f, 0.95f, v)) *
                smoothstepf(0.040f, 0.36f, v) *
                smokeMask *
                (0.58f + 1.08f * swirlNoise);

            const float temp = saturate(heat * 0.34f + fuel * 0.13f + (1.0f - v) * 0.13f + filament * 0.10f);
            float3 emission = mul3(fireColor(temp), flameDensity * stepT * 2.15f);
            emission = add3(emission, mul3(make_float3(1.75f, 0.22f, 0.030f), filament * heat * stepT * 0.46f));

            const float soot = saturate(smokeDensity * (0.86f + p.smokeGain * 0.70f));
            const float3 smokeBright = make_float3(0.38f, 0.37f, 0.36f);
            const float3 smokeDark = make_float3(0.008f, 0.007f, 0.006f);
            const float3 smokeColor = lerp3(smokeBright, smokeDark, smoothstepf(0.08f, 1.05f, smoke + v * 0.35f));

            const float fireAlpha = saturate(flameDensity * stepT * 0.52f);
            const float smokeAlpha = saturate(soot * stepT * 1.28f);
            accum = add3(accum, mul3(emission, trans));
            accum = add3(accum, mul3(smokeColor, trans * smokeAlpha));
            trans *= expf(-(fireAlpha * 0.35f + smokeAlpha * 3.15f));
        }
    }

    color = add3(mul3(color, trans), accum);

    for (int i = 0; i < 56; ++i) {
        const float seed = static_cast<float>(i);
        const float h0 = hash21(make_float2(seed, 3.7f));
        const float h1 = hash21(make_float2(seed, 9.1f));
        const float h2 = hash21(make_float2(seed, 19.4f));
        const float h3 = hash21(make_float2(seed, 31.6f));
        const float age = fracf(p.time * (0.32f + h2 * 0.28f) + h0);
        const float life = age;
        const float spawnX = (h0 - 0.5f) * 0.82f;
        const float spawnZ = (h1 - 0.5f) * 0.46f;
        const float vx = (h1 - 0.5f) * 0.28f + p.wind * 0.48f;
        const float vz = (h2 - 0.5f) * 0.20f;
        const float vy = 1.14f + h3 * 1.15f;
        const float t = life * 1.24f;
        const float3 sparkWorld = make_float3(
            spawnX + vx * t,
            0.05f + vy * t - 0.34f * t * t,
            spawnZ + vz * t);
        const float3 sparkScreen = projectPoint(cam, sparkWorld);
        if (sparkScreen.z > 0.0f && sparkScreen.x > -0.05f && sparkScreen.x < 1.05f && sparkScreen.y > -0.05f && sparkScreen.y < 1.05f) {
            const float2 d = sub2(uv, make_float2(sparkScreen.x, sparkScreen.y));
            const float radius = (0.0022f + h3 * 0.0025f) / fmaxf(0.55f, sparkScreen.z);
            const float spark = expf(-dot2(d, d) / fmaxf(0.0000002f, radius * radius)) * smoothstepf(1.0f, 0.10f, life) * smoothstepf(0.03f, 0.40f, maxHeat);
            const float3 hot = make_float3(2.9f, 0.74f, 0.12f);
            const float3 cooling = make_float3(0.62f, 0.10f, 0.025f);
            color = add3(color, mul3(lerp3(hot, cooling, life), spark * 0.62f));
        }
    }

    const float exposure = 0.92f + baseGlow * 0.30f;
    color = make_float3(
        1.0f - expf(-color.x * exposure),
        1.0f - expf(-color.y * exposure),
        1.0f - expf(-color.z * exposure));

    color = make_float3(
        powf(saturate(color.x), 1.0f / 2.2f),
        powf(saturate(color.y), 1.0f / 2.2f),
        powf(saturate(color.z), 1.0f / 2.2f));

    drawGizmos(&color, uv, cam, p);

    const std::uint32_t r = static_cast<std::uint32_t>(saturate(color.x) * 255.0f);
    const std::uint32_t g = static_cast<std::uint32_t>(saturate(color.y) * 255.0f);
    const std::uint32_t b = static_cast<std::uint32_t>(saturate(color.z) * 255.0f);
    out[y * p.frameW + x] = 0xff000000u | (r << 16) | (g << 8) | b;
}

void freeDeviceMemory() {
    cudaFree(g_heat);
    cudaFree(g_heatNext);
    cudaFree(g_smoke);
    cudaFree(g_smokeNext);
    cudaFree(g_fuel);
    cudaFree(g_fuelNext);
    cudaFree(g_frameDevice);
    g_heat = nullptr;
    g_heatNext = nullptr;
    g_smoke = nullptr;
    g_smokeNext = nullptr;
    g_fuel = nullptr;
    g_fuelNext = nullptr;
    g_frameDevice = nullptr;
}

} // namespace

bool fireCudaInitialize(int frameWidth, int frameHeight, int gridWidth, int gridHeight) {
    fireCudaShutdown();
    g_frameW = frameWidth;
    g_frameH = frameHeight;
    g_gridW = gridWidth;
    g_gridH = gridHeight;
    g_time = 0.0f;
    std::strcpy(g_lastError, "No CUDA error.");

    const std::size_t fieldBytes = static_cast<std::size_t>(gridWidth) * static_cast<std::size_t>(gridHeight) * sizeof(float);
    const std::size_t frameBytes = static_cast<std::size_t>(frameWidth) * static_cast<std::size_t>(frameHeight) * sizeof(std::uint32_t);

    if (!check("cudaSetDevice", cudaSetDevice(0))) {
        return false;
    }
    if (!check("cudaMalloc heat", cudaMalloc(&g_heat, fieldBytes)) ||
        !check("cudaMalloc heatNext", cudaMalloc(&g_heatNext, fieldBytes)) ||
        !check("cudaMalloc smoke", cudaMalloc(&g_smoke, fieldBytes)) ||
        !check("cudaMalloc smokeNext", cudaMalloc(&g_smokeNext, fieldBytes)) ||
        !check("cudaMalloc fuel", cudaMalloc(&g_fuel, fieldBytes)) ||
        !check("cudaMalloc fuelNext", cudaMalloc(&g_fuelNext, fieldBytes)) ||
        !check("cudaMalloc frame", cudaMalloc(&g_frameDevice, frameBytes))) {
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

    const dim3 block(16, 16);
    const dim3 grid((g_gridW + block.x - 1) / block.x, (g_gridH + block.y - 1) / block.y);
    resetKernel<<<grid, block>>>(g_heat, g_smoke, g_fuel, g_gridW, g_gridH);
    resetKernel<<<grid, block>>>(g_heatNext, g_smokeNext, g_fuelNext, g_gridW, g_gridH);
    if (!check("resetKernel launch", cudaGetLastError())) {
        return false;
    }
    return check("resetKernel sync", cudaDeviceSynchronize());
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

bool fireCudaStepAndRender(std::uint32_t* bgraPixels, const FireSettings& settings) {
    if (g_heat == nullptr || g_frameDevice == nullptr) {
        std::snprintf(g_lastError, sizeof(g_lastError), "CUDA renderer is not initialized.");
        return false;
    }
    if (settings.reset != 0 && !fireCudaReset()) {
        return false;
    }

    g_time += settings.dt;
    SimParams params = {};
    params.gridW = g_gridW;
    params.gridH = g_gridH;
    params.frameW = g_frameW;
    params.frameH = g_frameH;
    params.dt = std::max(1.0f / 240.0f, std::min(settings.dt, 1.0f / 25.0f));
    params.time = g_time;
    params.mouseX = std::max(0.0f, std::min(1.0f, settings.mouseX));
    params.mouseY = std::max(0.0f, std::min(1.0f, settings.mouseY));
    params.leftDown = settings.leftDown;
    params.rightDown = settings.rightDown;
    params.showGizmos = settings.showGizmos;
    params.activeGizmo = settings.activeGizmo;
    params.wind = std::max(-1.2f, std::min(1.2f, settings.wind));
    params.turbulence = std::max(0.0f, std::min(2.0f, settings.turbulence));
    params.detail = std::max(0.0f, std::min(2.0f, settings.detail));
    params.smokeGain = std::max(0.0f, std::min(2.0f, settings.smoke));
    params.intensity = std::max(0.0f, std::min(2.0f, settings.intensity));
    params.cameraYaw = settings.cameraYaw;
    params.cameraPitch = std::max(-0.75f, std::min(0.75f, settings.cameraPitch));
    params.cameraDistance = std::max(1.5f, std::min(6.0f, settings.cameraDistance));

    const dim3 fieldBlock(16, 16);
    const dim3 fieldGrid((g_gridW + fieldBlock.x - 1) / fieldBlock.x, (g_gridH + fieldBlock.y - 1) / fieldBlock.y);
    updateKernel<<<fieldGrid, fieldBlock>>>(g_heatNext, g_smokeNext, g_fuelNext, g_heat, g_smoke, g_fuel, params);
    if (!check("updateKernel launch", cudaGetLastError())) {
        return false;
    }

    std::swap(g_heat, g_heatNext);
    std::swap(g_smoke, g_smokeNext);
    std::swap(g_fuel, g_fuelNext);

    const dim3 frameBlock(16, 16);
    const dim3 frameGrid((g_frameW + frameBlock.x - 1) / frameBlock.x, (g_frameH + frameBlock.y - 1) / frameBlock.y);
    renderKernel<<<frameGrid, frameBlock>>>(g_frameDevice, g_heat, g_smoke, g_fuel, params);
    if (!check("renderKernel launch", cudaGetLastError())) {
        return false;
    }

    const std::size_t frameBytes = static_cast<std::size_t>(g_frameW) * static_cast<std::size_t>(g_frameH) * sizeof(std::uint32_t);
    if (!check("cudaMemcpy frame", cudaMemcpy(bgraPixels, g_frameDevice, frameBytes, cudaMemcpyDeviceToHost))) {
        return false;
    }
    return true;
}

void fireCudaShutdown() {
    freeDeviceMemory();
}

const char* fireCudaLastError() {
    return g_lastError;
}
