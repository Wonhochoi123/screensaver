#!/bin/bash
set -u

SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || { echo "build-title: missing config $SS_CONF — run the installer." >&2; exit 1; }

YEAR="$1"
MONTH="$2"
OUT_FILE="$3"
BG="${4:-}"

# Target resolution from the live display (render at the screen's resolution,
# not a hardcoded 1080p). Falls back to 1080p until display.conf is written.
TARGET_W=1920; TARGET_H=1080
if [ -s "$APP_DIR/display.conf" ]; then
    res="$(tr -dc '0-9x' < "$APP_DIR/display.conf")"
    if [[ "$res" =~ ^([0-9]+)x([0-9]+)$ ]]; then
        TARGET_W="${BASH_REMATCH[1]}"; TARGET_H="${BASH_REMATCH[2]}"
    fi
fi

DUR=4                                    # card length (s) — matches the label
FPS=24                                   # cap fps so a 60fps video hero doesn't
                                         # balloon the render
SIGMA=$(( 50 * TARGET_W / 640 ))         # blur strength == the app's (50 @ 640w)
[ "$SIGMA" -lt 1 ] && SIGMA=1

TMP_DIR="$(mktemp -d)"
OUT_TMP=""
trap 'rm -rf "$TMP_DIR"; [ -n "${OUT_TMP:-}" ] && rm -f "$OUT_TMP"' EXIT
TMP_ASS="$TMP_DIR/title.ass"
BG_PNG="$TMP_DIR/bg.png"

# Classify the hero. Background is resized to FILL the frame (stretch, no crop —
# it's blurred to mush anyway, so nothing is cut and nothing is lost), then
# blurred at full resolution. Same look as the app's other blurs.
bg_kind="none"
if [ -n "$BG" ] && [ -s "$BG" ]; then
    ext="${BG##*.}"
    case "${ext,,}" in
        mp4|mkv|mov|m4v|webm) bg_kind="video" ;;
        *)                    bg_kind="image" ;;
    esac
fi

# An image hero is blurred ONCE to a still and looped. A video hero is blurred
# per frame in the compose step (motion hides any savings, and encode dominates
# the time anyway, so we keep it full-res for one consistent blur path).
if [ "$bg_kind" = "image" ]; then
    if ! { ffmpeg -v error -nostdin -y -i "$BG" \
            -vf "scale=${TARGET_W}:${TARGET_H},setsar=1,gblur=sigma=${SIGMA},setsar=1" \
            -frames:v 1 "$BG_PNG" 2>/dev/null && [ -s "$BG_PNG" ]; }; then
        bg_kind="none"   # unreadable image (e.g. HEIC w/o decoder) -> black card
    fi
fi

# Animated text: letters reveal one by one, then the whole label drifts a slow
# zoom-in until the card ends.
python3 - "$YEAR" "$MONTH" "$TMP_ASS" "$TARGET_W" "$TARGET_H" "$DUR" <<'PY'
import sys, random
year, month, out_ass = sys.argv[1], sys.argv[2], sys.argv[3]
W, H, DUR = int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])

sc = H / 1080.0
def s(v): return max(1, int(round(v * sc)))

fs_year,  fsp_year  = s(50),  s(40)
fs_month, fsp_month = s(120), s(50)
cx, cy = W // 2, H // 2

tokens = ["{\\fs%d\\fsp%d}" % (fs_year, fsp_year)] + list(year) + ["\\N", "\\N"] \
       + ["{\\fs%d\\fsp%d}" % (fs_month, fsp_month)] + list(month.upper())
target_indices = [i for i, t in enumerate(tokens) if not t.startswith("{") and t != "\\N"]

# Outline=0, Shadow=0 -> no frames, no drop shadow. Just white glyphs.
ass_header = f"""[Script Info]
ScriptType: v4.00+
PlayResX: {W}
PlayResY: {H}

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Montserrat ExtraBold,{fs_month},&H00FFFFFF,&H000000FF,&H00FFFFFF,&H00000000,0,0,0,0,100,100,0,0,1,0,0,5,0,0,0,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""

# Pass 1: per-letter reveal timings (so we know when the build *completes*).
random.seed(year + month)
timings = []
for target_i in target_indices:
    start_t = random.randint(100, 1500)
    end_t = start_t + random.randint(500, 800)
    timings.append((target_i, start_t, end_t))

# Zoom begins once the last letter lands and runs to the end (through the
# fade-out), growing the whole label ~12%.
end_ms     = DUR * 1000
zoom_start = max((e for _, _, e in timings), default=0)
zoom_end   = end_ms
ZOOM       = 112

lines = []
for target_i, start_t, end_t in timings:
    # Line-level zoom is uniform across every line (all share \an5\pos(cx,cy)
    # and identical layout), so the label scales as one piece.
    lead = f"{{\\an5\\pos({cx},{cy})\\t({zoom_start},{zoom_end},\\fscx{ZOOM}\\fscy{ZOOM})}}"
    line_str = ""
    for i, t in enumerate(tokens):
        if t.startswith("{") or t == "\\N":
            line_str += t
        elif i == target_i:
            # reveal to &H40& == 0.75 opacity (00=opaque, FF=clear)
            line_str += f"{{\\alpha&HFF&\\t({start_t},{end_t},\\alpha&H40&)}}{t}{{\\alpha&HFF&}}"
        else:
            line_str += f"{{\\alpha&HFF&}}{t}{{\\alpha&HFF&}}"
    lines.append(f"Dialogue: 0,00:00:00.00,00:00:0{DUR}.00,Default,,0,0,0,,{lead}{line_str}")

with open(out_ass, "w") as f:
    f.write(ass_header)
    f.write("\n".join(lines))
PY

# Compose. Video hero -> blur per frame; image hero -> loop the pre-blurred
# still; nothing usable -> plain black.
case "$bg_kind" in
    video) VID_IN=(-stream_loop -1 -i "$BG"); VF_BG="scale=${TARGET_W}:${TARGET_H},setsar=1,gblur=sigma=${SIGMA},setsar=1," ;;
    image) VID_IN=(-loop 1 -i "$BG_PNG");     VF_BG="" ;;
    *)     VID_IN=(-f lavfi -i "color=c=black:s=${TARGET_W}x${TARGET_H}"); VF_BG="" ;;
esac

OUT_TMP="${OUT_FILE}.part.$$.mp4"
if ffmpeg -v error -nostdin -y \
        "${VID_IN[@]}" \
        -f lavfi -i "anullsrc=r=44100:cl=stereo" \
        -map 0:v:0 -map 1:a:0 -r "$FPS" -t "$DUR" \
        -vf "${VF_BG}ass='${TMP_ASS}':fontsdir='${FONT_DIR}',fade=t=out:st=3.2:d=0.8,format=yuv420p" \
        -c:v libx264 -preset fast -crf 22 -c:a aac "$OUT_TMP"; then
    mv -f "$OUT_TMP" "$OUT_FILE"
    OUT_TMP=""
else
    exit 1
fi
