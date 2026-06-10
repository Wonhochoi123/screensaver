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
#  Output is cached under $RES_DIR/thumbs keyed by file path + size + mtime, and
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
# Bump the version tag whenever the rendering changes, to bust stale caches.
KEY="$(printf '%s|%s|v3|%s' "$FILE" "$SIZE" "$MTIME" | md5sum | cut -d' ' -f1)"
OUT="$RES_DIR/thumbs/$KEY"

prune_cache() {   # keep only the 30 most-recently-used thumbs
    ls -1dt "$RES_DIR/thumbs"/*/ 2>/dev/null | tail -n +31 | tr '\n' '\0' | xargs -0r rm -rf
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
# Circular thumbnail with a light-grey ring baked on top (overlay-add bitmaps
# render ABOVE the ASS overlays, so the ring must live in the bitmap to frame
# the art). `-alpha set` forces an alpha channel so DstIn actually makes the
# corners transparent (covers stay opaque RGB otherwise → square thumb).
RW=$(( SIZE / 32 )); [ "$RW" -lt 1 ] && RW=1     # thin ring (≈3%)
RING=( -fill none -stroke "#C8C8C8" -strokewidth "$RW" -draw "circle $R,$R $R,$(( RW / 2 ))" )
$IM "$TMP/sq.png" -alpha set "$TMP/mask.png" -compose DstIn -composite \
    "${RING[@]}" -depth 8 "bgra:$OUT.part/color.bgra" || exit 4
$IM "$TMP/sq.png" -modulate 100,0 -alpha set "$TMP/mask.png" -compose DstIn -composite \
    "${RING[@]}" -depth 8 "bgra:$OUT.part/gray.bgra" || exit 4

# Publish atomically.
rm -rf "$OUT"
mv "$OUT.part" "$OUT"
: > "$OUT/.thumb"
prune_cache
echo "$OUT"
