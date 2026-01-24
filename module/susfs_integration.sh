#!/system/bin/sh
# ============================================================
# NoMount + SUSFS Tight Coupling Integration
# ============================================================
# This module provides automatic SUSFS configuration when
# NoMount rules are added. It creates a "plug-and-socket"
# architecture where NoMount orchestrates and SUSFS enforces.
#
# Logs: /data/adb/nomount/logs/susfs/susfs.log
#
# Usage:
#   . "$MODDIR/logging.sh"
#   . "$MODDIR/susfs_integration.sh"
#   susfs_init
#   nm_register_rule_with_susfs "/system/fonts/X.ttf" "/data/adb/modules/.../X.ttf"
# ============================================================

# ============================================================
# LOGGING FALLBACK
# If logging.sh wasn't sourced, provide fallback functions
# ============================================================
if ! type log_debug >/dev/null 2>&1; then
    # Fallback logging functions
    _SUSFS_LOG_FILE="${NOMOUNT_DATA:-/data/adb/nomount}/logs/susfs/susfs.log"
    mkdir -p "$(dirname "$_SUSFS_LOG_FILE")" 2>/dev/null

    log_debug() { echo "[$(date '+%H:%M:%S')] [DEBUG] [SUSFS] $*" >> "$_SUSFS_LOG_FILE" 2>/dev/null; }
    log_info() { echo "[$(date '+%H:%M:%S')] [INFO ] [SUSFS] $*" >> "$_SUSFS_LOG_FILE" 2>/dev/null; }
    log_warn() { echo "[$(date '+%H:%M:%S')] [WARN ] [SUSFS] $*" >> "$_SUSFS_LOG_FILE" 2>/dev/null; }
    log_err() { echo "[$(date '+%H:%M:%S')] [ERROR] [SUSFS] $*" >> "$_SUSFS_LOG_FILE" 2>/dev/null; }
    log_trace() { echo "[$(date '+%H:%M:%S')] [TRACE] [SUSFS] $*" >> "$_SUSFS_LOG_FILE" 2>/dev/null; }
    log_func_enter() { local f="$1"; shift; log_debug ">>> ENTER: $f($*)"; }
    log_func_exit() { log_debug "<<< EXIT: $1 (result=$2)"; }
    log_susfs_cmd() { log_debug "Executing: ksu_susfs $*"; }
    log_susfs_result() { [ "$1" -eq 0 ] && log_debug "OK: $2 '$3'" || log_warn "FAIL: $2 '$3' (rc=$1)"; }
fi

# ============================================================
# SUSFS CONFIGURATION
# ============================================================
SUSFS_CONFIG_DIR=""
SUSFS_BIN=""
HAS_SUSFS=0
HAS_SUS_PATH=0
HAS_SUS_PATH_LOOP=0
HAS_SUS_MOUNT=0
HAS_SUS_KSTAT=0
HAS_SUS_KSTAT_REDIRECT=0
HAS_SUS_MAPS=0

# Metadata cache directory
METADATA_CACHE_DIR="${NOMOUNT_DATA:-/data/adb/nomount}/metadata_cache"

# Track hidden mounts to avoid duplicates
SUSFS_HIDDEN_MOUNTS=""

# Statistics
SUSFS_STATS_PATH=0
SUSFS_STATS_KSTAT=0
SUSFS_STATS_MOUNT=0
SUSFS_STATS_MAPS=0
SUSFS_STATS_ERRORS=0

# ============================================================
# FUNCTION: Initialize SUSFS detection
# Detects SUSFS availability and capabilities
# ============================================================
susfs_init() {
    log_func_enter "susfs_init"
    log_info "Initializing SUSFS integration..."

    # Find SUSFS binary
    local bin_paths="/data/adb/ksu/bin/ksu_susfs /data/adb/ksu/bin/susfs"
    log_debug "Searching for SUSFS binary in: $bin_paths"

    for bin_path in $bin_paths; do
        log_trace "Checking: $bin_path"
        if [ -x "$bin_path" ]; then
            SUSFS_BIN="$bin_path"
            log_debug "Found SUSFS binary: $bin_path"
            break
        fi
    done

    # Try command lookup as fallback
    if [ -z "$SUSFS_BIN" ]; then
        log_trace "Trying command lookup..."
        SUSFS_BIN=$(command -v ksu_susfs 2>/dev/null)
        [ -z "$SUSFS_BIN" ] && SUSFS_BIN=$(command -v susfs 2>/dev/null)
    fi

    if [ -z "$SUSFS_BIN" ] || [ ! -x "$SUSFS_BIN" ]; then
        HAS_SUSFS=0
        log_warn "SUSFS binary not found - running in NoMount-only mode"
        log_func_exit "susfs_init" "1" "no binary"
        return 1
    fi

    HAS_SUSFS=1
    log_info "Found SUSFS binary: $SUSFS_BIN"

    # Detect capabilities from help output
    log_debug "Detecting SUSFS capabilities..."
    local help_output
    help_output=$("$SUSFS_BIN" 2>&1)
    log_trace "SUSFS help output length: ${#help_output} chars"

    # Check each capability
    if echo "$help_output" | grep -q "add_sus_path[^_]"; then
        HAS_SUS_PATH=1
        log_debug "Capability detected: add_sus_path"
    fi
    if echo "$help_output" | grep -q "add_sus_path_loop"; then
        HAS_SUS_PATH_LOOP=1
        log_debug "Capability detected: add_sus_path_loop"
    fi
    if echo "$help_output" | grep -q "add_sus_mount"; then
        HAS_SUS_MOUNT=1
        log_debug "Capability detected: add_sus_mount"
    fi
    if echo "$help_output" | grep -q "add_sus_kstat"; then
        HAS_SUS_KSTAT=1
        log_debug "Capability detected: add_sus_kstat_statically"
    fi
    if echo "$help_output" | grep -q "add_sus_kstat_redirect"; then
        HAS_SUS_KSTAT_REDIRECT=1
        log_debug "Capability detected: add_sus_kstat_redirect"
    fi
    if echo "$help_output" | grep -q "add_sus_map"; then
        HAS_SUS_MAPS=1
        log_debug "Capability detected: add_sus_map"
    fi

    # Export variables so subshells (find | while loops) can access them
    export SUSFS_BIN
    export HAS_SUSFS
    export HAS_SUS_PATH
    export HAS_SUS_PATH_LOOP
    export HAS_SUS_MOUNT
    export HAS_SUS_KSTAT
    export HAS_SUS_KSTAT_REDIRECT
    export HAS_SUS_MAPS

    log_info "Capabilities: path=$HAS_SUS_PATH loop=$HAS_SUS_PATH_LOOP mount=$HAS_SUS_MOUNT kstat=$HAS_SUS_KSTAT kstat_redirect=$HAS_SUS_KSTAT_REDIRECT maps=$HAS_SUS_MAPS"

    # Find config directory
    log_debug "Searching for SUSFS config directory..."
    for config_dir in "/data/adb/susfs4ksu" "/data/adb/ksu/susfs4ksu" "/data/adb/susfs"; do
        log_trace "Checking: $config_dir"
        if [ -d "$config_dir" ]; then
            SUSFS_CONFIG_DIR="$config_dir"
            log_debug "Found config directory: $config_dir"
            break
        fi
    done

    if [ -n "$SUSFS_CONFIG_DIR" ]; then
        log_info "Config directory: $SUSFS_CONFIG_DIR"
    else
        log_debug "No config directory found (runtime-only mode)"
    fi

    # Create metadata cache directory
    log_debug "Creating metadata cache directory: $METADATA_CACHE_DIR"
    if mkdir -p "$METADATA_CACHE_DIR" 2>/dev/null; then
        log_trace "Metadata cache directory created"
    else
        log_warn "Failed to create metadata cache directory"
    fi

    log_func_exit "susfs_init" "0" "initialized"
    return 0
}

# ============================================================
# FUNCTION: Intelligent path classification
# Determines which SUSFS actions to apply based on path
# Returns comma-separated list of actions
# ============================================================
susfs_classify_path() {
    local vpath="$1"
    log_func_enter "susfs_classify_path" "$vpath"

    local actions="sus_path"  # Always add sus_path for redirected files

    case "$vpath" in
        # Libraries and framework - also hide from maps
        *.so|*.jar|*.dex|*.oat|*.vdex|*.art|*.odex)
            actions="$actions,sus_maps,sus_kstat"
            log_debug "Classified as LIBRARY: $vpath"
            ;;
        # Binaries
        /system/bin/*|/system/xbin/*|/vendor/bin/*|/product/bin/*)
            actions="$actions,sus_kstat"
            log_debug "Classified as BINARY: $vpath"
            ;;
        # Fonts and media
        /system/fonts/*|/system/media/*|/product/fonts/*|/product/media/*)
            actions="$actions,sus_kstat"
            log_debug "Classified as MEDIA/FONT: $vpath"
            ;;
        # Apps - may need mount hiding
        /system/app/*|/system/priv-app/*|/product/app/*|/product/priv-app/*|/vendor/app/*)
            actions="$actions,sus_kstat,sus_mount_check"
            log_debug "Classified as APP: $vpath"
            ;;
        # Framework files
        /system/framework/*|/system_ext/framework/*|/product/framework/*)
            actions="$actions,sus_maps,sus_kstat"
            log_debug "Classified as FRAMEWORK: $vpath"
            ;;
        # Config files
        *.xml|*.prop|*.conf|*.rc)
            actions="$actions,sus_kstat"
            log_debug "Classified as CONFIG: $vpath"
            ;;
        # Module paths - use loop variant for zygote respawn
        /data/adb/*)
            actions="sus_path_loop,sus_kstat"
            log_debug "Classified as MODULE_PATH: $vpath"
            ;;
        # Default
        *)
            actions="$actions,sus_kstat"
            log_debug "Classified as DEFAULT: $vpath"
            ;;
    esac

    log_func_exit "susfs_classify_path" "$actions"
    echo "$actions"
}

# ============================================================
# FUNCTION: Capture original file metadata (EARLY - before overlays)
# Must be called in post-fs-data.sh before any mounts
# ============================================================
susfs_capture_metadata() {
    local vpath="$1"
    log_func_enter "susfs_capture_metadata" "$vpath"

    local cache_key
    cache_key=$(echo "$vpath" | md5sum 2>/dev/null | cut -d' ' -f1)
    if [ -z "$cache_key" ]; then
        cache_key=$(echo "$vpath" | cksum | cut -d' ' -f1)
        log_trace "Using cksum fallback for cache key"
    fi

    local cache_file="$METADATA_CACHE_DIR/$cache_key"
    log_trace "Cache file: $cache_file"

    if [ -e "$vpath" ]; then
        # File exists - capture real metadata
        log_debug "Capturing metadata for existing file: $vpath"
        local stat_data
        stat_data=$(stat -c '%i|%d|%h|%s|%X|%Y|%Z|%b|%B' "$vpath" 2>/dev/null)

        if [ -n "$stat_data" ]; then
            # Also get filesystem type
            local fstype
            fstype=$(stat -f -c '%T' "$vpath" 2>/dev/null || echo "unknown")
            echo "${stat_data}|${fstype}" > "$cache_file"
            log_debug "Captured: ino=$(echo "$stat_data" | cut -d'|' -f1) fstype=$fstype"
            log_func_exit "susfs_capture_metadata" "0" "captured"
            return 0
        else
            log_warn "stat failed for $vpath"
            log_func_exit "susfs_capture_metadata" "1" "stat failed"
            return 1
        fi
    else
        # File doesn't exist (new file from module) - mark for synthesis
        echo "NEW|$vpath" > "$cache_file"
        log_debug "Marked as NEW file (will synthesize metadata): $vpath"
        log_func_exit "susfs_capture_metadata" "0" "marked new"
        return 0
    fi
}

# ============================================================
# FUNCTION: Get cached metadata for a path
# ============================================================
susfs_get_cached_metadata() {
    local vpath="$1"
    log_func_enter "susfs_get_cached_metadata" "$vpath"

    local cache_key
    cache_key=$(echo "$vpath" | md5sum 2>/dev/null | cut -d' ' -f1)
    [ -z "$cache_key" ] && cache_key=$(echo "$vpath" | cksum | cut -d' ' -f1)

    local cache_file="$METADATA_CACHE_DIR/$cache_key"

    if [ -f "$cache_file" ]; then
        local metadata
        metadata=$(cat "$cache_file")
        log_debug "Cache hit: $vpath -> ${metadata:0:50}..."
        log_func_exit "susfs_get_cached_metadata" "found"
        echo "$metadata"
    else
        log_debug "Cache miss: $vpath"
        log_func_exit "susfs_get_cached_metadata" "not found"
        echo ""
    fi
}

# ============================================================
# FUNCTION: Apply SUSFS sus_path hiding
# Note: Only works for EXISTING paths (replacements, not new files)
# ============================================================
susfs_apply_path() {
    local vpath="$1"
    local use_loop="$2"
    log_func_enter "susfs_apply_path" "$vpath" "loop=$use_loop"

    if [ "$HAS_SUSFS" != "1" ]; then
        log_debug "SUSFS not available, skipping"
        log_func_exit "susfs_apply_path" "skip" "no susfs"
        return 0
    fi

    # Check if this is a NEW file (not in stock system)
    # sus_path can only hide EXISTING paths, not newly injected ones
    local cache_key cache_file
    cache_key=$(echo "$vpath" | md5sum 2>/dev/null | cut -d' ' -f1)
    [ -z "$cache_key" ] && cache_key=$(echo "$vpath" | cksum | cut -d' ' -f1)
    cache_file="$METADATA_CACHE_DIR/$cache_key"

    if [ -f "$cache_file" ] && grep -q "^NEW|" "$cache_file" 2>/dev/null; then
        log_debug "Path is NEW file (not in stock), sus_path not needed: $vpath"
        log_func_exit "susfs_apply_path" "skip" "new file"
        return 0
    fi

    # Skip zero-byte files (whiteouts) - SUSFS can't hide empty files
    if [ -f "$vpath" ] && [ ! -s "$vpath" ]; then
        log_debug "Path is zero-byte whiteout, sus_path not needed: $vpath"
        log_func_exit "susfs_apply_path" "skip" "whiteout"
        return 0
    fi

    local cmd result rc

    if [ "$use_loop" = "1" ] && [ "$HAS_SUS_PATH_LOOP" = "1" ]; then
        cmd="add_sus_path_loop"
        log_susfs_cmd "$cmd" "$vpath"
        result=$("$SUSFS_BIN" "$cmd" "$vpath" 2>&1)
        rc=$?
        log_susfs_result "$rc" "$cmd" "$vpath"

        if [ $rc -eq 0 ]; then
            SUSFS_STATS_PATH=$((SUSFS_STATS_PATH + 1))
            susfs_update_config "sus_path_loop.txt" "$vpath"
            log_func_exit "susfs_apply_path" "0" "loop applied"
            return 0
        else
            log_err "sus_path_loop failed for $vpath: $result"
            SUSFS_STATS_ERRORS=$((SUSFS_STATS_ERRORS + 1))
        fi
    fi

    if [ "$HAS_SUS_PATH" = "1" ]; then
        cmd="add_sus_path"
        log_susfs_cmd "$cmd" "$vpath"
        result=$("$SUSFS_BIN" "$cmd" "$vpath" 2>&1)
        rc=$?
        log_susfs_result "$rc" "$cmd" "$vpath"

        if [ $rc -eq 0 ]; then
            SUSFS_STATS_PATH=$((SUSFS_STATS_PATH + 1))
            susfs_update_config "sus_path.txt" "$vpath"
            log_func_exit "susfs_apply_path" "0" "path applied"
            return 0
        else
            log_err "sus_path failed for $vpath: $result"
            SUSFS_STATS_ERRORS=$((SUSFS_STATS_ERRORS + 1))
        fi
    fi

    log_func_exit "susfs_apply_path" "1" "failed"
    return 1
}

# ============================================================
# FUNCTION: Apply SUSFS sus_map hiding (for libraries)
# ============================================================
susfs_apply_maps() {
    local vpath="$1"
    log_func_enter "susfs_apply_maps" "$vpath"

    if [ "$HAS_SUSFS" != "1" ]; then
        log_debug "SUSFS not available, skipping"
        log_func_exit "susfs_apply_maps" "skip"
        return 0
    fi

    if [ "$HAS_SUS_MAPS" != "1" ]; then
        log_debug "sus_map not supported"
        log_func_exit "susfs_apply_maps" "skip" "not supported"
        return 0
    fi

    # Check if this is a NEW file (not in stock system)
    local cache_key cache_file
    cache_key=$(echo "$vpath" | md5sum 2>/dev/null | cut -d' ' -f1)
    [ -z "$cache_key" ] && cache_key=$(echo "$vpath" | cksum | cut -d' ' -f1)
    cache_file="$METADATA_CACHE_DIR/$cache_key"

    if [ -f "$cache_file" ] && grep -q "^NEW|" "$cache_file" 2>/dev/null; then
        log_debug "Path is NEW file (not in stock), sus_maps not needed: $vpath"
        log_func_exit "susfs_apply_maps" "skip" "new file"
        return 0
    fi

    log_susfs_cmd "add_sus_map" "$vpath"
    local result rc
    result=$("$SUSFS_BIN" add_sus_map "$vpath" 2>&1)
    rc=$?
    log_susfs_result "$rc" "add_sus_map" "$vpath"

    if [ $rc -eq 0 ]; then
        SUSFS_STATS_MAPS=$((SUSFS_STATS_MAPS + 1))
        susfs_update_config "sus_maps.txt" "$vpath"
        log_func_exit "susfs_apply_maps" "0"
        return 0
    else
        log_err "sus_map failed for $vpath: $result"
        SUSFS_STATS_ERRORS=$((SUSFS_STATS_ERRORS + 1))
        log_func_exit "susfs_apply_maps" "1"
        return 1
    fi
}

# ============================================================
# FUNCTION: Apply SUSFS kstat spoofing
# Args: vpath metadata [rpath]
# If rpath provided, uses add_sus_kstat_redirect (both paths)
# Otherwise falls back to add_sus_kstat_statically (original API)
# ============================================================
susfs_apply_kstat() {
    local vpath="$1"
    local metadata="$2"
    local rpath="$3"  # Optional: real path for redirect API
    log_func_enter "susfs_apply_kstat" "$vpath" "metadata_len=${#metadata}" "rpath=$rpath"

    if [ "$HAS_SUSFS" != "1" ]; then
        log_debug "SUSFS not available, skipping"
        log_func_exit "susfs_apply_kstat" "skip"
        return 0
    fi

    if [ "$HAS_SUS_KSTAT" != "1" ]; then
        log_debug "sus_kstat not supported"
        log_func_exit "susfs_apply_kstat" "skip" "not supported"
        return 0
    fi

    # Check if this is a NEW file - skip kstat for NEW files
    # NEW files should keep their actual size/blocks, not synthetic zeros
    local cache_key cache_file
    cache_key=$(echo "$vpath" | md5sum 2>/dev/null | cut -d' ' -f1)
    [ -z "$cache_key" ] && cache_key=$(echo "$vpath" | cksum | cut -d' ' -f1)
    cache_file="$METADATA_CACHE_DIR/$cache_key"

    if [ -f "$cache_file" ] && grep -q "^NEW|" "$cache_file" 2>/dev/null; then
        log_debug "Path is NEW file (not in stock), sus_kstat not needed: $vpath"
        log_func_exit "susfs_apply_kstat" "skip" "new file"
        return 0
    fi

    if [ -z "$metadata" ]; then
        log_debug "No metadata provided"
        log_func_exit "susfs_apply_kstat" "1" "no metadata"
        return 1
    fi

    local ino dev nlink size atime mtime ctime blocks blksize fstype

    if [ "${metadata%%|*}" = "NEW" ]; then
        # Synthesize metadata from parent directory
        log_debug "Synthesizing metadata for NEW file"
        local parent
        parent=$(dirname "$vpath")
        local parent_stat
        parent_stat=$(stat -c '%d|%X|%Y|%Z' "$parent" 2>/dev/null)

        if [ -n "$parent_stat" ]; then
            dev=$(echo "$parent_stat" | cut -d'|' -f1)
            atime=$(echo "$parent_stat" | cut -d'|' -f2)
            mtime=$(echo "$parent_stat" | cut -d'|' -f3)
            ctime=$(echo "$parent_stat" | cut -d'|' -f4)
            # Generate pseudo-random inode
            ino=$(($(date +%s) + RANDOM))
            nlink=1
            size=0
            blocks=0
            blksize=4096
            log_debug "Synthesized: ino=$ino dev=$dev times from parent"
        else
            log_warn "Cannot get parent stats for $parent"
            log_func_exit "susfs_apply_kstat" "1" "no parent stats"
            return 1
        fi
    else
        # Parse cached metadata
        log_trace "Parsing cached metadata: $metadata"
        IFS='|' read -r ino dev nlink size atime mtime ctime blocks blksize fstype <<EOF
$metadata
EOF
        log_debug "Parsed: ino=$ino dev=$dev nlink=$nlink size=$size"
    fi

    # Apply kstat spoofing - use redirect API if rpath provided and capability exists
    local result rc cmd
    if [ -n "$rpath" ] && [ "$HAS_SUS_KSTAT_REDIRECT" = "1" ]; then
        cmd="add_sus_kstat_redirect"
        log_susfs_cmd "$cmd" "$vpath $rpath ino=$ino dev=$dev"
        result=$("$SUSFS_BIN" "$cmd" "$vpath" "$rpath" \
            "$ino" "$dev" "$nlink" "$size" \
            "$atime" 0 "$mtime" 0 "$ctime" 0 \
            "$blocks" "$blksize" 2>&1)
        rc=$?
    else
        cmd="add_sus_kstat_statically"
        log_susfs_cmd "$cmd" "$vpath ino=$ino dev=$dev"
        result=$("$SUSFS_BIN" "$cmd" "$vpath" \
            "$ino" "$dev" "$nlink" "$size" \
            "$atime" 0 "$mtime" 0 "$ctime" 0 \
            "$blocks" "$blksize" 2>&1)
        rc=$?
    fi
    log_susfs_result "$rc" "$cmd" "$vpath"

    if [ $rc -eq 0 ]; then
        SUSFS_STATS_KSTAT=$((SUSFS_STATS_KSTAT + 1))
        log_func_exit "susfs_apply_kstat" "0"
        return 0
    else
        log_err "$cmd failed for $vpath: $result"
        SUSFS_STATS_ERRORS=$((SUSFS_STATS_ERRORS + 1))
        log_func_exit "susfs_apply_kstat" "1"
        return 1
    fi
}

# ============================================================
# FUNCTION: Detect and hide overlay mounts for a path
# ============================================================
susfs_apply_mount_hiding() {
    local vpath="$1"
    log_func_enter "susfs_apply_mount_hiding" "$vpath"

    if [ "$HAS_SUSFS" != "1" ]; then
        log_debug "SUSFS not available, skipping"
        log_func_exit "susfs_apply_mount_hiding" "skip"
        return 0
    fi

    if [ "$HAS_SUS_MOUNT" != "1" ]; then
        log_debug "sus_mount not supported"
        log_func_exit "susfs_apply_mount_hiding" "skip" "not supported"
        return 0
    fi

    # Find mount point covering this path
    log_debug "Searching for overlay mount covering $vpath"
    local mount_point
    mount_point=$(awk -v path="$vpath" '
        ($3 == "overlay" || $3 == "tmpfs") && path ~ "^"$2 {
            print $2
            exit
        }
    ' /proc/mounts 2>/dev/null)

    if [ -n "$mount_point" ]; then
        log_debug "Found mount point: $mount_point"

        # Check if already hidden (avoid duplicates)
        if echo "$SUSFS_HIDDEN_MOUNTS" | grep -qF "|$mount_point|"; then
            log_debug "Mount already hidden: $mount_point"
            log_func_exit "susfs_apply_mount_hiding" "0" "already hidden"
            return 0
        fi

        log_susfs_cmd "add_sus_mount" "$mount_point"
        local result rc
        result=$("$SUSFS_BIN" add_sus_mount "$mount_point" 2>&1)
        rc=$?
        log_susfs_result "$rc" "add_sus_mount" "$mount_point"

        if [ $rc -eq 0 ]; then
            SUSFS_HIDDEN_MOUNTS="${SUSFS_HIDDEN_MOUNTS}|${mount_point}|"
            SUSFS_STATS_MOUNT=$((SUSFS_STATS_MOUNT + 1))
            susfs_update_config "sus_mount.txt" "$mount_point"
            log_func_exit "susfs_apply_mount_hiding" "0" "hidden"
            return 0
        else
            log_err "sus_mount failed for $mount_point: $result"
            SUSFS_STATS_ERRORS=$((SUSFS_STATS_ERRORS + 1))
            log_func_exit "susfs_apply_mount_hiding" "1"
            return 1
        fi
    else
        log_debug "No overlay mount found for $vpath"
        log_func_exit "susfs_apply_mount_hiding" "0" "no mount"
        return 0
    fi
}

# ============================================================
# FUNCTION: Update SUSFS config file for persistence
# ============================================================
susfs_update_config() {
    local config_name="$1"
    local entry="$2"
    log_func_enter "susfs_update_config" "$config_name" "$entry"

    if [ -z "$SUSFS_CONFIG_DIR" ]; then
        log_debug "No config directory, skipping persistence"
        log_func_exit "susfs_update_config" "skip"
        return 0
    fi

    local config_path="$SUSFS_CONFIG_DIR/$config_name"

    # Skip if already present
    if grep -qxF "$entry" "$config_path" 2>/dev/null; then
        log_trace "Entry already exists in $config_name"
        log_func_exit "susfs_update_config" "0" "exists"
        return 0
    fi

    # Add with NoMount marker for later cleanup
    log_trace "Adding entry to $config_path"
    {
        echo "# [NoMount] $(date '+%Y-%m-%d %H:%M:%S')"
        echo "$entry"
    } >> "$config_path" 2>/dev/null

    if [ $? -eq 0 ]; then
        log_debug "Updated $config_name: $entry"
        log_func_exit "susfs_update_config" "0"
        return 0
    else
        log_warn "Failed to write to $config_path"
        log_func_exit "susfs_update_config" "1"
        return 1
    fi
}

# ============================================================
# FUNCTION: Clean NoMount entries from SUSFS configs
# Called when module is removed/disabled
# ============================================================
susfs_clean_nomount_entries() {
    log_func_enter "susfs_clean_nomount_entries"

    if [ -z "$SUSFS_CONFIG_DIR" ]; then
        log_debug "No config directory"
        log_func_exit "susfs_clean_nomount_entries" "skip"
        return 0
    fi

    log_info "Cleaning NoMount entries from SUSFS configs..."

    local cleaned=0
    for config in sus_path.txt sus_path_loop.txt sus_mount.txt sus_maps.txt; do
        local config_path="$SUSFS_CONFIG_DIR/$config"
        if [ -f "$config_path" ]; then
            log_debug "Cleaning $config"
            local before=$(wc -l < "$config_path")
            sed -i '/# \[NoMount\]/,+1d' "$config_path" 2>/dev/null
            local after=$(wc -l < "$config_path")
            local removed=$((before - after))
            if [ $removed -gt 0 ]; then
                log_debug "Removed $removed entries from $config"
                cleaned=$((cleaned + removed))
            fi
        fi
    done

    log_info "Cleaned $cleaned total entries"
    log_func_exit "susfs_clean_nomount_entries" "$cleaned"
}

# ============================================================
# FUNCTION: Clean SUSFS entries for a specific module
# More surgical than susfs_clean_nomount_entries() - only removes
# entries that match paths from the specified module.
# Called from monitor.sh unregister_module()
# ============================================================
susfs_clean_module_entries() {
    local mod_name="$1"
    local tracking_file="$2"  # Path to module's tracking file with virtual paths
    log_func_enter "susfs_clean_module_entries" "$mod_name"

    if [ "$HAS_SUSFS" != "1" ]; then
        log_debug "SUSFS not available, skipping"
        log_func_exit "susfs_clean_module_entries" "skip"
        return 0
    fi

    if [ -z "$SUSFS_CONFIG_DIR" ]; then
        log_debug "No SUSFS config directory"
        log_func_exit "susfs_clean_module_entries" "skip"
        return 0
    fi

    if [ ! -f "$tracking_file" ]; then
        log_debug "No tracking file provided or file missing"
        log_func_exit "susfs_clean_module_entries" "skip"
        return 0
    fi

    log_info "Cleaning SUSFS entries for module: $mod_name"

    local cleaned=0
    local total_paths=$(wc -l < "$tracking_file" 2>/dev/null || echo 0)
    log_debug "Processing $total_paths paths from tracking file"

    # For each config file, remove entries matching tracked paths
    for config in sus_path.txt sus_path_loop.txt sus_maps.txt sus_mount.txt; do
        local config_path="$SUSFS_CONFIG_DIR/$config"
        [ ! -f "$config_path" ] && continue

        local before=$(wc -l < "$config_path")
        local temp_file="${config_path}.tmp.$$"

        # Filter out lines that match any path in the tracking file
        # Also remove associated NoMount comment lines
        while IFS= read -r line; do
            local skip=0
            # Skip comment lines that precede entries we're removing
            if echo "$line" | grep -q "^# \[NoMount\]"; then
                # Check if next line would be removed
                continue  # Will be handled by the path matching
            fi
            # Check if this line matches any tracked path
            while IFS= read -r tracked_path; do
                [ -z "$tracked_path" ] && continue
                if [ "$line" = "$tracked_path" ]; then
                    skip=1
                    break
                fi
            done < "$tracking_file"
            [ "$skip" -eq 0 ] && echo "$line"
        done < "$config_path" > "$temp_file"

        # Replace original with filtered content
        mv "$temp_file" "$config_path" 2>/dev/null

        local after=$(wc -l < "$config_path")
        local removed=$((before - after))
        if [ $removed -gt 0 ]; then
            log_debug "Removed $removed entries from $config"
            cleaned=$((cleaned + removed))
        fi
    done

    log_info "Cleaned $cleaned SUSFS entries for module $mod_name"
    log_func_exit "susfs_clean_module_entries" "$cleaned"
    return 0
}

# ============================================================
# FUNCTION: Clean metadata cache for a specific module
# Removes cached metadata files for paths from the specified module.
# Called from monitor.sh unregister_module()
# ============================================================
susfs_clean_module_metadata_cache() {
    local mod_name="$1"
    local tracking_file="$2"  # Path to module's tracking file with virtual paths
    log_func_enter "susfs_clean_module_metadata_cache" "$mod_name"

    if [ ! -d "$METADATA_CACHE_DIR" ]; then
        log_debug "No metadata cache directory"
        log_func_exit "susfs_clean_module_metadata_cache" "skip"
        return 0
    fi

    if [ ! -f "$tracking_file" ]; then
        log_debug "No tracking file provided or file missing"
        log_func_exit "susfs_clean_module_metadata_cache" "skip"
        return 0
    fi

    log_info "Cleaning metadata cache for module: $mod_name"

    local cleaned=0
    while IFS= read -r vpath; do
        [ -z "$vpath" ] && continue

        # Generate cache key (same algorithm as susfs_capture_metadata)
        local cache_key
        cache_key=$(echo "$vpath" | md5sum 2>/dev/null | cut -d' ' -f1)
        [ -z "$cache_key" ] && cache_key=$(echo "$vpath" | cksum | cut -d' ' -f1)

        local cache_file="$METADATA_CACHE_DIR/$cache_key"
        if [ -f "$cache_file" ]; then
            rm -f "$cache_file"
            cleaned=$((cleaned + 1))
            log_trace "Removed metadata cache: $cache_file (for $vpath)"
        fi
    done < "$tracking_file"

    log_info "Cleaned $cleaned metadata cache entries for module $mod_name"
    log_func_exit "susfs_clean_module_metadata_cache" "$cleaned"
    return 0
}

# ============================================================
# MAIN API: Register rule with automatic SUSFS integration
# This is the unified entry point that does EVERYTHING
# ============================================================
nm_register_rule_with_susfs() {
    local vpath="$1"
    local rpath="$2"
    local loader="${3:-$LOADER}"
    log_func_enter "nm_register_rule_with_susfs" "$vpath" "$rpath"

    # Input validation
    if [ -z "$vpath" ]; then
        log_warn "nm_register_rule_with_susfs: empty vpath"
        return 1
    fi
    if [ -z "$rpath" ]; then
        log_warn "nm_register_rule_with_susfs: empty rpath"
        return 1
    fi
    if [ ${#vpath} -gt 4096 ]; then
        log_warn "nm_register_rule_with_susfs: vpath exceeds PATH_MAX"
        return 1
    fi
    if [ ${#rpath} -gt 4096 ]; then
        log_warn "nm_register_rule_with_susfs: rpath exceeds PATH_MAX"
        return 1
    fi

    log_info "Registering: $vpath"

    # Step 1: Apply VFS redirect (NoMount kernel)
    log_debug "Step 1: VFS redirect"
    log_trace "Executing: $loader add '$vpath' '$rpath'"

    local vfs_result vfs_rc
    vfs_result=$("$loader" add "$vpath" "$rpath" </dev/null 2>&1)
    vfs_rc=$?

    if [ $vfs_rc -ne 0 ]; then
        log_err "VFS redirect failed: $vpath -> $rpath (rc=$vfs_rc, output=$vfs_result)"
        log_func_exit "nm_register_rule_with_susfs" "1" "vfs failed"
        return 1
    fi
    log_debug "VFS redirect OK"

    # Step 2: Get classification and cached metadata
    log_debug "Step 2: Classification"
    local actions
    actions=$(susfs_classify_path "$vpath")
    log_debug "Actions: $actions"

    local metadata
    metadata=$(susfs_get_cached_metadata "$vpath")

    # Step 3: Apply SUSFS protections based on classification
    log_debug "Step 3: SUSFS protections"
    if [ "$HAS_SUSFS" = "1" ]; then
        # sus_path or sus_path_loop
        if echo "$actions" | grep -q "sus_path_loop"; then
            log_trace "Applying sus_path_loop"
            susfs_apply_path "$vpath" 1
        elif echo "$actions" | grep -q "sus_path"; then
            log_trace "Applying sus_path"
            susfs_apply_path "$vpath" 0
        fi

        # sus_maps for libraries
        if echo "$actions" | grep -q "sus_maps"; then
            log_trace "Applying sus_maps"
            susfs_apply_maps "$vpath"
        fi

        # sus_kstat spoofing (pass rpath for redirect API)
        if echo "$actions" | grep -q "sus_kstat"; then
            log_trace "Applying sus_kstat"
            susfs_apply_kstat "$vpath" "$metadata" "$rpath"
        fi

        # Mount hiding check
        if echo "$actions" | grep -q "sus_mount_check"; then
            log_trace "Checking mount hiding"
            susfs_apply_mount_hiding "$vpath"
        fi
    else
        log_debug "SUSFS not available, skipping protections"
    fi

    log_func_exit "nm_register_rule_with_susfs" "0"
    return 0
}

# ============================================================
# FUNCTION: Batch capture metadata for a module
# Called early in post-fs-data.sh
# ============================================================
susfs_capture_module_metadata() {
    local mod_path="$1"
    local partitions="${2:-system vendor product system_ext odm oem}"
    log_func_enter "susfs_capture_module_metadata" "$mod_path"

    local count=0
    local total_files=0

    for partition in $partitions; do
        if [ -d "$mod_path/$partition" ]; then
            log_debug "Scanning partition: $partition"
            # Count files first
            local partition_files=$(find "$mod_path/$partition" -type f 2>/dev/null | wc -l)
            total_files=$((total_files + partition_files))
            log_trace "Found $partition_files files in $partition"

            find "$mod_path/$partition" -type f 2>/dev/null | while read -r real_path; do
                local vpath="${real_path#$mod_path}"
                susfs_capture_metadata "$vpath"
            done
        fi
    done

    log_info "Captured metadata for $total_files files from $(basename "$mod_path")"
    log_func_exit "susfs_capture_module_metadata" "$total_files"
    return 0
}

# ============================================================
# FUNCTION: Get SUSFS integration status summary
# ============================================================
susfs_status() {
    log_func_enter "susfs_status"

    echo "========================================"
    echo "SUSFS Integration Status"
    echo "========================================"

    if [ "$HAS_SUSFS" = "1" ]; then
        echo "Status: ENABLED"
        echo "Binary: $SUSFS_BIN"
        echo ""
        echo "Capabilities:"
        echo "  sus_path:      $HAS_SUS_PATH"
        echo "  sus_path_loop: $HAS_SUS_PATH_LOOP"
        echo "  sus_mount:     $HAS_SUS_MOUNT"
        echo "  sus_kstat:     $HAS_SUS_KSTAT"
        echo "  kstat_redirect: $HAS_SUS_KSTAT_REDIRECT"
        echo "  sus_maps:      $HAS_SUS_MAPS"
        echo ""
        echo "Config Directory: ${SUSFS_CONFIG_DIR:-none}"
        echo ""
        echo "Statistics (this session):"
        echo "  Paths hidden:  $SUSFS_STATS_PATH"
        echo "  Kstat applied: $SUSFS_STATS_KSTAT"
        echo "  Mounts hidden: $SUSFS_STATS_MOUNT"
        echo "  Maps hidden:   $SUSFS_STATS_MAPS"
        echo "  Errors:        $SUSFS_STATS_ERRORS"
    else
        echo "Status: DISABLED (NoMount-only mode)"
        echo "Reason: SUSFS binary not found"
    fi

    echo "========================================"
    log_func_exit "susfs_status" "displayed"
}

# ============================================================
# FUNCTION: Reset SUSFS statistics
# ============================================================
susfs_reset_stats() {
    log_func_enter "susfs_reset_stats"
    SUSFS_STATS_PATH=0
    SUSFS_STATS_KSTAT=0
    SUSFS_STATS_MOUNT=0
    SUSFS_STATS_MAPS=0
    SUSFS_STATS_ERRORS=0
    log_debug "Statistics reset"
    log_func_exit "susfs_reset_stats" "0"
}
