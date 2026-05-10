#pragma once

#include "scene_runtime.h"

constexpr int kFrameWidth = 960;
constexpr int kFrameHeight = 540;

struct UiRect {
    int x;
    int y;
    int w;
    int h;
};

constexpr UiRect kRailRect = {14, 70, 76, 398};
constexpr UiRect kTopBarRect = {14, 14, 932, 36};
constexpr UiRect kViewportRect = {0, 0, kFrameWidth, kFrameHeight};
constexpr UiRect kInspectorRect = {762, 70, 184, 340};
constexpr UiRect kStatusRect = {14, 480, 932, 44};
constexpr UiRect kToolButtonRects[4] = {
    {22, 96, 60, 64},
    {22, 176, 60, 64},
    {22, 256, 60, 64},
    {22, 336, 60, 64},
};
constexpr UiRect kOverlayButtonRect = {104, 486, 72, 28};
constexpr UiRect kResetButtonRect = {184, 486, 72, 28};
constexpr UiRect kCudaWorkerButtonRect = {264, 486, 132, 28};
constexpr UiRect kSceneButtonRects[kSceneCount] = {
    {336, 20, 70, 24},
    {414, 20, 70, 24},
    {492, 20, 86, 24},
    {586, 20, 70, 24},
};
constexpr UiRect kWindSliderRect = {790, 214, 130, 16};
constexpr UiRect kTurbulenceSliderRect = {790, 304, 130, 16};
