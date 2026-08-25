# syntax=docker/dockerfile:1.7
#
# agention-llama — Vulkan container images for the ROCmFPx + DFlash2 llama.cpp fork.
#
# The fork's source arrives as the BuildKit named context `llamasrc`, so this
# repo never has to live inside the fork tree and the fork stays clean for
# upstream PRs:
#
#   docker buildx build --build-context llamasrc=../llama.cpp \
#       --target server -t agention-llama:server -f docker/Dockerfile .
#
# scripts/build.sh wraps that with provenance labels. Targets:
#
#   server    llama-server + embedded web UI   (the default)
#   cli       llama / llama-cli / llama-bench
#   dist      portable Linux x86_64 tarball, exported with --output type=local
#
ARG UBUNTU_VERSION=26.04
ARG NODE_VERSION=24

# --------------------------------------------------------------------- web UI
# Built from source rather than fetched from the Hugging Face bucket: that
# bucket holds mainline's UI, and a build should not depend on the network
# resolving to the right version of someone else's asset.
FROM docker.io/node:${NODE_VERSION} AS web

ARG APP_VERSION=0
WORKDIR /ui

COPY --from=llamasrc tools/ui/package.json tools/ui/package-lock.json ./
RUN npm ci

COPY --from=llamasrc tools/ui/ ./
RUN LLAMA_BUILD_NUMBER="${APP_VERSION}" npm run build

# ----------------------------------------------------------------------- build
FROM docker.io/ubuntu:${UBUNTU_VERSION} AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates \
        libssl-dev libvulkan-dev glslc spirv-headers \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# The fork's own .dockerignore applies to this context, so build*/ and models/
# stay out of the transfer. .git comes along on purpose: cmake reads the build
# number and commit from it.
COPY --from=llamasrc . .
COPY --from=web /ui/dist tools/ui/dist

# GGML_NATIVE=OFF + CPU_ALL_VARIANTS: the image must run on any x86-64, with the
# CPU variant picked at load time. BACKEND_DL keeps the Vulkan backend a dlopened
# .so, so a machine with no Vulkan ICD still starts (on CPU) instead of failing
# to link.
ARG EXTRA_CMAKE_ARGS=""
RUN cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_VULKAN=ON \
        -DGGML_NATIVE=OFF \
        -DGGML_BACKEND_DL=ON \
        -DGGML_CPU_ALL_VARIANTS=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_UI=ON \
        -DLLAMA_USE_PREBUILT_UI=OFF \
        ${EXTRA_CMAKE_ARGS} \
    && cmake --build build --config Release -j"$(nproc)"

# Flat layout: binaries and their .so files in one directory, which is what the
# $ORIGIN rpath expects.
RUN set -eu; \
    mkdir -p /out; \
    find build -name '*.so*' -exec cp -P {} /out \; ; \
    for b in llama llama-cli llama-server llama-bench llama-quantize; do \
        cp "build/bin/$b" /out/; \
    done

# ------------------------------------------------------------------------ base
FROM docker.io/ubuntu:${UBUNTU_VERSION} AS base

ARG BUILD_DATE=unknown
ARG LLAMA_COMMIT=unknown
ARG LLAMA_BRANCH=unknown
ARG APP_VERSION=0

LABEL org.opencontainers.image.title="agention-llama" \
      org.opencontainers.image.description="Vulkan llama.cpp fork for AMD Strix Halo — ROCmFPx quants, DFlash2/MTP speculative decoding" \
      org.opencontainers.image.source="https://github.com/LaurentZuijdwijk/llama.cpp" \
      org.opencontainers.image.revision="${LLAMA_COMMIT}" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}"

RUN apt-get update && apt-get install -y --no-install-recommends \
        libgomp1 libvulkan1 mesa-vulkan-drivers vulkan-tools curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# The fork's LDS stride fix (+12-14% prefill) turns itself on only for
# RADV >= 25.3 — see ggml_vk_coopmat_shmem_pad(). In a container it is the
# IMAGE's Mesa that decides, not the host's, so an older base would silently
# ship the slow path. Fail the build instead.
RUN set -eu; \
    v="$(dpkg-query -W -f='${Version}' mesa-vulkan-drivers)"; v="${v#*:}"; \
    maj="${v%%.*}"; rest="${v#*.}"; min="${rest%%.*}"; \
    if [ "$maj" -lt 25 ] || { [ "$maj" -eq 25 ] && [ "$min" -lt 3 ]; }; then \
        echo "FATAL: image ships Mesa $v; the fork's LDS pad fix needs RADV >= 25.3." >&2; \
        echo "       Pick a newer UBUNTU_VERSION or add a Mesa PPA." >&2; \
        exit 1; \
    fi; \
    echo "mesa-vulkan-drivers $v — RADV >= 25.3, LDS pad fix will engage"

COPY --from=build /out /app
COPY scripts/doctor.sh /app/doctor.sh
COPY docker/entrypoint.sh /app/entrypoint.sh

RUN set -eu; \
    printf 'commit=%s\nbranch=%s\nbuilt=%s\nversion=%s\n' \
        "${LLAMA_COMMIT}" "${LLAMA_BRANCH}" "${BUILD_DATE}" "${APP_VERSION}" > /app/BUILD_INFO

ENV PATH="/app:${PATH}" \
    LD_LIBRARY_PATH="/app" \
    LLAMA_CACHE="/models/.cache"

WORKDIR /app
VOLUME ["/models"]

# ---------------------------------------------------------------------- server
FROM base AS server

# With no model argument the server comes up in router mode over /models, so the
# web UI can list and load whatever is mounted instead of the container exiting.
ENV LLAMA_ARG_HOST=0.0.0.0 \
    LLAMA_ARG_PORT=8080 \
    LLAMA_ARG_MODELS_DIR=/models \
    AGENTION_BINARY=/app/llama-server

EXPOSE 8080

# Loading a 27B model over the first prompt takes a while; don't mark unhealthy
# during it.
HEALTHCHECK --start-period=300s --interval=30s --timeout=5s --retries=3 \
    CMD curl -fsS http://localhost:8080/health || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]

# ------------------------------------------------------------------------- cli
FROM base AS cli

ENV AGENTION_BINARY=/app/llama

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["cli"]

# ------------------------------------------------------- portable Linux binaries
# Built on 22.04 (glibc 2.35) with the LunarG SDK, mirroring what upstream's
# release workflow does for its x64 Vulkan tarball. The runtime image can be
# modern because it ships its own Mesa; a tarball cannot, so it is built against
# the oldest glibc that still compiles the tree.
FROM docker.io/ubuntu:22.04 AS portable-build

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates wget gnupg libssl-dev \
    && wget -qO /etc/apt/trusted.gpg.d/lunarg.asc https://packages.lunarg.com/lunarg-signing-key-pub.asc \
    && wget -qO /etc/apt/sources.list.d/lunarg-vulkan-jammy.list https://packages.lunarg.com/vulkan/lunarg-vulkan-jammy.list \
    && apt-get update && apt-get install -y --no-install-recommends vulkan-sdk \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=llamasrc . .
COPY --from=web /ui/dist tools/ui/dist

ARG EXTRA_CMAKE_ARGS=""
RUN cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_VULKAN=ON \
        -DGGML_NATIVE=OFF \
        -DGGML_BACKEND_DL=ON \
        -DGGML_CPU_ALL_VARIANTS=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_UI=ON \
        -DLLAMA_USE_PREBUILT_UI=OFF \
        ${EXTRA_CMAKE_ARGS} \
    && cmake --build build --config Release -j"$(nproc)"

ARG APP_VERSION=0
ARG LLAMA_COMMIT=unknown
ARG LLAMA_BRANCH=unknown
ARG BUILD_DATE=unknown

COPY scripts/doctor.sh /src-tooling/doctor.sh
COPY scripts/install-binaries.sh /src-tooling/install.sh

RUN set -eu; \
    name="agention-llama-${APP_VERSION}-vulkan-linux-x64"; \
    mkdir -p "/pack/${name}" /dist; \
    find build -name '*.so*' -exec cp -P {} "/pack/${name}/" \; ; \
    for b in llama llama-cli llama-server llama-bench llama-quantize; do \
        cp "build/bin/$b" "/pack/${name}/"; \
    done; \
    cp /src-tooling/doctor.sh "/pack/${name}/doctor.sh"; \
    cp /src-tooling/install.sh "/pack/${name}/install.sh"; \
    printf 'commit=%s\nbranch=%s\nbuilt=%s\nversion=%s\nglibc=%s\n' \
        "${LLAMA_COMMIT}" "${LLAMA_BRANCH}" "${BUILD_DATE}" "${APP_VERSION}" \
        "$(ldd --version | head -1)" > "/pack/${name}/BUILD_INFO"; \
    tar -C /pack -czf "/dist/${name}.tar.gz" "${name}"; \
    cd /dist && sha256sum "${name}.tar.gz" > "${name}.tar.gz.sha256"

FROM scratch AS dist
COPY --from=portable-build /dist/ /
