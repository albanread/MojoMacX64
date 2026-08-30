# FreeTokenLayers — why expert paging does not work on this machine

A **negative result**, recorded so nobody repeats it. We built MoE expert paging
([FreeToken](https://arxiv.org/abs/2608.16157)) into our llama.cpp fork, measured
it, and removed it. The technique is sound; this hardware is the wrong shape for
it, and the reason is structural rather than an implementation failure.

Written 2026-08-24. The code was reverted the same day; the measurements below are
what it was worth.

---

## 1. The conclusion, first

**On a Mac Pro (2019) with a Radeon Pro Vega II, put whole layers on whichever
processor already holds the data. That is what `-ncmoe` already does.**

| configuration | gpt-oss-120b (58.5 GiB, 117B params) |
|---|---:|
| `-ncmoe 18` — static layer assignment | **20.6 t/s** |
| our expert paging, 25% pool | 0.7 t/s |

And the wider point, which matters more than either number:

| model | fits in 32 GiB? | speed | CPU impact |
|---|---|---:|---|
| **gpt-oss-20b** MXFP4 | yes | **62 t/s** | none |
| Gemma-4-26B QAT | yes | 49 t/s | none |
| Qwen3-30B-A3B Q6_K | yes | 47 t/s | none |
| gpt-oss-120b Q4_K_M | **no** | 20.6 t/s | saturates the memory bus |

**Anything that fits on the card beats anything that does not, by 2-3x, while
leaving the machine usable.** The offload path exists to make the impossible
merely slow, not to make it fast.

---

## 2. The four constants that decide it

**`MEASURED`** on a quiet machine (a stuck `PerfPowerServices` daemon had been
eating two cores for five hours; every number taken before rebooting was ~10%
pessimistic and had to be retaken).

| constant | value | how |
|---|---:|---|
| host expert-processing bandwidth | **~109 GB/s** | slope of `-ncmoe` sweeps, 3 models |
| fixed cost per layer crossing | **~0.96 ms** | intercept of the same fit |
| Metal dispatch overhead | **90 µs** | repeating a no-op dispatch and measuring the slope |
| GPU compute-kernel reads of host memory | **~0.4 GB/s** | implied by admission traffic |
| PCIe host→device DMA | **never measured** | still assumed ~12 GB/s |

The fit was `t_layer = 0.957 ms + 9.19 ms/GB × bytes`, R² = 0.83 over gpt-oss-120b
(MXFP4), Qwen3-30B-A3B (Q4_K_M) and the same at Q6_K. With three points the
intercept and slope are poorly separated — the bandwidth figure is solid, the
0.96 ms less so.

### Why those numbers kill the technique

**The crossing cost is per layer, and it amortises.** All of a layer's routed
experts cross together, so `-ncmoe` pays 0.96 ms once for four experts. Paging
pays PCIe *per expert* with nothing to amortise against:

| gpt-oss-120b, one layer | CPU | PCIe fetch |
|---|---:|---:|
| 1 missed expert | 1.08 ms | 1.12 ms |
| 4 missed experts (a whole layer) | **1.45 ms** | 4.47 ms |

**Host RAM is 9x faster than the bus.** 109 GB/s against maybe 12 GB/s through a
switched Gen3 link. Moving weights to the GPU to compute them is slower than
computing them where they already are.

**Finer granularity does not help.** Per-*expert* placement sounds attractive
given the routing skew we measured (top 25% of experts carry 70% of routing), but
with 4 experts routed per layer the chance all four are hot is 0.7⁴ ≈ 24%. Three
layers in four cross anyway, and you have gained almost nothing over moving the
whole layer. Splitting by *tensor* (gate/up/down) is worse still — all three are
needed per access, so it spreads CPU work over more layers and pays more
crossings for the same VRAM.

---

## 3. What was built, and what it measured

The implementation worked and was correct. It is gone now, but for the record:
two Metal kernels (`moe_resolve` deciding residency on device, `moe_admit`
copying slices into a VRAM slot pool), a device-side residency table, and
substitution at the `mul_mv_id` dispatch. No matmul kernel had to change —
`mul_mv_id` reaches an expert through the id buffer and `nb02`, so pointing
`src0` at a pool and remapping ids to slots is the whole indirection.

Greedy decoding was **bit-identical** with paging on and off. It reached 2.0x on
mmap'd Qwen3-30B (3.55 → 7.0 t/s) and **0.68 t/s** on gpt-oss-120b, against 20.6
for the one-line static flag.

The killer was the last constant in the table. A **compute kernel** reading host
memory on a discrete AMD GPU runs at ~0.4 GB/s — Metal's `StorageModeShared` gives
uncached loads, not DMA. The design note for the first kernel said:

> *Deliberately a compute kernel rather than a blit. Blits need their own encoder,
> and switching encoders mid-graph costs more than the copy itself.*

That was wrong by two orders of magnitude. An encoder switch is ~0.1 ms; the
compute-kernel copy cost tens of ms because it never touched the DMA engine.
A blit-based redesign would fix that particular defect — and still lose, for the
per-layer amortisation reason above.

---

## 4. Lessons, for the next stunt on old hardware

**Measure the baseline before building the alternative.** The whole exercise was
answerable by two measurements — `-ncmoe` on the target model, and host bandwidth.
Instead the baseline was taken last, after three kernels and a simulator. Nothing
else in this note matters as much as that sentence.

**Simulate only what you have constants for.** The simulator confidently ranked
LRU over static placement, then reversed when the crossing cost was added, then
was invalidated again when the crossing cost turned out to be measured on a
contaminated machine. Each reversal was one missing term.

**Distrust clean results.** Four measurement errors in this work, every one
producing a result that was *too* clean: a perfectly uniform router (a strided
view read contiguously), a suspiciously flat distribution (pooling by expert index
across layers), a 97% hit rate (replaying a trace in the wrong order), and a
controller billing itself at its own estimated bandwidths.

**Check the machine is quiet.** Five hours of measurements were taken with a stuck
system daemon consuming two cores. The tell was there — a 27-64% spread where
clean runs give under 1%.

**This platform substitutes silently.** `ggml_metal_buffer_init(shared=true)`
returns a *private* buffer when the device lacks shared-buffer support, and its
`all_data` is a synthetic address that faults on first write. Nothing warns you.
Same family as the wrong-target `mcpu` that disassembles to garbage, the stale
embedded shader library, and `-march=native` flags that read as OFF in the cache.
On this stack, assume substitution rather than error.

**Capacity is not bandwidth.** 192 GiB of RAM sounds like it should let a big
model run. It lets it *exist*. Generation speed is bandwidth over bytes-per-token,
and on this machine every path to that RAM is narrower than the card's own memory.

---

## 5. What survives

- **`llama-moe-histogram`** — counts which `(layer, expert)` slots a model actually
  routes to. Useful for any MoE, independent of this dead end.
- **`llama-moe-policy`** — replays a routing trace under different placement
  policies. Its conclusions were wrong until the crossing cost was added; treat its
  output as arithmetic, not prophecy.
- **[MoE_TestMatrix.md](MoE_TestMatrix.md)** — the variables and controls.
- The measured constants in §2, which are properties of the machine and will
  outlast this particular idea.

## 6. Attribution

The technique is FreeToken's — [arXiv:2608.16157](https://arxiv.org/abs/2608.16157),
code at [FlashML-org/FreeToken](https://github.com/FlashML-org/FreeToken) (NVIDIA
only). It works on the hardware they targeted, where `B_P/B_H` is 0.25–0.68. Ours
is nearer 0.11, and that ratio is the whole story.
