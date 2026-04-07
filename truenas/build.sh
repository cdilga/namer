#!/bin/bash
# Build the namer Docker image on TrueNAS via SSH (no git remote needed).
# rsync → docker build on host → image available as local/namer:latest
set -euo pipefail

TRUENAS_HOST="${TRUENAS_HOST:-truenas}"
IMAGE_NAME="local/namer"
IMAGE_TAG="${IMAGE_TAG:-latest}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Build namer image on TrueNAS ==="
echo "Host : $TRUENAS_HOST"
echo "Image: $IMAGE_NAME:$IMAGE_TAG"
echo ""

# Skip build if requested (e.g. image was built locally and loaded)
if [ "${SKIP_BUILD:-0}" = "1" ]; then
    echo "[skip] SKIP_BUILD=1 — using existing image"
    exit 0
fi

# Verify SSH
if ! ssh -o ConnectTimeout=5 "$TRUENAS_HOST" "echo ok" >/dev/null 2>&1; then
    echo "ERROR: Cannot reach $TRUENAS_HOST via SSH"
    exit 1
fi
echo "[ok] SSH connected"

# Ensure submodules are present
cd "$PROJECT_ROOT"
git submodule update --init --recursive

BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
GIT_HASH=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

REMOTE_DIR="/tmp/namer-build-$$"
ssh "$TRUENAS_HOST" "mkdir -p $REMOTE_DIR"

echo "Syncing project files..."
rsync -az --delete \
    --exclude='.git' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='.venv' \
    --exclude='venv' \
    --exclude='.DS_Store' \
    --exclude='*.log' \
    --exclude='dist' \
    --exclude='node_modules' \
    "$PROJECT_ROOT/" "$TRUENAS_HOST:$REMOTE_DIR/"

echo "Building image on TrueNAS (this takes a few minutes)..."
ssh "$TRUENAS_HOST" "cd $REMOTE_DIR && sudo docker build \
    -f truenas/Dockerfile \
    --build-arg BUILD_DATE='$BUILD_DATE' \
    --build-arg GIT_HASH='$GIT_HASH' \
    -t $IMAGE_NAME:$IMAGE_TAG \
    . 2>&1"

echo "Cleaning up remote build files..."
ssh "$TRUENAS_HOST" "rm -rf $REMOTE_DIR"

echo ""
echo "=== Image built: $IMAGE_NAME:$IMAGE_TAG ==="
echo ""
echo "Next: run ./truenas/deploy.sh to restart the TrueNAS app with the new image."
