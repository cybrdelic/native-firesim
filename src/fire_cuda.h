#pragma once

#include <cstdint>

struct FireSettings {
    int width = 1280;
    int height = 720;
    float dt = 1.0f / 60.0f;
    float mouseX = 0.5f;
    float mouseY = 0.12f;
    int leftDown = 0;
    int rightDown = 0;
    int reset = 0;
    int showGizmos = 1;
    int activeGizmo = 1;
    float wind = 0.0f;
    float turbulence = 0.72f;
    float detail = 0.88f;
    float smoke = 0.92f;
    float intensity = 1.0f;
    float cameraYaw = 0.0f;
    float cameraPitch = 0.18f;
    float cameraDistance = 3.35f;
};

bool fireCudaInitialize(int frameWidth, int frameHeight, int gridWidth, int gridHeight);
bool fireCudaStepAndRender(std::uint32_t* bgraPixels, const FireSettings& settings);
bool fireCudaReset();
void fireCudaShutdown();
const char* fireCudaLastError();
