#!/bin/sh
# NoMount Universal Hijacker - service.sh
# LATE BOOT PHASE: VFS registration (KPM should be loaded by now)
# Non-blocking check - if /dev/nomount unavailable, skip gracefully

MODDIR=${0%/*}
LOADER="$MODDIR/bin/nm"
MODULES_DIR="/data/adb/modules"
NOMOUNT_DATA="/data/adb/nomount"
LOG_FILE="$NOMOUNT_DATA/nomount.log"
CONFIG_FILE="$NOMOUNT_DATA/config.sh"
VERBOSE_FLAG="$NOMOUNT_DATA/.verbose"
TARGET_PARTITIONS="system vendor product system_ext odm oem"

# Counters
ACTIVE_MODULES_COUNT=0
HIJACKED_OVERLAYS_COUNT=0

# Append to existing log
echo "" >> "$LOG_FILE"
echo "========== SERVICE.SH PHASE (Late Boot) ==========" >> "$LOG_FILE"
echo "Time: $(date)" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Load config
universal_hijack=true
aggressive_mode=false
monitor_new_modules=true
excluded_modules=""

[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# Verbose mode
VERBOSE=false
[ -f "$VERBOSE_FLAG" ] && VERBOSE=true

# ============================================================
# NON-BLOCKING CHECK: Is /dev/nomount available?
# ============================================================
if [ ! -c "/dev/nomount" ]; then
    echo "[INFO] /dev/nomount not available - VFS registration skipped" >> "$LOG_FILE"
    echo "[INFO] Module will work normally on next boot when KPM is loaded" >> "$LOG_FILE"
    echo "[INFO] Continuing without VFS..." >> "$LOG_FILE"

    # Still start monitor for module description updates
    sh "$MODDIR/monitor.sh" "0" "0" &
    exit 0
fi

echo "[OK] /dev/nomount ready - proceeding with VFS registration" >> "$LOG_FILE"

# ============================================================
# HIDE /dev/nomount FROM NON-ROOT DETECTION APPS
# ============================================================
# Kernel-level hiding returns ENOENT for non-root open() calls
# SUSFS sus_path provides additional protection (hides from readdir too)
if command -v ksu_susfs >/dev/null 2>&1; then
    ksu_susfs add_sus_path /dev/nomount 2>/dev/null
    echo "[HIDE] /dev/nomount hidden via SUSFS sus_path" >> "$LOG_FILE"
else
    echo "[HIDE] /dev/nomount protected by kernel-level hiding (SUSFS not available)" >> "$LOG_FILE"
fi

echo "" >> "$LOG_FILE"

# ============================================================
# FUNCTION: Check if module is excluded
# ============================================================
is_excluded() {
    local mod_name="$1"
    echo "$excluded_modules" | grep -q "$mod_name" && return 0
    return 1
}

# ============================================================
# FUNCTION: Detect overlay mounts on target partitions
# ============================================================
detect_overlay_mounts() {
    echo "[HIJACK] Scanning for overlay mounts..." >> "$LOG_FILE"

    while read -r device mountpoint fstype options rest; do
        if [ "$fstype" = "overlay" ]; then
            for partition in $TARGET_PARTITIONS; do
                if echo "$mountpoint" | grep -q "^/$partition"; then
                    echo "$mountpoint"
                    echo "[HIJACK] Found overlay: $mountpoint" >> "$LOG_FILE"
                fi
            done
        fi
    done < /proc/mounts
}

# ============================================================
# FUNCTION: Find module that owns an overlay mount
# ============================================================
find_module_for_overlay() {
    local mountpoint="$1"
    local mount_line=$(grep " $mountpoint overlay " /proc/mounts)
    local options=$(echo "$mount_line" | awk '{print $4}')
    local lowerdir=$(echo "$options" | tr ',' '\n' | grep "^lowerdir=" | sed 's/lowerdir=//' | cut -d: -f1)

    if echo "$lowerdir" | grep -q "/data/adb/modules/"; then
        echo "$lowerdir" | sed 's|.*/data/adb/modules/||' | cut -d/ -f1
    fi
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
                ksu_susfs add_sus_map "$so_file" 2>/dev/null
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

    for partition in $TARGET_PARTITIONS; do
        if [ -d "$mod_path/$partition" ]; then
            (
                cd "$mod_path" || exit
                find "$partition" -type f -o -type c 2>/dev/null | while read -r relative_path; do
                    real_path="$mod_path/$relative_path"
                    virtual_path="/$relative_path"

                    if [ -c "$real_path" ]; then
                        $VERBOSE && echo "  [VFS] Whiteout: $virtual_path" >> "$LOG_FILE"
                        "$LOADER" add "$virtual_path" "/nonexistent" 2>/dev/null
                    else
                        $VERBOSE && echo "  [VFS] Inject: $virtual_path" >> "$LOG_FILE"
                        "$LOADER" add "$virtual_path" "$real_path" 2>/dev/null
                    fi
                done
            )
        fi
    done

    register_sus_map_for_module "$mod_path" "$mod_name"
}

# ============================================================
# FUNCTION: Hijack a single overlay mount
# ============================================================
hijack_overlay() {
    local mountpoint="$1"

    echo "[HIJACK] Processing: $mountpoint" >> "$LOG_FILE"

    local mod_name=$(find_module_for_overlay "$mountpoint")

    if [ -z "$mod_name" ]; then
        echo "  [WARN] Could not determine module for $mountpoint" >> "$LOG_FILE"
        return 1
    fi

    local mod_path="$MODULES_DIR/$mod_name"
    echo "  [INFO] Module: $mod_name" >> "$LOG_FILE"

    if is_excluded "$mod_name"; then
        echo "  [SKIP] Module is in exclusion list" >> "$LOG_FILE"
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
            echo "  [WARN] Unmount failed, keeping overlay as fallback" >> "$LOG_FILE"
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
# MAIN EXECUTION (late boot phase)
# ============================================================

if [ "$universal_hijack" = "true" ]; then
    echo "========== UNIVERSAL HIJACKER MODE ==========" >> "$LOG_FILE"

    # Phase 1: Detect and hijack existing overlay mounts
    overlay_list=$(detect_overlay_mounts)

    if [ -n "$overlay_list" ]; then
        echo "" >> "$LOG_FILE"
        echo "[HIJACK] Hijacking detected overlays..." >> "$LOG_FILE"

        echo "$overlay_list" | while read -r mountpoint; do
            [ -n "$mountpoint" ] && hijack_overlay "$mountpoint"
        done

        echo "[HIJACK] Complete" >> "$LOG_FILE"
    else
        echo "[HIJACK] No overlay mounts detected" >> "$LOG_FILE"
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
