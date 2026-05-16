#pragma once

enum class FireSimRenderStageOwner {
    SceneSource,
    Simulation,
    BrickMetadata,
    SparseIntegrator,
    LightingCache,
    TemporalReconstruction,
    Present
};

struct FireSimRenderStageContract {
    FireSimRenderStageOwner owner;
    const char* name;
    const char* owns;
    const char* forbidden;
};

constexpr FireSimRenderStageContract kFireSimRenderContracts[] = {
    {
        FireSimRenderStageOwner::SceneSource,
        "SceneSource",
        "fuel identity, emitter geometry, methanol profile, source injection, validation thresholds",
        "camera visibility, transmittance integration, compositing, temporal display policy"
    },
    {
        FireSimRenderStageOwner::Simulation,
        "Simulation",
        "velocity, pressure, transported scalar fields, combustion state, soot/optics fields",
        "display color grading, scene-specific validation decisions, UI presentation"
    },
    {
        FireSimRenderStageOwner::BrickMetadata,
        "BrickMeta",
        "active masks, max density, max temperature, emission bounds, extinction bounds, velocity bounds",
        "scene identity, plume style, source policy, color design, validation thresholds"
    },
    {
        FireSimRenderStageOwner::SparseIntegrator,
        "SparseIntegrator",
        "visibility, transmittance, empty-space skipping, field sampling cadence, radiance compositing",
        "methanol behavior, soot policy, fake plume shaping, validation targets"
    },
    {
        FireSimRenderStageOwner::LightingCache,
        "LightingCache",
        "cached flame-fed radiance, volumetric shadow state, probe/froxel energy reuse",
        "fuel chemistry, source injection, UI display cadence"
    },
    {
        FireSimRenderStageOwner::TemporalReconstruction,
        "Temporal",
        "history validity, reprojection/accumulation policy, fresh-frame and reprojected-frame accounting",
        "simulation stepping, source behavior, validation thresholds"
    },
    {
        FireSimRenderStageOwner::Present,
        "Present",
        "camera response, FP16 D3D presentation, UI overlay ordering, present timing",
        "simulation physics, sparse residency, scene source behavior"
    }
};
