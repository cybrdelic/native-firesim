#pragma once

#include <cstdint>
#include <array>
#include <filesystem>
#include <string>
#include <vector>

#include "scene_runtime.h"

struct MeshVertex {
    float px;
    float py;
    float pz;
    float nx;
    float ny;
    float nz;
    float cr;
    float cg;
    float cb;
};

struct SceneMeshCpuData {
    std::vector<MeshVertex> vertices;
    std::vector<std::uint32_t> indices;
    float minX = 0.0f;
    float minY = 0.0f;
    float minZ = 0.0f;
    float maxX = 0.0f;
    float maxY = 0.0f;
    float maxZ = 0.0f;
    bool loaded = false;
};

std::string readTextFile(const std::filesystem::path& path);
std::string jsonArrayForKey(const std::string& text, const char* key);
std::string jsonObjectForKey(const std::string& text, const char* key);
bool jsonNumberForKey(const std::string& text, const char* key, float& out);
const char* runtimeMeshAssetId(int sceneId);
std::filesystem::path runtimeSceneDirectory(int sceneId);
std::string readSceneContract(int sceneId);
std::array<float, 3> sceneMeshTranslationMeters(int sceneId, const std::string& sceneContract);
std::array<float, 3> applySceneMeshTranslation(const std::array<float, 3>& point, const std::array<float, 3>& translation);
SceneEmitterParams loadSceneEmitterParams(int sceneId);
bool loadRuntimeSceneMeshCpuData(int sceneId, SceneMeshCpuData& mesh, std::string* error);
