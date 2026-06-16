#pragma once

struct SparseRaymarchSkipDecision {
    bool skip;
    int stride;
    bool brickExitBounded;
};

struct SparseBrickProbe {
    bool valid;
    bool active;
    float activity;
};
