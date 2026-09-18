#!/usr/bin/env python3
"""Interactive iCloud 2FA login that keeps the code request and validation in ONE process.

Flow:
  1. Initialize the service -> Apple sends a fresh SMS code.
  2. Print CODE_SENT and poll /tmp/icloud-2fa-code.txt for the code.
  3. Validate the code in this same process (the one that requested it).

Usage: run under tmux so it survives while the code is collected.
"""
import os
import sys
import time

CODE_FILE = "/tmp/icloud-2fa-code.txt"

conf = os.path.expanduser("~/.config/icloud_upload.conf")
for line in open(conf):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        os.environ[k.strip()] = v.strip().strip('"').strip("'")

sys.path.insert(0, "/home/ubuntu/jackspark.top.server/ytdl")
from icloud_upload import SmsOnlyPyiCloudService  # noqa: E402

if os.path.exists(CODE_FILE):
    os.remove(CODE_FILE)

print("INIT: sending a fresh SMS code...", flush=True)
api = SmsOnlyPyiCloudService(
    os.environ["ICID_USERNAME"],
    os.environ["ICID_PASSWORD"],
    cookie_directory=os.path.expanduser("~/.config/icloud_upload_session"),
    china_mainland=os.environ.get("ICID_CHINA", "0") == "1",
)

if getattr(api, "is_trusted_session", False):
    print("RESULT: SESSION_OK (no 2FA needed)", flush=True)
    sys.exit(0)

print("CODE_SENT", flush=True)
code = None
for _ in range(120):  # wait up to 10 minutes
    if os.path.exists(CODE_FILE):
        code = open(CODE_FILE).read().strip()
        if code:
            break
    time.sleep(5)

if not code:
    print("RESULT: TIMEOUT (no code provided)", flush=True)
    sys.exit(2)

ok = api.validate_2fa_code(code)
if not ok:
    print("RESULT: CODE_REJECTED", flush=True)
    sys.exit(3)

if getattr(api, "is_trusted_session", False):
    print("RESULT: LOGIN_OK (session saved)", flush=True)
else:
    print("RESULT: VALIDATED_BUT_NOT_TRUSTED", flush=True)
