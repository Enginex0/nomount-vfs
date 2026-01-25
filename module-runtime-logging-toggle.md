# Runtime Debug Logging for Xposed/LSPosed Modules & Android Apps

## A Complete Implementation Guide with Material 3 UI

---

## Table of Contents

1. [The Problem](#the-problem)
2. [The Solution](#the-solution)
3. [Architecture Overview](#architecture-overview)
4. [Part 1: Xposed Module Logger](#part-1-xposed-module-logger)
5. [Part 2: Java/Kotlin Interop](#part-2-javakotlin-interop)
6. [Part 3: Frontend App Logger](#part-3-frontend-app-logger)
7. [Part 4: Material 3 UI](#part-4-material-3-ui)
8. [Part 5: Integration](#part-5-integration)
9. [Part 6: Usage Examples](#part-6-usage-examples)
10. [Edge Cases & Gotchas](#edge-cases--gotchas)
11. [Quick Reference](#quick-reference)

---

## The Problem

You're building an Xposed module. You want to see everything:

```kotlin
XposedBridge.log("Hook triggered for ${param.method.name}")
XposedBridge.log("Original value: ${param.args[0]}")
XposedBridge.log("Replacing with: $newValue")
```

This is smart. Silent failures are debugging nightmares. But now your device crawls because every hook floods the log system.

**The dilemma:**
- Logs ON → You can debug, device is slow
- Logs OFF (remove code) → Device is fast, you're blind to failures
- Rebuild every time? → Painful

**What you want:** A light switch.

---

## The Solution

### The Light Switch Analogy

```
┌─────────────────────────────────────────────────────────────────┐
│                        YOUR ROOM                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│     ┌─────┐                              💡 💡 💡              │
│     │ ON  │                              (lights)               │
│     │─────│ ← switch                                            │
│     │ OFF │                                                     │
│     └─────┘                                                     │
│                                                                 │
│   Switch OFF:                                                   │
│   • Lights exist (wired, installed)                            │
│   • Zero electricity flows                                      │
│   • Room is dark but ready                                      │
│                                                                 │
│   Switch ON:                                                    │
│   • Electricity flows                                           │
│   • Lights illuminate                                           │
│   • You can see everything                                      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

Your logging code is the **wiring**. The debug flag is the **switch**. When OFF, the wiring exists but no electricity (CPU cycles) flows through the expensive logging operations.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              DEVICE                                      │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌──────────────────────┐         ┌──────────────────────────────────┐  │
│  │   FRONTEND APP       │         │        TARGET APP PROCESS        │  │
│  │   (Material 3 UI)    │         │     (Where hooks run)            │  │
│  │                      │         │                                  │  │
│  │  ┌────────────────┐  │         │  ┌────────────────────────────┐  │  │
│  │  │  Debug Toggle  │  │         │  │    XPOSED MODULE CODE      │  │  │
│  │  │    [━━●]       │──┼────┐    │  │                            │  │  │
│  │  └────────────────┘  │    │    │  │  HookLogger.enabled ◄──────┼──┼──┘
│  │         │            │    │    │  │        ↓                   │  │  (reads flag)
│  │         ▼            │    │    │  │  if (enabled) {            │  │
│  │  ┌────────────────┐  │    │    │  │    XposedBridge.log(...)   │  │
│  │  │ App's own logs │  │    │    │  │  }                         │  │
│  │  │ Logger.d {...} │  │    │    │  │                            │  │
│  │  └────────────────┘  │    │    │  └────────────────────────────┘  │
│  │                      │    │    │                                  │
│  └──────────────────────┘    │    └──────────────────────────────────┘
│                              │                                        │
│                              ▼                                        │
│                    ┌──────────────────┐                               │
│                    │  SHARED STATE    │                               │
│                    │                  │                               │
│                    │  /data/local/tmp │                               │
│                    │  /mymodule_debug │                               │
│                    │                  │                               │
│                    │  exists = ON     │                               │
│                    │  absent = OFF    │                               │
│                    └──────────────────┘                               │
│                                                                        │
└─────────────────────────────────────────────────────────────────────────┘
```

**Key insight:** The frontend app and Xposed module run in **different processes**. They communicate through a shared file that both can access.

---

## Part 1: Xposed Module Logger

### Simple Implementation (Recommended)

Uses time-based caching. File checked at most once every few seconds.

```kotlin
// HookLogger.kt
package com.mymodule.logging

import de.robv.android.xposed.XposedBridge
import java.io.File

object HookLogger {

    private const val TAG = "MyModule"
    private const val FLAG_FILE = "/data/local/tmp/mymodule_debug"
    private const val CACHE_DURATION_MS = 3000L

    @Volatile
    private var cachedEnabled = false

    @Volatile
    private var lastCheckTime = 0L

    @JvmField
    val enabled: Boolean
        get() {
            val now = System.currentTimeMillis()
            if (now - lastCheckTime > CACHE_DURATION_MS) {
                cachedEnabled = File(FLAG_FILE).exists()
                lastCheckTime = now
            }
            return cachedEnabled
        }

    inline fun d(message: () -> String) {
        if (enabled) XposedBridge.log("[$TAG] ${message()}")
    }

    inline fun hook(method: String, message: () -> String) {
        if (enabled) XposedBridge.log("[$TAG][$method] ${message()}")
    }

    @JvmStatic
    fun d(message: String) {
        if (enabled) XposedBridge.log("[$TAG] $message")
    }

    @JvmStatic
    fun hook(method: String, message: String) {
        if (enabled) XposedBridge.log("[$TAG][$method] $message")
    }

    @JvmStatic
    fun e(message: String, t: Throwable? = null) {
        XposedBridge.log("[$TAG][ERROR] $message")
        t?.let { XposedBridge.log(it) }
    }

    @JvmStatic
    fun isEnabled(): Boolean = enabled
}
```

### How The Caching Works

```
Time:     0ms      1000ms    2000ms    3000ms    4000ms    5000ms
          │         │         │         │         │         │
Log call: ├─────────┼─────────┼─────────┼─────────┼─────────┤
          │         │         │         │         │         │
Check:    [FILE]    [cache]   [cache]   [FILE]    [cache]   [cache]
          │         │         │         │         │         │
          └─ reads  └─ fast   └─ fast   └─ reads  └─ fast   └─ fast
             disk      mem       mem       disk      mem       mem
```

### Advanced Implementation (Instant Toggle)

Uses FileObserver for immediate response.

```kotlin
// HookLogger.kt (Advanced)
package com.mymodule.logging

import android.os.FileObserver
import de.robv.android.xposed.XposedBridge
import java.io.File

object HookLogger {

    private const val TAG = "MyModule"
    private const val FLAG_DIR = "/data/local/tmp"
    private const val FLAG_FILE = "mymodule_debug"
    private val flagPath = "$FLAG_DIR/$FLAG_FILE"

    @Volatile
    @JvmField
    var enabled = false
        private set

    private var observer: FileObserver? = null

    @JvmStatic
    fun init() {
        enabled = File(flagPath).exists()

        observer = object : FileObserver(FLAG_DIR, CREATE or DELETE) {
            override fun onEvent(event: Int, path: String?) {
                if (path == FLAG_FILE) {
                    enabled = (event == CREATE)
                    XposedBridge.log("[$TAG] Debug ${if (enabled) "ENABLED" else "DISABLED"}")
                }
            }
        }.also { it.startWatching() }
    }

    inline fun d(message: () -> String) {
        if (enabled) XposedBridge.log("[$TAG] ${message()}")
    }

    inline fun hook(method: String, message: () -> String) {
        if (enabled) XposedBridge.log("[$TAG][$method] ${message()}")
    }

    @JvmStatic
    fun d(message: String) {
        if (enabled) XposedBridge.log("[$TAG] $message")
    }

    @JvmStatic
    fun e(message: String, t: Throwable? = null) {
        XposedBridge.log("[$TAG][ERROR] $message")
        t?.let { XposedBridge.log(it) }
    }

    @JvmStatic
    fun isEnabled(): Boolean = enabled
}
```

---

## Part 2: Java/Kotlin Interop

Your hooks are in Java, logger is in Kotlin. Here's how to call it.

### From Kotlin Hooks

```kotlin
HookLogger.d { "Value: ${expensive()}" }  // Zero overhead when disabled
```

### From Java Hooks

```java
// Pattern: check flag BEFORE building string
if (HookLogger.enabled) {
    HookLogger.d("Hooked method called with: " + param.args[0]);
}

// Or use helper method
if (HookLogger.isEnabled()) {
    HookLogger.d("Some message: " + someValue);
}
```

### Why The Difference?

```
┌─────────────────────────────────────────────────────────────────┐
│                    KOTLIN (inline works)                        │
├─────────────────────────────────────────────────────────────────┤
│  HookLogger.d { "Value: ${expensive()}" }                       │
│                                                                 │
│  Compiler produces:                                             │
│  if (HookLogger.enabled) {                                      │
│      XposedBridge.log("Value: " + expensive())                  │
│  }                                                              │
│                                                                 │
│  When disabled: expensive() NEVER called                        │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    JAVA (inline ignored)                        │
├─────────────────────────────────────────────────────────────────┤
│  HookLogger.d("Value: " + expensive());                         │
│                                                                 │
│  What happens:                                                  │
│  1. expensive() called                                          │
│  2. String concatenated                                         │
│  3. THEN if-check in logger                                     │
│                                                                 │
│  When disabled: expensive() STILL called (wasted)               │
│                                                                 │
│  FIX: Wrap in your own if-check                                │
│  if (HookLogger.enabled) {                                      │
│      HookLogger.d("Value: " + expensive());                     │
│  }                                                              │
└─────────────────────────────────────────────────────────────────┘
```

---

## Part 3: Frontend App Logger

For logging within your manager app itself.

```kotlin
// Logger.kt
package com.mymodule.logging

import android.util.Log

object Logger {

    private const val TAG = "MyModuleApp"

    @Volatile
    var enabled = false

    inline fun d(message: () -> String) {
        if (enabled) Log.d(TAG, message())
    }

    inline fun i(message: () -> String) {
        if (enabled) Log.i(TAG, message())
    }

    inline fun w(message: () -> String) {
        if (enabled) Log.w(TAG, message())
    }

    fun e(message: String, t: Throwable? = null) {
        Log.e(TAG, message, t)
    }
}
```

---

## Part 4: Material 3 UI

### Dependencies

```kotlin
// build.gradle.kts
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

dependencies {
    // Compose BOM
    implementation(platform("androidx.compose:compose-bom:2024.02.00"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")

    // ViewModel
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.7.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.7.0")
}
```

### ViewModel

```kotlin
// SettingsViewModel.kt
package com.mymodule.ui

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.mymodule.logging.Logger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File

class SettingsViewModel(application: Application) : AndroidViewModel(application) {

    private val prefs = application.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private val flagFile = File("/data/local/tmp/mymodule_debug")

    private val _debugEnabled = MutableStateFlow(prefs.getBoolean("debug", false))
    val debugEnabled: StateFlow<Boolean> = _debugEnabled.asStateFlow()

    init {
        Logger.enabled = _debugEnabled.value
    }

    fun setDebugEnabled(enabled: Boolean) {
        _debugEnabled.value = enabled
        Logger.enabled = enabled
        prefs.edit().putBoolean("debug", enabled).apply()

        viewModelScope.launch(Dispatchers.IO) {
            updateModuleFlag(enabled)
        }
    }

    private fun updateModuleFlag(enabled: Boolean) {
        try {
            if (enabled) flagFile.createNewFile() else flagFile.delete()
        } catch (e: Exception) {
            try {
                val cmd = if (enabled) "touch" else "rm -f"
                Runtime.getRuntime().exec(arrayOf("su", "-c", "$cmd ${flagFile.path}")).waitFor()
            } catch (e: Exception) {
                Logger.e("Failed to update debug flag", e)
            }
        }
    }
}
```

### Reusable Toggle Component

```kotlin
// SettingsToggleItem.kt
package com.mymodule.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector

@Composable
fun SettingsToggleItem(
    title: String,
    subtitle: String? = null,
    icon: ImageVector,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier
) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = subtitle?.let { { Text(it) } },
        leadingContent = {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary
            )
        },
        trailingContent = {
            Switch(
                checked = checked,
                onCheckedChange = onCheckedChange
            )
        },
        modifier = modifier.clickable { onCheckedChange(!checked) }
    )
}
```

### Settings Screen

```kotlin
// SettingsScreen.kt
package com.mymodule.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.BugReport
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.mymodule.ui.components.SettingsToggleItem

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onNavigateBack: () -> Unit,
    viewModel: SettingsViewModel = viewModel()
) {
    val debugEnabled by viewModel.debugEnabled.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back"
                        )
                    }
                }
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            item {
                Text(
                    text = "Developer",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                )
            }

            item {
                SettingsToggleItem(
                    title = "Debug Logging",
                    subtitle = if (debugEnabled) {
                        "Verbose logs active • May slow device"
                    } else {
                        "Disabled"
                    },
                    icon = Icons.Outlined.BugReport,
                    checked = debugEnabled,
                    onCheckedChange = { viewModel.setDebugEnabled(it) }
                )
            }

            item { HorizontalDivider() }
        }
    }
}
```

### Visual Preview

```
┌────────────────────────────────────────┐
│ ←  Settings                            │
├────────────────────────────────────────┤
│                                        │
│ Developer                              │
│ ┌────────────────────────────────────┐ │
│ │ 🐛  Debug Logging            [━━●] │ │
│ │     Verbose logs active •          │ │
│ │     May slow device                │ │
│ └────────────────────────────────────┘ │
│ ────────────────────────────────────── │
│                                        │
└────────────────────────────────────────┘

Toggle OFF:
┌────────────────────────────────────────┐
│ │ 🐛  Debug Logging            [●━━] │ │
│ │     Disabled                       │ │
└────────────────────────────────────────┘
```

---

## Part 5: Integration

### Project Structure

```
app/
├── src/main/
│   ├── java/com/mymodule/
│   │   └── hooks/
│   │       ├── MainHook.java
│   │       ├── RootDetectionHook.java
│   │       └── NetworkHook.java
│   │
│   └── kotlin/com/mymodule/
│       ├── logging/
│       │   ├── HookLogger.kt
│       │   └── Logger.kt
│       │
│       └── ui/
│           ├── MainActivity.kt
│           ├── SettingsScreen.kt
│           ├── SettingsViewModel.kt
│           └── components/
│               └── SettingsToggleItem.kt
│
├── build.gradle.kts
└── proguard-rules.pro
```

### Complete Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         USER TAPS DEBUG TOGGLE                               │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                     ViewModel.setDebugEnabled(true)                          │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
            ┌─────────────┐ ┌─────────────┐ ┌─────────────────┐
            │ Logger      │ │ SharedPrefs │ │ touch flag file │
            │ .enabled    │ │ save state  │ │                 │
            │ = true      │ │             │ │ /data/local/tmp │
            └─────────────┘ └─────────────┘ │ /mymodule_debug │
                    │               │       └────────┬────────┘
                    │               │                │
                    ▼               │                ▼
            ┌─────────────┐         │       ┌─────────────────┐
            │ App logs    │         │       │ FileObserver OR │
            │ now work    │         │       │ next cache check│
            └─────────────┘         │       └────────┬────────┘
                                    │                │
                                    │                ▼
                                    │       ┌─────────────────┐
                                    │       │ HookLogger      │
                                    │       │ .enabled = true │
                                    │       └────────┬────────┘
                                    │                │
                                    │                ▼
                                    │       ┌─────────────────┐
                                    │       │ Xposed logs     │
                                    │       │ now work        │
                                    │       └─────────────────┘
                                    │
                                    ▼
                           ┌─────────────────┐
                           │ On next app     │
                           │ launch, prefs   │
                           │ restore state   │
                           └─────────────────┘
```

---

## Part 6: Usage Examples

### Java Hook Usage

```java
// MainHook.java
package com.mymodule.hooks;

import com.mymodule.logging.HookLogger;
import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.callbacks.XC_LoadPackage;
import static de.robv.android.xposed.XposedHelpers.findAndHookMethod;

public class MainHook implements IXposedHookLoadPackage {

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lpparam) {
        if (!lpparam.packageName.equals("com.target.app")) return;

        if (HookLogger.enabled) {
            HookLogger.d("Initializing hooks for " + lpparam.packageName);
        }

        hookRootCheck(lpparam);
        hookNetworkCalls(lpparam);
    }

    private void hookRootCheck(XC_LoadPackage.LoadPackageParam lpparam) {
        try {
            findAndHookMethod(
                "com.target.app.Security",
                lpparam.classLoader,
                "isRooted",
                new XC_MethodHook() {
                    @Override
                    protected void beforeHookedMethod(MethodHookParam param) {
                        if (HookLogger.enabled) {
                            HookLogger.hook("isRooted", "Intercepted, returning false");
                        }
                        param.setResult(false);
                    }
                }
            );

            if (HookLogger.enabled) {
                HookLogger.d("Root check hook installed");
            }
        } catch (Throwable t) {
            HookLogger.e("Failed to hook root check", t);
        }
    }

    private void hookNetworkCalls(XC_LoadPackage.LoadPackageParam lpparam) {
        findAndHookMethod(
            "com.target.app.Api",
            lpparam.classLoader,
            "sendRequest",
            String.class,
            new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (HookLogger.enabled) {
                        String url = (String) param.args[0];
                        HookLogger.hook("sendRequest", "URL: " + url);
                    }
                }

                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (HookLogger.enabled) {
                        HookLogger.hook("sendRequest", "Response: " + param.getResult());
                    }
                }
            }
        );
    }
}
```

### Kotlin Hook Usage

```kotlin
// SomeHook.kt
package com.mymodule.hooks

import com.mymodule.logging.HookLogger
import de.robv.android.xposed.IXposedHookLoadPackage
import de.robv.android.xposed.XC_MethodHook
import de.robv.android.xposed.XposedHelpers.findAndHookMethod
import de.robv.android.xposed.callbacks.XC_LoadPackage

class SomeHook : IXposedHookLoadPackage {

    override fun handleLoadPackage(lpparam: XC_LoadPackage.LoadPackageParam) {
        if (lpparam.packageName != "com.target.app") return

        HookLogger.d { "Kotlin hook loading for ${lpparam.packageName}" }

        findAndHookMethod(
            "com.target.app.Manager",
            lpparam.classLoader,
            "checkIntegrity",
            object : XC_MethodHook() {
                override fun beforeHookedMethod(param: MethodHookParam) {
                    HookLogger.hook("checkIntegrity") { "Bypassing integrity check" }
                    param.result = true
                }
            }
        )
    }
}
```

### Frontend App Usage

```kotlin
// MainActivity.kt
package com.mymodule.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.mymodule.logging.Logger
import com.mymodule.ui.theme.MyModuleTheme

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Logger.d { "MainActivity created" }

        setContent {
            MyModuleTheme {
                MainNavigation()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        Logger.d { "MainActivity resumed" }
    }
}
```

---

## Edge Cases & Gotchas

### 1. SELinux Blocking File Access

```kotlin
// Fallback to system property
private fun updateModuleFlag(enabled: Boolean) {
    try {
        if (enabled) flagFile.createNewFile() else flagFile.delete()
    } catch (e: SecurityException) {
        // Use su as fallback
        val cmd = if (enabled) "touch" else "rm -f"
        Runtime.getRuntime().exec(arrayOf("su", "-c", "$cmd ${flagFile.path}"))
    }
}
```

### 2. Multi-Process Target Apps

Each process independently checks the flag. This is fine - when you toggle, all processes will pick up the change (within cache duration or instantly with FileObserver).

### 3. Module Loaded Before Flag Exists

Default is `enabled = false`. Safe for production. Create the file to enable.

### 4. Never Crash on Logging

```kotlin
inline fun d(message: () -> String) {
    if (enabled) {
        try {
            XposedBridge.log("[$TAG] ${message()}")
        } catch (e: Throwable) {
            // Logging should never crash
        }
    }
}
```

### 5. ProGuard/R8 Rules

```proguard
# proguard-rules.pro
-keep class com.mymodule.logging.HookLogger { *; }
-keep class com.mymodule.logging.Logger { *; }
```

---

## Quick Reference

### File Locations

| What | Path |
|------|------|
| Debug flag | `/data/local/tmp/mymodule_debug` |
| LSPosed logs | `/data/adb/lspd/log/` |
| App preferences | `/data/data/com.mymodule/shared_prefs/settings.xml` |

### ADB Commands

```bash
# Enable debug
adb shell su -c "touch /data/local/tmp/mymodule_debug"

# Disable debug
adb shell su -c "rm -f /data/local/tmp/mymodule_debug"

# Check status
adb shell su -c "ls -la /data/local/tmp/mymodule_debug"

# View Xposed logs
adb shell su -c "cat /data/adb/lspd/log/all.log | grep MyModule"

# Live logcat
adb logcat -s MyModule:V MyModuleApp:V
```

### Behavior Summary

| State | App Logs | Xposed Logs | Performance |
|-------|----------|-------------|-------------|
| OFF | Silent | Silent | Full speed |
| ON | Verbose | Verbose | Slower |

### Toggle Timing

| Implementation | Delay | Complexity |
|----------------|-------|------------|
| Simple (cached) | 0-3 sec | Low |
| Advanced (FileObserver) | Instant | Medium |

---

## Summary

```
┌────────────────────────────────────────────────────────────┐
│                    WHAT YOU BUILT                          │
├────────────────────────────────────────────────────────────┤
│                                                            │
│   ┌─────────────────────────────────────────────────────┐  │
│   │              MATERIAL 3 UI                          │  │
│   │  ┌─────────────────────────────────────────────┐    │  │
│   │  │ 🐛 Debug Logging                     [━━●]  │    │  │
│   │  └─────────────────────────────────────────────┘    │  │
│   └──────────────────────┬──────────────────────────────┘  │
│                          │                                  │
│                          ▼                                  │
│   ┌─────────┐     ┌─────────┐     ┌─────────┐              │
│   │  App    │     │  FLAG   │     │ Xposed  │              │
│   │ Logger  │     │  FILE   │     │ Logger  │              │
│   └─────────┘     └─────────┘     └─────────┘              │
│                                                            │
│   ONE TOGGLE → CONTROLS ALL LOGGING → ZERO OVERHEAD OFF   │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

Wrap everything in logs. Toggle them off for production. Debug with confidence.
