#!/bin/sh
# Preroll privileged helper, version 1.
#
# launchd runs this as root whenever the request file changes. Its whole job is
# to set or clear one AirPlay preference and restart AirPlayXPCHelper, so that
# the next AirPlay route is built with the new latency. It does nothing else.
#
# The request file is written by the user who installed the helper, so its
# content is untrusted input. It is read with a size cap and parsed strictly, and
# nothing from it reaches a command except a validated integer.
#
# Request format, one line:   <sequence> <milliseconds|off>
# The sequence is any new number; a request whose sequence was already handled is
# ignored, so a spurious launch by launchd does nothing.

set -f
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export HOME=/var/root

DIR="/Library/Application Support/Preroll"
REQ="$DIR/request"
DONE="$DIR/done"
DOMAIN=com.apple.airplay
SYSTEM=/Library/Preferences/com.apple.airplay
KEY=audioLatencyMs

# The directory is root-owned, so the user cannot swap the file for a link.
[ -f "$REQ" ] && [ ! -L "$REQ" ] || exit 0

line=$(head -c 64 "$REQ" | head -n 1)
case "$line" in *" "*) ;; *) exit 0 ;; esac
seq=${line%% *}
val=${line#* }

case "$seq" in ''|*[!0-9]*) exit 0 ;; esac
[ ${#seq} -le 16 ] || exit 0
case "$val" in
  off) ;;
  ''|0*|*[!0-9]*) exit 0 ;;
  *) [ ${#val} -le 4 ] && [ "$val" -ge 100 ] && [ "$val" -le 4000 ] || exit 0 ;;
esac

[ "$seq" = "$(cat "$DONE" 2>/dev/null)" ] && exit 0

if [ "$val" = off ]; then
  defaults delete "$DOMAIN" "$KEY" 2>/dev/null
  defaults delete "$SYSTEM" "$KEY" 2>/dev/null
else
  # Root's own domain is what AirPlayXPCHelper reads; the system domain is only
  # there so the app, running as the user, can read the value back.
  defaults write "$DOMAIN" "$KEY" -int "$val"
  defaults write "$SYSTEM" "$KEY" -int "$val"
fi
echo "$seq" > "$DONE"
chmod 644 "$DONE"

# The helper keeps one engine for system audio for its whole life, so only a
# restart makes the next route use the new value. launchd relaunches it on demand.
killall AirPlayXPCHelper 2>/dev/null
logger -t preroll-helper "audioLatencyMs=$val, AirPlayXPCHelper restarted"
exit 0
