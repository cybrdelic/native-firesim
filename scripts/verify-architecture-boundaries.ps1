$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
$main = Read-RepoText "src/main.cpp"
$sceneRuntime = Get-Content (Join-Path $root "src/scene_runtime.h") -Raw
$sceneAssets = Get-Content (Join-Path $root "src/scene_assets.cpp") -Raw
$d3dTypes = Get-Content (Join-Path $root "src/d3d_render_types.h") -Raw
$sharedViewport = Get-Content (Join-Path $root "src/shared_viewport.h") -Raw
$workerLifecycle = Get-Content (Join-Path $root "src/worker_lifecycle.h") -Raw
$uiLayout = Get-Content (Join-Path $root "src/ui_layout.h") -Raw
$uiLabels = Get-Content (Join-Path $root "src/ui_labels.h") -Raw
$runtimeState = Get-Content (Join-Path $root "src/runtime_state.h") -Raw
$verify = Get-Content (Join-Path $root "scripts/verify.ps1") -Raw



Require-Text $verify "verify-architecture-boundaries.ps1" "main verification does not run architecture boundary checks"

Require-Text $sceneRuntime "struct SceneEmitterParams" "scene emitter contract escaped scene_runtime"
Require-Text $sceneRuntime "struct SceneInstance" "scene instance contract escaped scene_runtime"
Require-Text $sceneRuntime "struct PlacementCoordinateState" "placement contract escaped scene_runtime"
Forbid-Text $sceneAssets "loadRuntimeSceneMeshCpuData" "removed GLB mesh CPU loading re-entered scene_assets"
Forbid-Text $main "RuntimeSceneMesh" "removed GLB runtime mesh state re-entered main.cpp"
Require-Text $d3dTypes "struct D3DDisplayState" "D3D state contract escaped d3d_render_types"
Require-Text $d3dTypes "struct RenderGraphStats" "render graph stats escaped d3d_render_types"
Require-Text $sharedViewport "struct SharedViewportBuffer" "shared viewport protocol escaped shared_viewport"
Require-Text $sharedViewport "sharedViewportContractMatches" "shared viewport contract matcher is missing"
Require-Text $sharedViewport "initializeSharedViewportBuffer" "shared viewport initialization policy is missing"
Require-Text $sharedViewport "markSharedViewportWorkerStarting" "worker viewport start policy is missing"
Require-Text $workerLifecycle "enum class WorkerLifecycleReason" "worker lifecycle enum escaped worker_lifecycle"
Require-Text $runtimeState "struct CanonicalRuntimeState" "canonical runtime state escaped runtime_state"
Require-Text $uiLayout "constexpr UiRect kViewportRect" "UI layout constants escaped ui_layout"
Require-Text $uiLabels "inline const char* sceneName" "UI/runtime labels escaped ui_labels"

Forbid-Text $main "struct SharedViewportBuffer" "main.cpp reintroduced shared viewport protocol definition"
Forbid-Text $main "struct D3DDisplayState" "main.cpp reintroduced D3D state definition"
Forbid-Text $main "struct SceneEmitterParams" "main.cpp reintroduced scene emitter contract"
Forbid-Text $main "struct SceneInstance" "main.cpp reintroduced scene instance contract"
Forbid-Text $main "struct PlacementCoordinateState" "main.cpp reintroduced placement contract"
Forbid-Text $main "enum class WorkerLifecycleReason" "main.cpp reintroduced worker lifecycle enum"
Forbid-Text $main "struct UiRect" "main.cpp reintroduced UI layout contract"
Forbid-Text $main "std::string readTextFile" "main.cpp reintroduced scene asset file IO"
Forbid-Text $main "jsonObjectForKey" "main.cpp reintroduced JSON object parsing"
Forbid-Text $main "parseJsonFloats" "main.cpp reintroduced JSON float parsing"
Forbid-Text $main "std::max(0, std::min(kSceneCount" "main.cpp reintroduced ad hoc scene clamping"
Forbid-Text $main "g_sharedViewport->magic = kSharedViewportMagic" "main.cpp reintroduced manual shared viewport contract stamping"

Require-Text $main "if (reset) {" "initializeSharedViewport must honor reset requests even when mapped"
Require-Text $main "resetSharedViewportBuffer();" "shared viewport reset path must use central initializer"
Require-Text $main "sharedViewportContractMatches(*g_sharedViewport)" "shared viewport contract checks must use central matcher"
Require-Text $main "markSharedViewportWorkerStarting(*g_sharedViewport" "worker startup must use central shared viewport marker"

Write-Host "architecture boundaries ok"
