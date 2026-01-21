#!/system/bin/sh
# ============================================================
# NoMount VFS - Unified Log Collection Tool
# ============================================================
# Single CLI for all NoMount logging operations
#
# Usage: sh logcat.sh [command] [options]
#
# Commands:
#   collect     - Capture all logs (kernel, module, state)
#   view        - View all logs in terminal
#   tail        - Follow userspace log in real-time
#   export      - Export all logs to single file for sharing
#   clean       - Clear all log files
#   status      - Quick status overview
#   sync [mod]  - Force sync VFS rules
#   kernel      - Kernel log operations (see kernel -h)
#   help        - Show this help
#
# Kernel subcommand options:
#   kernel              - Collect NoMount kernel logs (default)
#   kernel -f|--follow  - Live tail of kernel logs
#   kernel -s|--susfs   - SUSFS logs only
#   kernel -a|--all     - All kernel logs (unfiltered)
#   kernel --stats      - Show kernel log statistics
#   kernel -c|--clear   - Clear ring buffer first
#   kernel -d|--dump    - Dump to stdout (no file)
#   kernel -v|--verbose - Include human-readable timestamps
# ============================================================

MODDIR="${0%/*}"
NOMOUNT_DATA="/data/adb/nomount"

# ============================================================
# SOURCE LOGGING LIBRARY
# ============================================================
if [ -f "$MODDIR/logging.sh" ]; then
    . "$MODDIR/logging.sh"
    LOGGING_LIB_LOADED=1
else
    LOGGING_LIB_LOADED=0
    # Minimal fallback if library not found
    NOMOUNT_LOG_BASE="$NOMOUNT_DATA/logs"
    LOG_DIR_KERNEL="$NOMOUNT_LOG_BASE/kernel"
    LOG_DIR_FRONTEND="$NOMOUNT_LOG_BASE/frontend"
    mkdir -p "$LOG_DIR_KERNEL" "$LOG_DIR_FRONTEND" 2>/dev/null
fi

# ============================================================
# CONFIGURATION
# ============================================================
MAIN_LOG="$NOMOUNT_DATA/nomount.log"
KERNEL_LOG="$LOG_DIR_KERNEL/dmesg.log"
STATE_LOG="$NOMOUNT_LOG_BASE/state.log"
EXPORT_FILE="$NOMOUNT_LOG_BASE/nomount_debug_$(date '+%Y%m%d_%H%M%S').txt"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

# Kernel log patterns
NOMOUNT_PATTERNS="nomount|vfs_dcache|NM_|nm_|VFS_HELPER|fs_dcache"
SUSFS_PATTERNS="susfs|sus_path|sus_mount|sus_kstat|SUS_"
ALL_PATTERNS="$NOMOUNT_PATTERNS|$SUSFS_PATTERNS"

# Kernel log rotation settings
MAX_KERNEL_LOG_FILES=10

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================================
# HELPER FUNCTIONS
# ============================================================

print_header() {
    echo ""
    echo "============================================================"
    echo " $1"
    echo "============================================================"
}

print_section() {
    echo ""
    echo "--- $1 ---"
}

ensure_dirs() {
    mkdir -p "$LOG_DIR_KERNEL" 2>/dev/null
    mkdir -p "$LOG_DIR_FRONTEND" 2>/dev/null
    mkdir -p "$NOMOUNT_LOG_BASE" 2>/dev/null
}

# ============================================================
# KERNEL LOG FUNCTIONS (merged from collect_kernel_logs.sh)
# ============================================================

kernel_rotate_logs() {
    local pattern="$1"
    local count=$(ls -1 "$LOG_DIR_KERNEL"/$pattern 2>/dev/null | wc -l)

    if [ "$count" -gt "$MAX_KERNEL_LOG_FILES" ]; then
        local to_remove=$((count - MAX_KERNEL_LOG_FILES))
        ls -1t "$LOG_DIR_KERNEL"/$pattern 2>/dev/null | tail -n "$to_remove" | while read -r f; do
            rm -f "$LOG_DIR_KERNEL/$f"
        done
    fi
}

kernel_collect_filtered() {
    local filter="$1"
    local output_file="$2"
    local include_timestamp="$3"

    echo "Collecting kernel logs matching: $filter"
    echo "Output: $output_file"
    echo ""

    {
        echo "# ============================================================"
        echo "# NoMount Kernel Log Collection"
        echo "# Date: $(date)"
        echo "# Device: $(getprop ro.product.model 2>/dev/null) ($(getprop ro.product.device 2>/dev/null))"
        echo "# Kernel: $(uname -r)"
        echo "# Filter: $filter"
        echo "# ============================================================"
        echo ""
    } > "$output_file"

    if [ "$include_timestamp" = "1" ]; then
        dmesg -T 2>/dev/null | grep -iE "$filter" >> "$output_file"
    else
        dmesg 2>/dev/null | grep -iE "$filter" >> "$output_file"
    fi

    local line_count=$(wc -l < "$output_file")
    echo "Collected $line_count lines"
    echo "Saved to: $output_file"
}

kernel_collect_all() {
    local output_file="$1"

    echo "Collecting ALL kernel logs (unfiltered)"
    echo "Output: $output_file"
    echo ""

    {
        echo "# ============================================================"
        echo "# Full Kernel Log Dump"
        echo "# Date: $(date)"
        echo "# Device: $(getprop ro.product.model 2>/dev/null)"
        echo "# Kernel: $(uname -r)"
        echo "# ============================================================"
        echo ""
    } > "$output_file"

    dmesg -T 2>/dev/null >> "$output_file"

    local line_count=$(wc -l < "$output_file")
    echo "Collected $line_count lines"
}

kernel_follow() {
    local filter="$1"
    local output_file="$LOG_DIR_KERNEL/kernel_live.log"

    echo "Following kernel logs matching: $filter"
    echo "Press Ctrl+C to stop"
    echo "Also saving to: $output_file"
    echo ""
    echo "--- Live Kernel Log Stream ---"

    : > "$output_file"

    # Use dmesg -w if available, otherwise poll
    if dmesg -w --help >/dev/null 2>&1; then
        dmesg -wT 2>/dev/null | grep -iE --line-buffered "$filter" | tee -a "$output_file"
    else
        local last_line=""
        while true; do
            local current=$(dmesg 2>/dev/null | grep -iE "$filter" | tail -20)
            if [ "$current" != "$last_line" ]; then
                echo "$current" | while read -r line; do
                    if ! grep -qF "$line" "$output_file" 2>/dev/null; then
                        echo "$line" | tee -a "$output_file"
                    fi
                done
                last_line="$current"
            fi
            sleep 1
        done
    fi
}

kernel_dump_stdout() {
    local filter="$1"

    echo "# ============================================================"
    echo "# NoMount Kernel Log Dump"
    echo "# Date: $(date)"
    echo "# Filter: $filter"
    echo "# ============================================================"
    echo ""

    dmesg -T 2>/dev/null | grep -iE "$filter"
}

kernel_show_stats() {
    echo ""
    echo "# ============================================================"
    echo "# NoMount Kernel Log Statistics"
    echo "# ============================================================"

    local total=$(dmesg 2>/dev/null | wc -l)
    local nomount=$(dmesg 2>/dev/null | grep -ciE "$NOMOUNT_PATTERNS" || echo 0)
    local susfs=$(dmesg 2>/dev/null | grep -ciE "$SUSFS_PATTERNS" || echo 0)
    local errors=$(dmesg 2>/dev/null | grep -ciE "(nomount|vfs_dcache|susfs).*error" || echo 0)
    local warnings=$(dmesg 2>/dev/null | grep -ciE "(nomount|vfs_dcache|susfs).*warn" || echo 0)

    echo "Total kernel log lines: $total"
    echo "NoMount related: $nomount"
    echo "SUSFS related: $susfs"
    echo "Errors: $errors"
    echo "Warnings: $warnings"
    echo ""

    echo "Recent NoMount activity (last 10 lines):"
    echo "---"
    dmesg -T 2>/dev/null | grep -iE "$NOMOUNT_PATTERNS" | tail -10
    echo ""
}

kernel_clear_buffer() {
    echo "Clearing kernel ring buffer..."
    dmesg -c >/dev/null 2>&1
    echo "Ring buffer cleared"
}

kernel_help() {
    cat << 'EOF'
NoMount Kernel Log Collector

Usage: sh logcat.sh kernel [OPTIONS]

Options:
  -h, --help     Show this help
  -f, --follow   Follow mode (live tail of kernel logs)
  -a, --all      Collect ALL kernel logs (unfiltered)
  -s, --susfs    Collect SUSFS logs only
  -n, --nomount  Collect NoMount logs only (default)
  -c, --clear    Clear kernel ring buffer before collecting
  -d, --dump     One-time dump to stdout (no file)
  -v, --verbose  Include human-readable timestamps
  --stats        Show kernel log statistics

Output Directory: /data/adb/nomount/logs/kernel/

Log Files:
  kernel_nomount_YYYYMMDD_HHMMSS.log  - NoMount specific logs
  kernel_susfs_YYYYMMDD_HHMMSS.log    - SUSFS specific logs
  kernel_all_YYYYMMDD_HHMMSS.log      - All kernel logs
  kernel_live.log                      - Current follow session

Examples:
  sh logcat.sh kernel              # Collect NoMount logs
  sh logcat.sh kernel -f           # Follow all NoMount/SUSFS logs
  sh logcat.sh kernel -s           # SUSFS logs only
  sh logcat.sh kernel --stats      # Show statistics
  sh logcat.sh kernel -c -f        # Clear buffer, then follow
EOF
}

# Main kernel command handler
cmd_kernel() {
    local mode="nomount"
    local clear_first=0
    local verbose=0
    local dump_only=0

    # Parse kernel subcommand arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                kernel_help
                return 0
                ;;
            -f|--follow)
                mode="follow"
                ;;
            -a|--all)
                mode="all"
                ;;
            -s|--susfs)
                mode="susfs"
                ;;
            -n|--nomount)
                mode="nomount"
                ;;
            -c|--clear)
                clear_first=1
                ;;
            -d|--dump)
                dump_only=1
                ;;
            -v|--verbose)
                verbose=1
                ;;
            --stats)
                kernel_show_stats
                return 0
                ;;
            *)
                echo "Unknown kernel option: $1"
                kernel_help
                return 1
                ;;
        esac
        shift
    done

    # Clear ring buffer if requested
    if [ "$clear_first" = "1" ]; then
        kernel_clear_buffer
    fi

    # Execute based on mode
    case "$mode" in
        follow)
            kernel_follow "$ALL_PATTERNS"
            ;;
        all)
            if [ "$dump_only" = "1" ]; then
                dmesg -T 2>/dev/null
            else
                kernel_rotate_logs "kernel_all_*.log"
                kernel_collect_all "$LOG_DIR_KERNEL/kernel_all_$TIMESTAMP.log"
            fi
            ;;
        susfs)
            if [ "$dump_only" = "1" ]; then
                kernel_dump_stdout "$SUSFS_PATTERNS"
            else
                kernel_rotate_logs "kernel_susfs_*.log"
                kernel_collect_filtered "$SUSFS_PATTERNS" "$LOG_DIR_KERNEL/kernel_susfs_$TIMESTAMP.log" "$verbose"
            fi
            ;;
        nomount|*)
            if [ "$dump_only" = "1" ]; then
                kernel_dump_stdout "$NOMOUNT_PATTERNS"
            else
                kernel_rotate_logs "kernel_nomount_*.log"
                kernel_collect_filtered "$NOMOUNT_PATTERNS" "$LOG_DIR_KERNEL/kernel_nomount_$TIMESTAMP.log" "$verbose"
                kernel_show_stats
            fi
            ;;
    esac
}

# ============================================================
# LEGACY DMESG CAPTURE (simple version for collect/view)
# ============================================================

capture_dmesg() {
    print_section "Capturing kernel logs (dmesg)"

    if command -v dmesg >/dev/null 2>&1; then
        dmesg 2>/dev/null | grep -iE "$ALL_PATTERNS" > "$KERNEL_LOG.full" 2>/dev/null
        tail -500 "$KERNEL_LOG.full" > "$KERNEL_LOG" 2>/dev/null

        local count=$(wc -l < "$KERNEL_LOG" 2>/dev/null || echo "0")
        echo "  Captured $count kernel log lines"
        echo "  Full log: $KERNEL_LOG.full"
        echo "  Recent log: $KERNEL_LOG"
    else
        echo "  [WARN] dmesg not available"
    fi
}

view_dmesg() {
    print_header "KERNEL LOGS (dmesg | grep nomount/susfs)"
    if [ -f "$KERNEL_LOG" ]; then
        cat "$KERNEL_LOG"
    else
        if command -v dmesg >/dev/null 2>&1; then
            dmesg 2>/dev/null | grep -iE "$ALL_PATTERNS" | tail -100
        else
            echo "[No kernel logs available]"
        fi
    fi
}

# ============================================================
# MODULE LOG FUNCTIONS
# ============================================================

capture_module_logs() {
    print_section "Capturing module logs"

    # Capture from new structured location
    if [ -d "$LOG_DIR_FRONTEND" ]; then
        local total=0
        for f in "$LOG_DIR_FRONTEND"/*.log; do
            [ -f "$f" ] || continue
            local lines=$(wc -l < "$f" 2>/dev/null || echo "0")
            total=$((total + lines))
            echo "  $(basename "$f"): $lines lines"
        done
        echo "  Total frontend logs: $total lines"
    fi

    # Also check legacy location
    if [ -f "$MAIN_LOG" ]; then
        local lines=$(wc -l < "$MAIN_LOG" 2>/dev/null || echo "0")
        echo "  Legacy log: $MAIN_LOG ($lines lines)"
        cp "$MAIN_LOG" "$NOMOUNT_LOG_BASE/nomount.log.snapshot" 2>/dev/null
    fi
}

view_module_logs() {
    print_header "MODULE LOGS"

    # Show structured logs first
    if [ -d "$LOG_DIR_FRONTEND" ]; then
        for f in "$LOG_DIR_FRONTEND"/*.log; do
            [ -f "$f" ] || continue
            echo ""
            echo "=== $(basename "$f") ==="
            tail -50 "$f"
        done
    fi

    # Show legacy log
    if [ -f "$MAIN_LOG" ]; then
        echo ""
        echo "=== Legacy nomount.log ==="
        tail -100 "$MAIN_LOG"
    fi
}

# ============================================================
# VFS STATE CAPTURE
# ============================================================

capture_vfs_state() {
    print_section "Capturing VFS state"

    local nm_bin=""
    [ -x "$MODDIR/nm-arm64" ] && nm_bin="$MODDIR/nm-arm64"
    [ -x "$MODDIR/bin/nm" ] && nm_bin="$MODDIR/bin/nm"
    [ -x "/data/adb/modules/nomount/bin/nm" ] && nm_bin="/data/adb/modules/nomount/bin/nm"

    {
        echo "=== VFS State Capture $(date) ==="
        echo ""

        echo "--- VFS Driver Status ---"
        if [ -c "/dev/vfs_helper" ]; then
            echo "Driver: LOADED (/dev/vfs_helper exists)"
            ls -la /dev/vfs_helper 2>/dev/null
        else
            echo "Driver: NOT LOADED (/dev/vfs_helper missing)"
        fi
        echo ""

        echo "--- NM Tool ---"
        if [ -n "$nm_bin" ] && [ -x "$nm_bin" ]; then
            echo "Binary: $nm_bin"
            "$nm_bin" ver 2>&1 || echo "Failed to get version"
        else
            echo "NM binary not found"
        fi
        echo ""

        echo "--- VFS Rules (nm list) ---"
        if [ -n "$nm_bin" ] && [ -x "$nm_bin" ]; then
            "$nm_bin" list 2>&1 || echo "Failed to list rules"
        fi
        echo ""

        echo "--- Current Mounts (first 50) ---"
        cat /proc/mounts 2>/dev/null | head -50
        echo "..."
        echo ""

        echo "--- Installed Modules ---"
        ls -la /data/adb/modules/ 2>/dev/null || echo "No modules directory"
        echo ""

        echo "--- NoMount Processes ---"
        ps -ef 2>/dev/null | grep -E "nomount|monitor\.sh|service\.sh" | grep -v grep || echo "None running"
        echo ""

    } > "$STATE_LOG" 2>&1

    echo "  State captured to: $STATE_LOG"
}

view_vfs_state() {
    print_header "VFS STATE"
    if [ -f "$STATE_LOG" ]; then
        cat "$STATE_LOG"
    else
        capture_vfs_state
        cat "$STATE_LOG"
    fi
}

# ============================================================
# SYSTEM INFO CAPTURE
# ============================================================

capture_system_info() {
    print_section "Capturing system info"

    {
        echo "=== System Info $(date) ==="
        echo ""
        echo "--- Kernel ---"
        uname -a 2>/dev/null
        echo ""
        echo "--- Android ---"
        echo "Version: $(getprop ro.build.version.release 2>/dev/null)"
        echo "SDK: $(getprop ro.build.version.sdk 2>/dev/null)"
        echo "Model: $(getprop ro.product.model 2>/dev/null)"
        echo "Device: $(getprop ro.product.device 2>/dev/null)"
        echo ""
        echo "--- SELinux ---"
        getenforce 2>/dev/null || echo "Unknown"
        echo ""
        echo "--- Memory ---"
        free 2>/dev/null || cat /proc/meminfo 2>/dev/null | head -5
        echo ""
        echo "--- Storage ---"
        df -h /data 2>/dev/null || df /data 2>/dev/null
        echo ""
    } > "$NOMOUNT_LOG_BASE/system.log" 2>&1

    echo "  System info captured to: $NOMOUNT_LOG_BASE/system.log"
}

# ============================================================
# EXPORT FUNCTION
# ============================================================

cmd_export() {
    print_header "EXPORTING ALL LOGS"
    ensure_dirs

    capture_dmesg
    capture_module_logs
    capture_vfs_state
    capture_system_info

    {
        echo "################################################################"
        echo "# NoMount VFS Debug Export"
        echo "# Generated: $(date)"
        echo "# Device: $(getprop ro.product.model 2>/dev/null || echo 'Unknown')"
        echo "################################################################"
        echo ""

        echo "================================================================"
        echo "                    SYSTEM INFORMATION"
        echo "================================================================"
        cat "$NOMOUNT_LOG_BASE/system.log" 2>/dev/null

        echo ""
        echo "================================================================"
        echo "                    VFS STATE"
        echo "================================================================"
        cat "$STATE_LOG" 2>/dev/null

        echo ""
        echo "================================================================"
        echo "                    KERNEL LOGS (dmesg)"
        echo "================================================================"
        cat "$KERNEL_LOG" 2>/dev/null || echo "[No kernel logs]"

        echo ""
        echo "================================================================"
        echo "                    FRONTEND LOGS"
        echo "================================================================"
        for f in "$LOG_DIR_FRONTEND"/*.log; do
            [ -f "$f" ] || continue
            echo ""
            echo "--- $(basename "$f") ---"
            cat "$f"
        done

        echo ""
        echo "================================================================"
        echo "                    LEGACY MODULE LOG"
        echo "================================================================"
        cat "$MAIN_LOG" 2>/dev/null || echo "[No legacy log]"

        echo ""
        echo "================================================================"
        echo "                    END OF EXPORT"
        echo "================================================================"

    } > "$EXPORT_FILE"

    echo ""
    echo "Export complete!"
    echo "File: $EXPORT_FILE"
    echo "Size: $(ls -lh "$EXPORT_FILE" 2>/dev/null | awk '{print $5}')"
    echo ""
    echo "To retrieve via ADB:"
    echo "  adb pull $EXPORT_FILE"
}

# ============================================================
# TAIL/FOLLOW FUNCTION
# ============================================================

cmd_tail() {
    print_header "FOLLOWING LOGS (Ctrl+C to stop)"

    # Prefer structured service.log
    local log_to_tail="$LOG_DIR_FRONTEND/service.log"
    [ ! -f "$log_to_tail" ] && log_to_tail="$MAIN_LOG"

    echo "Watching: $log_to_tail"
    echo ""

    if [ -f "$log_to_tail" ]; then
        tail -f "$log_to_tail"
    else
        echo "[Log file not found, creating watch...]"
        touch "$log_to_tail" 2>/dev/null
        tail -f "$log_to_tail"
    fi
}

# ============================================================
# CLEAN FUNCTION
# ============================================================

cmd_clean() {
    print_header "CLEANING LOGS"

    if [ "$LOGGING_LIB_LOADED" = "1" ]; then
        log_clear_all
    else
        rm -f "$LOG_DIR_KERNEL"/*.log 2>/dev/null
        rm -f "$LOG_DIR_FRONTEND"/*.log 2>/dev/null
        rm -f "$NOMOUNT_LOG_BASE"/*.log 2>/dev/null
        echo "Cleaned: $NOMOUNT_LOG_BASE"
    fi

    if [ -f "$MAIN_LOG" ]; then
        > "$MAIN_LOG"
        echo "Cleared: $MAIN_LOG"
    fi

    echo "Logs cleaned."
}

# ============================================================
# STATUS FUNCTION
# ============================================================

cmd_status() {
    print_header "NOMOUNT STATUS"

    echo ""
    echo "--- Driver ---"
    if [ -c "/dev/vfs_helper" ]; then
        echo "  VFS Driver: ${GREEN}LOADED${NC}"
    else
        echo "  VFS Driver: ${RED}NOT LOADED${NC}"
    fi

    echo ""
    echo "--- Logging Library ---"
    if [ "$LOGGING_LIB_LOADED" = "1" ]; then
        echo "  Library: LOADED"
        [ -n "$LOG_LEVEL" ] && echo "  Log Level: $LOG_LEVEL"
    else
        echo "  Library: NOT LOADED (using fallback)"
    fi

    echo ""
    echo "--- Frontend Logs ---"
    if [ -d "$LOG_DIR_FRONTEND" ]; then
        for f in "$LOG_DIR_FRONTEND"/*.log; do
            [ -f "$f" ] || continue
            local lines=$(wc -l < "$f" 2>/dev/null || echo "0")
            local size=$(ls -lh "$f" 2>/dev/null | awk '{print $5}')
            echo "  $(basename "$f"): $lines lines ($size)"
        done
    fi

    echo ""
    echo "--- Kernel Logs ---"
    local kcount=$(ls -1 "$LOG_DIR_KERNEL"/*.log 2>/dev/null | wc -l)
    echo "  Log files: $kcount"
    if command -v dmesg >/dev/null 2>&1; then
        local kmsg=$(dmesg 2>/dev/null | grep -c "nomount:" || echo "0")
        echo "  NoMount kernel messages: $kmsg"
    fi

    echo ""
    echo "--- Recent Errors ---"
    local errors=0
    for f in "$LOG_DIR_FRONTEND"/*.log "$MAIN_LOG"; do
        [ -f "$f" ] || continue
        local e=$(grep -c "\[ERROR\]" "$f" 2>/dev/null || echo "0")
        errors=$((errors + e))
    done
    echo "  Total errors: $errors"
    if [ "$errors" -gt 0 ]; then
        echo "  Last error:"
        grep "\[ERROR\]" "$LOG_DIR_FRONTEND"/*.log "$MAIN_LOG" 2>/dev/null | tail -1 | sed 's/^/    /'
    fi

    echo ""
}

# ============================================================
# HELP FUNCTION
# ============================================================

show_help() {
    cat << 'EOF'
NoMount VFS - Unified Log Collection Tool

Usage: sh logcat.sh [command] [options]

Commands:
  collect     Capture all logs (kernel, module, state, system)
  view        View all logs in terminal
  tail        Follow userspace log in real-time
  export      Export all logs to single file for sharing
  clean       Clear all log files
  status      Quick status overview
  sync [mod]  Force sync VFS rules (all or specific module)
  kernel      Kernel log operations (use 'kernel -h' for details)
  help        Show this help

Kernel Subcommand:
  kernel              Collect NoMount kernel logs (default)
  kernel -f|--follow  Live tail of kernel logs
  kernel -s|--susfs   SUSFS logs only
  kernel -a|--all     All kernel logs (unfiltered)
  kernel --stats      Show kernel log statistics
  kernel -c|--clear   Clear ring buffer before collecting
  kernel -d|--dump    Dump to stdout (no file)
  kernel -v|--verbose Include human-readable timestamps

Log Locations:
  Frontend:  /data/adb/nomount/logs/frontend/
  Kernel:    /data/adb/nomount/logs/kernel/
  SUSFS:     /data/adb/nomount/logs/susfs/
  Archive:   /data/adb/nomount/logs/archive/
  Legacy:    /data/adb/nomount/nomount.log

Examples:
  sh logcat.sh status           # Quick health check
  sh logcat.sh tail             # Follow frontend logs
  sh logcat.sh kernel -f        # Follow kernel logs
  sh logcat.sh kernel --stats   # Kernel log statistics
  sh logcat.sh export           # Create shareable debug file
EOF
}

# ============================================================
# MAIN
# ============================================================

ensure_dirs

case "${1:-help}" in
    collect)
        print_header "COLLECTING ALL LOGS"
        capture_dmesg
        capture_module_logs
        capture_vfs_state
        capture_system_info
        echo ""
        echo "Collection complete. Logs in: $NOMOUNT_LOG_BASE"
        ;;
    view)
        view_module_logs
        echo ""
        view_dmesg
        echo ""
        view_vfs_state
        ;;
    tail)
        cmd_tail
        ;;
    export)
        cmd_export
        ;;
    clean)
        cmd_clean
        ;;
    status)
        cmd_status
        ;;
    kernel)
        shift
        cmd_kernel "$@"
        ;;
    sync)
        print_header "FORCE SYNC VFS RULES"
        if [ -n "$2" ]; then
            echo "Syncing module: $2"
            sh "$MODDIR/sync.sh" "$2"
        else
            echo "Syncing all tracked modules..."
            sh "$MODDIR/sync.sh"
        fi
        echo ""
        echo "Sync complete. Check logs:"
        echo "  sh logcat.sh status"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown command: $1"
        echo ""
        show_help
        exit 1
        ;;
esac
