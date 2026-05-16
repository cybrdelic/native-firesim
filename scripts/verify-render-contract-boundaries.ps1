param(
    [switch]$SkipDiagnostics
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")

$contract = Read-RepoText "src\firesim_render_contract.h"
$bricksHeader = Read-RepoText "src\volume_bricks.h"
$bricksImpl = Read-RepoText "src\volume_bricks.cu"
$sparseHeader = Read-RepoText "src\render_sparse_integrator.h"
$sparseImpl = Read-RepoText "src\render_sparse_integrator.cu"
$cuda = Read-RepoText "src\fire_cuda.cu"
$main = Read-RepoText "src\main.cpp"

Require-Text $contract "FireSimRenderStageOwner" "renderer contract header is missing stage ownership enum"
Require-Text $contract "BrickMetadata" "renderer contract does not define brick metadata ownership"
Require-Text $contract "SparseIntegrator" "renderer contract does not define sparse integrator ownership"
Require-Text $contract "methanol behavior" "renderer contract does not forbid source behavior inside the sparse integrator"
Require-Text $contract "validation targets" "renderer contract does not forbid validation ownership inside the sparse integrator"
Require-Text $main "rendererContractHeader=src\\firesim_render_contract.h" "diagnostics no longer expose the renderer contract header"

Require-Text $bricksHeader "struct BrickMeta" "brick metadata struct was not extracted to volume_bricks.h"
Require-Text $bricksHeader "densityMax" "brick metadata must own density bounds"
Require-Text $bricksHeader "temperatureMax" "brick metadata must own temperature bounds"
Require-Text $bricksHeader "emissionMax" "brick metadata must own emission bounds"
Require-Text $bricksHeader "extinctionMax" "brick metadata must own extinction bounds"
Require-Text $bricksImpl "buildBrickMetaKernel" "brick metadata kernel was not extracted to volume_bricks.cu"
Require-Text $cuda '#include "volume_bricks.cu"' "fire_cuda.cu must include the extracted brick metadata implementation"
Forbid-Text $cuda "__global__ void __launch_bounds__(128, 1) buildBrickMetaKernel(" "brick metadata kernel body still lives in fire_cuda.cu"

Require-Text $sparseHeader "SparseRaymarchSkipDecision" "sparse integrator header is missing skip decision type"
Require-Text $sparseImpl "sparseRaymarchBrickSkipDecision" "sparse raymarch skip logic was not extracted"
Require-Text $cuda '#include "render_sparse_integrator.cu"' "fire_cuda.cu must include the extracted sparse integrator implementation"
Require-Text $cuda "sparseRaymarchBrickSkipDecision(" "render kernel must call the extracted sparse skip decision"

$forbiddenTerms = @(
    "methanol",
    "plumeShape",
    "orangeEdge",
    "sootCleanout",
    "tornado",
    "validation",
    "NIST"
)

foreach ($term in $forbiddenTerms) {
    if ($sparseImpl.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "render_sparse_integrator.cu contains scene/source-specific term: $term"
    }
}

if (-not $SkipDiagnostics) {
    $diagPath = Join-Path $script:RepoRoot "out\diagnostics.txt"
    if (-not (Test-Path -LiteralPath $diagPath)) {
        throw "missing out\diagnostics.txt; run .\scripts\verify.ps1 -DiagnosticsOnly first or pass -SkipDiagnostics"
    }
    $diag = Get-Content -LiteralPath $diagPath -Raw
    Require-Text $diag "rendererContractHeader=src\firesim_render_contract.h" "diagnostics do not report renderer contract header"
}

Write-Host "render contract boundaries ok"
