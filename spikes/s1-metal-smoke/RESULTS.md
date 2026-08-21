# S1 results — 2026-08-21, macOS 26.3.1 (Tahoe), x86-64 Mac Pro

Raw log: `RESULTS-MacPro7-1-20260821.txt`.

**Offline-metallib leg (rerun after Xcode 15.2 install): PASS.** A metallib
built offline with Xcode 15.2's `metal` (Apple metal 32023.101) loads via
`newLibraryWithURL` and builds pipelines on **both** GPUs. `air-objdump`
readout — the AIR trio's reference target (S4): container `MetalLib`, arch
`air64`, embedded triple **`air64-apple-macosx14.2.0`**, `air.*` metadata
schema (`air.buffer`, `air.thread_position_in_grid`, `air.arg_type_name`,
`air.max_device_buffers`, `air.compile.*`).

## Verdicts

| Question (design §) | Answer |
|---|---|
| SIMD width (§5.3 `warp_size=64`) | **64 — confirmed** on both GPUs, by API (`threadExecutionWidth`) *and* empirically (`threads_per_simdgroup`, `simd_sum`, 64-bit ballot popcount, `simd_shuffle_xor` all agree) |
| Unified memory (§5.4) | **No** — discrete semantics confirmed; managed storage works |
| `simdgroup_matrix` (§5.5) | **No** — compiles at MSL level, fails at *pipeline* creation ("SC compilation failure"); we must gate at compile time so users never see this |
| `double` (§5.5) | **No** — rejected at source compile, as expected |
| **bfloat (§5.5) — SURPRISE** | **Compiles + builds pipelines at MSL 3.1 on both GCN cards.** Execution/precision unverified; presumably conversion-based. Verify numerics before enabling bf16 kernel paths |
| MSL / target features (§5.3) | Runtime accepts **MSL 3.2** → `+metal3_2` validated. Vega II reports **Metal3 family** (580X: Mac2 only) |
| Correctness | vadd 1M elements: 0 wrong, both GPUs |
| VRAM bandwidth | **830 GB/s** (copy kernel, r+w) on Vega II ≈ 81% of HBM2 peak — the ≥80% target is real. 580X: 169 GB/s |
| HtoD (PCIe) | **12.0 GB/s** blit shared→private (`maxTransferRate` reports 15.75 GB/s theoretical) |
| **`maxBufferLength` — SURPRISE** | **3.5 GiB single-buffer cap** despite 32 GiB working set. MetalRT must chunk or reject larger allocations (§5.4) |
| Peer group | None (`peerCount=0`) — single Vega II, no Duo/Infinity Fabric here; peer hooks stay stubbed |
| Limits | 64 KiB threadgroup memory, 1024 threads/TG, working set 32.0 GiB — all as designed |

## macOS pin

S1 ran clean on **26.3.1 (Tahoe)** — provisional pin macOS 26, confirm at S4
(AIR loadability).

## Bonus

The Radeon Pro 580X (Polaris, Mac2-tier, wave64) passes everything except the
Metal3 family check — a useful second GCN device for generality testing, and a
potential second target later.
