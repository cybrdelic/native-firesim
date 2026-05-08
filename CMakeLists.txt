cmake_minimum_required(VERSION 3.25)

project(NativeFireSim LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# RTX 4060 Laptop GPU is compute capability 8.9 on this machine.
set(CMAKE_CUDA_ARCHITECTURES 89)

add_executable(NativeFireSim WIN32
    src/main.cpp
    src/d3d_render_types.h
    src/runtime_state.h
    src/scene_assets.cpp
    src/scene_assets.h
    src/scene_runtime.cpp
    src/scene_runtime.h
    src/shared_viewport.h
    src/ui_layout.h
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
target_link_libraries(NativeFireSim PRIVATE user32 winmm d3d11 dxgi d3dcompiler)

set_target_properties(NativeFireSim PROPERTIES
    CUDA_SEPARABLE_COMPILATION OFF
    CUDA_RESOLVE_DEVICE_SYMBOLS OFF
)
