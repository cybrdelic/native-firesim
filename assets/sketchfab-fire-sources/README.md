# Sketchfab Fire Source Assets

This folder tracks the source-of-truth registry for third-party fire-scene meshes.
It does not commit downloaded Sketchfab archives.

Current approved sources:

- `campfire`: Tactical_Beard, CC Attribution, low-poly solid fuel-bed source.
- `gas-burner-aver1`: Aver1, CC Attribution, controlled gas-burner source.

Import command:

```powershell
.\scripts\import-sketchfab-fire-scenes.ps1 -AssetId all -AcceptLicenseTerms
```

The importer needs either:

- `SKETCHFAB_API_TOKEN` in the environment, or
- manually downloaded archives placed in `assets\sketchfab-fire-sources\_downloads`.

Expected manual filenames:

- `campfire.zip`
- `gas-burner-aver1.zip`

Generated outputs go under `assets\fire-scenes\<asset-id>`:

- `scene.glb`
- `asset-manifest.json`
- `geometry.json`
- `emitter-mask.json`
- `sdf-grid.npz`

