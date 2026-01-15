#!/bin/sh
# NoMount Universal Hijacker - metamount.sh
# POST-FS-DATA PHASE: Only inject skip_mount (no VFS yet - KPM not loaded)
# VFS registration happens in service.sh at late boot

MODDIR=${0%/*}
MODULES_DIR="/data/adb/modules"
NOMOUNT_DATA="/data/adb/nomount"
LOG_FILE="$NOMOUNT_DATA/nomount.log"
CONFIG_FILE="$NOMOUNT_DATA/config.sh"
VERBOSE_FLAG="$NOMOUNT_DATA/.verbose"
TARGET_PARTITIONS="system vendor product system_ext odm oem"

INJECTED_SKIP_COUNT=0

# Create data directory
mkdir -p "$NOMOUNT_DATA"

# Initialize log
echo "=== NoMount Universal Hijacker ===" > "$LOG_FILE"
echo "Boot Time: $(date)" >> "$LOG_FILE"
echo "Kernel: $(uname -r)" >> "$LOG_FILE"
echo "Phase: post-fs-data (early boot)" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Load config (use defaults if not exists)
auto_skip_mount=true
excluded_modules=""

if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
    echo "[CONFIG] Loaded from $CONFIG_FILE" >> "$LOG_FILE"
else
    cp "$MODDIR/config.sh" "$CONFIG_FILE" 2>/dev/null
    echo "[CONFIG] Created default config" >> "$LOG_FILE"
fi

# Verbose mode
VERBOSE=false
[ -f "$VERBOSE_FLAG" ] && VERBOSE=true

echo "[CONFIG] auto_skip_mount=$auto_skip_mount" >> "$LOG_FILE"
echo "[CONFIG] excluded_modules=$excluded_modules" >> "$LOG_FILE"
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
# FUNCTION: Inject skip_mount into all module directories
# This runs at post-fs-data to prevent KSU from mounting
# ============================================================
inject_skip_mount_all() {
    echo "[INJECT] Creating skip_mount for all modules..." >> "$LOG_FILE"

    for mod_path in "$MODULES_DIR"/*; do
        [ -d "$mod_path" ] || continue
        mod_name="${mod_path##*/}"

        # Skip ourselves
        [ "$mod_name" = "nomount" ] && continue

        # Skip disabled/removed modules
        [ -f "$mod_path/disable" ] && continue
        [ -f "$mod_path/remove" ] && continue

        # Check if excluded
        if is_excluded "$mod_name"; then
            $VERBOSE && echo "  [SKIP] $mod_name (excluded)" >> "$LOG_FILE"
            continue
        fi

        # Check if has mountable content
        has_content=false
        for partition in $TARGET_PARTITIONS; do
            [ -d "$mod_path/$partition" ] && has_content=true && break
        done

        if [ "$has_content" = "true" ]; then
            if [ ! -f "$mod_path/skip_mount" ]; then
                touch "$mod_path/skip_mount"
                echo "  [INJECT] skip_mount: $mod_name" >> "$LOG_FILE"
                INJECTED_SKIP_COUNT=$((INJECTED_SKIP_COUNT + 1))
            else
                $VERBOSE && echo "  [EXISTS] skip_mount: $mod_name" >> "$LOG_FILE"
            fi
        fi
    done

    echo "[INJECT] Total: $INJECTED_SKIP_COUNT new skip_mount files" >> "$LOG_FILE"
}

# ============================================================
# MAIN EXECUTION (post-fs-data phase)
# ============================================================

echo "========== POST-FS-DATA PHASE ==========" >> "$LOG_FILE"
echo "[INFO] KPM may not be loaded yet - skipping VFS registration" >> "$LOG_FILE"
echo "[INFO] VFS registration will happen in service.sh (late boot)" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Only inject skip_mount at this phase
if [ "$auto_skip_mount" = "true" ]; then
    inject_skip_mount_all
fi

echo "" >> "$LOG_FILE"
echo "========== POST-FS-DATA COMPLETE ==========" >> "$LOG_FILE"
echo "skip_mount injected: $INJECTED_SKIP_COUNT" >> "$LOG_FILE"
echo "Completed: $(date)" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"
echo "[INFO] Waiting for service.sh to handle VFS registration..." >> "$LOG_FILE"
