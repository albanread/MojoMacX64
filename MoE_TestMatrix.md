# MoE offload — test matrix

What to vary, what to measure, and what to hold still, for the work described in
[FreeTokenLayers.md](FreeTokenLayers.md): running MoE models larger than 32 GiB of
VRAM at a useful speed, on a Mac Pro (2019) whose CPU is only half ours.

Two opportunities are in play and they are **not** the same experiment:

- **Residency policy** — keep the right experts on the card, so work never crosses
  to the CPU at all.
- **The CPU path itself** — when work does cross, make it cheaper.

The second matters less than it looks. The decomposition below says most of the
cost of a crossing is *fixed*, not bytes-proportional, so making dequantisation
faster attacks the smaller half.

---

## 0. Calibration — measure once, on a quiet machine

These are inputs to every projection. The paper is explicit that they cannot be
read off a spec sheet, and we have now been wrong about one of them by 3x.

| constant | how | status |
|---|---|---|
| `B_P` — PCIe host→device | Metal blit benchmark, or staged upload timing | **not measured** — assumed 12 GB/s |
| `B_H` — CPU expert bandwidth | slope of t/s against `-ncmoe N` | **measured**, see §1 |
| `a` — fixed cost per CPU layer | intercept of the same fit | **measured** ~0.70 ms, 2 points only |
| `B_VRAM` — on-card expert bandwidth | mat-vec kernel timing | **disputed** — 830 GB/s copy figure vs 428.9 STREAM triad |
| VRAM reserved | non-expert weights + KV(ctx) + compute buffer | derived; KV is 72 KiB/tok for gpt-oss-120b |

**`B_VRAM` is the one to settle first.** Every "% of ceiling" claim in the
llama.cpp README divides by 830 GB/s, and the Mojo port's vendored STREAM measures
428.9 GB/s triad on the same card. Both cannot be right.

---

## 1. What we already know

`t_layer = a + b·bytes`, fitted on two points:

| model | format | bytes/layer/token | ms/layer |
|---|---|---:|---:|
| gpt-oss-120b | MXFP4 | 0.054 | 1.78 |
| Qwen3-30B-A3B | Q4_K_M | 0.023 | 1.16 |

giving **`b` ≈ 20 ms/GB (~50 GB/s marginal)** and **`a` ≈ 0.70 ms fixed per
crossing**. Two points define a line exactly, so this has no residual and the two
models differ in more than bytes — layer count, `n_embd`, experts used. A third
point is the first thing the matrix must supply.

If `a` holds, at `-ncmoe 18` gpt-oss-120b spends **12.6 of 51.9 ms per token**
crossing the boundary rather than computing. That is the prize.

---

## 2. Independent variables

### A. Residency policy — the main axis
| variable | levels | notes |
|---|---|---|
| policy | `cpu_only`, `fixed`, `lru`, `hybrid` | `cpu_only` ≈ today's `-ncmoe`, the baseline to beat |
| capacity | 25%, 37.5%, 50%, **derived from VRAM** | derived is the only honest one; the rest map the curve |
| admission | fetch-only (theirs), fetch+CPU (ours) | worth 12.7 pts of hit rate in simulation |
| `pin_fraction` (hybrid) | 0.25, 0.5, 0.75 | 0.5 lost to pure LRU; smaller pins may not |

### B. Miss handling
| variable | levels | notes |
|---|---|---|
| balance | `all_cpu`, `all_pcie`, `residual`, `adaptive` | algebraically neutral at exact `B_P`/`B_H`; only interesting when the estimates are wrong |
| `cpu_budget` | **0.5**, 1.0 | 0.5 is the real constraint; 1.0 only as reference |

### C. The CPU path
| variable | levels | why |
|---|---|---|
| quant format | MXFP4, Q4_K_M, Q6_K, Q8_0 | third and fourth points for the `a + b·bytes` fit |
| threads | 4, 6, 8, 12 | does the CPU path scale, and where does 50% budget actually land |
| SIMD | native (AVX-512), AVX2-only | **tests downclocking** — Cascade Lake drops clock hard under 512-bit load, so wide may be slower |
| `-ncmoe N` | 0 … n_layer | the slope itself; needs ≥3 points per model for a residual |

### D. Model and workload
| variable | levels | notes |
|---|---|---|
| model | **gpt-oss-120b** (target), Qwen3-30B-A3B (control, fits entirely) | control must appear in every run — see §4 |
| domain | code, prose, agentic mix, tool-call JSON | routing skew differs: entropy 0.77 code vs 0.86 agentic |
| phase | prefill (batch 512), decode (batch 1) | **they want opposite policies** — caching is useless at batch 512 |
| context | 4K, 32K, 128K | KV comes out of the same VRAM, so context *is* capacity |

---

## 3. Dependent variables

**Speed**
- prefill t/s, generation t/s
- exposed ms/token, split into `t_vram`, `t_pcie`, `t_cpu`
- GPU utilisation %, CPU utilisation % — both, since we are allowed all of one and half the other

**Policy quality**
- hit rate, evictions
- PCIe GB and CPU GB per token
- crossings per token (the thing `a` multiplies)

**Correctness — non-negotiable**
- perplexity of the split configuration against **pure CPU** on identical text,
  with chunk count stated. A split `MUL_MAT_ID` path can route to the wrong
  experts and still read fluently; this is the only check that catches it.
- generated code compiles and passes a test, as a coarse smoke test
- determinism across repeated runs — nondeterminism means a scheduling bug, and
  we have a known unfixable concurrent-dispatch race on this driver

---

## 4. Controls — the part we keep getting wrong

Three measurement errors in the routing work and one in the simulator, every one
producing a result that was *too clean*. So:

- **An untouched control in every run.** A colleague's GPU use once made an
  unmodified kernel appear to lose 64% of its bandwidth. Without a control that
  reads as a catastrophic regression in code nobody changed.
- **Check the machine is quiet.** Mojo compiles at 500% CPU corrupted a STREAM run
  in this very session; the tell was a 27–64% spread where clean runs give <1%.
- **Repeat small shapes.** 0.6% run-to-run at 2048³ but **7.7% at 512³**. Our
  `pp512` numbers live in the noisy regime.
- **State the chunk count** on any perplexity figure. Absolute values are only
  comparable at equal chunks.
- **Distrust clean results.** Perfectly equal counts, a suspiciously flat
  distribution, a 97% hit rate — each of those was a bug, not a finding.

---

## 5. Priority

1. **`B_VRAM`** — settle 830 vs 428.9. It invalidates published claims either way.
2. **Third and fourth points for `a + b·bytes`** — Q6_K and Q8_0 MoE, `-ncmoe`
   sweeps with ≥3 points each. If `a` ≈ 0.70 ms survives, crossings dominate and
   the LRU case is made without simulating anything.
3. **`B_P`** — never measured, and the balance question is meaningless without it.
4. **Threads and SIMD** — cheap, and the AVX-512 downclock question could invert
   an assumption the way `B_H` did.
5. **Policy sweep on the real target** — gpt-oss-120b traces, all four policies,
   derived capacity, at `cpu_budget` 0.5.
6. **Correctness** on whatever configuration wins, before believing any of it.

Steps 1–4 are measurements on hardware we have, needing no new code. Step 5 needs
the trace tooling that exists. Only step 6's winner needs anything built.
