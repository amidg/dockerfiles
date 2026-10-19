# Plan: desktop Strata — Swift 1.5 (Qwen3.8-Flash-Next IQ2_XS) refresh

**Status of the base migration:** implemented and committed — `96d89db` (desktop
llama.cpp → Strata, submodule `ai/Strata` @ v0.1.45, compose service, desktop LiteLLM
config, n8n/ollama/research/open-webui removal, README/AGENTS.md rewrite).

**Status of the Swift refresh (Section A): done in `bb34bf1`.** The `strata` service now
runs `FAMILY=swift` / `VISION=cpu`, and README/AGENTS.md carry the Swift 1.5 rationale,
the 40GB-pin contract and the manual rollout runbook. Section A is kept below as the
record of what was changed and why; **Section B is the live part** — the manual rollout
still to be performed on the remote desktop.

**Repo state at refresh (2026-10-18):** HEAD was `418d13f` at the time of writing, with
four commits since `96d89db` (`a4ebb16` whisper on CPU, `94d5e2f` gemma-4-26b-a4b,
`2788179` qwen3.6-35b UD-Q3_K_XL + CPU projector back on the laptop dGPU, `418d13f`
ubatch tuning) — all laptop-side; the `strata` service was untouched by them. The
laptop's gateway roster has changed (`gemma-4-26b-a4b`, `qwen3.6-35b` in;
`tiel-coder-35b`, `lfm2.5-24b` out) and the two stale `server-qwen3.8-27b` /
`server-qwen3.6-35b` remote entries remain — B8 is unchanged, and laptop docs are that
repo's business, not this plan's.

> **Rollout note: everything below is rolled out manually by the user on the remote
> desktop machine.** The build agent only edits this repo; it never SSHes anywhere,
> never builds the container image, never downloads weights, and never runs the stack.
> Section A is the (completed) agent work; Section B is the user's runbook.

## Settled decisions (2026-10-18)

- **Model: Swift 1.5 IQ2_XS** — `ukisai/Swift-1.5-Qwen3.8-Flash-Next-GSQ-RCO-GGUF`,
  Strata family `swift`. UkisAI's post-train of the same 125B-A6B architecture: ~63%
  fewer thinking tokens, 1.8× sooner answers, <1% quality loss at xhigh effort. Its
  IQ2_XS beats base ISTA IQ2_XS KLD on 7/8 eval sets at the same ~35.5 GiB arena.
- **Memory contract: 40GB pin maximum**, hard. `STRATA_ARENA_PIN_GIB=40` stays. The
  documented worst case allows up to **48GB pin only** for a quant that needs it — the
  concrete candidate recorded below is **Swift IQ3_XXS** (arena ~42.9 GiB → pin 44).
  Anything needing more (IQ3_S 50.3 GiB, UD-Q4_K_XL 77, NVFP4 68) is out of scope, not
  a "worst case".
- **GPU: 5070 Ti 16GB**; 7900 XTX display-only (unchanged).
- **Vision: `VISION=cpu`.** Strata recommends the GPU encoder only at ≥23.5GB VRAM
  (#2406); on 16GB the CPU encoder is the engine's own recommended path — frees
  ~1.1–1.4GB VRAM for the expert cache at 3–5% decode cost. This **changes** the
  `VISION=yes` shipped in 96d89db.
- **Gateway name stays `qwen3.8-flash-next`** (user decision) — the LiteLLM entry and
  all client pins keep the name even though Swift 1.5 weights answer. Documented as a
  deliberate, user-owned naming choice (it is the model the desktop serves; the Swift
  post-train is what it is). No aliases.
- Context **262144**, KV `k8v4` (raised from 131072 on 2026-10-19 — 262K + k8v4 streaming;
  KV is only 13 × 816 B/token here, so the whole window costs 2.59 GiB of pinned RAM and no
  VRAM, and the total pinned set stays ≈36.4 GiB inside the 40 GiB contract)
  works with it from v0.1.40).
- **Swift Q2_0 is excluded** — its shards split one layer's experts across both shards,
  which Strata's packer cannot handle yet (upstream issue #171). Not a candidate.
- License note: Swift 1.5 GGUFs are **Swift Open License 1.0**, not Apache-2.0 like the
  ISTA quants — user accepted by choosing the family.

## File changes (follow-up diff)

### 1. `ai/llama-cpp.yml` — `strata` service env only

```yaml
      - MODEL=IQ2_XS
      - FAMILY=swift
      - CONTEXT=262144
      - VISION=cpu
      - KV=k8v4
      - GGUF_DIR=/models
      - STRATA_ARENA_PIN_GIB=40
```

Changes vs 96d89db: `FAMILY=qwen` → `swift`, `VISION=yes` → `cpu`. Everything else
(ports, volumes, memlock, grace period, network) unchanged. The entrypoint derives the
config tag `strata-swift-iq2_xs.json` under `/data/config`; a fresh `/data` volume (or
first boot with the new tag) runs the setup pass automatically — no `REINSTALL`.

### 2. Weights checklist (user downloads manually into `$LLAMA_MODELS_DIR`)

- `Swift-1.5-Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS` GGUF shards, **original filenames**
  (Strata matches the first shard by the canonical name or any `*-00001-of-*.gguf`
  containing the model name) — ~68 GB download
- `mmproj-Swift-Qwen3.8-Flash-Next-BF16.gguf` (~0.91GB) — **Swift ships its own
  projector; the base model's `mmproj-Qwen3.8-Flash-Next-BF16.gguf` is not reused**
- MTP draft (~6GB) still auto-fetches into `/data` on first start
- The base ISTA IQ2_XS shards are **not** needed; if they were downloaded, they can go
  (both families' shard-2 n-gram tables are byte-identical, but keeping both wastes
  ~28GB of disk)

### 3. `ai/litellm-config.desktop.yaml` — no change

Name, caps, allowlist and timeouts stay as committed. Only the weights behind the name
change.

### 4. Docs (same-commit rule)

**`ai/README.md`:**
- Desktop section: Swift 1.5 IQ2_XS, `VISION=cpu` rationale (16GB card, #2406), the
  40GB-pin-maximum contract and the **IQ3_XXS @ 44GB-pin worst case** as the single
  documented upgrade step (`MODEL=IQ3_XXS`, same family; ~15% decode cost for KLD
  0.341 → 0.240).
- Weights checklist: Swift repo + Swift mmproj; base-model shards explicitly not
  needed.
- Keep the three first-boot checks (CDI GPU wiring, arena pin ~36-40GiB via `grep VmLck
  /proc/<pid>/status`, `/v1/models` id vs LiteLLM `model:` field).

**`ai/AGENTS.md`:**
- Update the "Strata on the desktop — promoted 2026-10-17" section: promoted model is
  Swift 1.5 IQ2_XS (family `swift`), with the measured KLD comparison vs ISTA's IQ2_XS,
  the 40GB-pin contract and the IQ3_XXS worst case, `VISION=cpu` decision with the
  #2406 citation, Q2_0's #171 exclusion, and the Swift Open License 1.0 note.
- Architecture table row: `swift` family, Swift mmproj.
- Naming: record that `qwen3.8-flash-next` deliberately names the Swift 1.5 weights
  (user decision 2026-10-18) — anyone reading the config must know the weights are
  Swift's.

## Worst case, concretely documented

```text
Default:  MODEL=IQ2_XS   FAMILY=swift   STRATA_ARENA_PIN_GIB=40   (~35.5 GiB arena, fits)
Worst case (only if IQ2_XS disappoints):
          MODEL=IQ3_XXS   FAMILY=swift   STRATA_ARENA_PIN_GIB=44   (~42.9 GiB arena)
          # ≤48GB pin; ~15% slower decode; leaves ~52GB free on 96GB; KLD 0.240 vs 0.341
Beyond:   IQ3_S (50.3 GiB), UD-Q4_K_XL (77), NVFP4 (68) — over the 48GB worst case, out of scope
```

## Out of scope (unchanged)

- No downloads, no build/run/testing by the agent; first-boot verification is the
  user's checklist.
- Laptop rewiring (`litellm-config.laptop.yaml`, Hermes, opencode pins) — still
  deferred.
- Runtime purge of retired volumes/networks — user-run commands, already documented.

---

## A. Instructions for the build agent (repo only) — done in `bb34bf1`

Kept as the record of the change. Verified end state: the `strata` service runs
`FAMILY=swift` / `VISION=cpu`, `ai/litellm-config.desktop.yaml` still has exactly one
`model_name: qwen3.8-flash-next` entry, and README/AGENTS.md carry the Swift facts.

Apply, in order, on a fresh checkout at `~/Projects/dockerfiles`:

1. **`ai/llama-cpp.yml`** — in the `strata` service's `environment` list, change exactly
   two lines (verified still `qwen`/`yes` at HEAD `418d13f`; the service is otherwise
   identical to `96d89db`):
   - `FAMILY=qwen` → `FAMILY=swift`
   - `VISION=yes` → `VISION=cpu`
   Leave `MODEL=IQ2_XS`, `CONTEXT=131072`, `KV=k8v4`, `GGUF_DIR=/models`,
   `STRATA_ARENA_PIN_GIB=40`, ports, volumes, `ulimits.memlock: -1`,
   `stop_grace_period: 90s` untouched. Verify with `python3 -c "import yaml;
   yaml.safe_load(open('ai/llama-cpp.yml'))"`.
2. **`ai/litellm-config.desktop.yaml`** — no change. Verify it still contains exactly
   one `model_name: qwen3.8-flash-next` entry and no aliases/fallbacks.
3. **`ai/README.md`** — in the "Desktop: Strata + Qwen3.8-Flash-Next" section and the
   weights checklist:
   - promoted model is **Swift 1.5 IQ2_XS** (family `swift`, repo
     `ukisai/Swift-1.5-Qwen3.8-Flash-Next-GSQ-RCO-GGUF`): −63% thinking tokens,
     1.8× sooner answers, <1% quality loss at xhigh; its IQ2_XS beats base ISTA
     IQ2_XS KLD on 7/8 eval sets
   - weights checklist: Swift IQ2_XS shards (original filenames) +
     **`mmproj-Swift-Qwen3.8-Flash-Next-BF16.gguf`** (~0.91GB — Swift ships its own
     projector; the base model's mmproj is not reused); base ISTA shards explicitly
     not needed
   - memory contract: **40GB pin maximum**; worst case = Swift IQ3_XXS @ pin 44
     (arena ~42.9 GiB, ~15% slower, KLD 0.240 vs 0.341); IQ3_S / UD-Q4_K_XL / NVFP4
     are over the worst case and out of scope; Swift Q2_0 excluded (upstream #171)
   - `VISION=cpu` with the #2406 citation (GPU encoder recommended only ≥23.5GB VRAM;
     frees ~1.1–1.4GB VRAM at 3–5% decode cost)
   - license note: Swift Open License 1.0 (not Apache-2.0)
   - add the manual rollout runbook from Section B (or link it)
4. **`ai/AGENTS.md`** — update the "Strata on the desktop — promoted 2026-10-17"
   section and the architecture table row with the same facts: Swift 1.5 IQ2_XS,
   `VISION=cpu` + #2406, 40GB-pin contract + IQ3_XXS worst case, Q2_0/#171, license,
   and the deliberate naming note: **`qwen3.8-flash-next` names Swift 1.5 weights**
   (user decision 2026-10-18) — the config name must not be "corrected" to match the
   weights later without the user's say-so.
5. **Commit** in the repo's style (single-line imperative subject + short body),
   e.g. `feat: switch desktop Strata to Swift 1.5 IQ2_XS, vision on CPU`.
   Do not commit `ai/whisper_pip.txt`, `ai/plans/*.md` (untracked user WIP) or any
   weights.

## B. Manual rollout runbook (user, on the remote desktop machine)

**B0. Prerequisites, once**
- NVIDIA driver ≥ 580; `podman`, `podman-compose`; the repo cloned at
  `~/Projects/dockerfiles` (or wherever it lives on that machine).
- Fast NVMe with ≥ 200GB free: `/var/mnt/data/llama` (models) and
  `/var/mnt/data/llama/strata` (Strata data dir — n-gram table, MTP draft, pack,
  config). On Fedora Atomic `/mnt/data` and `/var/mnt/data` are the same directory;
  this runbook uses the canonical `/var/mnt/data`.

**B1. Update the checkout**

```bash
cd ~/Projects/dockerfiles
git pull --ff-only
git submodule update --init --checkout ai/Strata   # pins v0.1.45 (or the tag the repo pins)
```

**B2. Download the weights manually** into `$LLAMA_MODELS_DIR` (the same dir the laptop
uses, e.g. `/var/mnt/data/llama/models`) — **original filenames, do not rename**:

```bash
export LLAMA_MODELS_DIR=/var/mnt/data/llama/models
cd $LLAMA_MODELS_DIR
hf download ukisai/Swift-1.5-Qwen3.8-Flash-Next-GSQ-RCO-GGUF \
  --include "Swift-Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-*.gguf" \
  --include "mmproj-Swift-Qwen3.8-Flash-Next-BF16.gguf" \
  --local-dir .
```

That is ~68GB of GGUF shards + the 0.91GB Swift projector. **Do not download** the base
ISTA shards (not needed), Swift Q2_0 (packer bug #171), or any MTP file (Strata fetches
the draft itself into `/data` on first start). Verify the first shard name contains
`Swift` and matches `*-00001-of-*.gguf` — that is how Strata's setup finds it.

**B3. Prepare the data dir**

```bash
mkdir -p /var/mnt/data/llama/strata   # already created user-owned on the desktop 2026-10-18
```

**B4. Build and start**

```bash
export LLAMA_MODELS_DIR=/var/mnt/data/llama/models
export STRATA_DATA_DIR=/var/mnt/data/llama/strata    # compose default, override as needed
podman-compose -f ai/llama-cpp.yml --profile server build strata   # engine build, CUDA_ARCHITECTURES=120
podman-compose -f ai/llama-cpp.yml --profile server up -d
```

The first start is **minutes of logged silence** — setup unpacks the pack, fetches the
MTP draft and loads the arena before :8080 opens. Watch `podman logs -f strata`.

**B5. First-boot checks (in order, stop on the first failure)**
1. `curl -s 127.0.0.1:8080/health` — up.
2. **GPU wiring**: `podman logs strata | head -50` — the engine must report the 5070 Ti.
   If it reports no GPU, the podman CDI fallback is:
   `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`, then replace the
   `extends: base_nvidia` block on the `strata` service with
   `devices: ["nvidia.com/gpu=all"]` (with `security_opt: label=disable` if SELinux
   blocks it, per this repo's laptop notes) and `up -d` again.
3. **Arena**: `grep VmLck /proc/$(podman inspect -f '{{.State.Pid}}' strata)/status`
   → expect ~36–40 GiB. Confirm the desktop is still responsive (browser, compositor).
   If the pin comes back 0 or tiny, check `STRATA_ARENA_PIN_GIB=40` survived into the
   container env.
4. **Model id**: `curl -s 127.0.0.1:8080/v1/models | jq -r '.data[].id'` — must be
   `qwen3.8-flash-next` (or whatever the config names). If Strata advertises something
   else, change the `model:` field in `ai/litellm-config.desktop.yaml` to match
   (one line), then `podman restart litellm_server` (bind-mount inode rule).
5. **Gateway**: wait ~30–60s, then
   `curl -s localhost:4000/health/liveliness`, then a real completion through
   `:4000/v1` with `model: qwen3.8-flash-next`.

**B6. Rollback / quant ladder**
- Back to base ISTA IQ2_XS: swap weights, set `FAMILY=qwen` in the service env (the
  base mmproj is also required), `up -d`.
- The documented worst case (only if IQ2_XS disappoints): download Swift IQ3_XXS, set
  `MODEL=IQ3_XXS` and `STRATA_ARENA_PIN_GIB=44` (never above 48), `up -d` — the new
  model tag triggers its own setup pass.
- **Do not raise the pin past 48** and do not point the service at IQ3_S / UD-Q4_K_XL /
  NVFP4 without a new decision — they exceed the documented worst case.

**B7. One-time cleanup of the retired stacks** (same machine, when convenient)

```bash
podman-compose -f ai/n8n.yml down -v || true
podman-compose -f ai/ollama.yml down -v || true
podman-compose -f ai/research.yml down -v || true
podman-compose -f ai/llama-cpp.yml --profile server down   # retire old llama-swap/litellm/open-webui desktop containers
podman volume rm n8n_storage n8n_demo_data n8n_shared_data \
  postgres_storage qdrant_storage ollama open-webui \
  ldr_data ldr_scripts local_collections searxng_data || true
podman network rm n8n_network open-webui-network ldr-network || true
```

Volume names may carry podman-compose prefixes — verify with `podman volume ls`.
`postgres_storage` is n8n's postgres; the LiteLLM one (`litellm_postgres`) is kept.
The old llama.cpp GGUFs (Qwen3.8-27B IQ4_XS, Qwen3.6-35B, projectors) can be deleted
from `$LLAMA_MODELS_DIR` at the user's discretion — they are outside this repo.

**B8. Still pending, separately (not part of this rollout)**
- Laptop rewiring: `ai/litellm-config.laptop.yaml` remote entries still name
  `server-qwen3.8-27b` / `server-qwen3.6-35b`, which no longer exist.
- Client pins: `~/.hermes/config.yaml` and `~/.config/opencode/opencode.json` must be
  re-pointed to `qwen3.8-flash-next` (262144 pin since 2026-10-19).
