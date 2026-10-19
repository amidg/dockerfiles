# Qwen3.6-35B-A3B Q3_K_XL + vision — laptop dGPU tier

Status: FINAL PLAN, ready to execute. Target repo: `~/Projects/dockerfiles`.
**Step 0: file this document as `ai/plans/qwen3.6-35b-q3kxl.md`** (house plan
location; it was written in plan mode and could not touch the repo).
Build agent instructions: this file is self-contained; execute sections 3-9 in order.
House rules that bind every step: `ai/AGENTS.md` — same-session comparisons only;
judge agent tiers on `deep`, not `decode`; vision must be tested with a real 1280px
image (a 1×1 PNG has fooled this stack three times); never edit a config to make a
benchmark pass.

---

## 1. Decisions (user-confirmed 2026-10-18)

- **(a) Role: add alongside, bench-gated promotion.** `qwen3.6-35b` joins the dGPU
  tier as a third entry, `ttl: 600`, on-demand. It does **not** replace
  `gemma-4-26b-a4b` (main agent, promoted 2026-10-18) and does **not** touch any
  Hermes aux role or the opencode pin. Whether it is later promoted to main agent is
  a separate, bench-informed decision — out of scope here.
- **(b) Name: `qwen3.6-35b`** — direct naming, resurrecting the name retired in
  `742253c`. No collision: the stale *remote* entry is the dotted
  `server-qwen3.6-35b` at `api.gusev.tech` (deferred rewiring, untouched).
- **(c) Quant: UD-Q3_K_XL** (17.2 GB) — the recorded new reason that re-opens the
  "Q4_K_M is the floor" verdict is **mmproj fit**: at N=35 the Q4_K_M build left no
  room for the ~900 MiB projector on the 8 GB card; Q3_K_XL's smaller GPU-resident
  experts do. The −9% deep-decode cost must be re-measured, not inherited.
- **(d) MTP + mmproj on the GPU, 131072 ctx.** The MTP head ships **inside** the
  GGUF — **no `--model-draft`** (that flag is Gemma-style and would be wrong here).

## 2. Established facts (from current configs + AGENTS.md, engine b11641 / llama-swap v265)

| fact | value |
|---|---|
| dGPU tier now | `gemma-4-26b-a4b` (main, ttl 0, vision, 131K, N=27, deep 35.0, acc 62%/75%) + `gemma-4-e4b` (on-demand fallback, deep 134.8) |
| CPU | Ultra 9 285H: AVX2 + AVX_VNNI, **no AVX-512** — the Q3_K CPU-dequant cost finding applies |
| Prior Q3_K_XL verdict (b10276 era) | −9% deep vs Q4_K_M (43.3 vs 47.6), acceptance identical (58%/78% vs 60%/77%) — dequant cost, not draft quality |
| `--cpu-range 0-5 --cpu-strict 1` | **−10% decode @131072** (42.3 vs 46.5) → do NOT carry from the retired qwen baseline |
| weight repacking | default-enabled; measured ~6% cost for Q4/Q4_K CPU-resident experts (`-nr` 49.4 vs 46.3), not yet A/B'd with MTP + projector → leave default, do not add `--no-repack` |
| VRAM precedents | qwen Q4_K_M N=35 → 7275 MiB; tiel Q4_K_XL N=35 → 7402 MiB; qwen Q4_K_XL crashed at 7743 MiB with a real image |
| projector | `mmproj-F16.gguf` from this exact repo, n_embd 2048, save as `qwen3.6-35b-mmproj-F16.gguf` (vision-table convention) |
| sampler (Unsloth, thinking) | precise-coding row: temp 0.6, top_p 0.95, top_k 20, min_p 0.0, presence 0.0, repeat 1.0 — no penalties (penalties cost MTP acceptance) |
| KV / ctx | q4_0/q4_0 KV, 131072 ctx, batch 2048, ubatch 1024 (ubatch-before-N rule), flash-attn on, `--parallel 1` (forced by MTP) |
| bench footprint rule | ≤ ~40 GB summed GGUFs; this plan's runs pair 17.2 GB qwen with 14.25 GB gemma-4-26b-a4b (31.5 GB) or 4.0 GB e4b — legal |
| working tree | dirty: the 2026-10-18 consolidation is uncommitted. Land or commit it first; this plan builds on top of it |

HF API file facts (verified 2026-10-18, not assumed):

| file | bytes | sha256 (LFS oid) |
|---|---|---|
| `Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf` | 17,227,569,440 | `3fba9ab57290b34726837521335bf9268397174f3dd662880e2d0c5264d17b81` |
| `mmproj-F16.gguf` | 899,283,584 | `71f3cbc1f7cc0f30d09d41cfa924c0060827ebc33bf15ace7e86661e856f0160` |

## 3. Download (before anything else)

```bash
D=/mnt/data/llama/models
curl -sL --retry 3 --retry-delay 2 -o $D/Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf \
  https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf
curl -sL --retry 3 --retry-delay 2 -o $D/qwen3.6-35b-mmproj-F16.gguf \
  https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/resolve/main/mmproj-F16.gguf
```

Verify byte sizes and `sha256sum` against the table above. Abort on any mismatch.
(~17.1 GiB total.)

## 4. VRAM spike + N walk (gates everything)

Temporary entry, added to `ai/llama-swap-nvidia.yaml` **before** any other change
(nothing is removed — this is an add-alongside plan):

```yaml
  "qwen3.6-35b":
    cmd: |
      /app/llama-server \
        --model /models/Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf \
        --mmproj /models/qwen3.6-35b-mmproj-F16.gguf \
        --host 127.0.0.1 --port ${PORT} \
        --n-gpu-layers 99 --n-cpu-moe 35 --ctx-size 131072 --parallel 1 \
        --flash-attn on --cache-type-k q4_0 --cache-type-v q4_0 \
        --batch-size 2048 --ubatch-size 1024 \
        --cache-reuse 256 \
        --threads 6 \
        --load-mode none \
        --spec-type draft-mtp --spec-draft-n-max 2 \
        --temp 0.6 --top-k 20 --top-p 0.95 --min-p 0.0 --repeat-penalty 1.0
    proxy: "http://127.0.0.1:${PORT}"
    ttl: 600
    disableKeepAlives: true
```

Deliberate flag choices (do not "fix" them back):
- **no** `--cpu-range`/`--cpu-strict` (−10% measured at 131K),
- **no** `--model-draft` (Qwen bundles the MTP head),
- **no** `--reasoning` flag (thinking must stay reachable via the per-request field),
- `--min-p 0.0` explicit (unset = 0.05), `--repeat-penalty 1.0` (penalties cost draft acceptance),
- `--temp 0.6` = Unsloth precise-coding row (this box serves coding agents; the
  general row is a temperature-only edit later, decided on quality, never on t/s).

Also verify the mmproj `embedding_length == 2048` matches the body's n_embd before
trusting it — a mismatch aborts only on the first image request.

Walk N: `35 → 34 → 33 → 36` (35 first because it is the proven value; go *down* for
decode since Q3_K_XL frees VRAM, and probe 36 once to map the envelope). Each step:
`podman restart llama_swap_nvidia`, one small request to load,
`nvidia-smi --query-gpu=memory.used`, one ~100-token decode sample, watch `free -g`.
Record MiB per layer delta. Target: the largest GPU-resident expert count that holds
≤ ~7400 MiB at load **and** survives a real image.

**Kill criteria:**
- OOM at any N with mmproj resident → retest N with `--no-mmproj` (text-only).
- Still OOM text-only at N=38+ → drop `--ctx-size` to 65536 → still OOM → **abort**
  (nothing removed; the entry can be deleted or left dormant).
- Vision crashes (502, process gone) at the chosen N → step N back one layer and
  retest with a real image; if it cannot hold a 1280px image at any N ≥ 30, the
  premise is dead — record and stop.

## 5. Correctness checks (same session as section 4's last arm)

1. **Vision with a real 1280×1280 image**: `./llmbench.py --models qwen3.6-35b --tests vision`
   plus a generated image with a word in it. *Kill*: crash, 502, or hallucinated text.
2. **Thinking both directions**: (i) no reasoning control → reasoning chars > 0;
   (ii) top-level `reasoning_effort: "none"` → `APPROVE`/direct answer, 0 reasoning
   chars, `finish: stop` within 16 tokens. *Kill*: `none` still thinks → template
   or gateway bug, stop before wiring.
3. **MTP n-max {1,2,3}**, interleaved with `gemma-4-26b-a4b` (2-model rule, same run):
   `./llmbench.py --models qwen3.6-35b gemma-4-26b-a4b --tests perf --rounds 3 --perf-lines 320`.
   The old "n-max 3 is suspect" verdict predates b11641 — re-measure; keep the
   winner on deep + acceptance + quality, default to 2 on a tie.
4. **Full suite at depth**:
   `./llmbench.py --models qwen3.6-35b gemma-4-26b-a4b --tests all --rounds 3`.
   Judge on `deep`. Expect ~40-46 t/s if the Q3_K_XL penalty holds (46.9 × ~0.91)
   against gemma-4-26b-a4b's 35.0; expect acceptance ~68%/78% if the head is
   unchanged. Also longctx (expect ~50K @ ~900-930 t/s from the Q4_K_M precedent;
   Q3_K_XL prefill ran +11% in the old A/B).
5. Check `cut -d' ' -f1 /proc/loadavg` and `free -h` before each run; confirm
   `whisper_server` is not runaway (300%+ CPU kills every number on this box).

## 6. Wiring (after sections 4-5 pass)

`ai/litellm-config.laptop.yaml`:
- ADD `qwen3.6-35b` → `openai/qwen3.6-35b`, `api_base: http://llama_swap_nvidia:8080/v1`,
  `api_key: sk-no-key-required`, `allowed_openai_params: ["reasoning_effort"]`
  (drop_params would eat the field silently otherwise),
  `max_input_tokens: 131072`, `max_output_tokens: 32768` (32K rule for 128K models).
- REMOVE nothing. The stale dotted remote entries stay (deferred rewiring).

Final llama-swap entry: as section 4, with the N the walk picked and `ttl` per role
(600 for on-demand; the main-agent promotion question is deliberately out of scope).

## 7. End-to-end validation

- `podman restart llama_swap_nvidia` after every config edit (bind-mount inode trap).
- `./smoke.py` after the wiring (approval shape is the one failure mode a "does it
  respond" check misses).
- Through `:4000` with the master key: `qwen3.6-35b` approval role → `APPROVE`,
  `finish: stop`, 0 reasoning chars; a vision request returns an image-grounded
  answer; a normal turn streams without a post-stream 502 EOF
  (`disableKeepAlives: true` is already in the entry).
- Confirm `reasoning_effort` actually survives LiteLLM: one request with `none`
  must show 0 reasoning chars.

## 8. Documentation (same commit as the config changes)

- `ai/AGENTS.md`: architecture table row, Direct naming row (on-demand, not routed
  by default), performance table row, and a qualification note under
  "Q4_K_M is the floor" — Q3_K_XL re-entered with the recorded new reason (mmproj
  fit at N=35) and the fresh b11641 measurement; the old verdict stays for the
  quant-choice context. Update the vision projector table if the filename differs.
- `ai/README.md`: laptop tier model list + weights-to-download note.
- Record the N-walk table, the n-max re-test result, and VRAM after a real image.

## 9. Risks

| risk | severity | mitigation |
|---|---|---|
| Q3_K_XL CPU dequant costs the predicted −9% deep | medium | it is the accepted trade for mmproj fit; record the number either way |
| vision compute buffer kills the chosen N | high | section 4 kill criteria; real-image gate before promotion |
| mmproj n_embd mismatch | low | check metadata before benching; first image aborts loudly |
| n-max 3 regression returns on b11641 | low | re-measured in section 5.3, keep 2 on tie |
| prompt-cache/checkpoint issues (#24055) still open on the hybrid | low | same shape as before; in-slot prefix path unaffected |
| RAM pressure during N walk | medium | `free -g` watched; intel tier is embeddings-only now (~3.5 GB), which helps |
| operator later wants qwen as main agent | out of scope | separate bench-informed plan; aux-role repointing is the expensive part |

## 10. Rollback

`git checkout -- ai/llama-swap-nvidia.yaml ai/litellm-config.laptop.yaml` and
`podman restart llama_swap_nvidia`. Nothing was removed from any config, so a
rollback cannot strand a client. The downloaded GGUFs (~18 GB) are deletable but
re-downloadable — leave them unless disk pressure says otherwise.

## 11. Effort

~2 h wall clock, mostly waiting: download ~20 min, N walk ~25 min, correctness
~35 min, wiring ~10 min, end-to-end ~15 min, docs ~15 min. All novel risk sits in
the N walk + real-image gate; everything else repeats the pattern proven on
tiel → gemma-4-26b-a4b.

## 12. Outcome (executed 2026-10-18)

Two premises in this plan were falsified by measurement; the config shipped differently
from section 4.

1. **Q3_K_XL does not free enough for a GPU-resident projector at N=35.** N=35 with
   `--mmproj` loads at 7784 MiB and dies on first inference; N=36 works but leaves 519 MiB
   after a real image (inside this stack's crash band); N=37 leaves 851 MiB but costs
   3.8 t/s of the decode this entry exists for.
2. **Text-only is 38.0 t/s deep, not ~45.** The gap to the historical 46.3 is the quant,
   not the projector.

**Shipped config:** `--mmproj` + **`--no-mmproj-offload`** (CPU projector), N=35, n-max 2,
ttl 600. Deep **39.8 t/s**, prefill 1213, acc 65%/79%, 7040 MiB at load, 1405 MiB free after
a 1280px image, image turn ~40 s, `tools` 4/4, `quality` 4/4. This is the fastest
vision-capable configuration found and needs no second entry or cross-model swap.

**n-max 3:** +1.8% deep but `quality` 3/4 at the final flag set (4/4 at N=37/GPU projector),
so the "suspect" verdict holds and is config-dependent. Keep 2.

**Vision placement, decided:** do not move vision to `gemma-4-26b-a4b` (13.27 GiB swap per
image and back) and do not add a second text-only entry (same reload, worse). Move the
projector's execution device instead. The CPU encoder is the only cost, and it is bounded.
