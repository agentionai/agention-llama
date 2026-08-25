# Recipes

Seven configurations, one per situation. Each names the model it needs, the
command to run it, and how to tell it actually engaged — because a speculative
preset that doesn't match your model degrades **quietly** into ordinary decoding
rather than failing.

Every number here was measured on a single Radeon 8060S (Strix Halo APU). Other
hardware gets the correctness fixes and the upstreamable wins; the tuning was
not measured there.

| recipe | for | needs | measured |
|---|---|---|---|
| [`plain`](#plain) | the baseline, and A/B comparisons | anything | 14.0 t/s |
| [`dflash-fp4`](#dflash-fp4) | agents, structured output — the headline | Qwen3.8-27B FP4 + FP4 sidecar | **65.6 t/s, 4.7×** |
| [`dflash-q8`](#dflash-q8) | the same, on a stock K-quant target | any Qwen3.8-27B + Q8_0 sidecar | 48.5 t/s |
| [`mtp-long`](#mtp-long) | long context, any task, no sidecar | a model with an MTP head | 36.1 t/s at 31k |
| [`ornith-mtp`](#ornith-mtp) | long documents, fastest prefill | Ornith-1.5-35B-A3B (MoE) | **1648 t/s pp2048** |
| [`marshall`](#marshall) | a coding agent's fast tier | as `dflash-fp4` | as `dflash-fp4` |
| [`router`](#router) | serving a whole directory of models | anything | — |

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

**Needs:** a **Qwen3.8-27B** target. The sidecar is trained against it.

```bash
agention-llama run dflash-fp4 -- -hf julianmb/Qwen-3.8-27B-ROCmFP4-FAST-GGUF:FAST
```

The sidecar (`agentionai/Qwen3.8-27B-DFlash2-ROCmFP4-FAST-GGUF`) downloads on
first run.

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

**Needs:** any Qwen3.8-27B target.

```bash
agention-llama run dflash-q8 -- -m /models/Qwen3.8-27B-Q4_K_M.gguf
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

**Needs:** a model with an **MTP / nextn head**. The draft context is built from
the target itself, so a model without one cannot start in this mode — it fails
loudly rather than falling back.

```bash
agention-llama run mtp-long -- -m /models/a-model-with-an-MTP-head.gguf
```

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

**Needs:** Ornith-1.5-35B-A3B, or another delta-net MoE.

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

## `marshall`

**For:** the `fast` tier of [marshall](https://github.com/LaurentZuijdwijk/agention-marshall),
or any coding agent with a two-tier model setup.

**Needs:** as `dflash-fp4`.

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
