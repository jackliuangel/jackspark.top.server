#!/usr/bin/env python3
"""Create an iCloud Reminder (add-only; no delete capability).

Usage:
  create_reminder.py "标题" [--list "列表名"] [--due "YYYY-MM-DD HH:MM"] [--notes "备注"]

Uses pyicloud's Reminders write API (a real client implementation with CRDT
handling, unlike the read-only Notes service).
"""
import argparse
import datetime
import os
import sys

# Default target list unless --list overrides it.
DEFAULT_LIST = "24小时内自力完成🕙"


def _norm(s: str) -> str:
    """Drop emoji/whitespace so near-identical list names still match."""
    return "".join(ch for ch in (s or "") if ch.isalnum() or "\u4e00" <= ch <= "\u9fff")


def resolve_list(lists, wanted: str):
    """Match a list by exact title, then normalized title, then a 24小时内 prefix."""
    target = next((rl for rl in lists if rl.title == wanted), None)
    if target is not None:
        return target
    nw = _norm(wanted)
    target = next((rl for rl in lists if _norm(rl.title) == nw), None)
    if target is not None:
        return target
    if nw.startswith("24小时内") or "完成" in nw:
        target = next((rl for rl in lists if _norm(rl.title).startswith("24小时内")), None)
    return target

conf = os.path.expanduser("~/.config/icloud_upload.conf")
if os.path.exists(conf):
    with open(conf) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))

sys.path.insert(0, "/home/ubuntu/jackspark.top.server/ytdl")
from icloud_upload import SmsOnlyPyiCloudService  # noqa: E402


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
    api = SmsOnlyPyiCloudService(
        username, password, cookie_directory=cookie_dir, china_mainland=china
    )
    if not getattr(api, "is_trusted_session", False):
        print("2FA code needed: run notes/login_2fa.py first.", file=sys.stderr)
        sys.exit(3)
    return api


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("title", help="reminder title")
    parser.add_argument("--list", dest="list_name", help=f"list name (default: {DEFAULT_LIST})")
    parser.add_argument("--due", help='due date, e.g. "2026-09-18 09:00"')
    parser.add_argument("--notes", dest="desc", default="", help="optional notes body")
    parser.add_argument("--flagged", action="store_true", help="mark as flagged")
    parser.add_argument("--priority", type=int, default=0, help="priority 0-9 (1=high, 5=medium, 9=low)")
    args = parser.parse_args()

    api = login()
    lists = [rl for rl in api.reminders.lists() if not getattr(rl, "deleted", False)]
    target_name = args.list_name or DEFAULT_LIST
    target = resolve_list(lists, target_name)
    if target is None:
        print(f"ERROR: reminder list '{target_name}' not found. Available:", file=sys.stderr)
        for rl in lists:
            print(f"  - {rl.title}", file=sys.stderr)
        sys.exit(5)

    due = None
    if args.due:
        for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d"):
            try:
                due = datetime.datetime.strptime(args.due, fmt)
                break
            except ValueError:
                continue
        if due is None:
            print(f"ERROR: could not parse --due '{args.due}'", file=sys.stderr)
            sys.exit(6)

    reminder = api.reminders.create(
        list_id=target.id,
        title=args.title,
        desc=args.desc,
        due_date=due,
        priority=args.priority,
        flagged=args.flagged,
    )
    print(f"OK created reminder id={reminder.id} list={target.title!r} title={reminder.title!r}")
    if due:
        print(f"   due: {due}")


if __name__ == "__main__":
    main()
