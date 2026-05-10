#include "scene_assets.h"

#include <algorithm>
#include <array>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>

std::string readTextFile(const std::filesystem::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return {};
    }
    std::ostringstream buffer;
    buffer << in.rdbuf();
    return buffer.str();
}

std::string jsonArrayForKey(const std::string& text, const char* key) {
    const std::string needle = std::string("\"") + key + "\"";
    const std::size_t keyPos = text.find(needle);
    if (keyPos == std::string::npos) {
        return {};
    }
    const std::size_t start = text.find('[', keyPos);
    if (start == std::string::npos) {
        return {};
    }
    int depth = 0;
    for (std::size_t i = start; i < text.size(); ++i) {
        if (text[i] == '[') {
            ++depth;
        } else if (text[i] == ']') {
            --depth;
            if (depth == 0) {
                return text.substr(start, i - start + 1);
            }
        }
    }
    return {};
}

std::string jsonObjectForKey(const std::string& text, const char* key) {
    const std::string needle = std::string("\"") + key + "\"";
    const std::size_t keyPos = text.find(needle);
    if (keyPos == std::string::npos) {
        return {};
    }
    const std::size_t start = text.find('{', keyPos);
    if (start == std::string::npos) {
        return {};
    }
    int depth = 0;
    bool inString = false;
    bool escaped = false;
    for (std::size_t i = start; i < text.size(); ++i) {
        const char c = text[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = inString;
            continue;
        }
        if (c == '"') {
            inString = !inString;
            continue;
        }
        if (inString) {
            continue;
        }
        if (c == '{') {
            ++depth;
        } else if (c == '}') {
            --depth;
            if (depth == 0) {
                return text.substr(start, i - start + 1);
            }
        }
    }
    return {};
}

std::vector<float> parseJsonFloats(const std::string& text) {
    std::vector<float> values;
    const char* ptr = text.c_str();
    char* end = nullptr;
    while (*ptr != '\0') {
        const float value = std::strtof(ptr, &end);
        if (end != ptr) {
            values.push_back(value);
            ptr = end;
        } else {
            ++ptr;
        }
    }
    return values;
}

std::vector<std::uint32_t> parseJsonUInts(const std::string& text) {
    std::vector<std::uint32_t> values;
    const char* ptr = text.c_str();
    char* end = nullptr;
    while (*ptr != '\0') {
        const unsigned long value = std::strtoul(ptr, &end, 10);
        if (end != ptr) {
            values.push_back(static_cast<std::uint32_t>(value));
            ptr = end;
        } else {
            ++ptr;
        }
    }
    return values;
}

bool jsonNumberForKey(const std::string& text, const char* key, float& out) {
    const std::string needle = std::string("\"") + key + "\"";
    const std::size_t keyPos = text.find(needle);
    if (keyPos == std::string::npos) {
        return false;
    }
    const std::size_t colon = text.find(':', keyPos + needle.size());
    if (colon == std::string::npos) {
        return false;
    }
    const char* start = text.c_str() + colon + 1;
    char* end = nullptr;
    const float value = std::strtof(start, &end);
    if (end == start) {
        return false;
    }
    out = value;
    return true;
}

const char* sceneAssetId(int sceneId) {
    switch (sceneId) {
    case 1: return "campfire";
    case 2: return "gas-burner-aver1";
    case 3: return "methanol-pool";
    case 0: return "room";
    default: return "";
    }
}

std::filesystem::path runtimeSceneDirectory(int sceneId) {
    const char* assetId = sceneAssetId(sceneId);
    if (assetId[0] == '\0') {
        return {};
    }
    return std::filesystem::path("assets") / "fire-scenes" / assetId;
}

std::string readSceneContract(int sceneId) {
    const std::filesystem::path dir = runtimeSceneDirectory(sceneId);
    if (dir.empty()) {
        return {};
    }
    return readTextFile(dir / "scene.json");
}

std::array<float, 3> jsonTripletForKey(const std::string& text, const char* key, std::array<float, 3> fallback) {
    const std::vector<float> values = parseJsonFloats(jsonArrayForKey(text, key));
    if (values.size() >= 3) {
        return {values[0], values[1], values[2]};
    }
    return fallback;
}

std::array<float, 3> sceneCoordinateTranslationMeters(int sceneId, const std::string& sceneContract) {
    return jsonTripletForKey(sceneContract, "translationMeters", {0.0f, sceneId == 2 ? -0.24f : 0.0f, 0.0f});
}

std::array<float, 3> applySceneCoordinateTranslation(const std::array<float, 3>& point, const std::array<float, 3>& translation) {
    return {
        point[0] + translation[0],
        point[1] + translation[1],
        point[2] + translation[2],
    };
}

SceneEmitterParams loadSceneEmitterParams(int sceneId) {
    SceneEmitterParams params;
    const std::string sceneContract = readSceneContract(sceneId);
    if (!sceneContract.empty()) {
        const std::string emitterContract = jsonObjectForKey(sceneContract, "emitter");
        const std::string& emitterSource = emitterContract.empty() ? sceneContract : emitterContract;
        const std::array<float, 3> center = jsonTripletForKey(emitterSource, "centerMeters", {0.0f, 0.02f, 0.0f});
        params.centerX = center[0];
        params.centerZ = center[2];
        params.heightNorm = (center[1] - 0.02f) / 2.03f;
        float value = 0.0f;
        if (jsonNumberForKey(emitterSource, "radiusMeters", value)) {
            params.radius = value;
        }
        if (jsonNumberForKey(emitterSource, "heightBandMeters", value)) {
            params.heightBandNorm = value / 2.03f;
        }
    } else if (sceneId == 1) {
        params.radius = 0.32f;
        params.heightNorm = (0.045f - 0.02f) / 2.03f;
        params.heightBandNorm = 0.20f / 2.03f;
    } else if (sceneId == 2) {
        params.radius = 0.24f;
        params.heightNorm = (0.138f - 0.02f) / 2.03f;
        params.heightBandNorm = 0.105f / 2.03f;
    }

    const char* assetId = sceneAssetId(sceneId);
    if (assetId[0] == '\0' || sceneId == 0 || sceneId == 3) {
        return params;
    }
    const std::filesystem::path path = runtimeSceneDirectory(sceneId) / "emitter-mask.json";
    const std::string text = readTextFile(path);
    if (text.empty()) {
        return params;
    }
    const std::array<float, 3> sceneTranslation = sceneCoordinateTranslationMeters(sceneId, sceneContract);
    float value = 0.0f;
    if (jsonNumberForKey(text, "centerXMeters", value)) {
        params.centerX = value;
    }
    if (jsonNumberForKey(text, "centerZMeters", value)) {
        params.centerZ = value;
    }
    if (jsonNumberForKey(text, "centerYMeters", value)) {
        params.heightNorm = (value - 0.02f) / 2.03f;
    } else if (jsonNumberForKey(text, "worldHeightMeters", value)) {
        params.heightNorm = (value - 0.02f) / 2.03f;
    }
    if (jsonNumberForKey(text, "heightBandMeters", value)) {
        params.heightBandNorm = value / 2.03f;
    }
    if (jsonNumberForKey(text, "radiusMeters", value)) {
        params.radius = value;
    } else if (jsonNumberForKey(text, "radiusFraction", value)) {
        float width = 0.0f;
        float depth = 0.0f;
        if (jsonNumberForKey(text, "width", width) && jsonNumberForKey(text, "depth", depth)) {
            params.radius = value * std::max(width, depth);
        }
    }
    const std::vector<float> burnerCenters = parseJsonFloats(jsonArrayForKey(text, "burnerCentersMeters"));
    params.burnerCenterCount = static_cast<int>(std::min<std::size_t>(4, burnerCenters.size() / 3));
    for (int i = 0; i < params.burnerCenterCount; ++i) {
        const std::array<float, 3> burnerPoint = applySceneCoordinateTranslation(
            {
                burnerCenters[static_cast<std::size_t>(i) * 3 + 0],
                burnerCenters[static_cast<std::size_t>(i) * 3 + 1],
                burnerCenters[static_cast<std::size_t>(i) * 3 + 2],
            },
            sceneTranslation);
        params.burnerCenterX[i] = burnerPoint[0];
        params.burnerCenterY[i] = burnerPoint[1];
        params.burnerCenterZ[i] = burnerPoint[2];
    }
    if (sceneId == 2 && params.burnerCenterCount > 0) {
        params.heightNorm = ((params.burnerCenterY[0] + params.heightBandNorm * 2.03f * 0.42f) - 0.02f) / 2.03f;
    }
    return params;
}
