#pragma once

#include <array>
#include <cstdint>
#include <vector>

#include <d3d11.h>
#include <dxgi.h>
#include <wrl/client.h>

#include "scene_assets.h"

constexpr int kD3DSharedFrameSlots = 3;
constexpr int kD3DDisplayFrameSlots = 3;

struct DisplayConstants {
    float exposure;
    float padding[3];
};

struct MeshConstants {
    float viewProj[16];
    float lightPos[4];
    float baseColor[4];
    float fireColor[4];
    float fireParams[4];
    float meshOffset[4];
};

struct RuntimeSceneMesh {
    std::vector<MeshVertex> vertices;
    std::vector<std::uint32_t> indices;
    Microsoft::WRL::ComPtr<ID3D11Buffer> vertexBuffer;
    Microsoft::WRL::ComPtr<ID3D11Buffer> indexBuffer;
    float minX = 0.0f;
    float minY = 0.0f;
    float minZ = 0.0f;
    float maxX = 0.0f;
    float maxY = 0.0f;
    float maxZ = 0.0f;
    bool loaded = false;
};

struct D3DDisplayState {
    Microsoft::WRL::ComPtr<ID3D11Device> device;
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> context;
    Microsoft::WRL::ComPtr<IDXGISwapChain> swapChain;
    Microsoft::WRL::ComPtr<ID3D11RenderTargetView> renderTargetView;
    std::array<Microsoft::WRL::ComPtr<ID3D11Texture2D>, kD3DSharedFrameSlots> sharedSimTextures;
    std::array<Microsoft::WRL::ComPtr<IDXGIKeyedMutex>, kD3DSharedFrameSlots> sharedSimMutexes;
    std::array<HANDLE, kD3DSharedFrameSlots> sharedSimHandles = {};
    std::array<Microsoft::WRL::ComPtr<ID3D11Texture2D>, kD3DDisplayFrameSlots> displaySimTextures;
    std::array<Microsoft::WRL::ComPtr<ID3D11ShaderResourceView>, kD3DDisplayFrameSlots> displaySimSrvs;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> meshDepthTexture;
    Microsoft::WRL::ComPtr<ID3D11DepthStencilView> meshDepthView;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> uiTexture;
    Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> uiSrv;
    Microsoft::WRL::ComPtr<ID3D11SamplerState> sampler;
    Microsoft::WRL::ComPtr<ID3D11VertexShader> vertexShader;
    Microsoft::WRL::ComPtr<ID3D11VertexShader> meshVertexShader;
    Microsoft::WRL::ComPtr<ID3D11PixelShader> simPixelShader;
    Microsoft::WRL::ComPtr<ID3D11PixelShader> uiPixelShader;
    Microsoft::WRL::ComPtr<ID3D11PixelShader> meshPixelShader;
    Microsoft::WRL::ComPtr<ID3D11InputLayout> meshInputLayout;
    Microsoft::WRL::ComPtr<ID3D11Buffer> displayConstants;
    Microsoft::WRL::ComPtr<ID3D11Buffer> meshConstants;
    Microsoft::WRL::ComPtr<ID3D11BlendState> alphaBlend;
    Microsoft::WRL::ComPtr<ID3D11DepthStencilState> meshDepthState;
    Microsoft::WRL::ComPtr<ID3D11RasterizerState> meshRasterizerState;
    Microsoft::WRL::ComPtr<ID3D11Query> copyCompletionQuery;
    int activeDisplaySimSlot = -1;
    int nextDisplaySimSlot = 0;
    bool initialized = false;
    bool hasSimFrame = false;
};

struct RenderGraphStats {
    unsigned long long frameIndex = 0;
    unsigned long long clearPasses = 0;
    unsigned long long volumeCameraPasses = 0;
    unsigned long long sceneMeshPasses = 0;
    unsigned long long uiOverlayPasses = 0;
    unsigned long long presentPasses = 0;
    unsigned long long skippedPresentPasses = 0;
    bool lastFrameHadVolume = false;
    bool lastFrameHadMesh = false;
    bool lastFrameHadUi = false;
};
