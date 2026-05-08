#pragma once

enum class WorkerLifecycleReason {
    StartRequested,
    CreateProcessFailed,
    RestartBlocked,
    StaleHeartbeatKill,
    StopRequested,
    ForcedTerminate,
    Exited,
    GpuInitFailed,
    InteropFailed,
    RenderFailed,
    CleanExit
};

unsigned long long tickMs();
void appendRuntimeEvent(const char* event, const char* detail = "");
const char* workerLifecycleReasonName(WorkerLifecycleReason reason);
void appendWorkerLifecycleEvent(WorkerLifecycleReason reason, const char* detail = "");
