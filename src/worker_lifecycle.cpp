#include "worker_lifecycle.h"

#include <windows.h>

#include <cstdio>
#include <fstream>

unsigned long long tickMs() {
    return static_cast<unsigned long long>(GetTickCount64());
}

void appendRuntimeEvent(const char* event, const char* detail) {
    CreateDirectoryA("out", nullptr);
    std::ofstream log("out\\worker-events.log", std::ios::app | std::ios::binary);
    if (!log) {
        return;
    }
    log << tickMs() << "," << event << "," << detail << "\n";
}

const char* workerLifecycleReasonName(WorkerLifecycleReason reason) {
    switch (reason) {
    case WorkerLifecycleReason::StartRequested: return "start-requested";
    case WorkerLifecycleReason::CreateProcessFailed: return "createprocess-failed";
    case WorkerLifecycleReason::RestartBlocked: return "restart-blocked";
    case WorkerLifecycleReason::StaleHeartbeatKill: return "stale-heartbeat-kill";
    case WorkerLifecycleReason::StopRequested: return "stop-requested";
    case WorkerLifecycleReason::ForcedTerminate: return "forced-terminate";
    case WorkerLifecycleReason::Exited: return "exited";
    case WorkerLifecycleReason::GpuInitFailed: return "gpu-init-failed";
    case WorkerLifecycleReason::InteropFailed: return "interop-failed";
    case WorkerLifecycleReason::RenderFailed: return "render-failed";
    case WorkerLifecycleReason::CleanExit: return "clean-exit";
    }
    return "unknown";
}

void appendWorkerLifecycleEvent(WorkerLifecycleReason reason, const char* detail) {
    char event[96] = {};
    std::snprintf(event, sizeof(event), "worker-lifecycle:%s", workerLifecycleReasonName(reason));
    appendRuntimeEvent(event, detail);
}
