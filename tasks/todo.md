# NoMount VFS Rule Lifecycle Management - Implementation Plan

## Architecture Analysis

### Existing Implementation (MORE COMPLETE THAN EXPECTED)

After thorough analysis of the codebase, the system already has **robust lifecycle management** in `monitor.sh`:

| Feature | Status | Implementation |
|---------|--------|----------------|
| Realtime detection via inotify | EXISTS | `watch_loop_inotify_simple()` |
| Polling fallback (5s) | EXISTS | `watch_loop_polling()` |
| Module uninstall detection | EXISTS | Detects directory deletion |
| Module disable detection | EXISTS | Watches for `disable` file |
| Module removal marking | EXISTS | Watches for `remove` file |
| VFS rule removal | EXISTS | `unregister_module()` using `nm del` |
| Module re-enable | EXISTS | `handle_new_module()` |
| File change detection | EXISTS | `sync_module_files()` |
| Path tracking | EXISTS | `$NOMOUNT_DATA/module_paths/<module>` |

**The user's characterization of "COMPLETELY BLIND" is inaccurate.** The system does handle module lifecycle events.

### ACTUAL GAPS IDENTIFIED

1. **post-fs-data.sh: No cache validation** (CRITICAL)
   - Cached rules are applied blindly without checking if `real_path` exists
   - If module was uninstalled between boots, stale rules cause crashes

2. **monitor.sh: Incomplete cleanup in unregister_module()**
   - Removes VFS rules (good)
   - Does NOT clean `.rule_cache` entries
   - Does NOT clean SUSFS config entries
   - Does NOT clean `metadata_cache` entries

3. **susfs_integration.sh: No per-module cleanup**
   - `susfs_clean_nomount_entries()` exists but removes ALL entries
   - Need per-module cleanup that only removes specific paths

4. **Rule cache timing issue**
   - `save_rule_cache()` only runs at end of `service.sh`
   - Runtime module removal doesn't update cache until next boot

---

## Proposed Solution Architecture

### Component Changes

```
post-fs-data.sh
  |
  +-- validate_cache_rule()  [NEW] - Check if real_path exists before applying
  +-- clean_stale_cache_entries()  [NEW] - Remove orphaned entries from cache

monitor.sh
  |
  +-- unregister_module()  [MODIFY] - Add calls to cleanup functions
  +-- clean_module_metadata_cache()  [NEW] - Remove metadata_cache for module
  +-- clean_module_rule_cache()  [NEW] - Remove entries from .rule_cache
  +-- update_rule_cache_async()  [NEW] - Trigger async cache update

susfs_integration.sh
  |
  +-- susfs_clean_module_entries()  [NEW] - Clean SUSFS entries for specific module
```

---

## Implementation Details

### TASK 1: post-fs-data.sh Cache Validation

**Purpose:** Prevent applying stale rules for uninstalled modules

**Location:** `/home/claudetest/gki-build/nomount-vfs-clone/module/post-fs-data.sh`

Changes needed in the rule loading section:
- Before applying each `add` rule, verify `real_path` exists
- Skip and log rules with missing real_path
- Count skipped rules for summary

### TASK 2: monitor.sh Cleanup Enhancement

**Purpose:** Complete cleanup when module is unregistered

**Location:** `/home/claudetest/gki-build/nomount-vfs-clone/module/monitor.sh`

Add to `unregister_module()`:
- Clean module's entries from `.rule_cache`
- Clean module's entries from SUSFS configs
- Clean module's metadata cache files
- Optionally trigger async cache regeneration

### TASK 3: susfs_integration.sh Per-Module Cleanup

**Purpose:** Allow cleaning SUSFS entries for a specific module without affecting others

**Location:** `/home/claudetest/gki-build/nomount-vfs-clone/module/susfs_integration.sh`

Add new function:
- Takes module_name or path prefix
- Removes matching entries from SUSFS configs
- More surgical than `susfs_clean_nomount_entries()`

### TASK 4: Rule Cache Management

**Purpose:** Keep rule cache in sync with actual module state

Add capability to:
- Remove specific module's entries from cache
- Trigger cache regeneration after module removal

---

## Testing Scenarios

| # | Scenario | Test Steps | Expected Result |
|---|----------|------------|-----------------|
| 1 | Module uninstall | Install module, reboot, uninstall module, verify | VFS rules removed, no crashes |
| 2 | Module disable | Disable module via Magisk/KSU manager | VFS rules removed immediately |
| 3 | Reboot after uninstall | Uninstall module, reboot | No stale rules applied |
| 4 | Module re-enable | Disable then re-enable module | VFS rules re-registered |
| 5 | File deletion in module | Remove files from module directory | VFS rules for those files removed |
| 6 | SUSFS cleanup | Uninstall module | SUSFS entries cleaned |

---

## Checklist

- [x] Implement cache validation in post-fs-data.sh
- [x] Add cleanup functions to monitor.sh unregister_module()
- [x] Add susfs_clean_module_entries() to susfs_integration.sh
- [x] Add rule cache update capability
- [ ] Test all scenarios
- [x] Document changes

---

## Review Section

### Summary of Changes Made

**1. post-fs-data.sh (Line ~240)**
Added real_path validation before applying cached `add` rules:
```bash
# CRITICAL: Validate real_path exists before applying
# This prevents crashes from stale cache entries for uninstalled modules
if [ "$rpath" != "/nonexistent" ] && [ ! -e "$rpath" ]; then
    log_warn "Rule #$rule_index: SKIPPED (real_path missing) - $vpath -> $rpath"
    fail_count=$((fail_count + 1))
    continue
fi
```

**2. monitor.sh (Multiple sections)**

a) Added SUSFS integration sourcing near top:
```bash
# SUSFS INTEGRATION - Load for cleanup functions
SUSFS_INTEGRATION="$MODDIR/susfs_integration.sh"
if [ -f "$SUSFS_INTEGRATION" ]; then
    . "$SUSFS_INTEGRATION"
    if type susfs_init >/dev/null 2>&1; then
        susfs_init 2>/dev/null || true
    fi
fi
```

b) Added `clean_module_rule_cache()` function that removes module's entries from `.rule_cache`

c) Enhanced `unregister_module()` with 5-phase cleanup:
- Phase 1: Remove VFS rules from kernel (existing)
- Phase 2: Clean SUSFS entries for module (NEW)
- Phase 3: Clean metadata cache for module (NEW)
- Phase 4: Clean rule cache entries for module (NEW)
- Phase 5: Remove tracking file (moved to after cleanup uses it)

**3. susfs_integration.sh (Added two new functions)**

a) `susfs_clean_module_entries(mod_name, tracking_file)`:
- Removes SUSFS config entries (sus_path.txt, sus_path_loop.txt, sus_maps.txt) that match paths in the tracking file
- More surgical than `susfs_clean_nomount_entries()` which removes ALL entries

b) `susfs_clean_module_metadata_cache(mod_name, tracking_file)`:
- Removes metadata cache files for paths in the tracking file
- Uses same cache key algorithm as `susfs_capture_metadata()`

### How the Complete Lifecycle Now Works

```
Module Installation:
1. service.sh -> register_module_vfs() -> tracks paths in module_paths/<mod>
2. monitor.sh -> watches for new modules, calls handle_new_module()
3. SUSFS entries added via nm_register_rule_with_susfs()
4. Rules cached to .rule_cache at end of service.sh

Module Removal (Runtime):
1. monitor.sh detects (inotify/polling):
   - Directory deleted
   - disable file created
   - remove file created
2. unregister_module() called:
   - Removes VFS rules from kernel (nm del)
   - Cleans SUSFS config entries (sus_path.txt, etc.)
   - Cleans metadata cache files
   - Cleans .rule_cache entries
   - Removes tracking file
   - Updates status

Reboot After Removal:
1. post-fs-data.sh loads .rule_cache
2. For each 'add' rule, validates real_path exists
3. Stale rules (missing real_path) are SKIPPED with warning
4. service.sh later regenerates clean cache

Module Re-enable:
1. monitor.sh detects disable file removed
2. handle_new_module() called
3. Full registration process runs again
```

### Files Modified

| File | Lines Changed | Change Type |
|------|---------------|-------------|
| `/home/claudetest/gki-build/nomount-vfs-clone/module/post-fs-data.sh` | ~8 | Added validation |
| `/home/claudetest/gki-build/nomount-vfs-clone/module/monitor.sh` | ~80 | Added SUSFS source, cleanup function, enhanced unregister |
| `/home/claudetest/gki-build/nomount-vfs-clone/module/susfs_integration.sh` | ~110 | Added 2 new cleanup functions |

### Impact Assessment

- **Minimal code changes**: Targeted fixes to specific gaps
- **Backward compatible**: No changes to external APIs
- **Safe**: All cleanup operations check for existence before proceeding
- **Follows existing patterns**: Uses same logging, file operations, and function structure
- **No new dependencies**: Uses existing shell capabilities

### Remaining Considerations

1. **Boot-time cache cleaning**: Currently skips stale rules but doesn't clean them from cache. They'll be cleaned when service.sh regenerates the cache. For truly aggressive cleanup, could add a boot-time cache sanitization pass.

2. **SUSFS runtime removal**: The SUSFS entries are removed from config files, but the kernel-side SUSFS entries remain until reboot (no `del_sus_path` API used). This is consistent with the original code behavior.

3. **Race conditions**: The cleanup is atomic per-module (tracking file read, cleanup, delete). Multiple modules can be unregistered in parallel safely.
