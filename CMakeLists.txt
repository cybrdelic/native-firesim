cmake_minimum_required(VERSION 3.25)

project(NativeFireSim LANGUAGES C CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(NATIVE_UI_ENGINE_DIR "C:/Users/alexf/projects/native-ui-engine" CACHE PATH "Path to Alex's native UI engine repository.")
get_filename_component(NATIVE_UI_ENGINE_DIR "${NATIVE_UI_ENGINE_DIR}" ABSOLUTE BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")

if (NOT EXISTS "${NATIVE_UI_ENGINE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "native-ui-engine not found at ${NATIVE_UI_ENGINE_DIR}. Set NATIVE_UI_ENGINE_DIR.")
endif()

add_subdirectory("${NATIVE_UI_ENGINE_DIR}" "${CMAKE_BINARY_DIR}/native-ui-engine")

# Build native SASS for the common Ada/Ampere targets plus a forward-compatible PTX image.
set(CMAKE_CUDA_ARCHITECTURES 86-real 89-real 90-real 90-virtual)

add_executable(NativeFireSim WIN32
    src/main.cpp
    src/d3d_render_types.h
    src/firesim_render_contract.h
    src/firesim_ui_adapter.cpp
    src/firesim_ui_adapter.h
    src/render_sparse_integrator.h
    src/runtime_health.h
    src/runtime_quality.h
    src/runtime_state.h
    src/render_debug_modes.h
    src/scene_assets.cpp
    src/scene_assets.h
    src/scene_runtime.cpp
    src/scene_runtime.h
    src/shared_viewport.h
    src/ui_layout.h
    src/ui_labels.h
    src/volume_bricks.h
    src/worker_lifecycle.cpp
    src/worker_lifecycle.h
    src/fire_cuda.cu
    src/fire_cuda.h
)

target_include_directories(NativeFireSim PRIVATE src)
target_compile_definitions(NativeFireSim PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
target_compile_options(NativeFireSim PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:/W4 /permissive- /sdl>
    $<$<COMPILE_LANGUAGE:CUDA>:-lineinfo>
)
target_link_libraries(NativeFireSim PRIVATE alexf_native_ui_canvas_win32 user32 winmm d3d11 dxgi d3dcompiler)

set_target_properties(NativeFireSim PROPERTIES
    CUDA_SEPARABLE_COMPILATION OFF
    CUDA_RESOLVE_DEVICE_SYMBOLS OFF
)
