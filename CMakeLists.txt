cmake_minimum_required(VERSION 3.25)

project(NativeFireSim LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)

# RTX 4060 Laptop GPU is compute capability 8.9 on this machine.
set(CMAKE_CUDA_ARCHITECTURES 89)

add_executable(NativeFireSim WIN32
    src/main.cpp
    src/fire_cuda.cu
    src/fire_cuda.h
)

target_include_directories(NativeFireSim PRIVATE src)
target_compile_definitions(NativeFireSim PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(NativeFireSim PRIVATE user32 gdi32 winmm)

set_target_properties(NativeFireSim PROPERTIES
    CUDA_SEPARABLE_COMPILATION ON
)
