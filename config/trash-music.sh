#!/bin/bash
set -u

# Trash ONE music file (used by the song chooser's delete button). Mirrors
# trash-media.sh's fallback chain but only ever touches files under the Music
# directory, so a stray path can never delete anything else.
SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || { echo "trash-music: missing config $SS_CONF" >&2; exit 1; }

F="${1:-}"
[ -n "$F" ] && [ -e "$F" ] || exit 0

# Safety: only files under $MUSIC_DIR may be trashed here.
case "$F" in
    "$MUSIC_DIR"/*) ;;
    *) echo "trash-music: refusing path outside Music: $F" >&2; exit 0 ;;
esac

if command -v gio >/dev/null 2>&1 && gio trash -- "$F" 2>/dev/null; then exit 0; fi
if command -v trash-put >/dev/null 2>&1 && trash-put -- "$F" 2>/dev/null; then exit 0; fi
mkdir -p "$DATA_DIR/Trash"
mv -f "$F" "$DATA_DIR/Trash/" 2>/dev/null || true
exit 0
