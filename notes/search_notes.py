#!/usr/bin/env python3
"""Search the local iCloud Notes index.

Usage:
  search_notes.py <term...> [--limit N]     ranked matches with context snippets
  search_notes.py --note <id>               dump the full text of one note
  search_notes.py --stats                   index summary

All terms must appear (AND). Ranking: title match first, then early-position
text matches, then later text matches. Snippets surround the first term hit.
"""
import argparse
import os
import sqlite3
import sys

NOTES_DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(NOTES_DIR, "index.db")


def get_db():
    if not os.path.exists(DB_PATH):
        print("ERROR: no index yet - run index_notes.py first", file=sys.stderr)
        sys.exit(3)
    return sqlite3.connect(DB_PATH)


def escape_like(s):
    return s.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def snippet(text, terms, width=130):
    text = text or ""
    low = text.lower()
    pos = -1
    for t in terms:
        p = low.find(t.lower())
        if p >= 0 and (pos < 0 or p < pos):
            pos = p
    if pos < 0:
        pos = 0
    start = max(0, pos - width // 2)
    end = min(len(text), pos + width)
    seg = text[start:end].replace("\n", " ")
    prefix = "..." if start > 0 else ""
    suffix = "..." if end < len(text) else ""
    return prefix + seg + suffix


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("terms", nargs="*")
    parser.add_argument("--limit", type=int, default=8)
    parser.add_argument("--note", help="dump full text of a note by id")
    parser.add_argument("--stats", action="store_true")
    args = parser.parse_args()

    db = get_db()

    if args.stats:
        n = db.execute("SELECT COUNT(*) FROM notes WHERE is_deleted=0").fetchone()[0]
        folders = db.execute(
            "SELECT folder, COUNT(*) FROM notes WHERE is_deleted=0 GROUP BY folder ORDER BY COUNT(*) DESC"
        ).fetchall()
        print(f"indexed notes: {n}")
        for f, c in folders[:15]:
            print(f"  {f or '(no folder)'}: {c}")
        return

    if args.note:
        row = db.execute(
            "SELECT title, folder, modified_at, text FROM notes WHERE id=? AND is_deleted=0",
            (args.note,),
        ).fetchone()
        if not row:
            print(f"ERROR: note {args.note} not found in index", file=sys.stderr)
            sys.exit(1)
        title, folder, modified, text = row
        print(f"# {title}")
        print(f"folder: {folder} | modified: {modified} | id: {args.note}")
        print("-" * 50)
        print(text or "(no text)")
        return

    if not args.terms:
        parser.print_help()
        sys.exit(1)

    terms = args.terms
    # AND semantics: every term must appear in title OR text
    conds = " AND ".join("(title LIKE ? OR text LIKE ?)" for _ in terms)
    params = [v for t in terms for v in (f"%{escape_like(t)}%", f"%{escape_like(t)}%")]
    rows = db.execute(
        f"SELECT id, title, folder, modified_at, text FROM notes WHERE is_deleted=0 AND {conds}",
        params,
    ).fetchall()

    if not rows:
        # fallback: any-term match (OR) if AND found nothing
        rows = db.execute(
            "SELECT id, title, folder, modified_at, text FROM notes WHERE is_deleted=0 AND ("
            + " OR ".join("title LIKE ? OR text LIKE ?" for _ in terms)
            + ")",
            [v for t in terms for v in (f"%{escape_like(t)}%", f"%{escape_like(t)}%")],
        ).fetchall()

    # rank: title hit > text position
    def rank(row):
        id_, title, folder, modified, text = row
        title_hit = any(t.lower() in (title or "").lower() for t in terms)
        pos = min((text or "").lower().find(t.lower()) for t in terms if t.lower() in (text or "").lower()) if any(
            t.lower() in (text or "").lower() for t in terms
        ) else 10 ** 9
        return (0 if title_hit else 1, pos)

    rows.sort(key=rank)
    rows = rows[: args.limit]

    if not rows:
        print("NO MATCHES")
        sys.exit(0)

    for id_, title, folder, modified, text in rows:
        print(f"--- {title or '(untitled)'}  [{folder or '-'}] {modified or ''}")
        print(f"    id: {id_}")
        print(f"    {snippet(text, terms)}")
    print(f"\n{len(rows)} result(s)")


if __name__ == "__main__":
    main()
