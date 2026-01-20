#!/system/bin/sh
# NoMount Universal Hijacker - monitor.sh
# Watches for module changes: new installs, disables, removes, and file changes
# Critical for proper restoration when debloat modules remove whiteouts
# NOTE: Uses /system/bin/sh for `local` keyword support (mksh on Android)

MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR="."
PROP_FILE="$MODDIR/module.prop"
MODULES_DIR="/data/adb/modules"
NOMOUNT_DATA="/data/adb/nomount"
LOG_FILE="$NOMOUNT_DATA/nomount.log"
CONFIG_FILE="$NOMOUNT_DATA/config.sh"
PID_FILE="$NOMOUNT_DATA/.monitor.pid"

# ============================================================
# FUNCTION: Find nm binary dynamically
# Checks multiple possible locations for flexibility
# ============================================================
find_nm_binary() {
    local possible_paths="
        $MODDIR/bin/nm
        $MODDIR/nm-arm64
        $MODDIR/nm
        /data/adb/modules/nomount/bin/nm
        /data/adb/modules/nomount/nm-arm64
        /data/adb/modules/nomount/nm
    "
    for path in $possible_paths; do
        if [ -x "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

LOADER=$(find_nm_binary)
if [ -z "$LOADER" ]; then
    echo "[$(date '+%H:%M:%S')] [MONITOR] [ERROR] nm binary not found!" >> "$LOG_FILE"
    exit 1
fi
# Match partition list with service.sh
TARGET_PARTITIONS="system vendor product system_ext odm oem mi_ext my_heytap prism optics oem_dlkm system_dlkm vendor_dlkm"

# Directory to track registered paths per module
TRACKING_DIR="$NOMOUNT_DATA/module_paths"
mkdir -p "$TRACKING_DIR" 2>/dev/null

# Cleanup function for signal handling
cleanup() {
    echo "[$(date '+%H:%M:%S')] [MONITOR] [INFO] Cleanup triggered, removing PID file and temp files" >> "$LOG_FILE"
    # Kill inotifywait subprocess if running
    if [ -n "$INOTIFY_PID" ] && kill -0 "$INOTIFY_PID" 2>/dev/null; then
        kill "$INOTIFY_PID" 2>/dev/null
        echo "[$(date '+%H:%M:%S')] [MONITOR] [DEBUG] Killed inotifywait subprocess (PID $INOTIFY_PID)" >> "$LOG_FILE"
    fi
    rm -f "$PID_FILE" "$NOMOUNT_DATA/.sync_tmp_"* "$NOMOUNT_DATA/.sync_update_tmp_"* 2>/dev/null
}
trap cleanup EXIT INT TERM HUP

# Check for existing monitor instance using atomic write-then-check pattern
# Write our PID first to a temp file
echo $$ > "$PID_FILE.$$"

# Check if another instance exists
if [ -f "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$old_pid" ] && [ "$old_pid" != "$$" ] && kill -0 "$old_pid" 2>/dev/null; then
        rm -f "$PID_FILE.$$"
        echo "[MONITOR] Already running (PID $old_pid), exiting" >> "$LOG_FILE"
        exit 0
    fi
fi

# Atomic rename (on same filesystem, this is atomic)
mv "$PID_FILE.$$" "$PID_FILE"

# ============================================================
# LOGGING FUNCTIONS - Comprehensive error tracking
# ============================================================
LOG_LEVEL="${LOG_LEVEL:-2}"  # 0=off, 1=error, 2=info, 3=debug

log_err() {
    [ "$LOG_LEVEL" -ge 1 ] && echo "[$(date '+%H:%M:%S')] [MONITOR] [ERROR] $*" >> "$LOG_FILE"
}

log_info() {
    [ "$LOG_LEVEL" -ge 2 ] && echo "[$(date '+%H:%M:%S')] [MONITOR] [INFO] $*" >> "$LOG_FILE"
}

log_debug() {
    [ "$LOG_LEVEL" -ge 3 ] && echo "[$(date '+%H:%M:%S')] [MONITOR] [DEBUG] $*" >> "$LOG_FILE"
}

# ============================================================
# FUNCTION: Check if inotifywait is available
# Returns 0 if available, 1 otherwise
# ============================================================
has_inotify() {
    command -v inotifywait >/dev/null 2>&1
}

# inotifywait PID for cleanup (global for signal handler access)
INOTIFY_PID=""

MODULE_COUNT="$1"
HIJACKED_COUNT="$2"

[ -z "$MODULE_COUNT" ] && MODULE_COUNT=0
[ -z "$HIJACKED_COUNT" ] && HIJACKED_COUNT=0

log_info "Monitor starting (PID: $$)"
log_info "Initial state: MODULE_COUNT=$MODULE_COUNT, HIJACKED_COUNT=$HIJACKED_COUNT"

# Load config with security checks
monitor_new_modules=true
excluded_modules=""
if [ -f "$CONFIG_FILE" ]; then
    config_owner=$(stat -c '%u' "$CONFIG_FILE" 2>/dev/null)
    config_perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null)
    if [ "$config_owner" = "0" ] && [ "${config_perms#*2}" = "$config_perms" ]; then
        log_debug "Loading config from $CONFIG_FILE (owner=$config_owner, perms=$config_perms)"
        . "$CONFIG_FILE"
        log_info "Config loaded: monitor_new_modules=$monitor_new_modules"
    else
        log_err "Config file security check failed (owner=$config_owner, perms=$config_perms)"
    fi
else
    log_debug "No config file found at $CONFIG_FILE, using defaults"
fi

BASE_DESC="Universal Hijacker - VFS path redirection replaces all mounts"

# Build status string (use actual newline for Magisk Manager)
update_status() {
    if [ "$MODULE_COUNT" -gt 0 ]; then
        if [ "$HIJACKED_COUNT" -gt 0 ]; then
            STATUS="⚡🔥 [VFS: $MODULE_COUNT modules | $HIJACKED_COUNT hijacked] "
        else
            STATUS="⚡ [VFS: $MODULE_COUNT modules active] "
        fi
    else
        STATUS="⚠️ [Idle: No modules found] "
    fi
    log_debug "Updating status: $STATUS"
    # Portable sed without -i: write to temp then move
    if sed "s|^description=.*|description=$STATUS$BASE_DESC|" "$PROP_FILE" > "$PROP_FILE.tmp" && mv "$PROP_FILE.tmp" "$PROP_FILE"; then
        log_debug "Status updated successfully in module.prop"
    else
        log_err "Failed to update status in module.prop"
    fi
}

update_status

# ============================================================
# FUNCTION: Check if module is excluded
# ============================================================
is_excluded() {
    if echo "$excluded_modules" | grep -qw "$1"; then
        log_debug "Module '$1' is in exclusion list"
        return 0
    fi
    return 1
}

# ============================================================
# FUNCTION: Unregister all VFS paths for a module
# Called when module is disabled/removed
# ============================================================
unregister_module() {
    local mod_name="$1"
    local tracking_file="$TRACKING_DIR/$mod_name"

    log_info "Unregister request for module: $mod_name"

    if [ ! -f "$tracking_file" ]; then
        log_debug "No tracking file for $mod_name, nothing to unregister"
        return
    fi

    log_info "Unregistering module: $mod_name"

    local count=0
    local failed=0
    while IFS= read -r virtual_path; do
        [ -z "$virtual_path" ] && continue
        if "$LOADER" del "$virtual_path" < /dev/null 2>/dev/null; then
            count=$((count + 1))
            log_debug "Removed VFS rule: $virtual_path"
        else
            failed=$((failed + 1))
            log_err "Failed to remove VFS rule: $virtual_path"
        fi
    done < "$tracking_file"

    log_info "Removed $count VFS rules for $mod_name (failed: $failed)"
    rm -f "$tracking_file"

    # Remove skip_mount if we injected it
    local mod_path="$MODULES_DIR/$mod_name"
    if grep -q "^$mod_name$" "$NOMOUNT_DATA/skipped_modules" 2>/dev/null; then
        rm -f "$mod_path/skip_mount" 2>/dev/null
        # Portable sed without -i
        grep -v "^$mod_name$" "$NOMOUNT_DATA/skipped_modules" > "$NOMOUNT_DATA/skipped_modules.tmp" 2>/dev/null
        mv "$NOMOUNT_DATA/skipped_modules.tmp" "$NOMOUNT_DATA/skipped_modules" 2>/dev/null
        log_info "Removed skip_mount for $mod_name"
    fi

    MODULE_COUNT=$((MODULE_COUNT - 1))
    [ "$MODULE_COUNT" -lt 0 ] && MODULE_COUNT=0
    log_debug "Updated MODULE_COUNT to $MODULE_COUNT"
    update_status
}

# ============================================================
# FUNCTION: Register a module's files via VFS
# Tracks all registered paths for later cleanup
# ============================================================
register_module() {
    local mod_path="$1"
    local mod_name=$(basename "$mod_path")
    local tracking_file="$TRACKING_DIR/$mod_name"

    log_info "Registering module: $mod_name (path: $mod_path)"

    # Clear old tracking
    : > "$tracking_file"

    local partition_count=0
    for partition in $TARGET_PARTITIONS; do
        if [ -d "$mod_path/$partition" ]; then
            partition_count=$((partition_count + 1))
            log_debug "Processing partition: $partition"
            (
                cd "$mod_path" || exit
                find "$partition" -type f -o -type c 2>/dev/null | while read -r relative_path; do
                    real_path="$mod_path/$relative_path"
                    virtual_path="/$relative_path"

                    if [ -c "$real_path" ]; then
                        # Whiteout - map to nonexistent to hide original
                        if "$LOADER" add "$virtual_path" "/nonexistent" < /dev/null 2>/dev/null; then
                            echo "[$(date '+%H:%M:%S')] [MONITOR] [DEBUG] Added whiteout: $virtual_path" >> "$LOG_FILE"
                        else
                            echo "[$(date '+%H:%M:%S')] [MONITOR] [ERROR] nm add failed for whiteout: $virtual_path" >> "$LOG_FILE"
                        fi
                    else
                        if "$LOADER" add "$virtual_path" "$real_path" < /dev/null 2>/dev/null; then
                            echo "[$(date '+%H:%M:%S')] [MONITOR] [DEBUG] Added file mapping: $virtual_path -> $real_path" >> "$LOG_FILE"
                        else
                            echo "[$(date '+%H:%M:%S')] [MONITOR] [ERROR] nm add failed: $virtual_path -> $real_path" >> "$LOG_FILE"
                        fi
                    fi

                    # Track this path
                    echo "$virtual_path" >> "$tracking_file"
                done
            )
        fi
    done

    local count=$(wc -l < "$tracking_file" 2>/dev/null || echo 0)
    log_info "Registered $count paths from $partition_count partitions for $mod_name"
}

# ============================================================
# FUNCTION: Sync module files - detect added/removed files
# Critical for debloat modules that add/remove whiteouts
# ============================================================
sync_module_files() {
    local mod_path="$1"
    local mod_name=$(basename "$mod_path")
    local tracking_file="$TRACKING_DIR/$mod_name"

    if [ ! -f "$tracking_file" ]; then
        log_debug "No tracking file for $mod_name, skipping sync"
        return
    fi

    log_debug "Syncing files for module: $mod_name"

    # Get current files in module (use NOMOUNT_DATA for temp - /tmp doesn't exist on Android)
    local current_files="$NOMOUNT_DATA/.sync_tmp_$$"
    : > "$current_files"  # Ensure file exists and is empty
    for partition in $TARGET_PARTITIONS; do
        if [ -d "$mod_path/$partition" ]; then
            log_debug "Scanning partition $partition for $mod_name"
            (cd "$mod_path" && find "$partition" -type f -o -type c 2>/dev/null) | \
                sed 's|^|/|' >> "$current_files"
        fi
    done

    local current_count=$(wc -l < "$current_files" 2>/dev/null || echo 0)
    local tracked_count=$(wc -l < "$tracking_file" 2>/dev/null || echo 0)
    log_debug "Sync state for $mod_name: current=$current_count, tracked=$tracked_count"

    # Find removed files (in tracking but not in current)
    local removed=0
    local remove_failed=0
    while IFS= read -r tracked_path; do
        [ -z "$tracked_path" ] && continue
        if ! grep -qxF "$tracked_path" "$current_files"; then
            # File was removed from module - remove from VFS
            if "$LOADER" del "$tracked_path" < /dev/null 2>/dev/null; then
                removed=$((removed + 1))
                log_info "Removed stale rule: $tracked_path"
            else
                remove_failed=$((remove_failed + 1))
                log_err "Failed to remove stale rule: $tracked_path"
            fi
        fi
    done < "$tracking_file"

    # Find added files (in current but not in tracking)
    local added=0
    local add_failed=0
    while IFS= read -r current_path; do
        [ -z "$current_path" ] && continue
        if ! grep -qxF "$current_path" "$tracking_file"; then
            # New file in module - register it
            local real_path="$mod_path$current_path"
            local add_result=false
            if [ -c "$real_path" ]; then
                if "$LOADER" add "$current_path" "/nonexistent" < /dev/null 2>/dev/null; then
                    add_result=true
                    log_info "Added new whiteout rule: $current_path"
                fi
            elif [ -f "$real_path" ]; then
                if "$LOADER" add "$current_path" "$real_path" < /dev/null 2>/dev/null; then
                    add_result=true
                    log_info "Added new file rule: $current_path -> $real_path"
                fi
            fi
            if [ "$add_result" = "true" ]; then
                added=$((added + 1))
            else
                add_failed=$((add_failed + 1))
                log_err "Failed to add rule for: $current_path"
            fi
        fi
    done < "$current_files"

    # Update tracking file
    if [ "$removed" -gt 0 ] || [ "$added" -gt 0 ]; then
        cp "$current_files" "$tracking_file"
        log_info "Synced $mod_name: +$added -$removed (add_failed=$add_failed, remove_failed=$remove_failed)"
    else
        log_debug "No changes detected for $mod_name"
    fi

    rm -f "$current_files"
}

# ============================================================
# FUNCTION: Handle new module detection
# ============================================================
handle_new_module() {
    local mod_path="$1"
    local mod_name=$(basename "$mod_path")

    log_info "New module detected: $mod_name (path: $mod_path)"

    if is_excluded "$mod_name"; then
        log_info "Skipping excluded module: $mod_name"
        return
    fi

    # Check if has mountable content
    local has_content=false
    local found_partitions=""
    for partition in $TARGET_PARTITIONS; do
        if [ -d "$mod_path/$partition" ]; then
            has_content=true
            found_partitions="$found_partitions $partition"
        fi
    done

    if [ "$has_content" = "true" ]; then
        log_info "Module $mod_name has mountable content in:$found_partitions"

        # Inject skip_mount
        if [ ! -f "$mod_path/skip_mount" ]; then
            if touch "$mod_path/skip_mount"; then
                echo "$mod_name" >> "$NOMOUNT_DATA/skipped_modules"
                log_info "Injected skip_mount for: $mod_name"
            else
                log_err "Failed to create skip_mount for: $mod_name"
            fi
        else
            log_debug "skip_mount already exists for: $mod_name"
        fi

        register_module "$mod_path"
        MODULE_COUNT=$((MODULE_COUNT + 1))
        log_debug "Updated MODULE_COUNT to $MODULE_COUNT"
        update_status
    else
        log_debug "Module $mod_name has no mountable content, ignoring"
    fi
}

# ============================================================
# FUNCTION: Check modules_update for pending changes
# This detects when debloat modules make changes before reboot
# ============================================================
MODULES_UPDATE_DIR="/data/adb/modules_update"
SYNC_TRIGGER_DIR="$NOMOUNT_DATA/sync_trigger"

# Ensure sync_trigger directory exists (for Phase 3 external triggers)
mkdir -p "$SYNC_TRIGGER_DIR" 2>/dev/null

check_pending_updates() {
    # Only check if modules_update exists
    [ ! -d "$MODULES_UPDATE_DIR" ] && return

    local checked=0
    for mod_update in "$MODULES_UPDATE_DIR"/*; do
        [ ! -d "$mod_update" ] && continue
        local mod_name=$(basename "$mod_update")
        [ "$mod_name" = "nomount" ] && continue

        local mod_active="$MODULES_DIR/$mod_name"
        local tracking_file="$TRACKING_DIR/$mod_name"

        # Only check modules we're tracking
        [ ! -f "$tracking_file" ] && continue

        # Check if modules_update has different file content than active module
        # Compare file counts in partition directories as quick heuristic
        for partition in $TARGET_PARTITIONS; do
            local update_count=0
            local active_count=0

            if [ -d "$mod_update/$partition" ]; then
                update_count=$(find "$mod_update/$partition" -type f -o -type c 2>/dev/null | wc -l)
            fi
            if [ -d "$mod_active/$partition" ]; then
                active_count=$(find "$mod_active/$partition" -type f -o -type c 2>/dev/null | wc -l)
            fi

            # If counts differ, there's a pending update - sync based on modules_update
            if [ "$update_count" != "$active_count" ]; then
                log_info "Pending update detected for $mod_name (partition $partition: update=$update_count, active=$active_count)"

                # Sync using modules_update content instead of active module
                sync_module_from_update "$mod_update" "$mod_name"
                checked=$((checked + 1))
                break  # Only sync once per module
            fi
        done
    done

    [ "$checked" -gt 0 ] && log_debug "Checked $checked modules with pending updates"
}

# Sync module using modules_update content (for pending changes)
sync_module_from_update() {
    local update_path="$1"
    local mod_name="$2"
    local tracking_file="$TRACKING_DIR/$mod_name"

    log_info "Syncing $mod_name from pending update..."

    # Get current files in modules_update
    local current_files="$NOMOUNT_DATA/.sync_update_tmp_$$"
    : > "$current_files"
    for partition in $TARGET_PARTITIONS; do
        if [ -d "$update_path/$partition" ]; then
            (cd "$update_path" && find "$partition" -type f -o -type c 2>/dev/null) | \
                sed 's|^|/|' >> "$current_files"
        fi
    done

    # Find removed files (in tracking but not in pending update)
    local removed=0
    while IFS= read -r tracked_path; do
        [ -z "$tracked_path" ] && continue
        if ! grep -qxF "$tracked_path" "$current_files"; then
            # File will be removed after reboot - remove VFS rule now
            if "$LOADER" del "$tracked_path" < /dev/null 2>/dev/null; then
                removed=$((removed + 1))
                log_info "Pre-removed rule for pending deletion: $tracked_path"
            else
                log_err "Failed to pre-remove rule: $tracked_path"
            fi
        fi
    done < "$tracking_file"

    rm -f "$current_files"

    if [ "$removed" -gt 0 ]; then
        log_info "Pre-synced $mod_name: removed $removed rules for pending deletions"
    fi
}

# ============================================================
# FUNCTION: Handle inotify event
# Processes a single inotify event and triggers appropriate action
# ============================================================
handle_inotify_event() {
    local path="$1"
    local event="$2"

    log_debug "inotify event: $event on $path"

    # Determine which watch directory this belongs to
    case "$path" in
        "$MODULES_DIR"*)
            # Module directory change
            local mod_name=$(echo "$path" | sed "s|^$MODULES_DIR/||" | cut -d'/' -f1)
            [ -z "$mod_name" ] && return
            [ "$mod_name" = "nomount" ] && return

            local mod_path="$MODULES_DIR/$mod_name"

            case "$event" in
                *CREATE*|*MOVED_TO*)
                    # New module or file added
                    if [ -d "$mod_path" ] && [ ! -f "$mod_path/disable" ] && [ ! -f "$mod_path/remove" ]; then
                        if [ ! -f "$TRACKING_DIR/$mod_name" ]; then
                            log_info "inotify: New module detected: $mod_name"
                            handle_new_module "$mod_path"
                        else
                            # File added to existing module
                            log_debug "inotify: File change in $mod_name, syncing..."
                            sync_module_files "$mod_path"
                        fi
                    fi
                    # Check for disable/remove markers
                    if [ -f "$mod_path/disable" ] && [ -f "$TRACKING_DIR/$mod_name" ]; then
                        log_info "inotify: Module disabled: $mod_name"
                        unregister_module "$mod_name"
                    elif [ -f "$mod_path/remove" ] && [ -f "$TRACKING_DIR/$mod_name" ]; then
                        log_info "inotify: Module marked for removal: $mod_name"
                        unregister_module "$mod_name"
                    fi
                    ;;
                *DELETE*|*MOVED_FROM*)
                    # Module or file removed
                    if [ ! -d "$mod_path" ] && [ -f "$TRACKING_DIR/$mod_name" ]; then
                        log_info "inotify: Module removed: $mod_name"
                        unregister_module "$mod_name"
                    elif [ -d "$mod_path" ] && [ -f "$TRACKING_DIR/$mod_name" ]; then
                        # File removed from existing module
                        log_debug "inotify: File removed from $mod_name, syncing..."
                        sync_module_files "$mod_path"
                    fi
                    # Check if disable marker was removed (re-enable)
                    if [ -d "$mod_path" ] && [ ! -f "$mod_path/disable" ] && [ ! -f "$mod_path/remove" ]; then
                        if [ ! -f "$TRACKING_DIR/$mod_name" ]; then
                            # Was disabled, now re-enabled
                            log_info "inotify: Module re-enabled: $mod_name"
                            handle_new_module "$mod_path"
                        fi
                    fi
                    ;;
                *MODIFY*|*ATTRIB*)
                    # File modified
                    if [ -d "$mod_path" ] && [ -f "$TRACKING_DIR/$mod_name" ]; then
                        log_debug "inotify: File modified in $mod_name, syncing..."
                        sync_module_files "$mod_path"
                    fi
                    ;;
            esac
            ;;
        "$MODULES_UPDATE_DIR"*)
            # Pending update detected
            local mod_name=$(echo "$path" | sed "s|^$MODULES_UPDATE_DIR/||" | cut -d'/' -f1)
            [ -z "$mod_name" ] && return
            [ "$mod_name" = "nomount" ] && return

            log_info "inotify: Pending update detected for $mod_name"
            check_pending_updates
            ;;
        "$SYNC_TRIGGER_DIR"*)
            # ============================================================
            # External Sync Trigger API
            # ============================================================
            # Usage: touch /data/adb/nomount/sync_trigger/<module_name>
            # This triggers an immediate sync for the specified module.
            # The marker file is deleted after processing.
            # ============================================================
            local trigger_file=$(basename "$path")

            # Ignore the directory itself (inotify reports dir events too)
            [ "$trigger_file" = "sync_trigger" ] && return

            # Ignore hidden files (e.g., .gitkeep, temp files)
            [ "${trigger_file#.}" != "$trigger_file" ] && return

            log_info "inotify: External sync trigger for module: $trigger_file"

            # Call sync.sh for the specific module
            if [ -x "$MODDIR/sync.sh" ]; then
                sh "$MODDIR/sync.sh" "$trigger_file" 2>&1 | while read line; do
                    log_debug "sync.sh: $line"
                done
            else
                log_err "sync.sh not found or not executable at $MODDIR/sync.sh"
            fi

            # Clean up this specific trigger file
            rm -f "$path" 2>/dev/null
            ;;
    esac
}

# ============================================================
# FUNCTION: inotify-based watch loop (instant detection)
# Uses inotifywait for <500ms event detection
# Note: Uses named pipe approach for POSIX shell compatibility
# ============================================================
watch_loop_inotify() {
    # Redirect to simplified implementation for POSIX compatibility
    watch_loop_inotify_simple
}

# ============================================================
# FUNCTION: Simplified inotify loop (for limited shells)
# Fallback when process substitution isn't available
# ============================================================
watch_loop_inotify_simple() {
    log_info "Starting simplified inotify watcher..."

    # Build watch directories
    local watch_dirs=""
    [ -d "$MODULES_DIR" ] && watch_dirs="$MODULES_DIR"
    [ -d "$MODULES_UPDATE_DIR" ] && watch_dirs="$watch_dirs $MODULES_UPDATE_DIR"
    [ -d "$SYNC_TRIGGER_DIR" ] && watch_dirs="$watch_dirs $SYNC_TRIGGER_DIR"

    # Use a named pipe for event communication
    local event_pipe="$NOMOUNT_DATA/.inotify_pipe_$$"
    rm -f "$event_pipe" 2>/dev/null
    mkfifo "$event_pipe" 2>/dev/null || {
        log_err "Failed to create named pipe, falling back to polling"
        watch_loop_polling
        return
    }

    # Start inotifywait writing to the pipe
    inotifywait -m -r -e create,delete,modify,move,attrib \
        $watch_dirs \
        --format '%w%f|%e' > "$event_pipe" 2>/dev/null &
    INOTIFY_PID=$!

    log_info "inotifywait started via pipe (PID: $INOTIFY_PID)"

    # Read from the pipe
    while true; do
        # Check if our module is disabled/removed
        if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
            log_info "NoMount module disabled/removed, exiting watch loop"
            break
        fi

        # Check if inotifywait is still running
        if ! kill -0 "$INOTIFY_PID" 2>/dev/null; then
            log_err "inotifywait died unexpectedly, restarting..."
            inotifywait -m -r -e create,delete,modify,move,attrib \
                $watch_dirs \
                --format '%w%f|%e' > "$event_pipe" 2>/dev/null &
            INOTIFY_PID=$!
            sleep 1
            continue
        fi

        # Read with timeout using dd (portable)
        if read line < "$event_pipe" 2>/dev/null; then
            local path=$(echo "$line" | cut -d'|' -f1)
            local event=$(echo "$line" | cut -d'|' -f2)

            if [ -n "$path" ] && [ -n "$event" ]; then
                handle_inotify_event "$path" "$event"
            fi
        fi
    done

    # Cleanup
    rm -f "$event_pipe" 2>/dev/null
    log_info "inotify watch loop terminated"
}

# ============================================================
# FUNCTION: Polling-based watch loop (fallback)
# Uses 5-second polling interval when inotifywait unavailable
# ============================================================
watch_loop_polling() {
    log_info "Starting polling-based module watcher (fallback)..."
    log_info "Watching for: new modules, disables, removes, file changes, pending updates"
    log_info "Watch mode: polling (5-second interval) - inotifywait not available"
    log_debug "Target partitions: $TARGET_PARTITIONS"

    # Build initial state
    local known_modules=""
    local known_disabled=""
    local known_removed=""
    local initial_count=0

    for mod in $(ls -1 "$MODULES_DIR" 2>/dev/null); do
        [ "$mod" = "nomount" ] && continue
        known_modules="$known_modules $mod"
        initial_count=$((initial_count + 1))
        [ -f "$MODULES_DIR/$mod/disable" ] && known_disabled="$known_disabled $mod"
        [ -f "$MODULES_DIR/$mod/remove" ] && known_removed="$known_removed $mod"
    done

    log_info "Initial module scan: $initial_count modules found"
    log_debug "Known modules:$known_modules"
    log_debug "Initially disabled:$known_disabled"
    log_debug "Initially marked for removal:$known_removed"

    local iteration=0
    while true; do
        sleep 5  # Check every 5 seconds for responsiveness
        iteration=$((iteration + 1))

        # Exit if our own module is disabled or marked for removal
        if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
            log_info "NoMount module disabled/removed, exiting watch loop"
            break
        fi

        log_debug "=== Watch iteration #$iteration ==="

        # Get current state
        local current_modules=""
        local current_disabled=""
        local current_removed=""
        local current_count=0

        for mod in "$MODULES_DIR"/*; do
            [ ! -d "$mod" ] && continue
            mod=$(basename "$mod")
            [ "$mod" = "nomount" ] && continue
            current_modules="$current_modules $mod"
            current_count=$((current_count + 1))
            [ -f "$MODULES_DIR/$mod/disable" ] && current_disabled="$current_disabled $mod"
            [ -f "$MODULES_DIR/$mod/remove" ] && current_removed="$current_removed $mod"
        done

        log_debug "Current state: $current_count modules"

        # Check for newly disabled modules
        for mod in $current_disabled; do
            if ! echo "$known_disabled" | grep -qw "$mod"; then
                log_info "Module disabled: $mod"
                unregister_module "$mod"
            fi
        done

        # Check for re-enabled modules (was disabled, now not)
        for mod in $known_disabled; do
            if ! echo "$current_disabled" | grep -qw "$mod"; then
                local mod_path="$MODULES_DIR/$mod"
                if [ -d "$mod_path" ] && [ ! -f "$mod_path/remove" ]; then
                    log_info "Module re-enabled: $mod"
                    handle_new_module "$mod_path"
                fi
            fi
        done

        # Check for modules marked for removal
        for mod in $current_removed; do
            if ! echo "$known_removed" | grep -qw "$mod"; then
                log_info "Module marked for removal: $mod"
                unregister_module "$mod"
            fi
        done

        # Check for new modules
        for mod in $current_modules; do
            if ! echo "$known_modules" | grep -qw "$mod"; then
                local mod_path="$MODULES_DIR/$mod"
                if [ -d "$mod_path" ] && [ ! -f "$mod_path/disable" ] && [ ! -f "$mod_path/remove" ]; then
                    log_debug "Detected new module: $mod"
                    handle_new_module "$mod_path"
                fi
            fi
        done

        # Check for removed modules (was in list, now gone)
        for mod in $known_modules; do
            if ! echo "$current_modules" | grep -qw "$mod"; then
                log_info "Module completely removed: $mod"
                unregister_module "$mod"
            fi
        done

        # Sync file changes for active modules (detect whiteout additions/removals)
        local sync_count=0
        for mod in $current_modules; do
            local mod_path="$MODULES_DIR/$mod"
            if [ -d "$mod_path" ] && [ ! -f "$mod_path/disable" ] && [ ! -f "$mod_path/remove" ]; then
                if [ -f "$TRACKING_DIR/$mod" ]; then
                    sync_module_files "$mod_path"
                    sync_count=$((sync_count + 1))
                fi
            fi
        done

        log_debug "Synced $sync_count active modules"

        # Check for pending updates in modules_update (for debloat module changes)
        check_pending_updates

        # ============================================================
        # External Sync Trigger API (polling mode)
        # ============================================================
        # Usage: touch /data/adb/nomount/sync_trigger/<module_name>
        # This triggers an immediate sync for the specified module.
        # ============================================================
        if [ -d "$SYNC_TRIGGER_DIR" ]; then
            for trigger_path in "$SYNC_TRIGGER_DIR"/*; do
                [ ! -f "$trigger_path" ] && continue
                local trigger_file=$(basename "$trigger_path")

                # Ignore hidden files (e.g., .gitkeep, temp files)
                [ "${trigger_file#.}" != "$trigger_file" ] && continue

                log_info "polling: External sync trigger for module: $trigger_file"

                # Call sync.sh for the specific module
                if [ -x "$MODDIR/sync.sh" ]; then
                    sh "$MODDIR/sync.sh" "$trigger_file" 2>&1 | while read line; do
                        log_debug "sync.sh: $line"
                    done
                else
                    log_err "sync.sh not found or not executable at $MODDIR/sync.sh"
                fi

                # Clean up this specific trigger file
                rm -f "$trigger_path" 2>/dev/null
            done
        fi

        # Update known state
        known_modules="$current_modules"
        known_disabled="$current_disabled"
        known_removed="$current_removed"
    done

    log_info "Polling watch loop terminated after $iteration iterations"
}

# ============================================================
# FUNCTION: Main watch loop dispatcher
# Selects inotify or polling based on availability
# ============================================================
main_watch_loop() {
    if has_inotify; then
        log_info "inotifywait available - using instant detection mode"
        watch_loop_inotify_simple
    else
        log_info "inotifywait NOT available - using polling fallback (5s interval)"
        log_info "Install inotify-tools for instant detection: apt install inotify-tools"
        watch_loop_polling
    fi
}

# Start watching if enabled
if [ "$monitor_new_modules" = "true" ]; then
    log_info "Monitor feature enabled, starting main_watch_loop in background"
    main_watch_loop &
    log_debug "main_watch_loop started with background PID: $!"
else
    log_info "Monitor feature disabled (monitor_new_modules=$monitor_new_modules), exiting"
fi
