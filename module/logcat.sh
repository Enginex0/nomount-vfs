#!/system/bin/sh
# NoMount VFS - Comprehensive Log Collection Script
# Collects kernel logs, module logs, and system state for debugging
# Usage: sh logcat.sh [command]
# Commands: collect, view, tail, export, clean, dmesg, status

MODDIR="${0%/*}"
NOMOUNT_DATA="/data/adb/nomount"
LOG_DIR="$NOMOUNT_DATA/logs"
MAIN_LOG="$NOMOUNT_DATA/nomount.log"
KERNEL_LOG="$LOG_DIR/dmesg.log"
STATE_LOG="$LOG_DIR/state.log"
EXPORT_FILE="$LOG_DIR/nomount_debug_$(date '+%Y%m%d_%H%M%S').txt"

# Colors for terminal output (if supported)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
    mkdir -p "$LOG_DIR" 2>/dev/null
    mkdir -p "$NOMOUNT_DATA" 2>/dev/null
}

# ============================================================
# KERNEL LOG CAPTURE (dmesg)
# ============================================================

capture_dmesg() {
    print_section "Capturing kernel logs (dmesg)"

    # Full dmesg with nomount filter
    if command -v dmesg >/dev/null 2>&1; then
        dmesg 2>/dev/null | grep -i "nomount\|vfs_dcache\|fs_dcache" > "$KERNEL_LOG.full" 2>/dev/null

        # Last 500 lines of filtered dmesg
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
    print_header "KERNEL LOGS (dmesg | grep nomount)"
    if [ -f "$KERNEL_LOG" ]; then
        cat "$KERNEL_LOG"
    else
        # Try live capture
        if command -v dmesg >/dev/null 2>&1; then
            dmesg 2>/dev/null | grep -i "nomount\|vfs_dcache" | tail -100
        else
            echo "[No kernel logs available]"
        fi
    fi
}

# ============================================================
# MODULE LOG CAPTURE
# ============================================================

capture_module_logs() {
    print_section "Capturing module logs"

    if [ -f "$MAIN_LOG" ]; then
        local lines=$(wc -l < "$MAIN_LOG" 2>/dev/null || echo "0")
        echo "  Main log: $MAIN_LOG ($lines lines)"
        cp "$MAIN_LOG" "$LOG_DIR/nomount.log.snapshot" 2>/dev/null
    else
        echo "  [WARN] Main log not found: $MAIN_LOG"
    fi
}

view_module_logs() {
    print_header "MODULE LOGS"
    if [ -f "$MAIN_LOG" ]; then
        cat "$MAIN_LOG"
    else
        echo "[No module logs found at $MAIN_LOG]"
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

        # Check VFS driver
        echo "--- VFS Driver Status ---"
        if [ -c "/dev/vfs_helper" ]; then
            echo "Driver: LOADED (/dev/vfs_helper exists)"
            ls -la /dev/vfs_helper 2>/dev/null
        else
            echo "Driver: NOT LOADED (/dev/vfs_helper missing)"
        fi
        echo ""

        # NM version
        echo "--- NM Tool Version ---"
        if [ -n "$nm_bin" ] && [ -x "$nm_bin" ]; then
            "$nm_bin" ver 2>&1 || echo "Failed to get version"
        else
            echo "NM binary not found"
        fi
        echo ""

        # VFS Rules
        echo "--- VFS Rules (nm list) ---"
        if [ -n "$nm_bin" ] && [ -x "$nm_bin" ]; then
            "$nm_bin" list 2>&1 || echo "Failed to list rules"
        else
            echo "NM binary not found"
        fi
        echo ""

        # Hidden mounts
        echo "--- Current Mounts ---"
        cat /proc/mounts 2>/dev/null | head -50
        echo "... (truncated)"
        echo ""

        # Module directories
        echo "--- Installed Modules ---"
        ls -la /data/adb/modules/ 2>/dev/null || echo "No modules directory"
        echo ""

        # Process info
        echo "--- NoMount Processes ---"
        ps -ef 2>/dev/null | grep -E "nomount|monitor\.sh|service\.sh" | grep -v grep || echo "No running processes"
        echo ""

    } > "$STATE_LOG" 2>&1

    echo "  State captured to: $STATE_LOG"
}

view_vfs_state() {
    print_header "VFS STATE"
    if [ -f "$STATE_LOG" ]; then
        cat "$STATE_LOG"
    else
        # Live capture
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
        echo "--- Android Properties ---"
        getprop ro.build.version.release 2>/dev/null && echo "Android: $(getprop ro.build.version.release)"
        getprop ro.build.version.sdk 2>/dev/null && echo "SDK: $(getprop ro.build.version.sdk)"
        getprop ro.product.model 2>/dev/null && echo "Model: $(getprop ro.product.model)"
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
    } > "$LOG_DIR/system.log" 2>&1

    echo "  System info captured to: $LOG_DIR/system.log"
}

# ============================================================
# EXPORT FUNCTION
# ============================================================

export_all() {
    print_header "EXPORTING ALL LOGS"
    ensure_dirs

    # Capture everything fresh
    capture_dmesg
    capture_module_logs
    capture_vfs_state
    capture_system_info

    # Combine into single file
    {
        echo "################################################################"
        echo "# NoMount VFS Debug Export"
        echo "# Generated: $(date)"
        echo "# Device: $(getprop ro.product.model 2>/dev/null || echo 'Unknown')"
        echo "################################################################"
        echo ""

        echo ""
        echo "================================================================"
        echo "                    SYSTEM INFORMATION"
        echo "================================================================"
        cat "$LOG_DIR/system.log" 2>/dev/null

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
        echo "                    MODULE LOGS"
        echo "================================================================"
        cat "$MAIN_LOG" 2>/dev/null || echo "[No module logs]"

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

tail_logs() {
    print_header "FOLLOWING LOGS (Ctrl+C to stop)"
    echo "Watching: $MAIN_LOG"
    echo ""

    if [ -f "$MAIN_LOG" ]; then
        tail -f "$MAIN_LOG"
    else
        echo "[Log file not found, creating watch...]"
        touch "$MAIN_LOG" 2>/dev/null
        tail -f "$MAIN_LOG"
    fi
}

# ============================================================
# CLEAN FUNCTION
# ============================================================

clean_logs() {
    print_header "CLEANING LOGS"

    if [ -d "$LOG_DIR" ]; then
        rm -rf "$LOG_DIR"/*
        echo "  Cleaned: $LOG_DIR"
    fi

    if [ -f "$MAIN_LOG" ]; then
        > "$MAIN_LOG"
        echo "  Cleared: $MAIN_LOG"
    fi

    echo "Logs cleaned."
}

# ============================================================
# STATUS FUNCTION
# ============================================================

show_status() {
    print_header "NOMOUNT STATUS"

    echo ""
    echo "--- Driver ---"
    if [ -c "/dev/vfs_helper" ]; then
        echo "  VFS Driver: LOADED"
    else
        echo "  VFS Driver: NOT LOADED"
    fi

    echo ""
    echo "--- Logs ---"
    if [ -f "$MAIN_LOG" ]; then
        local lines=$(wc -l < "$MAIN_LOG" 2>/dev/null || echo "0")
        local size=$(ls -lh "$MAIN_LOG" 2>/dev/null | awk '{print $5}')
        echo "  Main log: $lines lines ($size)"
        echo "  Last entry:"
        tail -1 "$MAIN_LOG" 2>/dev/null | sed 's/^/    /'
    else
        echo "  Main log: NOT FOUND"
    fi

    echo ""
    echo "--- Recent Errors ---"
    if [ -f "$MAIN_LOG" ]; then
        local errors=$(grep -c "\[ERROR\]" "$MAIN_LOG" 2>/dev/null || echo "0")
        echo "  Total errors: $errors"
        if [ "$errors" -gt 0 ]; then
            echo "  Last 5 errors:"
            grep "\[ERROR\]" "$MAIN_LOG" 2>/dev/null | tail -5 | sed 's/^/    /'
        fi
    fi

    echo ""
    echo "--- Kernel Messages ---"
    if command -v dmesg >/dev/null 2>&1; then
        local kmsg=$(dmesg 2>/dev/null | grep -c "nomount:" || echo "0")
        echo "  NoMount kernel messages: $kmsg"
        local kerrors=$(dmesg 2>/dev/null | grep "nomount:" | grep -ci "error\|fail" || echo "0")
        echo "  Kernel errors: $kerrors"
        if [ "$kerrors" -gt 0 ]; then
            echo "  Last kernel error:"
            dmesg 2>/dev/null | grep "nomount:" | grep -i "error\|fail" | tail -1 | sed 's/^/    /'
        fi
    fi

    echo ""
}

# ============================================================
# HELP FUNCTION
# ============================================================

show_help() {
    echo "NoMount VFS Log Collection Tool"
    echo ""
    echo "Usage: sh logcat.sh [command]"
    echo ""
    echo "Commands:"
    echo "  collect   - Capture all logs (dmesg, module, state)"
    echo "  view      - View all logs in terminal"
    echo "  tail      - Follow log file in real-time"
    echo "  export    - Export all logs to single file for sharing"
    echo "  clean     - Clear all log files"
    echo "  dmesg     - View kernel logs only"
    echo "  status    - Quick status overview"
    echo "  sync      - Force sync all modules (remove stale VFS rules)"
    echo "  sync <mod>- Force sync specific module"
    echo "  help      - Show this help"
    echo ""
    echo "Log Locations:"
    echo "  Main log:   $MAIN_LOG"
    echo "  Log dir:    $LOG_DIR"
    echo "  Kernel log: $KERNEL_LOG"
    echo ""
    echo "Examples:"
    echo "  sh logcat.sh status    # Quick health check"
    echo "  sh logcat.sh tail      # Follow logs in real-time"
    echo "  sh logcat.sh export    # Create shareable debug file"
    echo ""
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
        echo "Collection complete. Logs in: $LOG_DIR"
        ;;
    view)
        view_module_logs
        echo ""
        view_dmesg
        echo ""
        view_vfs_state
        ;;
    tail)
        tail_logs
        ;;
    export)
        export_all
        ;;
    clean)
        clean_logs
        ;;
    dmesg)
        capture_dmesg
        view_dmesg
        ;;
    status)
        show_status
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
        echo "Sync complete. Check logs for details:"
        echo "  tail -20 $MAIN_LOG | grep SYNC"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
