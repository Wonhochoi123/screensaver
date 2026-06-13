#!/bin/bash
# fetch-chart.sh TICKER W H OUTFILE — fetch a stock chart and write it as a
# W×H BGRA bitmap for the screensaver's overlay (same format as the minimap).
# Writes OUTFILE only on full success (atomic .part + mv); on any failure it
# leaves no file, so photo.lua's size guard simply shows no chart.
set -u
T="${1:-}"; W="${2:-}"; H="${3:-}"; OUT="${4:-}"
[ -n "$T" ] && [ -n "$W" ] && [ -n "$H" ] && [ -n "$OUT" ] || exit 1
case "$W$H" in *[!0-9]*) exit 1;; esac

UA="Mozilla/5.0 (X11; Linux x86_64; rv:125.0) Gecko/20100101 Firefox/125.0"
PNG="$(mktemp --suffix=.png)"; trap 'rm -f "$PNG"' EXIT

# finviz daily chart with technical overlays. Ticker is sanitised to letters,
# digits, dot and dash only.
TT="$(printf '%s' "$T" | tr -cd 'A-Za-z0-9.-')"
[ -n "$TT" ] || exit 1
URL="https://charts2.finviz.com/chart.ashx?t=${TT}&ty=c&ta=1&p=d&s=l"

curl -sL --max-time 20 -A "$UA" "$URL" -o "$PNG" 2>/dev/null || exit 1
# Must actually be a PNG (finviz serves a tiny error page for bad tickers).
[ -s "$PNG" ] && head -c8 "$PNG" | grep -q $'\x89PNG' || exit 1

if command -v magick >/dev/null 2>&1; then IM="magick"; else IM="convert"; fi
$IM "$PNG" -background "#101010" -flatten -resize "${W}x${H}!" -depth 8 \
    bgra:"$OUT.part" 2>/dev/null || { rm -f "$OUT.part"; exit 1; }
mv -f "$OUT.part" "$OUT"
exit 0
