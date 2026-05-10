#pragma once

#include <array>

#include <d3d11.h>
#include <dxgi.h>
#include <wrl/client.h>

constexpr int kD3DSharedFrameSlots = 3;
constexpr int kD3DDisplayFrameSlots = 3;
constexpr int kSharedFrameSlots = kD3DSharedFrameSlots;
constexpr int kDisplayFrameSlots = kD3DDisplayFrameSlots;

struct DisplayConstants {
    float exposure;
    float padding[3];
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
    Microsoft::WRL::ComPtr<ID3D11Texture2D> uiTexture;
    Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> uiSrv;
    Microsoft::WRL::ComPtr<ID3D11SamplerState> sampler;
    Microsoft::WRL::ComPtr<ID3D11VertexShader> vertexShader;
    Microsoft::WRL::ComPtr<ID3D11PixelShader> simPixelShader;
    Microsoft::WRL::ComPtr<ID3D11PixelShader> uiPixelShader;
    Microsoft::WRL::ComPtr<ID3D11Buffer> displayConstants;
    Microsoft::WRL::ComPtr<ID3D11BlendState> alphaBlend;
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
    unsigned long long uiOverlayPasses = 0;
    unsigned long long presentPasses = 0;
    unsigned long long skippedPresentPasses = 0;
    bool lastFrameHadVolume = false;
    bool lastFrameHadUi = false;
};
