#!/bin/bash

SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || { echo "idle-watcher: missing config $SS_CONF — run the installer." >&2; exit 1; }

IDLE_LIMIT="$IDLE_TIMEOUT_MS"
while true; do
    if playerctl -a status 2>/dev/null | grep -iq "playing"; then sleep 10; continue; fi

    if pactl list sink-inputs 2>/dev/null | grep -iq "state: RUNNING"; then sleep 10; continue; fi

    if dbus-send --session --dest=org.freedesktop.ScreenSaver --type=method_call --print-reply /org/freedesktop/ScreenSaver org.freedesktop.ScreenSaver.GetInhibitors 2>/dev/null | grep -q "string"; then 
        sleep 10; continue; 
    fi

    if gdbus call --session --dest org.gnome.SessionManager --object-path /org/gnome/SessionManager --method org.gnome.SessionManager.IsInhibited 8 2>/dev/null | grep -q "true"; then
        sleep 10; continue;
    fi

    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        RAW=$(gdbus call --session --dest org.gnome.Mutter.IdleMonitor --object-path /org/gnome/Mutter/IdleMonitor/Core --method org.gnome.Mutter.IdleMonitor.GetIdletime 2>/dev/null)
        IDLE_MS=$(echo "$RAW" | awk '{print $2}' | tr -d '[,)]')
    else
        IDLE_MS=$(xdotool getidletime 2>/dev/null)
    fi

    IDLE_MS=${IDLE_MS:-0}
    [ "$IDLE_MS" -gt "$IDLE_LIMIT" ] && "$APP_DIR/launch.sh"
    sleep 10
done
