# syntax=docker/dockerfile:1
#
# PolyStrata's container path for a strata-poly model: Tiel Coder 35B-A3B on the
# laptop's RTX 5070 8GB (family tiel, architecture qwen35moe).
#
# Upstream's own Dockerfile compiles only the Qwen `strata` engine, and its header
# scopes the container to Qwen3.8. Upstream's docker-entrypoint.sh accepts FAMILY=tiel
# and expects the engine to be in the image, so the container path for poly families
# needs this one extension: compile `strata-poly` + `strata-vision` at build time with
# setup.py's own build helpers, using the exact cmake definitions setup.py uses natively
# on Linux (build_engine_poly). The result is what get_poly_prebuilt / build_engine_poly
# look for, so the first container start finds engine-poly/ current (the BUILD.json
# source-hash check passes), skips the compile, and goes straight to loading the model.
#
# No `strata` engine is built here: the tiel family never calls it, and skipping it
# halves the build. The image is engine-poly + the entrypoint, nothing else.
#
# The encoder is built with CUDA off, which is setup.py's `--vision cpu` arm: setup
# puts the image encoder on the CPU below 16 GB VRAM, and this card is 8 GB. A CUDA-built
# encoder also runs on the CPU, so building it with CUDA ON is the valid alternative on
# a bigger card.
#
# Build (the strata_laptop service in ai/llama-cpp.yml does this with CUDA_ARCHITECTURES=120):
#   podman build -f polystrata.Dockerfile PolyStrata --build-arg CUDA_ARCHITECTURES=120
#
# Run: the service below ai/llama-cpp.yml. Setup choices (FAMILY, MODEL, CONTEXT, VISION,
# GGUF_DIR, ...) are env vars read by upstream's unmodified docker-entrypoint.sh.
# The container needs --ulimit memlock=-1: strata-poly pins its RAM working set with
# cudaHostRegister, like the desktop engine.

FROM nvidia/cuda:13.0.0-devel-ubuntu24.04

# STRATA_EXECV=1: setup.py replaces itself with the server, so the server is PID 1 and
# docker stop's SIGTERM reaches it (same as upstream).
ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 LANG=C.UTF-8 STRATA_EXECV=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git libatomic1 libgomp1 \
        python3 python3-pip python3-venv unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/strata
COPY . .

# RTX 50 (120) only: the laptop card is Blackwell. setup.py's build takes
# semicolon-separated archs; CMakeLists refuses anything below 75.
ARG CUDA_ARCHITECTURES=120

RUN python3 -m venv .venv \
    && .venv/bin/pip install --no-cache-dir --upgrade pip \
    && .venv/bin/pip install --no-cache-dir -r requirements.txt \
    && chmod +x setup.sh docker-entrypoint.sh

# llama.cpp at the pinned commit, then strata-poly and the CPU image encoder, built
# exactly the way setup.py builds them on Linux. BUILD.json is what setup.py reads to
# decide whether an engine is current: source=local with a matching src hash, the card
# in archs, toolkit 13, and a vision_src match for the encoder means the first start
# reuses it instead of recompiling.
RUN .venv/bin/python - <<'PYEOF'
import json, os, pathlib, shutil
import setup

llama = setup.get_llama_cpp()
nvcc, _ = setup.find_nvcc()
arch = os.environ.get("CUDA_ARCHITECTURES", "120").strip().strip('"').replace(",", ";")
archs = [int(a.split("-")[0]) for a in arch.split(";") if a.split("-")[0].isdigit()]
cuda_archs = ";".join(str(a) for a in archs)

eng = setup.ROOT / setup.ENGINE_POLY_DIR
eng.mkdir(exist_ok=True)
setup.cmake_build(setup.ROOT, setup.ROOT / "build-poly", "strata-poly",
    ["-DSTRATA_ENABLE_CUDA=ON", "-DSTRATA_BUILD_TESTS=OFF",
     f"-DCMAKE_CUDA_ARCHITECTURES={cuda_archs}", f"-DCMAKE_CUDA_COMPILER={nvcc}",
     f"-DSTRATA_GGML_DIR={llama}"], None, "build-strata-poly.bat")
shutil.copy2(setup.ROOT / "build-poly" / setup.POLY_EXE, eng / setup.POLY_EXE)

# the image encoder, built for the CPU path (setup.py's "cpu" arm: no CUDA defs at all)
setup.cmake_build(setup.ROOT / "tools" / "vision", setup.ROOT / "build-vision-poly", "strata-vision",
    [f"-DLLAMA_DIR={setup.get_llama_cpp(vision=True)}", "-DSTRATA_VISION_CUDA=OFF"],
    None, "build-vision-poly.bat")
shutil.copy2(setup.ROOT / "build-vision-poly" / "bin" / setup.VEXE, eng / setup.VEXE)

# the toolkit's own libraries (bin, bin/x64, lib64) - what build_engine_poly records as
# cuda_dirs, and what poly_setup turns into the config's lib_dirs at first start
bindir = pathlib.Path(nvcc).parent
dirs = [str(x) for x in (bindir, bindir / "x64", bindir.parent / "lib64") if x.is_dir()]
(eng / "BUILD.json").write_text(json.dumps({"source": "local", "version": setup.source_version(),
    "archs": archs, "cuda_dirs": dirs, "toolkit": 13, "src": setup.source_hash(setup.ENGINE_SOURCES),
    "vision": "cpu", "vision_src": setup.source_hash(setup.VISION_SOURCES)}, indent=1))
PYEOF

# the cmake trees are build-time only; the engine, the encoder and BUILD.json are what the
# container needs. third_party/llama.cpp stays: setup.py's own download check finds it and
# does not re-download on the first start.
RUN rm -rf build-poly build-vision-poly third_party/*.zip

VOLUME ["/data"]
EXPOSE 8080

# /health is answered before the API key gate, so it works with or without one. The port
# only opens after the model loads (minutes on the first setup pass), so the start period
# is generous: a too short one marks a still-loading container unhealthy and the restart
# policy would kill it mid-setup.
HEALTHCHECK --interval=30s --timeout=5s --start-period=600s --retries=3 \
  CMD curl -fs "http://127.0.0.1:${PORT:-8080}/health" || exit 1

ENTRYPOINT ["./docker-entrypoint.sh"]
