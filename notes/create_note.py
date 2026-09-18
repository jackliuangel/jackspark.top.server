#!/usr/bin/env python3
"""Create an iCloud Note through the CloudKit Notes write API.

Usage:
  create_note.py "note text" [--folder NAME] [--title TITLE] [--dry-run]

Notes:
  - The note body is a protobuf (NoteStoreProto) compressed with zlib and base64
    encoded; iCloud's "TextDataEncrypted" field is misleadingly named and is NOT
    cryptographically encrypted (verified by reading the same data back through
    pyicloud's own decoder).
  - Structural record fields are cloned from an existing note (template), then the
    content and timestamps are replaced, so account-specific schema fields stay valid.
  - Requires a working iCloud session (see ~/.config/icloud_upload.conf); if the
    session expired, run icloud_upload.sh login first.
"""
import argparse
import base64
import os
import sys
import time
import uuid
import zlib

NOTES_DIR = os.path.dirname(os.path.abspath(__file__))

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
from pyicloud.common.cloudkit import (  # noqa: E402
    CKModifyOperation,
    CKWriteRecord,
    CKZoneIDReq,
)
from pyicloud.services.notes.protobuf import notes_pb2  # noqa: E402

# Default folder for new notes unless --folder overrides it.
DEFAULT_FOLDER = "打卡 Shorcuts"

# Fields the server owns or that we replace on every create.
# The two ReplicaID* fields are device/replica mappings cloned from a template note;
# carrying another device's replica identity makes iCloud adopt the new note as an
# orphan and move it to Recently Deleted, so they are omitted on create.
SKIP_FIELDS = {
    # Attachment metadata cloned from a template that has attachments makes the
    # service demand an asset upload receipt for a note we create without assets.
    "FirstAttachmentThumbnail",
    "FirstAttachmentUTIEncrypted",
    "FirstAttachmentThumbnailOrientation",
    "Attachments",
    "AttachmentViewType",
}
# Only pick a template WITHOUT attachments, so structural cloning stays valid.
CONTENT_FIELDS = {
    "TitleEncrypted",
    "SnippetEncrypted",
    "TextDataEncrypted",
    "CreationDate",
    "ModificationDate",
    "LastViewedModificationDate",
}


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
        print("2FA code needed (SMS). Pass it as argv[1] (--code).", file=sys.stderr)
        sys.exit(3)
    return api.notes


def build_body(text: str) -> str:
    """Build the base64(zlib(protobuf)) note body.

    iCloud expects one attribute_run per paragraph, each carrying a
    paragraph_style (writing direction + paragraph_uuid). A single run without a
    paragraph_style is accepted by CloudKit but the note service then discards the
    content and the note shows up blank (title becomes "New Note").
    """
    proto = notes_pb2.NoteStoreProto()
    proto.document.version = 0
    note = proto.document.note
    note.note_text = text

    parts = text.split("\n")
    segments = [p + "\n" for p in parts[:-1]]
    if parts[-1]:
        segments.append(parts[-1])
    if not segments:
        segments = [""]

    for seg in segments:
        run = note.attribute_run.add()
        run.length = len(seg)
        run.paragraph_style.writing_direction_paragraph = notes_pb2.WRITING_DIRECTION_LTR
        run.paragraph_style.paragraph_uuid = uuid.uuid4().bytes

    raw = proto.SerializeToString()
    return base64.b64encode(zlib.compress(raw)).decode()


def b64_text(s: str) -> str:
    return base64.b64encode(s.encode("utf-8")).decode()


def now_ms() -> int:
    return int(time.time() * 1000)


def field_to_write(name: str, field) -> dict:
    """Serialise a read-side field wrapper into a write-side {type, value} dict."""
    try:
        data = field.model_dump(mode="json", exclude_none=True)
        if isinstance(data, dict) and "type" in data:
            return data
    except Exception:
        pass
    ftype = getattr(field, "type", None)
    value = getattr(field, "value", None)
    if ftype == "ENCRYPTED_BYTES" and isinstance(value, (bytes, bytearray)):
        value = base64.b64encode(bytes(value)).decode()
    elif hasattr(value, "model_dump"):
        value = value.model_dump(mode="json", exclude_none=True)
    elif isinstance(value, list):
        value = [
            v.model_dump(mode="json", exclude_none=True) if hasattr(v, "model_dump") else v
            for v in value
        ]
    return {"type": ftype, "value": value}


def resolve_folder(notes, name: str):
    for folder in notes.folders():
        if folder.name == name:
            return folder.id
    return None


def delete_note(notes, note_id: str) -> bool:  # DISABLED: add-only tool
    """Refuse deletion. The captain authorized ADD ONLY; this tool must never delete.

    The previously implemented CloudKit delete path was removed entirely on 2026-09-18
    so no delete capability exists anywhere in this tooling.
    """
    print("REFUSED: this tool is add-only and never deletes notes.", file=sys.stderr)
    return False


def build_fields(template_fields, title: str, body_text: str, folder_id: str | None, ts: int):
    fields = {}
    for name, field in template_fields.items():
        if name in CONTENT_FIELDS or name in SKIP_FIELDS:
            continue
        fields[name] = field_to_write(name, field)

    # Replace the folder reference when a target folder is given.
    if folder_id:
        ref = {
            "recordName": folder_id,
            "action": "VALIDATE",
            "zoneID": {"zoneName": "Notes", "zoneType": "REGULAR_CUSTOM_ZONE"},
        }
        if "Folders" in fields:
            fields["Folders"] = {"type": "REFERENCE_LIST", "value": [ref]}
        if "Folder" in fields:
            fields["Folder"] = {"type": "REFERENCE", "value": ref}

    snippet = body_text.strip().splitlines()[0] if body_text.strip() else ""
    fields["TitleEncrypted"] = {"type": "ENCRYPTED_BYTES", "value": b64_text(title)}
    fields["SnippetEncrypted"] = {"type": "ENCRYPTED_BYTES", "value": b64_text(snippet)}
    fields["TextDataEncrypted"] = {"type": "ENCRYPTED_BYTES", "value": build_body(body_text)}
    for stamp in ("CreationDate", "ModificationDate"):
        fields[stamp] = {"type": "TIMESTAMP", "value": ts}
    # Optional timestamp fields: only set the ones the template actually carries.
    if "LastViewedModificationDate" in template_fields:
        fields["LastViewedModificationDate"] = {"type": "TIMESTAMP", "value": ts}
    return fields


def main():
    # DISABLED 2026-09-17: notes written via direct CloudKit are recycled into
    # "Recently Deleted" by iCloud. Refuse to run unless explicitly overridden.
    if os.environ.get("ICLOUD_NOTES_WRITE_ALLOWED") != "1":
        print(
            "REFUSED: iCloud note writing via pyicloud is disabled (notes get recycled\n"
            "into Recently Deleted). Use AppleScript on the Mac or an iPhone Shortcut.\n"
            "Override only for debugging with ICLOUD_NOTES_WRITE_ALLOWED=1.",
            file=sys.stderr,
        )
        sys.exit(8)

    parser = argparse.ArgumentParser()
    parser.add_argument("text", nargs="?", default="", help="note body text")
    parser.add_argument("--folder", help=f"target folder name (default: {DEFAULT_FOLDER})")
    parser.add_argument("--title", help="note title (default: first line of text)")
    parser.add_argument("--dry-run", action="store_true", help="assemble but do not write")
    args = parser.parse_args()

    notes = login()
    raw = notes.raw  # property, not a method

    title = args.title or (args.text.strip().splitlines()[0] if args.text.strip() else "Untitled")

    # Template = a recent note WITHOUT attachments (attachment metadata cannot be cloned).
    template_rec = None
    for cand in notes.recents(limit=20):
        rec = raw.lookup([cand.id]).records[0]
        if type(rec).__name__ != "CKRecord":
            continue
        if any(k.startswith("FirstAttachment") or k == "Attachments" for k in rec.fields.keys()):
            continue
        template_rec = rec
        break
    if template_rec is None:
        print("ERROR: no attachment-free note found to use as a template", file=sys.stderr)
        sys.exit(4)

    folder_id = None
    folder_name = args.folder or DEFAULT_FOLDER
    folder_id = resolve_folder(notes, folder_name)
    if not folder_id:
        print(
            f"ERROR: folder '{folder_name}' not found (pass --folder explicitly)",
            file=sys.stderr,
        )
        sys.exit(5)

    ts = now_ms()
    fields = build_fields(template_rec.fields, title, args.text, folder_id, ts)
    record_name = uuid.uuid4().hex.upper()

    payload = {
        "operationType": "create",
        "record": {"recordName": record_name, "recordType": "Note", "fields": fields},
    }
    if args.dry_run:
        import json

        print(json.dumps(payload, ensure_ascii=False, indent=2)[:2000])
        print(f"\n[dry-run] would create note {record_name} (title={title!r})")
        return

    op = CKModifyOperation(
        operationType="create",
        record=CKWriteRecord(recordName=record_name, recordType="Note", fields=fields),
    )
    # The Notes client wraps the generic CloudKit container client, which owns modify().
    resp = raw._client.modify(
        operations=[op], zone_id=CKZoneIDReq(zoneName="Notes"), atomic=True
    )

    created = []
    errors = []
    for r in getattr(resp, "records", []):
        cls = type(r).__name__
        if cls == "CKRecord":
            created.append(r)
        else:
            code = getattr(r, "serverErrorCode", None) or getattr(r, "code", None)
            reason = getattr(r, "reason", None)
            name = getattr(r, "recordName", None)
            errors.append(f"{cls} {name} code={code} reason={reason}")

    if not created:
        print("ERROR: CloudKit rejected the create", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(6)

    new_id = created[0].recordName
    print(f"OK created note id={new_id} title={title!r}")


if __name__ == "__main__":
    main()
