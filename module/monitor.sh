#!/bin/sh
# NoMount Universal Hijacker - monitor.sh
# Updates module description and watches for new module installs

MODDIR=${0%/*}
PROP_FILE="$MODDIR/module.prop"
MODULES_DIR="/data/adb/modules"
NOMOUNT_DATA="/data/adb/nomount"
LOG_FILE="$NOMOUNT_DATA/nomount.log"
CONFIG_FILE="$NOMOUNT_DATA/config.sh"
LOADER="$MODDIR/bin/nm"
TARGET_PARTITIONS="system vendor product system_ext odm oem"

MODULE_COUNT="$1"
HIJACKED_COUNT="$2"

[ -z "$MODULE_COUNT" ] && MODULE_COUNT=0
[ -z "$HIJACKED_COUNT" ] && HIJACKED_COUNT=0

# Load config
monitor_new_modules=true
excluded_modules=""
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

BASE_DESC="Universal Hijacker - VFS path redirection replaces all mounts"

# Build status string
if [ "$MODULE_COUNT" -gt 0 ]; then
    if [ "$HIJACKED_COUNT" -gt 0 ]; then
        STATUS="[⚡VFS: $MODULE_COUNT modules | $HIJACKED_COUNT hijacked]\\n"
    else
        STATUS="[⚡VFS: $MODULE_COUNT modules active]\\n"
    fi
else
    STATUS="[⚠️Idle: No modules found]\\n"
fi

# Update module description
sed -i "s|^description=.*|description=$STATUS$BASE_DESC|" "$PROP_FILE"

# ============================================================
# FUNCTION: Check if module is excluded
# ============================================================
is_excluded() {
    echo "$excluded_modules" | grep -q "$1" && return 0
    return 1
}

# ============================================================
# FUNCTION: Register a new module via VFS
# ============================================================
register_new_module() {
    local mod_path="$1"
    local mod_name=$(basename "$mod_path")

    echo "[MONITOR] New module detected: $mod_name" >> "$LOG_FILE"

    # Check if excluded
    if is_excluded "$mod_name"; then
        echo "[MONITOR] Skipping (excluded): $mod_name" >> "$LOG_FILE"
        return
    fi

    # Check if has mountable content
    local has_content=false
    for partition in $TARGET_PARTITIONS; do
        [ -d "$mod_path/$partition" ] && has_content=true && break
    done

    if [ "$has_content" = "true" ]; then
        # Inject skip_mount
        if [ ! -f "$mod_path/skip_mount" ]; then
            touch "$mod_path/skip_mount"
            echo "[MONITOR] Injected skip_mount: $mod_name" >> "$LOG_FILE"
        fi

        # Register files via VFS
        for partition in $TARGET_PARTITIONS; do
            if [ -d "$mod_path/$partition" ]; then
                (
                    cd "$mod_path" || exit
                    find "$partition" -type f -o -type c 2>/dev/null | while read -r relative_path; do
                        real_path="$mod_path/$relative_path"
                        virtual_path="/$relative_path"

                        if [ -c "$real_path" ]; then
                            "$LOADER" add "$virtual_path" "/nonexistent" < /dev/null 2>/dev/null
                        else
                            "$LOADER" add "$virtual_path" "$real_path" < /dev/null 2>/dev/null
                        fi
                    done
                )
            fi
        done
        echo "[MONITOR] Registered via VFS: $mod_name" >> "$LOG_FILE"

        # Update module count
        MODULE_COUNT=$((MODULE_COUNT + 1))
        STATUS="[⚡VFS: $MODULE_COUNT modules active]\\n"
        sed -i "s|^description=.*|description=$STATUS$BASE_DESC|" "$PROP_FILE"
    fi
}

# ============================================================
# FUNCTION: Watch for new modules (polling-based)
# ============================================================
watch_modules() {
    echo "[MONITOR] Starting module watcher..." >> "$LOG_FILE"

    # Get initial module list
    local known_modules=$(ls -1 "$MODULES_DIR" 2>/dev/null | sort)

    while true; do
        sleep 10

        # Get current module list
        local current_modules=$(ls -1 "$MODULES_DIR" 2>/dev/null | sort)

        # Find new modules
        for mod in $current_modules; do
            if ! echo "$known_modules" | grep -q "^${mod}$"; then
                # New module found
                local mod_path="$MODULES_DIR/$mod"
                if [ -d "$mod_path" ] && [ "$mod" != "nomount" ]; then
                    register_new_module "$mod_path"
                fi
            fi
        done

        # Update known modules
        known_modules="$current_modules"
    done
}

# Start watching if enabled
if [ "$monitor_new_modules" = "true" ]; then
    watch_modules &
fi
