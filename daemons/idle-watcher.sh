#!/bin/bash
set -u

# Single instance: the watcher is autostarted, so a second login session (or a
# re-login without a clean logout) would otherwise run a second copy and double-
# launch the screensaver. If a recorded PID is still alive, this copy bows out.
# (A PID file — not flock — because the watcher spawns launch.sh as a child, and
# an inherited lock fd would keep the lock held after the watcher itself exits.)
SS_WATCHER_PID="${TMPDIR:-/tmp}/ss_idle_watcher.$(id -u).pid"
if [ -f "$SS_WATCHER_PID" ] && kill -0 "$(cat "$SS_WATCHER_PID" 2>/dev/null)" 2>/dev/null; then
    exit 0
fi
echo "$$" > "$SS_WATCHER_PID" 2>/dev/null || true

SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || { echo "idle-watcher: missing config $SS_CONF — run the installer." >&2; exit 1; }

IDLE_LIMIT="$IDLE_TIMEOUT_MS"
while true; do
    # Cheapest check first: while the user is ACTIVE (most of the day) one
    # idle-time read per cycle is all this loop costs — the four media/inhibitor
    # subprocess checks below only run once the idle threshold is crossed.
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        RAW=$(gdbus call --session --dest org.gnome.Mutter.IdleMonitor --object-path /org/gnome/Mutter/IdleMonitor/Core --method org.gnome.Mutter.IdleMonitor.GetIdletime 2>/dev/null)
        IDLE_MS=$(echo "$RAW" | awk '{print $2}' | tr -d '[,)]')
    else
        IDLE_MS=$(xdotool getidletime 2>/dev/null)
    fi
    IDLE_MS=${IDLE_MS:-0}
    if [ "$IDLE_MS" -le "$IDLE_LIMIT" ]; then sleep 10; continue; fi

    if playerctl -a status 2>/dev/null | grep -iq "playing"; then sleep 10; continue; fi

    if pactl list sink-inputs 2>/dev/null | grep -iq "state: RUNNING"; then sleep 10; continue; fi

    if dbus-send --session --dest=org.freedesktop.ScreenSaver --type=method_call --print-reply /org/freedesktop/ScreenSaver org.freedesktop.ScreenSaver.GetInhibitors 2>/dev/null | grep -q "string"; then
        sleep 10; continue;
    fi

    if gdbus call --session --dest org.gnome.SessionManager --object-path /org/gnome/SessionManager --method org.gnome.SessionManager.IsInhibited 8 2>/dev/null | grep -q "true"; then
        sleep 10; continue;
    fi

    "$APP_DIR/launch.sh"
    sleep 10
done
