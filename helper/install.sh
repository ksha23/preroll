#!/bin/sh
# Installs the Preroll privileged helper. Run as root, once, by the app.
#
#   install.sh <uid> <resources dir>
#
# Everything root will later execute is COPIED into root-owned locations here.
# The app bundle is writable by its user, so root never runs anything from it.
set -e
PATH=/usr/bin:/bin:/usr/sbin:/sbin
USER_ID=$1
SRC=$2
LABEL=com.ksha23.preroll.helper
DIR="/Library/Application Support/Preroll"

case "$USER_ID" in ''|*[!0-9]*) echo "bad uid" >&2; exit 1 ;; esac

launchctl bootout "system/$LABEL" 2>/dev/null || true

mkdir -p /Library/PrivilegedHelperTools "$DIR"
chown root:wheel "$DIR"
chmod 755 "$DIR"
install -o root -g wheel -m 755 "$SRC/preroll-helper.sh" "/Library/PrivilegedHelperTools/$LABEL"
install -o root -g wheel -m 644 "$SRC/$LABEL.plist" "/Library/LaunchDaemons/$LABEL.plist"

# The one file the user may write. Only its content is theirs; the directory
# entry is root's, so it cannot be replaced with a link.
rm -f "$DIR/request" "$DIR/done"
: > "$DIR/request"
chown "$USER_ID" "$DIR/request"
chmod 600 "$DIR/request"

launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist"
