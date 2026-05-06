# NativeFireSim Performance Bug Audit

Date: 2026-05-03

This is not a quality downgrade list. These are bug-class performance defects: places where the current implementation does avoidable work, measures the wrong thing, serializes unnecessarily, burns memory bandwidth through representation mistakes, or recomputes data that should already exist.

Current measured baseline from `out/scene-lighting-visible-fast-workerbench/worker-benchmark.json`:

- Effective FPS: `8.254`
- Average frame: `121.153 ms`
- CUDA: `120.896 ms`
- Reaction: `29.069 ms`
- Projection: `19.788 ms`
- Raymarch: `70.097 ms`
- Lighting: `0.250 ms`
- Publish: `0.257 ms`

## 100 Bug-Class Performance Findings

1. `src/fire_cuda.cu:89` hardcodes `kPressureIterations = 40`; the solver always pays 80 SOR kernel launches even when divergence is already low. Fix: convergence-gated or residual-gated pressure iteration with a fixed max.
2. `src/fire_cuda.cu:2612-2615` launches red and black SOR as separate kernels per iteration. Fix: fuse parity in one kernel or replace with multigrid/PCG.
3. `src/fire_cuda.cu:1070` uses weighted SOR on a 3D grid; this is a scalability bug for realtime CUDA because iteration count grows with grid size. Fix: bounded multigrid V-cycle.
4. `src/fire_cuda.cu:2605-2620` runs full-grid projection every frame even when the fire source is localized. Fix: active-region projection tiles or sparse fluid region masks.
5. `src/fire_cuda.cu:2607` passes `g_pressure` into `divergenceKernel` just to clear pressure, mixing two jobs in one launch. Fix: explicit pressure clear only when needed, or fold clear into first solver pass.
6. `src/fire_cuda.cu:2619-2620` runs pressure subtract and wall boundary as separate global passes. Fix: fold wall boundary handling into pressure subtract where possible.
7. `src/fire_cuda.cu:1123-1168` boundary kernels scan the entire max velocity array and branch by component ranges. Fix: separate compact boundary kernels for the six faces.
8. `src/fire_cuda.cu:2605` recomputes `velocityMax` every frame on the host. Fix: cache it at initialization.
9. `src/fire_cuda.cu:2521-2522` recomputes scalar block/grid configuration every frame. Fix: cache launch configs after initialization.
10. `src/fire_cuda.cu:2528-2538` has z-slicing loops even though `kVolumeLaunchDepth = 256` covers the current `nz`. Fix: remove no-op slicing indirection for canonical grids.

11. `src/fire_cuda.cu:446-475` `sampleScalar` does manual tri-linear sampling with 8 global loads and clamp/floor math for every call. Fix: bind scalar fields to CUDA textures or use cached shared/texture fetches.
12. `src/fire_cuda.cu:478-556` duplicates tri-linear code for U/V/W velocity fields. Fix: texture objects or templated inline sampler with precomputed scale factors.
13. `src/fire_cuda.cu:559-560` `sampleVelocity` performs three full tri-linear samplers, so every velocity lookup is 24 global loads. Fix: packed velocity texture or structure-of-arrays texture fetches.
14. `src/fire_cuda.cu:670-694` MacCormack samples each scalar with first-order, current, round-trip, velocity, and neighborhood bounds. Fix: split MacCormack into cached advection passes or use a lower-cost limiter.
15. `src/fire_cuda.cu:884-895` runs MacCormack on eight scalar channels in one thread. Fix: group fields or advect less-critical channels at lower rate.
16. `src/fire_cuda.cu:885-895` recomputes the same backtrace and round-trip velocity for each scalar channel. Fix: compute backtrace data once and reuse for all channels.
17. `src/fire_cuda.cu:690-693` computes limiter bounds per scalar channel, causing another 8 global reads per channel. Fix: use a cheaper monotonic limiter or shared local stencil.
18. `src/fire_cuda.cu:683-692` uses velocity field sampling inside every scalar MacCormack call. Fix: pass the already-sampled `prevVel` into all scalar advectors.
19. `src/fire_cuda.cu:876-878` converts x/y/z to normalized coordinates per cell per frame. Fix: precompute reciprocal dimensions in `SimParams`.
20. `src/fire_cuda.cu:447-449`, `479-481`, `506-508`, and `533-535` clamp every sampler input even for known in-domain interior calls. Fix: add unchecked interior samplers for hot kernels.

21. `src/fire_cuda.cu:900` calls 2D FBM inside `advectReactKernel` for every cell. Fix: precompute source noise into a bed/source texture.
22. `src/fire_cuda.cu:697-706` recomputes procedural fuel-bed material during reset for both current and next buffers. Fix: store static fuel-bed material once.
23. `src/fire_cuda.cu:2402-2409` calls `resetScalarsKernel` twice, recalculating identical procedural fuel bed for current and next fields. Fix: initialize once and copy or use a reset kernel that writes both outputs.
24. `src/fire_cuda.cu:743-745` runs `fuelBedMaterial` and `fuelBedSource` during reset even for cells far above the bed. Fix: early-out on height before noise.
25. `src/fire_cuda.cu:709-714` `fuelBedSource` calls `fuelBedMaterial`, duplicating material computation if caller already has `material`. Fix: pass material into the source function.
26. `src/fire_cuda.cu:900-915` recomputes bed/source terms in reaction instead of using stored char/fuel-bed data. Fix: make bed mask a persistent field.
27. `src/fire_cuda.cu:922-927` computes mouse source `expf` branches for every cell even when controls are inactive. Fix: split active-source kernels or host branch before launch.
28. `src/fire_cuda.cu:999-1051` `forceVelocityKernel` samples heat gradients using 6 tri-linear scalar samples per active cell. Fix: compute gradients in-grid with neighbor loads.
29. `src/fire_cuda.cu:1038-1039` calls two 2D FBMs in the force kernel per cell. Fix: precompute curl/turbulence forcing in a low-res force texture.
30. `src/fire_cuda.cu:1046-1051` uses atomics to write velocity components from every scalar cell. Fix: use staged force buffers and a gather pass per velocity face.

31. `src/fire_cuda.cu:1046` and `src/fire_cuda.cu:1051` both atomic-add to the same `vField[y+1]` location from the same thread. Fix: combine the two contributions before one write.
32. `src/fire_cuda.cu:1047-1048` atomically writes the same U force to two neighboring faces. Fix: compute U-face force in a U-face kernel.
33. `src/fire_cuda.cu:1049-1050` atomically writes the same W force to two neighboring faces. Fix: compute W-face force in a W-face kernel.
34. `src/fire_cuda.cu:1031-1033` heat gradient samples are only used for force but reloaded from global memory instead of using current cell and neighbors. Fix: use direct indexed neighbor reads.
35. `src/fire_cuda.cu:982` decays turbulence after expensive force/noise work. Fix: apply decay in a cheaper scalar update path and only force active cells.
36. `src/fire_cuda.cu:950-962` uses multiple `expf` decays per cell in reaction. Fix: approximate with rational/linear decay or lookup tables where error is acceptable.
37. `src/fire_cuda.cu:957` uses `powf(..., 4.0f)` for radiation loss. Fix: square twice.
38. `src/fire_cuda.cu:935` uses `expf` Arrhenius every cell. Fix: LUT by temperature or polynomial approximation.
39. `src/fire_cuda.cu:1232` recomputes an Arrhenius-like `expf` in metrics. Fix: reuse heat-release proxy from reaction or skip in live mode.
40. `src/fire_cuda.cu:1227-1263` metrics use global atomics over the full grid. Fix: hierarchical block reduction and run only in validation/benchmark builds.

41. `src/fire_cuda.cu:1708-1738` raymarch uses 104 steps at 960x540, which is 53.9 million loop iterations per frame. Fix: empty-space skipping and adaptive step count.
42. `src/fire_cuda.cu:1738` ray loop uses `i < kMaxRaymarchSteps && i < raySteps` instead of a single loop bound. Fix: precompute `raySteps` and loop only on that.
43. `src/fire_cuda.cu:1748-1751` performs four coarse scalar samples before deciding whether to continue. Fix: use a precomputed occupancy/minmax volume.
44. `src/fire_cuda.cu:1757-1758` computes warp FBM before full scalar sampling. Fix: sample coarse occupancy first and skip warp/noise in empty space.
45. `src/fire_cuda.cu:1764-1773` samples ten scalar/light fields after warp on active steps. Fix: pack fields, use textures, or cache active brick data.
46. `src/fire_cuda.cu:1791-1796` computes heat/fuel gradients with 12 extra tri-linear scalar samples per active ray step. Fix: precompute gradients/fronts into a volume.
47. `src/fire_cuda.cu:1802-1805` calls four 3D FBMs per active ray step. Fix: precompute procedural noise volumes or use blue-noise/hashed sparse modulation.
48. `src/fire_cuda.cu:391-399` each FBM3 is 3 value-noise calls; four FBM3s means 12 3D value-noise calls per step. Fix: one shared multi-channel noise sample.
49. `src/fire_cuda.cu:358-377` each valueNoise3 does eight hash calls and interpolation. Fix: texture noise or precomputed tiled volume.
50. `src/fire_cuda.cu:1862` calls `volumeShadow` every active ray step. Fix: precompute shadow/visibility in the scene light volume.

51. `src/fire_cuda.cu:1671-1682` `volumeShadow` does two extra scalar samples and an `expf` per active ray step. Fix: bake it into `g_sceneShadow`.
52. `src/fire_cuda.cu:1872` uses `powf(..., 2.18f)` per active ray step. Fix: LUT/approximation or squared response.
53. `src/fire_cuda.cu:1875` calls `blackbodyColor` per active ray step. Fix: temperature-to-color LUT.
54. `src/fire_cuda.cu:1267-1289` `blackbodyColor` uses `logf`/`powf` branches. Fix: LUT texture or polynomial approximation.
55. `src/fire_cuda.cu:1860-1861` computes two `expf` calls per active ray step for alpha. Fix: approximate optical alpha or precompute extinction response.
56. `src/fire_cuda.cu:1902` computes a third `expf` for transmittance per active ray step. Fix: combine extinction/alpha math.
57. `src/fire_cuda.cu:1714` samples base glow for every pixel, although it is frame-constant. Fix: compute once into params or a tiny constant buffer.
58. `src/fire_cuda.cu:1460-1584` `roomBackgroundRay` is called for every pixel before raymarch occupancy is known. Fix: only shade background for rays that miss/exit or use a cheaper first pass.
59. `src/fire_cuda.cu:1523`, `src/fire_cuda.cu:1539`, `src/fire_cuda.cu:1565`, and `src/fire_cuda.cu:1581` run FBM for room material per pixel. Fix: bake room material textures.
60. `src/fire_cuda.cu:1407-1443` gathers scene irradiance per surface pixel. Fix: precompute wall/floor irradiance maps at lower resolution.

61. `src/fire_cuda.cu:1572-1579` does both a surface local GI sample and a source-probe gather. Fix: use one coherent irradiance representation.
62. `src/fire_cuda.cu:575-607` `sampleSceneLight` is tri-linear over `float4`; source-probe gather calls it four times per surface pixel. Fix: precomputed irradiance atlas or point-light SH fit.
63. `src/fire_cuda.cu:610-620` `sampleSceneShadow` is nearest-neighbor while light is tri-linear, causing extra calls without coherent filtering. Fix: pack shadow into light alpha and sample once.
64. `src/fire_cuda.cu:1347-1385` light propagation reads six neighbors in global memory for every light cell. Fix: use separable blur/shared-memory tile or fewer propagation passes.
65. `src/fire_cuda.cu:2630-2644` builds and propagates scene light every frame even when source fields change slowly. Fix: update lighting at half/quarter rate with temporal reprojection.
66. `src/fire_cuda.cu:1292-1345` `buildSceneLightKernel` samples nine scalar fields per light cell. Fix: build lighting directly from lower-rate emission/extinction fields.
67. `src/fire_cuda.cu:1338` calls `blackbodyColor` inside the light builder. Fix: LUT or reuse emission color computed by combustion.
68. `src/fire_cuda.cu:1337` and `src/fire_cuda.cu:1344` compute two `expf` attenuation values per light cell. Fix: combine extinction/shadow model.
69. `src/fire_cuda.cu:1381-1383` contact bounce is injected during every light propagation, so it is recomputed rather than stored as a surface response. Fix: write bounce into a floor irradiance texture.
70. `src/fire_cuda.cu:2308-2310` light-volume dimensions are derived from sim dimensions but capped without explicit performance budget. Fix: make radiance volume resolution budgeted and measured.

71. `src/fire_cuda.cu:2012-2068` embers are drawn with per-ember bounding-box pixel loops and atomic adds. Fix: rasterize embers as instanced quads in D3D or a tiled splat kernel.
72. `src/fire_cuda.cu:2064-2066` performs three atomicAdd operations per affected ember pixel. Fix: write one packed color or use additive blend in D3D.
73. `src/fire_cuda.cu:2022-2040` recomputes camera projection and hashes for each ember every frame. Fix: maintain ember particle state buffers.
74. `src/fire_cuda.cu:2023` samples base glow once per ember, although it is frame-constant. Fix: pass precomputed base glow.
75. `src/fire_cuda.cu:2061` uses `expf` for every ember pixel. Fix: small radial texture/lookup.
76. `src/fire_cuda.cu:2711-2715` runs ember kernel after raymarch as a separate pass. Fix: integrate embers into D3D overlay or composite pass.
77. `src/fire_cuda.cu:1992-2010` FP16 pack is a separate kernel after raymarch. Fix: render directly to the FP16 surface or use CUDA surface writes in render.
78. `src/fire_cuda.cu:2721-2744` maps/unmaps the D3D resource every frame. Fix: persistent interop resources with explicit fence/semaphore ownership.
79. `src/fire_cuda.cu:2727-2743` creates and destroys a CUDA surface object every frame. Fix: create once when registering the D3D texture.
80. `src/main.cpp:2207-2208` copies from CUDA texture to shared texture and flushes every worker frame. Fix: render directly into the shared ring slot or use keyed texture as the CUDA target.

81. `src/main.cpp:948-1044` host copies every ready shared slot in sorted order, not just the newest. Fix: read `latestFrameSlot` and copy only newest complete frame.
82. `src/main.cpp:1005-1010` sorts at most three slots every UI frame. Fix: avoid sort entirely with latest-slot metadata.
83. `src/main.cpp:1016` uses `AcquireSync(1, 0)` on each ready slot. Fix: nonblocking latest-only acquire.
84. `src/main.cpp:1028` copies the shared texture into a display texture every host frame. Fix: bind the shared texture SRV directly when possible.
85. `src/main.cpp:2208` calls `Flush` every worker frame, forcing D3D command submission. Fix: use fence/query only when publishing or benchmarking.
86. `src/main.cpp:1876-1891` busy-waits D3D query completion with `Sleep(0)`. Fix: do not run completion waits in live mode.
87. `src/main.cpp:1988-1998` worker benchmark includes an extra shared texture copy and D3D completion wait. Fix: benchmark CUDA-only and publish path separately.
88. `src/main.cpp:1596-1598` writes full settings through shared memory every UI frame even if unchanged. Fix: dirty-bit settings publication.
89. `src/main.cpp:1601-1615` worker retries stable settings reads and can `Sleep(0)` on torn updates. Fix: double-buffer settings or atomic pointer/version.
90. `src/main.cpp:2148-2230` worker acquires a keyed mutex before CUDA rendering, holding a publish slot during the whole CUDA frame. Fix: render first, acquire only for the short publish/copy.

91. `src/main.cpp:2158-2170` worker spins through all slots and sleeps if none can be acquired. Fix: acquire only at publish time or skip publish without delaying simulation.
92. `src/main.cpp:2205-2228` frame sequence is incremented twice per frame and shared as global plus slot state. Fix: one monotonic per-slot publish counter.
93. `src/main.cpp:3303-3306` host composes a full 960x540 CPU overlay buffer every frame even when only text/status changed. Fix: draw UI in D3D or cache static chrome.
94. `src/main.cpp:596-599` zero-fills the full overlay buffer every frame. Fix: persistent transparent overlay texture and dirty rect updates.
95. `src/main.cpp:530-588` redraws all app chrome text and sliders every frame on CPU. Fix: D3D text/quad renderer or cached UI atlas.
96. `src/main.cpp:500-507` CPU blit path exists for full-frame viewport copy; stale/fallback paths can still burn CPU. Fix: remove fallback path or guard it behind diagnostics only.
97. `src/main.cpp:3309-3310` calls `InvalidateRect` and immediate `UpdateWindow` every loop, forcing synchronous paint. Fix: let WM_PAINT/message pump schedule presentation.
98. `src/main.cpp:3324-3331` the 300 FPS host loop sleeps/yields independently of worker frame readiness. Fix: event-driven present on new worker frame plus idle UI ticks.
99. `src/main.cpp:30-35` canonical dimensions/ray steps are hardcoded in UI constants, making perf budget invisible to runtime validation. Fix: central performance contract with enforced frame budget.
100. `src/fire_cuda.cu:2323-2367` allocates 20+ separate scalar/velocity buffers as individual global allocations. Fix: arena allocation and packed field layouts to improve locality and reduce allocation/registration overhead.

## Highest-Leverage Fix Order

1. Replace manual scalar/velocity tri-linear samplers with CUDA texture objects or packed cached samplers.
2. Remove repeated MacCormack backtrace/velocity work across scalar channels.
3. Precompute raymarch occupancy, gradients, shadow, and noise into lower-rate volumes.
4. Replace red/black SOR with a bounded multigrid/PCG pressure solve.
5. Render directly to the shared FP16 ring slot and remove per-frame CUDA surface creation plus D3D texture copies.
6. Move UI overlay/chrome out of CPU full-frame redraw.
7. Keep metrics and validation reductions out of live/worker benchmarking unless explicitly profiling.

## Fixes Landed In This Pass

- Items 16 and 18: MacCormack scalar advection now computes the reverse velocity once per cell and passes the current scalar sample into each channel instead of resampling the same velocity/current state per scalar.
- Items 28, 31, 34, and 37: the reaction/force path now uses direct indexed heat and MAC-face reads for gradients/shear, combines duplicate vertical atomics, and replaces the fourth-power radiation `powf` with square-square math.
- Items 42, 46, 47, 50, 51, and 52: the raymarch loop now uses one loop bound, removes fuel-gradient tri-linear samples, derives plume/hole modulation from two 3D FBM samples instead of four, uses the scene shadow volume instead of per-step `volumeShadow`, and replaces the radiant `powf` curve with a multiply polynomial.
- Items 81, 82, 83, 88, 90, and 91: the D3D worker path now uses a three-slot shared FP16 ring, copies only the newest complete slot, avoids sorting/draining stale slots, publishes settings only when fields actually change, and holds keyed mutexes only during the short publish/copy window.
- Items 40, 86, 87, and 93-98: live worker benchmark timing no longer includes full-grid metrics reductions in render/raymarch timings, the benchmark separates live frame timing from sampled GPU breakdowns, and the host UI is dirty-driven instead of repainting synchronously every 300 Hz tick.
- Visual/perf coupling fix: the scalar update now has a conservative cold-air early-out above the fuel bed, and upper/open-boundary entrainment is stronger so stale heat/soot/progress does not keep the whole volume active indefinitely.

Validation evidence from this pass:

- `out/perf-pass-coldair-validation48/validation-report.json`: validation passed; sampled solve `54.41 ms`, render `8.21 ms`, reaction `26.05 ms`, projection `26.78 ms`, raymarch `7.79 ms`.
- `out/perf-pass-coldair-workerbench/worker-benchmark.json`: live worker benchmark passed; live frame `81.55 ms`, effective `12.26 FPS`, with metrics sampled outside the live timing loop.
- Sustained plume runs are still much slower after the dense volume fills; `out/perf-pass-coldair-workerbench-warm20/worker-benchmark.json` measured `208.42 ms` live frames. That is now identified as the dense full-grid SOR/MacCormack architecture, not the display path or UI repaint loop.

Remaining architectural blockers:

- The pressure solver is still 40 fixed red/black SOR iterations, so sustained frame time is dominated by projection once the plume is active.
- Scalar transport still MacCormack-advects many separate scalar arrays across the full dense grid. Cold-air early-out helps empty cells, but a canonical fast path needs sparse active tiles or a packed/texture-backed scalar layout.
- The worker still renders into one CUDA interop texture and publishes through a D3D shared ring copy. Directly rendering into the publish slot or using a persistent surface/fence path is still open.

## Live Viewport 100 FPS Profile Fix

The live 1 FPS report was not caused by the CUDA raymarch benchmark path. The slow path was the Windows presentation and interprocess transport loop:

- The UI originally invalidated/painted through `WM_PAINT`, so DWM message coalescing hid where time was spent.
- The host then presented duplicate stale frames at the 300 FPS app-loop rate, stealing GPU time from the worker.
- The worker published frames without pacing, which could flood the D3D queue.
- Adding a D3D completion query to every live publish made the handoff correct but exposed a separate 60 Hz cap.
- The remaining hard cap was `Sleep(1)` inside the worker process using the default Windows timer quantum. The main app had called `timeBeginPeriod(1)`, but the isolated worker had not.

Fixes now landed:

- The main loop presents directly from the render loop and records live copy/present timing.
- The swap chain uses flip-model FP16 presentation when supported.
- `Present` is non-blocking, so a full compositor queue drops a present instead of stalling the app thread.
- The host presents only on fresh worker frames or overlay changes, not on every stale-frame tick.
- The worker uses a paced 180 FPS publish target and owns its own `timeBeginPeriod(1)` scope.
- The worker can reclaim stale ready slots from the keyed-mutex ring instead of freezing when the host misses a frame.
- CUDA worker settings disable CUDA-side gizmos; the host UI overlay owns gizmos so the volume renderer does not redraw controls.

Current evidence from this pass:

- `out/current-render-only/worker-benchmark.json`: render-only worker benchmark passed at `5.41 ms`, `184.92 FPS`.
- `out/current-sim240/worker-benchmark.json`: physics-decoupled worker benchmark passed at `5.45 ms`, `183.36 FPS`.
- Live bounded run after the timer-resolution fix showed `wrk 171-180fps` and `copyHz 153-179`, clearing the requested 100 FPS target in the live CUDA viewport.

## Post-Merge Performance Pass

Date: 2026-05-04

This pass started from merged `main` after PR #3. Quality settings stayed fixed: `raymarchSteps=104`, `emberCount=176`, `pressureIterations=40`, and requested grid `384x240`.

Baseline:

- `out/postmerge-baseline-workerbench/worker-benchmark.json`: full physics benchmark passed at `88.12 ms`, `11.35 FPS`.
- Baseline sampled GPU breakdown: velocity `5.72 ms`, reaction `26.00 ms`, projection `35.14 ms`, lighting `0.31 ms`, raymarch `15.85 ms`, pack `4.84 ms`.

Kept fixes:

- Replaced full-grid red/black SOR launches with a compact parity launch. This keeps the same 40 pressure iterations and same pressure math, but does not launch threads that immediately return for the inactive checkerboard color.
- Removed the live worker's per-frame D3D immediate-context `Flush()` after copying the private CUDA/D3D FP16 texture into the shared keyed-mutex ring. Keyed mutex release still publishes key `1`, and live capture confirmed the host still receives frames.

Rejected experiment:

- A 2D compact parity launch was rejected. It regressed the full physics benchmark to `106.74 ms`, `9.37 FPS`, and the live-like `--sim-every-frames=30` benchmark to `23.61 ms`, `42.35 FPS`.

Final evidence:

- `out/postmerge-final-candidate-workerbench/worker-benchmark.json`: full physics benchmark passed at `71.28 ms`, `14.03 FPS`.
- `out/postmerge-final-candidate-sim30-workerbench/worker-benchmark.json`: live-like `--sim-every-frames=30` benchmark passed at `15.02 ms`, `66.57 FPS`.
- `docs/pr-assets/screenshot-postmerge-performance-pass.png`: live viewport capture showed `wrk 143-146fps`, worker publish around `6.6-6.8 ms`, and `copyHz 39-40/52-53` with frames still visible.

Remaining blockers:

- The dense full-grid pressure solve is still the largest physics-side blocker. Compact parity reduces wasted work, but a real jump still needs a bounded multigrid/PCG pressure path or sparse active projection tiles.
- The render-only/live-like path is now more limited by raymarch/pack/publish cadence than UI sleep, so the next exact pass should target persistent CUDA surface ownership or direct shared-slot rendering before changing visual quality.

## Room-Aware Render Performance Pass

Date: 2026-05-05

This pass keeps the same CUDA quality settings and improves the room without increasing the visible-frame cost:

- `renderKernel` now raymarches the fire volume before shading the room. If accumulated smoke/fire opacity makes the background contribution negligible, the room shader is skipped for that pixel.
- `roomBackgroundRay` no longer uses FBM for floor marble, reflection streak offsets, window grain, or final room grain. Those were expensive per-pixel procedural calls that made the room read synthetic.
- The room now uses analytic panel seams, ceiling ribs, wall base/crown shadow, a back-wall recess, tray contact darkening, and a cooler floor scorch. These are cheap masks, not extra volume samples.
- Scene irradiance gathering now uses the three lower flame probes instead of four probes, avoiding a warm upper-plume probe that made the room wash out.

Validation evidence:

- `out/room-perf-pass-final-workerbench-rerun/worker-benchmark.json`: full physics benchmark passed at `60.21 ms`, `16.61 FPS`.
- `out/room-perf-pass-final-sim30-workerbench/worker-benchmark.json`: live-like `--sim-every-frames=30` benchmark passed at `5.88 ms`, `170.00 FPS`.
- `docs/pr-assets/screenshot-room-performance-pass.png`: live viewport capture showed visible room panels/scorch, worker around `119 FPS` in the sustained capture, and frames still visible through the FP16 path.

Compared with the previous post-merge evidence:

- Full physics improved from `71.28 ms` / `14.03 FPS` to `60.21 ms` / `16.61 FPS` on the kept rerun.
- Live-like decoupled frames improved from `15.02 ms` / `66.57 FPS` to `5.88 ms` / `170.00 FPS`.

## Profiling And Fresh-Frame Pacing Pass

Date: 2026-05-05

The Pulse CUDA profiling checklist maps directly to this repo, but FireSim had only coarse CUDA event timings before this pass:

- Existing coverage: `--worker-benchmark` records section timings for velocity, reaction, projection, lighting, raymarch, and pack.
- New coverage: `scripts/profile-cuda-kernels.ps1` runs the canonical worker benchmark and can wrap it in Nsight Compute with launch filters, launch counts, imported source, and `basic`/`detailed`/`full` section sets.
- Current local blocker: Nsight Compute is installed, but hardware performance counters are restricted for this user. `-NsightSet basic` reaches the target process and then fails with `ERR_NVGPUCTRPERM` until the command runs elevated or NVIDIA Control Panel allows GPU performance counters for all users.

Frame pacing fix:

- The window title now reports fresh copied CUDA frames instead of duplicate D3D presents. This prevents a misleading `250 FPS` title when the host is only copying a much lower number of worker frames.
- The host presents on copied worker frames or overlay changes, not on every fresh metadata tick.
- The D3D UI texture is uploaded only when the overlay changes or the CPU fallback is active. Fresh CUDA frames no longer pay a full 960x540 CPU overlay upload when the chrome is unchanged.

Room lighting fix:

- The room ambient/material response was too bright and gray. Room albedo, GI scale, ceiling/floor/wall base values, and the final room distance multiplier are darker now so the fire reads as the room's primary light source.

Validation evidence:

- `out/profile-room-pacing-sim30-workerbench/worker-benchmark.json`: live-like `--sim-every-frames=30` benchmark passed at `5.81 ms`, `172.02 FPS`.
- `out/profile-room-pacing-full-workerbench/worker-benchmark.json`: full physics benchmark passed at `60.55 ms`, `16.52 FPS`.
- `out/cuda-profile-smoke/worker-benchmark/worker-benchmark.json`: profiling script benchmark mode passed and wrote `profile-commands.md`.
- `out/cuda-profile-ncu-smoke/firesim-speedoflight.ncu-rep`: Nsight Compute command path connected and captured launch-level data with the initial no-metric set.
- `out/cuda-profile-ncu-smoke-basic`: confirmed the useful `basic` set is blocked by `ERR_NVGPUCTRPERM` on this Windows user session.

## Live Physics Stutter Fix

Date: 2026-05-05

The consistent stutter came from two fixed live-loop rhythms:

- The worker advanced physics every 30 render frames, and a physics frame also paid for full raymarch and FP16 publish. That made the expensive frame arrive on a predictable cadence.
- Render-only frames use a temporal row budget; the kernel only understood the hardcoded `32` case, which made the pacing rule brittle and hid the actual cadence from parameters.

Kept fix:

- Added `fireCudaStepD3D11()`, a step-only CUDA path that advances the simulation without raymarching or publishing a D3D frame.
- The live worker now uses step-only frames for physics and publishes on render-only frames. That removes full raymarch/pack/publish cost from the periodic physics spike.
- Generalized render subsampling from a hardcoded `== 32` branch to `renderSubsample > 1`, keeping the current 32-row budget but making the cadence explicit.
- The window title now reports successful visual presents for the headline FPS instead of copied worker frames.

Rejected experiments:

- Full-frame render-only (`renderSubsample = 1`) removed row reuse but overloaded dense plume rendering in live use.
- 8-row and 16-row render budgets were smoother spatially but dropped the live-like benchmark to roughly `41-46 FPS`.
- Blocking/vsync present removed dropped presents but caused the host to wait behind dense GPU work and worsened visible stalls.

Validation evidence:

- `verify.ps1 -DiagnosticsOnly`: passed after the step-only path.
- Live telemetry after the kept fix showed startup visual presents around `110-135 FPS`, then mostly `90-120 FPS` visual presents and `70-100 Hz` copied fresh frames as the plume filled, instead of the earlier `1-4 FPS` spiral from the rejected experiments.

Remaining architectural fix:

- This shortens the periodic hitch; it does not eliminate the underlying single-state coupling. The complete fix is a double-buffered/asynchronous simulation-render split: physics writes a back simulation state, render samples the latest complete front state every display frame, and the front/back fields swap only at simulation barriers.

## Double-Buffered Render-State Split

Date: 2026-05-05

The remaining coupling was inside CUDA state ownership:

- Render-only frames still sampled the solver's current `g_heat`, `g_fuel`, `g_soot`, velocity, and scene-light pointers.
- Step-only physics frames incremented the render phase even though no pixels were rendered, so the temporal renderer skipped a phase on a fixed cadence.
- The original temporal budget selected rows. That made partial-frame reuse show up as horizontal bands; a naive per-pixel phase removed bands but broke warp coherence and regressed live-like rendering to `12.76 ms` / `78.37 FPS`.

Kept fix:

- Added two CUDA render snapshot slots for all render-visible scalar fields, MAC velocity fields, scene radiance, and scene shadow.
- Physics writes the normal solver buffers, then publishes a complete back snapshot and swaps it to front only after advection, reaction, projection, and scene-lighting finish.
- Render and pack kernels now read only the current front snapshot, not solver-owned mutable fields.
- Step-only physics no longer increments the render phase. Only actual rendered frames advance the temporal phase.
- Replaced row-only temporal phasing with coherent 16x16 tile phasing. This removes hard horizontal/vertical/diagonal update lines while keeping whole CUDA blocks coherent.
- Split simulation time from render time so render-only visual motion does not advance the solver clock.

Validation evidence:

- `verify.ps1 -DiagnosticsOnly`: passed after the render-state split.
- `out/snapshot-tilephase-sim30/worker-benchmark/worker-benchmark.json`: live-like `--sim-every-frames=30` benchmark passed at `3.55 ms`, `281.40 FPS`.
- `out/snapshot-tilephase-full/worker-benchmark/worker-benchmark.json`: full-physics benchmark passed at `55.38 ms`, `18.06 FPS`.
