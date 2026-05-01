# Physics Architecture

The current app is not a one-to-one digital twin of fire. It is a native sandbox with a safe preview path and an opt-in CUDA visual prototype.

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

## Why Exact One-to-One Is Not Free

Real fire depends on material composition, geometry, ventilation, humidity, pressure, scale, ignition, and measurement data. Without those inputs, the best honest target is a validated physically based model, not exact reproduction of an unknown real fire.

## Near-Term Native Milestones

1. Replace the 2D scalar field with a 3D MAC grid.
2. Add pressure projection and divergence checks.
3. Add fuel/oxygen/temperature/soot channels.
4. Add a bounded validation harness that reports conservation drift and divergence.
5. Move rendering to Direct3D/CUDA interop only after the solver is stable.
