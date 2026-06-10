#!/bin/bash
# =============================================================================
#  build-thumb.sh — extract a music file's embedded cover art and render two
#  circular BGRA thumbnails the HUD can blit: color.bgra (playing) and gray.bgra
#  (paused, so you can see at a glance the music is stopped).
#
#  Usage:   build-thumb.sh <music-file> <size-px>
#  Prints:  the output directory (containing color.bgra, gray.bgra, .thumb) on
#           success. Exits non-zero and prints nothing when there is no cover.
#
#  Output is cached under $MAP_DIR/thumbs keyed by file path + size + mtime, and
#  the cache is bounded to the 30 most-recently-used thumbs.
# =============================================================================
set -u
SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || { echo "build-thumb: missing config" >&2; exit 1; }

FILE="${1:-}"; SIZE="${2:-128}"
[ -f "$FILE" ] || exit 1
command -v ffmpeg >/dev/null 2>&1 || exit 1
if command -v magick >/dev/null 2>&1; then IM="magick"; else IM="convert"; fi

MTIME="$(stat -c '%Y' "$FILE" 2>/dev/null || echo 0)"
KEY="$(printf '%s|%s|%s' "$FILE" "$SIZE" "$MTIME" | md5sum | cut -d' ' -f1)"
OUT="$MAP_DIR/thumbs/$KEY"

prune_cache() {   # keep only the 30 most-recently-used thumbs
    ls -1dt "$MAP_DIR/thumbs"/*/ 2>/dev/null | tail -n +31 | tr '\n' '\0' | xargs -0r rm -rf
}

if [ -f "$OUT/.thumb" ]; then
    touch "$OUT" 2>/dev/null
    prune_cache
    echo "$OUT"; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Pull the embedded cover (mp3 APIC / FLAC PICTURE / m4a / …). No video stream =>
# no cover => signal "none" so the HUD shows an empty ring.
ffmpeg -v error -y -i "$FILE" -an -map 0:v:0 -frames:v 1 "$TMP/cover.png" 2>/dev/null || exit 2
[ -s "$TMP/cover.png" ] || exit 2

# Square the cover (center-crop, no distortion, no black bars) and a circle mask.
$IM "$TMP/cover.png" -resize "${SIZE}x${SIZE}^" -gravity center -extent "${SIZE}x${SIZE}" "$TMP/sq.png" || exit 3
R=$(( SIZE / 2 ))
$IM -size "${SIZE}x${SIZE}" xc:none -fill white -draw "circle $R,$R $R,0" "$TMP/mask.png" || exit 3

mkdir -p "$OUT.part"
# Color version, then a desaturated (grayscale) version — both masked to the circle.
$IM "$TMP/sq.png" "$TMP/mask.png" -compose DstIn -composite -depth 8 "bgra:$OUT.part/color.bgra" || exit 4
$IM "$TMP/sq.png" -modulate 100,0 "$TMP/mask.png" -compose DstIn -composite -depth 8 "bgra:$OUT.part/gray.bgra" || exit 4

# Publish atomically.
rm -rf "$OUT"
mv "$OUT.part" "$OUT"
: > "$OUT/.thumb"
prune_cache
echo "$OUT"
