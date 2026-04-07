#!/bin/bash
# Build and deploy namer on TrueNAS via app.update (Custom App).
# app.update writes the new compose config AND does a force-recreate in one shot.
set -euo pipefail

TRUENAS_HOST="${TRUENAS_HOST:-truenas}"
APP_NAME="${APP_NAME:-namer-cli}"
IMAGE_NAME="local/namer"
IMAGE_TAG="${IMAGE_TAG:-latest}"
MAX_WAIT=180

# NVIDIA GPU UUID — same device used by Jellyfin on this host.
# Override via: NVIDIA_GPU_UUID=GPU-xxxx ./deploy.sh
NVIDIA_GPU_UUID="${NVIDIA_GPU_UUID:-GPU-26b96ba5-6a5b-b357-543c-c6602c3a4a80}"

# Worker tuning — tweak here if needed.
NAMER_WORKERS="${NAMER_WORKERS:-18}"
NAMER_MAX_FFMPEG_WORKERS="${NAMER_MAX_FFMPEG_WORKERS:-4}"
NAMER_USE_GPU="${NAMER_USE_GPU:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Deploy namer to TrueNAS ==="
echo "Host : $TRUENAS_HOST  App: $APP_NAME  Image: $IMAGE_NAME:$IMAGE_TAG"
echo ""

# ── Step 1: Build ──────────────────────────────────────────────────────────────
"$SCRIPT_DIR/build.sh"

IMAGE_ID=$(ssh "$TRUENAS_HOST" "sudo docker images -q $IMAGE_NAME:$IMAGE_TAG 2>/dev/null" | head -1)
if [ -z "$IMAGE_ID" ]; then
    echo "ERROR: Image $IMAGE_NAME:$IMAGE_TAG not found after build"
    exit 1
fi
echo "[ok] Image built: $IMAGE_ID"
echo ""

# ── Step 2: Verify app exists ──────────────────────────────────────────────────
if ! ssh "$TRUENAS_HOST" "sudo midclt call app.query 2>/dev/null | python3 -c \
    \"import sys,json; apps=json.load(sys.stdin); \
    exit(0 if any(a['name']=='$APP_NAME' for a in apps) else 1)\""; then
    echo "ERROR: TrueNAS app '$APP_NAME' not found."
    echo "Create it once via UI: Apps > Discover > Custom App, name=$APP_NAME"
    exit 1
fi
echo "[ok] App '$APP_NAME' found"
echo ""

# ── Step 3: Check GPU access ───────────────────────────────────────────────────
echo "Checking GPU accessibility..."
if ssh "$TRUENAS_HOST" \
    "sudo docker run --rm --gpus device=$NVIDIA_GPU_UUID \
     ubuntu:noble nvidia-smi -L 2>/dev/null | grep -q GPU"; then
    echo "[ok] NVIDIA GPU $NVIDIA_GPU_UUID accessible"
else
    echo "[warn] GPU check failed — continuing without GPU validation"
    echo "       If GPU acceleration is wanted, ensure nvidia-container-toolkit is"
    echo "       installed on TrueNAS and the GPU UUID is correct."
fi
echo ""

# ── Step 4: Wait for app to reach a stable state ──────────────────────────────
# app.update acquires a job lock; calling it while DEPLOYING is safe but let's
# wait for any in-progress compose action to settle first.
echo "Waiting for app to reach stable state..."
STABLE_WAIT=60
SECONDS=0
while [ $SECONDS -lt $STABLE_WAIT ]; do
    APP_STATE=$(ssh "$TRUENAS_HOST" "sudo midclt call app.query 2>/dev/null | python3 -c \
        \"import sys,json; apps=json.load(sys.stdin); \
        print(next((a['state'] for a in apps if a['name']=='$APP_NAME'), 'UNKNOWN'))\"" 2>/dev/null || echo "UNKNOWN")
    if [[ "$APP_STATE" == "RUNNING" || "$APP_STATE" == "STOPPED" || "$APP_STATE" == "CRASHED" ]]; then
        echo "[ok] App state: $APP_STATE"
        break
    fi
    echo -n "  (state: $APP_STATE) ."
    sleep 5
done
echo ""

# ── Step 5: app.update — new compose config + force-recreate ──────────────────
# app.update for custom apps accepts custom_compose_config (JSON object).
# It writes the config to disk and then runs 'docker compose up --force-recreate'.
echo "Pushing new compose config via app.update..."

NEW_COMPOSE=$(python3 -c "
import json, sys
cfg = {
    'services': {
        'namer': {
            'container_name': 'namer-manual',
            'image': '$IMAGE_NAME:$IMAGE_TAG',
            'restart': 'unless-stopped',
            'environment': {
                'NAMER_CONFIG':           '/config/namer.cfg',
                'NAMER_WORKERS':          '$NAMER_WORKERS',
                'NAMER_MAX_FFMPEG_WORKERS': '$NAMER_MAX_FFMPEG_WORKERS',
                'NAMER_USE_GPU':          '$NAMER_USE_GPU',
                'NVIDIA_VISIBLE_DEVICES': '$NVIDIA_GPU_UUID',
                'NVIDIA_DRIVER_CAPABILITIES': 'video,compute,utility',
                'PGID': '3000',
                'PUID': '3000',
                'TZ': 'UTC',
            },
            'ports': ['20099:8080'],
            'volumes': [
                '/mnt/vessel/wtd/tz:/data:rw',
                '/mnt/vessel/wtd/namer-config:/config:rw',
                '/mnt/vessel/wtd/namer-work:/config/work:rw',
                '/mnt/vessel/wtd/tz/done:/config/done:rw',
            ],
            'deploy': {
                'resources': {
                    'reservations': {
                        'devices': [{
                            'capabilities': ['gpu'],
                            'device_ids':   ['$NVIDIA_GPU_UUID'],
                            'driver':       'nvidia',
                        }]
                    }
                }
            },
        }
    },
    'version': '3.8',
}
print(json.dumps({'custom_compose_config': cfg}))
")

# -j waits for the job to complete (app.update is a long-running job)
JOB_RESULT=$(ssh "$TRUENAS_HOST" "sudo midclt call -j app.update '$APP_NAME' '$NEW_COMPOSE'" 2>&1)
echo "[ok] app.update job completed"
echo "$JOB_RESULT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('  state :', d.get('state'))
    containers = d.get('active_workloads', {}).get('containers', '?')
    print('  containers :', containers)
except Exception:
    pass
" 2>/dev/null || true
echo ""

# ── Step 6: Wait for container to be running ───────────────────────────────────
echo "Waiting for container to be running (max ${MAX_WAIT}s)..."
SECONDS=0
while [ $SECONDS -lt $MAX_WAIT ]; do
    STATUS=$(ssh "$TRUENAS_HOST" \
        "sudo docker ps --filter name=namer-manual --filter status=running --format '{{.Status}}'" \
        2>/dev/null | head -1)
    if [ -n "$STATUS" ]; then
        echo "[ok] Container running: $STATUS"
        break
    fi
    echo -n "."
    sleep 3
done
echo ""
if [ $SECONDS -ge $MAX_WAIT ]; then
    echo "WARN: Timed out — check logs: ssh $TRUENAS_HOST 'sudo docker logs namer-manual'"
fi

# ── Step 7: Verify env and GPU inside the container ───────────────────────────
echo "Verifying container environment..."
WORKERS_LIVE=$(ssh "$TRUENAS_HOST" \
    "sudo docker exec namer-manual printenv NAMER_WORKERS 2>/dev/null" || echo "?")
GPU_LIVE=$(ssh "$TRUENAS_HOST" \
    "sudo docker exec namer-manual printenv NAMER_USE_GPU 2>/dev/null" || echo "?")
FFMPEG_LIVE=$(ssh "$TRUENAS_HOST" \
    "sudo docker exec namer-manual printenv NAMER_FFMPEG 2>/dev/null" || echo "(from Dockerfile)")
GPU_DRIVER=$(ssh "$TRUENAS_HOST" \
    "sudo docker exec namer-manual nvidia-smi -L 2>/dev/null | head -1" || echo "(no nvidia-smi in container)")
FFMPEG_VER=$(ssh "$TRUENAS_HOST" \
    "sudo docker exec namer-manual /usr/lib/jellyfin-ffmpeg/ffmpeg -version 2>&1 | head -1" || echo "?")

echo ""
echo "=== Deployment complete ==="
echo "Container         : namer-manual"
echo "Image             : $IMAGE_NAME:$IMAGE_TAG ($IMAGE_ID)"
echo "NAMER_WORKERS     : $WORKERS_LIVE"
echo "NAMER_USE_GPU     : $GPU_LIVE"
echo "NAMER_FFMPEG      : $FFMPEG_LIVE"
echo "jellyfin-ffmpeg   : $FFMPEG_VER"
echo "GPU in container  : $GPU_DRIVER"
echo "Web UI            : http://$TRUENAS_HOST:20099/"
echo ""
echo "Logs  : ssh $TRUENAS_HOST 'sudo docker logs -f namer-manual'"
echo "Shell : ssh $TRUENAS_HOST 'sudo docker exec -it namer-manual bash'"
