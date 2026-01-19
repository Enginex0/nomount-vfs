#!/system/bin/sh
# NoMount VFS - Early Boot Hook (post-fs-data phase)
# This script runs BEFORE service.sh, BEFORE zygote, to pre-register VFS rules
# from a cache created during the previous boot.
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
RULE_CACHE="$NOMOUNT_DATA/.rule_cache"
LOG_FILE="$NOMOUNT_DATA/nomount.log"

# Ensure log directory exists
mkdir -p "$NOMOUNT_DATA" 2>/dev/null

# ============================================================
# LOGGING (simple, early-boot safe)
# ============================================================
log_pfd() {
    echo "[$(date '+%H:%M:%S')] [POST-FS-DATA] $*" >> "$LOG_FILE" 2>/dev/null
}

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
    return 1
}

# ============================================================
# MAIN EXECUTION
# ============================================================
log_pfd "[INFO] Early boot hook starting..."

# Find nm binary
NM_BIN=$(find_nm_binary)
if [ -z "$NM_BIN" ]; then
    log_pfd "[WARN] nm binary not found, skipping early registration"
    exit 0
fi

log_pfd "[INFO] Using nm binary: $NM_BIN"

# Check if VFS driver is available
if [ ! -c "/dev/vfs_helper" ]; then
    log_pfd "[INFO] /dev/vfs_helper not available yet, skipping early registration"
    exit 0
fi

log_pfd "[INFO] VFS driver available"

# Check if cache exists
if [ ! -f "$RULE_CACHE" ]; then
    log_pfd "[INFO] No rule cache found at $RULE_CACHE, skipping early registration"
    exit 0
fi

# Validate cache file is not empty and has reasonable size
cache_size=$(wc -c < "$RULE_CACHE" 2>/dev/null || echo 0)
if [ "$cache_size" -eq 0 ]; then
    log_pfd "[INFO] Rule cache is empty, skipping early registration"
    exit 0
fi

if [ "$cache_size" -gt 10485760 ]; then
    # Cache > 10MB is suspicious, skip
    log_pfd "[WARN] Rule cache suspiciously large ($cache_size bytes), skipping"
    exit 0
fi

log_pfd "[INFO] Loading cached VFS rules from $RULE_CACHE ($cache_size bytes)..."

# Register cached rules
# Cache format: cmd|virtual_path|real_path
# cmd: "add" for file injection, "hide" for path hiding
count=0
fail_count=0

while IFS='|' read -r cmd vpath rpath || [ -n "$cmd" ]; do
    # Skip empty lines
    [ -z "$cmd" ] && continue

    # Skip comments (lines starting with #)
    case "$cmd" in
        \#*) continue ;;
    esac

    case "$cmd" in
        add)
            # Validate paths exist (vpath is the destination, rpath is the source)
            if [ -z "$vpath" ] || [ -z "$rpath" ]; then
                log_pfd "[WARN] Invalid add rule: missing path (vpath='$vpath', rpath='$rpath')"
                fail_count=$((fail_count + 1))
                continue
            fi

            # Register VFS rule
            if "$NM_BIN" add "$vpath" "$rpath" </dev/null >/dev/null 2>&1; then
                count=$((count + 1))
            else
                fail_count=$((fail_count + 1))
            fi
            ;;
        hide)
            # Hide mount - vpath contains mount_id
            if [ -z "$vpath" ]; then
                fail_count=$((fail_count + 1))
                continue
            fi

            if "$NM_BIN" hide "$vpath" </dev/null >/dev/null 2>&1; then
                count=$((count + 1))
            else
                fail_count=$((fail_count + 1))
            fi
            ;;
        setdev)
            # Partition device spoofing: setdev|partition_id|major|minor
            if [ -z "$vpath" ] || [ -z "$rpath" ]; then
                fail_count=$((fail_count + 1))
                continue
            fi
            # vpath contains "partition_id|major", rpath contains "minor"
            # Actually for setdev we store: setdev|partition_id|major:minor
            local part_id="$vpath"
            local major_minor="$rpath"
            local major="${major_minor%%:*}"
            local minor="${major_minor##*:}"

            if "$NM_BIN" setdev "$part_id" "$major" "$minor" </dev/null >/dev/null 2>&1; then
                count=$((count + 1))
            else
                fail_count=$((fail_count + 1))
            fi
            ;;
        addmap)
            # Maps pattern: addmap|pattern|
            if [ -z "$vpath" ]; then
                fail_count=$((fail_count + 1))
                continue
            fi

            if "$NM_BIN" addmap "$vpath" </dev/null >/dev/null 2>&1; then
                count=$((count + 1))
            else
                fail_count=$((fail_count + 1))
            fi
            ;;
        *)
            # Unknown command, skip
            log_pfd "[WARN] Unknown cache command: $cmd"
            ;;
    esac
done < "$RULE_CACHE"

log_pfd "[INFO] Pre-registered $count cached VFS rules ($fail_count failed)"
log_pfd "[INFO] Early boot hook complete"

# Always exit successfully - never fail boot
exit 0
