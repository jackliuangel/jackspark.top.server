#!/bin/bash

# File cleanup script - Delete files older than specified hours
# Used for cleaning temporary download files

# Configuration variables
TARGET_DIR="/tmp/video_download/congliulyc@gmail.com"
LOG_FILE="/var/log/cleanup_old_files.log"
MAX_AGE_HOURS=72
SLEEP_HOURS=1  # Execute every 2 hours

# Log function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Main loop
while true; do
    # Check if target directory exists
    if [ ! -d "$TARGET_DIR" ]; then
        log_message "ERROR: Target directory $TARGET_DIR does not exist"
        sleep ${SLEEP_HOURS}h
        continue
    fi

    # Log start of cleanup
    log_message "Starting cleanup of files older than ${MAX_AGE_HOURS} hour(s) in $TARGET_DIR"

    # Count files before cleanup
    files_before=$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l)
    log_message "Files before cleanup: $files_before"

    # Find and delete files older than specified time
    deleted_count=0
    deleted_files=""

    # Use find command to locate and delete files
    while IFS= read -r -d '' file; do
        if [ -f "$file" ]; then
            # Get file creation time (using stat command)
            file_creation_time=$(stat -c %W "$file" 2>/dev/null || stat -f %B "$file" 2>/dev/null)
            current_time=$(date +%s)
            file_age_hours=$(( (current_time - file_creation_time) / 3600 ))
            
            if [ "$file_age_hours" -gt "$MAX_AGE_HOURS" ]; then
                if rm -f "$file"; then
                    deleted_count=$((deleted_count + 1))
                    deleted_files="$deleted_files$(basename "$file") "
                    log_message "Deleted: $(basename "$file") (age: ${file_age_hours} hour(s))"
                else
                    log_message "Failed to delete: $(basename "$file")"
                fi
            fi
        fi
    done < <(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type f -print0)

    # Count files after cleanup
    files_after=$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l)

    # Log cleanup results
    log_message "Cleanup completed:"
    log_message "  - Files deleted: $deleted_count"
    log_message "  - Files remaining: $files_after"
    log_message "  - Directory size: $(du -sh "$TARGET_DIR" 2>/dev/null | cut -f1)"

    # If files were deleted, log details
    if [ "$deleted_count" -gt 0 ]; then
        log_message "Deleted files list: $deleted_files"
    fi


    log_message "Cleanup task completed, waiting ${SLEEP_HOURS} hour(s) before next execution"
    echo "---" >> "$LOG_FILE"
    
    # Sleep for specified time
    sleep ${SLEEP_HOURS}h
done 
