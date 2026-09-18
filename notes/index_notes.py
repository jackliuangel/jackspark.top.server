#!/usr/bin/env python3
"""Build or refresh a local SQLite index of iCloud Notes.

Usage:
  index_notes.py              Full sync (first run) or incremental refresh
  index_notes.py --status     Show index stats without syncing

Reuses the existing iCloud session (credentials from ~/.config/icloud_upload.conf,
cookie session from ~/.config/icloud_upload_session). If the session expired, a
2FA code is needed: run with the code as argv[1].
"""
import argparse
import os
import sqlite3
import sys
import time

NOTES_DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(NOTES_DIR, "index.db")

conf = os.path.expanduser("~/.config/icloud_upload.conf")
if os.path.exists(conf):
    with open(conf) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))

sys.path.insert(0, os.path.join(os.path.dirname(NOTES_DIR), "ytdl"))
from icloud_upload import SmsOnlyPyiCloudService  # noqa: E402


def get_db():
    db = sqlite3.connect(DB_PATH)
    db.execute(
        "CREATE TABLE IF NOT EXISTS notes ("
        " id TEXT PRIMARY KEY, title TEXT, folder TEXT, text TEXT, html TEXT,"
        " modified_at TEXT, is_deleted INTEGER DEFAULT 0, synced_at TEXT)"
    )
    db.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
    db.commit()
    return db


def get_meta(db, key):
    row = db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
    return row[0] if row else None


def set_meta(db, key, value):
    db.execute(
        "INSERT INTO meta(key,value) VALUES(?,?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (key, value),
    )


def login():
    username = os.environ.get("ICID_USERNAME", "")
    password = os.environ.get("ICID_PASSWORD", "")
    cookie_dir = os.environ.get("ICID_COOKIE_DIR", "") or os.path.expanduser(
        "~/.config/icloud_upload_session"
    )
    china = os.environ.get("ICID_CHINA", "0") == "1"
    if not username or not password:
        print("ERROR: ICID_USERNAME/ICID_PASSWORD missing", file=sys.stderr)
        sys.exit(2)
    api = SmsOnlyPyiCloudService(username, password, cookie_directory=cookie_dir, china_mainland=china)
    if not getattr(api, "is_trusted_session", False):
        print("2FA code needed (sent via SMS). Pass it as argv[1].", file=sys.stderr)
        code = sys.argv[1] if len(sys.argv) > 1 else input("Enter 6-digit code: ").strip()
        api.validate_2fa_code(code)
    return api.notes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--status", action="store_true", help="show index stats")
    parser.add_argument("code", nargs="?", help="2FA code if session expired")
    args = parser.parse_args()

    db = get_db()
    if args.status:
        n = db.execute("SELECT COUNT(*) FROM notes WHERE is_deleted=0").fetchone()[0]
        total = db.execute("SELECT COUNT(*) FROM notes").fetchone()[0]
        last = get_meta(db, "sync_cursor_ts") or "never"
        print(f"indexed notes: {n} (rows {total}) | last sync: {last}")
        return

    notes = login()
    print("Syncing notes...", file=sys.stderr)
    cursor = get_meta(db, "sync_cursor")
    events = list(notes.iter_changes(since=cursor)) if cursor else list(notes.iter_all())

    # iter_all yields NoteSummary; iter_changes yields ChangeEvent(s) with .note + .type
    updated = 0
    deleted = 0
    skipped_deleted = 0
    for item in events:
        if hasattr(item, "type"):  # ChangeEvent
            if item.type == "deleted":
                db.execute("UPDATE notes SET is_deleted=1, synced_at=? WHERE id=?", (now(), item.note.id))
                deleted += 1
                continue
            summary = item.note
        else:  # NoteSummary
            summary = item
        if summary.is_deleted:
            skipped_deleted += 1
            continue
        # full text
        try:
            full = notes.get(summary.id)
            text = full.text or ""
            db.execute(
                "INSERT INTO notes(id,title,folder,text,html,modified_at,is_deleted,synced_at) "
                "VALUES(?,?,?,?,?,?,0,?) "
                "ON CONFLICT(id) DO UPDATE SET title=excluded.title, folder=excluded.folder, "
                "text=excluded.text, html=excluded.html, modified_at=excluded.modified_at, "
                "is_deleted=0, synced_at=excluded.synced_at",
                (summary.id, summary.title or "", summary.folder_name or "", text,
                 full.html or "", str(summary.modified_at) if summary.modified_at else "", now()),
            )
            updated += 1
        except Exception as e:
            print(f"note {summary.id} read error: {e}", file=sys.stderr)
        time.sleep(0.12)  # be gentle with Apple rate limits

    new_cursor = notes.sync_cursor()
    set_meta(db, "sync_cursor", new_cursor)
    set_meta(db, "sync_cursor_ts", now())
    db.commit()
    total = db.execute("SELECT COUNT(*) FROM notes WHERE is_deleted=0").fetchone()[0]
    print(f"sync done: {updated} updated, {deleted} deleted, {skipped_deleted} skipped-deleted | index has {total} notes")
    print(f"sync cursor saved (incremental from now on)")


def now():
    import datetime

    return datetime.datetime.now(datetime.timezone.utc).isoformat()


if __name__ == "__main__":
    main()
