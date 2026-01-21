# Root Detection App Techniques Research

## Executive Summary

### Top 5 Most Reliable Detection Techniques Used Today (2025)

1. **Hardware-Backed Play Integrity (TEE Attestation)** - Nearly impossible to bypass without leaked keybox.xml files; relies on Trusted Execution Environment which is physically isolated from the OS
2. **Mount Namespace Mismatch Detection** - Detects when app runs in different mount namespace than expected; still works against Shamiko/Zygisk
3. **st_dev Device ID Comparison** - Compares device IDs from stat() calls across paths to detect overlay/bind mount manipulation; used by Native Detector
4. **/proc/self/mountinfo Parsing** - Detects Magisk-related entries, overlay mounts, and abnormal mount patterns
5. **Syscall Errno Pattern Analysis** - Detects inconsistent error responses that occur when syscalls are hooked/intercepted (kernel-dependent)

---

## 1. Native Detector Analysis (reveny/Android-Native-Root-Detector)

### Primary Detection Methods

Native Detector is one of the most comprehensive root detection tools, maintained by Reveny with both public and private versions.

**Documented Detection Checks:**

| Check Type | Description | Evidence |
|------------|-------------|----------|
| Magisk Detection | Detects Magisk installation | [GitHub](https://github.com/reveny/Android-Native-Root-Detector) |
| Magisk SU Detection | Detects Magisk's su binary | [Releases](https://github.com/reveny/Android-Native-Root-Detector/releases) |
| Zygisk Detection | Detects Zygisk framework | [XDA](https://xdaforums.com/t/how-to-resolve-native-detector-finds.4716259/) |
| Zygisk-Assistant Detection | Detects hiding module | [GitHub](https://github.com/snake-4/Zygisk-Assistant/issues/84) |
| KernelSU Detection | Detects KernelSU root | [GitHub](https://github.com/reveny/Android-Native-Root-Detector) |
| APatch Detection | Detects APatch root | [GitHub](https://github.com/reveny/Android-Native-Root-Detector) |
| LSPosed Detection | Detects LSPosed framework | [GitHub](https://github.com/reveny/Android-Native-Root-Detector) |
| Mount Inconsistency | Detects mount namespace issues | [XDA](https://xdaforums.com/t/how-to-resolve-native-detector-finds.4716259/page-2) |
| Umount Detection | Detects umount operations | [XDA](https://xdaforums.com/t/how-to-resolve-native-detector-finds.4716259/) |
| Magic Mount Detection | Detects Magisk's magic mount | [GitHub Releases](https://github.com/reveny/Android-Native-Root-Detector/releases) |
| Bootloader Detection | Detects unlocked bootloader | [GitHub](https://github.com/reveny/Android-Native-Root-Detector) |
| Custom ROM Detection | Detects non-stock ROMs | [GitHub](https://github.com/reveny/Android-Native-Root-Detector) |
| Leaked Keybox Detection | Detects known leaked keyboxes | [GitHub](https://github.com/reveny/Android-Native-Root-Detector) |
| Service Spoof Detection | Detects service spoofing | [Releases v7.2.0+](https://github.com/reveny/Android-Native-Root-Detector/releases) |

### st_dev / Mount Inconsistency Detection

Based on research, Native Detector performs **device ID (st_dev) comparison** checks:

- Compares `st_dev` values from `stat()` calls on paths like `/data` vs parent directories
- Overlay filesystems and bind mounts can cause st_dev mismatches
- "Detected Mount Inconsistency" string in app resources confirms this check
- **Currently no feasible bypass** for mount per-user inconsistency checks according to XDA discussions

### Does it check /proc/self/fd?

**UNKNOWN - Likely YES for Frida detection**

Native Detector includes Frida detection, and /proc/self/fd inspection is a common technique for Frida detection (checking for named pipes used by Frida agent). However, there's no direct evidence it uses /proc/self/fd specifically for root detection (vs Frida detection).

---

## 2. Momo Analysis (io.github.vvb2060.mahoshojo)

### Primary Detection Methods

Momo is considered "the strongest detection app known" and is reportedly developed by the same person behind Shamiko.

**Documented Checks:**

| Check | API/Method Used | Evidence |
|-------|-----------------|----------|
| Frida Detection | Memory maps, /proc parsing | [andnixsh.com](https://www.andnixsh.com/2023/12/magisk-root-detection-apps.html) |
| Magisk Detection | Multiple methods | [GitHub](https://github.com/apkunpacker/MagiskDetection) |
| Zygisk Detection | /proc/self/attr/prev, mountinfo | [8ksec.io](https://8ksec.io/advanced-root-detection-bypass-techniques/) |
| Magisk Modules Detection | File/path scanning | [andnixsh.com](https://www.andnixsh.com/2023/12/magisk-root-detection-apps.html) |
| Debugging Mode Detection | System properties | [andnixsh.com](https://www.andnixsh.com/2023/12/magisk-root-detection-apps.html) |
| Developer Mode Detection | Settings checking | [andnixsh.com](https://www.andnixsh.com/2023/12/magisk-root-detection-apps.html) |
| Bootloader Detection | System properties | [andnixsh.com](https://www.andnixsh.com/2023/12/magisk-root-detection-apps.html) |
| System Files Modified | File integrity checks | [andnixsh.com](https://www.andnixsh.com/2023/12/magisk-root-detection-apps.html) |
| Package Manager Abnormal | Package scanning | [andnixsh.com](https://www.andnixsh.com/2023/12/magisk-root-detection-apps.html) |
| Custom ROM Detection | Build props, fingerprints | [andnixsh.com](https://www.andnixsh.com/2023/12/magisk-root-detection-apps.html) |
| SELinux State Detection | stat() on policy files | [XDA](https://xdaforums.com/t/momo-root-detection-partition-mounted-abnormally.4402577/) |
| Partition Mount Abnormal | /proc/self/mountinfo | [XDA](https://xdaforums.com/t/momo-root-detection-partition-mounted-abnormally.4402577/) |

### Key Technical Details

- Uses `stat()` to access SELinux policy files
- Parses `/proc/self/mountinfo` looking for "magisk" and "zygote" strings
- Checks `/proc/self/attr/prev` for "zygote" (Zygisk indicator)
- String comparison functions are used for mountinfo/zygote detection

### Does it check /proc/self/fd?

**LIKELY YES** - Momo includes Frida detection which commonly uses /proc/self/fd inspection.

---

## 3. RootBeer Analysis (scottyab/rootbeer)

### Primary Detection Methods

RootBeer is an open-source library used by thousands of banking apps.

| Method | What It Checks | API/Technique |
|--------|---------------|---------------|
| `detectRootManagementApps()` | SuperSU, Magisk Manager | PackageManager API |
| `detectPotentiallyDangerousApps()` | Known risky apps | PackageManager API |
| `detectRootCloakingApps()` | Hide My Root, etc. | PackageManager + native lib access |
| `checkForSuBinary()` | /system/xbin/su, etc. | File.exists() on common paths |
| `checkForMagiskBinary()` | Magisk binary | File.exists() on common paths |
| `checkForBusyBoxBinary()` | BusyBox presence | File.exists() |
| `checkForDangerousProps()` | ro.debuggable, etc. | getprop command execution |
| `checkForRWPaths()` | /system writable | mount command parsing |
| `checkSuExists()` | su via which | which su command |
| `checkForRootNative()` | Native su check | JNI native library call |
| `detectTestKeys()` | Test-signed build | android.os.Build.TAGS |

**Source Code:** [GitHub - RootBeer.java](https://github.com/scottyab/rootbeer/blob/master/rootbeerlib/src/main/java/com/scottyab/rootbeer/RootBeer.java)

### Limitations

- Easily bypassed by Magisk DenyList/Shamiko
- No mount namespace detection
- No hardware attestation
- No advanced /proc parsing
- Author notes: "root==god, so there's no 100% guaranteed way to check for root"

### Does it check /proc/self/fd?

**NO** - RootBeer focuses on simpler file existence and package checks.

---

## 4. Play Integrity / SafetyNet Analysis

### Current State (2025)

SafetyNet was fully deprecated in January 2025. Play Integrity API is now the standard.

### Detection Mechanism Tiers

| Verdict | What It Requires | Bypassable? |
|---------|------------------|-------------|
| MEETS_BASIC_INTEGRITY | No root indicators, basic checks | Yes (easy) |
| MEETS_DEVICE_INTEGRITY | Locked bootloader (Android 13+), certified device | Yes (with PIF module + property spoofing) |
| MEETS_STRONG_INTEGRITY | Hardware-backed TEE attestation | Requires leaked keybox.xml |

### Hardware Attestation Details

**Since Android 13:**
- Hardware-backed proof that bootloader is locked
- Verified by Trusted Execution Environment (TEE) / Titan M chip
- TEE is physically isolated from OS - cannot be spoofed via software
- Google offers $250K bounty for TEE compromise

### Bypass Methods (2025)

1. **PlayIntegrityFix (PIF)** - Spoofs device properties for DEVICE integrity
2. **TrickyStore** - Intercepts Binder IPC to spoof certificate chain
3. **Leaked Keybox** - Valid OEM keybox.xml files periodically leak from manufacturers
4. **spoofVendingSdk** - Spoofs SDK 32 to bypass May 2025 bootloader checks (breaks Play Store functionality)

### May 2025 Policy Changes

- Unlocked bootloaders no longer meet BASIC integrity by default
- Android 13+ DEVICE integrity requires locked bootloader
- Strong integrity requires valid keybox which Google actively revokes

**Key Sources:**
- [Play Integrity Verdicts](https://developer.android.com/google/play/integrity/verdicts)
- [PlayIntegrityFork GitHub](https://github.com/osm0sis/PlayIntegrityFork)
- [Security Analysis](https://iamjosephmj.medium.com/a-technical-autopsy-of-the-android-trust-model-9dafc9ab08d4)

---

## 5. Common Banking App Techniques

### Detection Methods Used

| Method | Prevalence | Effectiveness |
|--------|------------|---------------|
| Play Integrity API | Very High | High (for STRONG) |
| Root management app scan | High | Low (easily hidden) |
| Su binary existence | High | Low (easily hidden) |
| Magisk package detection | High | Low (package name hidden) |
| /proc/mounts parsing | Medium | Medium |
| Native code checks | Medium | Medium-High |
| Commercial RASP (Appdome, etc.) | Medium | Medium-High |

### Commercial Solutions

Banking apps often use commercial Runtime Application Self-Protection (RASP):

- **Appdome** - AI-driven detection, blocks Magisk/Shamiko/Zygisk
- **Zimperium** - Mount count analysis, behavioral detection
- **Promon** - Multi-layer protection
- **Guardsquare** - DexGuard with root detection

These solutions combine multiple techniques:
- Behavioral monitoring (syscall patterns)
- Mount count anomaly detection
- Library loading anomalies
- Contextual cues (delayed system responses)

**Sources:**
- [Appdome Root Detection](https://www.appdome.com/mobile-app-security/android-root-detection/)
- [Banking App Bypass Guide](https://markuta.com/magisk-root-detection-banking-apps/)

---

## Detection Method Effectiveness Matrix

| Method | Effectiveness | Bypassable | How to Bypass |
|--------|---------------|------------|---------------|
| Hardware TEE attestation | VERY HIGH | Only with leaked keybox | TrickyStore + valid keybox.xml |
| Mount namespace mismatch | HIGH | Difficult | SUSFS kernel patches |
| st_dev comparison | HIGH | Difficult | Device ID spoofing (kernel-level) |
| /proc/self/mountinfo parsing | MEDIUM-HIGH | Yes | Shamiko/SUSFS mount hiding |
| Syscall errno pattern analysis | MEDIUM | Kernel-dependent | Custom kernel patches |
| OverlayFS detection | MEDIUM | Sometimes | Magic mount vs OverlayFS choice |
| /proc/self/maps scanning | MEDIUM | Yes | Frida naming, library hiding |
| /proc/self/fd inspection | MEDIUM | Yes | Frida gadget mode, fd hiding |
| SELinux state detection | MEDIUM | Yes | SUSFS, property spoofing |
| Binary existence checks | LOW | Yes | File hiding (Shamiko/SUSFS) |
| Package manager scans | LOW | Yes | Package hiding (HideMyApplist) |
| System property checks | LOW | Yes | Property spoofing |

---

## NoMount Gap Relevance Assessment

Based on research into what actual detection apps check:

| NoMount Gap | Used by Detection Apps? | Evidence | Priority |
|-------------|-------------------------|----------|----------|
| **/proc/self/fd leakage** | YES (for Frida) | Documented in Frida detection research | MEDIUM - primarily Frida, not direct root |
| **st_dev inconsistency** | YES | Native Detector "Mount Inconsistency" check | HIGH - actively exploited |
| **st_ino inconsistency** | UNKNOWN | No direct evidence found | LOW - theoretical concern |
| **Whiteout detection** | UNKNOWN | No direct evidence found | LOW - theoretical concern |
| **/dev visibility** | PARTIALLY | Some apps check /dev/magisk_patched | MEDIUM |
| **Boot race window** | NO | Detection happens at runtime, not boot | LOW - not a detection vector |
| **/proc/mounts parsing** | YES | Well documented | HIGH - widely used |
| **Mount namespace mismatch** | YES | Documented as "still working" in 2025 | HIGH - key detection vector |
| **OverlayFS in /proc/fs** | YES | OverlayFS analysis documented | MEDIUM-HIGH |

---

## Conclusion

### Which NoMount Gaps Are ACTUALLY Exploited

1. **HIGH PRIORITY - Actively Exploited:**
   - st_dev device ID comparison (Native Detector "Mount Inconsistency")
   - /proc/self/mountinfo and /proc/mounts parsing
   - Mount namespace mismatch detection
   - OverlayFS anomaly detection

2. **MEDIUM PRIORITY - Partially Exploited:**
   - /proc/self/fd (primarily for Frida detection, not direct root)
   - /dev entries (some apps check for magisk-related devices)

3. **LOW PRIORITY - Theoretical/Not Found in Practice:**
   - st_ino inode inconsistency checks - No evidence found
   - Whiteout/chardev detection - No evidence found
   - Boot race window exploitation - Not a detection technique
   - Timing attacks - Only for remote/network scenarios, not local root detection

### Key Takeaways

1. **Hardware attestation (Play Integrity STRONG) is the ultimate barrier** - requires leaked keyboxes which Google actively revokes

2. **Mount-related inconsistencies are the primary detection vector** for sophisticated apps like Native Detector and Momo

3. **SUSFS kernel patches are currently the most effective bypass** because they operate at kernel level, below where detection apps can inspect

4. **The cat-and-mouse game continues** - detection apps add new checks (like Native Detector's mount inconsistency), hiding tools respond with deeper integration (SUSFS)

5. **No evidence of timing attacks or inode consistency checks** being used by actual root detection apps in 2025

---

## Sources

### Detection App Repositories
- [Android-Native-Root-Detector](https://github.com/reveny/Android-Native-Root-Detector)
- [RootBeer](https://github.com/scottyab/rootbeer)
- [MagiskDetection Collection](https://github.com/apkunpacker/MagiskDetection)

### Root Hiding Tools
- [SUSFS Module](https://github.com/sidex15/susfs4ksu-module)
- [Shamiko](https://github.com/LSPosed/LSPosed.github.io/releases)
- [Zygisk-Assistant](https://github.com/snake-4/Zygisk-Assistant)
- [PlayIntegrityFix](https://github.com/osm0sis/PlayIntegrityFork)

### Research & Documentation
- [Detecting Shamiko & Zygisk (2025)](https://medium.com/@arnavsinghinfosec/detecting-shamiko-zygisk-root-hiding-on-android-2025-the-definitive-developer-guide-71beac4a378d)
- [Advanced Root Detection Bypass - 8kSec](https://8ksec.io/advanced-root-detection-bypass-techniques/)
- [Play Integrity Verdicts - Android Developers](https://developer.android.com/google/play/integrity/verdicts)
- [Magisk & Root Detection Apps - andnixsh](https://www.andnixsh.com/2023/12/magisk-root-detection-apps.html)
- [SUSFS Explained](https://www.privacyportal.co.uk/blogs/free-rooting-tips-and-tricks/susfs-explained-root-hiding-for-kernelsu-with-installation-guide)

### XDA Discussions
- [How to resolve Native Detector finds](https://xdaforums.com/t/how-to-resolve-native-detector-finds.4716259/)
- [Momo Partition Mounted Abnormally](https://xdaforums.com/t/momo-root-detection-partition-mounted-abnormally.4402577/)
- [Root Hiding Guide by TheUnrealZaka](https://gist.github.com/TheUnrealZaka/042040a1700ad869d54e781507a9ba4f)
