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
if [ -f "$SUSFS_INTEGRATION" ]; then
    log_debug "Loading SUSFS integration module"
    . "$SUSFS_INTEGRATION"
    log_info "SUSFS integration module loaded"
else
    log_warn "SUSFS integration module not found: $SUSFS_INTEGRATION"
fi

# ============================================================
# FUNCTION: Find nm binary dynamically
# ============================================================
find_nm_binary() {
    log_func_enter "find_nm_binary"
    local possible_paths="
        $MODDIR/bin/nm
        $MODDIR/nm-arm64
        $MODDIR/nm
        /data/adb/modules/nomount/bin/nm
        /data/adb/modules/nomount/nm-arm64
        /data/adb/modules/nomount/nm
    "
    local checked=0
    for path in $possible_paths; do
        checked=$((checked + 1))
        log_trace "Checking [$checked]: $path"
        if [ -x "$path" ]; then
            log_debug "Found nm binary: $path"
            log_func_exit "find_nm_binary" "$path"
            echo "$path"
            return 0
        fi
    done
    log_warn "nm binary not found after checking $checked paths"
    log_func_exit "find_nm_binary" "NOT_FOUND"
    return 1
}

# ============================================================
# MAIN EXECUTION
# ============================================================
log_section "POST-FS-DATA PHASE (Early Boot)"
log_info "Script starting at $(date)"
log_debug "MODDIR=$MODDIR"
log_debug "NOMOUNT_DATA=$NOMOUNT_DATA"

# Find nm binary
log_debug "Searching for nm binary..."
NM_BIN=$(find_nm_binary)
if [ -z "$NM_BIN" ]; then
    log_warn "nm binary not found, skipping early registration"
    exit 0
fi
log_info "Using nm binary: $NM_BIN"

# Check if VFS driver is available
log_debug "Checking VFS driver availability..."
if [ ! -c "/dev/vfs_helper" ]; then
    log_info "/dev/vfs_helper not available yet, skipping early registration"
    exit 0
fi
log_info "VFS driver available: /dev/vfs_helper"

# ============================================================
# CRITICAL: Capture original file metadata BEFORE any overlays
# ============================================================
log_section "METADATA CAPTURE (Pre-Overlay)"

# Initialize SUSFS integration for metadata capture
if type susfs_init >/dev/null 2>&1; then
    log_debug "Initializing SUSFS for metadata capture"
    susfs_init 2>/dev/null || log_warn "SUSFS init returned non-zero"
fi

# Scan modules and capture metadata for files that will be redirected
MODULES_DIR="/data/adb/modules"
if [ -d "$MODULES_DIR" ]; then
    log_info "Scanning modules for metadata capture..."
    metadata_count=0
    modules_scanned=0

    for mod_path in "$MODULES_DIR"/*; do
        [ -d "$mod_path" ] || continue
        mod_name="${mod_path##*/}"

        # Skip disabled/removed modules
        if [ -f "$mod_path/disable" ]; then
            log_trace "Skipping disabled module: $mod_name"
            continue
        fi
        if [ -f "$mod_path/remove" ]; then
            log_trace "Skipping removed module: $mod_name"
            continue
        fi
        if [ "$mod_name" = "nomount" ]; then
            log_trace "Skipping self: nomount"
            continue
        fi

        modules_scanned=$((modules_scanned + 1))
        log_debug "Scanning module: $mod_name"

        # Capture metadata for files in target partitions
        for partition in $TARGET_PARTITIONS; do
            if [ -d "$mod_path/$partition" ]; then
                log_trace "Scanning $mod_name/$partition"
                find "$mod_path/$partition" -type f 2>/dev/null | while read -r real_path; do
                    vpath="${real_path#$mod_path}"
                    # Capture metadata for ALL files (existing get real stats, new get marked as NEW)
                    if type susfs_capture_metadata >/dev/null 2>&1; then
                        susfs_capture_metadata "$vpath"
                    fi
                done
            fi
        done
    done

    log_info "Metadata capture complete: scanned $modules_scanned modules"
else
    log_info "No modules directory found, skipping metadata capture"
fi

# ============================================================
# FUNCTION: Validate and clean stale cache entries
# Removes entries for modules that are disabled, removed, or missing
# Called BEFORE applying cached rules to prevent broken redirects
# ============================================================
validate_and_clean_cache() {
    log_func_enter "validate_and_clean_cache"
    local cache_file="$RULE_CACHE"

    if [ ! -f "$cache_file" ]; then
        log_debug "No cache file to validate"
        log_func_exit "validate_and_clean_cache" "skip"
        return 0
    fi

    local temp_cache="${cache_file}.validated.$$"
    local removed=0
    local kept=0

    log_info "Validating cache entries against current module state..."

    while IFS='|' read -r cmd vpath rpath || [ -n "$cmd" ]; do
        [ -z "$cmd" ] && continue

        # Pass through comments and non-add rules unchanged
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

        # For 'add' rules, validate the real_path
        if [ "$cmd" = "add" ]; then
            local keep_rule=1

            # Check 1: Does real_path exist?
            if [ -n "$rpath" ] && [ "$rpath" != "/nonexistent" ] && [ ! -e "$rpath" ]; then
                log_debug "STALE: real_path missing - $vpath -> $rpath"
                keep_rule=0
            fi

            # Check 2: Is the owning module disabled/removed?
            if [ "$keep_rule" = "1" ] && echo "$rpath" | grep -q "/data/adb/modules/"; then
                local mod_name
                mod_name=$(echo "$rpath" | sed 's|.*/data/adb/modules/||' | cut -d/ -f1)
                local mod_path="/data/adb/modules/$mod_name"

                if [ -f "$mod_path/disable" ]; then
                    log_debug "STALE: module disabled - $vpath (module: $mod_name)"
                    keep_rule=0
                elif [ -f "$mod_path/remove" ]; then
                    log_debug "STALE: module marked for removal - $vpath (module: $mod_name)"
                    keep_rule=0
                elif [ ! -d "$mod_path" ]; then
                    log_debug "STALE: module missing - $vpath (module: $mod_name)"
                    keep_rule=0
                fi
            fi

            if [ "$keep_rule" = "1" ]; then
                echo "${cmd}|${vpath}|${rpath}" >> "$temp_cache"
                kept=$((kept + 1))
            else
                removed=$((removed + 1))
            fi
        fi
    done < "$cache_file"

    # Replace cache with validated version
    if [ "$removed" -gt 0 ]; then
        mv "$temp_cache" "$cache_file" 2>/dev/null
        log_info "Cache cleaned: removed $removed stale entries, kept $kept valid entries"
    else
        rm -f "$temp_cache" 2>/dev/null
        log_debug "Cache validation complete: all $kept entries valid"
    fi

    log_func_exit "validate_and_clean_cache" "removed=$removed"
    return 0
}

# ============================================================
# LOAD AND APPLY CACHED RULES
# ============================================================
log_section "RULE CACHE LOADING"

# CRITICAL: Validate and clean cache BEFORE loading
validate_and_clean_cache

# Check if cache exists
if [ ! -f "$RULE_CACHE" ]; then
    log_info "No rule cache found at $RULE_CACHE, skipping early registration"
    exit 0
fi

# Validate cache file
cache_size=$(wc -c < "$RULE_CACHE" 2>/dev/null || echo 0)
log_debug "Cache file size: $cache_size bytes"

if [ "$cache_size" -eq 0 ]; then
    log_info "Rule cache is empty, skipping early registration"
    exit 0
fi

if [ "$cache_size" -gt 10485760 ]; then
    log_warn "Rule cache suspiciously large ($cache_size bytes), skipping"
    exit 0
fi

log_info "Loading cached VFS rules from $RULE_CACHE..."

# Register cached rules
# Cache format: cmd|virtual_path|real_path
count=0
fail_count=0
rule_index=0

log_debug "Starting cache rule processing..."

while IFS='|' read -r cmd vpath rpath || [ -n "$cmd" ]; do
    rule_index=$((rule_index + 1))

    # Skip empty lines
    [ -z "$cmd" ] && continue

    # Skip comments (lines starting with #)
    case "$cmd" in
        \#*) continue ;;
    esac

    log_trace "Processing rule #$rule_index: cmd=$cmd"

    case "$cmd" in
        add)
            # Validate paths
            if [ -z "$vpath" ] || [ -z "$rpath" ]; then
                log_warn "Rule #$rule_index: Invalid add rule (missing path)"
                fail_count=$((fail_count + 1))
                continue
            fi

            # CRITICAL: Validate real_path exists before applying
            # This prevents crashes from stale cache entries for uninstalled modules
            if [ "$rpath" != "/nonexistent" ] && [ ! -e "$rpath" ]; then
                log_warn "Rule #$rule_index: SKIPPED (real_path missing) - $vpath -> $rpath"
                fail_count=$((fail_count + 1))
                continue
            fi

            log_trace "Rule #$rule_index: add $vpath -> $rpath"
            log_trace "Executing: $NM_BIN add $vpath $rpath"
            if "$NM_BIN" add "$vpath" "$rpath" </dev/null >/dev/null 2>&1; then
                count=$((count + 1))
                log_trace "Rule #$rule_index: add OK"
            else
                log_warn "Rule #$rule_index: add FAILED - $vpath"
                fail_count=$((fail_count + 1))
            fi
            ;;

        hide)
            # Hide mount - vpath contains mount_id
            if [ -z "$vpath" ]; then
                log_warn "Rule #$rule_index: Invalid hide rule (missing mount_id)"
                fail_count=$((fail_count + 1))
                continue
            fi

            log_trace "Rule #$rule_index: hide mount_id=$vpath"
            log_trace "Executing: $NM_BIN hide $vpath"
            if "$NM_BIN" hide "$vpath" </dev/null >/dev/null 2>&1; then
                count=$((count + 1))
                log_trace "Rule #$rule_index: hide OK"
            else
                log_warn "Rule #$rule_index: hide FAILED - mount_id=$vpath"
                fail_count=$((fail_count + 1))
            fi
            ;;

        setdev)
            # Partition device spoofing: setdev|partition_id|major:minor
            if [ -z "$vpath" ] || [ -z "$rpath" ]; then
                log_warn "Rule #$rule_index: Invalid setdev rule"
                fail_count=$((fail_count + 1))
                continue
            fi

            local part_id="$vpath"
            local major_minor="$rpath"
            local major="${major_minor%%:*}"
            local minor="${major_minor##*:}"

            log_trace "Rule #$rule_index: setdev part=$part_id major=$major minor=$minor"
            log_trace "Executing: $NM_BIN setdev $part_id $major $minor"
            if "$NM_BIN" setdev "$part_id" "$major" "$minor" </dev/null >/dev/null 2>&1; then
                count=$((count + 1))
                log_trace "Rule #$rule_index: setdev OK"
            else
                log_warn "Rule #$rule_index: setdev FAILED - part=$part_id"
                fail_count=$((fail_count + 1))
            fi
            ;;

        addmap)
            # Maps pattern: addmap|pattern|
            if [ -z "$vpath" ]; then
                log_warn "Rule #$rule_index: Invalid addmap rule"
                fail_count=$((fail_count + 1))
                continue
            fi

            log_trace "Rule #$rule_index: addmap pattern=$vpath"
            log_trace "Executing: $NM_BIN addmap $vpath"
            if "$NM_BIN" addmap "$vpath" </dev/null >/dev/null 2>&1; then
                count=$((count + 1))
                log_trace "Rule #$rule_index: addmap OK"
            else
                log_warn "Rule #$rule_index: addmap FAILED - pattern=$vpath"
                fail_count=$((fail_count + 1))
            fi
            ;;

        *)
            log_warn "Rule #$rule_index: Unknown command '$cmd'"
            ;;
    esac
done < "$RULE_CACHE"

# ============================================================
# SUMMARY
# ============================================================
log_section "SUMMARY"
log_info "Rules processed: $rule_index"
log_info "Rules applied: $count"
log_info "Rules failed: $fail_count"
log_info "Early boot hook complete at $(date)"

# Always exit successfully - never fail boot
exit 0
