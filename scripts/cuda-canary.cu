#include <cuda_runtime.h>

#include <cstdio>

__global__ void canaryKernel(int* value) {
    if (threadIdx.x == 0 && blockIdx.x == 0) {
        *value = 12345;
    }
}

int main() {
    int deviceCount = 0;
    cudaError_t status = cudaGetDeviceCount(&deviceCount);
    if (status != cudaSuccess || deviceCount <= 0) {
        std::fprintf(stderr, "cudaGetDeviceCount failed: %s\n", cudaGetErrorString(status));
        return 1;
    }

    status = cudaSetDevice(0);
    if (status != cudaSuccess) {
        std::fprintf(stderr, "cudaSetDevice failed: %s\n", cudaGetErrorString(status));
        return 2;
    }

    int* deviceValue = nullptr;
    status = cudaMalloc(&deviceValue, sizeof(int));
    if (status != cudaSuccess) {
        std::fprintf(stderr, "cudaMalloc failed: %s\n", cudaGetErrorString(status));
        return 3;
    }

    status = cudaMemset(deviceValue, 0, sizeof(int));
    if (status != cudaSuccess) {
        std::fprintf(stderr, "cudaMemset failed: %s\n", cudaGetErrorString(status));
        cudaFree(deviceValue);
        return 4;
    }

    canaryKernel<<<1, 1>>>(deviceValue);
    status = cudaGetLastError();
    if (status != cudaSuccess) {
        std::fprintf(stderr, "kernel launch failed: %s\n", cudaGetErrorString(status));
        cudaFree(deviceValue);
        return 5;
    }

    status = cudaDeviceSynchronize();
    if (status != cudaSuccess) {
        std::fprintf(stderr, "cudaDeviceSynchronize failed: %s\n", cudaGetErrorString(status));
        cudaFree(deviceValue);
        return 6;
    }

    int hostValue = 0;
    status = cudaMemcpy(&hostValue, deviceValue, sizeof(int), cudaMemcpyDeviceToHost);
    cudaFree(deviceValue);
    if (status != cudaSuccess) {
        std::fprintf(stderr, "cudaMemcpy failed: %s\n", cudaGetErrorString(status));
        return 7;
    }

    if (hostValue != 12345) {
        std::fprintf(stderr, "unexpected canary value: %d\n", hostValue);
        return 8;
    }

    std::printf("cuda canary ok: deviceCount=%d value=%d\n", deviceCount, hostValue);
    return 0;
}
