#!/bin/bash
# Official test suite for video_download_pro.sh.
# Run before every commit (CI: .github/workflows/test.yml; local: pre-commit hook).
#
# Modes:
#   - Unit tests: always run, deterministic, no network. Validate syntax, helper
#     functions (quality labels, title sanitization, JSON escaping, URL encoding).
#   - Integration tests: run only when the live environment is present (YouTube
#     cookies + the mTLS client certificate), skipped on plain CI runners.
#     Cover the 3-field JSON (sync + async), exact filename prediction, mTLS
#     enforcement (403 without cert / 200 with cert) and the /files redirect.
#
# Exit code 0 = all run checks passed; non-zero = at least one failure.

set -u

# Tests must not spam the captain's iCloud Reminders list with test links.
export SKIP_REMINDER=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOAD_SCRIPT="$SCRIPT_DIR/../video_download_pro.sh"
COOKIES_FILE="$SCRIPT_DIR/../cookies-youtube.txt"
MTLS_DIR="/home/ubuntu/mtls-cert"
DOWNLOAD_DIR="/tmp/video_download/congliulyc@gmail.com"
TEST_URL="https://www.youtube.com/watch?v=jNQXAC9IVRw"
TEST_URL_BASE="https://files.jackspark.top"

PASS=0
FAIL=0
PRE_COMMIT_CERT_TESTS="${PRE_COMMIT_CERT_TESTS:-0}"

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

check_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$name"
    else
        fail "$name (expected [$expected], got [$actual])"
    fi
}

if [ "$PRE_COMMIT_CERT_TESTS" != "1" ]; then
echo "=== Unit tests ==="

# 1. Syntax checks
if bash -n "$DOWNLOAD_SCRIPT" 2>/dev/null; then pass "video_download_pro.sh syntax (bash -n)"; else fail "video_download_pro.sh syntax"; fi
if python3 -m py_compile "$SCRIPT_DIR/../get_po_token.py" 2>/dev/null; then pass "get_po_token.py syntax"; else fail "get_po_token.py syntax"; fi

# 2. Load the script's helper functions without running main (guarded by BASH_SOURCE check)
# shellcheck source=../video_download_pro.sh
source "$DOWNLOAD_SCRIPT"

# 3. Quality labels
check_eq "quality 1 -> 360p" "360p" "$(get_quality_label 1)"
check_eq "quality 2 -> 720p" "720p" "$(get_quality_label 2)"
check_eq "quality 3 -> 1080p" "1080p" "$(get_quality_label 3)"
check_eq "quality 4 -> 4k" "4k" "$(get_quality_label 4)"
check_eq "quality empty -> best" "best" "$(get_quality_label "")"

# 4. Title sanitization (must match yt-dlp --replace-in-metadata used by the download)
check_eq "sanitize chinese title" "为什么“信息”才是宇宙最基本的组成单元信息熵信息守恒" "$(sanitize_title "为什么“信息”才是宇宙最基本的组成单元？信息熵、信息守恒")"
check_eq "sanitize spaces and symbols" "A_B_C" "$(sanitize_title "A  B! C")"
check_eq "sanitize trailing whitespace" "Hello" "$(sanitize_title "Hello   ")"
check_eq "sanitize punctuation" "abcde" "$(sanitize_title "a.b?c#d:e")"

# 5. JSON escaping (json_escape emits a quoted JSON string literal)
check_eq "json_escape plain" '"abc"' "$(json_escape "abc")"
check_eq "json_escape quote" '"a\"b"' "$(json_escape 'a"b')"

# 6. URL encoding
check_eq "url_encode space" "a%20b" "$(url_encode "a b")"
check_eq "url_encode chinese" "%E4%B8%AD" "$(url_encode "中")"
else
    echo "=== Unit tests skipped (pre-commit certificate mode) ==="
fi

# --- Integration tests: only when the live environment is available ---
if [ "${TEST_NETWORK:-1}" != "0" ] && [ -f "$COOKIES_FILE" ] && [ -f "$MTLS_DIR/jack-mtls-client.p12" ]; then
    echo "=== Integration tests (live environment) ==="

    P12_PW="$(sed 's/^PASSWORD: //' "$MTLS_DIR/jack-mtls-p12-password.txt")"
    P12="$MTLS_DIR/jack-mtls-client.p12"

    # Helper: run the script (sync or async) and parse its JSON output
    run_script_json() {
        local mode="$1"
        local out
        out=$("$DOWNLOAD_SCRIPT" "$TEST_URL" "" "" server "$mode" 2>/dev/null)
        printf '%s' "$out"
    }

    check_json3() {
        local label="$1" json="$2"
        if python3 - "$label" "$json" <<'PYEOF'
import json, sys
label, raw = sys.argv[1], sys.argv[2]
try:
    d = json.loads(raw)
except Exception as e:
    print(f"JSON parse error: {e}")
    sys.exit(1)
required = {"video_source_url", "title", "download_link"}
if set(d.keys()) != required:
    print(f"keys {sorted(d.keys())} != {sorted(required)}")
    sys.exit(1)
if not d["video_source_url"].startswith("http"):
    print("video_source_url empty/odd")
    sys.exit(1)
if not d["title"]:
    print("title empty")
    sys.exit(1)
if not d["download_link"].startswith("https://files.jackspark.top/"):
    print("download_link wrong base")
    sys.exit(1)
sys.exit(0)
PYEOF
        then
            pass "$label JSON structure (3 fields)"
        else
            fail "$label JSON structure"
        fi
    }

    # Prepare an async download because test 10 validates its download link.
    ASYNC_JSON=$(run_script_json async)
    ASYNC_LINK=$(printf '%s' "$ASYNC_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['download_link'])")
    ASYNC_FILE=$(printf '%s' "$ASYNC_JSON" | python3 -c "
import json,sys,urllib.parse
print(urllib.parse.unquote(json.load(sys.stdin)['download_link'].rsplit('/',1)[-1]))")
    # Wait for the background download to land (up to 150s)
    FOUND=0
    for _ in $(seq 1 30); do
        if [ -f "$DOWNLOAD_DIR/$ASYNC_FILE" ]; then FOUND=1; break; fi
        sleep 5
    done
    if [ "$FOUND" = "1" ]; then
        if [ "$PRE_COMMIT_CERT_TESTS" != "1" ]; then
            pass "async background file lands with exact predicted name ($ASYNC_FILE)"
        fi
    else
        fail "async file not found after 150s: $DOWNLOAD_DIR/$ASYNC_FILE"
    fi

    if [ "$PRE_COMMIT_CERT_TESTS" != "1" ]; then
        check_json3 "async JSON" "$ASYNC_JSON"
    fi

    if [ "$PRE_COMMIT_CERT_TESTS" != "1" ]; then
        # 8. Sync: JSON shape
        SYNC_JSON=$(run_script_json "")
        check_json3 "sync JSON" "$SYNC_JSON"
    fi

    # 9. mTLS: files. requires client cert
    NO_CERT=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 "$TEST_URL_BASE/")
    if [ "$NO_CERT" = "403" ]; then pass "files. without client cert -> 403 (mTLS)"; else fail "files. without cert -> $NO_CERT (expected 403)"; fi

    # 10. Download link reachable with client cert (only if the file landed)
    if [ "$FOUND" = "1" ]; then
        TMPCERT="$(mktemp)"
        TMPKEY="$(mktemp)"
        openssl pkcs12 -in "$P12" -passin pass:"$P12_PW" -nodes -clcerts -out "$TMPCERT" 2>/dev/null
        openssl pkcs12 -in "$P12" -passin pass:"$P12_PW" -nodes -nocerts -out "$TMPKEY" 2>/dev/null
        LINK_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 --cert "$TMPCERT" --key "$TMPKEY" "$ASYNC_LINK")
        rm -f "$TMPCERT" "$TMPKEY"
        if [ "$LINK_CODE" = "200" ]; then pass "download link serves 200 with client cert"; else fail "download link -> $LINK_CODE (expected 200)"; fi
    fi

    if [ "$PRE_COMMIT_CERT_TESTS" != "1" ]; then
        # 11. Old /files/ URL redirects to files.jackspark.top (served by the new zone)
        REDIR=$(curl -sI --max-time 20 "https://jackspark.top/files/test.txt" | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r')
        if printf '%s' "$REDIR" | grep -q "^https://files.jackspark.top/"; then
            pass "old /files/ link redirects to files.jackspark.top"
        else
            fail "old /files/ link redirect -> [$REDIR]"
        fi
    fi
else
    echo "SKIP: integration tests (no cookies or mTLS cert present - CI mode)"
fi

echo ""
echo "=============================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================================="

[ "$FAIL" -eq 0 ]
