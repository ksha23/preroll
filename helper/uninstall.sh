#!/bin/sh
# Removes the Preroll privileged helper. Run as root by the app. Leaves the
# latency preference alone; the app's Inactive switch is what removes that.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
LABEL=com.ksha23.preroll.helper
launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/PrivilegedHelperTools/$LABEL"
rm -rf "/Library/Application Support/Preroll"
