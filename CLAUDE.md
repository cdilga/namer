# namer — Dev Context

## What this project is

**namer** is a Python CLI + watchdog service that renames adult video files by matching them against [ThePornDatabase](https://www.theporndb.net/) metadata. It embeds tags in mp4s, runs a Flask web UI, and is deployed as a Docker container on TrueNAS Scale via SSH.

- **Python package**: `namer` (CLI entrypoint `python -m namer`)
- **Version**: see `pyproject.toml` → `[project].version`
- **Requires**: Python ≥ 3.11, `poetry` + `poethepoet` for dev
- **Frontend**: pnpm (Node 22), built by `poetry run poe build_deps`

## Deployment target — TrueNAS Scale via SSH

All production runs happen on a TrueNAS Scale host. The local dev machine connects via SSH alias `truenas`.

### Key scripts (in `truenas/`)

| Script | What it does |
|---|---|
| `truenas/build.sh` | rsyncs repo → TrueNAS, runs `docker build` there, produces `local/namer:latest` |
| `truenas/deploy.sh` | builds image, then calls `midclt call -j app.update` with full compose config (GPU + env vars) |
| `truenas/Dockerfile` | multi-stage build; runtime stage installs jellyfin-ffmpeg7 for CUDA support |

### How `deploy.sh` works

`app.update` (TrueNAS middleware) is the authoritative way to reconfigure a Custom App. It:
1. Writes the new `docker-compose.yaml` to `/mnt/.ix-apps/app_configs/namer-cli/versions/1.0.0/`
2. Runs `docker compose up --force-recreate --remove-orphans` in one shot
3. No separate `app.redeploy` needed

The compose config passed includes GPU `deploy.resources.reservations.devices` (same pattern as Jellyfin) and all env vars. This is how the GPU UUID gets wired into the container.

### TrueNAS app

- App name (TrueNAS Custom App): **`namer-cli`**
- Container name (after deploy): **`namer-manual`**
- Web UI exposed at: `http://truenas:20099/`
- Config file inside container: `/config/namer.cfg`
- Compose stored at: `/mnt/.ix-apps/app_configs/namer-cli/versions/1.0.0/user_config.yaml`

### SSH workflow

```bash
# SSH alias must resolve
ssh truenas "echo ok"

# Build + configure GPU + deploy in one step
./truenas/deploy.sh

# Tail logs
ssh truenas 'sudo docker logs -f namer-manual'

# Exec into container
ssh truenas 'sudo docker exec -it namer-manual bash'
```

Environment overrides: `TRUENAS_HOST`, `APP_NAME`, `NVIDIA_GPU_UUID`, `NAMER_WORKERS`, `NAMER_MAX_FFMPEG_WORKERS`, `NAMER_USE_GPU`.

## TrueNAS app environment variables

These must be set in **Apps > namer-cli > Edit > Environment Variables** in the TrueNAS UI:

| Variable | Value | Purpose |
|---|---|---|
| `NAMER_WORKERS` | `18` | Parallel file-processing workers |
| `NAMER_MAX_FFMPEG_WORKERS` | `4` | ffmpeg threads per file (phash screenshots) |
| `NAMER_USE_GPU` | `1` | Enable NVDEC GPU acceleration |
| `NAMER_FFMPEG` | `/usr/lib/jellyfin-ffmpeg/ffmpeg` | (set in Dockerfile, override if needed) |
| `NVIDIA_VISIBLE_DEVICES` | `GPU-26b96ba5-6a5b-b357-543c-c6602c3a4a80` | Pass the TrueNAS NVIDIA GPU through |
| `NVIDIA_DRIVER_CAPABILITIES` | `video,compute,utility` | (set in Dockerfile) |
| `NAMER_CONFIG` | `/config/namer.cfg` | Config path inside container |

Also enable **GPU passthrough** in the TrueNAS Custom App GUI (same GPU UUID as Jellyfin).

## Architecture notes

### Watchdog / worker threads

`namer/watchdog.py` — `MovieWatcher` runs:
- A `PollingObserver` watching `watch_dir` for new files
- **Multiple** worker threads (controlled by `NAMER_WORKERS` env var, defaults to `os.cpu_count()`)
- A background scheduler thread for retries / scheduled scans
- Optional Flask web server (`NamerWebServer`)

Deployed behaviour (local image `local/namer:latest`):
- Worker thread pool: controlled by `NAMER_WORKERS` env var (defaults to `os.cpu_count() or 4`)
- **Web UI starts immediately**: webserver starts before the initial directory scan; the scan runs in a background thread (`__initial_scan`)
- **work_dir recovery is async**: if work_dir is non-empty at startup (crash recovery), files are moved back to watch_dir inside `__initial_scan` so the web UI is not blocked
- Shutdown sends one `None` sentinel per worker; worker threads survive exceptions (try/except/finally in `__processing_thread`)
- `min_file_size = 100` MB (lowered from 300 to catch smaller SiteRip clips)

### GPU / jellyfin-ffmpeg

The Dockerfile installs **jellyfin-ffmpeg7** (`/usr/lib/jellyfin-ffmpeg/ffmpeg`) — the same CUDA-capable binary Jellyfin uses for hardware transcoding. It supports NVDEC for fast GPU-accelerated video decoding.

`NAMER_FFMPEG` env var selects the ffmpeg binary at startup (read in `FFMpeg.__init__`).
`NAMER_USE_GPU=1` enables CUDA hwaccel in screenshot extraction (`extract_screenshot`). Falls back to software per-file on unsupported codecs.

**Important:** The Dockerfile symlinks `/usr/lib/jellyfin-ffmpeg/ffmpeg` and `ffprobe` onto `/usr/local/bin/` so the `videohashes` Go binary (used for phash — `config.vph` = `StashVideoPerceptualHash`) can find them on PATH. Without this, phash calculation silently fails. `use_alt_phash_tool = False` means the Go binary is the *primary* phash tool; `True` uses the Python/ffmpeg fallback.

The NVIDIA GPU UUID on this TrueNAS host: `GPU-26b96ba5-6a5b-b357-543c-c6602c3a4a80`

### SQLite / requests cache

`namer/__main__.py` — `CachedSession` is initialised with WAL journal mode and `check_same_thread=False` to safely share the cache across multiple worker threads.

### File naming convention

Files must follow `STUDIO.[YY]YY.MM.DD.Scene.name.<ignored>.<ext>`. Periods in names are treated as any combination of spaces, dashes, or periods during matching.

### Directories (configured in `namer.cfg`)

| Key | Purpose |
|---|---|
| `watch_dir` | Drop new files here — watchdog picks them up |
| `work_dir` | Temp processing location |
| `failed_dir` | Files that didn't match — retried every 24 h |
| `dest_dir` | Final renamed + tagged files |

**Current on TrueNAS:** `dest_dir = /config/done` → `/mnt/vessel/wtd/tz/done/` (inside Jellyfin's library tree at `/media/wtd/tz/`). `ignored_dir_regex = .*_UNPACK_.*|^done` prevents the watchdog re-processing already-renamed files.

### Jellyfin integration

- **Jellyfin container:** `ix-jellyfin-wtd-new-jellyfin-1` (port 30090)
- **Jellyfin DB:** `/mnt/.ix-apps/app_mounts/jellyfin-wtd-new/config/data/jellyfin.db`
- **Media root:** host `/mnt/vessel/wtd/` → Jellyfin `/media/wtd/`
- **Library root:** `/media/wtd/tz/` (Jellyfin scans here recursively)
- **Remap script:** `truenas/jellyfin_remap.py` — backs up Jellyfin DB, maps old paths → new renamed paths using namer's `_namer.json.gz` logs; preserves all UserData (favourites, playcount) since it only updates `BaseItems.Path`
- **~22k stale entries** in Jellyfin from files that moved through the pipeline (indexed at tz/, namer-work/, failed/ paths that no longer exist)
- Jellyfin DB backup dir: `/mnt/vessel/wtd/namer-config/jellyfin-db-backups/`
- **Golden pre-remap backup**: `jellyfin_PRE_REMAP_GOLDEN.db` in that dir — 141 MB, 29,306 rows, taken before any remap run. Script also auto-creates a timestamped backup at the start of every run (they accumulate, never overwrite).
- **Run the remap**: `ssh truenas "sudo python3 /tmp/jellyfin_remap.py"` — copy script first with `scp truenas/jellyfin_remap.py truenas:/tmp/`. Use `--dry-run` to preview. After running, trigger a Jellyfin library scan to pick up path changes. Script is idempotent.

## Dev setup

```bash
# Install deps (Python + frontend)
poetry install
poetry run poe build_deps   # compiles JS assets + videohashes Go binary

# Run locally
poetry run python -m namer watchdog

# Lint
poetry run ruff check .

# Tests
poetry run pytest
```

## Release

1. Bump `version` in `pyproject.toml`
2. Run `./release.sh` (tags + pushes)
3. On TrueNAS: `./truenas/deploy.sh`

## CASS search tips

This workspace is at `/Users/cdilga/Documents/dev/namer`. To find prior sessions:

```bash
cass search "namer" --workspace /Users/cdilga/Documents/dev/namer --robot-format toon --limit 15 2>/dev/null
cass search "truenas deploy" --robot-format toon --limit 10 2>/dev/null
```
