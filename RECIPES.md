# Recipes

Eight configurations, one per situation. Each names the model it needs, the
command to run it, and how to tell it actually engaged — because a speculative
preset that doesn't match your model degrades **quietly** into ordinary decoding
rather than failing.

Every number here was measured on a single Radeon 8060S (Strix Halo APU). Other
hardware gets the correctness fixes and the upstreamable wins; the tuning was
not measured there.

| recipe | for | model | measured |
|---|---|---|---|
| [`plain`](#plain) | the baseline, and A/B comparisons | anything | 14.0 t/s |
| [`dflash-fp4`](#dflash-fp4) | agents, structured output — the headline | **Qwen3.8-27B** ROCmFP4-FAST + FP4 sidecar | **65.6 t/s, 4.7×** |
| [`dflash-q8`](#dflash-q8) | the same, on a stock K-quant target | **Qwen3.8-27B** (any quant) + Q8_0 sidecar | 48.5 t/s |
| [`mtp-long`](#mtp-long) | long context, any task, no sidecar | **Qwen3.8-27B** ROCmFP4-FAST, or any model with an MTP head | 36.1 t/s at 31k |
| [`ornith-mtp`](#ornith-mtp) | long documents, fastest prefill | **Ornith-1.5-35B-A3B** Q4_K_M | **1648 t/s pp2048** |
| [`gyro`](#gyro) | a 126B MoE on one 32 GB GPU | **Qwen3.8-Flash-Next Gyro-S** + its MTP draft | 32 → **58 t/s** JSON, 39 prose |
| [`marshall`](#marshall) | a coding agent's fast tier | **Qwen3.8-27B** ROCmFP4-FAST + FP4 sidecar | as `dflash-fp4` |
| [`router`](#router) | serving a whole directory of models | anything | — |

## The models

Three model families cover every recipe here. Both are downloaded on first run by
`-hf`, into your models directory — you do not have to fetch them by hand.

**Qwen3.8-27B** — dense, and the target for every generation recipe. It carries
an MTP head, so it works with `mtp-long` too.

| role | Hugging Face repo | notes |
|---|---|---|
| target, FP4 | `julianmb/Qwen-3.8-27B-ROCmFP4-FAST-GGUF:FAST` | 13.55 GiB. Needs this fork — mainline cannot load it |
| target, stock | any Qwen3.8-27B K-quant (the fork's benchmarks used unsloth's `UD-Q4_K_XL`) | for `dflash-q8`, if you would rather not use a ROCmFP4 conversion |
| DFlash2 sidecar, FP4 | `agentionai/Qwen3.8-27B-DFlash2-ROCmFP4-FAST-GGUF` | pairs with the FP4 target; the 65.6 t/s figure |
| DFlash2 sidecar, Q8_0 | `z-lab/Qwen3.8-27B-DFlash2-GGUF:Q8_0` | pairs with any Qwen3.8-27B target; better on prose |

**Ornith-1.5-35B-A3B** — delta-net MoE, and the prefill recipe. No sidecar: it
drafts against its own MTP head.

| role | Hugging Face repo |
|---|---|
| target | `ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M` |

**Qwen3.8-Flash-Next (Gyro)** — 126B MoE, and the single-GPU big-model recipe. Rotor-coded
experts that only this fork can run; it drafts against its own MTP head, shipped in the same repo.

| role | Hugging Face repo | notes |
|---|---|---|
| target | `agentionai/Qwen3.8-Flash-Next-Gyro-GGUF:Gyro-S` | 58.5 GB download, 28.8 GiB GPU at 64k; mainline cannot load it |
| MTP draft | same repo, `mtp-Qwen3.8-Flash-Next-draft.gguf` | 2.7 GB; fetched by `-hf` automatically |
| vision projector | same repo, `mmproj-F16.gguf` | 0.9 GB; fetched by `-hf` automatically, `--no-mmproj` for text-only |

A DFlash2 sidecar is **paired with a specific target**. The FP4 sidecar above is
trained against Qwen3.8-27B and is useless against anything else — it will draft
tokens the target rejects and you pay the full draft cost for nothing. There is
no error message for this; see [Did it actually engage?](#did-it-actually-engage).

Run one:

```bash
agention-llama run dflash-fp4
```

Everything after `--` goes straight to `llama-server`:

```bash
agention-llama run mtp-long -- -m /models/your-model.gguf --metrics
```

---

## Did it actually engage?

Read this once; it applies to every speculative recipe below.

The doctor answers the driver question at startup. It cannot answer this one: a
mismatched sidecar, or a model with no MTP head, produces correct output at
ordinary speed. The server tells you per request, at the default log level:

```
draft acceptance = 0.71429 (   45 accepted /    63 generated), mean len =  4.21
```

**The line is missing entirely.** No draft tokens were generated, so speculation
never engaged. Either the preset didn't reach the server —

```bash
docker exec agention-llama env | grep SPEC
```

— or the model can't support the method (`draft-mtp` against a model with no
nextn head).

**The line is there but the ratio is low.** Speculation is running and losing.
For a draft model that is a sidecar/target mismatch, or the ROCmFPx sidecar trap
described under [`dflash-q8`](#dflash-q8). For `draft-mtp` it usually means the
workload is prose rather than the structured, predictable output MTP drafts
well.

**`mean len` is the number that maps to wall-clock.** It is how many tokens each
verification step yields. At 1.0, speculation is costing you time — you would be
faster on `plain`.

For something you can graph rather than read:

```bash
agention-llama run dflash-fp4 -- --metrics
curl -s localhost:8080/metrics | grep spec_decode
```

`spec_decode_num_draft_tokens_total`, `spec_decode_num_accepted_tokens_total`
and `spec_decode_num_drafts_total`.

The only claim worth trusting on hardware other than the one in these tables is
the end-to-end one: run your own prompt against `plain` and against the recipe,
and compare tokens/s.

---

## `plain`

**For:** the baseline. Run this first, and run it again whenever a number below
looks wrong.

**Needs:** any GGUF.

```bash
agention-llama run plain -- -m /models/your-model.gguf
```

Its context and ubatch deliberately match `dflash-fp4`, so switching between the
two is a single-variable experiment. Change one, change the other.

**Measured:** 14.0 t/s structured, 14.1 prose on Qwen3.8-27B ROCmFP4-FAST. The
two are identical because with no draft in play, the content of the output
cannot matter. That symmetry is the tell — every recipe below breaks it.

Bare decode on this hardware is at **80% of theoretical memory bandwidth**. Two
decoders with nothing in common — an FP4 codebook with UE4M3 scales, and Q3_K
superblocks — reach the same 204 GB/s to three significant figures. No kernel
work moves this. Every remaining gain has to come from draft acceptance, which
multiplies effective bandwidth instead of competing for it.

---

## `dflash-fp4`

**For:** agents, tool calls, JSON, code — anything with predictable structure.
This is the fork's headline and its best case.

**Needs:** **Qwen3.8-27B**, specifically:

| | |
|---|---|
| target | `julianmb/Qwen-3.8-27B-ROCmFP4-FAST-GGUF:FAST` (13.55 GiB) |
| sidecar | `agentionai/Qwen3.8-27B-DFlash2-ROCmFP4-FAST-GGUF` |

```bash
agention-llama run dflash-fp4 -- -hf julianmb/Qwen-3.8-27B-ROCmFP4-FAST-GGUF:FAST
```

The sidecar is named in the preset and downloads on first run; only the target
goes on the command line. The FP4 target needs this fork — mainline cannot load
a ROCmFPx model at all.

**Measured**, greedy, 300 tokens, structured output:

| | t/s | |
|---|---:|---|
| bare decode | 14.0 | |
| fixed draft `n=3` | 41.6 | 95% acceptance — under-drafting |
| fixed draft `n=7` | 20.2 | **18% acceptance** — the same ceiling, unusable |
| **this recipe** | **65.6** | 96% acceptance while drafting longer — **4.7×** |

That `n=7` row is the argument for the whole feature. The ceiling that destroys
the fixed arm is safe under adaptive sizing, because the draft length follows
measured acceptance instead of always drafting to the cap.

**Two caveats, both real.** On prose this reads 26.1 t/s, not 65.6 — content
dominates configuration, and identical weights at identical context differ by
2.5× purely on whether the output is predictable. And 65.6 was taken on a short
high-power burst (79 °C, 115 W) this chassis cannot sustain; on the everyday
power profile the same configuration reads **55.0 t/s**.

**Serving another family?** Repoint `LLAMA_ARG_SPEC_DRAFT_HF_REPO` at that
model's own DFlash2 sidecar, or `LLAMA_ARG_SPEC_DRAFT_MODEL` at a local file. A
mismatched sidecar does not merely run slower — it drafts tokens the target
rejects, and you pay the full draft cost for nothing.

---

## `dflash-q8`

**For:** the same workload as `dflash-fp4`, when your target is a stock K-quant
rather than a ROCmFP4 conversion. Nothing here needs the fork's quant types.

**Needs:** **Qwen3.8-27B** in any quantisation:

| | |
|---|---|
| target | any Qwen3.8-27B K-quant (the fork's benchmarks used unsloth's `UD-Q4_K_XL`) |
| sidecar | `z-lab/Qwen3.8-27B-DFlash2-GGUF:Q8_0` |

```bash
agention-llama run dflash-q8 -- -m /models/Qwen3.8-27B-UD-Q4_K_XL.gguf
```

**Measured**, everyday power profile, greedy, 300 tokens:

| | structured | prose |
|---|---:|---:|
| fixed `n=3` | 36.6 | 24.7 |
| fixed `n=7` | 35.8 | 23.0 |
| **this recipe** | **48.5** | **25.0** |

It beats every fixed setting on **both** content types — +32% on structured over
the best fixed arm. It also gives up less on prose than the FP4 sidecar does, so
for mixed workloads rather than tool-call-shaped ones, prefer this.

> **Do not requantise this sidecar to ROCmFPx.** Our `Q8_0_ROCMFPX` scores 53.5%
> draft acceptance against z-lab's Q8_0 at 60.2%, at identical bpw and identical
> tensor routing — it lands below our own FP4, which is impossible as a
> precision effect. The cause is the block scale: Q8_0 stores an fp16 scale,
> ROCmFPx a UE4M3 byte. At 8 bits per weight the codes are not the problem, the
> coarse scale is.

---

## `mtp-long`

**For:** long context, any task, without downloading a second model.

**Needs:** a model with an **MTP / nextn head**, and no sidecar.
**Qwen3.8-27B** has one, so the same target as `dflash-fp4` works here:

```bash
agention-llama run mtp-long -- -hf julianmb/Qwen-3.8-27B-ROCmFP4-FAST-GGUF:FAST
```

Ornith-1.5-35B-A3B has one too — see [`ornith-mtp`](#ornith-mtp) for the
settings that model wants instead. A model *without* an MTP head cannot start in
this mode: the draft context is built from the target itself, so it fails loudly
rather than falling back.

**Measured** at ~31k tokens of real C source:

| | verbatim reproduction | prose about the code |
|---|---:|---:|
| bare | 12.20 | 12.19 |
| **this recipe** | **36.07** (97.5% acc) | 20.54 |
| `dflash-q8` at the same depth | 31.79 | 15.69 |

**The ranking inverts with context length.** DFlash2 wins short; by 31k, MTP
takes both tasks. The cause is structural, not tuning: a DFlash2 sidecar keeps
its own KV cache over the full context and re-runs up to `n-max` times per
verification step, so its cost scales with context. MTP's nextn layer reuses the
target's state and never pays that.

**Keep `n-max` tight** — this preset ships 4, and that is deliberate. The
adaptive controller maximises accepted tokens, not throughput, and for MTP those
diverge: later nextn layers are less accurate while draft cost stays linear in
`n`. With a DFlash2 sidecar the picture reverses and `n-max 7` is right.

---

## `ornith-mtp`

**For:** long documents, RAG, bulk summarisation — anything prefill-dominated.

**Needs:** **Ornith-1.5-35B-A3B** — `ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M`,
or another delta-net MoE. No sidecar; it drafts against its own MTP head.

```bash
agention-llama run ornith-mtp -- -hf ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M
```

**Measured** at ubatch 2048, against pinned upstream `95b8e33e1`:

| | mainline | this fork | |
|---|---:|---:|---:|
| pp512 | 1144.3 | 1289.7 | +12.7% |
| pp2048 | 870.5 | **1648.5** | **+89.4%** |
| tg64 | 76.6 | 76.8 | tie |

This is the single largest measured gain in the fork. Note the mainline column:
**mainline at ubatch 2048 is slower than mainline at ubatch 512.** The tiled
concat-transpose and `mul_mat_id` stack are what turn a wide ubatch from a
regression into the fastest setting available. Do not generalise it — the dense
27B prefers the default 512.

> **`-ub 2048` past 64k context can hang the GPU.** At a context depth of 65536
> or beyond this reproducibly times out the compute ring (`amdgpu: ring
> comp_1.2.0 timeout`, recovered by a ring reset). It reproduces on **stock
> upstream llama.cpp**, so it is not something this fork introduces — but it
> does cap this recipe at short-to-mid context. Serving longer? Use `mtp-long`,
> which runs ubatch 512.

**Generation here is parity with mainline, and honestly so.** MTP at a fixed
draft length landed upstream and works there; that figure belongs to the model
and to Strix Halo's bandwidth, not to this fork. What this fork adds on Ornith
is prefill. Run the MoE for prefill, the dense 27B for generation.

---

## `gyro`

**For:** a 126B mixture-of-experts on one 32 GB GPU — coding, agentic work and long reasoning.

**Needs:** **Qwen3.8-Flash-Next Gyro-S**:

| | |
|---|---|
| target | `agentionai/Qwen3.8-Flash-Next-Gyro-GGUF:Gyro-S` (58.5 GB) |
| draft | same repo, `mtp-Qwen3.8-Flash-Next-draft.gguf` (2.7 GB) |
| vision | same repo, `mmproj-F16.gguf` (0.9 GB) |

```bash
agention-llama run gyro -- -hf agentionai/Qwen3.8-Flash-Next-Gyro-GGUF:Gyro-S
```

`-hf` fetches the target, the MTP draft (by its `mtp-` name) and the vision projector in one go. Images work
out of the box; add `--no-mmproj` after `--` to run text-only and keep about 1 GiB of GPU memory. The 26.8 GB
n-gram table inside the target stays on disk (`--ngram-on-disk`).

**Measured**, Radeon 8060S, greedy, 384 tokens, reasoning off:

| | prose | JSON | code | copy |
|---|---:|---:|---:|---:|
| bare decode | 32.3 | 32.2 | 32.0 | 32.2 |
| MTP, Q8_0 draft, `n-max 4` | 38.2 | 51.3 | 49.0 | 55.8 |
| **this recipe** | **38.7** | **57.7** | **51.5** | **61.1** |

Two things make the difference over plain `mtp-long` settings: a 4-bit draft (same acceptance as Q8_0,
1.4 GB smaller) and `--spec-draft-mtp-vocab 32768`, which scores the draft over a 32k-token vocabulary subset
(draft step 4.3 → 1.6 ms; verification still uses the full vocabulary). A probability cutoff
(`--spec-draft-p-min 0.5`) made prose *slower* here: on this backend a verify of two tokens costs more than one
decode step, so short drafting rounds do not pay.

**Two GPUs:** keep the model on one card and the draft on the other (`-- --device Vulkan0 --device-draft Vulkan1`).
Splitting layers across cards makes them take turns: one R9700 decodes 57.8 t/s, two with a layer split 37.6.

**Memory:** 28.8 GiB at 64k without the draft; the draft adds 3.75 GiB (measured) and vision about 1 GiB. On one
32 GB card the draft does not fit next to Gyro-S: run it on a second GPU or on the CPU
(`LLAMA_ARG_N_GPU_LAYERS_DRAFT=0`), or drop drafting. Prefill is 250 t/s on this machine; one R9700 32 GB does
1,246 t/s prefill and 58 t/s decode.

---

## `marshall`

**For:** the `fast` tier of [marshall](https://github.com/LaurentZuijdwijk/agention-marshall),
or any coding agent with a two-tier model setup.

**Needs:** the same two models as [`dflash-fp4`](#dflash-fp4) — the
`julianmb/Qwen-3.8-27B-ROCmFP4-FAST-GGUF:FAST` target and the
`agentionai/Qwen3.8-27B-DFlash2-ROCmFP4-FAST-GGUF` sidecar.

```bash
agention-llama run marshall -- -hf julianmb/Qwen-3.8-27B-ROCmFP4-FAST-GGUF:FAST
marshall --workspace ~/code/project     # then /model, pick llama.cpp + localhost:8080
```

This is `dflash-fp4` plus continuous batching. An agent issues several requests
concurrently — context fetches, searches, history compression — and without
`cont-batching` they serialise behind one another.

That fast tier is most of an agent's token volume, and it is exactly the
workload this fork is fastest at: short, structured, tool-call-shaped
completions. marshall has a first-class `llamacpp` provider that probes a
running server, so there is nothing to integrate.

To pin it per project, copy [`examples/marshall.config.json`](examples/marshall.config.json)
to `.marshall/config.json` in the repo. Never put an API key in that file; it is
meant to be committed.

---

## `router`

**For:** serving everything in a directory and letting the client pick.

**Needs:** anything.

```bash
agention-llama serve                                  # globals.ini defaults
agention-llama serve --models-ini examples/models.ini # per-model config
```

With no model argument the server comes up as a **router**: it lists what it can
find, loads on demand, and forwards each request to the right instance. An INI
file configures that fleet — `[*]` cascades onto every model it discovers, so
the shipped `presets/globals.ini` needs no maintenance as you add GGUFs.

`presets/router.env` is empty **on purpose**. Anything set there becomes an
environment variable on the router, which every model instance inherits, silently
competing with the same key in your INI. One config layer is easier to reason
about than two.

The recipes above have INI equivalents — a section key is any `llama-server`
flag with its leading dashes removed:

```ini
[qwen3-27b-fp4]
alias = fast, agent
model = /models/Qwen3.8-27B-ROCmFP4-FAST.gguf
spec-type = draft-dflash
spec-draft-model = /models/dflash2/Qwen3.8-27B-DFlash2-ROCmFP4-FAST.gguf
spec-draft-adaptive = on
spec-draft-n-min = 3
spec-draft-n-max = 7

[ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M]
alias = ornith
spec-type = draft-mtp
spec-draft-n-min = 2
spec-draft-n-max = 4
ubatch-size = 2048
```

Full format reference, precedence rules and the router-only keys are in the
[README](README.md#model-configs--modelsini).

---

## Bring your own model family

Nothing above is model-agnostic, and the presets ship defaults that have to
match. Three rules:

1. **A DFlash2 sidecar must be trained against your target.** Repoint
   `LLAMA_ARG_SPEC_DRAFT_HF_REPO`, or `LLAMA_ARG_SPEC_DRAFT_MODEL` for a local
   file. Watch the acceptance line afterwards — a mismatch shows up there and
   nowhere else.
2. **`draft-mtp` needs a model with an MTP head.** No head, no start.
3. **Don't layer ngram under a draft model** — it costs 13%. Used alone on
   quote-heavy long context it is worth 25.4 t/s against 12.2 bare, but
   `ngram-cache` is slower than bare and `DSpark` did not pay off on this target.

Two more things measured not to work here: `Q2_0_ROCMFPX` has no Vulkan kernel,
and requantising a Q8_0 sidecar to ROCmFPx costs draft acceptance (see
[`dflash-q8`](#dflash-q8)).
