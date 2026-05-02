# Calibration Benchmarks

This folder separates target-image matching from real burn calibration.

Use `reference-fire-room-envelope.csv` only as a visual proxy for the generated target image. It is not physical truth.

Use `real-burn-calibration-template.csv` for measured burn data templates:

- `hrrKW`: heat release rate from calorimetry.
- `massRemainingKg`: fuel-bed mass over time.
- `tc_*_C`: thermocouple readings in Celsius. The validator compares their mean shape.
- `irMeanC` and `irMaxC`: calibrated IR frame temperatures.
- `plumeHeightM`: video-derived flame/plume height in meters.
- `videoFramePath` and `irFramePath`: frame sidecars for future image-space validation.

Use `geometry-template.json` for room, tray, fuel, sensor, and camera geometry. Validation accepts it with `--geometry=<json>` and records whether the sidecar is readable.

Use `lab-grade-manifest-template.json` for dataset provenance. It records the source URL/DOI/license, raw/processed file paths, hashes, measurement channels, uncertainty notes, and preprocessing command.

The first checked-in real dataset is `nist-fcd/methanol-1m-pool-r1`. Rebuild it from NIST FCD with:

```powershell
.\scripts\import-nist-fcd-methanol-r1.ps1 -Force
```

That dataset has direct HRR, gas, radiant heat-flux, and smoke-extinction channels plus derived fuel-mass and optical-depth columns. It does not claim IR-frame, thermocouple, or plume-height calibration because those are not numeric channels in the FCD CSV export.

Run the no-GPU lab-grade preflight:

```powershell
.\scripts\verify-lab-grade.ps1
```

Use this before admitting a real measured burn dataset:

```powershell
.\scripts\verify-lab-grade.ps1 -RequireRealDataset
```

Current validation compares normalized curve shapes for HRR, mass loss, thermocouples, and IR because no real dataset is checked in. Once a measured dataset exists, replace the proxy envelopes with experiment-specific tolerances and add target rows such as:

```csv
calibrationHrrShapeRmse,0.00,0.18
calibrationMassShapeRmse,0.00,0.18
calibrationThermocoupleShapeRmse,0.00,0.22
calibrationIrMeanShapeRmse,0.00,0.22
calibrationIrMaxShapeRmse,0.00,0.22
calibrationPlumeHeightRmseMeters,0.00,0.18
```
