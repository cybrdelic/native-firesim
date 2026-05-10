$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
$main = Read-RepoText "src/main.cpp"
$profile = Read-RepoText "scripts/profile-cuda-kernels.ps1"
$summary = Get-Content (Join-Path $root "scripts/summarize-gpu-timings.py") -Raw
$diag = Join-Path $root "out\diagnostics\startup.txt"


Require-Text $main "const double averageCudaMs = averageSubmitMs" "averageCudaMs must report CUDA submit time, not total frame time"
Require-Text $main "std::array<std::pair<const char*, double>, 6> hotspots" "worker benchmark must rank measured CUDA pass hotspots"
Require-Text $main '{"velocity", averageVelocityMs}' "velocity pass must be part of hotspot ranking"
Require-Text $main '{"reaction", averageReactionMs}' "reaction pass must be part of hotspot ranking"
Require-Text $main '{"projection", averageProjectionMs}' "projection pass must be part of hotspot ranking"
Require-Text $main '{"lighting", averageLightingMs}' "lighting pass must be part of hotspot ranking"
Require-Text $main '{"raymarch", averageRaymarchMs}' "raymarch pass must be part of hotspot ranking"
Require-Text $main '{"pack", averagePackMs}' "pack pass must be part of hotspot ranking"
Require-Text $main '\"hotspotRanking\"' "worker benchmark JSON must emit hotspotRanking"
Require-Text $main '\"hotspotPolicy\"' "worker benchmark JSON must emit the no-quality-reduction policy"
Require-Text $profile '[int]$SimEveryFrames = 1' "CUDA profiling must default to the live full-physics cadence"
Require-Text $profile '"--scene=$Scene"' "CUDA profiling must allow scene-specific profiling"
Require-Text $main 'const int benchmarkScene = argumentIntValue(args, "--scene=", 0, 0, kSceneCount - 1)' "worker benchmark must profile the requested scene"
Require-Text $main 'settings.sceneId = benchmarkScene' "worker benchmark settings must not silently fall back to room scene"
Require-Text $main 'fireCudaRegisterD3D11TextureSlot(slot, target.sharedTextures[slot].Get())' "worker benchmark must register the shared texture ring, not a staging texture"
Require-Text $main 'const int publishSlot = i % kSharedFrameSlots' "worker benchmark must rotate publish slots like the live worker"
Require-Text $main 'fireCudaSetD3D11TextureSlot(publishSlot)' "worker benchmark must render into the selected publish slot"
Require-Text $main '\"publishPath\": \"shared-texture-ring-keyed-mutex-handoff\"' "worker benchmark report must name the live publish path"
Forbid-Text $main 'target.context->CopyResource(target.sharedTextures[0].Get(), target.cudaTexture.Get())' "worker benchmark must not publish through a single-slot staging copy"
Require-Text $summary "## Hotspot Ranking" "timing summary must render hotspot ranking"
Require-Text $summary "Hotspot policy" "timing summary must render the hotspot policy"
Require-Text $main "kernelHotspotProfiling=worker benchmark reports true CUDA submit time, publish time, frame time, and sorted measured pass hotspots without quality reduction" "diagnostics kernel hotspot string is missing from source"

if (Test-Path $diag) {
    $diagText = Get-Content $diag -Raw
    Require-Text $diagText "kernelHotspotProfiling=worker benchmark reports true CUDA submit time, publish time, frame time, and sorted measured pass hotspots without quality reduction" "diagnostics do not report kernel hotspot profiling"
}

Write-Host "kernel hotspot gate ok"
