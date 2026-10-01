# agention-llama

Packaging for [the adaptive-speculation llama.cpp fork](https://github.com/agentionai/llama.cpp):
a container image, portable binaries, and a preflight check that tells you
whether you are actually getting the fork's speed.

The fork is a Vulkan build of llama.cpp with **adaptive speculative decoding** —
draft length follows measured acceptance instead of a fixed `n` — on a backend
tuned for **AMD Strix Halo** (Radeon 8060S / gfx1151) using stock Mesa, no ROCm
toolchain. On a Qwen3.8-27B that is **65.6 t/s against 14.0 bare decode, 4.7x**,
at a setting that without adaptive sizing collapses to 20.2. This repo makes it
runnable without building it yourself.

Nothing here lives inside the fork tree. The fork stays clean so its
upstreamable fixes stay easy to send upstream.

---

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/agentionai/agention-llama/main/install.sh | sh

agention-llama doctor      # is this machine set up to be fast?
agention-llama recipes     # the configurations, one per use case

# The 4.7x one. Downloads Qwen3.8-27B (13.55 GiB) and its DFlash2 sidecar.
agention-llama run dflash-fp4 -- -hf julianmb/Qwen-3.8-27B-ROCmFP4-FAST-GGUF:FAST
```

Then open **http://localhost:8080** — the web UI is built into the server image.
The installer clones this repo and links one script; the image is pulled on
first run.

Run the doctor first. It takes a second and answers the question that matters:

```
  ok  device: Radeon 8060S Graphics (RADV STRIX_HALO)
      driver: radv Mesa 26.0.8-1ubuntu0.3
  ok  RADV 26.0 >= 25.3 — LDS stride fix active (pad 2, ~+12-14% prefill)
```

**[RECIPES.md](RECIPES.md) is the part most people want**: eight configurations,
what each one needs, what it was measured at, and how to tell it engaged.
`plain` runs anything and is the baseline. The speculative recipes are where the
4.7x lives, but each assumes something about the model you serve.

Prefer not to install a script?

```bash
docker run --rm -it --device /dev/dri \
  --group-add "$(getent group render | cut -d: -f3)" \
  -v ~/models:/models -p 8080:8080 \
  ghcr.io/agentionai/agention-llama:server
```

## Why the doctor exists

The fork's most broadly applicable win — a one-constant LDS bank-conflict fix
worth 12–14% prefill on every quant — **turns itself off on RADV older than
25.3**. That is deliberate: on older RADV the same constant is more than 2x
*slower*, because that driver lowers `coopMatLoad` to `ds_read_b128` and the
stride stops being aligned for it. So the fix is real, and it is silent when it
isn't taken.

Which Mesa decides differs by how you run:

| | who provides Mesa | consequence |
|---|---|---|
| container | the **image** | pinned; the build fails if the base is older than RADV 25.3 |
| binaries | the **host** | an old host distro silently gets the upstream-default path |

The doctor reports which case you are in. It runs on the host, inside the
container (as the server's preflight, printed at startup) and from the tarball.

It cannot tell you whether a *recipe* engaged — a mismatched sidecar degrades
quietly into ordinary decoding. That check is the draft-acceptance line, in
[RECIPES.md](RECIPES.md#did-it-actually-engage).

## What you get

### Container images

| image | contents |
|---|---|
| `ghcr.io/agentionai/agention-llama:server` | `llama-server` + the embedded web UI, healthcheck, preflight on start |
| `ghcr.io/agentionai/agention-llama:cli` | `llama`, `llama-cli`, `llama-bench`, `llama-quantize` |

Both are Vulkan builds on Ubuntu 26.04 with `GGML_BACKEND_DL` and
`GGML_CPU_ALL_VARIANTS`: the CPU variant is chosen at load time and the Vulkan
backend is a dlopened `.so`, so a machine with no Vulkan ICD still starts on CPU
instead of failing to link. x86-64 only.

Each push is also tagged `:server-<fork-commit>`, so rolling back is naming the
old tag rather than rebuilding.

To build them yourself from a fork checkout:

```bash
./scripts/build.sh server              # from ../llama.cpp (or $LLAMA_SRC)
./scripts/build.sh cli
./scripts/build.sh server --ref main   # from a fresh clone of the fork, pinned
```

`--ref` takes any git ref; pin a SHA when you want a reproducible image. The
build tags `agention-llama:server` and `agention-llama:server-<commit>`, and
stamps the commit into the image labels and `/app/BUILD_INFO`.

### Prebuilt binaries

No Docker, no compiler. Attached to the fork's
[releases page](https://github.com/agentionai/llama.cpp/releases):

| | |
|---|---|
| Linux x86-64 | `llama-<tag>-bin-ubuntu-vulkan-x64.tar.gz` — glibc 2.35, runs on anything from 2022 on |
| Windows x64 | `llama-<tag>-bin-win-vulkan-x64.zip` — self-contained, unzip and run |

The `agention-llama` CLI drives these too: with no Docker present it falls back
to them automatically, so the recipes work either way.

```bash
AGENTION_BACKEND=native agention-llama run dflash-fp4
```

The host needs a Vulkan ICD (`mesa-vulkan-drivers` on Linux) and, for the LDS
fix, Mesa ≥ 25.3 — a **Linux/RADV-only** gate, so Windows takes the upstream
default pad. Everything else in the fork applies on both.

Or build a Linux tarball locally:

```bash
./scripts/build.sh dist        # -> dist/agention-llama-<build>-vulkan-linux-x64.tar.gz
tar xzf dist/agention-llama-*.tar.gz && cd agention-llama-*
./doctor.sh && ./install.sh    # /opt/agention-llama + symlinks in /usr/local/bin
```

Built on Ubuntu 22.04 with the LunarG SDK. The runtime image can be modern
because it ships its own Mesa; a tarball cannot, so it is compiled against the
oldest glibc that still builds the tree.

### Recipes

Eight configurations, one per situation — see **[RECIPES.md](RECIPES.md)** for
the full treatment.

| recipe | for | model | measured |
|---|---|---|---|
| `plain` | baseline, no speculation | anything | 14.0 t/s |
| `dflash-fp4` | agents, structured output | **Qwen3.8-27B** + FP4 sidecar | **65.6 t/s** (4.7x) |
| `dflash-q8` | the same, on a stock K-quant target | **Qwen3.8-27B** + Q8_0 sidecar | 48.5 t/s |
| `mtp-long` | long context, any task, no sidecar | **Qwen3.8-27B**, or any MTP-head model | 36.1 t/s at 31k |
| `ornith-mtp` | long documents, fastest prefill | **Ornith-1.5-35B-A3B** | **1648 t/s** pp2048 (1.9x mainline) |
| `gyro` | a 126B MoE on one 32 GB GPU | **Qwen3.8-Flash-Next Gyro-S** | 32 → **58** t/s on JSON, 39 on prose |
| `marshall` | serving a coding agent's fast tier | as `dflash-fp4` | as `dflash-fp4` |
| `router` | a whole directory of models | anything | — |

Three model families cover all of it — the dense **Qwen3.8-27B** for generation,
the **Ornith-1.5-35B-A3B** MoE for prefill, and **Qwen3.8-Flash-Next Gyro** for a 126B MoE on one 32 GB GPU. Exact Hugging Face repos, and which
sidecar pairs with which target, are in
[RECIPES.md](RECIPES.md#the-models); everything downloads on first run.

```bash
agention-llama run mtp-long -- -m /models/a-model-with-an-MTP-head.gguf
```

Each is a short env file of `LLAMA_ARG_*` variables in `presets/` — edit them
freely. **A speculative recipe is not model-agnostic**: `mtp-long` needs a model
with an MTP head, the `dflash` ones need a sidecar trained against your target.
A mismatched sidecar does not merely run slower, it drafts tokens the target
rejects and you pay the draft cost for nothing.

### Model configs — `models.ini`

The presets above configure **one** model, passed with `-m`. Start the server
with no model and it comes up as a **router** instead: it lists everything it
can find, loads on demand, and forwards each request to the right instance. An
INI file is how you configure that fleet.

Two files ship here:

| file | contains | use it when |
|---|---|---|
| `presets/globals.ini` | a `[*]` section only — context, thinking, offload, speculative rails | the default; you want sane settings applied to every model without listing any |
| `examples/models.ini` | the same globals plus worked per-model sections | you want per-model context, thinking, or a draft model |

`[*]` cascades onto every model the router discovers on its own — your mounted
`/models` directory and the download cache — so the globals-only file needs no
maintenance as you add GGUFs.

```bash
./scripts/server.sh --models-ini examples/models.ini
MODELS_INI=./examples/models.ini docker compose up -d
```

**The format.** A key is any `llama-server` flag with its leading dashes
removed; short forms (`c`, `ngl`) and env names (`LLAMA_ARG_CTX_SIZE`) work as
keys too. A section name is the model name clients ask for.

```ini
[*]                                  ; applies to every model
ctx-size = 16384
reasoning = auto                     ; on | off | auto

[qwen3-27b-dflash]                   ; a local file
alias = short, fast                  ; extra API names, comma-separated
model = /models/Qwen3.8-27B-Q4_K_M.gguf
ctx-size = 8192                      ; overrides [*]
reasoning = off
spec-type = draft-dflash
spec-draft-model = /models/dflash2/Qwen3.8-27B-DFlash2-Q8_0.gguf

[ggml-org/gemma-3-4b-it-GGUF:Q4_K_M] ; a HF repo, downloaded on first use
ctx-size = 8192
```

The four knobs worth knowing, since they are what you actually change:

- **`ctx-size`** — the biggest lever on memory. An APU shares system RAM with
  the GPU, so this is the first thing to turn down when a model won't fit.
- **`reasoning`** — `on` / `off` / `auto`. `off` is the fast choice for
  tool-call and extraction work; `auto` follows the model's chat template.
- **`reasoning-effort`** and **`reasoning-budget`** — how much thinking, and a
  hard token ceiling on it (`-1` unrestricted, `0` off immediately). The budget
  is what stops a reasoning model stalling an agent loop.
- **`spec-type`** plus its draft model — per-model speculative decoding, which
  is the whole point of the fork. Same requirements as the presets above: a
  DFlash2 sidecar must match its target, `draft-mtp` needs a model with an MTP
  head.

Three keys configure the router rather than `llama-server`:
`load-on-startup` (load at boot instead of on first request), `stop-timeout`,
and `dedup-cache-models`. Five more are ignored because the router owns them:
`host`, `port`, `api-key`, `models-dir`, `models-preset`.

**Precedence**, lowest to highest: `[*]` → the model's own section → flags on
the `llama-server` command line. That last one is a blunt instrument — a `-c
8192` on the command line overrides `ctx-size` for *every* model in the file —
which is why `presets/router.env` is empty on purpose. Environment variables
set on the router are inherited by every model instance too, so keeping
configuration in one layer, the INI, is the whole design.

An unrecognised key is a hard error at startup, not a warning. That is a
feature: a typo'd `ctx_size` fails loudly instead of silently serving 4096.

### Is it actually working?

The doctor answers this for the driver gate, at startup. It cannot answer it for
the recipe: a mismatched sidecar, or a model with no MTP head, degrades quietly
into ordinary decoding rather than failing. Reading the per-request draft
acceptance line is how you check, and it is written up once in
**[RECIPES.md](RECIPES.md#did-it-actually-engage)** rather than repeated here.

The short version: `mean len` is the number that maps to wall-clock, and at 1.0
speculation is costing you time.

## Running it as a service

Most people end up running this permanently. There are two ways, and they
differ in one thing that matters: **who owns the upgrade.**

| | systemd unit on the binaries | container |
|---|---|---|
| what runs | `llama-server` from the tarball or your own build | the image |
| Mesa comes from | the **host** — an old distro silently loses the LDS fix | the **image** — pinned, build-time verified |
| upgrade | rebuild or reinstall in place, then restart | build a new image, recreate the container |
| rollback | whatever you kept a copy of | `image: ...agention-llama:server-<commit>`, published per build |
| GPU access | your user is in the `render` group | `--group-add` with the host's render gid |
| config | flags in the unit file | `.env` + `models.ini` |

The container is the better default precisely because of row two: the fork's
headline fix is driver-gated, and in a container the image pins the driver.
The unit is the better choice if you are iterating on the fork itself and want
your working tree running without a build step.

### As a container

```bash
cp .env.example .env         # set MODELS_DIR, MODELS_INI, RENDER_GID
docker compose up -d         # pulls the published image
docker compose logs -f server
```

Compose already sets `restart: unless-stopped`, so it survives reboots once the
Docker daemon is enabled. Restart, and pick up a changed `.env`:

```bash
docker compose restart server            # config unchanged
docker compose up -d --force-recreate    # after editing .env
```

Editing `models.ini` needs neither — the router re-reads it, and the file is
mounted read-only from the host, so it is not baked into the image.

`docker-compose.yml` pulls and never builds. To run your own fork checkout
instead, add the override:

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

### Migrating from a systemd unit

If you already run something like this:

```ini
[Service]
ExecStart=/home/you/.local/bin/llama-server --models-preset /models/models.ini \
  --host 0.0.0.0 --port 8080
WorkingDirectory=/models
```

then the translation is entirely `.env`:

```bash
MODELS_DIR=/models                 # same path inside and out, so absolute paths in the ini still resolve
MODELS_INI=/models/models.ini      # your existing file, mounted read-only
PRESET=router                      # empty on purpose; the ini owns the config
PORT=8080
```

Four things to check on the way across:

1. **Stop the unit first** — `systemctl --user disable --now llama-server`.
   Both bind `0.0.0.0:8080` and the second one to start just fails.
2. **Relative paths in your INI.** The unit's `WorkingDirectory=/models` is what
   made `model = some-model.gguf` resolve. The container sets `working_dir:
   /models` to match, but absolute paths are the safer fix.
3. **Drop `HSA_*` environment variables.** `HSA_OVERRIDE_GFX_VERSION` and
   friends are ROCm settings; this is a Vulkan build and they do nothing.
4. **Don't set `PRESET` to one of the single-model presets.** Those export
   `LLAMA_ARG_*` variables that every model instance inherits, competing with
   the same keys in your INI. `router` is empty for that reason.

To keep `systemctl` muscle memory, let systemd own compose rather than the
binary:

```ini
# ~/.config/systemd/user/agention-llama.service
[Unit]
Description=agention-llama
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=%h/.local/share/agention-llama
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
ExecReload=/usr/bin/docker compose up -d --force-recreate

[Install]
WantedBy=default.target
```

### Updating

```bash
agention-llama update          # docker pull, and fast-forward the recipes
```

Or with compose:

```bash
docker compose pull && docker compose up -d
```

Every published build is also tagged `:server-<fork-commit>`, so the previous
image stays addressable under its own name. Rolling back is setting `IMAGE` in
`.env` to that tag and running `up -d` again — no rebuild, no network if it is
still on disk.

Building it yourself instead:

```bash
git -C ../llama.cpp pull                 # or check out the ref you want
./scripts/build.sh server                # rebuild
IMAGE=agention-llama:server docker compose up -d
```

For something reproducible, build from a ref rather than your working tree:

```bash
./scripts/build.sh server --ref 0b120ab11
```

`--ref` clones the public fork into `.cache/` and builds from a detached
checkout, so uncommitted local changes cannot leak into an image you intend to
keep. Building from `../llama.cpp` includes your working tree — convenient
while developing, wrong for anything you want to reproduce later. The commit is
stamped into `/app/BUILD_INFO` and the image labels either way:

```bash
agention-llama version
```

For the binaries instead, download the newest release archive and re-run its
`install.sh`; it replaces `/opt/agention-llama` in place, so the symlinks in
`/usr/local/bin` keep pointing at the new build.

## Using it with marshall

[marshall](https://github.com/LaurentZuijdwijk/agention-marshall) is a terminal
coding assistant with a two-tier model setup: a `deep` tier that makes the
decisions, and a `fast` tier that does the bulk work — fetching context,
searching, compressing history. That fast tier is most of the token volume, and
it is exactly the workload this fork is fastest at: short, structured,
tool-call-shaped completions, which is the DFlash2 case at 3× bare decode.

marshall has a first-class `llamacpp` provider that probes a running server, so
there is nothing to integrate:

```bash
agention-llama run marshall -- -hf julianmb/Qwen-3.8-27B-ROCmFP4-FAST-GGUF:FAST
marshall --workspace ~/code/project        # then /model, pick llama.cpp + localhost:8080
```

(The `marshall` preset carries the Qwen3.8-27B DFlash2 sidecar; serving a
different model means repointing it — see [Presets](#presets).)

To pin it per project, copy [`examples/marshall.config.json`](examples/marshall.config.json)
to `.marshall/config.json` in the repo — fast on the local server, deep wherever
you pay for it. Never put an API key in that file; it is meant to be committed.

marshall deliberately is **not** containerised here. It edits your workspace and
runs shell commands under its own approval gate; putting that inside a container
fights the design rather than helping it.

## Layout

```
bin/agention-llama     the one command: doctor, recipes, run, serve, update
install.sh             curl | sh installer — clones this repo, links the CLI
RECIPES.md             eight configurations, what each needs, what it measured
docker/Dockerfile      all image targets + the portable-binary stage
docker-compose.yml     long-lived server, pulls the published image
docker-compose.build.yml  override that builds from a fork checkout instead
presets/*.env          the recipes (one model, configured by env)
presets/router.env     empty on purpose — in router mode the INI owns the config
presets/globals.ini    default model config: global defaults, no models listed
examples/models.ini    worked per-model config, to copy and edit
examples/marshall.config.json   marshall project config
scripts/doctor.sh      preflight: GPU access, driver, whether the LDS fix is on
scripts/build.sh       build images or the tarball from a fork checkout
scripts/server.sh      run llama-server directly (what the CLI wraps)
scripts/cli.sh         run llama cli (or any binary in the image)
.github/workflows/images.yml   builds and pushes the images to GHCR
```

The Dockerfile takes the fork as a BuildKit **named context** (`llamasrc`)
rather than as the build context, which is what keeps this repo outside the
fork. The fork's own `.dockerignore` still applies, so `build/` and `models/`
never enter the transfer.

**`run` and `serve` are different modes, on purpose.** `agention-llama run
<recipe>` configures a single model from a preset and mounts no INI;
`agention-llama serve` mounts the INI and applies the empty `router.env`.
Mixing them means environment variables set on the router are inherited by every
model instance, silently competing with the same keys in your INI. One
configuration layer is easier to reason about than two.

## Caveats

- Every number quoted here was measured on a single Radeon 8060S (Strix Halo
  APU) against upstream master, interleaved on an idle GPU. Other hardware gets
  the correctness fixes and the upstreamable wins; the tuning was not measured
  there.
- CI here proves the images *build*, and nothing more. No hosted runner has this
  GPU, so it can never prove they are fast. Performance verification is
  `bench/run-spec-suite.sh` in the fork, run locally — and that asymmetry is
  exactly why the doctor and the acceptance line exist.
- ROCmFPx models need converting; that tooling lives in the fork
  (`conversion/`), not in these images.
