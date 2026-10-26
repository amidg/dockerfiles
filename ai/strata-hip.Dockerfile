# syntax=docker/dockerfile:1
#
# Strata: Qwen3.8-Flash-Next on an AMD Radeon card (RX 7900 XT / XTX, gfx1100) through the HIP
# backend (upstream docs/AMD_HIP.md). The CUDA image's Dockerfile cannot be reused: it builds
# with nvcc and ships no ROCm, and one build carries one backend only.
#
# Build (on the PC it runs on: the engine is compiled for that CPU):
#   podman-compose -f llama-cpp.yml --profile server_work build strata_hip
#
# One difference from upstream's docker-entrypoint.sh: VRAM_RESERVE_MIB becomes setup.py's
# --vram-reserve-mib (the VRAM the expert cache leaves free for other programs). This card
# drives the desktop, so the work profile asks for 4096 MiB; upstream measured 3072 as the
# value that keeps a KDE/Wayland session alive (docs/AMD_HIP.md, issues #560/#516).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 LANG=C.UTF-8 STRATA_EXECV=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git libatomic1 libgomp1 \
        python3 python3-pip python3-venv unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/strata
COPY . .

# No system ROCm here: setup.py installs AMD's TheRock wheels into .venv (~10 GB), the path
# upstream tests for gfx110X. cmake and ninja come from requirements.txt.
RUN python3 -m venv .venv \
    && .venv/bin/pip install --no-cache-dir --upgrade pip \
    && .venv/bin/pip install --no-cache-dir -r requirements.txt \
    && chmod +x setup.sh docker-entrypoint.sh

# gfx1100 = RX 7900 XT / XTX. BUILD.json is what setup.py reads to reuse the engine instead of
# recompiling, so the first container start goes straight to the model.
ARG HIP_ARCHITECTURES=gfx1100

RUN .venv/bin/python - <<'PYEOF'
import os
import setup

llama = setup.get_llama_cpp()
archs = [a for a in os.environ.get("HIP_ARCHITECTURES", "gfx1100").strip().strip('"').replace(";", ",").split(",") if a]
setup.build_engine_hip({"arch": archs[0], "archs": archs}, llama, "cpu")
PYEOF

# Upstream's entry point, plus VRAM_RESERVE_MIB -> --vram-reserve-mib on the setup pass. The
# build stops if upstream's wording changes: a silently dropped reserve puts the desktop's
# compositor back in the OOM-killer's reach.
RUN python3 - <<'PYEOF'
p = "docker-entrypoint.sh"
s = open(p, encoding="utf-8").read()
s = s.replace('CONFIG="${CONFIG:-}"',
              'VRAM_RESERVE_MIB="${VRAM_RESERVE_MIB:-}"   # MiB of VRAM kept free for other programs\n'
              'CONFIG="${CONFIG:-}"', 1)
s = s.replace('  if [ -n "$GGUF_DIR" ]; then set -- "$@" --gguf-dir "$GGUF_DIR"; fi',
              '  if [ -n "$GGUF_DIR" ]; then set -- "$@" --gguf-dir "$GGUF_DIR"; fi\n'
              '  if [ -n "$VRAM_RESERVE_MIB" ]; then set -- "$@" --vram-reserve-mib "$VRAM_RESERVE_MIB"; fi', 1)
assert s.count('--vram-reserve-mib "$VRAM_RESERVE_MIB"') == 1, \
    "upstream docker-entrypoint.sh changed: re-apply the VRAM_RESERVE_MIB patch"
open(p, "w", encoding="utf-8").write(s)
PYEOF

# the cmake trees are build-time only
RUN rm -rf build-hip build-vision

VOLUME ["/data"]
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=600s --retries=3 \
  CMD curl -fs "http://127.0.0.1:${PORT:-8080}/health" || exit 1

ENTRYPOINT ["./docker-entrypoint.sh"]
