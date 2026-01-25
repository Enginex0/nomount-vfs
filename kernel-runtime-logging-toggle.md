# Runtime Kernel Logging Toggle System

## TL;DR

A sysfs-based toggle that lets you enable/disable verbose kernel logging at runtime without recompiling. When disabled, logging statements have near-zero performance impact (~5 nanoseconds per call). Control via KernelSU module UI or shell commands.

```
Toggle = 0  →  Logs disabled, full device performance
Toggle = 1  →  Logs enabled, debugging mode
```

---

## Table of Contents

1. [Problem Statement](#problem-statement)
2. [Solution Architecture](#solution-architecture)
3. [System Diagrams](#system-diagrams)
4. [Implementation](#implementation)
5. [Macro Behavior Deep Dive](#macro-behavior-deep-dive)
6. [Performance Analysis](#performance-analysis)
7. [KernelSU Module Integration](#kernelsu-module-integration)
8. [Boot-time Parameters](#boot-time-parameters)
9. [SELinux/SEAndroid Configuration](#selinuxseandroid-configuration)
10. [Testing & Validation](#testing--validation)
11. [Troubleshooting](#troubleshooting)
12. [Alternative Approaches](#alternative-approaches)

---

## Problem Statement

### The Situation

You have custom kernel patches with verbose logging for debugging:

```c
pr_info("SUSFS: hiding path %s\n", path);
pr_info("Hook: intercepted call to %s\n", func_name);
pr_info("Feature X: value = %d, state = %d\n", val, state);
// ... hundreds more throughout the kernel
```

### The Problem

These `pr_info()` calls execute **every time**, causing:

| Impact | Description |
|--------|-------------|
| CPU overhead | String formatting (vsnprintf) |
| Memory I/O | Writing to kernel ring buffer |
| Lock contention | Spinlock acquisition for buffer access |
| Buffer overflow | dmesg fills up, losing important logs |
| Device lag | Noticeable performance degradation |

### The Goal

Toggle logging on/off at runtime:
- **OFF by default** → Production performance
- **ON when needed** → Full debugging capability
- **No recompilation** → Instant switching

---

## Solution Architecture

### Core Components

```
┌─────────────────────────────────────────────────────────────────────┐
│                         USERSPACE                                   │
├─────────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────┐         ┌─────────────────────────────┐   │
│  │   KernelSU Module   │         │      ADB Shell / Terminal   │   │
│  │   (Your App UI)     │         │                             │   │
│  │                     │         │  # echo 1 > /sys/kernel/    │   │
│  │  [Toggle Switch]    │         │    my_features/debug        │   │
│  └──────────┬──────────┘         └──────────────┬──────────────┘   │
│             │                                    │                  │
│             │         write "0" or "1"           │                  │
│             └────────────────┬───────────────────┘                  │
│                              │                                      │
├──────────────────────────────┼──────────────────────────────────────┤
│                         KERNEL                                      │
├──────────────────────────────┼──────────────────────────────────────┤
│                              ▼                                      │
│             ┌────────────────────────────────┐                      │
│             │  /sys/kernel/my_features/debug │                      │
│             │  (sysfs node)                  │                      │
│             └───────────────┬────────────────┘                      │
│                             │                                       │
│                             ▼                                       │
│             ┌────────────────────────────────┐                      │
│             │     debug_store() function     │                      │
│             │     parses input, updates:     │                      │
│             └───────────────┬────────────────┘                      │
│                             │                                       │
│                             ▼                                       │
│             ┌────────────────────────────────┐                      │
│             │    my_features_debug = 0|1     │                      │
│             │    (global kernel variable)    │                      │
│             └───────────────┬────────────────┘                      │
│                             │                                       │
│         ┌───────────────────┼───────────────────┐                   │
│         ▼                   ▼                   ▼                   │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐             │
│  │  MY_LOG()   │    │  MY_LOG()   │    │  MY_LOG()   │             │
│  │  in SUSFS   │    │  in Hooks   │    │  in Feature │             │
│  │  patches    │    │  code       │    │  X code     │             │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘             │
│         │                  │                  │                     │
│         └──────────────────┼──────────────────┘                     │
│                            ▼                                        │
│         ┌─────────────────────────────────────────┐                 │
│         │  if (my_features_debug)                 │                 │
│         │      → pr_info() → dmesg               │                 │
│         │  else                                   │                 │
│         │      → nothing (skip entire block)      │                 │
│         └─────────────────────────────────────────┘                 │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## System Diagrams

### Data Flow: Toggle State Change

```
         User taps "Enable Debug"
                    │
                    ▼
    ┌───────────────────────────────┐
    │  App executes shell command:  │
    │  su -c "echo 1 > /sys/..."    │
    └───────────────┬───────────────┘
                    │
                    ▼
    ┌───────────────────────────────┐
    │  Kernel receives write()      │
    │  syscall on sysfs file        │
    └───────────────┬───────────────┘
                    │
                    ▼
    ┌───────────────────────────────┐
    │  debug_store() callback       │
    │  - kstrtoint("1") → val = 1   │
    │  - my_features_debug = 1      │
    └───────────────┬───────────────┘
                    │
                    ▼
    ┌───────────────────────────────┐
    │  Change takes effect          │
    │  IMMEDIATELY                  │
    │  (no delay, no reboot)        │
    └───────────────────────────────┘
```

### Memory Layout

```
┌─────────────────────────────────────────────────────────────────┐
│                      KERNEL VIRTUAL MEMORY                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  .data section (initialized global variables):                   │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Address: 0xFFFFFF80_12345678                           │    │
│  │  Symbol:  my_features_debug                             │    │
│  │  Value:   0x00000000  (debug OFF)                       │    │
│  │       or  0x00000001  (debug ON)                        │    │
│  │       or  0x00000002  (verbose mode)                    │    │
│  └─────────────────────────────────────────────────────────┘    │
│           ▲                                                      │
│           │ READ_ONCE() - atomic read, no caching                │
│           │                                                      │
│  .text section (code):                                           │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  MY_LOG macro expansion:                                │    │
│  │                                                         │    │
│  │  mov  x0, #0xFFFFFF80_12345678  ; load address         │    │
│  │  ldr  w1, [x0]                   ; read value           │    │
│  │  cbz  w1, skip_log               ; if 0, skip           │    │
│  │  ...                             ; pr_info code         │    │
│  │  skip_log:                                              │    │
│  │  ...                             ; continue execution   │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
│  sysfs interface:                                                │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  /sys/kernel/my_features/                               │    │
│  │  └── debug                                              │    │
│  │      ├── read  → debug_show()  → returns current value  │    │
│  │      └── write → debug_store() → updates variable       │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Boot Sequence Timeline

```
     BOOT START
         │
         ▼
┌─────────────────────┐
│ Bootloader          │ ← Can pass my_debug=1 via cmdline
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ Kernel early init   │
│ - parse cmdline     │ ← __setup("my_debug=", ...) runs here
│ - my_features_debug │   if boot param present
│   may be set to 1   │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ core_initcall()     │ ← my_debug_init() creates sysfs node
│ - sysfs node        │
│   /sys/kernel/      │
│   my_features/debug │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ Subsystem init      │ ← Your patches with MY_LOG() start running
│ - SUSFS init        │   They check my_features_debug
│ - Hook registration │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ Userspace starts    │
│ - init / systemd    │
│ - Android zygote    │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ KernelSU module     │ ← Can now read/write sysfs to toggle
│ app launches        │
└─────────────────────┘
```

---

## Implementation

### File Structure

```
kernel/
├── include/
│   └── linux/
│       └── my_debug.h          ← Header with macros and extern
├── kernel/
│   ├── my_debug.c              ← Sysfs node implementation
│   └── Makefile                ← Add my_debug.o
└── [your patches]              ← Convert pr_info → MY_LOG
```

### File 1: Header (`include/linux/my_debug.h`)

```c
/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_MY_DEBUG_H
#define _LINUX_MY_DEBUG_H

#include <linux/kernel.h>
#include <linux/compiler.h>

/*
 * Debug levels:
 * 0 = disabled (production)
 * 1 = standard debug messages
 * 2 = verbose (includes high-frequency logs)
 */
extern int my_features_debug;

/* Feature-specific bitmasks for granular control */
#define MY_DBG_SUSFS    0x0001
#define MY_DBG_HOOKS    0x0002
#define MY_DBG_FS       0x0004
#define MY_DBG_NET      0x0008
#define MY_DBG_ALL      0xFFFF

extern int my_features_debug_mask;

/* Standard debug log - level 1+ */
#define MY_LOG(fmt, ...) \
    do { \
        if (unlikely(READ_ONCE(my_features_debug) >= 1)) \
            pr_info("[MY_FEATURE] " fmt, ##__VA_ARGS__); \
    } while (0)

/* Verbose debug log - level 2+ */
#define MY_LOG_V(fmt, ...) \
    do { \
        if (unlikely(READ_ONCE(my_features_debug) >= 2)) \
            pr_info("[MY_FEATURE:V] " fmt, ##__VA_ARGS__); \
    } while (0)

/* Feature-specific logs using bitmask */
#define MY_LOG_SUSFS(fmt, ...) \
    do { \
        if (unlikely(READ_ONCE(my_features_debug_mask) & MY_DBG_SUSFS)) \
            pr_info("[SUSFS] " fmt, ##__VA_ARGS__); \
    } while (0)

#define MY_LOG_HOOKS(fmt, ...) \
    do { \
        if (unlikely(READ_ONCE(my_features_debug_mask) & MY_DBG_HOOKS)) \
            pr_info("[HOOKS] " fmt, ##__VA_ARGS__); \
    } while (0)

/* Rate-limited variant for high-frequency paths */
#define MY_LOG_RATELIMITED(fmt, ...) \
    do { \
        if (unlikely(READ_ONCE(my_features_debug) >= 1)) { \
            static DEFINE_RATELIMIT_STATE(_rs, HZ, 10); \
            if (__ratelimit(&_rs)) \
                pr_info("[MY_FEATURE:RL] " fmt, ##__VA_ARGS__); \
        } \
    } while (0)

#endif /* _LINUX_MY_DEBUG_H */
```

### File 2: Implementation (`kernel/my_debug.c`)

```c
// SPDX-License-Identifier: GPL-2.0
/*
 * Runtime debug toggle for custom kernel features
 * Provides sysfs interface at /sys/kernel/my_features/
 */

#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/init.h>
#include <linux/string.h>
#include <linux/my_debug.h>

/* Global debug level: 0=off, 1=normal, 2=verbose */
int my_features_debug = 0;
EXPORT_SYMBOL(my_features_debug);

/* Bitmask for per-feature debug control */
int my_features_debug_mask = 0;
EXPORT_SYMBOL(my_features_debug_mask);

static struct kobject *my_features_kobj;

/* ─────────────────────────────────────────────────────────────────
 * Sysfs attribute: debug (read/write)
 * Controls global debug level
 * ───────────────────────────────────────────────────────────────── */

static ssize_t debug_show(struct kobject *kobj,
                          struct kobj_attribute *attr,
                          char *buf)
{
    return sysfs_emit(buf, "%d\n", my_features_debug);
}

static ssize_t debug_store(struct kobject *kobj,
                           struct kobj_attribute *attr,
                           const char *buf,
                           size_t count)
{
    int val;
    int ret;

    ret = kstrtoint(buf, 10, &val);
    if (ret < 0)
        return ret;

    if (val < 0 || val > 2)
        return -EINVAL;

    WRITE_ONCE(my_features_debug, val);

    return count;
}

static struct kobj_attribute debug_attr =
    __ATTR(debug, 0644, debug_show, debug_store);

/* ─────────────────────────────────────────────────────────────────
 * Sysfs attribute: debug_mask (read/write)
 * Controls per-feature debug via bitmask
 * ───────────────────────────────────────────────────────────────── */

static ssize_t debug_mask_show(struct kobject *kobj,
                               struct kobj_attribute *attr,
                               char *buf)
{
    return sysfs_emit(buf, "0x%04x\n", my_features_debug_mask);
}

static ssize_t debug_mask_store(struct kobject *kobj,
                                struct kobj_attribute *attr,
                                const char *buf,
                                size_t count)
{
    int val;
    int ret;

    ret = kstrtoint(buf, 0, &val);  /* 0 = auto-detect base (hex/dec) */
    if (ret < 0)
        return ret;

    WRITE_ONCE(my_features_debug_mask, val);

    return count;
}

static struct kobj_attribute debug_mask_attr =
    __ATTR(debug_mask, 0644, debug_mask_show, debug_mask_store);

/* ─────────────────────────────────────────────────────────────────
 * Attribute group
 * ───────────────────────────────────────────────────────────────── */

static struct attribute *my_features_attrs[] = {
    &debug_attr.attr,
    &debug_mask_attr.attr,
    NULL,
};

static struct attribute_group my_features_attr_group = {
    .attrs = my_features_attrs,
};

/* ─────────────────────────────────────────────────────────────────
 * Boot parameter parsing
 * Usage: add "my_debug=1" to kernel cmdline
 * ───────────────────────────────────────────────────────────────── */

static int __init my_debug_setup(char *str)
{
    int val;

    if (kstrtoint(str, 10, &val) == 0)
        my_features_debug = val;

    return 1;
}
__setup("my_debug=", my_debug_setup);

static int __init my_debug_mask_setup(char *str)
{
    int val;

    if (kstrtoint(str, 0, &val) == 0)
        my_features_debug_mask = val;

    return 1;
}
__setup("my_debug_mask=", my_debug_mask_setup);

/* ─────────────────────────────────────────────────────────────────
 * Initialization
 * ───────────────────────────────────────────────────────────────── */

static int __init my_debug_init(void)
{
    int ret;

    my_features_kobj = kobject_create_and_add("my_features", kernel_kobj);
    if (!my_features_kobj)
        return -ENOMEM;

    ret = sysfs_create_group(my_features_kobj, &my_features_attr_group);
    if (ret) {
        kobject_put(my_features_kobj);
        return ret;
    }

    return 0;
}
core_initcall(my_debug_init);
```

### File 3: Makefile Addition (`kernel/Makefile`)

Add this line to `kernel/Makefile`:

```makefile
obj-y += my_debug.o
```

### File 4: Example Patch Conversion

**Before (always logs):**

```c
// In fs/susfs/susfs.c
int susfs_hide_path(const char *path)
{
    pr_info("SUSFS: attempting to hide path: %s\n", path);

    // ... implementation ...

    pr_info("SUSFS: successfully hidden: %s\n", path);
    return 0;
}
```

**After (controllable):**

```c
// In fs/susfs/susfs.c
#include <linux/my_debug.h>

int susfs_hide_path(const char *path)
{
    MY_LOG_SUSFS("attempting to hide path: %s\n", path);

    // ... implementation ...

    MY_LOG_SUSFS("successfully hidden: %s\n", path);
    return 0;
}
```

---

## Macro Behavior Deep Dive

### Expansion Example

When you write:

```c
MY_LOG("hiding path %s\n", path);
```

The preprocessor expands it to:

```c
do {
    if (unlikely(READ_ONCE(my_features_debug) >= 1))
        pr_info("[MY_FEATURE] " "hiding path %s\n", path);
} while (0)
```

### Execution Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    MY_LOG() EXECUTION                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Entry: MY_LOG("value = %d", x)                                  │
│                    │                                             │
│                    ▼                                             │
│  ┌─────────────────────────────────────┐                        │
│  │ READ_ONCE(my_features_debug)        │                        │
│  │ - Atomic read from memory           │                        │
│  │ - Prevents compiler caching         │                        │
│  │ - Cost: ~1-3 CPU cycles             │                        │
│  └─────────────────┬───────────────────┘                        │
│                    │                                             │
│                    ▼                                             │
│  ┌─────────────────────────────────────┐                        │
│  │ unlikely() hint + comparison >= 1   │                        │
│  │ - Tells CPU: "usually false"        │                        │
│  │ - Branch predictor optimizes        │                        │
│  │ - Cost: ~1 cycle                    │                        │
│  └─────────────────┬───────────────────┘                        │
│                    │                                             │
│         ┌─────────┴─────────┐                                   │
│         │                   │                                    │
│    value = 0           value >= 1                                │
│         │                   │                                    │
│         ▼                   ▼                                    │
│  ┌─────────────┐    ┌─────────────────────────────────┐         │
│  │ SKIP BLOCK  │    │ EXECUTE pr_info():              │         │
│  │             │    │ - Format string (vsnprintf)     │         │
│  │ Cost: ~0    │    │ - Acquire ring buffer lock      │         │
│  │ cycles      │    │ - Write to buffer               │         │
│  │ (predicted) │    │ - Release lock                  │         │
│  │             │    │ - Cost: ~500-2000+ cycles       │         │
│  └─────────────┘    └─────────────────────────────────┘         │
│         │                   │                                    │
│         └─────────┬─────────┘                                   │
│                   │                                              │
│                   ▼                                              │
│            Continue execution                                    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Argument Evaluation Behavior

```
┌─────────────────────────────────────────────────────────────────┐
│  CRITICAL: Arguments are NOT evaluated when debug = 0           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Code:                                                           │
│    MY_LOG("result = %s", expensive_function());                  │
│                                                                  │
│  When debug = 0:                                                 │
│    if (0)                      ← false, entire block skipped     │
│        pr_info(..., expensive_function());                       │
│                      │                                           │
│                      └── NEVER CALLED                            │
│                                                                  │
│  When debug = 1:                                                 │
│    if (1)                      ← true, block executes            │
│        pr_info(..., expensive_function());                       │
│                      │                                           │
│                      └── CALLED, result used                     │
│                                                                  │
├─────────────────────────────────────────────────────────────────┤
│  This is a key benefit: expensive argument computation is       │
│  completely avoided when logging is disabled.                    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Performance Analysis

### Cost Comparison Table

| Operation | Cycles | Time (@ 2GHz) | When |
|-----------|--------|---------------|------|
| READ_ONCE() | 1-3 | ~1 ns | Always |
| Compare + Branch | 1-2 | ~1 ns | Always |
| **Total (debug=0)** | **2-5** | **~2 ns** | **Per MY_LOG call** |
| vsnprintf formatting | 200-500 | 100-250 ns | debug >= 1 |
| Spinlock acquire | 50-200 | 25-100 ns | debug >= 1 |
| Ring buffer write | 100-300 | 50-150 ns | debug >= 1 |
| Spinlock release | 20-50 | 10-25 ns | debug >= 1 |
| **Total (debug=1)** | **500-2000+** | **250-1000+ ns** | **Per MY_LOG call** |

### Performance Ratio

```
┌─────────────────────────────────────────────────────────────────┐
│                    PERFORMANCE COMPARISON                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Scenario: 10,000 MY_LOG() calls per second                      │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ debug = 0 (OFF):                                            ││
│  │                                                             ││
│  │   10,000 × 2 ns = 20,000 ns = 0.02 ms                       ││
│  │                                                             ││
│  │   ████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  (negligible)  ││
│  └─────────────────────────────────────────────────────────────┘│
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ debug = 1 (ON):                                             ││
│  │                                                             ││
│  │   10,000 × 500 ns = 5,000,000 ns = 5 ms                     ││
│  │                                                             ││
│  │   ████████████████████████████████████████████  (noticeable)││
│  └─────────────────────────────────────────────────────────────┘│
│                                                                  │
│  Ratio: 5 ms / 0.02 ms = 250x difference                         │
│                                                                  │
│  In practice, the difference can be 1000x+ due to:               │
│  - I/O blocking                                                  │
│  - Lock contention with other kernel subsystems                  │
│  - Console driver overhead                                       │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Why unlikely() Matters

```
┌─────────────────────────────────────────────────────────────────┐
│                    BRANCH PREDICTION                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  CPU Pipeline (simplified):                                      │
│                                                                  │
│    Fetch → Decode → Execute → Memory → Writeback                 │
│      │                                                           │
│      └── CPU predicts branch outcome and speculatively           │
│          fetches the predicted path                              │
│                                                                  │
│  Without unlikely():                                             │
│    CPU may predict either path (50/50)                           │
│    Misprediction = pipeline flush = ~15-20 cycle penalty         │
│                                                                  │
│  With unlikely():                                                │
│    Compiler hints to CPU: "predict false"                        │
│    CPU almost always predicts correctly                          │
│    Branch cost drops to ~0-1 cycles                              │
│                                                                  │
│  Impact over 10,000 calls:                                       │
│    Without: ~5,000 mispredictions × 15 cycles = 75,000 cycles   │
│    With:    ~10 mispredictions × 15 cycles = 150 cycles         │
│                                                                  │
│  Savings: ~500x fewer misprediction penalties                    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## KernelSU Module Integration

### Kotlin Implementation

```kotlin
package com.example.kernelfeatures

import android.content.Context
import android.content.SharedPreferences
import java.io.DataOutputStream

object DebugToggle {

    private const val SYSFS_DEBUG = "/sys/kernel/my_features/debug"
    private const val SYSFS_MASK = "/sys/kernel/my_features/debug_mask"
    private const val PREFS_NAME = "kernel_debug_prefs"

    // Debug mask constants (match kernel header)
    const val DBG_SUSFS = 0x0001
    const val DBG_HOOKS = 0x0002
    const val DBG_FS    = 0x0004
    const val DBG_NET   = 0x0008
    const val DBG_ALL   = 0xFFFF

    /**
     * Check if sysfs interface exists
     */
    fun isSupported(): Boolean {
        return try {
            java.io.File(SYSFS_DEBUG).exists()
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Get current debug level from kernel
     */
    fun getDebugLevel(): Int {
        return try {
            val process = Runtime.getRuntime().exec(arrayOf("su", "-c", "cat $SYSFS_DEBUG"))
            val result = process.inputStream.bufferedReader().readText().trim()
            process.waitFor()
            result.toIntOrNull() ?: 0
        } catch (e: Exception) {
            0
        }
    }

    /**
     * Set debug level in kernel
     */
    fun setDebugLevel(level: Int): Boolean {
        return try {
            val process = Runtime.getRuntime().exec(arrayOf("su", "-c", "echo $level > $SYSFS_DEBUG"))
            process.waitFor()
            process.exitValue() == 0
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Get current debug mask from kernel
     */
    fun getDebugMask(): Int {
        return try {
            val process = Runtime.getRuntime().exec(arrayOf("su", "-c", "cat $SYSFS_MASK"))
            val result = process.inputStream.bufferedReader().readText().trim()
            process.waitFor()
            // Parse hex (0x0001) or decimal
            if (result.startsWith("0x")) {
                result.substring(2).toIntOrNull(16) ?: 0
            } else {
                result.toIntOrNull() ?: 0
            }
        } catch (e: Exception) {
            0
        }
    }

    /**
     * Set debug mask in kernel
     */
    fun setDebugMask(mask: Int): Boolean {
        return try {
            val process = Runtime.getRuntime().exec(
                arrayOf("su", "-c", "echo 0x${mask.toString(16)} > $SYSFS_MASK")
            )
            process.waitFor()
            process.exitValue() == 0
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Toggle a specific feature's debug logging
     */
    fun toggleFeature(feature: Int, enabled: Boolean): Boolean {
        val currentMask = getDebugMask()
        val newMask = if (enabled) {
            currentMask or feature
        } else {
            currentMask and feature.inv()
        }
        return setDebugMask(newMask)
    }

    /**
     * Enable all debug logging
     */
    fun enableAll(): Boolean {
        return setDebugLevel(2) && setDebugMask(DBG_ALL)
    }

    /**
     * Disable all debug logging
     */
    fun disableAll(): Boolean {
        return setDebugLevel(0) && setDebugMask(0)
    }
}
```

### Jetpack Compose UI Example

```kotlin
@Composable
fun DebugSettingsScreen() {
    var debugLevel by remember { mutableStateOf(0) }
    var susfsEnabled by remember { mutableStateOf(false) }
    var hooksEnabled by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        // Sync state from kernel on launch
        debugLevel = DebugToggle.getDebugLevel()
        val mask = DebugToggle.getDebugMask()
        susfsEnabled = (mask and DebugToggle.DBG_SUSFS) != 0
        hooksEnabled = (mask and DebugToggle.DBG_HOOKS) != 0
    }

    Column(modifier = Modifier.padding(16.dp)) {
        Text("Debug Settings", style = MaterialTheme.typography.headlineMedium)

        Spacer(modifier = Modifier.height(16.dp))

        // Master toggle
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("Enable Debug Logging")
            Switch(
                checked = debugLevel > 0,
                onCheckedChange = { enabled ->
                    val newLevel = if (enabled) 1 else 0
                    if (DebugToggle.setDebugLevel(newLevel)) {
                        debugLevel = newLevel
                    }
                }
            )
        }

        // Verbose mode
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("Verbose Mode")
            Switch(
                checked = debugLevel >= 2,
                enabled = debugLevel > 0,
                onCheckedChange = { verbose ->
                    val newLevel = if (verbose) 2 else 1
                    if (DebugToggle.setDebugLevel(newLevel)) {
                        debugLevel = newLevel
                    }
                }
            )
        }

        Divider(modifier = Modifier.padding(vertical = 16.dp))

        Text("Feature-Specific Logging", style = MaterialTheme.typography.titleMedium)

        // SUSFS toggle
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("SUSFS Logs")
            Switch(
                checked = susfsEnabled,
                onCheckedChange = { enabled ->
                    if (DebugToggle.toggleFeature(DebugToggle.DBG_SUSFS, enabled)) {
                        susfsEnabled = enabled
                    }
                }
            )
        }

        // Hooks toggle
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("Hook Logs")
            Switch(
                checked = hooksEnabled,
                onCheckedChange = { enabled ->
                    if (DebugToggle.toggleFeature(DebugToggle.DBG_HOOKS, enabled)) {
                        hooksEnabled = enabled
                    }
                }
            )
        }
    }
}
```

---

## Boot-time Parameters

### Adding to Kernel Cmdline

The implementation includes boot parameter parsing. To enable debug at boot:

**Method 1: Via bootloader (device-specific)**

```
# Example for some devices via fastboot
fastboot oem set-cmdline "... my_debug=1 my_debug_mask=0xFFFF ..."
```

**Method 2: Via boot image modification**

Unpack boot.img, edit cmdline, repack.

**Method 3: Via Magisk/KernelSU boot scripts**

Create `/data/adb/post-fs-data.d/enable_debug.sh`:

```bash
#!/system/bin/sh
# Enable debug early in boot
echo 1 > /sys/kernel/my_features/debug
```

### Parameter Reference

| Parameter | Values | Description |
|-----------|--------|-------------|
| `my_debug=N` | 0, 1, 2 | Debug level (0=off, 1=normal, 2=verbose) |
| `my_debug_mask=N` | hex or decimal | Bitmask for per-feature control |

---

## SELinux/SEAndroid Configuration

### The Problem

By default, SELinux may block userspace from writing to your sysfs node, even with root:

```
avc: denied { write } for ... scontext=u:r:su:s0 tcontext=u:object_r:sysfs:s0
```

### Solution: Custom SEPolicy

Add to your KernelSU module's `sepolicy.rule`:

```
# Allow su domain to read/write our debug sysfs nodes
allow su sysfs:file { read write open getattr };

# Or more specifically (if you create custom context):
# type my_features_sysfs, sysfs_type, fs_type;
# allow su my_features_sysfs:file { read write open getattr };
```

### Alternative: Label the sysfs node

In kernel code, you can set the security context:

```c
// In my_debug_init(), after creating the kobject:
// Note: This is device-specific and may require additional kernel config
#ifdef CONFIG_SECURITY_SELINUX
    // Set appropriate SELinux context
    // This varies by Android version and device
#endif
```

### Quick Testing (Permissive Mode)

For testing only, temporarily set SELinux to permissive:

```bash
su -c setenforce 0
```

Then test your sysfs toggle. Remember to develop proper sepolicy for production.

---

## Testing & Validation

### Test Procedure

```bash
# 1. Verify sysfs node exists
adb shell su -c "ls -la /sys/kernel/my_features/"
# Expected: debug  debug_mask

# 2. Check initial state (should be 0)
adb shell su -c "cat /sys/kernel/my_features/debug"
# Expected: 0

# 3. Verify dmesg is quiet for your features
adb shell dmesg | grep -E "\[MY_FEATURE\]|\[SUSFS\]|\[HOOKS\]"
# Expected: (empty or minimal)

# 4. Enable debug logging
adb shell su -c "echo 1 > /sys/kernel/my_features/debug"

# 5. Trigger your features (e.g., hide a path, trigger a hook)
# ... do something that would generate logs ...

# 6. Verify logs appear
adb shell dmesg | grep -E "\[MY_FEATURE\]|\[SUSFS\]" | tail -20
# Expected: Your debug messages

# 7. Disable logging
adb shell su -c "echo 0 > /sys/kernel/my_features/debug"

# 8. Trigger features again
# ... do something ...

# 9. Verify no new logs (check timestamps)
adb shell dmesg | grep -E "\[MY_FEATURE\]|\[SUSFS\]" | tail -5
# Expected: Same logs as step 6, no new ones

# 10. Test per-feature mask
adb shell su -c "echo 0 > /sys/kernel/my_features/debug"
adb shell su -c "echo 0x0001 > /sys/kernel/my_features/debug_mask"  # SUSFS only
# Verify only SUSFS logs appear, not HOOKS
```

### Verification Checklist

```
┌─────────────────────────────────────────────────────────────────┐
│                    VALIDATION CHECKLIST                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  □ Sysfs nodes exist at /sys/kernel/my_features/                │
│  □ Nodes have correct permissions (0644)                        │
│  □ Reading returns current value                                 │
│  □ Writing updates the value                                     │
│  □ debug=0 produces no feature logs                             │
│  □ debug=1 produces normal logs                                 │
│  □ debug=2 produces verbose logs                                │
│  □ debug_mask controls per-feature logging                      │
│  □ Boot parameter works (if needed)                             │
│  □ KernelSU module UI correctly toggles state                   │
│  □ State persists until changed (survives app close)            │
│  □ State resets to 0 on reboot (as expected)                    │
│  □ No SELinux denials in production                             │
│  □ Device performance normal when debug=0                        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Troubleshooting

### Common Issues

| Symptom | Cause | Solution |
|---------|-------|----------|
| "Permission denied" when writing | SELinux blocking | Add sepolicy rule or test with `setenforce 0` |
| "No such file or directory" | sysfs not created | Check `my_debug_init()` runs, verify `core_initcall` |
| Logs still appear when debug=0 | Missed conversions | Search for remaining `pr_info`, convert to `MY_LOG` |
| Toggle has no effect | Symbol not exported | Check `EXPORT_SYMBOL(my_features_debug)` |
| Boot param not working | Parse order | Use `early_param()` instead of `__setup()` |
| App can't read current value | Read permission | Verify file is 0644 not 0200 |
| Kernel panic on toggle | NULL pointer | Check `kobject_create_and_add` succeeded |

### Debug Commands

```bash
# Check if module symbols are exported
adb shell su -c "cat /proc/kallsyms | grep my_features_debug"

# Check sysfs permissions
adb shell su -c "ls -laZ /sys/kernel/my_features/"

# Check SELinux denials
adb shell su -c "dmesg | grep avc | grep my_features"

# Monitor dmesg in real-time
adb shell su -c "dmesg -w" | grep "\[MY_FEATURE\]"

# Check kernel cmdline
adb shell su -c "cat /proc/cmdline"
```

---

## Alternative Approaches

### 1. Dynamic Debug (Built-in)

If `CONFIG_DYNAMIC_DEBUG=y` in your kernel:

```bash
# Enable debug for specific file
echo "file susfs.c +p" > /sys/kernel/debug/dynamic_debug/control

# Disable
echo "file susfs.c -p" > /sys/kernel/debug/dynamic_debug/control
```

**Pros:** Built into kernel, no code changes needed
**Cons:** Only works with `pr_debug()`, requires debugfs mounted

### 2. Kernel Log Level

```bash
# Suppress everything below KERN_WARNING
echo 4 > /proc/sys/kernel/printk

# Restore normal
echo 7 > /proc/sys/kernel/printk
```

**Pros:** No code changes, immediate effect
**Cons:** Affects ALL kernel logging, not selective

### 3. Tracepoints

```c
TRACE_EVENT(my_feature_event,
    TP_PROTO(const char *msg),
    TP_ARGS(msg),
    ...
);
```

**Pros:** Low overhead, sophisticated tooling (trace-cmd, perfetto)
**Cons:** Complex to implement, overkill for simple debugging

### 4. Compile-time Removal

```c
#ifdef CONFIG_MY_DEBUG
#define MY_LOG pr_info
#else
#define MY_LOG(...) do {} while(0)
#endif
```

**Pros:** Zero runtime overhead when disabled
**Cons:** Requires recompile to toggle

---

## Summary

```
┌─────────────────────────────────────────────────────────────────┐
│                         KEY TAKEAWAYS                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. CREATE: Add my_debug.h header + my_debug.c sysfs handler    │
│                                                                  │
│  2. CONVERT: Replace pr_info() → MY_LOG() in your patches       │
│                                                                  │
│  3. CONTROL: Write 0/1/2 to /sys/kernel/my_features/debug       │
│                                                                  │
│  4. INTEGRATE: Update KernelSU module to toggle via UI          │
│                                                                  │
│  Result:                                                         │
│    • debug=0 → Negligible overhead (~2ns per call)               │
│    • debug=1 → Full logging for debugging                        │
│    • No recompilation needed                                     │
│    • Instant toggle via app or shell                             │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

*Document generated for kernel feature debugging with runtime toggle support.*
