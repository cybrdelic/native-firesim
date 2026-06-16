# Intervention Plan: native firesim cuda worker nist calibration validation d3d shared viewport fire settings volume metrics lab-grade gpu risk benchmark build

These actions are designed to reduce uncertainty. Do not promote frames without recording the resulting observation.

## 1. `native-firesim.pipeline.ui-to-worker-to-viewport`

- status/confidence: `inferred` / `0.85`
- state: Native FireSim presents live fire through a process-isolated CUDA worker rather than by running CUDA kernels inside the UI process.
- mechanism: visible_frame := ui_present(copy(shared_fp16_d3d11_texture(worker_render(step(settings)))))
- discriminating question: If `native-firesim.contract.shared-viewport-buffer` is perturbed, does `Native FireSim presents live fire through a process-isolated CUDA worker rather than by running CUDA kernels inside the UI process.` change in the predicted direction?
- intervention: `run NativeFireSim.exe with default worker path and inspect out/worker-events.log`
- observation to record: Record command/log/test/screenshot evidence tied to `README.md`.

## 2. `native-firesim.mechanism.cuda-volume-step`

- status/confidence: `inferred` / `0.84`
- state: The CUDA backend advances and renders a 3D fire volume from FireSettings through field advection, reaction, pressure projection, lighting, raymarching, and packing.
- mechanism: frame_pixels, metrics := pack(raymarch(light(project(react(advect(fields, settings))))))
- discriminating question: If `native-firesim.contract.fire-settings` is perturbed, does `The CUDA backend advances and renders a 3D fire volume from FireSettings through field advection, reaction, pressure projection, lighting, raymarching, and packing.` change in the predicted direction?
- intervention: `run smoke test with accepted GPU risk and compare cuda-smoke-test-frame.bmp to expected nonblank output`
- observation to record: Record command/log/test/screenshot evidence tied to `src/fire_cuda.cu`.

## 3. `native-firesim.presentation.d3d-ui-compositor`

- status/confidence: `inferred` / `0.82`
- state: The UI compositor copies the latest shared worker FP16 texture into the D3D display path and overlays operator UI/status.
- mechanism: swapchain_frame := compose(displaySimTexture(copy_worker_slot), uiTexture(status_overlay(settings, worker_status)))
- discriminating question: If `native-firesim.contract.shared-viewport-buffer` is perturbed, does `The UI compositor copies the latest shared worker FP16 texture into the D3D display path and overlays operator UI/status.` change in the predicted direction?
- intervention: `feed a fixed worker texture slot and checksum displayed pixels`
- observation to record: Record command/log/test/screenshot evidence tied to `src/main.cpp`.
