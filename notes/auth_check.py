#!/usr/bin/env python3
"""One-shot iCloud auth check (no retries): reports whether the session logs in.

Writes a single result line to /tmp/icloud-auth-check.log:
  SESSION_OK          - logged in, trusted session, no 2FA needed
  NEEDS_2FA           - password accepted, Apple wants a verification code
  APPLE_503           - Apple identity service rejected the auth attempt (rate limit/outage)
  FAIL:<detail>       - anything else
"""
import datetime
import os
import sys

LOG = "/tmp/icloud-auth-check.log"

conf = os.path.expanduser("~/.config/icloud_upload.conf")
for line in open(conf):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        os.environ[k.strip()] = v.strip().strip('"').strip("'")

sys.path.insert(0, "/home/ubuntu/jackspark.top.server/ytdl")

result = None
try:
    from icloud_upload import SmsOnlyPyiCloudService

    api = SmsOnlyPyiCloudService(
        os.environ["ICID_USERNAME"],
        os.environ["ICID_PASSWORD"],
        cookie_directory=os.path.expanduser("~/.config/icloud_upload_session"),
        china_mainland=os.environ.get("ICID_CHINA", "0") == "1",
    )
    if getattr(api, "is_trusted_session", False):
        result = "SESSION_OK"
    else:
        result = "NEEDS_2FA"
except Exception as e:
    msg = str(e)
    if "503" in msg or "Temporarily Unavailable" in msg:
        result = "APPLE_503"
    elif "Invalid email/password" in msg:
        # pyicloud reports Apple's 503 with this misleading message; keep both facts.
        result = "APPLE_503_OR_BAD_PASSWORD"
    else:
        result = f"FAIL:{type(e).__name__}:{msg[:80]}"

stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
with open(LOG, "a") as f:
    f.write(f"{stamp} {result}\n")
print(f"{stamp} {result}")
