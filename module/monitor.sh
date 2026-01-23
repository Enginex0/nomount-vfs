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

# ============================================================
# SUSFS INTEGRATION - Load for cleanup functions
# ============================================================
SUSFS_INTEGRATION="$MODDIR/susfs_integration.sh"
if [ -f "$SUSFS_INTEGRATION" ]; then
    . "$SUSFS_INTEGRATION"
    # Initialize SUSFS if available (for cleanup functions)
    if type susfs_init >/dev/null 2>&1; then
        susfs_init 2>/dev/null || true  # Don't fail if SUSFS unavailable
    fi
fi

# Match partition list with service.sh
TARGET_PARTITIONS="system vendor product system_ext odm oem mi_ext my_heytap prism optics oem_dlkm system_dlkm vendor_dlkm"

# Directory to track registered paths per module
TRACKING_DIR="$NOMOUNT_DATA/module_paths"
mkdir -p "$TRACKING_DIR" 2>/dev/null

# Cleanup function for signal handling
cleanup() {
    [ -n "$INOTIFY_PID" ] && kill -0 "$INOTIFY_PID" 2>/dev/null && kill "$INOTIFY_PID" 2>/dev/null
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
        . "$CONFIG_FILE"
    else
        log_err "Config file security check failed"
    fi
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
    sed "s|^description=.*|description=$STATUS$BASE_DESC|" "$PROP_FILE" > "$PROP_FILE.tmp" && mv "$PROP_FILE.tmp" "$PROP_FILE" || log_err "Failed to update module.prop"
}

update_status

# ============================================================
# FUNCTION: Check if module is excluded
# ============================================================
is_excluded() {
    echo "$excluded_modules" | grep -qw "$1"
}

# ============================================================
# FUNCTION: Clean rule cache entries for a specific module
# ============================================================
clean_module_rule_cache() {
    local mod_name="$1"
    local tracking_file="$2"
    local rule_cache="$NOMOUNT_DATA/.rule_cache"

    [ ! -f "$rule_cache" ] || [ ! -f "$tracking_file" ] && return 0

    local temp_cache="${rule_cache}.tmp.$$"
    local cleaned=0

    while IFS='|' read -r cmd vpath rpath; do
        [ -z "$cmd" ] && continue
        case "$cmd" in
            \#*|setdev|addmap|hide)
                echo "${cmd}|${vpath}|${rpath}"
                ;;
            add)
                if grep -qxF "$vpath" "$tracking_file" 2>/dev/null; then
                    cleaned=$((cleaned + 1))
                else
                    echo "${cmd}|${vpath}|${rpath}"
                fi
                ;;
            *)
                echo "${cmd}|${vpath}|${rpath}"
                ;;
        esac
    done < "$rule_cache" > "$temp_cache"

    if [ $cleaned -gt 0 ]; then
        mv "$temp_cache" "$rule_cache" 2>/dev/null
        log_info "Cleaned $cleaned cache entries for $mod_name"
    else
        rm -f "$temp_cache"
    fi
}

# ============================================================
# FUNCTION: Unregister all VFS paths for a module
# Called when module is disabled/removed
# ============================================================
unregister_module() {
    local mod_name="$1"
    local tracking_file="$TRACKING_DIR/$mod_name"

    [ ! -f "$tracking_file" ] && return

    log_info "Unregistering module: $mod_name"

    local count=0
    local failed=0
    while IFS= read -r virtual_path; do
        [ -z "$virtual_path" ] && continue
        if "$LOADER" del "$virtual_path" < /dev/null 2>/dev/null; then
            count=$((count + 1))
        else
            failed=$((failed + 1))
        fi
    done < "$tracking_file"

    [ $failed -gt 0 ] && log_err "Failed to remove $failed VFS rules for $mod_name"
    log_info "Removed $count VFS rules for $mod_name"

    type susfs_clean_module_entries >/dev/null 2>&1 && susfs_clean_module_entries "$mod_name" "$tracking_file"
    type susfs_clean_module_metadata_cache >/dev/null 2>&1 && susfs_clean_module_metadata_cache "$mod_name" "$tracking_file"
    clean_module_rule_cache "$mod_name" "$tracking_file"
    rm -f "$tracking_file"

    local mod_path="$MODULES_DIR/$mod_name"
    if grep -q "^$mod_name$" "$NOMOUNT_DATA/skipped_modules" 2>/dev/null; then
        rm -f "$mod_path/skip_mount" 2>/dev/null
        grep -v "^$mod_name$" "$NOMOUNT_DATA/skipped_modules" > "$NOMOUNT_DATA/skipped_modules.tmp" 2>/dev/null
        mv "$NOMOUNT_DATA/skipped_modules.tmp" "$NOMOUNT_DATA/skipped_modules" 2>/dev/null
    fi

    MODULE_COUNT=$((MODULE_COUNT - 1))
    [ "$MODULE_COUNT" -lt 0 ] && MODULE_COUNT=0
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

    : > "$tracking_file"
    local success=0
    local failed=0

    for partition in $TARGET_PARTITIONS; do
        if [ -d "$mod_path/$partition" ]; then
            (
                cd "$mod_path" || exit
                find "$partition" -type f -o -type c 2>/dev/null | while read -r relative_path; do
                    real_path="$mod_path/$relative_path"
                    virtual_path="/$relative_path"

                    if [ -c "$real_path" ]; then
                        "$LOADER" add "$virtual_path" "/nonexistent" < /dev/null 2>/dev/null || \
                            echo "[$(date '+%H:%M:%S')] [MONITOR] [ERROR] nm add failed: $virtual_path" >> "$LOG_FILE"
                    else
                        "$LOADER" add "$virtual_path" "$real_path" < /dev/null 2>/dev/null || \
                            echo "[$(date '+%H:%M:%S')] [MONITOR] [ERROR] nm add failed: $virtual_path" >> "$LOG_FILE"
                    fi
                    echo "$virtual_path" >> "$tracking_file"
                done
            )
        fi
    done

    local count=$(wc -l < "$tracking_file" 2>/dev/null || echo 0)
    log_info "Registered $count paths for $mod_name"
}

# ============================================================
# FUNCTION: Sync module files - detect added/removed files
# ============================================================
sync_module_files() {
    local mod_path="$1"
    local mod_name=$(basename "$mod_path")
    local tracking_file="$TRACKING_DIR/$mod_name"

    [ ! -f "$tracking_file" ] && return

    local current_files="$NOMOUNT_DATA/.sync_tmp_$$"
    : > "$current_files"
    for partition in $TARGET_PARTITIONS; do
        [ -d "$mod_path/$partition" ] && \
            (cd "$mod_path" && find "$partition" -type f -o -type c 2>/dev/null) | sed 's|^|/|' >> "$current_files"
    done

    local removed=0 added=0

    # Find removed files
    while IFS= read -r tracked_path; do
        [ -z "$tracked_path" ] && continue
        if ! grep -qxF "$tracked_path" "$current_files"; then
            "$LOADER" del "$tracked_path" < /dev/null 2>/dev/null && removed=$((removed + 1)) || log_err "Failed to remove: $tracked_path"
        fi
    done < "$tracking_file"

    # Find added files
    while IFS= read -r current_path; do
        [ -z "$current_path" ] && continue
        if ! grep -qxF "$current_path" "$tracking_file"; then
            local real_path="$mod_path$current_path"
            if [ -c "$real_path" ]; then
                "$LOADER" add "$current_path" "/nonexistent" < /dev/null 2>/dev/null && added=$((added + 1)) || log_err "Failed to add: $current_path"
            elif [ -f "$real_path" ]; then
                "$LOADER" add "$current_path" "$real_path" < /dev/null 2>/dev/null && added=$((added + 1)) || log_err "Failed to add: $current_path"
            fi
        fi
    done < "$current_files"

    if [ "$removed" -gt 0 ] || [ "$added" -gt 0 ]; then
        cp "$current_files" "$tracking_file"
        log_info "Synced $mod_name: +$added -$removed"
    fi

    rm -f "$current_files"
}

# ============================================================
# FUNCTION: Handle new module detection
# ============================================================
handle_new_module() {
    local mod_path="$1"
    local mod_name=$(basename "$mod_path")

    is_excluded "$mod_name" && return

    local has_content=false
    for partition in $TARGET_PARTITIONS; do
        [ -d "$mod_path/$partition" ] && { has_content=true; break; }
    done

    if [ "$has_content" = "true" ]; then
        log_info "New module: $mod_name"

        if [ ! -f "$mod_path/skip_mount" ]; then
            touch "$mod_path/skip_mount" && echo "$mod_name" >> "$NOMOUNT_DATA/skipped_modules" || log_err "Failed to create skip_mount for: $mod_name"
        fi

        register_module "$mod_path"
        MODULE_COUNT=$((MODULE_COUNT + 1))
        update_status
    fi
}

# ============================================================
# FUNCTION: Check modules_update for pending changes
# ============================================================
MODULES_UPDATE_DIR="/data/adb/modules_update"
SYNC_TRIGGER_DIR="$NOMOUNT_DATA/sync_trigger"
mkdir -p "$SYNC_TRIGGER_DIR" 2>/dev/null

check_pending_updates() {
    [ ! -d "$MODULES_UPDATE_DIR" ] && return

    for mod_update in "$MODULES_UPDATE_DIR"/*; do
        [ ! -d "$mod_update" ] && continue
        local mod_name=$(basename "$mod_update")
        [ "$mod_name" = "nomount" ] && continue
        [ ! -f "$TRACKING_DIR/$mod_name" ] && continue

        local mod_active="$MODULES_DIR/$mod_name"

        for partition in $TARGET_PARTITIONS; do
            local update_count=0 active_count=0
            [ -d "$mod_update/$partition" ] && update_count=$(find "$mod_update/$partition" -type f -o -type c 2>/dev/null | wc -l)
            [ -d "$mod_active/$partition" ] && active_count=$(find "$mod_active/$partition" -type f -o -type c 2>/dev/null | wc -l)

            if [ "$update_count" != "$active_count" ]; then
                log_info "Pending update for $mod_name"
                sync_module_from_update "$mod_update" "$mod_name"
                break
            fi
        done
    done
}

# Sync module using modules_update content (for pending changes)
sync_module_from_update() {
    local update_path="$1"
    local mod_name="$2"
    local tracking_file="$TRACKING_DIR/$mod_name"

    local current_files="$NOMOUNT_DATA/.sync_update_tmp_$$"
    : > "$current_files"
    for partition in $TARGET_PARTITIONS; do
        [ -d "$update_path/$partition" ] && \
            (cd "$update_path" && find "$partition" -type f -o -type c 2>/dev/null) | sed 's|^|/|' >> "$current_files"
    done

    local removed=0
    while IFS= read -r tracked_path; do
        [ -z "$tracked_path" ] && continue
        if ! grep -qxF "$tracked_path" "$current_files"; then
            "$LOADER" del "$tracked_path" < /dev/null 2>/dev/null && removed=$((removed + 1)) || log_err "Failed to remove: $tracked_path"
        fi
    done < "$tracking_file"

    rm -f "$current_files"
    [ "$removed" -gt 0 ] && log_info "Pre-synced $mod_name: -$removed rules"
}

# ============================================================
# FUNCTION: Handle inotify event
# ============================================================
handle_inotify_event() {
    local path="$1"
    local event="$2"

    case "$path" in
        "$MODULES_DIR"*)
            local mod_name=$(echo "$path" | sed "s|^$MODULES_DIR/||" | cut -d'/' -f1)
            [ -z "$mod_name" ] || [ "$mod_name" = "nomount" ] && return
            local mod_path="$MODULES_DIR/$mod_name"

            case "$event" in
                *CREATE*|*MOVED_TO*)
                    if [ -d "$mod_path" ] && [ ! -f "$mod_path/disable" ] && [ ! -f "$mod_path/remove" ]; then
                        [ ! -f "$TRACKING_DIR/$mod_name" ] && handle_new_module "$mod_path" || sync_module_files "$mod_path"
                    fi
                    [ -f "$mod_path/disable" ] && [ -f "$TRACKING_DIR/$mod_name" ] && unregister_module "$mod_name"
                    [ -f "$mod_path/remove" ] && [ -f "$TRACKING_DIR/$mod_name" ] && unregister_module "$mod_name"
                    ;;
                *DELETE*|*MOVED_FROM*)
                    if [ ! -d "$mod_path" ] && [ -f "$TRACKING_DIR/$mod_name" ]; then
                        unregister_module "$mod_name"
                    elif [ -d "$mod_path" ] && [ -f "$TRACKING_DIR/$mod_name" ]; then
                        sync_module_files "$mod_path"
                    fi
                    [ -d "$mod_path" ] && [ ! -f "$mod_path/disable" ] && [ ! -f "$mod_path/remove" ] && \
                        [ ! -f "$TRACKING_DIR/$mod_name" ] && handle_new_module "$mod_path"
                    ;;
                *MODIFY*|*ATTRIB*)
                    [ -d "$mod_path" ] && [ -f "$TRACKING_DIR/$mod_name" ] && sync_module_files "$mod_path"
                    ;;
            esac
            ;;
        "$MODULES_UPDATE_DIR"*)
            local mod_name=$(echo "$path" | sed "s|^$MODULES_UPDATE_DIR/||" | cut -d'/' -f1)
            [ -z "$mod_name" ] || [ "$mod_name" = "nomount" ] && return
            check_pending_updates
            ;;
        "$SYNC_TRIGGER_DIR"*)
            local trigger_file=$(basename "$path")
            [ "$trigger_file" = "sync_trigger" ] || [ "${trigger_file#.}" != "$trigger_file" ] && return
            log_info "External sync trigger: $trigger_file"
            [ -x "$MODDIR/sync.sh" ] && sh "$MODDIR/sync.sh" "$trigger_file" 2>/dev/null || log_err "sync.sh not found"
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
# ============================================================
watch_loop_inotify_simple() {
    local watch_dirs=""
    [ -d "$MODULES_DIR" ] && watch_dirs="$MODULES_DIR"
    [ -d "$MODULES_UPDATE_DIR" ] && watch_dirs="$watch_dirs $MODULES_UPDATE_DIR"
    [ -d "$SYNC_TRIGGER_DIR" ] && watch_dirs="$watch_dirs $SYNC_TRIGGER_DIR"

    local event_pipe="$NOMOUNT_DATA/.inotify_pipe_$$"
    rm -f "$event_pipe" 2>/dev/null
    mkfifo "$event_pipe" 2>/dev/null || { watch_loop_polling; return; }

    inotifywait -m -r -e create,delete,modify,move,attrib $watch_dirs --format '%w%f|%e' > "$event_pipe" 2>/dev/null &
    INOTIFY_PID=$!
    log_info "inotify watcher started (PID: $INOTIFY_PID)"

    while true; do
        [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] && break

        if ! kill -0 "$INOTIFY_PID" 2>/dev/null; then
            inotifywait -m -r -e create,delete,modify,move,attrib $watch_dirs --format '%w%f|%e' > "$event_pipe" 2>/dev/null &
            INOTIFY_PID=$!
            sleep 1
            continue
        fi

        if read line < "$event_pipe" 2>/dev/null; then
            local path=$(echo "$line" | cut -d'|' -f1)
            local event=$(echo "$line" | cut -d'|' -f2)
            [ -n "$path" ] && [ -n "$event" ] && handle_inotify_event "$path" "$event"
        fi
    done

    rm -f "$event_pipe" 2>/dev/null
}

# ============================================================
# FUNCTION: Polling-based watch loop (fallback)
# ============================================================
watch_loop_polling() {
    log_info "Polling watcher started (5s interval)"

    local known_modules="" known_disabled="" known_removed=""
    for mod in $(ls -1 "$MODULES_DIR" 2>/dev/null); do
        [ "$mod" = "nomount" ] && continue
        known_modules="$known_modules $mod"
        [ -f "$MODULES_DIR/$mod/disable" ] && known_disabled="$known_disabled $mod"
        [ -f "$MODULES_DIR/$mod/remove" ] && known_removed="$known_removed $mod"
    done

    while true; do
        sleep 5
        [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] && break

        local current_modules="" current_disabled="" current_removed=""
        for mod in "$MODULES_DIR"/*; do
            [ ! -d "$mod" ] && continue
            mod=$(basename "$mod")
            [ "$mod" = "nomount" ] && continue
            current_modules="$current_modules $mod"
            [ -f "$MODULES_DIR/$mod/disable" ] && current_disabled="$current_disabled $mod"
            [ -f "$MODULES_DIR/$mod/remove" ] && current_removed="$current_removed $mod"
        done

        # Check state changes
        for mod in $current_disabled; do
            echo "$known_disabled" | grep -qw "$mod" || unregister_module "$mod"
        done

        for mod in $known_disabled; do
            if ! echo "$current_disabled" | grep -qw "$mod"; then
                local mod_path="$MODULES_DIR/$mod"
                [ -d "$mod_path" ] && [ ! -f "$mod_path/remove" ] && handle_new_module "$mod_path"
            fi
        done

        for mod in $current_removed; do
            echo "$known_removed" | grep -qw "$mod" || unregister_module "$mod"
        done

        for mod in $current_modules; do
            if ! echo "$known_modules" | grep -qw "$mod"; then
                local mod_path="$MODULES_DIR/$mod"
                [ -d "$mod_path" ] && [ ! -f "$mod_path/disable" ] && [ ! -f "$mod_path/remove" ] && handle_new_module "$mod_path"
            fi
        done

        for mod in $known_modules; do
            echo "$current_modules" | grep -qw "$mod" || unregister_module "$mod"
        done

        # Sync active modules
        for mod in $current_modules; do
            local mod_path="$MODULES_DIR/$mod"
            [ -d "$mod_path" ] && [ ! -f "$mod_path/disable" ] && [ ! -f "$mod_path/remove" ] && \
                [ -f "$TRACKING_DIR/$mod" ] && sync_module_files "$mod_path"
        done

        check_pending_updates

        # External sync triggers
        if [ -d "$SYNC_TRIGGER_DIR" ]; then
            for trigger_path in "$SYNC_TRIGGER_DIR"/*; do
                [ ! -f "$trigger_path" ] && continue
                local trigger_file=$(basename "$trigger_path")
                [ "${trigger_file#.}" != "$trigger_file" ] && continue
                log_info "Sync trigger: $trigger_file"
                [ -x "$MODDIR/sync.sh" ] && sh "$MODDIR/sync.sh" "$trigger_file" 2>/dev/null || log_err "sync.sh not found"
                rm -f "$trigger_path" 2>/dev/null
            done
        fi

        known_modules="$current_modules"
        known_disabled="$current_disabled"
        known_removed="$current_removed"
    done
}

# ============================================================
# FUNCTION: Main watch loop dispatcher
# ============================================================
main_watch_loop() {
    if has_inotify; then
        watch_loop_inotify_simple
    else
        watch_loop_polling
    fi
}

# Start watching if enabled
if [ "$monitor_new_modules" = "true" ]; then
    main_watch_loop &
fi
