# Physics Architecture

The solver architecture is CUDA-only, but the main app viewport process no longer initializes CUDA or submits custom simulation/render kernels. The real 3D volume runs in an isolated CUDA worker process, and the UI receives BGRA frames through shared memory. That separation exists because the live CUDA path has already triggered Windows bugchecks. CPU fire rendering is still not part of the simulation fallback path; if the worker is stale, the UI uses an animated replay preview until real worker frames resume.

The target for physically grounded fire is not "more procedural noise." It needs a solver stack where flame shape emerges from coupled transport, combustion, buoyancy, turbulence, soot, and radiation.

## Minimum Credible Solver

1. Low-Mach incompressible Navier-Stokes on a 3D staggered grid.
2. Semi-Lagrangian or MacCormack advection for velocity, temperature, fuel vapor, oxygen, and soot.
3. Buoyancy force from temperature and density difference.
4. Pressure projection to enforce near-zero divergence.
5. Combustion source terms for fuel/oxygen reaction and heat release.
6. Soot formation/oxidation model.
7. Participating-media rendering with emission, absorption, and single/multiple scattering.
8. Boundary conditions for tray, walls, inflow, exhaust, and solid fuel.
9. Validation against real burn references: plume height, heat release rate, mass loss, temperature probes, RGB/HDR video, and IR where available.

## Current CUDA Runtime

The CUDA backend now uses a bounded 3D MAC-style layout: heat, fuel vapor, oxygen, soot, char, ash, pyrolysis, flame-front progress, turbulence energy, soot optical depth, pressure, and divergence live at cell centers; U/V/W velocity live on staggered faces. Each frame advects velocity, advects/reacts scalar channels, adds buoyancy/wind/turbulence forces, projects velocity with weighted red/black pressure iterations, and raymarches the resulting 3D fields.

The scalar model is now a reduced, calibratable combustion pass rather than a pure visual heuristic. It has a material-seeded fuel bed with broken char chunks and ash, pyrolysis from heat flux and char release, oxygen-limited Arrhenius activation, heat release, soot yield, soot oxidation, radiative cooling, open-air oxygen replenishment, and interactive fuel/smoke injection. Transported scalars use a clamped MacCormack/BFECC correction on top of the stable semi-Lagrangian backtrace to preserve sharper flame fronts without introducing unbounded overshoot.

The turbulence pass is still compact, but it is now tied to resolved velocity shear and flame activity through a scalar LES-style turbulence-energy channel. That channel feeds buoyancy/curl forcing and the renderer's flame breakup terms, so the breakup is driven by transported simulation state instead of only by visual noise.

The renderer now uses blackbody-derived flame emission, Beer-Lambert extinction, soot optical depth, particle-size-derived soot absorption/scattering, raymarched volume shadowing, emitter scattering, ACES display tonemapping, and domain-warped volume sampling. It raymarches into a CUDA `float4` HDR radiance buffer first, then tone-maps and dithers into the BGRA display frame. It samples heat, fuel, oxygen, soot, char, ash, pyrolysis, progress, turbulence energy, and soot optical depth directly instead of drawing named flame or smoke silhouettes. The scene model still provides non-fire context from the reference image: shallow tray, dark reflective floor, smoke-stained back wall, ceiling fixtures, left-side glass, vignette, and warm floor bounce. Embers and gizmos run in a separate overlay kernel so the heavyweight raymarch kernel has one job.

The implementation now has one canonical runtime configuration: requested 384x240 simulation grid, capped internally at 176x208x128, 72 raymarch steps, and 176 ember samples. Crash prevention comes from keeping the main viewport process out of custom CUDA, isolating live CUDA inside the worker process, plus explicit CUDA launch bounds, 12-layer z-sliced volume launches, 36-row raymarch launches, separated render/tonemap/overlay kernels, and the live-kernel safety gate for lab commands. The solver uses 24 weighted red/black pressure iterations, early ray termination, and one final device-to-host display-frame copy. Metrics collection is opt-in through validation.

The UI/worker protocol uses shared memory for the current bridge. It has stable settings sequencing, frame sequence checks, heartbeat timestamps, stale-frame fallback, forced stale-worker termination, restart backoff, and lifecycle event logging. This is the production isolation layer; the transport itself should move to Direct3D/CUDA external memory before this is considered final rendering infrastructure.

## Validation Path

`NativeFireSim.exe --validation` runs the live CUDA path for a deterministic burn sequence, writes `out/validation-metrics.csv`, writes `out/validation-report.json`, and saves raw/app validation frames. The metrics include:

1. Divergence L2/max before and after projection.
2. Divergence reduction across the validation sequence.
3. Heat, fuel, oxygen, soot, char, ash, pyrolysis, progress, turbulence-energy, and soot-optical totals.
4. Heat-release proxy.
5. Mean optical depth.
6. Maximum flame height.
7. Maximum pyrolysis, progress, and turbulence-energy values.
8. Invalid-cell count.
9. GPU solve/render timings.

`--validation --targets=<csv>` additionally checks measured outputs against a target envelope CSV. `benchmarks/reference-fire-room-envelope.csv` is the current target-image proxy envelope, and `benchmarks/target-envelope-template.csv` is the generic starting point for real burn data. Replace proxy rows with measured values when a dataset is available.

`--validation --calibration=<csv> --geometry=<json>` ingests measured burn sidecars. The CSV contract supports HRR, mass remaining, thermocouple readings, IR mean/max temperatures, video-derived plume height, and frame sidecar paths. The JSON sidecar records room, tray, fuel-bed, sensor, and camera geometry. Current comparison reports normalized shape RMSE for HRR, mass loss, thermocouple, and IR series plus direct plume-height RMSE. This makes the validation path ready for a real dataset without claiming that the checked-in proxy image is physical truth.

## Why Exact One-to-One Is Not Free

Real fire depends on material composition, geometry, ventilation, humidity, pressure, scale, ignition, and measurement data. Without those inputs, the best honest target is a validated physically based model, not exact reproduction of an unknown real fire.

## Near-Term Native Milestones

1. Analyze `C:\Windows\Minidump\050126-21062-01.dmp` with symbols before running longer GPU kernels.
2. Replace proxy target envelopes with real burn measurements and version the dataset provenance.
3. Replace the reduced soot-optical scalar with a particle size distribution and optical-property lookup.
4. Replace pressure projection with multigrid or PCG once the validation baselines are stable.
5. Add sparse brick allocation for inactive volume regions before raising the reference grid again.
6. Move rendering to Direct3D/CUDA interop after the solver metrics are stable.
7. Fit material constants against a real burn dataset instead of the current generated-image proxy.
