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

std::string jsonStringForKey(const std::string& text, const char* key) {
    const std::string needle = std::string("\"") + key + "\"";
    const std::size_t keyPos = text.find(needle);
    if (keyPos == std::string::npos) {
        return {};
    }
    const std::size_t colon = text.find(':', keyPos + needle.size());
    if (colon == std::string::npos) {
        return {};
    }
    const std::size_t quote = text.find('"', colon + 1);
    if (quote == std::string::npos) {
        return {};
    }
    std::string out;
    bool escaped = false;
    for (std::size_t i = quote + 1; i < text.size(); ++i) {
        const char c = text[i];
        if (escaped) {
            out.push_back(c);
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') {
            return out;
        }
        out.push_back(c);
    }
    return {};
}

const char* sceneAssetId(int sceneId) {
    (void)sceneId;
    return kProductSceneKey;
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

std::string sceneEmitterSourcePolicy(int sceneId) {
    const std::string sceneContract = readSceneContract(sceneId);
    const std::string emitterContract = jsonObjectForKey(sceneContract, "emitter");
    return jsonStringForKey(emitterContract.empty() ? sceneContract : emitterContract, "emitterSourcePolicy");
}

SceneEmitterParams loadSceneEmitterParams(int sceneId) {
    (void)sceneId;
    SceneEmitterParams params;
    const std::string sceneContract = readSceneContract(kProductSceneId);
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
    }
    return params;
}
