# NoMount + SUSFS Integration: Surgical Refactoring Plan

**Date:** 2026-01-24
**Context:** With SUSFS `add_sus_kstat_redirect` API handling stat spoofing, significant NoMount code becomes dead. This plan documents exactly what to remove, what to keep, and critical gotchas.

---

## Executive Summary

| Metric | Value |
|--------|-------|
| **Total Dead Code** | ~705 lines |
| **Functions to Remove** | 9 |
| **Functions to Keep** | 15+ |
| **Inject Hooks to Remove** | 6 (in inject-stat-hooks.sh) |
| **Critical Dependencies** | 5 (must NOT remove) |

---

## Part 1: Code That CAN Be Removed

### 1.1 Global Variables (All Dead - ~15 lines)

**File:** `nomount-core-5.10.patch` lines 256-272

```c
// Lines 256-269 - Individual partition devices
static dev_t nm_system_dev = 0;
static dev_t nm_vendor_dev = 0;
static dev_t nm_product_dev = 0;
static dev_t nm_odm_dev = 0;
static dev_t nm_system_ext_dev = 0;
static dev_t nm_oem_dev = 0;
static dev_t nm_mi_ext_dev = 0;
static dev_t nm_my_heytap_dev = 0;
static dev_t nm_prism_dev = 0;
static dev_t nm_optics_dev = 0;
static dev_t nm_oem_dlkm_dev = 0;
static dev_t nm_system_dlkm_dev = 0;
static dev_t nm_vendor_dlkm_dev = 0;

// Line 272 - Partition device array
static dev_t nm_partition_devs[NM_PART_COUNT];
```

**Why Dead:** SUSFS uses hash table by inode, not partition device IDs.

---

### 1.2 Core Stat Spoofing Functions (All Dead - ~345 lines)

#### 1.2.1 `nomount_spoof_stat()`
- **Lines:** 1094-1198 (~104 lines)
- **Purpose:** Inode-based stat spoofing at generic_fillattr()
- **Why Dead:** SUSFS handles this via BIT_SUS_KSTAT flag

#### 1.2.2 `vfs_dcache_spoof_stat_dev()`
- **Lines:** 1212-1382 (~170 lines)
- **Purpose:** Path-based stat spoofing at vfs_getattr_nosec()
- **Why Dead:** SUSFS handles this via hash lookup by real inode

#### 1.2.3 `nomount_syscall_spoof_stat()`
- **Lines:** 1395-1464 (~69 lines)
- **Purpose:** Syscall-level spoofing at newfstatat/fstatat64
- **Why Dead:** SUSFS operates at VFS layer, syscall hooks unnecessary

---

### 1.3 Partition Device Functions (All Dead - ~209 lines)

#### 1.3.1 `nomount_init_partition_devs()`
- **Lines:** 799-903 (~104 lines)
- **Purpose:** Discover and cache partition device numbers
- **Why Dead:** SUSFS doesn't need partition discovery

#### 1.3.2 `nomount_get_partition_dev()`
- **Lines:** 906-967 (~62 lines)
- **Purpose:** Prefix-based partition device lookup
- **Why Dead:** Prefix fallback logic obsolete with SUSFS

#### 1.3.3 `nomount_get_partition_dev_for_path()`
- **Lines:** 397-439 (~43 lines)
- **Purpose:** Fast prefix-based lookup variant
- **Why Dead:** Only used by dead stat spoofing functions

---

### 1.4 Helper Functions (Dead - ~74 lines)

#### 1.4.1 `nomount_is_injected_file()` - PARTIAL
- **Lines:** 1050-1092 (~42 lines)
- **Status:** ⚠️ COMPLEX - See Dependencies section
- **Used By:** Stat spoofing AND permission/xattr hooks

#### 1.4.2 `nomount_get_parent_timestamps()`
- **Lines:** 448-463 (~16 lines)
- **Purpose:** Set static 2009-01-01 timestamps
- **Why Dead:** SUSFS handles timestamps in spoofed_metadata

#### 1.4.3 `nomount_lookup_by_real_path()`
- **Lines:** ~1855-1885 (~30 lines)
- **Purpose:** Reverse lookup for stat spoofing
- **Why Dead:** Only called by vfs_dcache_spoof_stat_dev()

---

### 1.5 Struct Fields (Dead)

**Struct:** `nomount_rule` line 3114

```c
dev_t cached_partition_dev;  // DEAD - only used by stat spoofing
```

**References to Remove:**
- Line 593: Initialization to 0
- Line 636: Set to vpath.dentry->d_sb->s_dev
- Line 662: Set to vpath.dentry->d_sb->s_dev
- All reads in stat spoofing functions

---

### 1.6 Constants & Enums (Dead - ~16 lines)

```c
// Line 277
#define STOCK_ANDROID_TIME 1230768000  // Dead - timestamps handled by SUSFS

// Lines 3155-3170
enum nm_partition {
    NM_PART_SYSTEM = 0,
    NM_PART_VENDOR,
    // ... 13 more values
    NM_PART_COUNT
};
```

---

### 1.7 Inject Script Hooks to Remove

**File:** `inject-stat-hooks.sh`

| Injection | Location | Lines | Purpose |
|-----------|----------|-------|---------|
| INJECTION 1 | Include directive | 57-59 | `#include <linux/vfs_dcache.h>` |
| INJECTION 2 | generic_fillattr() | 88-93 | Calls nomount_spoof_stat() |
| INJECTION 3 | vfs_getattr_nosec() | 123-135 | Calls vfs_dcache_spoof_stat_dev() |
| INJECTION 4 | SYSCALL_DEFINE4(newfstatat) | 174-176 | Calls nomount_syscall_spoof_stat() |
| INJECTION 5 | COMPAT_SYSCALL_DEFINE4(newfstatat) | 223-225 | Calls nomount_syscall_spoof_stat() |
| INJECTION 6 | SYSCALL_DEFINE4(fstatat64) | 263-265 | Calls nomount_syscall_spoof_stat() |

**Also in `inject-overlayfs-hooks.sh`:**
- ovl_getattr() hook calling vfs_dcache_spoof_stat_dev()

---

## Part 2: Code That MUST Be Kept

### 2.1 Core Infrastructure (Required by Multiple Subsystems)

| Component | Used By | Lines |
|-----------|---------|-------|
| `nomount_rules_ht` | Readdir, xattr, permission, mount hiding | - |
| `nomount_dirs_ht` | Directory injection only | - |
| `nomount_hidden_mounts_ht` | Mount hiding only | - |
| `nomount_maps_patterns_ht` | Maps hiding only | - |
| `struct nomount_rule` | All subsystems | 3100-3130 |

---

### 2.2 Independent Subsystems (Not Affected by SUSFS)

#### 2.2.1 Directory Injection
- `nomount_inject_dents64()` - lines ~2028-2102
- `nomount_inject_dents()` - 32-bit variant
- **Inject:** `inject-readdir-hooks.sh`

#### 2.2.2 Mount Hiding
- `vfs_dcache_is_mount_hidden()` - lines ~1500-1550
- **Inject:** `inject-procmounts-hooks.sh`

#### 2.2.3 Maps Hiding
- `vfs_dcache_should_hide_map()` - lines ~1550-1620
- **Inject:** `inject-maps-hooks.sh`

#### 2.2.4 xattr Spoofing
- `nomount_get_spoofed_selinux_context()` - lines ~1564-1620
- **Inject:** `inject-xattr-hooks.sh`

#### 2.2.5 VFS Path Redirection
- `nomount_resolve_path()` - lines ~700-780
- `nomount_getname_hook()` - used in namei.c
- **Inject:** `inject-namei-hooks.sh`

#### 2.2.6 Statfs Spoofing
- `nomount_spoof_statfs()` - lines ~1372-1394
- `nm_cached_statfs[]` - partition statfs cache
- **Inject:** `inject-statfs-hooks.sh`

---

### 2.3 Functions That Look Dead But ARE NOT

#### ⚠️ CRITICAL: `nomount_is_injected_file()`

**DO NOT REMOVE** - Used by:
1. `generic_permission()` hook - Allows read/execute on injected files
2. `inode_permission()` hook - Permission bypass
3. `vfs_readlink()` hook - Symlink sanitization
4. `vfs_listxattr()` hook - xattr spoofing
5. `__vfs_getxattr()` hook - SELinux context spoofing

**Stat spoofing was just ONE caller** - removing breaks 5 other features.

---

#### ⚠️ CRITICAL: SUSFS Integration Checks

**Keep ALL `#ifdef CONFIG_KSU_SUSFS` blocks:**

| Location | Purpose |
|----------|---------|
| `nomount_is_traversal_allowed()` lines 978-983 | Blocks /data/adb exposure |
| `nomount_inject_dents64()` lines 2041-2044 | Blocks dir injection for SUSFS targets |
| `nomount_inject_dents()` lines 2117-2120 | Same for 32-bit |

---

#### ⚠️ CRITICAL: Partition Caching for Statfs

**KEEP even though stat spoofing is dead:**
- `nomount_cache_partition_metadata()` - Still needed for statfs caching
- `nm_cached_statfs[]` array - Used by nomount_spoof_statfs()

---

## Part 3: Dependency Graph

```
DEAD CODE TREE (can remove entire subtree):
============================================
fs/stat.c INJECTIONS
├── INJECTION 2: generic_fillattr()
│   └── nomount_is_injected_file() [KEEP - used elsewhere]
│       └── nomount_spoof_stat() [DEAD]
│           ├── nomount_lazy_resolve_real_ino() [KEEP - used by readdir]
│           ├── nomount_get_partition_dev() [DEAD]
│           │   └── nomount_init_partition_devs() [DEAD*]
│           │       └── nm_partition_devs[] [DEAD]
│           └── nomount_get_parent_timestamps() [DEAD]
│
├── INJECTION 3: vfs_getattr_nosec()
│   └── vfs_dcache_spoof_stat_dev() [DEAD]
│       ├── nomount_lookup_by_real_path() [DEAD]
│       └── nomount_get_partition_dev_for_path() [DEAD]
│
└── INJECTIONS 4-6: syscall hooks
    └── nomount_syscall_spoof_stat() [DEAD]


LIVE CODE (must keep):
======================
├── Directory Injection (inject-readdir-hooks.sh)
│   ├── nomount_inject_dents64()
│   └── nomount_inject_dents()
│
├── Mount Hiding (inject-procmounts-hooks.sh)
│   └── vfs_dcache_is_mount_hidden()
│
├── Maps Hiding (inject-maps-hooks.sh)
│   └── vfs_dcache_should_hide_map()
│
├── xattr Spoofing (inject-xattr-hooks.sh)
│   ├── vfs_listxattr() hook
│   └── __vfs_getxattr() hook
│       └── nomount_get_spoofed_selinux_context()
│
├── VFS Path Redirection (inject-namei-hooks.sh)
│   ├── nomount_resolve_path()
│   ├── generic_permission() hook → nomount_is_injected_file() [KEEP]
│   ├── inode_permission() hook → nomount_is_injected_file() [KEEP]
│   └── vfs_readlink() hook → nomount_is_injected_file() [KEEP]
│
└── Statfs Spoofing (inject-statfs-hooks.sh)
    └── nomount_spoof_statfs()
        └── nm_cached_statfs[] [KEEP]

* nomount_init_partition_devs() marked DEAD but verify statfs doesn't need it
```

---

## Part 4: Removal Checklist

### Phase 1: Safe Removals (No Dependencies)

- [ ] Remove `STOCK_ANDROID_TIME` constant (line 277)
- [ ] Remove `enum nm_partition` (lines 3155-3170)
- [ ] Remove `nomount_get_parent_timestamps()` (lines 448-463)
- [ ] Remove `nomount_lookup_by_real_path()` (lines ~1855-1885)
- [ ] Remove `nomount_syscall_spoof_stat()` (lines 1395-1464)
- [ ] Remove INJECTION 4-6 from inject-stat-hooks.sh

### Phase 2: Medium Risk Removals

- [ ] Remove `vfs_dcache_spoof_stat_dev()` (lines 1212-1382)
- [ ] Remove INJECTION 3 from inject-stat-hooks.sh
- [ ] Remove overlayfs hook from inject-overlayfs-hooks.sh
- [ ] Remove `nomount_get_partition_dev_for_path()` (lines 397-439)

### Phase 3: High Risk Removals (Verify Dependencies First)

- [ ] Remove `nomount_spoof_stat()` (lines 1094-1198)
- [ ] Remove INJECTION 2 from inject-stat-hooks.sh
- [ ] Remove `nomount_get_partition_dev()` (lines 906-967)
- [ ] Verify statfs doesn't need `nomount_init_partition_devs()` before removing

### Phase 4: Struct Cleanup

- [ ] Remove `cached_partition_dev` field from `struct nomount_rule`
- [ ] Remove all initializations (lines 593, 636, 662)
- [ ] Remove all EXPORT_SYMBOL for dead functions

### Phase 5: Global Variable Cleanup

- [ ] Remove 14 partition device variables (lines 256-269)
- [ ] Remove `nm_partition_devs[]` array (line 272)
- [ ] Verify `nomount_targets_ht` isn't used elsewhere before removing

---

## Part 5: Testing Checklist

After each phase, verify:

- [ ] Directory injection works (`ls /system/fonts` shows module files)
- [ ] Mount hiding works (`cat /proc/self/mounts` doesn't show module mounts)
- [ ] Maps hiding works (`cat /proc/self/maps` doesn't show /data/adb)
- [ ] xattr spoofing works (`getfattr` shows correct SELinux context)
- [ ] Permission granting works (apps can read injected files)
- [ ] Symlink sanitization works (no /data/adb leaks in symlink resolution)
- [ ] Statfs spoofing works (`statfs` returns correct partition info)
- [ ] SUSFS stat spoofing works (`stat` on redirected files shows spoofed values)

---

## Part 6: Files Summary

| File | Action | Lines Affected |
|------|--------|----------------|
| `nomount-core-5.10.patch` | Major refactor | ~580 lines removed |
| `inject-stat-hooks.sh` | Remove entirely or gut | ~125 lines |
| `inject-overlayfs-hooks.sh` | Remove stat hook only | ~20 lines |
| `inject-statfs-hooks.sh` | Keep as-is | 0 |
| `inject-readdir-hooks.sh` | Keep as-is | 0 |
| `inject-procmounts-hooks.sh` | Keep as-is | 0 |
| `inject-maps-hooks.sh` | Keep as-is | 0 |
| `inject-xattr-hooks.sh` | Keep as-is | 0 |
| `inject-namei-hooks.sh` | Keep as-is | 0 |

---

## Part 7: Gotchas & Warnings

### ⛔ DO NOT Remove These (Even Though They Look Dead)

1. **`nomount_is_injected_file()`** - Used by 5+ non-stat features
2. **`nomount_lazy_resolve_real_ino()`** - Used by readdir injection
3. **`nm_cached_statfs[]`** - Used by statfs spoofing
4. **All `#ifdef CONFIG_KSU_SUSFS` blocks** - SUSFS coordination
5. **`struct nomount_rule`** - Core data structure for all features

### ⚠️ Verify Before Removing

1. **`nomount_init_partition_devs()`** - Check if statfs fallback needs it
2. **`nomount_targets_ht`** - May be used by readdir (reverse lookup)
3. **Include directive injection** - Other inject scripts may need the header

### 🔄 Consider Refactoring Instead of Removing

1. Keep function stubs that return early (safer than removing)
2. Use `#ifdef CONFIG_NOMOUNT_STAT_SPOOFING` to gate dead code
3. This allows easy re-enablement if SUSFS has issues

---

**End of Plan**
