#include "firesim_ui_adapter.h"

#include "ui_canvas.h"
#include "ui_engine.h"
#include "ui_hud_scene.h"
#include "ui_primitives.h"
#include "ui_skin_atlas.h"

#include <algorithm>
#include <cstring>

namespace {

UiFrameGraph g_uiFrame = {};
UiSkinPack g_skinPack = {};
UiSkinAtlas g_skinAtlas = {};
UiHudScene g_hudScene = {};
bool g_skinReady = false;
constexpr UiVisualLanguage kFireSimVisualLanguage = UI_VISUAL_TECH_CYBERNETIC_ARTISAN;

float clamp01(float v) {
    return std::max(0.0f, std::min(1.0f, v));
}

void ensureSkinPack() {
    if (g_skinReady) {
        return;
    }
    g_skinPack = ui_skin_pack(kFireSimVisualLanguage);
    ui_skin_atlas_generate(&g_skinAtlas, &g_skinPack);
    g_skinReady = true;
}

UiRect toNativeRect(FireUiRect rect) {
    UiRect out = {rect.x, rect.y, rect.w, rect.h};
    return ui_rect_sanitize(out);
}

UiId surfaceId(FireUiSurfaceRole role, std::uint32_t id) {
    return (static_cast<UiId>(role) << 24) ^ (id & 0x00ffffffu);
}

FireUiColor color(float r, float g, float b, float a = 1.0f) {
    return {r, g, b, a};
}

FireUiColor scaleColor(FireUiColor c, float energy, float alphaScale = 1.0f) {
    c.r = clamp01(c.r + energy);
    c.g = clamp01(c.g + energy);
    c.b = clamp01(c.b + energy);
    c.a = clamp01(c.a * alphaScale);
    return c;
}

FireUiColor mixColor(FireUiColor a, FireUiColor b, float t) {
    t = clamp01(t);
    return {
        a.r + (b.r - a.r) * t,
        a.g + (b.g - a.g) * t,
        a.b + (b.b - a.b) * t,
        a.a + (b.a - a.a) * t
    };
}

FireUiColor fromNativeColor(UiColor c) {
    return {c.r, c.g, c.b, c.a};
}

UiColor toNativeColor(FireUiColor c) {
    return {c.r, c.g, c.b, c.a};
}

UiMaterialSurface toNativeSurface(const FireUiSurface& surface) {
    UiMaterialSurface native = ui_material_surface_default(
        toNativeColor(surface.fill),
        toNativeColor(surface.accent),
        toNativeColor(surface.text));
    native.cut = surface.cut;
    native.notchMask = surface.notchMask;
    native.elevation = surface.elevation;
    native.roughness = surface.roughness > 0.0f ? surface.roughness : 0.58f;
    native.hover = surface.hover;
    native.pressure = surface.pressure;
    native.activity = surface.activity;
    return native;
}

UiChromeRole toNativeRole(FireUiSurfaceRole role) {
    switch (role) {
    case FireUiSurfaceRole::TopBar:
        return UI_CHROME_TOP_BAR;
    case FireUiSurfaceRole::RailPanel:
        return UI_CHROME_RAIL_PANEL;
    case FireUiSurfaceRole::InspectorPanel:
        return UI_CHROME_INSPECTOR_PANEL;
    case FireUiSurfaceRole::StatusPanel:
        return UI_CHROME_STATUS_PANEL;
    case FireUiSurfaceRole::ToolButton:
        return UI_CHROME_TOOL_BUTTON;
    case FireUiSurfaceRole::CommandButton:
        return UI_CHROME_COMMAND_BUTTON;
    case FireUiSurfaceRole::SceneButton:
        return UI_CHROME_SCENE_BUTTON;
    case FireUiSurfaceRole::SliderTrack:
        return UI_CHROME_SLIDER_TRACK;
    case FireUiSurfaceRole::SliderFill:
        return UI_CHROME_SLIDER_FILL;
    case FireUiSurfaceRole::SliderThumb:
        return UI_CHROME_SLIDER_THUMB;
    case FireUiSurfaceRole::DebugOverlay:
        return UI_CHROME_DEBUG_OVERLAY;
    default:
        return UI_CHROME_COMMAND_BUTTON;
    }
}

UiControlRole toControlRole(FireUiSurfaceRole role, bool active) {
    switch (role) {
    case FireUiSurfaceRole::TopBar:
        return UI_CONTROL_TITLEBAR;
    case FireUiSurfaceRole::RailPanel:
    case FireUiSurfaceRole::InspectorPanel:
    case FireUiSurfaceRole::StatusPanel:
    case FireUiSurfaceRole::DebugOverlay:
        return UI_CONTROL_PANEL;
    case FireUiSurfaceRole::ToolButton:
    case FireUiSurfaceRole::SceneButton:
        return active ? UI_CONTROL_NAV_ITEM_ACTIVE : UI_CONTROL_NAV_ITEM;
    case FireUiSurfaceRole::CommandButton:
    case FireUiSurfaceRole::SliderFill:
    case FireUiSurfaceRole::SliderThumb:
        return UI_CONTROL_COMMAND_BUTTON;
    case FireUiSurfaceRole::SliderTrack:
        return UI_CONTROL_INPUT_WELL;
    default:
        return UI_CONTROL_PANEL;
    }
}

UiHudAction actionForSurface(FireUiSurfaceRole role, std::uint32_t id) {
    if (role == FireUiSurfaceRole::SceneButton && id <= 5u) {
        return static_cast<UiHudAction>(static_cast<int>(UI_HUD_ACTION_NAV_0) + static_cast<int>(id));
    }
    if (role == FireUiSurfaceRole::CommandButton) {
        return UI_HUD_ACTION_SEND;
    }
    return UI_HUD_ACTION_NONE;
}

UiMaterial materialFor(FireUiSurfaceRole role, bool active) {
    UiMaterial material = ui_material_default();
    material.borderEnergy = active ? 0.22f : 0.08f;
    material.emissive = active ? 0.18f : 0.03f;
    material.diffusion = 0.30f;
    material.pressureResponse = 0.65f;
    material.interactionResponse = 0.58f;

    switch (role) {
    case FireUiSurfaceRole::TopBar:
    case FireUiSurfaceRole::RailPanel:
    case FireUiSurfaceRole::InspectorPanel:
    case FireUiSurfaceRole::StatusPanel:
        material.roughness = 0.74f;
        material.diffusion = 0.42f;
        material.temporalPersistence = 0.24f;
        break;
    case FireUiSurfaceRole::ToolButton:
    case FireUiSurfaceRole::CommandButton:
    case FireUiSurfaceRole::SceneButton:
        material.roughness = 0.46f;
        material.borderEnergy = active ? 0.34f : 0.12f;
        material.emissive = active ? 0.24f : 0.05f;
        material.interactionResponse = 0.78f;
        break;
    case FireUiSurfaceRole::SliderFill:
    case FireUiSurfaceRole::SliderThumb:
        material.roughness = 0.38f;
        material.borderEnergy = active ? 0.28f : 0.16f;
        material.emissive = active ? 0.22f : 0.10f;
        break;
    case FireUiSurfaceRole::DebugOverlay:
        material.roughness = 0.58f;
        material.translucency = 0.22f;
        material.emissive = active ? 0.18f : 0.06f;
        break;
    default:
        break;
    }

    return material;
}

FireUiSurface baseSurfaceFor(FireUiSurfaceRole role, bool active) {
    FireUiSurface surface = {};
    surface.fill = color(0.025f, 0.027f, 0.028f, 0.82f);
    surface.stroke = color(0.18f, 0.19f, 0.19f, 0.70f);
    surface.text = color(0.84f, 0.86f, 0.80f, 0.90f);
    surface.accent = color(0.32f, 0.36f, 0.36f, 0.78f);
    surface.strokeWidth = 1.0f;
    surface.cut = 0.0f;
    surface.elevation = 0.0f;
    surface.roughness = 0.58f;
    surface.notchMask = 0;
    surface.iconKind = 0;
    surface.visualLanguage = static_cast<std::uint32_t>(kFireSimVisualLanguage);
    surface.controlRole = static_cast<std::uint32_t>(UI_CONTROL_PANEL);

    switch (role) {
    case FireUiSurfaceRole::TopBar:
        surface.fill = color(0.010f, 0.011f, 0.011f, 0.86f);
        surface.stroke = color(0.18f, 0.19f, 0.18f, 0.78f);
        break;
    case FireUiSurfaceRole::RailPanel:
        surface.fill = color(0.012f, 0.013f, 0.013f, 0.88f);
        surface.stroke = color(0.23f, 0.24f, 0.23f, 0.74f);
        break;
    case FireUiSurfaceRole::InspectorPanel:
        surface.fill = color(0.013f, 0.014f, 0.014f, 0.88f);
        surface.stroke = color(0.22f, 0.24f, 0.23f, 0.72f);
        break;
    case FireUiSurfaceRole::StatusPanel:
        surface.fill = color(0.011f, 0.012f, 0.012f, 0.86f);
        surface.stroke = color(0.18f, 0.19f, 0.18f, 0.74f);
        break;
    case FireUiSurfaceRole::ToolButton:
        surface.fill = active ? color(0.105f, 0.059f, 0.037f, 1.0f) : color(0.048f, 0.050f, 0.052f, 1.0f);
        surface.stroke = active ? color(1.0f, 0.42f, 0.08f, 0.95f) : color(0.20f, 0.22f, 0.24f, 0.70f);
        surface.text = color(0.88f, 0.90f, 0.86f, active ? 0.98f : 0.70f);
        break;
    case FireUiSurfaceRole::CommandButton:
        surface.fill = active ? color(0.080f, 0.078f, 0.064f, 1.0f) : color(0.046f, 0.048f, 0.050f, 1.0f);
        surface.stroke = active ? color(0.78f, 0.74f, 0.55f, 0.90f) : color(0.22f, 0.24f, 0.25f, 0.70f);
        break;
    case FireUiSurfaceRole::SceneButton:
        surface.fill = active ? color(0.036f, 0.052f, 0.070f, 0.95f) : color(0.023f, 0.026f, 0.028f, 0.76f);
        surface.stroke = active ? color(0.38f, 0.66f, 1.0f, 0.92f) : color(0.16f, 0.18f, 0.20f, 0.68f);
        surface.text = active ? color(0.62f, 0.78f, 1.0f, 0.96f) : color(0.54f, 0.58f, 0.62f, 0.78f);
        break;
    case FireUiSurfaceRole::SliderTrack:
        surface.fill = color(0.030f, 0.032f, 0.033f, 1.0f);
        surface.stroke = color(0.20f, 0.21f, 0.20f, 0.82f);
        break;
    case FireUiSurfaceRole::SliderFill:
        surface.fill = color(0.10f, 0.56f, 0.62f, 0.92f);
        surface.stroke = color(0.18f, 0.72f, 0.80f, 0.86f);
        break;
    case FireUiSurfaceRole::SliderThumb:
        surface.fill = color(0.05f, 0.86f, 1.0f, 0.96f);
        surface.stroke = color(0.60f, 0.95f, 1.0f, 0.90f);
        break;
    case FireUiSurfaceRole::DebugOverlay:
        surface.fill = color(0.020f, 0.022f, 0.021f, 0.42f);
        surface.stroke = color(0.95f, 0.58f, 0.12f, 0.74f);
        surface.text = color(0.76f, 0.82f, 0.72f, 0.88f);
        break;
    default:
        break;
    }

    return surface;
}

} // namespace

void fireUiBeginFrame(float dt, float mouseX, float mouseY, bool mouseDown) {
    ensureSkinPack();
    ui_frame_begin(&g_uiFrame, dt, mouseX, mouseY, mouseDown ? 1 : 0);
    ui_hud_scene_begin(&g_hudScene, g_skinPack.language, {0.0f, 0.0f, 2048.0f, 2048.0f}, g_uiFrame.time);
    ui_frame_phase(&g_uiFrame, UI_PHASE_COLLECT_NODES);
    ui_field_emit(&g_uiFrame, UI_FIELD_HOVER, mouseX, mouseY, 72.0f, 0.86f, 1.0f);
    if (mouseDown) {
        ui_field_emit(&g_uiFrame, UI_FIELD_PRESSURE, mouseX, mouseY, 56.0f, 1.0f, 1.0f);
    }
}

void fireUiEndFrame() {
    ui_frame_phase(&g_uiFrame, UI_PHASE_COMPOSITE);
    ui_frame_end(&g_uiFrame);
}

FireUiSurface fireUiResolveSurface(FireUiSurfaceRole role, std::uint32_t id, FireUiRect rect, bool active) {
    ensureSkinPack();
    const UiRect nativeRect = toNativeRect(rect);
    const UiControlRole controlRole = toControlRole(role, active);
    const UiVisualPalette palette = ui_visual_palette(g_skinPack.language);
    const UiMaterialRecipe materialRecipe = ui_skin_material_recipe(&g_skinPack, controlRole);
    const UiGeometryRecipe geometryRecipe = ui_skin_geometry_recipe(&g_skinPack, controlRole);
    const UiSurfaceProgram baseProgram = ui_surface_program_for_skin(g_skinPack.baseSkin);
    const UiSurfaceProgram& program = controlRole >= 0 && controlRole < UI_CONTROL_COUNT ? g_skinPack.programs[controlRole] : baseProgram;
    UiHudPart* hudPart = ui_hud_add_part(&g_hudScene, UI_HUD_PART_NINE_SLICE, actionForSurface(role, id), controlRole, nativeRect);
    UiMaterial base = materialFor(role, active);
    UiNode* node = ui_node_register(&g_uiFrame, surfaceId(role, id), nativeRect, base);
    const float hover = ui_field_sample(&g_uiFrame, UI_FIELD_HOVER, nativeRect);
    const float pressure = ui_field_sample(&g_uiFrame, UI_FIELD_PRESSURE, nativeRect);
    const float activity = active ? 1.0f : hover * 0.28f + pressure * 0.42f;
    const float focus = active ? 1.0f : 0.0f;
    const UiMaterial resolved = ui_material_resolve(base, hover, pressure, activity, focus);

    if (node != nullptr) {
        node->hover = hover;
        node->activity = activity;
        node->focus = focus;
        node->material = resolved;
    }

    FireUiSurface surface = baseSurfaceFor(role, active);
    const UiMaterialSurface chrome = ui_chrome_surface(toNativeRole(role), resolved, active ? 1 : 0, hover, pressure, activity, focus);
    surface.fill = fromNativeColor(chrome.base);
    surface.stroke = fromNativeColor(chrome.accent);
    surface.text = fromNativeColor(chrome.text);
    surface.accent = fromNativeColor(chrome.accent);
    surface.cut = chrome.cut;
    surface.elevation = chrome.elevation;
    surface.roughness = materialRecipe.roughness;
    surface.notchMask = chrome.notchMask;
    surface.iconKind = static_cast<std::uint32_t>(ui_chrome_icon(toNativeRole(role), static_cast<int>(id)));
    surface.visualLanguage = static_cast<std::uint32_t>(g_skinPack.language);
    surface.controlRole = static_cast<std::uint32_t>(controlRole);

    UiColor targetBase = palette.surface;
    if (role == FireUiSurfaceRole::TopBar) {
        targetBase = palette.topbar;
    } else if (role == FireUiSurfaceRole::RailPanel || role == FireUiSurfaceRole::InspectorPanel) {
        targetBase = palette.sidebar;
    } else if (role == FireUiSurfaceRole::StatusPanel || role == FireUiSurfaceRole::SliderTrack || role == FireUiSurfaceRole::DebugOverlay) {
        targetBase = palette.recessed;
    } else if (active) {
        targetBase = palette.surfaceRaised;
    }
    surface.fill = mixColor(surface.fill, fromNativeColor(targetBase), 0.24f);
    surface.stroke = mixColor(surface.stroke, fromNativeColor(active ? palette.accent : palette.accentSoft), active ? 0.42f : 0.26f);
    surface.text = mixColor(surface.text, fromNativeColor(active ? palette.text : palette.textMuted), active ? 0.36f : 0.24f);
    surface.accent = mixColor(surface.accent, fromNativeColor(palette.accent), active ? 0.46f : 0.30f);

    const float geometryScale = std::max(0.35f, std::min(1.85f, geometryRecipe.cornerScale * program.cutScale));
    surface.cut *= geometryScale;
    if (program.corners == UI_CORNER_SQUARE || program.corners == UI_CORNER_ROUNDED) {
        surface.cut = 0.0f;
        surface.notchMask = 0;
    } else if (program.corners == UI_CORNER_NOTCHED && surface.notchMask == 0) {
        surface.notchMask = UI_NOTCH_TOP_LEFT | UI_NOTCH_BOTTOM_RIGHT;
    }

    const float fillEnergy = hover * resolved.diffusion * 0.045f + pressure * resolved.pressureResponse * 0.065f + resolved.emissive * 0.030f;
    const float strokeEnergy = resolved.borderEnergy * 0.050f + hover * 0.035f + pressure * 0.055f;
    surface.fill = scaleColor(surface.fill, fillEnergy);
    surface.stroke = scaleColor(surface.stroke, strokeEnergy);
    surface.text = scaleColor(surface.text, hover * 0.050f + resolved.emissive * 0.020f);
    surface.strokeWidth = 1.0f + resolved.borderEnergy * 0.55f + pressure * 0.35f;
    surface.hover = hover;
    surface.pressure = pressure;
    surface.activity = activity;
    surface.focus = focus;
    if (hudPart != nullptr) {
        hudPart->id = surfaceId(role, id);
        hudPart->atlas = ui_skin_atlas_slot_for_role(controlRole);
        hudPart->tint = toNativeColor(surface.accent);
        hudPart->z = surface.elevation;
        hudPart->phase = activity;
    }
    return surface;
}

int fireUiIconPrimitives(std::uint32_t iconKind, FireUiIconPrimitive* outPrimitives, int capacity) {
    if (capacity <= 0) {
        return ui_icon_primitives(static_cast<UiIconKind>(iconKind), nullptr, 0);
    }
    UiIconPrimitive nativePrimitives[32] = {};
    const int nativeCount = ui_icon_primitives(static_cast<UiIconKind>(iconKind), nativePrimitives, std::min(capacity, 32));
    const int count = std::min(nativeCount, capacity);
    for (int i = 0; i < count; ++i) {
        outPrimitives[i].op = static_cast<FireUiIconOp>(nativePrimitives[i].op);
        outPrimitives[i].x0 = nativePrimitives[i].x0;
        outPrimitives[i].y0 = nativePrimitives[i].y0;
        outPrimitives[i].x1 = nativePrimitives[i].x1;
        outPrimitives[i].y1 = nativePrimitives[i].y1;
        outPrimitives[i].radius = nativePrimitives[i].radius;
    }
    return nativeCount;
}

void fireUiPaintSurface(std::uint32_t* pixels, int width, int height, FireUiRect rect, const FireUiSurface& surface, bool active) {
    ensureSkinPack();
    UiCanvas canvas = {};
    ui_canvas_begin(&canvas, pixels, width, height);
    UiControlRole controlRole = UI_CONTROL_PANEL;
    if (surface.controlRole < static_cast<std::uint32_t>(UI_CONTROL_COUNT)) {
        controlRole = static_cast<UiControlRole>(surface.controlRole);
    }
    UiSurfaceProgram program = g_skinPack.programs[controlRole];
    ui_canvas_set_skin(&canvas, g_skinPack.baseSkin, &program);
    ui_canvas_draw_material_surface(&canvas, toNativeRect(rect), toNativeSurface(surface), active ? 1 : 0);
}

void fireUiDrawIcon(std::uint32_t* pixels, int width, int height, FireUiRect rect, const FireUiSurface& surface, float alphaScale) {
    if (surface.iconKind == 0) {
        return;
    }
    ensureSkinPack();
    UiCanvas canvas = {};
    ui_canvas_begin(&canvas, pixels, width, height);
    UiSurfaceProgram program = g_skinPack.programs[UI_CONTROL_COMMAND_BUTTON];
    ui_canvas_set_skin(&canvas, g_skinPack.baseSkin, &program);
    ui_canvas_draw_icon(&canvas, toNativeRect(rect), static_cast<UiIconKind>(surface.iconKind), toNativeSurface(surface), alphaScale);
}

int fireUiTextWidth(const char* text, int scale) {
    return ui_canvas_text_width(text, scale);
}

void fireUiDrawText(std::uint32_t* pixels, int width, int height, int x, int y, const char* text, int scale, FireUiColor color) {
    UiCanvas canvas = {};
    ui_canvas_begin(&canvas, pixels, width, height);
    ui_canvas_draw_text(&canvas, x, y, text, scale, toNativeColor(color));
}

void fireUiDrawClippedText(std::uint32_t* pixels, int width, int height, int x, int y, const char* text, int maxChars, int scale, FireUiColor color) {
    UiCanvas canvas = {};
    ui_canvas_begin(&canvas, pixels, width, height);
    ui_canvas_draw_text_clipped(&canvas, x, y, text, maxChars, scale, toNativeColor(color));
}

void fireUiDrawCenteredText(std::uint32_t* pixels, int width, int height, FireUiRect rect, const char* text, int scale, FireUiColor color) {
    UiCanvas canvas = {};
    ui_canvas_begin(&canvas, pixels, width, height);
    ui_canvas_draw_text_centered(&canvas, toNativeRect(rect), text, scale, toNativeColor(color));
}

const char* fireUiEngineName() {
    return "alexf_native_ui_core";
}

const char* fireUiEnginePath() {
    return "C:/Users/alexf/projects/native-ui-engine";
}
