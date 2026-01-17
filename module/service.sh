#!/bin/sh
# NoMount Universal Hijacker - service.sh
# LATE BOOT PHASE: VFS registration (KPM should be loaded by now)
# Non-blocking check - if /dev/vfs_helper unavailable, skip gracefully

MODDIR=${0%/*}
LOADER="$MODDIR/bin/nm"
MODULES_DIR="/data/adb/modules"
NOMOUNT_DATA="/data/adb/nomount"
LOG_FILE="$NOMOUNT_DATA/nomount.log"
CONFIG_FILE="$NOMOUNT_DATA/config.sh"
VERBOSE_FLAG="$NOMOUNT_DATA/.verbose"
# Expanded partition list (matching Mountify's coverage)
TARGET_PARTITIONS="system vendor product system_ext odm oem mi_ext my_heytap prism optics oem_dlkm system_dlkm vendor_dlkm"

# Counters
ACTIVE_MODULES_COUNT=0
HIJACKED_OVERLAYS_COUNT=0

# Append to existing log
echo "" >> "$LOG_FILE"
echo "========== SERVICE.SH PHASE (Late Boot) ==========" >> "$LOG_FILE"
echo "Time: $(date)" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Initialize skip_mount tracking (fresh on each boot)
: > "$NOMOUNT_DATA/skipped_modules"

# Load config
universal_hijack=true
aggressive_mode=false
monitor_new_modules=true
excluded_modules=""
skip_hosts_modules=true
skip_nomount_marker=true

[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# Verbose mode
VERBOSE=false
[ -f "$VERBOSE_FLAG" ] && VERBOSE=true

# ============================================================
# FUNCTION: Logging helper
# ============================================================
log() {
    echo "$1" >> "$LOG_FILE"
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
echo "[INFO] Detected framework: $FRAMEWORK" >> "$LOG_FILE"

# APatch-specific handling
if [ "$FRAMEWORK" = "apatch" ]; then
    # APatch uses slightly different paths in some versions
    [ -d "/data/adb/ap/modules" ] && MODULES_DIR="/data/adb/ap/modules"
    echo "[INFO] APatch mode - using modules dir: $MODULES_DIR" >> "$LOG_FILE"
fi

# ============================================================
# NON-BLOCKING CHECK: Is /dev/vfs_helper available?
# ============================================================
if [ ! -c "/dev/vfs_helper" ]; then
    echo "[INFO] /dev/vfs_helper not available - VFS registration skipped" >> "$LOG_FILE"
    echo "[INFO] Module will work normally on next boot when KPM is loaded" >> "$LOG_FILE"
    echo "[INFO] Continuing without VFS..." >> "$LOG_FILE"

    # Still start monitor for module description updates
    sh "$MODDIR/monitor.sh" "0" "0" &
    exit 0
fi

echo "[OK] /dev/vfs_helper ready - proceeding with VFS registration" >> "$LOG_FILE"

# ============================================================
# HIDE /dev/vfs_helper FROM NON-ROOT DETECTION APPS
# ============================================================
# Kernel-level hiding returns ENOENT for non-root open() calls
# SUSFS sus_path provides additional protection (hides from readdir too)
# We must hide: /dev/vfs_helper, /sys/class/misc/vfs_helper, /sys/devices/virtual/misc/vfs_helper
if command -v ksu_susfs >/dev/null 2>&1; then
    # Hide device node
    ksu_susfs add_sus_path /dev/vfs_helper 2>/dev/null
    # Hide sysfs class entry (detectable via stat/readdir)
    ksu_susfs add_sus_path /sys/class/misc/vfs_helper 2>/dev/null
    # Hide sysfs device entry
    ksu_susfs add_sus_path /sys/devices/virtual/misc/vfs_helper 2>/dev/null
    echo "[HIDE] /dev/vfs_helper hidden via SUSFS (dev + sysfs)" >> "$LOG_FILE"
else
    echo "[HIDE] /dev/vfs_helper protected by kernel-level hiding (SUSFS not available)" >> "$LOG_FILE"
    echo "[WARN] /sys/class/misc/vfs_helper may still be visible without SUSFS" >> "$LOG_FILE"
fi

echo "" >> "$LOG_FILE"

# ============================================================
# FUNCTION: Check if module is excluded (by name)
# ============================================================
is_excluded() {
    mod_name="$1"
    # Use -w for portable word matching instead of \b
    echo "$excluded_modules" | grep -qw "$mod_name" && return 0
    return 1
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
        echo "  [SKIP] $mod_name has skip_nomount marker" >> "$LOG_FILE"
        return 0
    fi

    # Check for hosts file modification (detection risk)
    if [ "$skip_hosts_modules" = "true" ]; then
        for partition in $TARGET_PARTITIONS; do
            if [ -f "$mod_path/$partition/etc/hosts" ]; then
                echo "  [SKIP] $mod_name modifies /etc/hosts (detection risk)" >> "$LOG_FILE"
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
    echo "[HIJACK] Scanning for ALL module-related mounts..." >> "$LOG_FILE"

    # 1. Overlay mounts on target partitions
    while read -r device mountpoint fstype options rest; do
        if [ "$fstype" = "overlay" ]; then
            for partition in $TARGET_PARTITIONS; do
                if echo "$mountpoint" | grep -q "^/$partition"; then
                    echo "overlay:$mountpoint"
                    echo "[HIJACK] Found overlay: $mountpoint" >> "$LOG_FILE"
                fi
            done
        fi
    done < /proc/mounts

    # 2. Bind mounts (source contains /data/adb/modules)
    while read -r device mountpoint fstype options rest; do
        if echo "$options" | grep -q "bind"; then
            if echo "$device" | grep -q "/data/adb/modules"; then
                echo "bind:$mountpoint"
                echo "[HIJACK] Found bind mount: $mountpoint (source: $device)" >> "$LOG_FILE"
            fi
        fi
    done < /proc/mounts

    # 3. Check for bind mounts via same device/inode on target partitions
    # These may not have explicit bind option
    while read -r device mountpoint fstype options rest; do
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
                                echo "[HIJACK] Found hidden bind: $mountpoint" >> "$LOG_FILE"
                            fi
                        fi
                    done
                fi
            fi
        done
    done < /proc/mounts

    # 4. Loop mounts from module paths
    if command -v losetup >/dev/null 2>&1; then
        losetup -a 2>/dev/null | grep -E "modules|magisk" | while read -r loop_line; do
            loop_dev=$(echo "$loop_line" | cut -d: -f1)
            if grep -q "^$loop_dev " /proc/mounts; then
                loop_mount=$(grep "^$loop_dev " /proc/mounts | awk '{print $2}')
                echo "loop:$loop_mount"
                echo "[HIJACK] Found loop mount: $loop_mount (device: $loop_dev)" >> "$LOG_FILE"
            fi
        done
    fi

    # 5. tmpfs at suspicious locations (may be used by some modules)
    while read -r device mountpoint fstype options rest; do
        if [ "$fstype" = "tmpfs" ]; then
            for partition in $TARGET_PARTITIONS; do
                if echo "$mountpoint" | grep -q "^/$partition"; then
                    echo "tmpfs:$mountpoint"
                    echo "[HIJACK] Found tmpfs: $mountpoint" >> "$LOG_FILE"
                fi
            done
        fi
    done < /proc/mounts
}

# ============================================================
# FUNCTION: Check if overlay mount is from a module (not system)
# Returns 0 if module overlay, 1 if system overlay
# ============================================================
is_module_overlay() {
    local mountpoint="$1"
    local mount_line=$(grep " $mountpoint overlay " /proc/mounts 2>/dev/null)
    local options=$(echo "$mount_line" | awk '{print $4}')

    # Check if any option contains known module paths
    # Covers: Magisk, KernelSU, APatch module directories
    if echo "$options" | grep -qE "/data/adb/(modules|ksu|ap|magisk)/"; then
        return 0  # Is a module overlay
    fi

    # Check for KernelSU module_root style paths
    if echo "$options" | grep -qE "/data/adb/[^/]+/modules/"; then
        return 0
    fi

    # Fallback: Check if ANY module has content for this mountpoint
    # This catches cases where overlay options don't contain module path
    local relative="${mountpoint#/}"
    for mod_dir in "$MODULES_DIR"/*; do
        [ -d "$mod_dir" ] || continue
        if [ -d "$mod_dir/$relative" ] || [ -f "$mod_dir/$relative" ]; then
            return 0  # A module has content for this path
        fi
    done

    return 1  # System overlay - do not touch
}

# ============================================================
# FUNCTION: Find module that owns an overlay mount
# Returns module name or empty string
# ============================================================
find_module_for_overlay() {
    local mountpoint="$1"
    local mount_line=$(grep " $mountpoint overlay " /proc/mounts 2>/dev/null)
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

    # Try workdir (sometimes contains module path)
    local workdir=$(echo "$options" | tr ',' '\n' | grep "^workdir=" | sed 's/workdir=//')
    if echo "$workdir" | grep -q "/data/adb/modules/"; then
        echo "$workdir" | sed 's|.*/data/adb/modules/||' | cut -d/ -f1
        return
    fi

    # Check all lowerdir entries (overlay can have multiple)
    local all_lowerdirs=$(echo "$options" | tr ',' '\n' | grep "^lowerdir=" | sed 's/lowerdir=//' | tr ':' '\n')
    for dir in $all_lowerdirs; do
        if echo "$dir" | grep -q "/data/adb/modules/"; then
            echo "$dir" | sed 's|.*/data/adb/modules/||' | cut -d/ -f1
            return
        fi
    done

    # No module found
    echo ""
}

# ============================================================
# FUNCTION: Register .so files with SUSFS sus_map for /proc/maps hiding
# ============================================================
register_sus_map_for_module() {
    local mod_path="$1"
    local mod_name="$2"

    command -v ksu_susfs >/dev/null 2>&1 || return

    for partition in $TARGET_PARTITIONS; do
        if [ -d "$mod_path/$partition" ]; then
            find "$mod_path/$partition" -name "*.so" -type f 2>/dev/null | while read -r so_file; do
                ksu_susfs add_sus_map "$so_file" < /dev/null 2>/dev/null
                $VERBOSE && echo "  [SUS_MAP] $so_file" >> "$LOG_FILE"
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

    # Path tracking for monitor.sh to detect file changes later
    local tracking_dir="$NOMOUNT_DATA/module_paths"
    local tracking_file="$tracking_dir/$mod_name"
    mkdir -p "$tracking_dir"
    : > "$tracking_file"

    for partition in $TARGET_PARTITIONS; do
        if [ -d "$mod_path/$partition" ]; then
            (
                cd "$mod_path" || exit
                find "$partition" -type f -o -type c 2>/dev/null | while read -r relative_path; do
                    real_path="$mod_path/$relative_path"
                    virtual_path="/$relative_path"

                    if [ -c "$real_path" ]; then
                        $VERBOSE && echo "  [VFS] Whiteout: $virtual_path" >> "$LOG_FILE"
                        "$LOADER" add "$virtual_path" "/nonexistent" < /dev/null 2>/dev/null
                    else
                        $VERBOSE && echo "  [VFS] Inject: $virtual_path" >> "$LOG_FILE"
                        "$LOADER" add "$virtual_path" "$real_path" < /dev/null 2>/dev/null
                    fi

                    # Track for later sync
                    echo "$virtual_path" >> "$tracking_file"
                done
            )
        fi
    done

    register_sus_map_for_module "$mod_path" "$mod_name"
}

# ============================================================
# FUNCTION: Hijack a single mount (any type)
# ============================================================
hijack_mount() {
    local mount_info="$1"
    local mount_type="${mount_info%%:*}"
    local mountpoint="${mount_info#*:}"

    echo "[HIJACK] Processing $mount_type mount: $mountpoint" >> "$LOG_FILE"

    # CRITICAL: For overlay mounts, verify it's from a module, not Android system
    if [ "$mount_type" = "overlay" ]; then
        if ! is_module_overlay "$mountpoint"; then
            echo "  [SKIP] System overlay (not from module) - preserving" >> "$LOG_FILE"
            return 0
        fi
    fi

    local mod_name=""

    # Find owning module based on mount type
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
                            break 2
                        fi
                    fi
                done
            done
            ;;
    esac

    if [ -z "$mod_name" ]; then
        echo "  [WARN] Could not determine module for $mountpoint" >> "$LOG_FILE"
        return 1
    fi

    local mod_path="$MODULES_DIR/$mod_name"
    echo "  [INFO] Module: $mod_name (type: $mount_type)" >> "$LOG_FILE"

    if is_excluded "$mod_name"; then
        echo "  [SKIP] Module is in exclusion list" >> "$LOG_FILE"
        return 0
    fi

    # Content-aware filtering (skip hosts-modifying modules, skip_nomount markers)
    if should_skip_module "$mod_path" "$mod_name"; then
        return 0
    fi

    if [ ! -d "$mod_path" ]; then
        echo "  [WARN] Module directory not found: $mod_path" >> "$LOG_FILE"
        return 1
    fi

    echo "  [VFS] Registering files..." >> "$LOG_FILE"
    register_module_vfs "$mod_path" "$mod_name"

    echo "  [UNMOUNT] Attempting lazy unmount..." >> "$LOG_FILE"
    if umount -l "$mountpoint" 2>/dev/null; then
        echo "  [OK] Unmounted: $mountpoint" >> "$LOG_FILE"
        HIJACKED_OVERLAYS_COUNT=$((HIJACKED_OVERLAYS_COUNT + 1))
        return 0
    else
        if [ "$aggressive_mode" = "true" ]; then
            echo "  [WARN] Unmount failed, aggressive mode - continuing" >> "$LOG_FILE"
            return 0
        else
            echo "  [WARN] Unmount failed, keeping mount as fallback" >> "$LOG_FILE"
            return 1
        fi
    fi
}

# ============================================================
# FUNCTION: Process modules directly via VFS
# ============================================================
process_modules_direct() {
    echo "[DIRECT] Processing modules via VFS..." >> "$LOG_FILE"

    for mod_path in "$MODULES_DIR"/*; do
        [ -d "$mod_path" ] || continue
        mod_name="${mod_path##*/}"

        [ "$mod_name" = "nomount" ] && continue
        [ -f "$mod_path/disable" ] && continue
        [ -f "$mod_path/remove" ] && continue

        is_excluded "$mod_name" && continue

        # Content-aware filtering
        should_skip_module "$mod_path" "$mod_name" && continue

        has_content=false
        for partition in $TARGET_PARTITIONS; do
            [ -d "$mod_path/$partition" ] && has_content=true && break
        done

        if [ "$has_content" = "true" ]; then
            echo "[DIRECT] Processing: $mod_name" >> "$LOG_FILE"
            register_module_vfs "$mod_path" "$mod_name"
            ACTIVE_MODULES_COUNT=$((ACTIVE_MODULES_COUNT + 1))
        fi
    done
}

# ============================================================
# PHASE 1: Cache partition device IDs (SUSFS-independent)
# Must run EARLY before overlays change device IDs
# ============================================================
cache_partition_devs() {
    log "Phase 1: Caching partition device IDs..."
    local part_id=0
    for partition in system vendor product system_ext odm oem; do
        if [ -d "/$partition" ]; then
            local dev_info=$(stat -c '%t:%T' "/$partition" 2>/dev/null)
            if [ -n "$dev_info" ]; then
                local major=$(printf "%d" "0x${dev_info%:*}")
                local minor=$(printf "%d" "0x${dev_info#*:}")
                "$LOADER" setdev "$part_id" "$major" "$minor" 2>/dev/null
                log "  /$partition -> $major:$minor"
            fi
        fi
        part_id=$((part_id + 1))
    done
}

# ============================================================
# PHASE 2: Register hidden mounts (SUSFS-independent)
# Hides overlay/tmpfs mounts from /proc/mounts, /proc/self/mountinfo
# ============================================================
register_hidden_mounts() {
    log "Phase 2: Registering hidden mounts..."
    local count=0
    while IFS=' ' read -r mount_id rest; do
        local fstype=$(echo "$rest" | sed 's/.* - //' | cut -d' ' -f1)
        local mount_point=$(echo "$rest" | cut -d' ' -f4)

        case "$fstype" in
            overlay|tmpfs)
                for partition in $TARGET_PARTITIONS; do
                    if echo "$mount_point" | grep -qE "^/$partition(/|$)"; then
                        "$LOADER" hide "$mount_id" 2>/dev/null && {
                            log "  Hidden: $mount_id ($fstype @ $mount_point)"
                            count=$((count + 1))
                        }
                        break
                    fi
                done
                ;;
        esac
    done < /proc/self/mountinfo
    log "  Total: $count mounts hidden"
}

# ============================================================
# PHASE 3: Register maps patterns (SUSFS-independent)
# Hides suspicious paths from /proc/self/maps
# ============================================================
register_maps_patterns() {
    log "Phase 3: Registering maps patterns..."
    for pattern in "/data/adb" "magisk" "kernelsu" "zygisk"; do
        "$LOADER" addmap "$pattern" 2>/dev/null
        log "  Pattern: $pattern"
    done
}

# ============================================================
# MAIN EXECUTION (late boot phase)
# ============================================================

# ============================================================
# SUSFS-INDEPENDENT VFS HIDING (Phases 1-3)
# These run BEFORE file registration for complete detection evasion
# ============================================================
log "========== SUSFS-INDEPENDENT VFS HIDING =========="
cache_partition_devs
register_hidden_mounts
register_maps_patterns
log ""

if [ "$universal_hijack" = "true" ]; then
    echo "========== UNIVERSAL HIJACKER MODE ==========" >> "$LOG_FILE"

    # Phase 1: Detect and hijack ALL existing mounts (overlay, bind, loop, tmpfs)
    mount_list=$(detect_all_module_mounts)

    if [ -n "$mount_list" ]; then
        echo "" >> "$LOG_FILE"
        echo "[HIJACK] Hijacking ALL detected mounts..." >> "$LOG_FILE"

        # Use here-string to avoid subshell variable loss
        while read -r mount_info; do
            [ -n "$mount_info" ] && hijack_mount "$mount_info"
        done <<EOF
$mount_list
EOF

        echo "[HIJACK] Complete" >> "$LOG_FILE"
    else
        echo "[HIJACK] No module-related mounts detected" >> "$LOG_FILE"
    fi

    # Phase 2: Process all modules directly via VFS
    echo "" >> "$LOG_FILE"
    process_modules_direct

else
    echo "========== STANDARD MODE ==========" >> "$LOG_FILE"
    process_modules_direct
fi

# Handle UID exclusion list
if [ -f "$NOMOUNT_DATA/.exclusion_list" ]; then
    echo "" >> "$LOG_FILE"
    echo "[UID] Processing exclusion list..." >> "$LOG_FILE"
    while IFS= read -r uid; do
        [ -z "$uid" ] && continue
        "$LOADER" blk "$uid" 2>/dev/null
        echo "  [UID] Blocked: $uid" >> "$LOG_FILE"
    done < "$NOMOUNT_DATA/.exclusion_list"
fi

# Summary
echo "" >> "$LOG_FILE"
echo "========== SUMMARY ==========" >> "$LOG_FILE"
echo "Modules processed: $ACTIVE_MODULES_COUNT" >> "$LOG_FILE"
echo "Overlays hijacked: $HIJACKED_OVERLAYS_COUNT" >> "$LOG_FILE"
echo "Completed: $(date)" >> "$LOG_FILE"

# Start monitor
if [ "$monitor_new_modules" = "true" ]; then
    sh "$MODDIR/monitor.sh" "$ACTIVE_MODULES_COUNT" "$HIJACKED_OVERLAYS_COUNT" &
fi
