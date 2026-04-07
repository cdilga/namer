# NAMER DOCKERFILE - CACHING BEST PRACTICES
# ==========================================
# 
# Layer ordering (most stable -> most frequently changing):
# 1. Base image (ubuntu:noble) - NEVER CHANGES
# 2. System packages (apt-get) - RARELY CHANGES
# 3. Build tools (node, golang, poetry) - RARELY CHANGES
# 4. Dependency files (pyproject.toml, package.json) - SOMETIMES CHANGES
# 5. Source code (COPY . .) - FREQUENTLY CHANGES
# 6. Build steps (poetry build, webpack) - FREQUENTLY CHANGES
#
# RULES TO PRESERVE CACHING:
# - NEVER put COPY . . before dependency installation
# - ALWAYS copy dependency files (package*.json, pyproject.toml) BEFORE source
# - ALWAYS put stable steps (apt-get) before unstable steps (build)
# - Use multi-stage builds to isolate cache-invalidating steps
#
# If you break caching, builds will take 5-10 minutes instead of 30 seconds.

# ── Stage 1: Frontend Build ───────────────────────────────────────────────────
FROM node:22-alpine AS frontend-build

WORKDIR /frontend

# Install build tools (stable layer)
RUN apk add --no-cache python3 make g++

# Copy dependency files FIRST (cached unless package files change)
COPY package.json pnpm-lock.yaml ./
COPY webpack.prod.js ./

# Install dependencies (cached unless package files change)
# Uses npm fallback since pnpm has EAGAIN issues on some filesystems
RUN npm install -g pnpm && \
    (pnpm install --frozen-lockfile || \
     (echo "pnpm failed, trying npm..." && rm -rf node_modules && npm install --legacy-peer-deps))

# Copy source LAST (only this invalidates when code changes)
COPY src/ ./src/

# Build frontend assets
RUN mkdir -p namer/web/public/assets && \
    (pnpm run build 2>/dev/null || npm run build)

# ── Stage 2: Videohashes Build ────────────────────────────────────────────────
FROM golang:1.22-alpine AS videohashes-build

WORKDIR /build
RUN apk add --no-cache make git

COPY videohashes/ ./
RUN make build

# ── Stage 3: Python Build ─────────────────────────────────────────────────────
FROM ubuntu:noble AS python-build

ENV PATH="/root/.local/bin:$PATH" TZ=UTC
ARG DEBIAN_FRONTEND=noninteractive

# System deps (stable layer - cached)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pip python3 pipx \
    build-essential libffi-dev libssl-dev python3-dev python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Poetry (stable layer - cached)
RUN pipx install poetry && pipx inject poetry poethepoet

WORKDIR /work

# Python deps FIRST (cached unless pyproject.toml/poetry.lock changes)
COPY pyproject.toml poetry.lock ./
RUN poetry install --no-interaction --no-root

# Copy source and built assets LAST (changes frequently)
COPY . .
COPY --from=frontend-build /frontend/namer/web/public/assets/ ./namer/web/public/assets/
COPY --from=videohashes-build /build/dist/ ./namer/tools/

# Build Python package
RUN poetry build --no-interaction

# ── Stage 4: Runtime ───────────────────────────────────────────────────────────
FROM ubuntu:noble

ENV PATH="/root/.local/bin:$PATH" TZ=UTC
ARG DEBIAN_FRONTEND=noninteractive

# Runtime deps (stable layer - cached)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pip python3 pipx tzdata curl gnupg \
    && rm -rf /var/lib/apt/lists/*

# jellyfin-ffmpeg (stable layer - cached, rarely changes)
ARG TARGETARCH
RUN curl -fsSL https://repo.jellyfin.org/ubuntu/jellyfin_team.gpg.key | \
    gpg --dearmor -o /usr/share/keyrings/jellyfin.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/jellyfin.gpg arch=${TARGETARCH}] https://repo.jellyfin.org/ubuntu noble main" \
    > /etc/apt/sources.list.d/jellyfin.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends jellyfin-ffmpeg7 && \
    rm -rf /var/lib/apt/lists/*

# Symlink jellyfin-ffmpeg onto PATH so the videohashes Go binary (and anything
# else that searches PATH) can locate ffmpeg/ffprobe without auto-downloading.
RUN ln -s /usr/lib/jellyfin-ffmpeg/ffmpeg /usr/local/bin/ffmpeg && \
    ln -s /usr/lib/jellyfin-ffmpeg/ffprobe /usr/local/bin/ffprobe

# Copy and install built package (changes when code changes)
COPY --from=python-build /work/dist/namer-*.tar.gz /
RUN pipx install /namer-*.tar.gz && rm /namer-*.tar.gz

# Verify all assets are in place
RUN ls -la /root/.local/share/pipx/venvs/namer/lib/python*/site-packages/namer/web/public/assets/ && \
    ls /root/.local/share/pipx/venvs/namer/lib/python*/site-packages/namer/tools/videohashes*

ENV PYTHONUNBUFFERED=1 \
    NAMER_CONFIG=/config/namer.cfg \
    NAMER_FFMPEG=/usr/lib/jellyfin-ffmpeg/ffmpeg \
    NAMER_WORKERS=0 \
    NAMER_MAX_FFMPEG_WORKERS=0 \
    NAMER_USE_GPU=0 \
    NVIDIA_DRIVER_CAPABILITIES=video,compute,utility

ARG BUILD_DATE
ARG GIT_HASH
LABEL build_date=$BUILD_DATE
LABEL git_hash=$GIT_HASH

EXPOSE 8080
HEALTHCHECK --interval=1m --timeout=30s CMD curl -sf http://localhost:8080/api/healthcheck >/dev/null || exit 1
ENTRYPOINT ["namer", "watchdog"]

# NOTE: CSS/JS assets (bundle.min.css, bundle.min.js) require webpack build.
# If styling is needed, run 'pnpm run build' before 'poetry build' and ensure
# namer/web/public/assets/ is included in the package.
