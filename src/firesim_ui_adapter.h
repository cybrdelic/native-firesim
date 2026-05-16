#pragma once

#include <cstdint>

struct FireUiRect {
    float x;
    float y;
    float w;
    float h;
};

struct FireUiColor {
    float r;
    float g;
    float b;
    float a;
};

enum class FireUiSurfaceRole : std::uint32_t {
    TopBar = 1,
    RailPanel = 2,
    InspectorPanel = 3,
    StatusPanel = 4,
    ToolButton = 5,
    CommandButton = 6,
    SceneButton = 7,
    SliderTrack = 8,
    SliderFill = 9,
    SliderThumb = 10,
    DebugOverlay = 11,
};

struct FireUiSurface {
    FireUiColor fill;
    FireUiColor stroke;
    FireUiColor text;
    FireUiColor accent;
    float strokeWidth;
    float cut;
    float elevation;
    float roughness;
    std::uint32_t notchMask;
    std::uint32_t iconKind;
    std::uint32_t visualLanguage;
    std::uint32_t controlRole;
    float hover;
    float pressure;
    float activity;
    float focus;
};

enum class FireUiIconOp : std::uint32_t {
    Line = 1,
    Circle = 2,
    Dot = 3,
};

struct FireUiIconPrimitive {
    FireUiIconOp op;
    float x0;
    float y0;
    float x1;
    float y1;
    float radius;
};

void fireUiBeginFrame(float dt, float mouseX, float mouseY, bool mouseDown);
void fireUiEndFrame();
FireUiSurface fireUiResolveSurface(FireUiSurfaceRole role, std::uint32_t id, FireUiRect rect, bool active);
int fireUiIconPrimitives(std::uint32_t iconKind, FireUiIconPrimitive* outPrimitives, int capacity);
void fireUiPaintSurface(std::uint32_t* pixels, int width, int height, FireUiRect rect, const FireUiSurface& surface, bool active);
void fireUiDrawIcon(std::uint32_t* pixels, int width, int height, FireUiRect rect, const FireUiSurface& surface, float alphaScale);
int fireUiTextWidth(const char* text, int scale);
void fireUiDrawText(std::uint32_t* pixels, int width, int height, int x, int y, const char* text, int scale, FireUiColor color);
void fireUiDrawClippedText(std::uint32_t* pixels, int width, int height, int x, int y, const char* text, int maxChars, int scale, FireUiColor color);
void fireUiDrawCenteredText(std::uint32_t* pixels, int width, int height, FireUiRect rect, const char* text, int scale, FireUiColor color);
const char* fireUiEngineName();
const char* fireUiEnginePath();
