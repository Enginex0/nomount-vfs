# NoMount VFS

VFS-level path redirection for KernelSU. Replaces overlay mounts with kernel VFS hooks.

## Requirements

- Kernel compiled with `CONFIG_VFS_DCACHE_HELPER=y`
- KernelSU, APatch, or Magisk
- ARM64 device

## Installation

1. Flash a kernel with NoMount support
2. Install the module via KSU Manager

## How It Works

Traditional module mounting uses overlayfs which is detectable via `/proc/mounts`, `statfs()`, or `st_dev` checks. NoMount operates at the VFS syscall level - no mounts are created, paths are simply redirected in the kernel.

```
Overlay approach:
stat("/system/app/Bloat") → kernel checks mount table → overlay detected

NoMount approach:
stat("/system/app/Bloat") → VFS hook intercepts → returns ENOENT
                           (no mount exists to detect)
```

## Boot Sequence

```
post-fs-data (early):
└── Inject skip_mount into all modules (prevents KSU from mounting)

service.sh (late boot):
├── Check /dev/vfs_helper availability
├── Register VFS redirections for all modules
├── Hijack any existing overlay/bind/loop/tmpfs mounts
└── Hide device via SUSFS (if available)
```

## Configuration

Config file: `/data/adb/nomount/config.sh`

```bash
universal_hijack=true      # Auto-hijack all module mounts
auto_skip_mount=true       # Inject skip_mount into modules
monitor_new_modules=true   # Watch for new module installs
excluded_modules=""        # Modules to exclude (comma-separated)
```

## Commands

```bash
# List active redirections
nm list

# Add redirection
nm add <virtual_path> <real_path>

# Remove redirection
nm del <virtual_path>

# Block UID from seeing redirections
nm blk <uid>
```

## Logs

```bash
cat /data/adb/nomount/nomount.log
```

## Building

The `nm` binary source is at [maxsteeel/nomount](https://github.com/maxsteeel/nomount).

## Credits

- [maxsteeel](https://github.com/maxsteeel) - Original NoMount kernel patches and nm binary
- [Enginex0](https://github.com/Enginex0) - Universal Hijacker implementation

## License

GPL-3.0
