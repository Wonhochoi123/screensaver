#!/bin/bash
# =============================================================================
#  fix-flac.sh — standalone FLAC health check + repair (NOT part of the
#  screensaver install; run it by hand).
#
#  Why: a FLAC whose STREAMINFO has no/!wrong total-samples reports no duration,
#  which makes anything position-based (a progress bar, seeking) misbehave. This
#  scans your files and can losslessly re-encode the broken ones so their
#  duration is correct again — tags AND embedded cover art are preserved.
#
#  Usage:
#    fix-flac.sh [DIR]              scan only (read-only; default DIR = the
#                                   screensaver's Music folder, else .)
#    fix-flac.sh [DIR] --fix        repair the flagged files in place
#    fix-flac.sh [DIR] --fix --all  repair EVERY .flac, not just the flagged ones
#
#  Originals are moved to DIR/.flac-backup/ before replacement; nothing is
#  overwritten until the re-encoded copy is verified to have a real duration.
# =============================================================================
set -u

DIR=""; DOFIX=0; ALL=0
for a in "$@"; do
    case "$a" in
        --fix) DOFIX=1 ;;
        --all) ALL=1 ;;
        *)     DIR="$a" ;;
    esac
done

# Default to the screensaver's Music dir if no dir given.
if [ -z "$DIR" ]; then
    CONF="$HOME/Screensaver-App/config/screensaver.conf"
    [ -f "$CONF" ] && . "$CONF" 2>/dev/null
    DIR="${MUSIC_DIR:-.}"
fi
[ -d "$DIR" ] || { echo "fix-flac: not a directory: $DIR" >&2; exit 1; }

command -v ffprobe >/dev/null 2>&1 || { echo "fix-flac: ffprobe (ffmpeg) is required." >&2; exit 1; }
command -v ffmpeg  >/dev/null 2>&1 || { echo "fix-flac: ffmpeg is required." >&2; exit 1; }
HAVE_FLAC=0; command -v flac >/dev/null 2>&1 && HAVE_FLAC=1   # optional, better integrity test

dur_of() { ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$1" 2>/dev/null; }
hhmmss() { awk -v s="$1" 'BEGIN{ if(s<=0){print "—";exit} printf "%d:%02d", int(s/60), int(s%60) }'; }

BACKUP="$DIR/.flac-backup"
n_ok=0; n_bad=0; n_fixed=0; n_failed=0
flagged=()

echo "Scanning: $DIR"
while IFS= read -r -d '' f; do
    dur="$(dur_of "$f")"
    bad=""
    if [ -z "$dur" ] || awk -v d="$dur" 'BEGIN{exit !(d+0 <= 0)}'; then
        bad="no-duration"
    elif [ "$HAVE_FLAC" = 1 ] && ! flac -ts "$f" >/dev/null 2>&1; then
        bad="corrupt"
    fi
    if [ -n "$bad" ]; then
        printf '  %-11s %s\n' "$bad" "$(basename "$f")"
        n_bad=$((n_bad+1)); flagged+=("$f")
    else
        printf '  %-11s %s  (%s)\n' "ok" "$(basename "$f")" "$(hhmmss "$dur")"
        n_ok=$((n_ok+1))
    fi
done < <(find "$DIR" -maxdepth 1 -type f \( -iname '*.flac' \) -print0 2>/dev/null | sort -z)

echo "Summary: $n_ok ok, $n_bad flagged"

if [ "$DOFIX" != 1 ]; then
    [ "$n_bad" -gt 0 ] && echo "Run again with --fix to repair the flagged files (originals backed up to $BACKUP)."
    exit 0
fi

# --- repair -----------------------------------------------------------------
targets=()
if [ "$ALL" = 1 ]; then
    while IFS= read -r -d '' f; do targets+=("$f"); done \
        < <(find "$DIR" -maxdepth 1 -type f -iname '*.flac' -print0 2>/dev/null)
else
    targets=("${flagged[@]}")
fi
[ "${#targets[@]}" -eq 0 ] && { echo "Nothing to fix."; exit 0; }

mkdir -p "$BACKUP"
for f in "${targets[@]}"; do
    base="$(basename "$f")"
    tmp="$(mktemp --suffix=.flac)"
    # Re-encode the audio (rebuilds a correct STREAMINFO/seektable); copy every
    # other stream (cover art) and all tags verbatim.
    if ffmpeg -v error -nostdin -y -i "$f" -map 0 -c:a flac -compression_level 8 \
              -c:v copy -map_metadata 0 "$tmp" 2>/dev/null \
       && [ -s "$tmp" ] && awk -v d="$(dur_of "$tmp")" 'BEGIN{exit !(d+0 > 0)}'; then
        mv -f "$f" "$BACKUP/$base"
        mv -f "$tmp" "$f"
        printf '  fixed  %s  (%s)\n' "$base" "$(hhmmss "$(dur_of "$f")")"
        n_fixed=$((n_fixed+1))
    else
        rm -f "$tmp"
        printf '  FAILED %s  (left untouched)\n' "$base"
        n_failed=$((n_failed+1))
    fi
done
echo "Repaired: $n_fixed, failed: $n_failed.  Originals are in $BACKUP"
