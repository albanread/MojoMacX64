# bench — the cross-port matmul benchmark

Both benchmarks here are **vendored, byte-identical**, from the shared oracles
repository (`matmul_sram_bench.mojo` at `09fbdbe`, `matmul_reg_bench.mojo` at
`233dea6`). Neither is maintained here.

- `matmul_sram_bench.mojo` — naive 32×32 tiling, two threadgroup reads per FMA.
  Bound by threadgroup bandwidth; it ranks memory subsystems, not compilers.
- `matmul_reg_bench.mojo` — 64×64 tile, 4×4 outputs per thread. 1.95× the naive
  kernel at 2048³ here, and leaves ALU, threadgroup and DRAM all near a quarter,
  so it is the one that is actually sensitive to codegen. **Compete on this one.**

    git@github.com:albanread/oracles.git  —  bench/matmul_sram_bench.mojo

Keeping it byte-identical is the whole point: the five ports run the same
source on different hardware and the results are only comparable while nobody
has quietly tuned their copy. `diff` against upstream before trusting a
number, and send changes there rather than making them here.

Our recorded results live upstream too, as `bench/RESULTS-vega2.md` and
`bench/RESULTS-vega2-reg.md`.

Note the register-blocked kernel is a **regression at 512³** (0.97×): its 64×64
tile launches a quarter as many threadgroups, which on 64 CUs is exactly one
each, leaving no occupancy to hide latency. Run all five shapes.

## Running it

```
vega-sdk/bin/mojo build --target-accelerator=metal-vega2 -o /tmp/sram_bench \
    spikes/bench/matmul_sram_bench.mojo
/tmp/sram_bench
```

Every shape must print `EXACT`. The ragged shapes are the ones that were
silently wrong before barriers were marked `convergent` at declaration creation
(`54391a96`), so a `WRONG` here is most likely that defect returning — see
`spikes/matmul/ragged_matmul.mojo` for the minimal correctness-only version.

Note the run-to-run spread measured on this machine: **0.6% at 2048³ but 7.7%
at 512³**. Repeat the small shapes before believing a change there.
