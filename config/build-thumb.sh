#!/bin/bash
# =============================================================================
#  build-thumb.sh — extract a music file's embedded cover art and pre-render a
#  ring of circular, rotated BGRA frames the HUD can cycle to "spin" the thumb.
#
#  Usage:   build-thumb.sh <music-file> <size-px> [frames]
#  Prints:  the output directory (containing f000.bgra … and .frames) on success.
#  Exits non-zero and prints nothing when the file has no embedded cover.
#
#  Frames are cached under $MAP_DIR/thumbs keyed by file path + size + mtime, so
#  a track that comes round again in the shuffle is not re-rendered.
# =============================================================================
set -u
SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || { echo "build-thumb: missing config" >&2; exit 1; }

FILE="${1:-}"; SIZE="${2:-128}"; FRAMES="${3:-24}"
[ -f "$FILE" ] || exit 1
command -v ffmpeg >/dev/null 2>&1 || exit 1
if command -v magick >/dev/null 2>&1; then IM="magick"; else IM="convert"; fi

MTIME="$(stat -c '%Y' "$FILE" 2>/dev/null || echo 0)"
KEY="$(printf '%s|%s|%s|%s' "$FILE" "$SIZE" "$FRAMES" "$MTIME" | md5sum | cut -d' ' -f1)"
OUT="$MAP_DIR/thumbs/$KEY"

# Keep the thumb cache bounded: only the 30 most-recently-used sets survive.
prune_cache() {
    ls -1dt "$MAP_DIR/thumbs"/*/ 2>/dev/null | tail -n +31 | tr '\n' '\0' | xargs -0r rm -rf
}

# Cached already? (a complete run leaves .frames last). Touch it so it counts as
# recently used, then prune.
if [ -f "$OUT/.frames" ]; then
    touch "$OUT" 2>/dev/null
    prune_cache
    echo "$OUT"; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Pull the embedded cover (mp3 APIC / FLAC PICTURE / m4a / etc.). No video
# stream => no cover => signal "none" so the HUD shows an empty circle.
ffmpeg -v error -y -i "$FILE" -an -map 0:v:0 -frames:v 1 "$TMP/cover.png" 2>/dev/null || exit 2
[ -s "$TMP/cover.png" ] || exit 2

# Square the cover (center-crop) at SIZE, and a white circle mask of diameter
# SIZE. The circle inscribed in the SIZE×SIZE square stays fully covered at every
# rotation angle, so spinning the square never exposes a gap at the rim.
$IM "$TMP/cover.png" -resize "${SIZE}x${SIZE}^" -gravity center -extent "${SIZE}x${SIZE}" "$TMP/sq.png" || exit 3
R=$(( SIZE / 2 ))
$IM -size "${SIZE}x${SIZE}" xc:none -fill white -draw "circle $R,$R $R,0" "$TMP/mask.png" || exit 3

mkdir -p "$OUT.part"
i=0
while [ "$i" -lt "$FRAMES" ]; do
    ang=$(( 360 * i / FRAMES ))
    f="$(printf 'f%03d.bgra' "$i")"
    $IM "$TMP/sq.png" -background none -rotate "$ang" \
        -gravity center -extent "${SIZE}x${SIZE}" \
        "$TMP/mask.png" -compose DstIn -composite \
        -depth 8 "bgra:$OUT.part/$f" || exit 4
    i=$(( i + 1 ))
done

# Publish atomically: a complete frame set, then the .frames marker.
rm -rf "$OUT"
mv "$OUT.part" "$OUT"
echo "$FRAMES" > "$OUT/.frames"
prune_cache
echo "$OUT"
