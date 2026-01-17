ui_print " "
ui_print "======================================="
ui_print "               NoMount                 "
ui_print "  Native Kernel Injection Metamodule   "
ui_print "======================================="
ui_print " "

ui_print "- Device Architecture: $ARCH"
if [ ! -f "$MODPATH/nm-$ARCH" ]; then
  abort "! Unsupported architecture: $ARCH"
fi
mkdir -p "$MODPATH/bin"
cp -f "$MODPATH/nm-$ARCH" "$MODPATH/bin/nm"
set_perm "$MODPATH/bin/nm" 0 0 0755
rm -rf $MODPATH/nm*

ui_print "- Checking Kernel support..."
if [ -e "/dev/vfs_helper" ]; then
  ui_print "  [OK] Driver /dev/vfs_helper detected."
  ui_print "  [OK] System is ready for injection."
else
  ui_print " "
  ui_print "***************************************************"
  ui_print "* [!] WARNING: KERNEL DRIVER NOT DETECTED         *"
  ui_print "***************************************************"
  ui_print "* The device node /dev/vfs_helper is missing.     *"
  ui_print "* *"
  ui_print "* This module will NOT FUNCTION until you flash   *"
  ui_print "* a Kernel compiled with CONFIG_FS_DCACHE_PREFETCH*"
  ui_print "***************************************************"
  ui_print " "

  touch "$MODPATH/disable"
fi

if [ -f "/data/adb/nomount.log" ]; then
    rm -f "/data/adb/nomount.log"
fi

ui_print "- Installation complete."
