# Reference Target

`assets/reference-fire-room.png` is the active visual target for the CUDA renderer.

Measured image proxies:

- Resolution: 1536x1024
- Mean luminance: 0.185796
- Max luminance: 0.988728
- Bright-pixel fraction above luma 0.68: 0.014217

The canonical runtime is built around that target:

- requested simulation grid: 384x240
- internal cap: 176x208x128
- raymarch steps: 72
- ember samples: 176
- darker soot extinction
- stronger glossy floor reflection
- target-room shading: tray, reflective dark floor, wall smoke, ceiling fixtures, left glass, vignette

Run only after the driver crash path is understood:

```powershell
.\build\NativeFireSim.exe --validation --targets=benchmarks\reference-fire-room-envelope.csv --allow-gpu-kernels --accept-bugcheck-risk
```

The target envelope is an image/solver proxy. It is not a substitute for measured burn data such as HRR, mass loss, thermocouple probes, gas velocity, or IR.
