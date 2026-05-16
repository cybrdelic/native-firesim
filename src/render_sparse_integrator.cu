__device__ SparseBrickProbe sparseRaymarchBrickProbe(
    const BrickMeta* brickMeta,
    int brickNx,
    int brickNy,
    int brickNz,
    float fu,
    float fv,
    float fw,
    const SimParams& p,
    float sparseActiveThreshold) {
    SparseBrickProbe probe = {};
    probe.valid = false;
    probe.active = false;
    probe.activity = 0.0f;

    if (brickMeta == nullptr || brickNx <= 0 || brickNy <= 0 || brickNz <= 0) {
        return probe;
    }

    const int brickX = min(brickNx - 1, max(0, static_cast<int>(fu * static_cast<float>(p.nx)) / kSparseBrickSize));
    const int brickY = min(brickNy - 1, max(0, static_cast<int>(fv * static_cast<float>(p.ny)) / kSparseBrickSize));
    const int brickZ = min(brickNz - 1, max(0, static_cast<int>(fw * static_cast<float>(p.nz)) / kSparseBrickSize));
    const BrickMeta meta = brickMeta[(brickZ * brickNy + brickY) * brickNx + brickX];
    const float brickActivity = fmaxf(meta.emissionMax, fmaxf(meta.extinctionMax, meta.densityMax * 0.20f));
    probe.valid = true;
    probe.activity = brickActivity;
    probe.active = meta.activeMask != 0u || brickActivity > sparseActiveThreshold;
    return probe;
}

__device__ SparseRaymarchSkipDecision sparseRaymarchBrickSkipDecision(
    const BrickMeta* brickMeta,
    int brickNx,
    int brickNy,
    int brickNz,
    float fu,
    float fv,
    float fw,
    const SimParams& p,
    int maxEmptyStride,
    int mediumEmptyStride,
    float sparseActiveThreshold,
    float sparseFineThreshold) {
    SparseRaymarchSkipDecision decision = {};
    decision.skip = false;
    decision.stride = 1;

    if (brickMeta == nullptr || brickNx <= 0 || brickNy <= 0 || brickNz <= 0 ||
        renderDebugModeKeepsSparseVolumeSamples(p.renderDebugMode)) {
        return decision;
    }

    const SparseBrickProbe probe = sparseRaymarchBrickProbe(brickMeta, brickNx, brickNy, brickNz, fu, fv, fw, p, sparseActiveThreshold);
    if (probe.valid && !probe.active) {
        decision.skip = true;
        decision.stride = maxEmptyStride;
        return decision;
    }
    if (probe.valid && probe.activity <= sparseFineThreshold * 0.50f) {
        decision.stride = mediumEmptyStride;
    }
    return decision;
}

__device__ int sparseRaymarchBrickExitStride(
    const BrickMeta* brickMeta,
    int brickNx,
    int brickNy,
    int brickNz,
    float fu,
    float fv,
    float fw,
    float3 worldPosition,
    float3 rayDirection,
    float stepT,
    const SimParams& p,
    int requestedStride) {
    if (brickMeta == nullptr || brickNx <= 0 || brickNy <= 0 || brickNz <= 0 || requestedStride <= 1 || stepT <= 0.0f) {
        return max(1, requestedStride);
    }

    const int brickX = min(brickNx - 1, max(0, static_cast<int>(fu * static_cast<float>(p.nx)) / kSparseBrickSize));
    const int brickY = min(brickNy - 1, max(0, static_cast<int>(fv * static_cast<float>(p.ny)) / kSparseBrickSize));
    const int brickZ = min(brickNz - 1, max(0, static_cast<int>(fw * static_cast<float>(p.nz)) / kSparseBrickSize));
    const BrickMeta meta = brickMeta[(brickZ * brickNy + brickY) * brickNx + brickX];

    float exitDistance = 1.0e20f;
    if (fabsf(rayDirection.x) > 1.0e-5f) {
        const float plane = rayDirection.x > 0.0f ? meta.aabbMax.x : meta.aabbMin.x;
        const float distance = (plane - worldPosition.x) / rayDirection.x;
        if (distance > 1.0e-5f) {
            exitDistance = fminf(exitDistance, distance);
        }
    }
    if (fabsf(rayDirection.y) > 1.0e-5f) {
        const float plane = rayDirection.y > 0.0f ? meta.aabbMax.y : meta.aabbMin.y;
        const float distance = (plane - worldPosition.y) / rayDirection.y;
        if (distance > 1.0e-5f) {
            exitDistance = fminf(exitDistance, distance);
        }
    }
    if (fabsf(rayDirection.z) > 1.0e-5f) {
        const float plane = rayDirection.z > 0.0f ? meta.aabbMax.z : meta.aabbMin.z;
        const float distance = (plane - worldPosition.z) / rayDirection.z;
        if (distance > 1.0e-5f) {
            exitDistance = fminf(exitDistance, distance);
        }
    }

    if (exitDistance >= 1.0e19f) {
        return max(1, requestedStride);
    }
    const int boundaryStride = max(1, static_cast<int>(ceilf(exitDistance / stepT)));
    return max(1, min(requestedStride, boundaryStride));
}
