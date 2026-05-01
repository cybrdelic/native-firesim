# Crash Analysis

## Observed Failures

Two Windows bugchecks were recorded during early live CUDA testing:

- `2026-04-30 22:06:38`: bugcheck `0x00000139`, dump `C:\Windows\Minidump\043026-30062-01.dmp`
- `2026-04-30 22:30:57`: bugcheck `0x000000d1`, dump `C:\Windows\Minidump\043026-17593-01.dmp`

The second crash happened while interacting with a gizmo in the live app. `0xD1` is `DRIVER_IRQL_NOT_LESS_OR_EQUAL`, so this was a kernel/driver failure, not a normal user-mode exception.

## Local Driver Snapshot

`nvidia-smi` reported:

- GPU: NVIDIA GeForce RTX 4060 Laptop GPU
- Driver: `576.57`
- CUDA: `12.9`
- Driver model: WDDM

Windows also logged repeated `WUDFRd failed to load` warnings for Intel audio / PCI devices around reboot. Those warnings happen during boot and are not enough by themselves to prove the root cause.

## Current Mitigation

Live CUDA is disabled by default. The normal desktop launcher starts the safe CPU preview. CUDA kernels only run when explicitly requested:

- `--allow-live-cuda`: interactive CUDA backend
- `--cuda-smoke-test`: offscreen CUDA proof frame
- `--diagnostics`: CUDA/runtime/device query, no simulation kernel

The verification script does not run live CUDA by default.

## Remaining Root-Cause Work

Install Windows debugging tools and analyze the minidumps with symbols:

```powershell
windbg -z C:\Windows\Minidump\043026-17593-01.dmp
!analyze -v
lm
```

Until the crashing module is identified, live CUDA interaction should remain opt-in.
