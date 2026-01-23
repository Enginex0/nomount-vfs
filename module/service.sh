#!/system/bin/sh
# NoMount Universal Hijacker - service.sh
# LATE BOOT PHASE: VFS registration (KPM should be loaded by now)
# Non-blocking check - if /dev/vfs_helper unavailable, skip gracefully
# NOTE: Uses /system/bin/sh for `local` keyword support (mksh on Android)
#
# Logs: /data/adb/nomount/logs/frontend/service.log

MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR="."  # Fallback if invoked without path
MODULES_DIR="/data/adb/modules"

# ============================================================
# LOGGING LIBRARY INITIALIZATION
# ============================================================
NOMOUNT_DATA="/data/adb/nomount"
if [ -f "$MODDIR/logging.sh" ]; then
    . "$MODDIR/logging.sh"
    log_init "service"
else
    # Fallback logging if library not found
    mkdir -p "$NOMOUNT_DATA/logs/frontend" 2>/dev/null
    _LOG_FILE="$NOMOUNT_DATA/logs/frontend/service.log"
    log_debug() { echo "[$(date '+%H:%M:%S')] [DEBUG] $*" >> "$_LOG_FILE"; }
    log_info() { echo "[$(date '+%H:%M:%S')] [INFO ] $*" >> "$_LOG_FILE"; }
    log_warn() { echo "[$(date '+%H:%M:%S')] [WARN ] $*" >> "$_LOG_FILE"; }
    log_err() { echo "[$(date '+%H:%M:%S')] [ERROR] $*" >> "$_LOG_FILE"; }
    log_trace() { echo "[$(date '+%H:%M:%S')] [TRACE] $*" >> "$_LOG_FILE"; }
    log_func_enter() { local f="$1"; shift; log_debug ">>> ENTER: $f($*)"; }
    log_func_exit() { log_debug "<<< EXIT: $1 (result=$2)"; }
    log_section() { log_info "========== $1 =========="; }
fi

# ============================================================
# FUNCTION: Detect device architecture
# Returns: arm64, arm, x86_64, or x86
# ============================================================
get_arch() {
    local abi=$(getprop ro.product.cpu.abi)
    local result
    case "$abi" in
        arm64*) result="arm64" ;;
        armeabi*|arm*) result="arm" ;;
        x86_64*) result="x86_64" ;;
        x86*) result="x86" ;;
        *) result="arm64" ;;
    esac
    echo "$result"
}

# ============================================================
# FUNCTION: Find nm binary dynamically
# Checks multiple possible locations for flexibility
# Supports both arm64 and arm32 architectures
# ============================================================
find_nm_binary() {
    local arch=$(get_arch)
    local possible_paths="
        $MODDIR/bin/nm
        $MODDIR/nm-$arch
        $MODDIR/nm
        /data/adb/modules/nomount/bin/nm
        /data/adb/modules/nomount/nm-$arch
        /data/adb/modules/nomount/nm
    "
    for path in $possible_paths; do
        if [ -x "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    log_err "nm binary not found"
    return 1
}

LOADER=$(find_nm_binary)
if [ -z "$LOADER" ]; then
    log_err "nm binary not found!"
    exit 1
fi
log_info "Using nm binary: $LOADER"

# ============================================================
# SUSFS INTEGRATION - Tight Coupling Module
# ============================================================
SUSFS_INTEGRATION="$MODDIR/susfs_integration.sh"
if [ -f "$SUSFS_INTEGRATION" ]; then
    . "$SUSFS_INTEGRATION"
else
    log_warn "SUSFS integration module not found: $SUSFS_INTEGRATION"
fi

# Legacy LOG_FILE for backward compatibility
LOG_FILE="$NOMOUNT_DATA/logs/frontend/service.log"
CONFIG_FILE="$NOMOUNT_DATA/config.sh"
VERBOSE_FLAG="$NOMOUNT_DATA/.verbose"
# Expanded partition list (matching Mountify's coverage)
TARGET_PARTITIONS="system vendor product system_ext odm oem mi_ext my_heytap prism optics oem_dlkm system_dlkm vendor_dlkm"

# Counters
ACTIVE_MODULES_COUNT=0
HIJACKED_OVERLAYS_COUNT=0
FAILED_COUNT=0
VFS_REGISTERED_COUNT=0
START_TIME=$(date +%s)

# Track processed modules to avoid double registration in universal_hijack mode
PROCESSED_MODULES=""

# Ensure data directory exists before any writes
mkdir -p "$NOMOUNT_DATA" 2>/dev/null
chmod 755 "$NOMOUNT_DATA" 2>/dev/null

# Cleanup handler for temp files on unexpected exit
cleanup_on_exit() {
    rm -f "$NOMOUNT_DATA/.vfs_count_"* 2>/dev/null
    rm -f "$NOMOUNT_DATA/.rule_cache_"* 2>/dev/null
    rm -f "$NOMOUNT_DATA/.*_$$" 2>/dev/null
}
trap cleanup_on_exit EXIT INT TERM HUP

# Clean stale temp files from previous crashed sessions
# Only delete if file is old AND the PID in filename is not running
for stale_file in "$NOMOUNT_DATA"/.*_*; do
    [ -f "$stale_file" ] || continue
    # Extract PID from filename (pattern: .something_PID)
    stale_pid="${stale_file##*_}"
    # Only delete if PID is numeric and process is not running
    case "$stale_pid" in
        ''|*[!0-9]*) continue ;;  # Skip if not numeric
    esac
    if ! kill -0 "$stale_pid" 2>/dev/null; then
        rm -f "$stale_file" 2>/dev/null
    fi
done

# ============================================================
# External Sync Trigger API Directory
# ============================================================
# Create sync_trigger directory for external module integration.
# External modules can trigger a sync by creating a marker file:
#   touch /data/adb/nomount/sync_trigger/<module_name>
# The monitor will call sync.sh for that specific module.
# ============================================================
SYNC_TRIGGER_DIR="$NOMOUNT_DATA/sync_trigger"
mkdir -p "$SYNC_TRIGGER_DIR" 2>/dev/null

# ============================================================
# LOGGING CONFIGURATION
# Note: Logging functions are provided by logging.sh (sourced at top)
# ============================================================
LOG_LEVEL="${LOG_LEVEL:-4}"  # 0=off, 1=error, 2=warn, 3=info, 4=debug, 5=trace

# Override log_err to also increment FAILED_COUNT
# Note: We wrap the original function directly (mksh-compatible)
if type log_err >/dev/null 2>&1; then
    # Save original as alias-style wrapper
    _log_err_orig() {
        _log_write "ERROR" "$@"
    }
else
    _log_err_orig() { echo "[ERROR] $*" >&2; }
fi
log_err() {
    _log_err_orig "$@"
    FAILED_COUNT=$((FAILED_COUNT + 1))
}

# Legacy log_cmd for backward compatibility
log_cmd() {
    local cmd="$1"
    local result
    result=$(eval "$cmd" 2>&1)
    local rc=$?
    [ $rc -ne 0 ] && log_err "CMD FAIL (rc=$rc): $cmd -> $result"
    echo "$result"
    return $rc
}

# Session header
log_section "SERVICE.SH PHASE (Late Boot)"
log_info "MODDIR=$MODDIR, LOADER=$LOADER"
echo "" >> "$LOG_FILE"

# Initialize skip_mount tracking (fresh on each boot)
: > "$NOMOUNT_DATA/skipped_modules"

# Load config with security checks
universal_hijack=true
aggressive_mode=false
monitor_new_modules=true
excluded_modules=""
skip_hosts_modules=true
skip_nomount_marker=true

# Only source config if owned by root and not world-writable
if [ -f "$CONFIG_FILE" ]; then
    config_owner=$(stat -c '%u' "$CONFIG_FILE" 2>/dev/null)
    config_perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null)
    if [ "$config_owner" = "0" ] && [ "${config_perms#*2}" = "$config_perms" ]; then
        . "$CONFIG_FILE"
    else
        log_warn "Config file has unsafe permissions (owner=$config_owner, perms=$config_perms), using defaults"
    fi
fi

# Verbose mode
VERBOSE=false
[ -f "$VERBOSE_FLAG" ] && VERBOSE=true

# ============================================================
# FUNCTION: Legacy logging helper (compatibility wrapper)
# ============================================================
log() {
    log_info "$1"
}

# ============================================================
# FUNCTION: Detect root framework
# ============================================================
detect_framework() {
    if [ -d "/data/adb/ksu" ] && [ -f "/data/adb/ksu/modules.img" ]; then
        echo "kernelsu"
    elif [ -d "/data/adb/ap" ]; then
        echo "apatch"
    elif [ -d "/data/adb/magisk" ]; then
        echo "magisk"
    else
        echo "unknown"
    fi
}

FRAMEWORK=$(detect_framework)
log_info "Detected framework: $FRAMEWORK"

# ============================================================
# SUSFS INTEGRATION INITIALIZATION
# ============================================================
if type susfs_init >/dev/null 2>&1; then
    log_info "Initializing SUSFS integration..."
    if susfs_init; then
        log_info "SUSFS integration initialized successfully"
        susfs_status >> "$LOG_FILE"
    else
        log_info "SUSFS not available - continuing in NoMount-only mode"
    fi
else
    log_info "SUSFS integration module not loaded"
    HAS_SUSFS=0
fi

# APatch-specific handling
if [ "$FRAMEWORK" = "apatch" ] && [ -d "/data/adb/ap/modules" ]; then
    MODULES_DIR="/data/adb/ap/modules"
    log_info "APatch mode - using modules dir: $MODULES_DIR"
fi

# ============================================================
# NON-BLOCKING CHECK: Is /dev/vfs_helper available?
# ============================================================
if [ ! -c "/dev/vfs_helper" ]; then
    log_info "/dev/vfs_helper not available - VFS registration skipped"
    sh "$MODDIR/monitor.sh" "0" "0" &
    exit 0
fi
log_info "VFS driver ready: /dev/vfs_helper"

# ============================================================
# HIDE /dev/vfs_helper FROM NON-ROOT DETECTION APPS
# ============================================================
# Kernel-level hiding returns ENOENT for non-root open() calls
# SUSFS sus_path provides additional protection (hides from readdir too)
# We must hide: /dev/vfs_helper, /sys/class/misc/vfs_helper, /sys/devices/virtual/misc/vfs_helper
log_info "Hiding VFS device from detection apps..."
if command -v ksu_susfs >/dev/null 2>&1; then
    log_debug "SUSFS available, hiding device paths"
    # Hide device node
    if ksu_susfs add_sus_path /dev/vfs_helper 2>/dev/null; then
        log_debug "Hidden: /dev/vfs_helper"
    else
        log_err "Failed to hide /dev/vfs_helper via SUSFS"
    fi
    # Hide sysfs class entry (detectable via stat/readdir)
    if ksu_susfs add_sus_path /sys/class/misc/vfs_helper 2>/dev/null; then
        log_debug "Hidden: /sys/class/misc/vfs_helper"
    else
        log_debug "Could not hide /sys/class/misc/vfs_helper (may not exist)"
    fi
    # Hide sysfs device entry
    if ksu_susfs add_sus_path /sys/devices/virtual/misc/vfs_helper 2>/dev/null; then
        log_debug "Hidden: /sys/devices/virtual/misc/vfs_helper"
    else
        log_debug "Could not hide /sys/devices/virtual/misc/vfs_helper (may not exist)"
    fi
    log_info "VFS device hidden via SUSFS (dev + sysfs)"
else
    log_info "SUSFS not available - relying on kernel-level hiding only"
    log_debug "/sys/class/misc/vfs_helper may still be visible to detection apps"
fi

echo "" >> "$LOG_FILE"

# ============================================================
# FUNCTION: Check if module is excluded (by name)
# ============================================================
is_excluded() {
    echo "$excluded_modules" | grep -qw "$1"
}

# ============================================================
# FUNCTION: Content-aware module filtering
# Returns 0 if module should be skipped, 1 otherwise
# ============================================================
should_skip_module() {
    local mod_path="$1"
    local mod_name="$2"

    # Check for skip_nomount marker
    if [ "$skip_nomount_marker" = "true" ] && [ -f "$mod_path/skip_nomount" ]; then
        log_info "SKIP: $mod_name has skip_nomount marker"
        return 0
    fi

    # Check for hosts file modification (detection risk)
    if [ "$skip_hosts_modules" = "true" ]; then
        for partition in $TARGET_PARTITIONS; do
            if [ -f "$mod_path/$partition/etc/hosts" ]; then
                log_info "SKIP: $mod_name modifies /etc/hosts"
                return 0
            fi
        done
    fi

    return 1
}

# ============================================================
# FUNCTION: Detect ALL module-related mounts (universal hijacking)
# Detects: overlay mounts, bind mounts, loop mounts, tmpfs
# ============================================================
detect_all_module_mounts() {
    log_info "Scanning for module-related mounts..."

    local mounts_snapshot
    if [ -n "$CACHED_PROC_MOUNTS" ]; then
        mounts_snapshot="$CACHED_PROC_MOUNTS"
    else
        mounts_snapshot=$(cat /proc/mounts 2>&1)
        [ $? -ne 0 ] && { log_err "Failed to read /proc/mounts"; return 1; }
    fi

    # 1. Overlay mounts on target partitions
    echo "$mounts_snapshot" | while read -r device mountpoint fstype options rest; do
        if [ "$fstype" = "overlay" ]; then
            for partition in $TARGET_PARTITIONS; do
                if echo "$mountpoint" | grep -q "^/$partition"; then
                    echo "overlay:$mountpoint"
                    log_info "Found overlay: $mountpoint"
                fi
            done
        fi
    done

    # 2. Bind mounts (source contains /data/adb/modules)
    echo "$mounts_snapshot" | while read -r device mountpoint fstype options rest; do
        if echo "$options" | grep -q "bind"; then
            if echo "$device" | grep -q "/data/adb/modules"; then
                echo "bind:$mountpoint"
                log_info "Found bind mount: $mountpoint"
            fi
        fi
    done

    # 3. Check for bind mounts via same device/inode on target partitions
    echo "$mounts_snapshot" | while read -r device mountpoint fstype options rest; do
        for partition in $TARGET_PARTITIONS; do
            if echo "$mountpoint" | grep -q "^/$partition" && [ "$fstype" != "overlay" ]; then
                if [ -d "$MODULES_DIR" ]; then
                    for mod_dir in "$MODULES_DIR"/*; do
                        [ -d "$mod_dir" ] || continue
                        if [ -d "$mod_dir$mountpoint" ]; then
                            real_dev=$(stat -c %d "$mod_dir$mountpoint" 2>/dev/null)
                            mount_dev=$(stat -c %d "$mountpoint" 2>/dev/null)
                            if [ "$real_dev" = "$mount_dev" ] && [ -n "$real_dev" ]; then
                                echo "bind:$mountpoint"
                                log_info "Found hidden bind: $mountpoint"
                            fi
                        fi
                    done
                fi
            fi
        done
    done

    # 4. Loop mounts from module paths
    if command -v losetup >/dev/null 2>&1; then
        losetup -a 2>/dev/null | grep -E "modules|magisk" | while read -r loop_line; do
            loop_dev=$(echo "$loop_line" | cut -d: -f1)
            if echo "$mounts_snapshot" | grep -q "^$loop_dev "; then
                loop_mount=$(echo "$mounts_snapshot" | grep "^$loop_dev " | awk '{print $2}')
                echo "loop:$loop_mount"
                log_info "Found loop mount: $loop_mount"
            fi
        done
    fi

    # 5. tmpfs at suspicious locations
    echo "$mounts_snapshot" | while read -r device mountpoint fstype options rest; do
        if [ "$fstype" = "tmpfs" ]; then
            for partition in $TARGET_PARTITIONS; do
                if echo "$mountpoint" | grep -q "^/$partition"; then
                    echo "tmpfs:$mountpoint"
                    log_info "Found tmpfs: $mountpoint"
                fi
            done
        fi
    done
}

# ============================================================
# FUNCTION: Check if overlay mount is from a module (not system)
# Returns 0 if module overlay, 1 if system overlay
# ============================================================
is_module_overlay() {
    local mountpoint="$1"

    local mount_line
    if [ -n "$CACHED_PROC_MOUNTS" ]; then
        mount_line=$(echo "$CACHED_PROC_MOUNTS" | grep " $mountpoint overlay ")
    else
        mount_line=$(grep " $mountpoint overlay " /proc/mounts 2>/dev/null)
    fi
    local options=$(echo "$mount_line" | awk '{print $4}')

    # Check if any option contains known module paths
    echo "$options" | grep -qE "/data/adb/(modules|ksu|ap|magisk)/" && return 0
    echo "$options" | grep -qE "/data/adb/[^/]+/modules/" && return 0

    # Fallback: Check if ANY module has content for this mountpoint
    local relative="${mountpoint#/}"
    for mod_dir in "$MODULES_DIR"/*; do
        [ -d "$mod_dir" ] || continue
        [ -d "$mod_dir/$relative" ] || [ -f "$mod_dir/$relative" ] && return 0
    done

    return 1
}

# ============================================================
# FUNCTION: Find module that owns an overlay mount
# Returns module name or empty string
# ============================================================
find_module_for_overlay() {
    local mountpoint="$1"

    local mount_line
    if [ -n "$CACHED_PROC_MOUNTS" ]; then
        mount_line=$(echo "$CACHED_PROC_MOUNTS" | grep " $mountpoint overlay ")
    else
        mount_line=$(grep " $mountpoint overlay " /proc/mounts 2>/dev/null)
    fi
    local options=$(echo "$mount_line" | awk '{print $4}')

    # Try lowerdir first (most common)
    local lowerdir=$(echo "$options" | tr ',' '\n' | grep "^lowerdir=" | sed 's/lowerdir=//' | cut -d: -f1)
    if echo "$lowerdir" | grep -q "/data/adb/modules/"; then
        echo "$lowerdir" | sed 's|.*/data/adb/modules/||' | cut -d/ -f1
        return
    fi

    # Try upperdir
    local upperdir=$(echo "$options" | tr ',' '\n' | grep "^upperdir=" | sed 's/upperdir=//')
    if echo "$upperdir" | grep -q "/data/adb/modules/"; then
        echo "$upperdir" | sed 's|.*/data/adb/modules/||' | cut -d/ -f1
        return
    fi

    # Try workdir
    local workdir=$(echo "$options" | tr ',' '\n' | grep "^workdir=" | sed 's/workdir=//')
    if echo "$workdir" | grep -q "/data/adb/modules/"; then
        echo "$workdir" | sed 's|.*/data/adb/modules/||' | cut -d/ -f1
        return
    fi

    # Check all lowerdir entries
    local all_lowerdirs=$(echo "$options" | tr ',' '\n' | grep "^lowerdir=" | sed 's/lowerdir=//' | tr ':' '\n')
    for dir in $all_lowerdirs; do
        if echo "$dir" | grep -q "/data/adb/modules/"; then
            echo "$dir" | sed 's|.*/data/adb/modules/||' | cut -d/ -f1
            return
        fi
    done

    echo ""
}

# ============================================================
# FUNCTION: Register .so files with SUSFS sus_map for /proc/maps hiding
# ============================================================
register_sus_map_for_module() {
    local mod_path="$1"
    local mod_name="$2"
    local so_count=0

    command -v ksu_susfs >/dev/null 2>&1 || return

    for partition in $TARGET_PARTITIONS; do
        if [ -d "$mod_path/$partition" ]; then
            find "$mod_path/$partition" -name "*.so" -type f 2>/dev/null | while read -r so_file; do
                if ksu_susfs add_sus_map "$so_file" < /dev/null 2>/dev/null; then
                    so_count=$((so_count + 1))
                else
                    log_err "SUS_MAP failed: $so_file"
                fi
            done
        fi
    done
}

# ============================================================
# FUNCTION: Register files from a module directory via VFS
# ============================================================
register_module_vfs() {
    local mod_path="$1"
    local mod_name="$2"
    local file_count=0
    local success_count=0
    local whiteout_count=0

    # Path tracking for monitor.sh to detect file changes later
    local tracking_dir="$NOMOUNT_DATA/module_paths"
    local tracking_file="$tracking_dir/$mod_name"
    mkdir -p "$tracking_dir"
    : > "$tracking_file"

    # Use temp file to accumulate counts (avoids subshell variable isolation from pipe)
    local count_file="$NOMOUNT_DATA/.vfs_count_$$"
    echo "0 0 0" > "$count_file"  # file_count success_count whiteout_count

    for partition in $TARGET_PARTITIONS; do
        if [ -d "$mod_path/$partition" ]; then
            find "$mod_path/$partition" -type f -o -type c 2>/dev/null | while read -r real_path; do
                virtual_path="${real_path#$mod_path}"

                # Skip marker files
                case "${real_path##*/}" in
                    .replace|.remove|.gitkeep|.nomedia|.placeholder) continue ;;
                esac

                read f_cnt s_cnt w_cnt < "$count_file"
                f_cnt=$((f_cnt + 1))

                if [ -c "$real_path" ]; then
                    # Whiteout (character device)
                    if "$LOADER" add "$virtual_path" "/nonexistent" < /dev/null 2>/dev/null; then
                        w_cnt=$((w_cnt + 1))
                        s_cnt=$((s_cnt + 1))
                        echo "VFS_INC" >> "$count_file.global"
                        [ "$HAS_SUSFS" = "1" ] && type susfs_apply_path >/dev/null 2>&1 && susfs_apply_path "$virtual_path" 0
                    else
                        log_err "VFS add failed (whiteout): $virtual_path"
                    fi
                else
                    # Regular file injection
                    if type nm_register_rule_with_susfs >/dev/null 2>&1 && [ "$HAS_SUSFS" = "1" ]; then
                        if nm_register_rule_with_susfs "$virtual_path" "$real_path" "$LOADER"; then
                            s_cnt=$((s_cnt + 1))
                            echo "VFS_INC" >> "$count_file.global"
                        else
                            log_err "VFS+SUSFS failed: $virtual_path"
                        fi
                    else
                        if "$LOADER" add "$virtual_path" "$real_path" < /dev/null 2>/dev/null; then
                            s_cnt=$((s_cnt + 1))
                            echo "VFS_INC" >> "$count_file.global"
                        else
                            log_err "VFS add failed: $virtual_path"
                        fi
                    fi
                fi

                echo "$f_cnt $s_cnt $w_cnt" > "$count_file"
                echo "$virtual_path" >> "$tracking_file"
            done
        fi
    done

    if [ -f "$count_file" ]; then
        read file_count success_count whiteout_count < "$count_file"
        rm -f "$count_file"
    fi

    if [ -f "$count_file.global" ]; then
        local global_inc=$(wc -l < "$count_file.global")
        VFS_REGISTERED_COUNT=$((VFS_REGISTERED_COUNT + global_inc))
        rm -f "$count_file.global"
    fi

    log_info "Module $mod_name: $success_count files registered"
    register_sus_map_for_module "$mod_path" "$mod_name"
}

# ============================================================
# FUNCTION: Hijack a single mount (any type)
# ============================================================
hijack_mount() {
    local mount_info="$1"
    local mount_type="${mount_info%%:*}"
    local mountpoint="${mount_info#*:}"

    log_info "Hijacking $mount_type mount: $mountpoint"

    # For overlay mounts, verify it's from a module, not Android system
    if [ "$mount_type" = "overlay" ]; then
        if ! is_module_overlay "$mountpoint"; then
            log_info "SKIP: System overlay - preserving"
            return 0
        fi
    fi

    local mod_name=""
    case "$mount_type" in
        overlay)
            mod_name=$(find_module_for_overlay "$mountpoint")
            ;;
        bind|loop|tmpfs)
            for mod_dir in "$MODULES_DIR"/*; do
                [ -d "$mod_dir" ] || continue
                local test_mod="${mod_dir##*/}"
                for partition in $TARGET_PARTITIONS; do
                    if [ -d "$mod_dir/$partition" ]; then
                        local relative="${mountpoint#/}"
                        if [ -e "$mod_dir/$relative" ]; then
                            mod_name="$test_mod"
                            break 2
                        fi
                    fi
                done
            done
            ;;
    esac

    if [ -z "$mod_name" ]; then
        log_err "Could not determine owning module for mount: $mountpoint"
        return 1
    fi

    local mod_path="$MODULES_DIR/$mod_name"

    is_excluded "$mod_name" && { log_info "SKIP: $mod_name excluded"; return 0; }
    should_skip_module "$mod_path" "$mod_name" && return 0
    [ ! -d "$mod_path" ] && { log_err "Module directory not found: $mod_path"; return 1; }

    PROCESSED_MODULES="$PROCESSED_MODULES $mod_name "
    register_module_vfs "$mod_path" "$mod_name"

    local umount_output
    umount_output=$(umount -l "$mountpoint" 2>&1)
    local umount_rc=$?

    if [ $umount_rc -eq 0 ]; then
        log_info "Unmounted: $mountpoint"
        HIJACKED_OVERLAYS_COUNT=$((HIJACKED_OVERLAYS_COUNT + 1))
        return 0
    else
        log_err "Unmount failed: $mountpoint - $umount_output"
        [ "$aggressive_mode" = "true" ] && return 0
        return 1
    fi
}

# ============================================================
# FUNCTION: Process modules directly via VFS
# ============================================================
process_modules_direct() {
    log_info "Processing modules directly via VFS..."

    for mod_path in "$MODULES_DIR"/*; do
        [ -d "$mod_path" ] || continue
        mod_name="${mod_path##*/}"

        [ "$mod_name" = "nomount" ] && continue
        [ -f "$mod_path/disable" ] && continue
        [ -f "$mod_path/remove" ] && continue
        is_excluded "$mod_name" && continue
        echo "$PROCESSED_MODULES" | grep -q " $mod_name " && continue
        should_skip_module "$mod_path" "$mod_name" && continue

        has_content=false
        for partition in $TARGET_PARTITIONS; do
            [ -d "$mod_path/$partition" ] && { has_content=true; break; }
        done

        if [ "$has_content" = "true" ]; then
            register_module_vfs "$mod_path" "$mod_name"
            ACTIVE_MODULES_COUNT=$((ACTIVE_MODULES_COUNT + 1))
        fi
    done

    log_info "Direct processing complete: $ACTIVE_MODULES_COUNT modules"
}

# ============================================================
# PHASE 1: Cache partition device IDs (SUSFS-independent)
# Must run EARLY before overlays change device IDs
# ============================================================
cache_partition_devs() {
    log_info "Phase 1: Caching partition device IDs..."

    local part_id=0
    local cached_count=0

    for partition in system vendor product system_ext odm oem mi_ext my_heytap prism optics oem_dlkm system_dlkm vendor_dlkm; do
        if [ -d "/$partition" ]; then
            local dev_dec=$(stat -c '%d' "/$partition" 2>/dev/null)
            if [ -n "$dev_dec" ] && [ "$dev_dec" -gt 0 ]; then
                local major=$((dev_dec >> 8))
                local minor=$((dev_dec & 255))
                if "$LOADER" setdev "$part_id" "$major" "$minor" 2>/dev/null; then
                    cached_count=$((cached_count + 1))
                else
                    log_err "setdev failed for /$partition"
                fi
            fi
        fi
        part_id=$((part_id + 1))
    done

    log_info "Phase 1 complete: $cached_count partitions cached"
}

# ============================================================
# PHASE 2: Register hidden mounts (SUSFS-independent)
# Hides overlay/tmpfs mounts from /proc/mounts, /proc/self/mountinfo
# ============================================================
register_hidden_mounts() {
    log_info "Phase 2: Registering hidden mounts..."

    local count=0
    local fail_count=0

    while IFS=' ' read -r mount_id rest; do
        local fstype=$(echo "$rest" | sed 's/.* - //' | cut -d' ' -f1)
        local mount_point=$(echo "$rest" | cut -d' ' -f4)

        case "$fstype" in
            overlay|tmpfs)
                for partition in $TARGET_PARTITIONS; do
                    if echo "$mount_point" | grep -qE "^/$partition(/|$)"; then
                        if "$LOADER" hide "$mount_id" 2>/dev/null; then
                            count=$((count + 1))
                        else
                            log_err "Failed to hide mount $mount_id ($mount_point)"
                            fail_count=$((fail_count + 1))
                        fi
                        break
                    fi
                done
                ;;
        esac
    done < /proc/self/mountinfo

    log_info "Phase 2 complete: $count mounts hidden"
}

# ============================================================
# PHASE 3: Register maps patterns (SUSFS-independent)
# Hides suspicious paths from /proc/self/maps
# ============================================================
register_maps_patterns() {
    log_info "Phase 3: Registering maps patterns..."

    local count=0
    for pattern in "/data/adb" "magisk" "kernelsu" "zygisk"; do
        if "$LOADER" addmap "$pattern" 2>/dev/null; then
            count=$((count + 1))
        else
            log_err "Failed to register maps pattern: $pattern"
        fi
    done

    log_info "Phase 3 complete: $count patterns registered"
}

# ============================================================
# MAIN EXECUTION (late boot phase)
# ============================================================
log_info "========== MAIN EXECUTION =========="
log_info "Config: universal_hijack=$universal_hijack, aggressive_mode=$aggressive_mode"

# ============================================================
# SUSFS-INDEPENDENT VFS HIDING (Phases 1-3)
# These run BEFORE file registration for complete detection evasion
# ============================================================
log_info "========== SUSFS-INDEPENDENT VFS HIDING =========="
cache_partition_devs
register_hidden_mounts
register_maps_patterns

# NOTE: We intentionally do NOT call "nm clear" here.
# Clearing rules creates a race condition where fonts/libraries become
# temporarily inaccessible, causing apps like Gboard to crash.
# Instead, we register new rules (which overwrite old ones) and let
# save_rule_cache() generate a clean cache at the end. Orphaned rules
# for removed/disabled modules are harmless until next boot.
# See: https://github.com/user/nomount/issues/XXX

# Cache /proc/mounts BEFORE enabling hooks (prevents kernel deadlock)
CACHED_PROC_MOUNTS=$(cat /proc/mounts 2>/dev/null)
export CACHED_PROC_MOUNTS

mount_list=""
if [ "$universal_hijack" = "true" ]; then
    log_info "========== UNIVERSAL HIJACKER MODE =========="
    mount_list=$(detect_all_module_mounts)
    mount_count=$(echo "$mount_list" | grep -c . || echo 0)
    log_info "Detected $mount_count module-related mounts"
fi

# Enable NoMount hooks - after mount detection is complete
if "$LOADER" enable < /dev/null 2>/dev/null; then
    log_info "NoMount VFS hooks ENABLED"
else
    log_err "FATAL: Failed to enable NoMount hooks!"
    exit 1
fi

if [ "$universal_hijack" = "true" ]; then
    if [ -n "$mount_list" ]; then
        hijack_success=0
        hijack_fail=0

        while read -r mount_info; do
            if [ -n "$mount_info" ]; then
                if hijack_mount "$mount_info"; then
                    hijack_success=$((hijack_success + 1))
                else
                    hijack_fail=$((hijack_fail + 1))
                fi
            fi
        done <<EOF
$mount_list
EOF

        log_info "Hijacking complete: $hijack_success ok, $hijack_fail failed"
    fi
    process_modules_direct
else
    log_info "========== STANDARD MODE =========="
    process_modules_direct
fi

# Handle UID exclusion list
if [ -f "$NOMOUNT_DATA/.exclusion_list" ]; then
    uid_count=0
    while IFS= read -r uid; do
        [ -z "$uid" ] && continue
        if "$LOADER" blk "$uid" 2>/dev/null; then
            uid_count=$((uid_count + 1))
        else
            log_err "Failed to block UID: $uid"
        fi
    done < "$NOMOUNT_DATA/.exclusion_list"
    [ "$uid_count" -gt 0 ] && log_info "UIDs blocked: $uid_count"
fi

# Calculate execution time
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# Summary
log_info ""
log_info "========== EXECUTION SUMMARY =========="
log_info "Framework: $FRAMEWORK"
log_info "Mode: $([ \"$universal_hijack\" = \"true\" ] && echo 'Universal Hijacker' || echo 'Standard')"
log_info "Modules processed: $ACTIVE_MODULES_COUNT"
log_info "Overlays hijacked: $HIJACKED_OVERLAYS_COUNT"
log_info "VFS files registered: $VFS_REGISTERED_COUNT"
log_info "Failed operations: $FAILED_COUNT"
log_info "Execution time: ${ELAPSED}s"

# SUSFS Integration Status
if [ "$HAS_SUSFS" = "1" ]; then
    log_info "SUSFS Integration: ACTIVE"
    log_info "  - sus_path: $HAS_SUS_PATH"
    log_info "  - sus_kstat: $HAS_SUS_KSTAT"
    log_info "  - sus_mount: $HAS_SUS_MOUNT"
    log_info "  - sus_maps: $HAS_SUS_MAPS"
else
    log_info "SUSFS Integration: DISABLED (NoMount-only mode)"
fi

log_info "Completed: $(date)"
log_info "=========================================="

# ============================================================
# Save VFS rules to cache for early boot registration
# ============================================================
save_rule_cache() {
    local cache_file="$NOMOUNT_DATA/.rule_cache"
    local temp_file="$NOMOUNT_DATA/.rule_cache_tmp_$$"
    local filtered_count=0

    : > "$temp_file"
    echo "# NoMount VFS Rule Cache - $(date)" >> "$temp_file"

    local list_output
    list_output=$("$LOADER" list 2>/dev/null)
    local filter_count_file="$NOMOUNT_DATA/.filter_count_$$"
    echo "0" > "$filter_count_file"

    if [ $? -eq 0 ] && [ -n "$list_output" ]; then
        echo "$list_output" | while IFS= read -r line; do
            [ -z "$line" ] && continue
            local rpath="${line%%->*}"
            local vpath="${line##*->}"
            local include_rule=1

            # Validate real_path exists
            if [ -n "$rpath" ] && [ "$rpath" != "/nonexistent" ] && [ ! -e "$rpath" ]; then
                include_rule=0
                echo "FILTER" >> "$filter_count_file"
            fi

            # Validate module is active
            if [ "$include_rule" = "1" ] && echo "$rpath" | grep -q "/data/adb/modules/"; then
                local mod_name=$(echo "$rpath" | sed 's|.*/data/adb/modules/||' | cut -d/ -f1)
                local mod_path="$MODULES_DIR/$mod_name"
                if [ -f "$mod_path/disable" ] || [ -f "$mod_path/remove" ] || [ ! -d "$mod_path" ]; then
                    include_rule=0
                    echo "FILTER" >> "$filter_count_file"
                fi
            fi

            # Skip marker files
            case "${rpath##*/}" in
                .replace|.remove|.gitkeep|.nomedia|.placeholder) include_rule=0 ;;
            esac

            [ "$include_rule" = "1" ] && [ -n "$vpath" ] && [ -n "$rpath" ] && echo "add|$vpath|$rpath" >> "$temp_file"
        done
    fi

    if [ -f "$filter_count_file" ]; then
        filtered_count=$(grep -c "FILTER" "$filter_count_file" 2>/dev/null || echo 0)
        rm -f "$filter_count_file"
    fi

    # Cache partition device IDs
    local part_id=0
    for partition in system vendor product system_ext odm oem mi_ext my_heytap prism optics oem_dlkm system_dlkm vendor_dlkm; do
        if [ -d "/$partition" ]; then
            local dev_dec=$(stat -c '%d' "/$partition" 2>/dev/null)
            if [ -n "$dev_dec" ] && [ "$dev_dec" -gt 0 ]; then
                local major=$((dev_dec >> 8))
                local minor=$((dev_dec & 255))
                echo "setdev|$part_id|$major:$minor" >> "$temp_file"
            fi
        fi
        part_id=$((part_id + 1))
    done

    for pattern in "/data/adb" "magisk" "kernelsu" "zygisk"; do
        echo "addmap|$pattern|" >> "$temp_file"
    done

    # Deduplicate and save
    local dedup_file="$NOMOUNT_DATA/.rule_cache_dedup_$$"
    grep "^#" "$temp_file" > "$dedup_file" 2>/dev/null || true
    grep -v "^#" "$temp_file" | sort -u >> "$dedup_file" 2>/dev/null || true
    mv "$dedup_file" "$temp_file" 2>/dev/null

    if mv "$temp_file" "$cache_file" 2>/dev/null; then
        local count=$(grep -c "^add|" "$cache_file" 2>/dev/null || echo 0)
        log_info "Rule cache saved: $count rules (filtered $filtered_count stale)"
        chmod 600 "$cache_file" 2>/dev/null
    else
        log_err "Failed to save rule cache"
        rm -f "$temp_file" 2>/dev/null
    fi
}

# Call save_rule_cache at end of successful execution
save_rule_cache

# Start monitor
if [ "$monitor_new_modules" = "true" ]; then
    sh "$MODDIR/monitor.sh" "$ACTIVE_MODULES_COUNT" "$HIJACKED_OVERLAYS_COUNT" &
fi
