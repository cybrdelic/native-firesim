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
std::string jsonStringForKey(const std::string& text, const char* key);
const char* sceneAssetId(int sceneId);
std::filesystem::path runtimeSceneDirectory(int sceneId);
std::string readSceneContract(int sceneId);
std::string sceneEmitterSourcePolicy(int sceneId);
SceneEmitterParams loadSceneEmitterParams(int sceneId);
