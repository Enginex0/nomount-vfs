# NoMount VFS Debugging Handoff Document

**Date**: 2026-01-22
**Session Duration**: ~4 hours
**Status**: IN PROGRESS - Critical findings made, root cause partially identified

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Problem Statement](#2-problem-statement)
3. [Repository Structure](#3-repository-structure)
4. [Architectural Changes Made](#4-architectural-changes-made)
5. [KernelSU Research Findings](#5-kernelsu-research-findings)
6. [Debug Logging Added](#6-debug-logging-added)
7. [Test Results & Findings](#7-test-results--findings)
8. [Root Cause Analysis](#8-root-cause-analysis)
9. [Current State](#9-current-state)
10. [Next Steps](#10-next-steps)
11. [Key Commands Reference](#11-key-commands-reference)

---

## 1. Executive Summary

### The Problem
NoMount VFS kernel module's stat spoofing is NOT working. When apps call `stat()` on redirected files (like `/system/etc/audio_effects.conf`), they see the real device ID (64815 = /data partition) instead of the spoofed device ID (64773 = /system partition). This causes Gboard to crash with SIGSEGV in libminikin.so when accessing emoji fonts.

### What We Discovered
1. **The inode-based hook (`generic_fillattr`) IS working** - it finds the match for injected files
2. **The path-based hook (`vfs_getattr_nosec`) is NOT being called for target files** - only for `/dev/__properties__`
3. **Even when the match is found, the device ID is NOT being spoofed**
4. **KernelSU does NOT interfere** - it only hooks `/system/bin/su` paths

### Current Status
- Debug logging with 121 `pr_info()` statements is deployed
- Build successful, kernel flashed and running
- We can see exactly what's happening but spoofing still fails
- Need to investigate why `nomount_spoof_stat()` isn't changing the device ID

---

## 2. Problem Statement

### Symptoms
1. **Gboard crashes** with SIGSEGV in libminikin.so when accessing emoji fonts
2. **stat() returns wrong device ID**: `/system/etc/X` returns 64815 (/data) instead of 64773 (/system)
3. **statfs() returns wrong filesystem**: f2fs instead of erofs for /system paths
4. **readlink leaks real path**: `/proc/self/fd/X` shows `/data/adb/...` instead of `/system/...`

### Root Cause (Original Theory)
NoMount used INODE-based stat spoofing. When apps access files DIRECTLY (like `/system/fonts/X`) vs through redirected paths, the inodes are DIFFERENT, so spoofing fails.

### Solution Approach (What We Implemented)
Port HymoFS's proven architecture:
- Dual hash tables (forward + reverse lookup)
- PATH-based stat spoofing instead of inode-based
- Path normalization for consistent lookups
- statfs cache initialization fix
- d_path reverse lookup fix

---

## 3. Repository Structure

### Local Paths
```
/home/claudetest/gki-build/
├── nomount-vfs-clone/           # Main NoMount module code (THIS REPO)
│   ├── patches/
│   │   ├── nomount-core-5.10.patch    # MAIN KERNEL PATCH (what we modified)
│   │   ├── nomount-kernel-5.10.patch  # Alternative patch (not used in build)
│   │   ├── inject-stat-hooks.sh       # Injects hooks into fs/stat.c
│   │   ├── inject-readdir-hooks.sh
│   │   ├── inject-statfs-hooks.sh
│   │   ├── inject-xattr-hooks.sh
│   │   ├── inject-namei-hooks.sh
│   │   └── inject-maps-hooks.sh
│   ├── module/
│   │   ├── service.sh                 # Main boot script
│   │   ├── post-fs-data.sh            # Early boot script
│   │   └── bin/nm                     # Userspace binary
│   └── src/
│       └── nm.c                       # Userspace source
│
├── fork-nomount/                # GKI Build repo (triggers CI)
│   └── .github/workflows/       # Build workflows
│
└── kernel-test/                 # Kernel source for dry-testing
    └── android12-5.10-2024-05/  # GKI kernel source tree
```

### Remote Repositories
| Repo | URL | Purpose |
|------|-----|---------|
| NoMount VFS | https://github.com/Enginex0/nomount-vfs | Module source code |
| GKI Build | https://github.com/Enginex0/GKI_KernelSU_SUSFS | Kernel build CI |
| HymoFS Reference | https://github.com/Anatdx/HymoFS | Architecture reference |

### Device Info
- **Device**: Xiaomi Redmi 14C (codename: lake)
- **Android**: 14
- **Kernel**: 5.10.209
- **Root**: KernelSU + SUSFS

---

## 4. Architectural Changes Made

### Phase 1: Reverse Hash Table
**Status**: Already existed in code
- `nomount_targets_ht` hash table for real_path -> virtual_path lookups
- `target_node` field in `struct nomount_rule`
- `nomount_lookup_by_real_path()` function for O(1) reverse lookup

### Phase 2: Path-Based Stat Spoofing
**Status**: Implemented
- Added `NOMOUNT_INODE_XOR_MAGIC` (0x4E4F4D4F = "NOMO")
- Modified `vfs_dcache_spoof_stat_dev()` to use path-based matching
- Uses reverse hash table lookup for real_path -> rule resolution
- Falls back to prefix-based lookup if no rule found

### Phase 3: Path Normalization
**Status**: Implemented
- Added `nomount_normalize_path()` function
- Normalizes `/system/etc/X` -> `/etc/X` (Android symlink mapping)
- Called before hash computation in all lookup functions

### Phase 4: statfs Cache Fix
**Status**: Implemented
- Added `nm_statfs_initializing` bypass flag
- Bypasses redirects during `kern_path()` calls in cache init
- Ensures `/system` returns erofs, not f2fs from redirect target

### Phase 5: d_path Reverse Lookup
**Status**: Implemented
- Added `nomount_process_d_path()` for path-based spoofing
- Uses O(1) reverse hash table lookup
- Returns virtual path instead of real path for `/proc/fd/X`

### Commit History
```
cd36395 debug: MAXIMUM verbosity pr_info tracing for stat spoof diagnosis (CURRENT)
ef0fe8f debug: MAXIMUM verbosity pr_info tracing (amended)
52ab3cf debug: Add comprehensive pr_info tracing
b995ef8 fix(patch): Correct vfs_dcache.c hunk count to 2491 lines
64429b9 feat(kernel): Implement path-based stat spoofing architecture
```

---

## 5. KernelSU Research Findings

### KernelSU Does NOT Interfere with NoMount
**Critical Finding**: KernelSU's stat hook ONLY modifies `/system/bin/su` paths.

```c
// From KernelSU kernel/sucompat.c
int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags)
{
    const char su[] = "/system/bin/su";

    // ONLY for allowed UIDs
    if (!ksu_is_allow_uid_for_current(current_uid().val))
        return 0;

    // ONLY modifies /system/bin/su → /system/bin/sh
    if (!memcmp(path, su, sizeof(su))) {
        *filename_user = sh_user_path();
    }
    return 0;
}
```

### Hook Execution Order
```
User calls stat("/system/etc/audio_effects.conf")
         │
         ▼
┌─────────────────────────────────────────┐
│ KSU Syscall Tracepoint (sys_enter)      │
│ - Checks: Is this /system/bin/su?       │
│ - Answer: NO → passes through unchanged │
└─────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│ Kernel VFS Layer                        │
│ - vfs_statx() / vfs_fstatat()           │
│ - NoMount hooks HERE                    │
└─────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│ OverlayFS (meta-overlayfs mounts)       │
│ - Returns overlaid file                 │
└─────────────────────────────────────────┘
```

### KernelSU Mount Mechanism
- All KernelSU mounts use `source="KSU"` identifier
- Mounting is done by `meta-overlayfs` (userspace metamodule)
- OverlayFS changes inode numbers (detection vector)
- `/proc/mounts` shows mounts with `KSU` device name

### Boot Sequence (When Mounts Happen)
```
post-fs-data.sh scripts run FIRST
    ↓
metamount.sh runs (OverlayFS mounts happen HERE)
    ↓
post-mount.sh scripts run AFTER mounting
```

### Detection Vectors NoMount Must Address
| Vector | What Apps Check | NoMount Must |
|--------|-----------------|--------------|
| `/proc/mounts` | Mount entries with `KSU` source | Filter/hide entries |
| `stat()` results | Inode numbers, device IDs | Spoof to match original |
| Extended attrs | `trusted.overlay.opaque` | Hide overlay xattrs |
| Device ID | Files show different dev IDs | Return consistent dev ID |

---

## 6. Debug Logging Added

### Total: 121 pr_info() Statements

All logging uses unconditional `pr_info()` (NOT the conditional `NM_DBG`/`NM_INFO` macros which require debug level 2/3).

### Logging Locations

#### A. Rule Storage (`nomount_ioctl_add_rule`)
- Virtual path being added
- Real path being added
- Hash computed for virtual/real paths
- cached_partition_dev value stored

#### B. Hash Table State (NOMOUNT_IOC_ENABLE handler)
- Dumps all rules in `nomount_rules_ht`
- Dumps all rules in `nomount_targets_ht`
- Total count of rules

#### C. Partition Dev Cache (`nomount_init_partition_devs`)
- Each partition path checked
- Device ID found for each
- Whether cache was populated

#### D. `nomount_normalize_path()`
- Input path
- Which normalization rule matched
- Output path

#### E. `nomount_lookup_by_real_path()`
- Input real_path
- Normalized path
- Hash computed
- Every rule in the hash bucket
- Match or no match

#### F. `nomount_get_partition_dev()` / `nomount_get_partition_dev_for_path()`
- Input path
- Which prefix matched
- Device ID returned

#### G. `vfs_dcache_spoof_stat_dev()` (PATH-BASED HOOK)
- Entry: path, stat->dev, stat->ino, current UID
- After UID blocked check
- Reverse lookup result
- Prefix fallback result
- DECISION: expected_dev vs actual stat->dev
- SPOOFED or NO_CHANGE with reason

#### H. Hook Injection Points (`inject-stat-hooks.sh`)
- `vfs_getattr_nosec` hook: logs path/dev/ino before and after
- `generic_fillattr` hook: logs when injected file detected

#### I. `nomount_is_injected_file()` / `nomount_spoof_stat()` (INODE-BASED)
- What inode is being checked
- Whether identified as injected
- What spoofing is applied

### Log Prefix Format
```
nomount: [FUNCTION_NAME] message
```

Examples:
```
nomount: [ADD_RULE] vpath=/system/etc/X rpath=/data/adb/... vhash=XXX rhash=YYY
nomount: [ENABLE] dumping rules: total=55
nomount: [SPOOF_STAT_DEV] DECISION: expected=64773 actual=64815 -> WILL_SPOOF
nomount: [IS_INJECTED] MATCHED: ino=55971 dev=253:47 -> vpath=/system/etc/audio_effects.conf
```

---

## 7. Test Results & Findings

### Test Commands Run
```bash
# Test 1: stat device ID
sudo adb shell "su -c 'stat /system/etc/audio_effects.conf'" | grep Device
# Result: Device: fd2fh/64815d (WRONG - should be 64773)

# Test 2: statfs filesystem type
sudo adb shell "su -c 'stat -f /system/fonts/NotoColorEmoji.ttf'" | grep Type
# Result: Type: f2fs (WRONG - should be erofs)

# Test 3: Font file accessibility
sudo adb shell "su -c 'head -c 4 /system/fonts/NotoColorEmoji.ttf | xxd'"
# Result: 0001 0000 (PASS - TrueType magic correct)

# Test 4: readlink/d_path
sudo adb shell "su -c 'exec 7</system/fonts/NotoColorEmoji.ttf && readlink /proc/\$\$/fd/7'"
# Result: /data/adb/modules/... (WRONG - should show /system/fonts/...)
```

### Critical Debug Findings

#### Finding 1: Inode-Based Hook WORKS
When running `ls -la /system/etc/audio_effects.conf`:
```
nomount: [IS_INJECTED] checking ino=55971 dev=253:47
nomount: [IS_INJECTED] MATCHED: ino=55971 dev=253:47 -> vpath=/system/etc/audio_effects.conf
nomount: [IS_INJECTED] RESULT: ino=55971 -> INJECTED
nomount: [HOOK] generic_fillattr ENTER ino=55971 dev=253:47 uid=0
nomount: [HOOK] generic_fillattr AFTER dev=253:47 ino=55971
```

The `generic_fillattr` hook IS triggering and the inode-based match IS working.

#### Finding 2: Path-Based Hook NOT Called for Target Files
When running `stat /system/etc/audio_effects.conf`:
```
nomount: [SPOOF_STAT_DEV] ============ ENTER ============
nomount: [SPOOF_STAT_DEV] path=/dev/__properties__          <-- WRONG PATH!
nomount: [SPOOF_STAT_DEV] PHASE1: NO rule found
nomount: [SPOOF_STAT_DEV] PHASE2 result: expected_dev=0:0
nomount: [SPOOF_STAT_DEV] ============ NO SPOOFING ============
```

The `vfs_getattr_nosec` hook is being called, but ONLY for `/dev/__properties__`, NOT for our target file `/system/etc/audio_effects.conf`.

#### Finding 3: Device ID Not Spoofed Even When Match Found
Even when `[IS_INJECTED] MATCHED` appears:
```
nomount: [HOOK] generic_fillattr AFTER dev=253:47 ino=55971
```
The device is STILL 253:47 (64815 in decimal) - NOT being changed to system partition.

#### Finding 4: File Identity Verified
```bash
# Module file:
stat /data/adb/modules/viperfxmod/system/etc/audio_effects.conf
# ino=55971 dev=fd2f (253:47)

# Virtual path (after overlay):
stat /system/etc/audio_effects.conf
# ino=55971 dev=fd2f (253:47)
```
Both show SAME inode/dev because OverlayFS redirect IS working - they're the same file now.

---

## 8. Root Cause Analysis

### The Two Hook Systems

NoMount has TWO separate stat spoofing mechanisms:

#### 1. Inode-Based Hook (in `generic_fillattr`)
- Location: Injected by `inject-stat-hooks.sh` into `generic_fillattr()`
- Trigger: Called for EVERY file's attributes
- Logic: Checks `nomount_is_injected_file(inode)` which scans rules by inode
- Status: **WORKING** - finds matches correctly

#### 2. Path-Based Hook (in `vfs_getattr_nosec`)
- Location: Injected by `inject-stat-hooks.sh` into `vfs_getattr_nosec()`
- Trigger: Called when stat is performed with a `struct path`
- Logic: Gets path via `d_path()`, calls `vfs_dcache_spoof_stat_dev(path, stat)`
- Status: **NOT CALLED FOR TARGET FILES** - only triggers for `/dev/__properties__`

### Why Path-Based Hook Doesn't Trigger

The `vfs_getattr_nosec` hook requires the code path to go through `vfs_getattr_nosec()`. But when `stat()` is called on an overlayfs file, the call may go through a different code path that doesn't call `vfs_getattr_nosec()`.

Possible reasons:
1. OverlayFS has its own `getattr` implementation that bypasses `vfs_getattr_nosec`
2. The `stat` syscall takes a different path than `ls` (which does work)
3. The hook injection point is wrong

### Why Inode-Based Hook Doesn't Spoof

Even though `nomount_is_injected_file()` returns true (MATCHED), the `nomount_spoof_stat()` function is supposed to change `stat->dev`, but the debug logs show:
```
nomount: [HOOK] generic_fillattr AFTER dev=253:47 ino=55971
```

The device is UNCHANGED. This means either:
1. `nomount_spoof_stat()` is not being called after the match
2. Or it's being called but not changing the device
3. Or the change is being overwritten afterward

---

## 9. Current State

### What's Working
- OverlayFS file redirect (content comes from module)
- Inode-based matching (`nomount_is_injected_file` finds matches)
- Debug logging (121 pr_info statements active)
- Build and flash process

### What's NOT Working
- stat() device ID spoofing (shows 64815 instead of 64773)
- statfs() filesystem type spoofing (shows f2fs instead of erofs)
- d_path spoofing (real path leaked)
- Gboard still crashes

### Files Modified (Not Yet Committed)
None - all debug changes were committed and pushed.

### Current Kernel
Commit `cd36395` with full debug logging is running on the device.

---

## 10. Next Steps

### Immediate Investigation Needed

1. **Check if `nomount_spoof_stat()` is being called**
   - Add pr_info at the START of `nomount_spoof_stat()`
   - Verify if it's called when `IS_INJECTED` returns true

2. **Check what `nomount_spoof_stat()` does**
   - Review the code in `nomount-core-5.10.patch`
   - Add logging for `stat->dev` before and after modification
   - Check if `cached_partition_dev` is populated

3. **Investigate why path-based hook skips target files**
   - Check OverlayFS's `getattr` implementation
   - May need to hook at a different level (e.g., directly in overlayfs)

4. **Check the hook injection**
   - Review `inject-stat-hooks.sh`
   - Verify the hooks are placed in the correct functions
   - Check if OverlayFS bypasses these hooks

### Code to Review

```bash
# nomount_spoof_stat function (inode-based)
grep -A 50 "void nomount_spoof_stat" patches/nomount-core-5.10.patch

# generic_fillattr hook injection
cat patches/inject-stat-hooks.sh

# OverlayFS getattr (in kernel source)
cat /home/claudetest/gki-build/kernel-test/android12-5.10-2024-05/common/fs/overlayfs/inode.c
```

### Potential Fixes

1. **Hook OverlayFS directly**: Instead of hooking VFS, hook OverlayFS's `ovl_getattr()`
2. **Fix `nomount_spoof_stat()`**: Ensure it actually modifies `stat->dev`
3. **Use d_path in inode hook**: Get path from dentry in `generic_fillattr` hook

---

## 11. Key Commands Reference

### Build & Deploy
```bash
# Push changes
cd /home/claudetest/gki-build/nomount-vfs-clone
sudo -u president git push origin main

# Trigger build
cd /home/claudetest/gki-build/fork-nomount
sudo -u president gh workflow run "Build Kernels" -f ksu_variant=WKSU -f build_custom=true

# Check build status
sudo -u president gh run list --workflow="Build Kernels" --limit 3

# Get build link
# https://github.com/Enginex0/GKI_KernelSU_SUSFS/actions/runs/XXXXX
```

### Dry-Test Before Build
```bash
bash /home/claudetest/.claude/skills/dry-test/validate.sh android12 5.10 209
```

### Debug on Device
```bash
# Clear dmesg and run test
sudo adb shell "su -c 'dmesg -c > /dev/null; stat /system/etc/audio_effects.conf; dmesg | grep nomount:'"

# Check specific patterns
sudo adb shell "su -c 'dmesg | grep -E \"SPOOF_STAT|MATCHED|IS_INJECTED\"'"

# Check registered rules
sudo adb shell "su -c '/data/adb/modules/nomount/bin/nm list'" | head -20

# Compare file identities
sudo adb shell "su -c 'stat /system/etc/audio_effects.conf'"
sudo adb shell "su -c 'stat /data/adb/modules/viperfxmod/system/etc/audio_effects.conf'"
```

### Git Operations
```bash
cd /home/claudetest/gki-build/nomount-vfs-clone

# Check status
git log -5 --oneline
git status

# Amend last commit
git add patches/nomount-core-5.10.patch
git commit --amend --no-edit

# Push with force (after amend)
sudo -u president git push origin main --force
```

---

## Appendix A: Device IDs Reference

| Partition | Device ID (hex) | Device ID (decimal) | Major:Minor |
|-----------|-----------------|---------------------|-------------|
| /system | fd05h | 64773 | 253:5 |
| /data | fd2fh | 64815 | 253:47 |
| /vendor | varies | varies | 253:8 |

---

## Appendix B: Key Functions in nomount-core-5.10.patch

| Function | Line | Purpose |
|----------|------|---------|
| `nomount_normalize_path()` | ~155 | Path normalization |
| `nomount_lookup_by_real_path()` | ~1478 | Reverse hash table lookup |
| `nomount_is_injected_file()` | ~974 | Check if inode is injected |
| `nomount_spoof_stat()` | ~1021 | Inode-based stat spoofing |
| `vfs_dcache_spoof_stat_dev()` | ~1027 | Path-based stat spoofing |
| `nomount_get_partition_dev()` | ~877 | Get device ID for virtual path |

---

## Appendix C: Test File Details

**Target File**: `/system/etc/audio_effects.conf`
- **Module Source**: `/data/adb/modules/viperfxmod/system/etc/audio_effects.conf`
- **Size**: 5817 bytes
- **Inode**: 55971
- **Device**: 253:47 (fd2f) - this is /data partition
- **Expected Device**: 253:5 (fd05) - this is /system partition

The file IS being redirected (content from module), but stat() shows wrong device ID.

---

**END OF HANDOFF DOCUMENT**

*For questions or clarification, review the dmesg logs on the device or examine the nomount-core-5.10.patch file directly.*
