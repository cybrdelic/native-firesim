__global__ void __launch_bounds__(128, 1) buildBrickMetaKernel(
    BrickMeta* brickMeta,
    const float* heatField,
    const float* fuelField,
    const float* sootField,
    const float* progressField,
    const float* sootOpticsField,
    const float* uField,
    const float* vField,
    const float* wField,
    SimParams p,
    int brickNx,
    int brickNy,
    int brickNz) {
    const int bx = blockIdx.x * blockDim.x + threadIdx.x;
    const int by = blockIdx.y * blockDim.y + threadIdx.y;
    const int bz = blockIdx.z * blockDim.z + threadIdx.z;
    if (bx >= brickNx || by >= brickNy || bz >= brickNz) {
        return;
    }

    const int x0 = bx * kSparseBrickSize;
    const int y0 = by * kSparseBrickSize;
    const int z0 = bz * kSparseBrickSize;
    const int x1 = min(p.nx, x0 + kSparseBrickSize);
    const int y1 = min(p.ny, y0 + kSparseBrickSize);
    const int z1 = min(p.nz, z0 + kSparseBrickSize);

    float densityMax = 0.0f;
    float temperatureMax = 0.0f;
    float emissionMax = 0.0f;
    float extinctionMax = 0.0f;
    float velocityMax = 0.0f;
    unsigned int activeMask = 0u;

    for (int z = z0; z < z1; ++z) {
        for (int y = y0; y < y1; ++y) {
            for (int x = x0; x < x1; ++x) {
                const int id = scalarIndexUnchecked(x, y, z, p);
                const float heat = heatField[id];
                const float fuel = fuelField[id];
                const float soot = sootField[id];
                const float progress = progressField[id];
                const float sootOptics = sootOpticsField[id];
                const float density = fmaxf(0.0f, soot * 0.34f + sootOptics + fuel * 0.08f);
                const float temperature = 293.0f + heat * 360.0f + fuel * 44.0f + progress * 64.0f;
                const float emission = fmaxf(0.0f, heat * fuel * 0.028f + progress * 0.18f);
                const float extinction = fmaxf(0.0f, density * (0.80f + sootOptics * 2.20f));
                const float u = uField[uIndex(x, y, z, p)];
                const float v = vField[vIndex(x, y, z, p)];
                const float w = wField[wIndex(x, y, z, p)];
                const float velocity = sqrtf(u * u + v * v + w * w);
                densityMax = fmaxf(densityMax, density);
                temperatureMax = fmaxf(temperatureMax, temperature);
                emissionMax = fmaxf(emissionMax, emission);
                extinctionMax = fmaxf(extinctionMax, extinction);
                velocityMax = fmaxf(velocityMax, velocity);
                if (density > 0.0020f || emission > 0.0020f || progress > 0.010f) {
                    const int localX = (x - x0) >> 1;
                    const int localY = (y - y0) >> 1;
                    const int localZ = (z - z0) >> 1;
                    const int maskBit = min(31, (localZ * 4 + localY) * 4 + localX);
                    activeMask |= 1u << maskBit;
                }
            }
        }
    }

    const int brickIndex = (bz * brickNy + by) * brickNx + bx;
    BrickMeta meta;
    meta.activeMask = activeMask;
    meta.densityMax = densityMax;
    meta.temperatureMax = temperatureMax;
    meta.emissionMax = emissionMax;
    meta.extinctionMax = extinctionMax;
    meta.velocityMax = velocityMax;
    meta.aabbMin = make_float3(
        (static_cast<float>(x0) / static_cast<float>(p.nx)) * 2.10f - 1.05f,
        (static_cast<float>(y0) / static_cast<float>(p.ny)) * kFireDomainHeightMeters + kRenderVolumeFloorMeters,
        (static_cast<float>(z0) / static_cast<float>(p.nz)) * 1.64f - 0.82f);
    meta.aabbMax = make_float3(
        (static_cast<float>(x1) / static_cast<float>(p.nx)) * 2.10f - 1.05f,
        (static_cast<float>(y1) / static_cast<float>(p.ny)) * kFireDomainHeightMeters + kRenderVolumeFloorMeters,
        (static_cast<float>(z1) / static_cast<float>(p.nz)) * 1.64f - 0.82f);
    brickMeta[brickIndex] = meta;
}
