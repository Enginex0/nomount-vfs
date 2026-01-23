#!/system/bin/sh
# NoMount VFS - Early Boot Hook (post-fs-data phase)
# This script runs BEFORE service.sh, BEFORE zygote, to pre-register VFS rules
# from a cache created during the previous boot.
#
# Logs: /data/adb/nomount/logs/frontend/post-fs-data.log
#
# Boot sequence:
#   1. Kernel starts
#   2. post-fs-data.sh runs (THIS SCRIPT - early protection)
#   3. Cached VFS rules registered
#   4. Magisk/KSU mounts module overlays
#   5. Zygote starts
#   6. Apps start (already protected by cached rules)
#   7. service.sh runs (refreshes/updates rules, saves new cache)
#
# CRITICAL: This script must NEVER fail boot. All errors exit 0.

MODDIR="${0%/*}"
[ "$MODDIR" = "$0" ] && MODDIR="."

NOMOUNT_DATA="/data/adb/nomount"
NOMOUNT_LOG_DIR="$NOMOUNT_DATA/logs/frontend"
RULE_CACHE="$NOMOUNT_DATA/.rule_cache"

# Ensure log directories exist
mkdir -p "$NOMOUNT_LOG_DIR" 2>/dev/null
mkdir -p "$NOMOUNT_DATA/metadata_cache" 2>/dev/null

# ============================================================
# LOGGING - Early Boot Safe
# ============================================================
LOG_FILE="$NOMOUNT_LOG_DIR/post-fs-data.log"

# Simple logging for early boot (logging.sh may not be reliable here)
log_pfd() {
    echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null
}

# Structured logging functions
log_trace() { log_pfd "[TRACE] $*"; }
log_debug() { log_pfd "[DEBUG] $*"; }
log_info() { log_pfd "[INFO ] $*"; }
log_warn() { log_pfd "[WARN ] $*"; }
log_err() { log_pfd "[ERROR] $*"; }

log_func_enter() {
    local func="$1"
    shift
    log_debug ">>> ENTER: $func($*)"
}

log_func_exit() {
    log_debug "<<< EXIT: $1 (result=$2)"
}

log_section() {
    log_info "========== $1 =========="
}

# Target partitions for metadata capture
TARGET_PARTITIONS="system vendor product system_ext odm oem mi_ext my_heytap prism optics"

# ============================================================
# SUSFS INTEGRATION - Early Metadata Capture
# ============================================================
SUSFS_INTEGRATION="$MODDIR/susfs_integration.sh"
[ -f "$SUSFS_INTEGRATION" ] && . "$SUSFS_INTEGRATION" || log_warn "SUSFS integration not found"

# ============================================================
# FUNCTION: Find nm binary dynamically
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
    log_warn "nm binary not found"
    return 1
}

# ============================================================
# MAIN EXECUTION
# ============================================================
log_section "POST-FS-DATA PHASE"

NM_BIN=$(find_nm_binary)
[ -z "$NM_BIN" ] && { log_warn "nm binary not found"; exit 0; }

[ ! -c "/dev/vfs_helper" ] && { log_info "VFS driver not available yet"; exit 0; }
log_info "VFS driver ready"

# ============================================================
# CRITICAL: Capture original file metadata BEFORE any overlays
# ============================================================
type susfs_init >/dev/null 2>&1 && susfs_init 2>/dev/null

MODULES_DIR="/data/adb/modules"
if [ -d "$MODULES_DIR" ]; then
    modules_scanned=0
    for mod_path in "$MODULES_DIR"/*; do
        [ -d "$mod_path" ] || continue
        mod_name="${mod_path##*/}"
        [ -f "$mod_path/disable" ] || [ -f "$mod_path/remove" ] || [ "$mod_name" = "nomount" ] && continue

        modules_scanned=$((modules_scanned + 1))
        for partition in $TARGET_PARTITIONS; do
            if [ -d "$mod_path/$partition" ]; then
                find "$mod_path/$partition" -type f 2>/dev/null | while read -r real_path; do
                    vpath="${real_path#$mod_path}"
                    type susfs_capture_metadata >/dev/null 2>&1 && susfs_capture_metadata "$vpath"
                done
            fi
        done
    done
    log_info "Metadata capture: $modules_scanned modules scanned"
fi

# ============================================================
# FUNCTION: Validate and clean stale cache entries
# ============================================================
validate_and_clean_cache() {
    local cache_file="$RULE_CACHE"
    [ ! -f "$cache_file" ] && return 0

    local temp_cache="${cache_file}.validated.$$"
    local removed=0 kept=0

    while IFS='|' read -r cmd vpath rpath || [ -n "$cmd" ]; do
        [ -z "$cmd" ] && continue

        case "$cmd" in
            \#*)
                echo "${cmd}|${vpath}|${rpath}" >> "$temp_cache"
                continue
                ;;
            setdev|addmap|hide)
                echo "${cmd}|${vpath}|${rpath}" >> "$temp_cache"
                kept=$((kept + 1))
                continue
                ;;
        esac

        if [ "$cmd" = "add" ]; then
            local keep_rule=1

            [ -n "$rpath" ] && [ "$rpath" != "/nonexistent" ] && [ ! -e "$rpath" ] && keep_rule=0

            if [ "$keep_rule" = "1" ] && echo "$rpath" | grep -q "/data/adb/modules/"; then
                local mod_name=$(echo "$rpath" | sed 's|.*/data/adb/modules/||' | cut -d/ -f1)
                local mod_path="/data/adb/modules/$mod_name"
                [ -f "$mod_path/disable" ] || [ -f "$mod_path/remove" ] || [ ! -d "$mod_path" ] && keep_rule=0
            fi

            if [ "$keep_rule" = "1" ]; then
                echo "${cmd}|${vpath}|${rpath}" >> "$temp_cache"
                kept=$((kept + 1))
            else
                removed=$((removed + 1))
            fi
        fi
    done < "$cache_file"

    if [ "$removed" -gt 0 ]; then
        mv "$temp_cache" "$cache_file" 2>/dev/null
        log_info "Cache cleaned: -$removed stale, $kept valid"
    else
        rm -f "$temp_cache" 2>/dev/null
    fi
}

# ============================================================
# LOAD AND APPLY CACHED RULES
# ============================================================
validate_and_clean_cache

[ ! -f "$RULE_CACHE" ] && { log_info "No rule cache"; exit 0; }

cache_size=$(wc -c < "$RULE_CACHE" 2>/dev/null || echo 0)
[ "$cache_size" -eq 0 ] && { log_info "Empty cache"; exit 0; }
[ "$cache_size" -gt 10485760 ] && { log_warn "Cache too large"; exit 0; }

count=0
fail_count=0

while IFS='|' read -r cmd vpath rpath || [ -n "$cmd" ]; do
    [ -z "$cmd" ] && continue
    case "$cmd" in \#*) continue ;; esac

    case "$cmd" in
        add)
            [ -z "$vpath" ] || [ -z "$rpath" ] && { fail_count=$((fail_count + 1)); continue; }
            [ "$rpath" != "/nonexistent" ] && [ ! -e "$rpath" ] && { fail_count=$((fail_count + 1)); continue; }
            "$NM_BIN" add "$vpath" "$rpath" </dev/null >/dev/null 2>&1 && count=$((count + 1)) || fail_count=$((fail_count + 1))
            ;;
        hide)
            [ -z "$vpath" ] && { fail_count=$((fail_count + 1)); continue; }
            "$NM_BIN" hide "$vpath" </dev/null >/dev/null 2>&1 && count=$((count + 1)) || fail_count=$((fail_count + 1))
            ;;
        setdev)
            [ -z "$vpath" ] || [ -z "$rpath" ] && { fail_count=$((fail_count + 1)); continue; }
            local major="${rpath%%:*}" minor="${rpath##*:}"
            "$NM_BIN" setdev "$vpath" "$major" "$minor" </dev/null >/dev/null 2>&1 && count=$((count + 1)) || fail_count=$((fail_count + 1))
            ;;
        addmap)
            [ -z "$vpath" ] && { fail_count=$((fail_count + 1)); continue; }
            "$NM_BIN" addmap "$vpath" </dev/null >/dev/null 2>&1 && count=$((count + 1)) || fail_count=$((fail_count + 1))
            ;;
    esac
done < "$RULE_CACHE"

# ============================================================
# SUMMARY
# ============================================================
log_info "Rules applied: $count, failed: $fail_count"
exit 0
