# Fire Visual Gap Audit

Generated artifacts:

- `out/visual-audit/fire-visual-gap-audit.gif`
- `out/visual-audit/fire-visual-gap-audit.mp4`
- `out/visual-audit/visual-audit-contact-sheet.png`
- `out/visual-audit/visual-metrics.json`

This audit uses existing render artifacts only. No live CUDA kernels were launched.

The image metrics below describe the existing validation frames on disk. They do not include a fresh live render of the new CUDA model fields, because the live kernel path is still gated after recent Windows bugchecks.

## Evidence Snapshot

The current render is visibly wrong in the same way the metrics say it is wrong:

- Target bright fraction above luma 0.68: `0.01619`; current render: `0.00164`. The current frame has about ten times fewer bright flame pixels.
- Target edge energy: `0.02468`; current render: `0.00368`. The current frame has about 6.7x less high-frequency flame/smoke structure.
- Target hot-fire fraction: `0.01923`; current render: `0.00409`. The current frame has much less true hot flame area.
- Target warm-fire fraction: `0.21834`; current render: `0.48673`. The current frame is too broadly amber without enough white/yellow fire core.
- Target luma entropy: `4.69459`; current render: `3.84644`. The current frame has less tonal variation.
- Target hot-fire box spans `x=276..675, y=149..539`; current render spans `x=359..589, y=122..427`. The current flame is narrower, floats high, and misses the wide burning bed.

## 60 Reasons It Looks Fake

1. The whole plume reads as one tan translucent column instead of separate flame tongues.
2. The flame base is mostly a smooth glow, not a burning bed with distinct ignition sites.
3. The central flame lacks white-hot cores.
4. The flame tips do not pinch into thin curling sheets.
5. There are no torn holes through the flame body.
6. The fire does not split into multiple unstable lobes.
7. The current flame silhouette is too vertical and symmetric.
8. The target has three dominant tongues; the current render has a wall-like volume.
9. The lower flame does not crawl laterally across the fuel bed.
10. Flame-front detail is mostly procedural streaking, not combustion-front structure.
11. The smoke is amber/brown instead of dark gray/black soot with warm backscatter.
12. Smoke and flame are not visually separated enough.
13. The smoke plume side boundaries are too smooth.
14. The smoke lacks rolling billows.
15. The smoke lacks nested curls and vortical folds.
16. The smoke does not show entrainment of room air along the sides.
17. The plume does not widen, fold, and collapse as it rises.
18. Smoke density is too uniform across the plume.
19. The smoke top is clipped by the frame instead of organically dissipating.
20. There is not enough black smoke core behind the flame.
21. The ember particles are sparse dots, not a turbulent spark field tied to updraft.
22. Embers are too evenly distributed vertically.
23. Embers do not inherit enough local vortical motion.
24. Embers do not brighten/dim with heat, oxygen, and soot conditions.
25. Embers are disconnected from char/fuel-bed breakup.
26. The floor reflection is a soft orange patch, not sharp/blurred mixed reflection from flame tongues.
27. The tray edge is visually weak compared with the reference.
28. The fuel bed lacks char chunks, ash texture, and glowing coals.
29. The room lighting is too uniformly dim instead of being shaped by fire bounce.
30. The wall soot staining is generated as a static backdrop, not deposited by plume behavior.
31. The renderer lacks contact shadows where smoke/fire occlude room surfaces.
32. The participating media does not cast convincing volumetric shadows.
33. The flame does not self-occlude enough.
34. The smoke does not self-shadow enough.
35. The color ramp is too narrow: amber dominates over white/yellow/red/black variation.
36. The flame temperature mapping is too compressed.
37. The current frame has lower max brightness than the target despite being brighter on average.
38. The current frame has broad warm color but too few hot pixels.
39. The flame edges are too soft where they should be razor-thin sheets.
40. The edge map shows weak high-frequency structure in the current render.
41. Procedural noise is visible as bands/streaks instead of hidden inside physics.
42. The volume has moire-like vertical artifacts near the lower plume.
43. The plume has a billboard/slab feeling from the camera angle.
44. The room geometry looks synthetic and low-detail, which makes the fire feel synthetic too.
45. The camera composition is too close and cropped for the target's fire-bed context.
46. UI overlays hide and flatten the cinematic read in the app frame.
47. The solver does not produce enough small-scale turbulence near the shear layer.
48. The velocity field appears too laminar at the plume boundary.
49. Buoyancy is too dominant relative to lateral turbulent breakup.
50. The pressure projection is visually stable but not producing convincing plume instability.
51. Fuel and oxygen channels do not create intermittent starvation/reignition pockets.
52. The old source was too continuous, so the fire lacked pulsing and stochastic material release.
53. The solid-fuel mass loss model is still reduced and needs real burn calibration.
54. Char/ash layer evolution exists now, but it is still a reduced grid model rather than measured fuel geometry.
55. Soot formation now drives particle-size-derived optical terms, but it is not yet a full particle distribution.
56. Soot oxidation still needs calibration to create the right holes and clearing near hot oxygenated regions.
57. Radiation loss is a local scalar term, not a scene-coupled heat transfer model.
58. The renderer uses approximate single-pass compositing, not enough multiple scattering.
59. Validation targets are image proxies, not real burn measurements.
60. The system can match broad metrics while still missing the actual perceptual grammar of fire.

## Architectural Causes

1. The captured frame was driven by a smooth tray source rather than measured discrete fuel geometry, wetness, material composition, and mass loss.
2. `advectReactKernel` uses reduced oxygen-limited Arrhenius-like terms, but it is not calibrated against a real fuel/ventilation experiment.
3. The combustion model uses coarse grid scalar fields. It does not yet resolve true thin flame sheets.
4. The velocity model uses semi-Lagrangian advection plus buoyancy/curl forcing. The new turbulence-energy field is a reduced LES-style closure, not a calibrated production fire solver.
5. The pressure solve is weighted red/black SOR with 24 iterations. It is stable enough for a demo, but not enough as a production fluid backbone.
6. The renderer maps fields into flame/smoke appearance with procedural domain warping. That makes detail appear, but it does not guarantee physically meaningful detail.
7. Soot is a single scalar. Real smoke needs particle formation, agglomeration, oxidation, optical depth, and size distribution.
8. Radiation is local cooling plus approximate emission. Real fire appearance depends on radiative transfer between flame, smoke, fuel bed, and room.
9. The scene is mostly analytic shading. There is no measured material BRDF, no real tray/fuel geometry, and no deposited soot feedback.
10. The validation harness measures solver stability and image proxies, not real heat-release rate, mass loss, gas velocity, thermocouples, or calibrated HDR video.

## Systems Added In This Pass

1. Fuel-bed state: GPU char and ash fields now evolve from the tray source and heat feedback.
2. Pyrolysis model: a solid-to-vapor release term now feeds fuel vapor and soot production.
3. Flame-front progress variable: transported progress now marks active reaction fronts and drives flame sheet rendering.
4. LES-style turbulence closure: a transported turbulence-energy field is produced from velocity shear and flame activity, then fed back into buoyancy and breakup.
5. Higher-order scalar transport: heat, fuel, oxygen, soot, pyrolysis, progress, turbulence energy, and soot optics now use clamped MacCormack/BFECC correction over the stable semi-Lagrangian backtrace.
6. Soot optical model: soot optical depth is now a separate transported scalar with oxidation feedback, renderer extinction coupling, and particle-size-derived absorption/scattering terms.
7. Volumetric shadowing: the raymarcher now traces short in-volume transmittance through soot optics and progress fields.
8. HDR render path: the CUDA raymarcher now writes linear `float4` radiance first; a separate tone-map kernel applies ACES display mapping and dithering before BGRA presentation.
9. Fuel-bed breakup: the reset/source path now seeds broken char chunks and ash, and pyrolysis is gated by remaining char instead of a uniform orange source.
8. Emitter scattering: smoke scattering and flame emission now use local shadow/transmittance terms instead of flat additive glow.
9. Calibration data layer: validation now accepts `--calibration=<csv>` and `--geometry=<json>` sidecars for HRR, mass loss, thermocouples, IR, video-derived plume height, and experiment geometry.

## Still Missing For A True Digital Twin

1. Pressure solver upgrade: multigrid or PCG with residual targets instead of fixed red/black SOR iterations.
2. Soot particle distribution: formation, oxidation, particle size distribution, agglomeration, and optical-property lookup instead of a reduced optical-depth scalar.
3. Radiation heat-transfer model: coupled radiation from flame/smoke to fuel bed and room, not only local cooling and visual transmittance.
4. Ember physics: particles spawned from char breakup and advected by the local velocity field.
5. Room/material coupling: measured tray geometry, fuel chunks, wall/floor BRDF, soot deposition, and fire-light response.
6. Real calibration dataset: checked-in measured HRR, mass loss, thermocouple, IR/HDR video, and geometry data with provenance.
7. Visual validation layer: compare flame masks, smoke masks, plume width, billow frequency, edge energy, hot-core fraction, reflection strength, and temporal flicker spectra.
8. Progressive render scheduler: keep WDDM-safe kernel slices while accumulating more samples and detail over time.

## Immediate Engineering Direction

The next real jump is not another color tweak. Keep one canonical runtime, but replace the source/combustion/smoke/render stack in this order:

1. Replace the reduced soot optical-depth scalar with a particle-distribution model.
2. Replace fixed-iteration pressure projection with a residual-targeted solve.
3. Fit pyrolysis, soot yield, oxygen consumption, and radiation constants against a real burn dataset.
4. Add temporal visual validation against HRR/video/IR frames.
5. Add sparse-brick volume allocation before raising the active grid.

Until those systems exist, the renderer can look better, but it will still be a stylized fire volume rather than a digital twin.
