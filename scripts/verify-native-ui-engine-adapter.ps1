$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")

$root = Split-Path -Parent $PSScriptRoot
$cmake = Read-RepoText "CMakeLists.txt"
$main = Read-RepoText "src/main.cpp"
$adapterHeader = Read-RepoText "src/firesim_ui_adapter.h"
$adapterCpp = Read-RepoText "src/firesim_ui_adapter.cpp"
$launcher = Read-RepoText "launch-firesim.ps1"
$nativeUiCmake = Get-Content "C:\Users\alexf\projects\native-ui-engine\CMakeLists.txt" -Raw
$nativeUiPrimitives = Get-Content "C:\Users\alexf\projects\native-ui-engine\include\ui_primitives.h" -Raw
$nativeUiCanvas = Get-Content "C:\Users\alexf\projects\native-ui-engine\include\ui_canvas.h" -Raw
$nativeUiHud = Get-Content "C:\Users\alexf\projects\native-ui-engine\include\ui_hud_scene.h" -Raw
$nativeUiSkinAtlas = Get-Content "C:\Users\alexf\projects\native-ui-engine\include\ui_skin_atlas.h" -Raw
$diag = Join-Path $root "out\diagnostics.txt"
$snapshot = Join-Path $root "out\native-ui-snapshot.bmp"

Require-Text $cmake 'NATIVE_UI_ENGINE_DIR "C:/Users/alexf/projects/native-ui-engine"' "CMake does not point at the shared native-ui-engine repository"
Require-Text $cmake 'add_subdirectory("${NATIVE_UI_ENGINE_DIR}" "${CMAKE_BINARY_DIR}/native-ui-engine")' "CMake does not consume native-ui-engine as a sibling project"
Require-Text $cmake "alexf_native_ui_canvas_win32" "NativeFireSim does not link the native UI engine canvas target"
Require-Text $nativeUiCmake "src/ui_primitives.c" "native-ui-engine core does not build backend-neutral UI primitives"
Require-Text $nativeUiCmake "src/ui_canvas.c" "native-ui-engine core does not build the engine-owned BGRA canvas renderer"
Require-Text $nativeUiCmake "src/ui_hud_scene.c" "native-ui-engine core does not build HUD scene metadata"
Require-Text $nativeUiCmake "src/ui_skin_atlas.c" "native-ui-engine core does not build generated skin atlas support"
Require-Text $nativeUiPrimitives "ui_chrome_surface" "native-ui-engine does not expose chrome surface primitives"
Require-Text $nativeUiPrimitives "ui_icon_primitives" "native-ui-engine does not expose engine-owned icon primitives"
Require-Text $nativeUiPrimitives "ui_skin_pack" "native-ui-engine does not expose skin packs"
Require-Text $nativeUiPrimitives "ui_surface_program_for_skin" "native-ui-engine does not expose surface programs"
Require-Text $nativeUiPrimitives "ui_visual_palette" "native-ui-engine does not expose visual palettes"
Require-Text $nativeUiCanvas "ui_canvas_draw_material_surface" "native-ui-engine does not expose engine-owned surface rasterization"
Require-Text $nativeUiCanvas "ui_canvas_set_skin" "native-ui-engine canvas does not accept engine skin/surface programs"
Require-Text $nativeUiCanvas "ui_canvas_draw_text" "native-ui-engine does not expose engine-owned text rasterization"
Require-Text $nativeUiCanvas "ui_canvas_text_width" "native-ui-engine does not expose engine-owned text measurement"
Require-Text $nativeUiHud "ui_hud_scene_begin" "native-ui-engine does not expose HUD scene begin"
Require-Text $nativeUiHud "ui_hud_add_part" "native-ui-engine does not expose HUD part registration"
Require-Text $nativeUiSkinAtlas "ui_skin_atlas_generate" "native-ui-engine does not expose generated skin atlas support"
Require-Text $nativeUiCmake "gdi32" "native-ui-engine core does not link native Windows text rasterization support"
Require-Text $adapterHeader "FireUiSurfaceRole" "FireSim native UI adapter role contract is missing"
Require-Text $adapterCpp '#include "ui_engine.h"' "FireSim native UI adapter does not include the native UI engine"
Require-Text $adapterCpp '#include "ui_primitives.h"' "FireSim native UI adapter does not include native UI primitives"
Require-Text $adapterCpp '#include "ui_hud_scene.h"' "FireSim native UI adapter does not include native UI HUD scene metadata"
Require-Text $adapterCpp '#include "ui_skin_atlas.h"' "FireSim native UI adapter does not include native UI skin atlas support"
Require-Text $adapterCpp "UiSkinPack" "FireSim native UI adapter does not create a native UI skin pack"
Require-Text $adapterCpp "UiHudScene" "FireSim native UI adapter does not own native UI HUD scene metadata"
Require-Text $adapterCpp "UiSkinAtlas" "FireSim native UI adapter does not own a native UI skin atlas"
Require-Text $adapterCpp "ui_skin_pack" "FireSim native UI adapter does not resolve a native UI skin pack"
Require-Text $adapterCpp "ui_skin_atlas_generate" "FireSim native UI adapter does not generate a native UI skin atlas"
Require-Text $adapterCpp "ui_visual_palette" "FireSim native UI adapter does not consume native UI visual palettes"
Require-Text $adapterCpp "ui_skin_material_recipe" "FireSim native UI adapter does not consume native UI material recipes"
Require-Text $adapterCpp "ui_skin_geometry_recipe" "FireSim native UI adapter does not consume native UI geometry recipes"
Require-Text $adapterCpp "ui_surface_program_for_skin" "FireSim native UI adapter does not consume native UI surface programs"
Require-Text $adapterCpp "ui_hud_scene_begin" "FireSim native UI adapter does not begin native UI HUD scenes"
Require-Text $adapterCpp "ui_hud_add_part" "FireSim native UI adapter does not register controls as HUD parts"
Require-Text $adapterCpp "UiFrameGraph" "FireSim native UI adapter does not use the native UI frame graph"
Require-Text $adapterCpp "ui_node_register" "FireSim native UI adapter does not register UI nodes"
Require-Text $adapterCpp "ui_field_sample" "FireSim native UI adapter does not use native UI interaction fields"
Require-Text $adapterCpp "ui_material_resolve" "FireSim native UI adapter does not use native UI material resolution"
Require-Text $adapterCpp "ui_chrome_surface" "FireSim native UI adapter does not resolve engine chrome surface primitives"
Require-Text $adapterCpp "ui_chrome_icon" "FireSim native UI adapter does not request engine-owned icons"
Require-Text $adapterCpp "ui_icon_primitives" "FireSim native UI adapter does not expose engine icon primitives"
Require-Text $adapterCpp '#include "ui_canvas.h"' "FireSim native UI adapter does not include the native UI canvas renderer"
Require-Text $adapterCpp "ui_canvas_set_skin" "FireSim native UI adapter does not pass engine skin/surface programs to the canvas"
Require-Text $adapterCpp "ui_canvas_draw_material_surface" "FireSim native UI adapter does not delegate surface drawing to native-ui-engine"
Require-Text $adapterCpp "ui_canvas_draw_icon" "FireSim native UI adapter does not delegate icon drawing to native-ui-engine"
Require-Text $adapterCpp "ui_canvas_draw_text" "FireSim native UI adapter does not delegate text drawing to native-ui-engine"
Require-Text $adapterCpp "UI_CHROME_SLIDER_FILL" "FireSim native UI adapter does not route slider fill through native-ui-engine"
Require-Text $main "fireUiBeginFrame" "FireSim overlay composition does not begin a native UI frame"
Require-Text $main "fireUiResolveSurface" "FireSim overlay controls do not resolve through the native UI adapter"
Require-Text $main "fireUiPaintSurface" "FireSim overlay surfaces do not delegate painting to native-ui-engine"
Require-Text $main "fireUiDrawIcon" "FireSim overlay does not delegate icon drawing to native-ui-engine"
Require-Text $main "fireUiDrawText" "FireSim overlay text does not delegate text rasterization to native-ui-engine"
Forbid-Text $main "Glyph glyphFor" "FireSim reintroduced its own bitmap glyph table instead of native-ui-engine text rasterization"
Forbid-Text $main "insideNativeShape" "FireSim reintroduced its own notched-surface shape test instead of native-ui-engine surface rasterization"
Forbid-Text $main "fillNativeShapeVerticalGradient" "FireSim reintroduced its own notched-surface fill instead of native-ui-engine surface rasterization"
Forbid-Text $main "strokeNativeShape" "FireSim reintroduced its own notched-surface stroke instead of native-ui-engine surface rasterization"
Require-Text $main "--native-ui-snapshot" "FireSim does not expose a safe native UI visual proof snapshot"
Require-Text $main "nativeUiEngine=" "diagnostics do not report the native UI engine"
Require-Text $main "nativeUiAdapter=FireSim overlay panels/buttons/sliders resolve through native UI frame graph, HUD scene metadata, skin packs, skin atlas slots, surface programs, engine icon glyphs, and native-ui-engine canvas rasterization" "diagnostics do not report the native UI adapter contract"
Require-Text $launcher "Test-NativeFireSimBuildFresh" "Desktop launcher does not rebuild when source changes"
Require-Text $launcher "native-ui-engine" "Desktop launcher freshness check does not include the shared native UI engine"
Require-Text $launcher "launcher-build.log" "Desktop launcher rebuild failures do not leave a build log"

if (Test-Path $diag) {
    $diagInfo = Get-Item $diag
    $sourceNewest = @(
        Get-Item (Join-Path $root "CMakeLists.txt")
        Get-Item (Join-Path $root "src\main.cpp")
        Get-Item (Join-Path $root "src\firesim_ui_adapter.cpp")
    ) | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1

    if ($diagInfo.LastWriteTimeUtc -ge $sourceNewest.LastWriteTimeUtc) {
        $diagText = Get-Content $diag -Raw
        Require-Text $diagText "nativeUiEngine=alexf_native_ui_core" "diagnostics did not confirm the native UI engine core target"
        Require-Text $diagText "nativeUiEnginePath=C:/Users/alexf/projects/native-ui-engine" "diagnostics did not confirm the native UI engine path"
        Require-Text $diagText "nativeUiFeatures=notched material surfaces, cut-corner chrome, engine-owned icon primitives, cached native font atlas, hover and pressure fields, Tech Cybernetic skin pack, UiHudScene parts, UiSkinAtlas generation, UiSurfaceProgram layer stack" "diagnostics did not confirm visible native UI features"
    } else {
        Write-Host "native UI diagnostics are stale; source gate only"
    }
}

if (Test-Path $snapshot) {
    $size = (Get-Item $snapshot).Length
    if ($size -lt 1024) {
        throw "native UI snapshot exists but is too small to be a valid visual proof"
    }
}

Write-Host "native UI engine adapter gate ok"
