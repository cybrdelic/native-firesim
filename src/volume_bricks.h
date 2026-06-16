#pragma once

struct BrickMeta {
    unsigned int activeMask;
    float densityMax;
    float temperatureMax;
    float emissionMax;
    float extinctionMax;
    float velocityMax;
    float3 aabbMin;
    float3 aabbMax;
};

