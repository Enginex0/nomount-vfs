#!/bin/bash
# inject-base-hide-stuff.sh - Injects lineage path spoofing into fs/proc/base.c (map_files)
# This is the second part of 69_hide_stuff.patch functionality
# Uses awk for reliable multi-line pattern replacement

set -e

TARGET_FILE="${1:-fs/proc/base.c}"

if [ ! -f "$TARGET_FILE" ]; then
    echo "ERROR: Target file not found: $TARGET_FILE"
    exit 1
fi

# Check if already patched (look for the lineage spoofing pattern)
# The pattern is on multiple lines, so check for the distinctive marker
if grep -q 'hide_stuff: Spoof lineage paths in map_files' "$TARGET_FILE" 2>/dev/null; then
    echo "INFO: $TARGET_FILE already contains base.c hide_stuff hooks, skipping"
    exit 0
fi

echo "Injecting base.c hide_stuff hooks into $TARGET_FILE..."

# Create temp file
TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT

# The pattern we're looking for in map_files_get_link function:
#   vma = find_exact_vma(mm, vm_start, vm_end);
#   if (vma && vma->vm_file) {
#       *path = vma->vm_file->f_path;
#       path_get(path);
#       rc = 0;
#   }
#
# Transform to:
#   vma = find_exact_vma(mm, vm_start, vm_end);
#   if (vma) {
#       if (vma->vm_file) {
#           if (strstr(vma->vm_file->f_path.dentry->d_name.name, "lineage")) {
#               rc = kern_path("/system/framework/framework-res.apk", LOOKUP_FOLLOW, path);
#           } else {
#               *path = vma->vm_file->f_path;
#               path_get(path);
#               rc = 0;
#           }
#       }
#   }

# Use awk to perform the transformation
# This handles the multi-line replacement robustly
awk '
/if \(vma && vma->vm_file\) \{/ {
    # Found the target pattern - replace with hide_stuff version
    print "\tif (vma) {"
    print "\t\tif (vma->vm_file) {"
    print "\t\t\t/* hide_stuff: Spoof lineage paths in map_files */"
    print "\t\t\tif (strstr(vma->vm_file->f_path.dentry->d_name.name, \"lineage\")) {"
    print "\t\t\t\trc = kern_path(\"/system/framework/framework-res.apk\", LOOKUP_FOLLOW, path);"
    print "\t\t\t} else {"
    # Now we need to consume the next 3 original lines and indent them
    getline  # *path = vma->vm_file->f_path;
    print "\t\t\t\t*path = vma->vm_file->f_path;"
    getline  # path_get(path);
    print "\t\t\t\tpath_get(path);"
    getline  # rc = 0;
    print "\t\t\t\trc = 0;"
    print "\t\t\t}"
    print "\t\t}"
    getline  # } (closing brace of original if)
    print "\t}"
    next
}
{ print }
' "$TARGET_FILE" > "$TEMP_FILE"

# Verify the injection worked
if ! grep -q 'strstr.*lineage' "$TEMP_FILE"; then
    echo "ERROR: Injection failed - lineage pattern not found in output"
    rm -f "$TEMP_FILE"
    exit 1
fi

if ! grep -q 'kern_path.*framework-res.apk' "$TEMP_FILE"; then
    echo "ERROR: Injection failed - kern_path not found in output"
    rm -f "$TEMP_FILE"
    exit 1
fi

# Apply changes
mv "$TEMP_FILE" "$TARGET_FILE"
trap - EXIT

echo "SUCCESS: base.c hide_stuff hooks injected into $TARGET_FILE"
