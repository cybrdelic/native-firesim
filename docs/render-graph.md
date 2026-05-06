# Native FireSim Render Graph

The live viewport has one render graph. Keep future renderer work inside this order unless a PR explicitly changes the graph and updates the verifier.

## Pass Order

1. `clear`
   Clears the FP16 D3D swapchain target.

2. `volume-hdr-camera`
   Samples the CUDA worker's FP16 shared scene-radiance texture and applies the only camera response in the frame: exposure, hue-preserving ACES curve, toe, shoulder, and display gamma.

3. `lit-scene-mesh`
   Draws imported scene geometry after the volume camera pass. Mesh lighting samples the volume texture as scene context, but it does not run the HDR camera response again.

4. `ui-overlay`
   Draws operator UI after world rendering. UI pixels are authored display colors and must not be tone-mapped as fire radiance.

5. `present`
   Presents the FP16 swapchain without vsync. A would-block present is counted as a skipped present instead of blocking the app.

## HDR Contract

The simulation renderer writes linear radiance into the shared D3D texture as `DXGI_FORMAT_R16G16B16A16_FLOAT`. The display path preserves that FP16 payload until the `volume-hdr-camera` pass. Do not add an 8-bit intermediate between CUDA output and the camera response.

The final camera response lives in `CameraResponse` in [src/main.cpp](../src/main.cpp). UI and mesh drawing stay outside that display transform so the flame cannot be clipped by UI compositing and the UI cannot be unintentionally exposed like fire.

## Validation

Run:

```powershell
.\scripts\verify-render-architecture.ps1
.\scripts\verify-roadmap-gates.ps1
```

The render architecture verifier checks the source and diagnostics output for the required FP16 format, named pass graph, single camera-response owner, and UI-after-camera contract.
