#!/usr/bin/env python3
"""
jellyfin_remap.py — Update Jellyfin DB paths after namer renames files.

Backs up the Jellyfin SQLite DB, then remaps BaseItems.Path entries whose
files no longer exist on disk to their new namer-renamed paths.  All
UserData (favourites, playcount, playback position) is preserved because
it is keyed by ItemId, not Path.

Run on the TrueNAS host (not inside a container):
    python3 jellyfin_remap.py [--dry-run] [--verbose]

Always backs up the DB at the start of every run before touching anything.
"""

import argparse
import gzip
import json
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

# ── Config ────────────────────────────────────────────────────────────────────

JELLYFIN_DB   = "/mnt/.ix-apps/app_mounts/jellyfin-wtd-new/config/data/jellyfin.db"
NAMER_DONE_DIRS = [
    "/mnt/vessel/wtd/tz/done",           # post-deploy: done/ is inside Jellyfin's tz/ library
    "/mnt/vessel/wtd/namer-config/done", # pre-deploy fallback: old location
]
BACKUP_DIR    = "/mnt/vessel/wtd/namer-config/jellyfin-db-backups"

# How Jellyfin sees the media root vs how the host sees it.
JELLYFIN_ROOT = "/media/wtd"
HOST_ROOT     = "/mnt/vessel/wtd"

VIDEO_EXTS = {".mp4", ".mkv", ".avi", ".mov", ".flv"}

# ── Path helpers ──────────────────────────────────────────────────────────────

def to_host(jellyfin_path: str) -> Path:
    return Path(jellyfin_path.replace(JELLYFIN_ROOT, HOST_ROOT, 1))

def to_jellyfin(host_path: Path) -> str:
    return str(host_path).replace(HOST_ROOT, JELLYFIN_ROOT, 1)

# ── DB backup ─────────────────────────────────────────────────────────────────

def backup_db() -> Path:
    Path(BACKUP_DIR).mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup = Path(BACKUP_DIR) / f"jellyfin_{ts}.db"
    # Use SQLite's online backup API so WAL is checkpointed cleanly
    src = sqlite3.connect(JELLYFIN_DB)
    dst = sqlite3.connect(str(backup))
    src.backup(dst)
    dst.close()
    src.close()
    print(f"[backup] Saved DB → {backup}  ({backup.stat().st_size // 1024 // 1024} MB)")
    return backup

# ── Mapping builder ───────────────────────────────────────────────────────────

def _read_source_stem(gz_path: Path) -> str | None:
    """Extract the original source file stem from a namer _namer.json.gz log."""
    try:
        with gzip.open(gz_path, 'rt', encoding='utf-8') as f:
            data = json.load(f)
        results = data.get("results", [])
        if not results:
            return None
        # name_parts may be null in JSON (phash-only match with no parsed name)
        name_parts = results[0].get("name_parts") or {}
        source_name = name_parts.get("source_file_name", "")
        if not source_name:
            return None
        return Path(source_name).stem
    except Exception:
        return None

def build_mapping(done_dirs: list[str]) -> dict[str, str]:
    """
    Returns {source_stem: new_jellyfin_path} for every successfully renamed file.
    Scans all *_namer.json.gz files across all done_dirs and looks for matching video files.
    """
    mapping: dict[str, str] = {}

    for done_dir in done_dirs:
        done_path = Path(done_dir)
        if not done_path.is_dir():
            continue
        print(f"[map] Scanning {done_dir}")

        for gz in done_path.rglob("*_namer.json.gz"):
            source_stem = _read_source_stem(gz)
            if not source_stem:
                continue

            new_stem = gz.name[: -len("_namer.json.gz")]
            for ext in VIDEO_EXTS:
                candidate = gz.parent / f"{new_stem}{ext}"
                if candidate.exists():
                    mapping[source_stem] = to_jellyfin(candidate)
                    break

    return mapping

# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run",  action="store_true", help="Report changes without writing to DB")
    parser.add_argument("--verbose",  action="store_true", help="Print every skipped / matched item")
    args = parser.parse_args()

    # 1. Backup first — always
    backup_db()

    # 2. Build old-stem → new-jellyfin-path mapping from namer logs
    print("\n[map] Scanning namer done dirs")
    mapping = build_mapping(NAMER_DONE_DIRS)
    print(f"[map] {len(mapping)} source→new mappings found")

    if not mapping:
        print("[map] Nothing to do — no namer logs found in done dir.")
        return

    # 3. Open DB and scan for missing-file items
    conn = sqlite3.connect(JELLYFIN_DB)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    cur.execute(
        "SELECT Id, Path FROM BaseItems "
        "WHERE IsFolder=0 AND Path IS NOT NULL AND Path LIKE ?",
        (f"{JELLYFIN_ROOT}/%",)
    )
    rows = cur.fetchall()
    print(f"\n[scan] {len(rows)} media items in Jellyfin under {JELLYFIN_ROOT}")

    updated = []
    missing_no_map = []

    for row in rows:
        item_id, jf_path = row["Id"], row["Path"]
        host_path = to_host(jf_path)

        if host_path.exists():
            continue  # File is fine

        # File is missing on disk — look it up in the mapping
        stem = host_path.stem
        new_jf_path = mapping.get(stem)

        if new_jf_path:
            updated.append((item_id, jf_path, new_jf_path))
            if args.verbose:
                print(f"  REMAP  {jf_path}\n      →  {new_jf_path}")
        else:
            missing_no_map.append(jf_path)
            if args.verbose:
                print(f"  MISS   {jf_path}")

    # 4. Apply updates
    print(f"\n[result] {len(updated)} items can be remapped")
    print(f"[result] {len(missing_no_map)} missing items have no mapping (not yet renamed, or not in TPDB)")

    if updated and not args.dry_run:
        try:
            conn.execute("BEGIN IMMEDIATE")
            for item_id, old_path, new_path in updated:
                cur.execute("UPDATE BaseItems SET Path=? WHERE Id=?", (new_path, item_id))
            conn.commit()
            print(f"[db] Committed {len(updated)} path updates")
        except Exception as e:
            conn.rollback()
            print(f"[db] ERROR — rolled back all changes: {e}", file=sys.stderr)
            sys.exit(1)
    elif updated and args.dry_run:
        print("[db] Dry run — no changes written")

    conn.close()

    # 5. Summary
    print("\n── Summary " + "─" * 50)
    print(f"  DB backup:           {BACKUP_DIR}")
    print(f"  Mappings available:  {len(mapping)}")
    print(f"  Items remapped:      {len(updated)}")
    print(f"  Still missing:       {len(missing_no_map)}")

    if missing_no_map and args.verbose:
        print("\nStill-missing items (no mapping found):")
        for p in missing_no_map[:50]:
            print(f"  {p}")
        if len(missing_no_map) > 50:
            print(f"  ... and {len(missing_no_map) - 50} more")


if __name__ == "__main__":
    main()
