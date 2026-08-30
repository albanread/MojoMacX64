# FreeTokenLayers — running MoE models larger than VRAM on the Mac Pro

A design note: what [FreeToken](https://arxiv.org/abs/2608.16157) does, why this
particular machine is an unusually good fit for it, and what it would take to
build the useful parts of it into our llama.cpp fork.

Written 2026-08-24. Nothing here is implemented yet. Claims are marked
**`MEASURED`** where we have run the number ourselves, **`THEIRS`** where it comes
from the paper, and **`ESTIMATED`** where it is arithmetic on top of those — the
distinction matters, because the estimates stack and several are load-bearing.

---

## 1. The problem

This card has 32 GiB. That caps us at roughly 52B parameters at `Q4_K_M`, and the
cap is hard: weights, KV cache and compute buffer all come out of the same pool.
Nothing else on the machine is short of memory — there is **192 GiB of DDR4-2933
across all six channels**, six times the VRAM, sitting idle while the GPU refuses
to load a model.

MoE is the structure that makes this worth attacking. A dense model reads every
weight every token, so streaming it from RAM is hopeless. An MoE reads only its
*active* experts — gpt-oss-120b touches about 5.1B of 120B per token — so the
question stops being "can we move 63 GB per token" (no) and becomes "can we move
the few hundred megabytes that actually fire" (maybe).

## 2. What FreeToken does

**`THEIRS`** — from the paper. FreeToken is NVIDIA/Linux/Windows only and leans
hard on CUDA Graphs, FlashInfer and device-side kernels; the paper says it
"cannot operate on alternative accelerators without significant redesign." We
cannot run it. What follows is the *idea*, which is portable.

### 2.1 Host RAM is the source of truth

All expert weights live in host RAM, in an `FTW` format that pre-merges them into
the runtime bank layout indexed by a flattened `l·E + e` identifier. Weights are
read from disk *directly into their final host layout* and the memory is pinned
only afterwards — avoiding the cost of zeroing a large pinned buffer first. The
GPU holds a **cache**, not the model.

### 2.2 The slot pool

GPU memory is divided into fixed-size **slots**, each holding every tensor needed
to evaluate one `(layer, expert)` pair. Prefill and decode share one pool, so the
experts prefill touches seed decode's working set.

### 2.3 Prefill: double-buffer whole layers

Prefill touches nearly every expert, so caching is pointless there. Instead they
run **full-layer double buffering** — while the GPU computes the routed experts of
layer *l* from one buffer, a transfer stream loads the complete expert set of
layer *l+1* into the other. Transfer hides behind compute. This needs the slot
pool to spare two entire layers; when it cannot, they fall back to on-demand
prefill loading.

### 2.4 Decode: semantic-aware LRU

Decode is cacheable, because consecutive tokens route to overlapping experts. The
residency space is a plain LRU over `(layer, expert)` pairs, and "semantic-aware"
means only that it **follows the router's actual decisions** rather than a
workload-agnostic placement chosen at load time. Reported decode miss rates:

| model | cache capacity | miss rate |
|---|---:|---:|
| Qwen3.6 | 37% | **16%** |
| DeepSeek-V4-Flash | 11% | **39%** |

### 2.5 The bandwidth-adaptive split — the core idea

On a miss you have two ways to get the expert's work done, and they use
*different* resources. You can ship the weights over PCIe and compute on the GPU,
or you can compute on the CPU straight out of host RAM. So do both at once, and
split the misses in proportion to the two bandwidths:

> **q⋆ ≈ m · B_P / B_H**

where `m` is the number of missing experts, `q⋆` the number fetched over PCIe,
`B_P` the pinned transfer bandwidth and `B_H` the host-side expert-processing
bandwidth. Cache fills run at full PCIe rate; the CPU consumes the host bandwidth
the saturated link leaves over. Both branches run concurrently and **the exposed
latency is the slower one**.

Crucially the CPU path is not an approximation — it produces per-token,
gate-weighted partial sums that are merged exactly with the GPU's results. The
CPU side is a persistent pinned thread pool on physical cores, using
architecture-specific SIMD with in-kernel dequantisation to stay bandwidth-bound.

### 2.6 Their measured bandwidths

**`THEIRS`** — and note the paper insists these must be measured per machine,
because the optimal split "cannot be read from specification sheets."

| system | B_P (GB/s) | B_H (GB/s) | B_P/B_H |
|---|---:|---:|---:|
| RTX 5090 | 52.7 | 77.3 | 0.68 |
| RTX 4090 | 25.1 | 63.2 | 0.40 |
| RTX 3090 | 25.3 | 56.7 | 0.45 |
| RTX 4060 laptop | 11.8 | 47.5 | 0.25 |

Reported throughput: Qwen3.6-35B at 77–83 t/s on a 5090 and **39.3 t/s on an 8 GB
laptop**; DeepSeek-V4-Flash (284B) at 22–25 t/s; GLM-5.2 (753B) at 14.9 t/s
against llama.cpp's 7.3.

---

## 3. Why this machine is an unusual fit

| | value | basis |
|---|---:|---|
| VRAM | 32 GiB | **`MEASURED`** — `recommendedMaxWorkingSetSize` 34343 MB |
| host RAM | 192 GiB | **`MEASURED`** — 6 × 32 GB DDR4-2933 R-DIMM, all channels |
| host RAM theoretical | 140.8 GB/s | 6 ch × 2933 MT/s × 8 B |
| PCIe | Gen3 ×16 | **`MEASURED`** — `system_profiler` reports ×16; Mac Pro 2019 is Gen3 |
| `B_P` | **~12 GB/s** | **`ESTIMATED`** — 15.75 GB/s theoretical, ~75% achieved |
| `B_H` | **~70–110 GB/s** | **`ESTIMATED`** — six-channel DDR4 plus AVX-512 dequant |
| `B_P/B_H` | **~0.15** | **`ESTIMATED`** |

The shape of this is peculiar and favourable. Our PCIe is the **worst** on the
board above — Gen3 ×16 ties us with their laptop. Our host bandwidth is plausibly
the **best**, because six-channel workstation memory beats dual-channel desktop
DDR5, and the W-3235 has AVX-512 for the dequantisation path.

That gives the lowest `B_P/B_H` ratio of any system in the paper, which means
**the CPU should carry ~85% of misses** — the opposite of the instinct that the
GPU is the fast part. It is also the regime where the technique matters most: the
whole point of the adaptive split is to stop a slow interconnect being the
bottleneck, and here the interconnect barely participates.

For calibration, their 8 GB laptop has our PCIe and worse host memory and still
reaches 39.3 t/s on a 35B MoE. We have four times its VRAM.

---

## 4. What llama.cpp has today, and the exact gap

`-ncmoe N` / `--n-cpu-moe N` is sugar over `--override-tensor`:

```cpp
// common/arg.cpp:2748
buft_overrides.push_back(llm_ffn_exps_block_regex(i));
params.tensor_buft_overrides.push_back({..., ggml_backend_cpu_buffer_type()});
```

That is **static, layer-granular, decided at load time, and completely
routing-unaware**. It pushes the first *N* layers' experts to CPU and leaves them
there forever. Every gap to FreeToken is in that sentence:

| | llama.cpp `-ncmoe` | FreeToken |
|---|---|---|
| granularity | whole layer | `(layer, expert)` |
| decided | at load | every token |
| routing-aware | no | yes, LRU follows the router |
| miss handling | n/a — placement is fixed | split across PCIe and CPU by bandwidth |
| prefill | same as decode | double-buffered whole layers |

### 4.1 The obstacle

Expert selection is a tensor *inside the compute graph*:

```cpp
// src/llama-graph.cpp:2057
selected_experts = ggml_argsort_top_k(ctx0, selection_probs, n_expert_used);
```

It exists only in device memory during execution. A host-side residency manager
would need it back on the CPU every MoE layer, every token — a PCIe round trip
that also drains the pipeline. This is precisely why FreeToken keeps the decision
on-device: one GPU kernel deduplicates the routed experts, classifies them
against the residency table and derives the fetch count, all inside a captured
graph. Metal on this card gives us no equivalent.

### 4.3 Measured: routing is strongly skewed, and the skew is stable

**`MEASURED`** — `llama-moe-histogram` (in our fork, `examples/moe-histogram`) over
16,384 tokens of wikitext on Qwen3-30B-A3B, 48 layers x 128 experts = 6144 slots.

Mean per-layer normalised entropy **0.85** against 1.0 for a uniform router, and
**9.1% of slots were never routed to at all**. Capacity against coverage, where
"train-chosen" ranks slots by a profile taken on `wiki.train` and scores them on
`wiki.test` — the honest number, since ranking and scoring on the same text is
fitting to the test set:

| slots resident | train-chosen | same-corpus oracle | uniform |
|---:|---:|---:|---:|
| 10% | 38.6% | 41.6% | 10% |
| 25% | 64.9% | 70.1% | 25% |
| **37.5%** | **80.8%** | 85.3% | 37.5% |
| 50% | 90.8% | 94.6% | 50% |
| 75% | 99.1% | 99.8% | 75% |

Three conclusions.

**Routers are not load-balanced at inference.** They are balanced during
*training*; on real text a tenth of the slots are dead and 37.5% of them carry
four-fifths of the work.

**The distribution belongs to the model, not the corpus.** Profiles from
`wiki.train` and `wiki.test` agree closely — entropy 0.840 vs 0.852, dead slots
567 vs 562 — and cross-validation costs only 4.5 points at the capacity we care
about. An offline profile therefore transfers.

**Static placement captures most of what a dynamic cache would.** Our honest
static figure is 80.8% at 37.5% capacity; FreeToken's *online LRU* reports ~84%
hit at 37% on Qwen3.6. Static gets roughly 96% of dynamic, which makes Phase 1
the high-value phase and Phase 3 possibly unnecessary — and Phase 3 is precisely
the part that needs residency management we cannot easily build on Metal.

**Caveat:** both corpora here are wikitext. Stability across *domains* (code,
chat, tool-calling) is untested and is the obvious next measurement, because a
static placement that only holds within one domain is much less useful.

### 4.2 The opening

We do not have to pay that cost, because of an accident of llama.cpp's design:
**when any experts are CPU-resident, `ggml_backend_sched` must already copy the
routing ids to the host** so the CPU backend can run `MUL_MAT_ID`. The
information a residency manager needs is therefore available host-side, for free,
in exactly the configuration where we want it.

That converts the central objection from "impossible without device-side
dispatch" into "available, if we hook the right place."

---

## 4.4 Measured: which policy, on an agentic trace

**`MEASURED`** — `llama-moe-policy` replaying a 577,560-event routing trace from a
synthetic agentic session (prose requests, code slabs, tool-call JSON, diffs) with
the placement profile taken from a *different* corpus (pure code). Decode-order
replay; Qwen3-30B-A3B; this machine's bandwidths.

At 37.5% of slots resident:

| policy | hit rate | exposed ms/1k events |
|---|---:|---:|
| `cpu_only` (≈ `-ncmoe` everywhere) | 0.0% | 248.6 |
| `fixed` (offline profile) | 73.8% | 114.2 |
| **`lru`** | **93.3%** | **66.6** |
| `hybrid` (pinned core + LRU) | 90.3% | 75.2 |

**LRU wins, and hybrid loses to it.** Pinning half the capacity to a profile fitted
on another corpus both spends slots on the wrong distribution and starves the
adaptive half. Dynamic residency is worth roughly 20 points of hit rate over static
here — far more than the ~3 points the frequency analysis in §4.3 suggested,
because temporal locality is a much stronger effect than frequency skew and a
static profile cannot exploit it.

### Two departures from the paper

**Admit CPU-computed experts, not only fetched ones.** FreeToken admits set ℱ, the
experts it transfers. That is reasonable at their `B_P/B_H` of 0.25–0.68; at our
0.13 it admits 13% of misses and the cache never fills. Promoting what the CPU
computed — it already holds the weights, and the copy is off the critical path —
is worth:

| admission | hit rate | PCIe GB | exposed ms/1k |
|---|---:|---:|---:|
| fetch only (theirs) | 80.6% | 91.5 | 98.7 |
| **fetch + CPU (ours)** | **93.3%** | **25.9** | **66.6** |

**The bandwidth split is neutral, and its real job is admission.** Substituting the
optimal `q = m·B_P/B_H` back into either branch:

```
t_pcie = (m·B_P/B_H)·gb/B_P         = m·gb/B_H
t_cpu  = m(1 − B_P/B_H)·gb/(B_H−B_P) = m·gb/B_H
```

Both equal `m·gb/B_H` — precisely the cost of running every miss on the CPU. Under
its own residual model **the split cannot beat CPU-only on throughput.** What it
actually buys is cache population, and once CPU-computed experts are admitted too,
that benefit is available without the transfers. Measured: `all_cpu` 65.4 ms/1k
against `residual` 66.6, and the adaptive balancer converges to ~0 PCIe traffic on
its own.

**Consequence for this machine:** run essentially every miss on the CPU, promote
asynchronously, and treat PCIe as a cache-fill path of last resort. Our weak
interconnect stops being the problem it looked like in §3.

### Health warning

Three measurement errors were made and caught while producing §4.3 and §4.4: a
contiguous read of a strided view (fake uniform routing), pooling counts by expert
index across layers (halved apparent skew), and layer-major trace replay (LRU at a
fictional 97.4%). Every one produced a result that was *too clean*. The numbers
above are the ones that survived; treat them as provisional until an implementation
reproduces them.

---

The variables to sweep, and the controls that keep the answers honest, are in
**[MoE_TestMatrix.md](MoE_TestMatrix.md)**.

## 4.5 Measured: long context is nearly free here

**`MEASURED`** — gpt-oss reports `n_swa = 128` with `is_swa_any = 1`, and the layer
assignments come out **half sliding-window, half full attention** (12 and 12 on the
24-layer 20B; 18 and 18 expected on the 36-layer 120B).

Sliding-window layers hold a 128-token window *whatever the context length*, so
only half the layers scale with it. For gpt-oss-120b that is 36 KiB/token rather
than the 72 the naive figure implies:

| context | KV cache | expert capacity left in 32 GiB |
|---:|---:|---:|
| 4K | 0.14 GiB | ~48% |
| 32K | 1.13 GiB | ~48% |
| 128K | 4.50 GiB | ~42% |

Against the §4.4 curve, 42% capacity still gives roughly 95% hit rate. **Context
and expert residency are not really competing**, which matters because code
assistance needs long context and the naive arithmetic made that look expensive.

## 5. Staged plan

Ordered so that each phase is useful alone and the cheap ones come first.

### Phase 0 — measure the two numbers (hours)

Neither can be read off a spec sheet. Both are load-bearing for everything below.

1. **`B_H` from an `-ncmoe` sweep.** Run generation on Qwen3-30B-A3B (which fits
   entirely, so the GPU baseline is known) at `-ncmoe 0,4,8,…,48` and fit the
   slope of t/s against layers-on-CPU. That gives real host expert-processing
   bandwidth on this machine, with this quantisation, through llama.cpp's actual
   CPU kernels — not a synthetic STREAM figure.
2. **`B_P` by host→device transfer.** A Metal blit benchmark, or inferred from
   staged upload timings in `ggml_metal_buffer_set_tensor`.
3. ~~**The expert-usage histogram.**~~ **DONE — see §4.3.**

### Phase 1 — static hot/cold placement (small) — **superseded by §4.4**

Measurement says static placement reaches 73.8% where LRU reaches 93.3%. Worth
building only as a fallback for models we cannot profile, or as a first step whose
machinery Phase 3 reuses.

If routing is skewed: pin frequently-routed experts to VRAM and push the cold
tail to CPU, using `-ot` regexes generated from the Phase 0 histogram. This is
literally "CPU cores for the least likely experts". **No new kernels** — it uses
machinery that already exists and ships today.

### Phase 2 — size the split by measured bandwidth (small)

Apply `q⋆ ≈ m·B_P/B_H` to choose *how much* goes where, rather than guessing. On
this machine the answer looks like ~85% CPU, which no one would pick by
intuition. Still static, but correctly sized for this hardware.

### Phase 3 — dynamic residency (the real thing)

LRU promotion and demotion between host RAM and VRAM, driven by the routing ids
we get for free from §4.2. Misses are computed on the CPU synchronously — it has
to compute them anyway — while promotion to VRAM happens asynchronously, off the
critical path. This is the genuine research piece and should not be started until
Phase 0 says it is worth it.

### Phase 4 — prefill double buffering (separate problem)

**Prefill and decode want opposite policies and any design that conflates them
will lose one.** At batch 512 nearly every expert is touched, so the cache is
useless and what you want is FreeToken's layer-ahead double buffer. At batch 1
only `n_expert_used` experts fire per layer, which is highly cacheable. Note our
prefill is already 3.5× behind ToshLLM's, so this is not the place to start.

---

## 6. Projection, and what would falsify it

**`ESTIMATED`** — estimates stacked on estimates. Stated so each can be shot down.

For gpt-oss-120b `Q4_K_M` (62.8 GB, ~5.1B active, downloading now):

| step | value | assumption |
|---|---:|---|
| active bytes/token | ~2.7 GB | 5.1B params at ~4.25 bpw |
| VRAM cache capacity | ~50% | 32 GiB against ~63 GB of experts |
| miss rate | **~5%** | **`MEASURED`** §4.4 curve at the ~45% capacity §4.5 derives |
| missed bytes/token | ~0.35 GB | |
| PCIe branch (15%) | ~4.4 ms | 0.053 GB at 12 GB/s |
| CPU branch (85%) | ~3.3 ms | 0.30 GB at 90 GB/s |
| **exposed** | **~4.4 ms** | branches concurrent, slower one shows |
| fully-resident baseline | ~23 ms/token | scaled from gpt-oss-20b's measured 62 t/s |
| **projected** | **~36 t/s** | |

Each of these kills it:

- ~~Routing is uniform, not skewed.~~ **Ruled out** — §4.3.
- **`B_H` comes in near 40 GB/s rather than 90.** The CPU branch doubles and
  becomes the exposed cost. Phase 0 settles this and it is the single most
  important measurement.
- **Metal cannot DMA-register host memory usefully.** Their fallback is a pure-CPU
  MoE backend, which is what `-ncmoe` already gives us and is much slower.
- **Transfer will not overlap compute on this driver.** We have a documented,
  unfixable concurrent-dispatch ordering bug (`memoryBarrierWithScope` is not
  honoured between concurrent dispatches on AMD/macOS). Blit-versus-compute
  overlap is a *different* mechanism and probably fine — but it is an assumption,
  not a finding, and it must be proved before Phase 3.
- **The skew does not survive a change of domain.** Only wikitext has been
  tested. Code or chat routing could look entirely different, and a placement
  that holds for one domain only is much less useful.

---

## 7. Attribution

The algorithm is FreeToken's — Zaharia, Stoica, Han, Keutzer et al.,
[arXiv:2608.16157](https://arxiv.org/abs/2608.16157), code at
[FlashML-org/FreeToken](https://github.com/FlashML-org/FreeToken) (NVIDIA only).
Everything in §3–§6 is our own analysis of applying the idea to this hardware and
to llama.cpp, and none of their code has been read or used — their
implementation is CUDA and could not be transplanted regardless.
