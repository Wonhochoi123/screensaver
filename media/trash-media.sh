#!/bin/bash
set -u

# Central config gives us MEDIA_DIR / OPT_DIR / PLAYLIST / DATA_DIR.
SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || { echo "trash-media: missing config $SS_CONF" >&2; exit 1; }

MEDIA="${1:-}"
[ -n "$MEDIA" ] || { echo "trash-media: no path given" >&2; exit 1; }

# Move one path to the system trash. Prefers gio (GNOME/glib), then trash-cli;
# falls back to an in-app Trash folder so nothing is ever hard-deleted.
trash_one() {
    f="$1"
    [ -e "$f" ] || return 0
    if command -v gio >/dev/null 2>&1 && gio trash -- "$f" 2>/dev/null; then return 0; fi
    if command -v trash-put >/dev/null 2>&1 && trash-put -- "$f" 2>/dev/null; then return 0; fi
    mkdir -p "$DATA_DIR/Trash"
    mv -f "$f" "$DATA_DIR/Trash/" 2>/dev/null || true
}

name="$(basename "$MEDIA")"
base="${name%.*}"
dir="$(dirname "$MEDIA")"

# 1) Drop the exact line from the playlist so it will not replay this session.
if [ -f "$PLAYLIST" ]; then
    tmp="$(mktemp)"
    if grep -vxF -- "$MEDIA" "$PLAYLIST" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$PLAYLIST"
    else
        rm -f "$tmp"
    fi
fi

# 2) The media itself.
trash_one "$MEDIA"

# 3) Sidecars (both "<media>.<ext>.xmp/.txt" and "<base>.xmp/.txt" layouts).
trash_one "$MEDIA.xmp"
trash_one "$dir/$base.xmp"
trash_one "$MEDIA.txt"
trash_one "$dir/$base.txt"

# 4) Every per-resolution optimized clip + its internal markers.
if [ -d "$OPT_DIR" ]; then
    for f in "$OPT_DIR"/*/"$base.mp4" "$OPT_DIR/$base.mp4"; do
        [ -e "$f" ] && trash_one "$f"
    done
    for m in "$OPT_DIR"/*/.skip_"$base" "$OPT_DIR"/*/.res_"$base" "$OPT_DIR"/*/.tmp_"$base.mp4" \
             "$OPT_DIR/.skip_$base" "$OPT_DIR/.res_$base" "$OPT_DIR/.tmp_$base.mp4"; do
        [ -e "$m" ] && rm -f "$m"
    done
fi

exit 0
