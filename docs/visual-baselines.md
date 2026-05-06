# Native FireSim Visual Baselines

These baselines define what each scene is supposed to look like before a PR can claim visual improvement. They are intentionally scene-specific. A gas burner, campfire, and room sandbox fire should not converge into one generic orange plume.

## Capture Source

Use the repeatable capture set:

```powershell
.\scripts\verify-visual-regression.ps1 -Capture -AcceptBugcheckRisk
```

The command writes:

- `out/scene-visual-audit/room/validation-frame.bmp`
- `out/scene-visual-audit/campfire/validation-frame.bmp`
- `out/scene-visual-audit/burner/validation-frame.bmp`
- `out/scene-visual-audit/scene-contact-sheet.png`
- `out/scene-visual-audit/scene-visual-audit.json`

## Room Fire Baseline

The room scene is the neutral sandbox. It should show visible warm flame coverage and room-scale smoke without turning into a full-height rectangular slab.

Target traits:

- warm flame coverage is visible from the default camera
- plume height stays below a full-volume curtain
- smoke is visible but not a flat gray screen
- room remains dark enough that fire is the dominant light source
- UI/debug overlays must not disappear when switching into the scene

Audit warnings to watch:

- `room fire has too little warm flame coverage`
- `room fire/plume still reads as an oversized vertical slab`

## Campfire Baseline

The campfire scene should read as a fuel-bed fire. Flame tongues should originate from the log/char region, not from a centered floating tube.

Target traits:

- flame starts at the log/fuel bed
- warm/orange tongues are irregular and separated
- ember bed remains visible below the flame body
- smoke is darker and sootier than gas burner smoke
- flame body is taller and more turbulent than a burner flame

Audit warnings to watch:

- `campfire flame body is too short or underdeveloped`
- `campfire smoke is too weak or not dark enough`

## Gas Burner Baseline

The burner scene should read as an oxygen-rich stovetop burner source, not a campfire plume.

Target traits:

- active source is one selected burner, not all burners
- flame is lower and tighter than campfire
- blue/white structure is visible around burner ports
- soot and embers are minimal
- plume does not rise into a broad brown curtain

Audit warnings to watch:

- `burner flame is too tall for a stove source`
- `burner has high active pixels in upper plume region`
- `burner still reads too orange/warm instead of blue port jets`

## Review Rule

Any PR that changes scene source behavior, color, smoke, lighting, volume rendering, or frame pacing must include the visual audit JSON summary and either the contact sheet or equivalent live D3D captures in the PR body.
