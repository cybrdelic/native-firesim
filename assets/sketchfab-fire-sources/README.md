# Sketchfab Fire Source Assets

This folder tracks the source-of-truth registry for third-party fire-scene meshes.
It does not commit downloaded model bundles.

Current approved sources:

- `campfire`: Quaternius Bonfire from the Poly Pizza Survival Pack, Public Domain (CC0), solid fuel-bed source.
- `gas-burner-aver1`: Quaternius Oven from the Poly Pizza Ultimate House Interior Pack, Public Domain (CC0), controlled stove/burner source.

Import command:

```powershell
.\scripts\import-sketchfab-fire-scenes.ps1 -AssetId all -AcceptLicenseTerms
```

The importer needs manually downloaded/direct-downloaded source files placed in `assets\sketchfab-fire-sources\_downloads`.

Expected manual filenames:

- `cc0\bonfire.glb`
- `cc0\oven.glb`

The full source bundles can be re-downloaded from Poly Pizza:

- `https://poly.pizza/api/list/XzvQPP0yWB/download/glb`
- `https://poly.pizza/api/list/2SXnFbwFzm/download/glb`

Generated outputs go under `assets\fire-scenes\<asset-id>`:

- `scene.glb`
- `asset-manifest.json`
- `geometry.json`
- `emitter-mask.json`
- `sdf-grid.npz`
