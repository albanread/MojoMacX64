# bench — the cross-port matmul benchmark

`matmul_sram_bench.mojo` is **vendored, byte-identical**, from the shared
oracles repository at commit `09fbdbe`. It is not maintained here.

    git@github.com:albanread/oracles.git  —  bench/matmul_sram_bench.mojo

Keeping it byte-identical is the whole point: the five ports run the same
source on different hardware and the results are only comparable while nobody
has quietly tuned their copy. `diff` against upstream before trusting a
number, and send changes there rather than making them here.

Our recorded results live upstream too, as `bench/RESULTS-vega2.md`.

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
