#!/bin/bash
# Universal Video Downloader (YouTube & Bilibili)
# Save as video-download-pro.sh

# Global Configuration
URL="${1:-}"
QUALITY="${2:-}"
SILENT_MODE="${3:-}"
LOCAL_MODE="${4:-}"  # Optional: "local" or "server" to force local or server paths, default is server
ASYNC_MODE="${5:-}"  # Optional: "async" to return the 3-field JSON after metadata and download in the background

# 超过此字节数的文件跳过 iCloud 上传（70 MB = 70 * 1024 * 1024）
ICLOUD_MAX_SIZE_BYTES=73400320

# PO token 缓存有效期（秒）：token 短期内有效，复用可减少对 YouTube 的请求与风控风险
PO_TOKEN_TTL=600
# 生成 PO token 的超时（秒）：绝不无限阻塞下载流程
PO_TOKEN_TIMEOUT=30
# 本脚本测试过的 yt-dlp 版本；安装版本不一致时给出告警（A1 版本钉扎）
YTDLP_PINNED_VERSION="2026.07.04"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR_LOCAL="$SCRIPT_DIR/workdir"
BASE_DIR_SERVER="/tmp/video_download"
if [ "$LOCAL_MODE" = "local" ]; then
    BASE_DIR=$BASE_DIR_LOCAL
else
    BASE_DIR=$BASE_DIR_SERVER
fi

BASE_LOG_DIR_SERVER="/tmp/video_download"
BASE_LOG_DIR_LOCAL="$BASE_DIR_LOCAL"
if [ "$LOCAL_MODE" = "local" ]; then
    BASE_LOG_DIR=$BASE_LOG_DIR_LOCAL
else
    BASE_LOG_DIR=$BASE_LOG_DIR_SERVER
fi


YTDL_COOKIES_DIR_LOCAL="$SCRIPT_DIR"
YTDL_COOKIES_DIR_SERVER="/home/ubuntu/ytdl"
if [ "$LOCAL_MODE" = "local" ]; then
    YTDL_COOKIES_DIR=$YTDL_COOKIES_DIR_LOCAL
else
    YTDL_COOKIES_DIR=$YTDL_COOKIES_DIR_SERVER
fi


DOWNLOAD_DIR_SERVER="$BASE_DIR/congliulyc@gmail.com"
# DOWNLOAD_DIR_LOCAL="$BASE_DIR/video_download"
DOWNLOAD_DIR_LOCAL="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Downloads"
if [ ! -d "$DOWNLOAD_DIR_LOCAL" ]; then
    DOWNLOAD_DIR_LOCAL="$HOME/Downloads"
fi
if [ "$LOCAL_MODE" = "local" ]; then
    DOWNLOAD_DIR=$DOWNLOAD_DIR_LOCAL
else
    DOWNLOAD_DIR=$DOWNLOAD_DIR_SERVER
fi

PYTHON_CMD="$(command -v python 2>/dev/null || command -v python3 2>/dev/null || command -v python3.10 2>/dev/null || command -v python3.11 2>/dev/null || echo python)"
YTDLP_CMD=()

# Generate timestamp for filename
TIMESTAMP="${DOWNLOAD_TS:-$(date '+%Y%m%d_%H%M%S')}"

# Function to log messages
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# 安全转义一个值，用于嵌入 JSON 字符串字面量（B3：JSON 输出转义）
json_escape() {
    "$PYTHON_CMD" -c 'import json, sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1" 2>/dev/null
}

# 对文件名做 URL 百分号编码，保证下载链接在浏览器/curl 中都可用（B4）
url_encode() {
    # surrogateescape keeps invalid UTF-8 bytes (e.g. a 120-byte title truncation
    # cutting mid-CJK-character) encodeable, so the link never comes back empty.
    "$PYTHON_CMD" -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1].encode("utf-8", "surrogateescape")))' "$1" 2>/dev/null
}

# Function to upload a downloaded file to iCloud Drive via the companion script
upload_to_icloud() {
    local file="$1"
    local icloud_script="$SCRIPT_DIR/icloud_upload.sh"
    if [ ! -x "$icloud_script" ]; then
        log "iCloud upload skipped: $icloud_script not found"
        return 0
    fi
    if [ ! -f "$file" ]; then
        log "ERROR: iCloud upload skipped: file not found: $file"
        return 0
    fi
    # 文件大于 70MB 时跳过 iCloud 上传（避免大文件上传超时/失败）
    local size_bytes
    size_bytes=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
    if [ -n "$size_bytes" ] && [ "$size_bytes" -gt "$ICLOUD_MAX_SIZE_BYTES" ]; then
        local size_human
        size_human=$(du -h "$file" | cut -f1)
        log "ERROR: iCloud upload SKIPPED - file too large: ${size_human} (>70MB limit): $file"
        return 0
    fi
    log "Uploading to iCloud Drive: $file"
    if "$icloud_script" upload "$file" >> "$LOG_FILE" 2>&1; then
        log "iCloud upload succeeded"
    else
        log "iCloud upload FAILED (download result unaffected); run '$icloud_script login' to refresh the session"
    fi
}

# Create an iCloud Reminder whose content is the finished download link (best-effort).
# Skipped when SKIP_REMINDER=1 (the test suite sets it so tests do not spam the list).
create_reminder_for_link() {
    local link="$1"
    [ "${SKIP_REMINDER:-0}" = "1" ] && { log "reminder skipped (SKIP_REMINDER=1)"; return 0; }

    local reminder_script="$SCRIPT_DIR/../notes/create_reminder.py"
    local venv_python="/home/ubuntu/.local/venvs/icloud/bin/python"
    if [ ! -f "$reminder_script" ]; then
        log "reminder skipped: $reminder_script not found"
        return 0
    fi
    if [ ! -x "$venv_python" ]; then
        log "reminder skipped: $venv_python not found"
        return 0
    fi

    log "Creating reminder for download link: $link"
    if timeout 120 "$venv_python" "$reminder_script" "$link" >> "$LOG_FILE" 2>&1; then
        log "reminder created"
    else
        log "reminder creation FAILED (download result unaffected)"
    fi
}

# Function to get quality label for filename
get_quality_label() {
    local quality="$1"
    case "$quality" in
        1|"360p")
            echo "360p"
            ;;
        2|"720p")
            echo "720p"
            ;;
        3|"1080p")
            echo "1080p"
            ;;
        4|"4k")
            echo "4k"
            ;;
        *)
            echo "best"
            ;;
    esac
}

# Function to get YouTube format selector (More compatible version)
get_youtube_format_selector() {
    local quality="$1"
    case "$quality" in
        1|"360p")
            # 优先 360p MP4，否则选 360p 任意格式
            echo "bv*[height<=360][ext=mp4]+ba[ext=m4a]/bv*[height<=360]+ba/b[height<=360]/best"
            ;;
        2|"720p")
            # 优先 720p MP4
            echo "bv*[height<=720][ext=mp4]+ba[ext=m4a]/bv*[height<=720]+ba/b[height<=720]/best"
            ;;
        3|"1080p")
            # 优先 1080p MP4 (avc1 编码兼容性最好)
            echo "bv*[height<=1080][vcodec^=avc1]+ba[acodec^=mp4a]/bv*[height<=1080][ext=mp4]+ba[ext=m4a]/bv*[height<=1080]+ba/b[height<=1080]/best"
            ;;
        *)
            # Default: Select the best single-file format (prevents issues when ffmpeg is missing)
            # Or bestvideo+bestaudio if they can be merged. Without ffmpeg, yt-dlp will fallback to 
            # single-file best or download two files.
            echo "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best"
            ;;
    esac
}

# Function to get Bilibili format selector
get_bilibili_format_selector() {
    local quality="$1"
    case "$quality" in
        1|"360p")
            echo "bv*[height<=360]+ba/b[height<=360]/worst"
            ;;
        2|"720p")
            echo "bv*[height<=720]+ba/b[height<=720]/b"
            ;;
        3|"1080p")
            echo "bv*[height<=1080]+ba/b[height<=1080]/b"
            ;;
        4|"4k")
            echo "bv*[height<=2160]+ba/b[height<=2160]/best"
            ;;
        *)
            echo "bv*+ba/b/best"
            ;;
    esac
}

# Function to clean and extract valid URL
clean_url() {
    local input="$1"
    # Extract URL starting with http:// or https://
    if [[ "$input" =~ (https?://[^[:space:]]*) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$input"
    fi
}

# Function to detect platform from URL
detect_platform() {
    local url="$1"
    if [[ "$url" =~ youtu ]]; then
        echo "youtube"
    elif [[ "$url" =~ bilibili\.com ]] || [[ "$url" =~ b23\.tv ]]; then
        echo "bilibili"
    else
        echo "unknown"
    fi
}

# Function to setup platform-specific configurations
setup_platform_config() {
    local platform="$1"
    
    case "$platform" in
        "youtube")
            COOKIES_FILE="$YTDL_COOKIES_DIR/cookies-youtube.txt"
            LOG_FILE="$BASE_LOG_DIR/youtube_download.log"
            FORMAT_SELECTOR=$(get_youtube_format_selector "$QUALITY")
            ;;
        "bilibili")
            COOKIES_FILE="$YTDL_COOKIES_DIR/cookies-bilibili.txt"

            LOG_FILE="$BASE_LOG_DIR/bilibili_download.log"
            FORMAT_SELECTOR=$(get_bilibili_format_selector "$QUALITY")
            ;;
    esac
    
    # Create directories
    mkdir -p "$DOWNLOAD_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
}

# Function to check prerequisites
check_prerequisites() {
    local platform="$1"
    
    # Check if yt-dlp is installed (Homebrew yt-dlp takes priority)
    local system_yt_dlp
    system_yt_dlp="$(command -v yt-dlp 2>/dev/null || true)"
    if [ -x "/opt/homebrew/bin/yt-dlp" ]; then
        YTDLP_CMD=("/opt/homebrew/bin/yt-dlp")
    elif [ -n "$system_yt_dlp" ] && [ -x "$system_yt_dlp" ] && [[ "$system_yt_dlp" != "$HOME/Library/Python/3.9/bin/yt-dlp" ]]; then
        YTDLP_CMD=("$system_yt_dlp")
    elif [ -x "$HOME/.local/bin/yt-dlp" ]; then
        YTDLP_CMD=("$HOME/.local/bin/yt-dlp")
    elif [ -x "$HOME/Library/Python/3.9/bin/yt-dlp" ]; then
        YTDLP_CMD=("$HOME/Library/Python/3.9/bin/yt-dlp")
    elif command -v "$PYTHON_CMD" >/dev/null 2>&1 && "$PYTHON_CMD" -m yt_dlp --version >/dev/null 2>&1; then
        YTDLP_CMD=("$PYTHON_CMD" -m yt_dlp)
    fi

    if [ ${#YTDLP_CMD[@]} -eq 0 ]; then
        log "ERROR: yt-dlp not found"
        echo "ERROR: yt-dlp not found. Please install it first:"
        echo "$PYTHON_CMD -m pip install --user yt-dlp"
        exit 1
    fi

    YTDLP_PATH="${YTDLP_CMD[*]}"
    log "Using yt-dlp at: $YTDLP_PATH"

    # A1: 版本钉扎——安装版本与测试版本不一致时告警，避免 YouTube 变更悄悄破坏下载
    local installed_ver
    installed_ver=$("$YTDLP_PATH" --version 2>/dev/null || true)
    if [ -n "$installed_ver" ] && [ "$installed_ver" != "$YTDLP_PINNED_VERSION" ]; then
        log "WARNING: yt-dlp version $installed_ver differs from pinned/tested version $YTDLP_PINNED_VERSION; keep the tested version or re-verify the pin"
    fi
    
    # Check cookies file based on platform
    if [ ! -f "$COOKIES_FILE" ]; then
        if [ "$platform" = "youtube" ]; then
            log "ERROR: YouTube cookies file does not exist at $COOKIES_FILE"
            echo "ERROR: YouTube cookies file not found at $COOKIES_FILE"
            exit 1
        else
            # For Bilibili, warn but continue
            log "WARNING: Bilibili cookies file does not exist at $COOKIES_FILE"
            echo "WARNING: Cookies file not found at $COOKIES_FILE"
            echo "Some bilibili videos may not be accessible without cookies."
            echo "Please export your bilibili cookies and save to: $COOKIES_FILE"
            echo ""
            echo "Continuing without cookies..."
            COOKIES_OPTION=()
            return 0
        fi
    fi
    
    log "Using cookies file: $COOKIES_FILE"
    COOKIES_OPTION=(--cookies "$COOKIES_FILE")
}

# Function to get PO token args
get_po_token_args() {
    local token_script="$YTDL_COOKIES_DIR/get_po_token.py"

    if [ ! -f "$token_script" ]; then
        # Try relative path
        token_script="$(dirname "$0")/get_po_token.py"
    fi

    if [ ! -f "$token_script" ]; then
        log "WARNING: get_po_token.py not found at $token_script"
        return 1
    fi

    # A1: PO token 缓存——token 短期内有效，复用可减少对 YouTube 的请求与风控风险
    local cache_file="$BASE_LOG_DIR/po_token_cache"
    local ttl_min=$(( (PO_TOKEN_TTL + 59) / 60 ))
    if [ -f "$cache_file" ] && [ -n "$(find "$cache_file" -mmin "-$ttl_min" 2>/dev/null)" ]; then
        local cached
        cached=$(cat "$cache_file" 2>/dev/null)
        if [ -n "$cached" ]; then
            log "PO token reused from cache: $cache_file"
            echo "--extractor-args"
            echo "$cached"
            return 0
        fi
    fi

    log "Attempting to generate PO token using $token_script..."
    # Run python script and capture stdout. Stderr goes to log. Never block forever.
    local args
    args=$(timeout "$PO_TOKEN_TIMEOUT" "$PYTHON_CMD" "$token_script" 2>>"$LOG_FILE")
    local ret=$?

    if [ $ret -eq 0 ] && [ -n "$args" ]; then
        mkdir -p "$(dirname "$cache_file")"
        printf '%s' "$args" > "$cache_file"
        log "PO token generated successfully (cached to $cache_file)."
        # The python script returns the value for extractor-args.
        # We need to prepend the flag.
        echo "--extractor-args"
        echo "$args"
        return 0
    fi

    log "WARNING: PO token generation failed (exit=$ret) or returned empty; falling back to alternative player clients."
    return 1
}

# Function to download YouTube video
download_youtube() {
    # Check for history-only mode
    if [ "$QUALITY" = "history" ]; then
        log "=== YOUTUBE HISTORY UPDATE ONLY ==="
        log "URL: $URL"
        
        # Get title first for the output
        VIDEO_TITLE=$("$YTDLP_PATH" --cookies "$COOKIES_FILE" --get-title "$URL" 2>/dev/null)
        
        log "Updating watch history for: $VIDEO_TITLE"
        
        "$YTDLP_PATH" \
            --cookies "$COOKIES_FILE" \
            --mark-watched \
            --simulate \
            "$URL" >> "$LOG_FILE" 2>&1
            
        local ret=$?
        if [ $ret -eq 0 ]; then
            log "SUCCESS: Watch history updated"
            echo "{\"title\": $(json_escape "$VIDEO_TITLE"), \"status\": \"success\", \"action\": \"history_update\", \"video_source_url\": $(json_escape "$URL"), \"platform\": \"youtube\"}"
            exit 0
        else
            log "ERROR: Failed to update watch history"
            echo "{\"status\": \"error\", \"message\": \"Failed to update watch history\", \"video_source_url\": $(json_escape "$URL"), \"platform\": \"youtube\"}"
            exit 1
        fi
    fi

    log "=== YOUTUBE DOWNLOAD STARTED ==="
    log "URL: $URL"
    log "Quality: ${QUALITY:-best} ($(get_quality_label "$QUALITY"))"
    log "Format selector: $FORMAT_SELECTOR"
    log "download dir: $DOWNLOAD_DIR"    
    # PO token（缓存或新生成）；失败时降级到替代 player_client（A1）
    local po_extra_flag="" po_extra_val=""
    {
        read -r po_extra_flag
        read -r po_extra_val
    } < <(get_po_token_args)

    if [ -n "$po_extra_flag" ] && [ -n "$po_extra_val" ]; then
        log "Using PO Token args: $po_extra_val"
    else
        log "Proceeding without PO Token; using alternative player clients fallback: default,tv,ios,web_embedded"
        po_extra_flag="--extractor-args"
        po_extra_val="youtube:player_client=default,tv,ios,web_embedded"
    fi

    # Execute download
    "$YTDLP_PATH" \
        ${po_extra_flag:+"$po_extra_flag"} ${po_extra_val:+"$po_extra_val"} \
        --cookies "$COOKIES_FILE" \
        --remote-components ejs:github \
        -f "$FORMAT_SELECTOR" \
        --write-sub \
        --write-auto-sub \
        --sub-lang "zh,zh-Hans,zh-CN,en" \
        --sub-format "srt" \
        --embed-subs \
        --embed-metadata \
        --add-metadata \
        --replace-in-metadata title "\\s+$" "" \
        --replace-in-metadata title "\\s+" "_" \
        --replace-in-metadata title "[,!，！]+" "" \
        --replace-in-metadata title "[|｜]+" "" \
        --replace-in-metadata title "[;]+" "" \
        --replace-in-metadata title "[?]+" "" \
        --replace-in-metadata title "[.]+" "" \
        --replace-in-metadata title "[#]+" "" \
        --replace-in-metadata title '[<>]+' "" \
        --replace-in-metadata title '[:]+' "" \
        --replace-in-metadata title '["]+' "" \
        --replace-in-metadata title '[/]+' "" \
        --replace-in-metadata title '[\\]+' "" \
        --replace-in-metadata title '[*]+' "" \
        --replace-in-metadata title "[\x00-\x1F]+" "" \
        --replace-in-metadata title "[\\u3001-\\u303F\\uFF01-\\uFF60\\uFFE0-\\uFFEE]+" "" \
        --no-progress \
        --mark-watched \
        -o "$DOWNLOAD_DIR/%(title).120B_$(get_quality_label "$QUALITY")_${TIMESTAMP}.%(ext)s" \
	"$URL" >> "$LOG_FILE" 2>&1
    local ret=$?
    log "yt-dlp exited with code: $ret"
    log "=== YOUTUBE DOWNLOAD DONE" 
    return $ret
}

# Function to download Bilibili video
# NOTE: bilibili 下载逻辑原先被误放进 download_youtube 的 return 之后（死代码），
# 导致 download_bilibili 从未被定义、bilibili 下载一直失败；此处提取为独立函数。
download_bilibili() {
    log "Format selector: $FORMAT_SELECTOR"
    
    # Determine progress and output options based on silent mode
    if [ "$SILENT_MODE" = "progress" ]; then
        log "Running in interactive mode - showing progress"
        log "📺 开始下载 Bilibili 视频..."
    else
        # Default to silent mode for Bilibili
        log "Running in silent mode - no progress display"
        log "🔇 运行在静默模式 - 查看日志: tail -f $LOG_FILE"
    fi

    # Build base command as an array to avoid word-splitting
    local -a yt_cmd=("$YTDLP_PATH")
    if [ ${#COOKIES_OPTION[@]} -gt 0 ]; then
        yt_cmd+=("${COOKIES_OPTION[@]}")
    fi
    
    # Execute download
    if [ "$SILENT_MODE" != "progress" ]; then
        "${yt_cmd[@]}" \
            -f "$FORMAT_SELECTOR" \
            --write-sub \
            --write-auto-sub \
            --sub-lang "zh-Hans,zh-Hant,zh,en" \
            --sub-format "srt" \
            --embed-subs \
            --embed-metadata \
            --add-metadata \
            --replace-in-metadata title "\\s+$" "" \
            --replace-in-metadata title "\\s+" "_" \
            --replace-in-metadata title "[,!，！]+" "" \
            --replace-in-metadata title "[|｜]+" "" \
            --replace-in-metadata title "[;；]+" "" \
            --replace-in-metadata title "[?？]+" "" \
            --replace-in-metadata title "[.。]+" "" \
            --replace-in-metadata title "[#]+" "" \
            --replace-in-metadata title '[<>《》]+' "" \
            --replace-in-metadata title '[:：]+' "" \
            --replace-in-metadata title '["「」"]+' "" \
            --replace-in-metadata title '[/／]+' "" \
            --replace-in-metadata title '[\\]+' "" \
            --replace-in-metadata title '[*]+' "" \
            --replace-in-metadata title "[\x00-\x1F]+" "" \
            --replace-in-metadata title "[\\u3001-\\u303F\\uFF01-\\uFF60\\uFFE0-\\uFFEE]+" "" \
            --no-progress \
            --extractor-args "bilibili:sessdata=" \
            -o "$DOWNLOAD_DIR/%(title).120B_$(get_quality_label "$QUALITY")_${TIMESTAMP}.%(ext)s" \
            "$URL" >> "$LOG_FILE" 2>&1
    else
        "${yt_cmd[@]}" \
            -f "$FORMAT_SELECTOR" \
            --write-sub \
            --write-auto-sub \
            --sub-lang "zh-Hans,zh-Hant,zh,en" \
            --sub-format "srt" \
            --embed-subs \
            --embed-metadata \
            --add-metadata \
            --replace-in-metadata title "\\s+$" "" \
            --replace-in-metadata title "\\s+" "_" \
            --replace-in-metadata title "[,!，！]+" "" \
            --replace-in-metadata title "[|｜]+" "" \
            --replace-in-metadata title "[;；]+" "" \
            --replace-in-metadata title "[?？]+" "" \
            --replace-in-metadata title "[.。]+" "" \
            --replace-in-metadata title "[#]+" "" \
            --replace-in-metadata title '[<>《》]+' "" \
            --replace-in-metadata title '[:：]+' "" \
            --replace-in-metadata title '["「」"]+' "" \
            --replace-in-metadata title '[/／]+' "" \
            --replace-in-metadata title '[\\]+' "" \
            --replace-in-metadata title '[*]+' "" \
            --replace-in-metadata title "[\x00-\x1F]+" "" \
            --replace-in-metadata title "[\\u3001-\\u303F\\uFF01-\\uFF60\\uFFE0-\\uFFEE]+" "" \
            --progress \
            --extractor-args "bilibili:sessdata=" \
            -o "$DOWNLOAD_DIR/%(title).120B_$(get_quality_label "$QUALITY")_${TIMESTAMP}.%(ext)s" \
            "$URL" 2>&1 | tee -a "$LOG_FILE"
    fi
    log "=== BILIBILI DOWNLOAD DONE===" 
}

# Function to process download results
process_download_result() {
    local platform="$1"
    local exit_code="$2"
    local quality_label
    quality_label=$(get_quality_label "$QUALITY")
    
    if [ "$exit_code" -eq 0 ]; then
        log "=== DOWNLOAD COMPLETED ==="
        log "SUCCESS: $platform download completed"
        
        # Find the downloaded files
        log "Searching for downloaded files with quality: ${quality_label}, timestamp: ${TIMESTAMP}"
        log "Search directory: $DOWNLOAD_DIR"
        log "Search pattern: *_${quality_label}_${TIMESTAMP}.*"
        
        # List all files in download directory for debugging
        log "All files in download directory:"
        find "$DOWNLOAD_DIR" -type f -name "*${TIMESTAMP}*" | while read -r file; do
            log "Found file: $file"
        done
        
        DOWNLOADED_VIDEO=$(find "$DOWNLOAD_DIR" -name "*_${quality_label}_${TIMESTAMP}.*" -type f | grep -E '\.(mp4|mkv|avi|flv|webm)$' | head -1)
        DOWNLOADED_SUBTITLES=$(find "$DOWNLOAD_DIR" -name "*_${quality_label}_${TIMESTAMP}.*" -type f | grep -E '\.(srt|vtt)$')
        
        log "Found video file: $DOWNLOADED_VIDEO"
        log "Found subtitle files: $DOWNLOADED_SUBTITLES"
        
        if [ -n "$DOWNLOADED_VIDEO" ] && [ -f "$DOWNLOADED_VIDEO" ]; then
            # Extract video information
            VIDEO_TITLE=$("$YTDLP_PATH" "${COOKIES_OPTION[@]}" --get-title "$URL" 2>/dev/null)
            
            # Get additional info for Bilibili
            if [ "$platform" = "bilibili" ]; then
                VIDEO_UPLOADER=$("$YTDLP_PATH" "${COOKIES_OPTION[@]}" --get-uploader "$URL" 2>/dev/null)
                log "Video uploader: $VIDEO_UPLOADER"
            fi
            
            log "Video title: $VIDEO_TITLE"
            
            # Get file information
            FILE_SIZE=$(du -h "$DOWNLOADED_VIDEO" | cut -f1)
            FILE_NAME=$(basename "$DOWNLOADED_VIDEO")
            FILE_PATH="$DOWNLOADED_VIDEO"
            
            log "Downloaded video: $FILE_NAME (Quality: $quality_label)"
            log "Video size: $FILE_SIZE"
            log "Video path: $FILE_PATH"
            
            # Save the original source URL into the file metadata using exiftool if available
            # - Title: original video title followed by the source URL
            # - XMP:Description / XMP:Identifier / XMP:WebStatement: store the original URL in standard XMP fields
            if command -v exiftool >/dev/null 2>&1; then
                log "Saving original URL to metadata via exiftool..."
                exiftool -overwrite_original \
                    -Title="$VIDEO_TITLE $URL" \
                    -XMP:Description="$URL" \
                    -XMP:Identifier="$URL" \
                    -XMP:WebStatement="$URL" \
                    "$FILE_PATH" >> "$LOG_FILE" 2>&1 && log "exiftool metadata update succeeded"
            else
                log "exiftool not available; skipping metadata overwrite"
            fi


            
            # Check for subtitles
            if [ -n "$DOWNLOADED_SUBTITLES" ]; then
                log "Subtitles found:"
                for sub in $DOWNLOADED_SUBTITLES; do
                    SUB_NAME=$(basename "$sub")
                    SUB_SIZE=$(du -h "$sub" | cut -f1)
                    # Prepend a UTF-8 BOM so players detect the encoding instead of showing boxes
                    if [ -f "$sub" ] && [ "$(head -c 3 "$sub")" != "$(printf '\xef\xbb\xbf')" ]; then
                        printf '\xef\xbb\xbf' | cat - "$sub" > "$sub.tmp" && mv "$sub.tmp" "$sub"
                    fi
                    log "  - $SUB_NAME ($SUB_SIZE)"
                done
            else
                log "No separate subtitle files found (may be embedded)"
            fi
            
            DOWNLOAD_HTTP_URL="https://files.jackspark.top/$(url_encode "$FILE_NAME")"
            
            # Return file information
            log "SUCCESS: Download completed"
            log "Video: $FILE_NAME"
            log "Size: $FILE_SIZE"
            log "Path: $FILE_PATH"
            log "Title: $VIDEO_TITLE"
            log "DOWNLOAD HTTP URL: $DOWNLOAD_HTTP_URL"
            # log "SMB Path: //47.128.3.198/YoutubeDownload/$FILE_NAME"

            # Upload to iCloud Drive
            upload_to_icloud "$DOWNLOADED_VIDEO"
            
            # Create a Reminder containing the download link (best-effort)
            create_reminder_for_link "$DOWNLOAD_HTTP_URL"

            # Generate platform-independent JSON output (original url, video title, download url)
            echo "{"
            echo "  \"video_source_url\": $(json_escape "$URL"),"
            echo "  \"title\": $(json_escape "$VIDEO_TITLE"),"
            echo "  \"download_link\": $(json_escape "$DOWNLOAD_HTTP_URL")"
            echo "}"
            exit 0
        else
            log "ERROR: Downloaded video file not found with pattern *_${quality_label}_${TIMESTAMP}.*"
            log "Trying alternative search patterns..."
            
            # Try broader search patterns
            DOWNLOADED_VIDEO=$(find "$DOWNLOAD_DIR" -name "*${TIMESTAMP}*" -type f | grep -E '\.(mp4|mkv|avi|webm|flv)$' | head -1)
            
            if [ -n "$DOWNLOADED_VIDEO" ] && [ -f "$DOWNLOADED_VIDEO" ]; then
                log "Found video with broader search: $DOWNLOADED_VIDEO"
                # Continue with the same processing logic
                VIDEO_TITLE=$("$YTDLP_PATH" "${COOKIES_OPTION[@]}" --get-title "$URL" 2>/dev/null)
                if [ "$platform" = "bilibili" ]; then
                    VIDEO_UPLOADER=$("$YTDLP_PATH" "${COOKIES_OPTION[@]}" --get-uploader "$URL" 2>/dev/null)
                fi
                FILE_SIZE=$(du -h "$DOWNLOADED_VIDEO" | cut -f1)
                FILE_NAME=$(basename "$DOWNLOADED_VIDEO")
                FILE_PATH="$DOWNLOADED_VIDEO"
                
                log "Downloaded video: $FILE_NAME (Quality: $quality_label)"
                log "Video size: $FILE_SIZE"
                log "Video path: $FILE_PATH"
                
                DOWNLOAD_HTTP_URL="https://files.jackspark.top/$(url_encode "$FILE_NAME")"

                # Upload to iCloud Drive
                upload_to_icloud "$DOWNLOADED_VIDEO"
                
                # Create a Reminder containing the download link (best-effort)
                create_reminder_for_link "$DOWNLOAD_HTTP_URL"

                # Generate platform-independent JSON output (original url, video title, download url)
                echo "{"
                echo "  \"video_source_url\": $(json_escape "$URL"),"
                echo "  \"title\": $(json_escape "$VIDEO_TITLE"),"
                echo "  \"download_link\": $(json_escape "$DOWNLOAD_HTTP_URL")"
                echo "}"
                exit 0
            else
                log "ERROR: Downloaded video file not found even with broader search"
                log "All files in download directory:"
                find "$DOWNLOAD_DIR" -maxdepth 1 -mindepth 1 | while read -r line; do
                    log "$line"
                done
                echo "ERROR: Downloaded video file not found"
                exit 1
            fi
        fi
    else
        log "=== DOWNLOAD FAILED ==="
        log "ERROR: $platform download failed (exit code: $exit_code)"
        echo "ERROR: $platform download failed (exit code: $exit_code)"
        if [ "$platform" = "bilibili" ]; then
            echo "This might be due to:"
            echo "1. Missing or invalid cookies file"
            echo "2. Private or restricted video"
            echo "3. Network connectivity issues"
            echo "4. Invalid video URL"
        fi
        exit 1
    fi
}

# Main function
# Reproduce yt-dlp's --replace-in-metadata title sanitization, then truncate to 120 bytes
# at a character boundary (yt-dlp's .120B rounds down, never leaves a partial char).
sanitize_title() {
    printf '%s' "$1" | perl -CSD -pe 's/\s+$//; s/\s+/_/g; s/[,!，！]+//g; s/[|｜]+//g; s/[;]+//g; s/[?]+//g; s/[.]+//g; s/[#]+//g; s/[<>]+//g; s/[:]+//g; s/["]+//g; s|[/]+||g; s/[\\]+//g; s/[*]+//g; s/[\x00-\x1F]+//g; s/[\x{3001}-\x{303F}\x{FF01}-\x{FF60}\x{FFE0}-\x{FFEE}]+//g' | "$PYTHON_CMD" -c '
import sys
b = sys.stdin.buffer.read().decode("utf-8").encode("utf-8")[:120]
while True:
    try:
        sys.stdout.buffer.write(b.decode("utf-8").encode("utf-8"))
        break
    except UnicodeDecodeError:
        b = b[:-1]
'
}

# Async flow: resolve metadata, emit the 3-field JSON immediately, then run the real download in the background with the same timestamp.
async_download_and_exit() {
    local quality_label
    quality_label=$(get_quality_label "$QUALITY")

    local po_token_flag="" po_token_val=""
    {
        read -r po_token_flag
        read -r po_token_val
    } < <(get_po_token_args)

    local out_template="$DOWNLOAD_DIR/%(title).120B_${quality_label}_${TIMESTAMP}.%(ext)s"

    # One metadata pass: raw (pretty) title + output filename (for the extension)
    local meta_out
    meta_out=$("$YTDLP_PATH" \
        ${po_token_flag:+"$po_token_flag"} ${po_token_val:+"$po_token_val"} \
        --cookies "$COOKIES_FILE" \
        -f "$FORMAT_SELECTOR" \
        --simulate \
        --print "%(title)s" \
        --print "%(filename)s" \
        -o "$out_template" \
        "$URL" 2>>"$LOG_FILE")
    if [ -z "$meta_out" ]; then
        echo "ERROR: could not resolve video metadata"
        exit 1
    fi

    local raw_title
    raw_title=$(printf '%s\n' "$meta_out" | sed -n '1p')
    local file_path
    file_path=$(printf '%s\n' "$meta_out" | sed -n '2p')
    local out_ext
    out_ext=$(basename "$file_path" | grep -oE '\.[a-zA-Z0-9]+$' | head -1)

    # Reproduce the script's --replace-in-metadata title sanitization, then truncate to 120 bytes like yt-dlp's .120B
    local sanitized
    sanitized=$(sanitize_title "$raw_title")

    local file_name="${sanitized}_${quality_label}_${TIMESTAMP}${out_ext}"

    local download_http_url
    download_http_url="https://files.jackspark.top/$(url_encode "$file_name")"

    echo "{"
    echo "  \"video_source_url\": $(json_escape "$URL"),"
    echo "  \"title\": $(json_escape "$raw_title"),"
    echo "  \"download_link\": $(json_escape "$download_http_url")"
    echo "}"

    log "ASYNC: metadata resolved, background download starting for $file_name"
    DOWNLOAD_TS="$TIMESTAMP" setsid nohup "${BASH_SOURCE[0]}" "$ORIGINAL_URL" "$QUALITY" "$SILENT_MODE" "$LOCAL_MODE" >> "$LOG_FILE" 2>&1 < /dev/null &
    disown 2>/dev/null || true

    exit 0
}

main() {
    # Check if parameters are provided
    if [ $# -eq 0 ]; then
        echo "Universal Video Downloader (YouTube & Bilibili)"
        echo "Usage: $0 <Video_URL> [quality] [mode]"
        echo ""
        echo "Quality options:"
        echo "  1 or 360p - Up to 360p quality (small file size)"
        echo "  2 or 720p - Up to 720p quality (balanced)"
        echo "  3 or 1080p - Up to 1080p quality (high quality)"
        echo "  4 or 4k - Up to 4K quality (highest quality) - Bilibili only"
        echo "  history - 仅更新播放历史，不下载 (Update watch history only)"
        echo "  (no parameter) - Best available quality"
        echo ""
        echo "Mode options (Bilibili only):"
        echo "  silent - 静默模式 (无进度显示，默认模式)"
        echo "  progress - 前台模式 (显示下载进度)"
        echo "  注意: Bilibili默认使用静默模式，如需显示进度请使用 'progress'"
        echo ""
        echo "Examples:"
        echo "  $0 \"https://www.youtube.com/watch?v=Z99Njl3Fra0\" 720p"
        echo "  $0 \"https://www.bilibili.com/video/BV1xx411c7mD\" 2 silent"
        echo "  $0 \"https://youtu.be/Z99Njl3Fra0\""
        echo "  $0 \"https://www.bilibili.com/video/BV1xx411c7mD\""
        echo "  $0 \"https://b23.tv/abc123\""
        echo "  $0 \"https://www.youtube.com/watch?v=KPdD-GeoFk8\""
        echo ""
        echo "Supported platforms: YouTube (youtu), Bilibili (bilibili.com, b23.tv)"
        exit 1
    elif [ $# -eq 1 ]; then
        QUALITY=""
        SILENT_MODE=""
    elif [ $# -eq 2 ]; then
        SILENT_MODE=""
    fi
    
    # Clean and extract valid URL
    ORIGINAL_URL="$URL"
    URL=$(clean_url "$URL")

    # Detect platform from URL
    PLATFORM=$(detect_platform "$URL")

    if [ "$PLATFORM" = "unknown" ]; then
        echo "ERROR: Unsupported platform. Please provide a YouTube or Bilibili URL."
        echo "Supported platforms:"
        echo "  - YouTube: URLs containing 'youtu'"
        echo "  - Bilibili: URLs containing 'bilibili.com' or 'b23.tv'"
        exit 1
    fi

    # Setup platform-specific configurations (must be before any log() call)
    setup_platform_config "$PLATFORM"

    # Log URL cleaning if changed
    if [ "$ORIGINAL_URL" != "$URL" ]; then
        log "🧹 Cleaned URL: $ORIGINAL_URL -> $URL"
    fi
    
    # Force silent mode for Bilibili if not explicitly set
    if [ "$PLATFORM" = "bilibili" ] && [ "$SILENT_MODE" != "silent" ] && [ -z "$SILENT_MODE" ]; then
        SILENT_MODE="silent"
        log "🔇 Bilibili下载使用静默模式（无进度显示）"
    fi
    
    # Check prerequisites
    check_prerequisites "$PLATFORM"

    # Async mode: return the 3-field JSON after metadata, download in the background
    if [ "$ASYNC_MODE" = "async" ]; then
        async_download_and_exit
    fi
    
    # Download based on platform
    case "$PLATFORM" in
        "youtube")
            download_youtube
            DOWNLOAD_EXIT_CODE=$?
            ;;
        "bilibili")
            download_bilibili
            DOWNLOAD_EXIT_CODE=$?
            ;;
    esac
    
    # Process results
    process_download_result "$PLATFORM" "$DOWNLOAD_EXIT_CODE"
}

# Run main only when the script is executed directly, so tests can source it to reach the helper functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
