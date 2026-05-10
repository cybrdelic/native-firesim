#pragma once

#include <cstdint>
#include <array>
#include <filesystem>
#include <string>

#include "scene_runtime.h"

std::string readTextFile(const std::filesystem::path& path);
std::string jsonArrayForKey(const std::string& text, const char* key);
std::string jsonObjectForKey(const std::string& text, const char* key);
bool jsonNumberForKey(const std::string& text, const char* key, float& out);
const char* sceneAssetId(int sceneId);
std::filesystem::path runtimeSceneDirectory(int sceneId);
std::string readSceneContract(int sceneId);
std::array<float, 3> sceneCoordinateTranslationMeters(int sceneId, const std::string& sceneContract);
std::array<float, 3> applySceneCoordinateTranslation(const std::array<float, 3>& point, const std::array<float, 3>& translation);
SceneEmitterParams loadSceneEmitterParams(int sceneId);
