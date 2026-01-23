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
    log_func_enter "get_arch"
    local abi=$(getprop ro.product.cpu.abi)
    local rc=$?
    log_trace "getprop ro.product.cpu.abi returned: '$abi' (rc=$rc)"

    local result
    case "$abi" in
        arm64*) result="arm64" ;;
        armeabi*|arm*) result="arm" ;;
        x86_64*) result="x86_64" ;;
        x86*) result="x86" ;;
        *)
            result="arm64"
            log_debug "Unknown ABI '$abi', defaulting to arm64"
            ;;
    esac
    log_func_exit "get_arch" "$result"
    echo "$result"
}

# ============================================================
# FUNCTION: Find nm binary dynamically
# Checks multiple possible locations for flexibility
# Supports both arm64 and arm32 architectures
# ============================================================
find_nm_binary() {
    log_func_enter "find_nm_binary"
    local arch=$(get_arch)
    log_debug "Architecture: $arch"

    local possible_paths="
        $MODDIR/bin/nm
        $MODDIR/nm-$arch
        $MODDIR/nm
        /data/adb/modules/nomount/bin/nm
        /data/adb/modules/nomount/nm-$arch
        /data/adb/modules/nomount/nm
    "
    local checked=0
    for path in $possible_paths; do
        checked=$((checked + 1))
        log_trace "Checking path [$checked]: $path"
        if [ -x "$path" ]; then
            log_debug "Found nm binary: $path"
            log_func_exit "find_nm_binary" "$path"
            echo "$path"
            return 0
        fi
    done

    log_err "nm binary not found after checking $checked paths"
    log_func_exit "find_nm_binary" "NOT_FOUND"
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
    log_debug "Loading SUSFS integration module"
    . "$SUSFS_INTEGRATION"
    log_debug "SUSFS integration module loaded"
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
    log_func_enter "log_cmd" "$1"
    local cmd="$1"
    local result
    result=$(eval "$cmd" 2>&1)
    local rc=$?
    if [ $rc -eq 0 ]; then
        log_debug "CMD OK: $cmd"
    else
        log_err "CMD FAIL (rc=$rc): $cmd -> $result"
    fi
    log_func_exit "log_cmd" "$rc"
    echo "$result"
    return $rc
}

# Session header
log_section "SERVICE.SH PHASE (Late Boot)"
log_info "Script version: 3.0-unified-logging"
log_info "MODDIR=$MODDIR"
log_info "LOADER=$LOADER"
log_info "MODULES_DIR=$MODULES_DIR"
log_info "NOMOUNT_DATA=$NOMOUNT_DATA"
log_info "LOG_LEVEL=$LOG_LEVEL"
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
    log_debug "Checking config file security: $CONFIG_FILE"
    config_owner=$(stat -c '%u' "$CONFIG_FILE" 2>/dev/null)
    config_perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null)
    log_trace "Config file owner=$config_owner, perms=$config_perms"
    if [ "$config_owner" = "0" ] && [ "${config_perms#*2}" = "$config_perms" ]; then
        log_debug "Config file security check passed, sourcing"
        . "$CONFIG_FILE"
        log_debug "Config file sourced successfully"
    else
        log_warn "Config file has unsafe permissions (owner=$config_owner, perms=$config_perms), using defaults"
    fi
else
    log_debug "Config file not found: $CONFIG_FILE, using defaults"
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
    log_func_enter "detect_framework"
    local result="unknown"
    if [ -d "/data/adb/ksu" ] && [ -f "/data/adb/ksu/modules.img" ]; then
        result="kernelsu"
        log_debug "Found KernelSU: /data/adb/ksu exists with modules.img"
    elif [ -d "/data/adb/ap" ]; then
        result="apatch"
        log_debug "Found APatch: /data/adb/ap exists"
    elif [ -d "/data/adb/magisk" ]; then
        result="magisk"
        log_debug "Found Magisk: /data/adb/magisk exists"
    else
        log_debug "No known root framework detected"
    fi
    log_func_exit "detect_framework" "$result"
    echo "$result"
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
if [ "$FRAMEWORK" = "apatch" ]; then
    # APatch uses slightly different paths in some versions
    if [ -d "/data/adb/ap/modules" ]; then
        MODULES_DIR="/data/adb/ap/modules"
        log_info "APatch mode - using modules dir: $MODULES_DIR"
    else
        log_debug "APatch detected but /data/adb/ap/modules not found, using default"
    fi
fi

# ============================================================
# NON-BLOCKING CHECK: Is /dev/vfs_helper available?
# ============================================================
log_info "Checking VFS driver availability..."
if [ ! -c "/dev/vfs_helper" ]; then
    log_info "/dev/vfs_helper not available - VFS registration skipped"
    log_info "Module will work normally on next boot when KPM is loaded"
    log_info "Continuing without VFS..."
    log_debug "Starting monitor.sh with args: 0 0"

    # Still start monitor for module description updates
    sh "$MODDIR/monitor.sh" "0" "0" &
    log_info "Monitor started (PID: $!)"

    END_TIME=$(date +%s)
    log_info "========== EXECUTION SUMMARY (NO VFS) =========="
    log_info "Execution time: $((END_TIME - START_TIME))s"
    log_info "VFS driver: NOT AVAILABLE"
    exit 0
fi

log_info "VFS driver check: /dev/vfs_helper is a character device - READY"
log_debug "VFS device permissions: $(ls -la /dev/vfs_helper 2>/dev/null || echo 'unable to stat')"

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
    local mod_name="$1"
    log_func_enter "is_excluded" "$mod_name"

    # Use -w for portable word matching instead of \b
    if echo "$excluded_modules" | grep -qw "$mod_name"; then
        log_debug "Module '$mod_name' is in exclusion list"
        log_func_exit "is_excluded" "true"
        return 0
    fi

    log_func_exit "is_excluded" "false"
    return 1
}

# ============================================================
# FUNCTION: Content-aware module filtering
# Returns 0 if module should be skipped, 1 otherwise
# ============================================================
should_skip_module() {
    local mod_path="$1"
    local mod_name="$2"

    log_func_enter "should_skip_module" "$mod_name"

    # Check for skip_nomount marker
    if [ "$skip_nomount_marker" = "true" ] && [ -f "$mod_path/skip_nomount" ]; then
        log_info "SKIP: $mod_name has skip_nomount marker"
        log_func_exit "should_skip_module" "true (marker)"
        return 0
    fi

    # Check for hosts file modification (detection risk)
    if [ "$skip_hosts_modules" = "true" ]; then
        for partition in $TARGET_PARTITIONS; do
            if [ -f "$mod_path/$partition/etc/hosts" ]; then
                log_info "SKIP: $mod_name modifies /etc/hosts (detection risk)"
                log_func_exit "should_skip_module" "true (hosts)"
                return 0
            fi
        done
    fi

    log_func_exit "should_skip_module" "false"
    return 1
}

# ============================================================
# FUNCTION: Detect ALL module-related mounts (universal hijacking)
# Detects: overlay mounts, bind mounts, loop mounts, tmpfs
# ============================================================
detect_all_module_mounts() {
    log_func_enter "detect_all_module_mounts"
    log_info "Scanning for ALL module-related mounts..."

    # Use cached /proc/mounts if available (to avoid deadlock after hooks enabled)
    local mounts_snapshot
    if [ -n "$CACHED_PROC_MOUNTS" ]; then
        log_trace "Using cached /proc/mounts..."
        mounts_snapshot="$CACHED_PROC_MOUNTS"
    else
        log_trace "Reading /proc/mounts snapshot..."
        mounts_snapshot=$(cat /proc/mounts 2>&1)
        local cat_rc=$?
        if [ $cat_rc -ne 0 ]; then
            log_err "Failed to read /proc/mounts (rc=$cat_rc): $mounts_snapshot"
            log_func_exit "detect_all_module_mounts" "error"
            return 1
        fi
    fi
    local mount_line_count=$(echo "$mounts_snapshot" | wc -l)
    log_debug "Using $mount_line_count lines from mounts data"

    local overlay_count=0 bind_count=0 loop_count=0 tmpfs_count=0

    # 1. Overlay mounts on target partitions
    log_debug "Phase 1: Scanning overlay mounts..."
    echo "$mounts_snapshot" | while read -r device mountpoint fstype options rest; do
        if [ "$fstype" = "overlay" ]; then
            for partition in $TARGET_PARTITIONS; do
                if echo "$mountpoint" | grep -q "^/$partition"; then
                    echo "overlay:$mountpoint"
                    log_info "Found overlay: $mountpoint"
                    log_debug "  device=$device fstype=$fstype"
                fi
            done
        fi
    done

    # 2. Bind mounts (source contains /data/adb/modules)
    log_debug "Phase 2: Scanning bind mounts..."
    echo "$mounts_snapshot" | while read -r device mountpoint fstype options rest; do
        if echo "$options" | grep -q "bind"; then
            if echo "$device" | grep -q "/data/adb/modules"; then
                echo "bind:$mountpoint"
                log_info "Found bind mount: $mountpoint (source: $device)"
            fi
        fi
    done

    # 3. Check for bind mounts via same device/inode on target partitions
    # These may not have explicit bind option
    log_debug "Phase 3: Scanning hidden bind mounts..."
    echo "$mounts_snapshot" | while read -r device mountpoint fstype options rest; do
        for partition in $TARGET_PARTITIONS; do
            if echo "$mountpoint" | grep -q "^/$partition" && [ "$fstype" != "overlay" ]; then
                # Check if this is a hidden bind mount from modules
                if [ -d "$MODULES_DIR" ]; then
                    for mod_dir in "$MODULES_DIR"/*; do
                        [ -d "$mod_dir" ] || continue
                        if [ -d "$mod_dir$mountpoint" ]; then
                            real_dev=$(stat -c %d "$mod_dir$mountpoint" 2>/dev/null)
                            mount_dev=$(stat -c %d "$mountpoint" 2>/dev/null)
                            if [ "$real_dev" = "$mount_dev" ] && [ -n "$real_dev" ]; then
                                echo "bind:$mountpoint"
                                log_info "Found hidden bind: $mountpoint (dev=$real_dev)"
                            fi
                        fi
                    done
                fi
            fi
        done
    done

    # 4. Loop mounts from module paths
    log_debug "Phase 4: Scanning loop mounts..."
    if command -v losetup >/dev/null 2>&1; then
        log_trace "Executing: losetup -a"
        losetup -a 2>/dev/null | grep -E "modules|magisk" | while read -r loop_line; do
            loop_dev=$(echo "$loop_line" | cut -d: -f1)
            if echo "$mounts_snapshot" | grep -q "^$loop_dev "; then
                loop_mount=$(echo "$mounts_snapshot" | grep "^$loop_dev " | awk '{print $2}')
                echo "loop:$loop_mount"
                log_info "Found loop mount: $loop_mount (device: $loop_dev)"
            fi
        done
    else
        log_debug "losetup not available, skipping loop mount detection"
    fi

    # 5. tmpfs at suspicious locations (may be used by some modules)
    log_debug "Phase 5: Scanning tmpfs mounts..."
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

    log_func_exit "detect_all_module_mounts" "0"
}

# ============================================================
# FUNCTION: Check if overlay mount is from a module (not system)
# Returns 0 if module overlay, 1 if system overlay
# ============================================================
is_module_overlay() {
    local mountpoint="$1"
    log_func_enter "is_module_overlay" "$mountpoint"

    # Use cached mounts if available (to avoid reading /proc/mounts after hooks enabled)
    local mount_line
    if [ -n "$CACHED_PROC_MOUNTS" ]; then
        mount_line=$(echo "$CACHED_PROC_MOUNTS" | grep " $mountpoint overlay ")
    else
        mount_line=$(grep " $mountpoint overlay " /proc/mounts 2>/dev/null)
    fi
    local options=$(echo "$mount_line" | awk '{print $4}')
    log_debug "Overlay options: ${options:0:200}..."

    # Check if any option contains known module paths
    # Covers: Magisk, KernelSU, APatch module directories
    if echo "$options" | grep -qE "/data/adb/(modules|ksu|ap|magisk)/"; then
        log_func_exit "is_module_overlay" "true (/data/adb/* pattern)"
        return 0  # Is a module overlay
    fi

    # Check for KernelSU module_root style paths
    if echo "$options" | grep -qE "/data/adb/[^/]+/modules/"; then
        log_func_exit "is_module_overlay" "true (KSU module_root)"
        return 0
    fi

    # Fallback: Check if ANY module has content for this mountpoint
    # This catches cases where overlay options don't contain module path
    local relative="${mountpoint#/}"
    for mod_dir in "$MODULES_DIR"/*; do
        [ -d "$mod_dir" ] || continue
        if [ -d "$mod_dir/$relative" ] || [ -f "$mod_dir/$relative" ]; then
            log_func_exit "is_module_overlay" "true (module content: ${mod_dir##*/})"
            return 0  # A module has content for this path
        fi
    done

    log_func_exit "is_module_overlay" "false (system overlay)"
    return 1  # System overlay - do not touch
}

# ============================================================
# FUNCTION: Find module that owns an overlay mount
# Returns module name or empty string
# ============================================================
find_module_for_overlay() {
    local mountpoint="$1"
    log_func_enter "find_module_for_overlay" "$mountpoint"

    # Use cached mounts if available (to avoid reading /proc/mounts after hooks enabled)
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
        local result=$(echo "$lowerdir" | sed 's|.*/data/adb/modules/||' | cut -d/ -f1)
        log_func_exit "find_module_for_overlay" "$result (lowerdir)"
        echo "$result"
        return
    fi

    # Try upperdir
    local upperdir=$(echo "$options" | tr ',' '\n' | grep "^upperdir=" | sed 's/upperdir=//')
    if echo "$upperdir" | grep -q "/data/adb/modules/"; then
        local result=$(echo "$upperdir" | sed 's|.*/data/adb/modules/||' | cut -d/ -f1)
        log_func_exit "find_module_for_overlay" "$result (upperdir)"
        echo "$result"
        return
    fi

    # Try workdir (sometimes contains module path)
    local workdir=$(echo "$options" | tr ',' '\n' | grep "^workdir=" | sed 's/workdir=//')
    if echo "$workdir" | grep -q "/data/adb/modules/"; then
        local result=$(echo "$workdir" | sed 's|.*/data/adb/modules/||' | cut -d/ -f1)
        log_func_exit "find_module_for_overlay" "$result (workdir)"
        echo "$result"
        return
    fi

    # Check all lowerdir entries (overlay can have multiple)
    local all_lowerdirs=$(echo "$options" | tr ',' '\n' | grep "^lowerdir=" | sed 's/lowerdir=//' | tr ':' '\n')
    for dir in $all_lowerdirs; do
        if echo "$dir" | grep -q "/data/adb/modules/"; then
            local result=$(echo "$dir" | sed 's|.*/data/adb/modules/||' | cut -d/ -f1)
            log_func_exit "find_module_for_overlay" "$result (multi-lowerdir)"
            echo "$result"
            return
        fi
    done

    # No module found
    log_func_exit "find_module_for_overlay" "NOT_FOUND"
    echo ""
}

# ============================================================
# FUNCTION: Register .so files with SUSFS sus_map for /proc/maps hiding
# ============================================================
register_sus_map_for_module() {
    local mod_path="$1"
    local mod_name="$2"
    local so_count=0

    log_func_enter "register_sus_map_for_module" "$mod_name"

    if ! command -v ksu_susfs >/dev/null 2>&1; then
        log_func_exit "register_sus_map_for_module" "skipped (ksu_susfs not available)"
        return
    fi

    for partition in $TARGET_PARTITIONS; do
        if [ -d "$mod_path/$partition" ]; then
            find "$mod_path/$partition" -name "*.so" -type f 2>/dev/null | while read -r so_file; do
                if ksu_susfs add_sus_map "$so_file" < /dev/null 2>/dev/null; then
                    log_debug "SUS_MAP registered: $so_file"
                    so_count=$((so_count + 1))
                else
                    log_err "SUS_MAP failed: $so_file"
                fi
            done
        fi
    done

    log_func_exit "register_sus_map_for_module" "$so_count .so files"
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

    log_func_enter "register_module_vfs" "$mod_name"
    log_info "Registering VFS files for module: $mod_name"

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
            log_debug "Processing partition: $partition"
            # Use absolute paths to avoid cd/subshell - find from mod_path, strip prefix for virtual path
            find "$mod_path/$partition" -type f -o -type c 2>/dev/null | while read -r real_path; do
                # Convert absolute real_path to relative virtual_path
                virtual_path="${real_path#$mod_path}"

                # Skip Magisk/KernelSU marker files - not real content
                case "${real_path##*/}" in
                    .replace|.remove|.gitkeep|.nomedia|.placeholder)
                        log_debug "SKIP: Marker file $virtual_path"
                        continue
                        ;;
                esac

                # Read current counts
                read f_cnt s_cnt w_cnt < "$count_file"
                f_cnt=$((f_cnt + 1))

                # ALWAYS re-add rules to ensure real_ino is populated with current inode
                # This fixes the issue where cached rules from early boot have stale/zero inodes

                if [ -c "$real_path" ]; then
                    # Whiteout (character device) - delete file
                    log_debug "VFS Whiteout: $virtual_path"
                    if "$LOADER" add "$virtual_path" "/nonexistent" < /dev/null 2>/dev/null; then
                        w_cnt=$((w_cnt + 1))
                        s_cnt=$((s_cnt + 1))
                        echo "VFS_INC" >> "$count_file.global"
                        # Apply SUSFS path hiding for whiteouts too
                        if [ "$HAS_SUSFS" = "1" ] && type susfs_apply_path >/dev/null 2>&1; then
                            susfs_apply_path "$virtual_path" 0
                        fi
                    else
                        log_err "VFS add failed (whiteout): $virtual_path"
                    fi
                else
                    # Regular file injection - use unified API with SUSFS integration
                    log_debug "VFS Inject: $virtual_path -> $real_path"
                    if type nm_register_rule_with_susfs >/dev/null 2>&1 && [ "$HAS_SUSFS" = "1" ]; then
                        # Use unified API (NoMount + SUSFS together)
                        if nm_register_rule_with_susfs "$virtual_path" "$real_path" "$LOADER"; then
                            s_cnt=$((s_cnt + 1))
                            echo "VFS_INC" >> "$count_file.global"
                        else
                            log_err "VFS+SUSFS failed: $virtual_path"
                        fi
                    else
                        # Fallback to NoMount-only
                        if "$LOADER" add "$virtual_path" "$real_path" < /dev/null 2>/dev/null; then
                            s_cnt=$((s_cnt + 1))
                            echo "VFS_INC" >> "$count_file.global"
                        else
                            log_err "VFS add failed (inject): $virtual_path"
                        fi
                    fi
                fi

                # Write updated counts
                echo "$f_cnt $s_cnt $w_cnt" > "$count_file"

                # Track for later sync
                echo "$virtual_path" >> "$tracking_file"
            done
        fi
    done

    # Read final counts from temp file
    if [ -f "$count_file" ]; then
        read file_count success_count whiteout_count < "$count_file"
        rm -f "$count_file"
    fi

    # Update global VFS_REGISTERED_COUNT from marker file
    if [ -f "$count_file.global" ]; then
        local global_inc=$(wc -l < "$count_file.global")
        VFS_REGISTERED_COUNT=$((VFS_REGISTERED_COUNT + global_inc))
        rm -f "$count_file.global"
    fi

    log_info "Module $mod_name: registered $success_count files via VFS"
    log_func_exit "register_module_vfs" "files=$file_count, success=$success_count, whiteouts=$whiteout_count"

    register_sus_map_for_module "$mod_path" "$mod_name"
}

# ============================================================
# FUNCTION: Hijack a single mount (any type)
# ============================================================
hijack_mount() {
    local mount_info="$1"
    local mount_type="${mount_info%%:*}"
    local mountpoint="${mount_info#*:}"

    log_func_enter "hijack_mount" "$mount_info"
    log_info "Processing $mount_type mount: $mountpoint"

    # CRITICAL: For overlay mounts, verify it's from a module, not Android system
    if [ "$mount_type" = "overlay" ]; then
        if ! is_module_overlay "$mountpoint"; then
            log_info "SKIP: System overlay (not from module) - preserving"
            log_func_exit "hijack_mount" "skipped (system overlay)"
            return 0
        fi
    fi

    local mod_name=""

    # Find owning module based on mount type
    log_debug "Looking for owning module (mount_type=$mount_type)"
    case "$mount_type" in
        overlay)
            mod_name=$(find_module_for_overlay "$mountpoint")
            ;;
        bind|loop|tmpfs)
            # For non-overlay mounts, scan module directories
            for mod_dir in "$MODULES_DIR"/*; do
                [ -d "$mod_dir" ] || continue
                local test_mod="${mod_dir##*/}"
                for partition in $TARGET_PARTITIONS; do
                    if [ -d "$mod_dir/$partition" ]; then
                        # Check if this module has content for this mountpoint
                        local relative="${mountpoint#/}"
                        if [ -e "$mod_dir/$relative" ]; then
                            mod_name="$test_mod"
                            log_debug "Found module via directory scan: $mod_name"
                            break 2
                        fi
                    fi
                done
            done
            ;;
    esac

    if [ -z "$mod_name" ]; then
        log_err "Could not determine owning module for mount: $mountpoint"
        log_func_exit "hijack_mount" "1 (no module found)"
        return 1
    fi

    local mod_path="$MODULES_DIR/$mod_name"
    log_info "Mount owned by module: $mod_name (type: $mount_type)"

    if is_excluded "$mod_name"; then
        log_info "SKIP: Module $mod_name is in exclusion list"
        log_func_exit "hijack_mount" "0 (excluded)"
        return 0
    fi

    # Content-aware filtering (skip hosts-modifying modules, skip_nomount markers)
    if should_skip_module "$mod_path" "$mod_name"; then
        log_func_exit "hijack_mount" "0 (filtered)"
        return 0
    fi

    if [ ! -d "$mod_path" ]; then
        log_err "Module directory not found: $mod_path"
        log_func_exit "hijack_mount" "1 (mod_path missing)"
        return 1
    fi

    # Track this module as processed to avoid double registration in process_modules_direct()
    PROCESSED_MODULES="$PROCESSED_MODULES $mod_name "

    log_info "Registering VFS files for mount $mountpoint..."
    register_module_vfs "$mod_path" "$mod_name"

    log_info "Attempting lazy unmount: $mountpoint"
    local umount_output
    umount_output=$(umount -l "$mountpoint" 2>&1)
    local umount_rc=$?

    if [ $umount_rc -eq 0 ]; then
        log_info "Successfully unmounted: $mountpoint"
        HIJACKED_OVERLAYS_COUNT=$((HIJACKED_OVERLAYS_COUNT + 1))
        log_func_exit "hijack_mount" "0 (success)"
        return 0
    else
        log_err "Unmount failed (rc=$umount_rc): $mountpoint - $umount_output"
        if [ "$aggressive_mode" = "true" ]; then
            log_info "Aggressive mode enabled - continuing despite unmount failure"
            log_func_exit "hijack_mount" "0 (unmount failed, aggressive mode)"
            return 0
        else
            log_info "Keeping mount as fallback (aggressive_mode=false)"
            log_func_exit "hijack_mount" "1 (unmount failed)"
            return 1
        fi
    fi
}

# ============================================================
# FUNCTION: Process modules directly via VFS
# ============================================================
process_modules_direct() {
    log_func_enter "process_modules_direct"
    log_info "Processing modules directly via VFS..."

    local total_modules=0
    local skipped_disabled=0
    local skipped_excluded=0
    local skipped_no_content=0

    for mod_path in "$MODULES_DIR"/*; do
        [ -d "$mod_path" ] || continue
        mod_name="${mod_path##*/}"
        total_modules=$((total_modules + 1))

        log_debug "Checking module: $mod_name"

        if [ "$mod_name" = "nomount" ]; then
            log_debug "Skipping self (nomount module)"
            skipped_excluded=$((skipped_excluded + 1))
            continue
        fi

        if [ -f "$mod_path/disable" ]; then
            log_debug "Skipping $mod_name (has disable flag)"
            skipped_disabled=$((skipped_disabled + 1))
            continue
        fi

        if [ -f "$mod_path/remove" ]; then
            log_debug "Skipping $mod_name (has remove flag)"
            skipped_disabled=$((skipped_disabled + 1))
            continue
        fi

        if is_excluded "$mod_name"; then
            skipped_excluded=$((skipped_excluded + 1))
            continue
        fi

        # Skip if already processed via hijack_mount() (universal_hijack mode)
        if echo "$PROCESSED_MODULES" | grep -q " $mod_name "; then
            log_debug "Skipping $mod_name (already processed via hijack_mount)"
            continue
        fi

        # Content-aware filtering
        if should_skip_module "$mod_path" "$mod_name"; then
            skipped_excluded=$((skipped_excluded + 1))
            continue
        fi

        has_content=false
        for partition in $TARGET_PARTITIONS; do
            if [ -d "$mod_path/$partition" ]; then
                has_content=true
                log_debug "Module $mod_name has content in /$partition"
                break
            fi
        done

        if [ "$has_content" = "true" ]; then
            log_info "Processing module: $mod_name"
            register_module_vfs "$mod_path" "$mod_name"
            ACTIVE_MODULES_COUNT=$((ACTIVE_MODULES_COUNT + 1))
        else
            log_debug "Skipping $mod_name (no partition content)"
            skipped_no_content=$((skipped_no_content + 1))
        fi
    done

    log_info "Direct processing complete: $ACTIVE_MODULES_COUNT modules processed"
    log_debug "Stats: total=$total_modules, disabled=$skipped_disabled, excluded=$skipped_excluded, no_content=$skipped_no_content"
    log_func_exit "process_modules_direct" "$ACTIVE_MODULES_COUNT"
}

# ============================================================
# PHASE 1: Cache partition device IDs (SUSFS-independent)
# Must run EARLY before overlays change device IDs
# ============================================================
cache_partition_devs() {
    log_func_enter "cache_partition_devs"
    log_info "Phase 1: Caching partition device IDs..."

    # Partition IDs must match kernel enum: system=0, vendor=1, product=2, system_ext=3,
    # odm=4, oem=5, mi_ext=6, my_heytap=7, prism=8, optics=9, oem_dlkm=10, system_dlkm=11, vendor_dlkm=12
    local part_id=0
    local cached_count=0
    local missing_count=0

    for partition in system vendor product system_ext odm oem mi_ext my_heytap prism optics oem_dlkm system_dlkm vendor_dlkm; do
        if [ -d "/$partition" ]; then
            # Use %d to get decimal device ID, then extract major/minor
            # Device ID = major * 256 + minor (standard Linux encoding)
            local dev_dec=$(stat -c '%d' "/$partition" 2>/dev/null)
            if [ -n "$dev_dec" ] && [ "$dev_dec" -gt 0 ]; then
                local major=$((dev_dec >> 8))
                local minor=$((dev_dec & 255))
                local nm_output
                nm_output=$("$LOADER" setdev "$part_id" "$major" "$minor" 2>&1)
                local nm_rc=$?
                if [ $nm_rc -eq 0 ]; then
                    log_info "Partition /$partition (id=$part_id) -> $major:$minor"
                    cached_count=$((cached_count + 1))
                else
                    log_err "nm setdev failed for /$partition: $nm_output (rc=$nm_rc)"
                fi
            else
                log_debug "Partition /$partition -> not mounted or invalid (dev_dec=$dev_dec)"
                missing_count=$((missing_count + 1))
            fi
        else
            log_debug "Partition /$partition does not exist"
            missing_count=$((missing_count + 1))
        fi
        part_id=$((part_id + 1))
    done

    log_info "Phase 1 complete: $cached_count partitions cached, $missing_count not found"
    log_func_exit "cache_partition_devs" "$cached_count/$missing_count"
}

# ============================================================
# PHASE 2: Register hidden mounts (SUSFS-independent)
# Hides overlay/tmpfs mounts from /proc/mounts, /proc/self/mountinfo
# ============================================================
register_hidden_mounts() {
    log_func_enter "register_hidden_mounts"
    log_info "Phase 2: Registering hidden mounts..."

    local count=0
    local fail_count=0
    local total_mounts=$(wc -l < /proc/self/mountinfo)
    log_debug "Total mounts in mountinfo: $total_mounts"

    while IFS=' ' read -r mount_id rest; do
        local fstype=$(echo "$rest" | sed 's/.* - //' | cut -d' ' -f1)
        local mount_point=$(echo "$rest" | cut -d' ' -f4)

        case "$fstype" in
            overlay|tmpfs)
                for partition in $TARGET_PARTITIONS; do
                    if echo "$mount_point" | grep -qE "^/$partition(/|$)"; then
                        log_debug "Attempting to hide mount_id=$mount_id ($fstype @ $mount_point)"
                        local hide_output
                        hide_output=$("$LOADER" hide "$mount_id" 2>&1)
                        local hide_rc=$?
                        if [ $hide_rc -eq 0 ]; then
                            log_info "Hidden mount: $mount_id ($fstype @ $mount_point)"
                            count=$((count + 1))
                        else
                            log_err "Failed to hide mount $mount_id: $hide_output (rc=$hide_rc)"
                            fail_count=$((fail_count + 1))
                        fi
                        break
                    fi
                done
                ;;
        esac
    done < /proc/self/mountinfo

    log_info "Phase 2 complete: $count mounts hidden, $fail_count failed"
    log_func_exit "register_hidden_mounts" "$count/$fail_count"
}

# ============================================================
# PHASE 3: Register maps patterns (SUSFS-independent)
# Hides suspicious paths from /proc/self/maps
# ============================================================
register_maps_patterns() {
    log_func_enter "register_maps_patterns"
    log_info "Phase 3: Registering maps patterns..."

    local count=0
    local fail_count=0

    for pattern in "/data/adb" "magisk" "kernelsu" "zygisk"; do
        local addmap_output
        addmap_output=$("$LOADER" addmap "$pattern" 2>&1)
        local addmap_rc=$?
        if [ $addmap_rc -eq 0 ]; then
            log_info "Maps pattern registered: $pattern"
            count=$((count + 1))
        else
            log_err "Failed to register maps pattern '$pattern': $addmap_output (rc=$addmap_rc)"
            fail_count=$((fail_count + 1))
        fi
    done

    log_info "Phase 3 complete: $count patterns registered, $fail_count failed"
    log_func_exit "register_maps_patterns" "$count/$fail_count"
}

# ============================================================
# MAIN EXECUTION (late boot phase)
# ============================================================
log_info "========== MAIN EXECUTION STARTING =========="
log_info "Configuration: universal_hijack=$universal_hijack, aggressive_mode=$aggressive_mode"
log_info "Configuration: monitor_new_modules=$monitor_new_modules, skip_hosts_modules=$skip_hosts_modules"
log_debug "Excluded modules: ${excluded_modules:-none}"

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

# CRITICAL: Cache /proc/mounts BEFORE enabling hooks!
# Reading /proc/mounts after hooks are enabled causes kernel deadlock
# because the VFS hooks intercept the read and cause recursive locking.
log_info "Caching /proc/mounts (before hooks enabled)..."
CACHED_PROC_MOUNTS=$(cat /proc/mounts 2>/dev/null)
export CACHED_PROC_MOUNTS
log_debug "Cached $(echo "$CACHED_PROC_MOUNTS" | wc -l) mount entries"

mount_list=""
if [ "$universal_hijack" = "true" ]; then
    log_info "========== UNIVERSAL HIJACKER MODE =========="
    log_info "Pre-scanning module mounts (using cached /proc/mounts)..."
    mount_list=$(detect_all_module_mounts)
    mount_count=$(echo "$mount_list" | grep -c . || echo 0)
    log_info "Detected $mount_count module-related mounts"
fi

# NOW enable NoMount hooks - after mount detection is complete
log_info "Enabling NoMount VFS hooks..."
log_debug "Executing: $LOADER enable"
if "$LOADER" enable < /dev/null 2>/dev/null; then
    log_info "NoMount hooks ENABLED - VFS interception active"
    log_debug "$LOADER enable succeeded"
else
    log_err "FATAL: Failed to enable NoMount hooks!"
    log_debug "$LOADER enable FAILED"
    exit 1
fi
log_info ""

if [ "$universal_hijack" = "true" ]; then
    # Mount list was already captured above, before hooks were enabled
    if [ -n "$mount_list" ]; then
        log_info ""
        log_info "Hijacking all detected mounts..."

        hijack_success=0
        hijack_fail=0

        # Use here-string to avoid subshell variable loss
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

        log_info "Hijacking complete: $hijack_success successful, $hijack_fail failed"
    else
        log_info "No module-related mounts detected"
    fi

    # Phase 2: Process all modules directly via VFS
    log_info ""
    process_modules_direct

else
    log_info "========== STANDARD MODE =========="
    process_modules_direct
fi

# Handle UID exclusion list
if [ -f "$NOMOUNT_DATA/.exclusion_list" ]; then
    log_info ""
    log_info "Processing UID exclusion list..."
    uid_count=0
    uid_fail=0
    while IFS= read -r uid; do
        [ -z "$uid" ] && continue
        blk_output=$("$LOADER" blk "$uid" 2>&1)
        blk_rc=$?
        if [ $blk_rc -eq 0 ]; then
            log_info "UID blocked: $uid"
            uid_count=$((uid_count + 1))
        else
            log_err "Failed to block UID $uid: $blk_output (rc=$blk_rc)"
            uid_fail=$((uid_fail + 1))
        fi
    done < "$NOMOUNT_DATA/.exclusion_list"
    log_info "UID processing complete: $uid_count blocked, $uid_fail failed"
else
    log_debug "No UID exclusion list found at $NOMOUNT_DATA/.exclusion_list"
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
# This allows post-fs-data.sh to pre-register rules on next boot
# BEFORE zygote starts, closing the detection window.
# ============================================================
save_rule_cache() {
    log_func_enter "save_rule_cache"
    local cache_file="$NOMOUNT_DATA/.rule_cache"
    local temp_file="$NOMOUNT_DATA/.rule_cache_tmp_$$"
    local filtered_count=0

    log_info "Saving VFS rules to cache for early boot..."

    # Clear temp file
    : > "$temp_file"

    # Add header comment
    echo "# NoMount VFS Rule Cache" >> "$temp_file"
    echo "# Generated: $(date)" >> "$temp_file"
    echo "# Format: cmd|arg1|arg2" >> "$temp_file"
    echo "# Commands: add (vpath|rpath), hide (mount_id|), setdev (part_id|major:minor), addmap (pattern|)" >> "$temp_file"

    # Get current VFS rules from kernel via nm list
    # Kernel returns: real_path->virtual_path
    local list_output
    log_debug "Executing: $LOADER list"
    list_output=$("$LOADER" list 2>/dev/null)
    local list_rc=$?
    log_trace "$LOADER list returned rc=$list_rc"

    # Use temp file to track filtered count (avoids subshell variable isolation from pipe)
    local filter_count_file="$NOMOUNT_DATA/.filter_count_$$"
    echo "0" > "$filter_count_file"

    if [ $list_rc -eq 0 ] && [ -n "$list_output" ]; then
        local rule_count=$(echo "$list_output" | wc -l)
        log_debug "$LOADER list returned $rule_count rules"
        echo "$list_output" | while IFS= read -r line; do
            [ -z "$line" ] && continue
            # Parse kernel format: real_path->virtual_path
            local rpath="${line%%->*}"
            local vpath="${line##*->}"

            # VALIDATE: Check if real_path exists and module is active
            local include_rule=1

            # Check 1: real_path must exist
            if [ -n "$rpath" ] && [ "$rpath" != "/nonexistent" ] && [ ! -e "$rpath" ]; then
                log_debug "FILTERED: real_path missing - $vpath -> $rpath"
                include_rule=0
                echo "FILTER" >> "$filter_count_file"
            fi

            # Check 2: owning module must be active (not disabled/removed)
            if [ "$include_rule" = "1" ] && echo "$rpath" | grep -q "/data/adb/modules/"; then
                local mod_name
                mod_name=$(echo "$rpath" | sed 's|.*/data/adb/modules/||' | cut -d/ -f1)
                local mod_path="$MODULES_DIR/$mod_name"

                if [ -f "$mod_path/disable" ]; then
                    log_debug "FILTERED: module disabled - $vpath (module: $mod_name)"
                    include_rule=0
                    echo "FILTER" >> "$filter_count_file"
                elif [ -f "$mod_path/remove" ]; then
                    log_debug "FILTERED: module marked for removal - $vpath (module: $mod_name)"
                    include_rule=0
                    echo "FILTER" >> "$filter_count_file"
                elif [ ! -d "$mod_path" ]; then
                    log_debug "FILTERED: module missing - $vpath (module: $mod_name)"
                    include_rule=0
                    echo "FILTER" >> "$filter_count_file"
                fi
            fi

            # Only save valid rules
            if [ "$include_rule" = "1" ]; then
                [ -n "$vpath" ] && [ -n "$rpath" ] && echo "add|$vpath|$rpath" >> "$temp_file"
            fi
        done
    else
        log_debug "nm list returned no rules or failed (rc=$list_rc)"
    fi

    # Read filtered count from temp file (subtract 1 for initial "0" line)
    if [ -f "$filter_count_file" ]; then
        filtered_count=$(grep -c "FILTER" "$filter_count_file" 2>/dev/null || echo 0)
        rm -f "$filter_count_file"
    fi

    # Also cache partition device IDs for stat spoofing
    # These are critical for early detection evasion
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

    # Cache maps patterns for /proc/self/maps filtering
    for pattern in "/data/adb" "magisk" "kernelsu" "zygisk"; do
        echo "addmap|$pattern|" >> "$temp_file"
    done

    # Deduplicate rules before saving (preserves comments at top, deduplicates data lines)
    local dedup_file="$NOMOUNT_DATA/.rule_cache_dedup_$$"
    grep "^#" "$temp_file" > "$dedup_file" 2>/dev/null || true
    grep -v "^#" "$temp_file" | sort -u >> "$dedup_file" 2>/dev/null || true
    mv "$dedup_file" "$temp_file" 2>/dev/null

    # Atomic replace using rename
    log_debug "Attempting atomic cache file replacement..."
    if mv "$temp_file" "$cache_file" 2>/dev/null; then
        local count=$(grep -c "^add|" "$cache_file" 2>/dev/null || echo 0)
        local setdev_count=$(grep -c "^setdev|" "$cache_file" 2>/dev/null || echo 0)
        local addmap_count=$(grep -c "^addmap|" "$cache_file" 2>/dev/null || echo 0)
        log_info "Rule cache saved: $count rules (filtered $filtered_count stale)"
        log_debug "Cache breakdown: $count add, $setdev_count setdev, $addmap_count addmap"

        # Set restrictive permissions
        chmod 600 "$cache_file" 2>/dev/null
        log_func_exit "save_rule_cache" "0"
    else
        log_err "Failed to save rule cache (mv failed)"
        rm -f "$temp_file" 2>/dev/null
        log_func_exit "save_rule_cache" "1"
    fi
}

# Call save_rule_cache at end of successful execution
save_rule_cache

# Start monitor
if [ "$monitor_new_modules" = "true" ]; then
    log_info "Starting monitor.sh with args: $ACTIVE_MODULES_COUNT $HIJACKED_OVERLAYS_COUNT"
    sh "$MODDIR/monitor.sh" "$ACTIVE_MODULES_COUNT" "$HIJACKED_OVERLAYS_COUNT" &
    log_debug "Monitor started with PID: $!"
else
    log_debug "Monitor disabled (monitor_new_modules=false)"
fi
