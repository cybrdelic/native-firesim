# Lab-Grade Fire Roadmap

NativeFireSim is not lab-grade until it can state a scoped prediction claim, cite the experiment used for that claim, and report error and uncertainty against measured burn data. Photorealism is a separate target.

## External Baseline

The credible reference model is the NIST FDS project shape:

- FDS is an LES code for low-speed flows with emphasis on smoke and heat transport from fires: https://pages.nist.gov/fds/
- The FDS manual set is split into user guide, technical reference, verification guide, validation guide, and configuration-management plan: https://pages.nist.gov/fds/manuals.html
- The public FDS repository keeps `Verification` and `Validation` trees next to source and manuals: https://github.com/firemodels/fds
- NIST's fire-model V&V process emphasizes model uncertainty plus transparent QA for open-source fire code: https://www.nist.gov/publications/verification-and-validation-process-fire-model
- NIST's Fire Calorimetry Database contains measured NFRL fire experiments with calorimetry over 50 kW to 20000 kW, including controlled burners, well-characterized fuels, rooms, and real composite fuels: https://www.nist.gov/el/fcd
- NRC NUREG-1824 is the regulatory-grade example for reporting ranges of accuracy for fire models, using test data and ASTM-style model evaluation: https://www.nrc.gov/reading-rm/doc-collections/nuregs/staff/sr1824/s1/index
- ASTM E1355 says fire-model evaluation is for a specific use; validation in one scenario does not transfer automatically to another: https://store.astm.org/e1355-23.html
- ASME V&V 20 frames CFD/heat-transfer validation as comparison of solution and data while accounting for uncertainty in both: https://www.asme.org/codes-standards/find-codes-standards/standard-for-verification-and-validation-in-computational-fluid-dynamics-and-heat-transfer

## Lab-Grade Definition

For this project, lab-grade means:

1. Scoped use claim: for example, "methanol pool fire plume height and HRR in an open-front room," not "all fire."
2. Theory record: equations, closures, assumptions, boundary conditions, units, and solver limits are documented.
3. Code verification: kernels have deterministic unit/probe cases, conservation checks, manufactured or analytic comparison where possible, and grid/time-step convergence studies.
4. Experimental validation: measured HRR, mass loss, thermocouples, IR, RGB/HDR video, plume geometry, smoke/optical-depth proxies, room/fuel geometry, and sensor/camera positions.
5. Uncertainty accounting: each measured channel has units, uncertainty, sample rate, calibration notes, and preprocessing provenance.
6. Error envelope: validation reports include bias/error by quantity and scenario, not one global pass/fail.
7. Configuration management: every validation report records commit hash, compiler/toolkit/driver, GPU, solver constants, grid, timestep, raymarch settings, and input dataset hash.
8. Scope limits: the report states where the model is not validated.

## First Validation Ladder

1. Controlled burner with prescribed HRR.
   - Goal: decouple gas plume/render validation from solid-fuel pyrolysis.
   - Required channels: HRR curve, room geometry, camera calibration, thermocouple tree, plume height video.
   - Expected result: match plume height, temperature trend, smoke transport, and visual silhouette without tuning fuel chemistry.

2. 1 m methanol pool fire.
   - NIST FCD includes "Characteristics of a 1 m Methanol Pool Fire."
   - Goal: validate liquid fuel flame structure, HRR, visible plume, and soot-light behavior on a simpler fuel than mixed solid material.

3. Medium-scale pool fire.
   - NIST FCD includes "Structure of Medium-Scale Pool Fires."
   - Goal: validate scaling and plume structure across fire sizes.

4. Furnished room/kitchen fire.
   - NIST FCD includes "Kitchen Room Fire" and design-fire room/furniture experiments.
   - Goal: validate enclosure behavior, smoke layer, wall/floor heat feedback, and complex fuel growth.

5. Solid-fuel char/ash/pyrolysis case.
   - Goal: validate this repo's char, ash, mass-loss, soot, and pyrolysis model against measured material data.

## Current Project Gaps

- `benchmarks/nist-fcd/methanol-1m-pool-r1` now provides the first real NIST FCD calibration dataset for HRR, gas, radiant heat-flux, smoke extinction, and derived fuel mass.
- `benchmarks/real-burn-calibration-template.csv` remains a template, not evidence.
- The first real dataset does not include numeric IR-frame, thermocouple, or plume-height channels, so those validation claims still need another dataset or sidecar extraction pass.
- Geometry sidecar exists but does not yet carry full sensor uncertainty, camera calibration, surface/material properties, or ventilation conditions.
- Validation compares normalized curve shapes; lab-grade needs dimensional error, uncertainty, bias, and confidence intervals.
- Pressure projection is fixed-iteration weighted SOR, not residual-targeted multigrid/PCG.
- Chemistry is reduced. It needs explicit, documented closure constants and calibration bounds.
- Soot optics are reduced to transported fields and particle-size-derived optical terms, not a full particle distribution.
- Radiation is still approximate and not scene-coupled enough for wall/fuel heat feedback.
- The app still transports final frames as BGRA through shared memory; internal HDR exists, but final lab image capture needs calibrated HDR/EXR output.

## Required New Systems

1. Dataset registry:
   - manifest per experiment
   - raw-file hashes
   - source URL/DOI/license
   - unit declarations
   - channel uncertainty
   - preprocessing script reference

2. Validation runner:
   - no-GPU structural checks
   - optional live CUDA validation
   - deterministic seeds/settings
   - one output directory per experiment and commit

3. Measurement extractors:
   - HRR and mass-loss curve comparison
   - thermocouple interpolation at sensor locations
   - IR mean/max comparison
   - RGB/HDR flame mask, plume height, and silhouette error
   - smoke optical-depth proxy

4. Numerical verification:
   - kernel invariant probes
   - divergence residual history
   - grid/time-step convergence
   - scalar mass/oxygen/energy budgets
   - TDR-safe per-kernel duration budget

5. Scientific report:
   - experiment scope
   - model version and configuration
   - measurement uncertainty
   - validation metrics
   - pass/fail by quantity
   - known nonvalidated regimes

## Next Dataset Move

The first import target is complete: NIST FCD `Methanol_1m_Pool_R1`. The next dataset should add the missing image-space and sensor channels: controlled-burner or methanol-pool records with thermocouple trees, calibrated IR frames, or extractable plume-height video sidecars.
