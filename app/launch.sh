#!/bin/bash
pgrep -f "Screensaver-App/config" >/dev/null 2>&1 && exit 0

# --- Load central config (single source of truth; required) ------------------
SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || { echo "Screensaver: missing config $SS_CONF — run the installer." >&2; exit 1; }

# --- Self-healing: recreate any folder that was deleted ----------------------
mkdir -p "$MEDIA_DIR" "$MUSIC_DIR" "$MUSIC_DIR/ScreenSaver" "$MUSIC_DIR/GrokMorning" \
         "$TITLE_DIR" "$PLAYLIST_DIR" "$RES_DIR" "$RES_DIR/geo" "$OPT_DIR" "$FONT_DIR"

# Sweep away half-written title cards left behind by an interrupted build
# (build-title.sh renames a "<card>.part.<pid>.mp4" into place; a kill leaves it).
rm -f "$TITLE_DIR"/*.part.*.mp4 2>/dev/null || true

command -v exiftool >/dev/null 2>&1 || \
    echo "WARN: exiftool not found - date/location HUD will be disabled. Run setup-screensaver.sh to install deps." >&2

# --- Build the offline place DB once, in the background, if it's missing or -
#     out of date. Runs whether GEONAMES_COUNTRIES lists specific countries or
#     is empty (empty = whole planet, ~390MB download on first build).
#     Backgrounded so the slideshow starts immediately; landmarks light up once
#     it finishes. A GEODB_VERSION change forces a one-time rebuild.
geodb_needs_build=0
if [ ! -s "${GEODB:-/nonexistent}" ]; then
    geodb_needs_build=1
elif [ "$(cat "${GEODB}.version" 2>/dev/null)" != "${GEODB_VERSION:-1}" ]; then
    geodb_needs_build=1
fi
if [ "$geodb_needs_build" = 1 ] && command -v unzip >/dev/null 2>&1; then
    ( "$CFG_DIR/build-geodb.sh" >/dev/null 2>&1 & )
fi

MUSIC_PID=""
POLICE_PID=""
VID_PID=""
MPV_LOAD_PID=""
GROK_PID=""
LOAD_SOCK=""

cleanup() {
    [ -n "$MUSIC_PID" ]    && kill "$MUSIC_PID" 2>/dev/null
    [ -n "$POLICE_PID" ]   && kill "$POLICE_PID" 2>/dev/null
    [ -n "$VID_PID" ]      && kill "$VID_PID" 2>/dev/null
    [ -n "$MPV_LOAD_PID" ] && kill "$MPV_LOAD_PID" 2>/dev/null
    [ -n "$GROK_PID" ]     && kill "$GROK_PID" 2>/dev/null
    [ -f /tmp/ss_briefing_ffplay.pid ] && kill "$(cat /tmp/ss_briefing_ffplay.pid 2>/dev/null)" 2>/dev/null
    [ -f /tmp/ss_briefing.pid ]        && kill "$(cat /tmp/ss_briefing.pid 2>/dev/null)" 2>/dev/null
    rm -f "$AUDIO_SOCK" "${LOAD_SOCK:-}" /tmp/ss_briefing.txt /tmp/ss_briefing.pid /tmp/ss_briefing_ffplay.pid
}
trap cleanup EXIT INT TERM

rm -f "$AUDIO_SOCK"

nice -n 19 "$POLICE" >/dev/null 2>&1 &
POLICE_PID=$!

"$APP_DIR/vid-daemon.sh" >/dev/null 2>&1 &
VID_PID=$!

# Slideshow music plays from Music/ScreenSaver (Music/GrokMorning is the
# briefing's own bgm); fall back to the whole Music folder if that's empty.
SS_MUSIC="$MUSIC_DIR/ScreenSaver"
[ -n "$(ls -A "$SS_MUSIC" 2>/dev/null)" ] || SS_MUSIC="$MUSIC_DIR"
if [ -d "$SS_MUSIC" ] && [ -n "$(ls -A "$SS_MUSIC" 2>/dev/null)" ]; then
    mpv --no-video --loop-playlist=inf --shuffle --input-ipc-server="$AUDIO_SOCK" "$SS_MUSIC" >/dev/null 2>&1 &
    MUSIC_PID=$!
fi

# Morning briefing scheduler (exits immediately + silently unless enabled with
# a valid XAI key; see GROK_* in screensaver.conf).
"$CFG_DIR/grok-briefing.sh" --watch >/dev/null 2>&1 &
GROK_PID=$!

# =============================================================================
# CHRONOLOGICAL PLAYLIST BUILDER  (sidecar-driven, rebuilt every launch)
#   * EXTRACTION (police --once) stays INCREMENTAL.
#   * ASSEMBLY runs UNCONDITIONALLY and reconciles media / sidecars / playlist,
#     including dropping deleted media.
#   HEAVY only decides whether to show the loading screen.
# =============================================================================
_SS_MC="$(find "$MEDIA_DIR" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \
       -o -iname '*.tif' -o -iname '*.tiff' -o -iname '*.heic' -o -iname '*.heif' \
       -o -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.m4v' \
       -o -iname '*.webm' \) -print 2>/dev/null | wc -l)"

HEAVY=0
HEAVY_REASON="startup"
if [ ! -f "$PLAYLIST" ]; then
    HEAVY=1; HEAVY_REASON="first-run"
elif [ -z "$(ls -A "$TITLE_DIR" 2>/dev/null)" ]; then
    HEAVY=1; HEAVY_REASON="first-run"
elif [ -n "$(find "$MEDIA_DIR" -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \
           -o -iname '*.tif' -o -iname '*.tiff' -o -iname '*.heic' -o -iname '*.heif' \
           -o -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.m4v' \
           -o -iname '*.webm' -o -iname '*.txt' \) \
        -newer "$PLAYLIST" -print -quit 2>/dev/null)" ]; then
    HEAVY=1; HEAVY_REASON="new-media"
fi

# A resolution change re-renders every title card (their cached fingerprint
# embeds the display resolution), which is slow — show the loading screen for
# that too. The fingerprint is "<WxH>|<hero>"; compare its resolution half.
if [ "$HEAVY" = 0 ]; then
    CUR_RES="$(tr -dc '0-9x' < "$APP_DIR/display.conf" 2>/dev/null || true)"
    if [ -n "$CUR_RES" ]; then
        for f in "$TITLE_DIR"/.src_*; do
            [ -f "$f" ] || continue
            fp="$(cat "$f" 2>/dev/null)"
            [ "${fp%%|*}" != "$CUR_RES" ] && { HEAVY=1; HEAVY_REASON="resolution"; break; }
        done
    fi
fi

# Also trigger if media count changed — catches files copied with old timestamps
# (e.g. photos from a camera whose mtime is older than the playlist).
if [ "$HEAVY" = 0 ] && \
   [ "$_SS_MC" != "$(cat "$APP_DIR/media.count" 2>/dev/null)" ]; then
    HEAVY=1; HEAVY_REASON="new-media"
fi

# Map reason to on-screen title + subtitle.
case "$HEAVY_REASON" in
    first-run)  _SS_TITLE="BUILDING LIBRARY";  _SS_SUB="Setting up your screensaver..." ;;
    new-media)  _SS_TITLE="UPDATING LIBRARY";  _SS_SUB="New media detected..." ;;
    resolution) _SS_TITLE="UPDATING LIBRARY";  _SS_SUB="Display resolution changed..." ;;
    *)          _SS_TITLE="LOADING";            _SS_SUB="Starting up..." ;;
esac

# Detect actual screen resolution so the loading screen fills the display.
_SS_W=1920; _SS_H=1080
if [ -f "$APP_DIR/display.conf" ]; then
    _SS_DR="$(tr -dc '0-9x' < "$APP_DIR/display.conf" 2>/dev/null)"
    case "$_SS_DR" in
        *x*) _SS_W="${_SS_DR%x*}"; _SS_H="${_SS_DR#*x}" ;;
    esac
fi

# Always start with the black loading screen so the user sees something
# immediately. photo.lua shows a context-specific message; when the playlist
# is ready loadlist-replace hands off to real content in the same process.
LOAD_SOCK="/tmp/ss_load_$$.sock"
rm -f "$LOAD_SOCK"
mpv --config-dir="$CFG_DIR" \
    --sub-fonts-dir="$FONT_DIR" \
    --title="Start Screensaver" --x11-name="StartScreensaver" \
    --image-display-duration="$PHOTO_DURATION" \
    --volume=0 \
    --input-ipc-server="$LOAD_SOCK" \
    "av://lavfi:color=c=black:s=${_SS_W}x${_SS_H}" \
    >/dev/null 2>&1 &
MPV_LOAD_PID=$!
# Wait for IPC socket (up to 5s)
_w=0
while [ ! -S "$LOAD_SOCK" ] && [ $_w -lt 50 ]; do
    sleep 0.1; _w=$((_w+1))
done
# Push a live status line to the loading overlay (no-op once handed off).
_ss_load_msg() {
    [ -S "$LOAD_SOCK" ] || return 0
    printf '{"command":["script-message","ss-show-loading","%s","%s"]}\n' "$1" "$2" | \
        socat -t 1 - "UNIX-CONNECT:$LOAD_SOCK" 2>/dev/null
}

# Ask photo.lua to show the loading overlay with a context-specific message.
_ss_load_msg "$_SS_TITLE" "$_SS_SUB"

# Capture the REAL screen size straight from the running (fullscreen) mpv and
# record it, so the build below — title cards especially — renders at the true
# resolution/aspect on the very first run too, never a hardcoded 1080p.
_w=0
while [ $_w -lt 30 ]; do
    _dw="$(printf '{"command":["get_property","display-width"]}\n' | socat -t1 - "UNIX-CONNECT:$LOAD_SOCK" 2>/dev/null | grep -o '"data":[0-9]\+' | grep -o '[0-9]\+' | head -1)"
    _dh="$(printf '{"command":["get_property","display-height"]}\n' | socat -t1 - "UNIX-CONNECT:$LOAD_SOCK" 2>/dev/null | grep -o '"data":[0-9]\+' | grep -o '[0-9]\+' | head -1)"
    if [ -n "${_dw:-}" ] && [ -n "${_dh:-}" ] && [ "$_dw" -ge 320 ] && [ "$_dh" -ge 320 ]; then
        printf '%sx%s' "$_dw" "$_dh" > "$APP_DIR/display.conf"
        _SS_W="$_dw"; _SS_H="$_dh"
        break
    fi
    sleep 0.1; _w=$((_w+1))
done

_ss_load_msg "$_SS_TITLE" "Reading photo metadata..."
"$POLICE" --once

# The sidecars are tiny XML files xmp-police just wrote in a fixed format, so
# read the dates straight out of them — no second full exiftool pass over the
# library (the police already ran exiftool on everything that needed it).
python3 - "$MEDIA_DIR" <<'PY' > "$PLAYLIST.raw"
import sys, os, re
mdir = sys.argv[1]
pats = [re.compile(r"<%s>([^<]*)</%s>" % (t, t)) for t in
        ("exif:DateTimeOriginal", "xmp:CreateDate", "photoshop:DateCreated")]
try:
    names = os.listdir(mdir)
except Exception:
    names = []
rows = []
for n in names:
    if not n.lower().endswith(".xmp"):
        continue
    xmp = os.path.join(mdir, n)
    media = xmp[:-4]
    if not os.path.isfile(xmp) or not os.path.exists(media):
        continue
    try:
        txt = open(xmp, encoding="utf-8", errors="ignore").read()
    except Exception:
        continue
    d = ""
    for p in pats:
        m = p.search(txt)
        if m:
            d = m.group(1)
            break
    d = "".join(c for c in d if c.isdigit())
    if len(d) < 6:
        d = "99999999999999"
    rows.append((d, media))
rows.sort()
for d, m in rows:
    print(d + "|" + m)
PY

# --- Pick each month's "hero" for the title-card background. Videos win when a
#     month has one (used only for the card's ~4s); otherwise the largest still.
#     A month with neither falls through to a black card in build-title.sh.
DISPLAY_RES="$(tr -dc '0-9x' < "$APP_DIR/display.conf" 2>/dev/null || true)"
declare -A HERO_VIDEO HERO_VSIZE HERO_PHOTO HERO_PSIZE
while IFS='|' read -r D PATH_STR; do
    [ -e "$PATH_STR" ] || continue
    [[ "$D" == "99999999999999" || ${#D} -lt 6 ]] && continue
    YM="${D:0:6}"
    sz="$(stat -c '%s' "$PATH_STR" 2>/dev/null || echo 0)"
    ext="${PATH_STR##*.}"
    case "${ext,,}" in
        mp4|mkv|mov|m4v|webm)
            if [ "${HERO_VSIZE[$YM]:-0}" -lt "$sz" ]; then
                HERO_VSIZE[$YM]="$sz"; HERO_VIDEO[$YM]="$PATH_STR"
            fi ;;
        jpg|jpeg|png|webp|tif|tiff|heic|heif|gif)
            if [ "${HERO_PSIZE[$YM]:-0}" -lt "$sz" ]; then
                HERO_PSIZE[$YM]="$sz"; HERO_PHOTO[$YM]="$PATH_STR"
            fi ;;
    esac
done < "$PLAYLIST.raw"



echo "#EXTM3U" > "$PLAYLIST.tmp"
declare -A M_NAMES=( ["01"]="January" ["02"]="February" ["03"]="March" ["04"]="April" ["05"]="May" ["06"]="June" ["07"]="July" ["08"]="August" ["09"]="September" ["10"]="October" ["11"]="November" ["12"]="December" )

LAST_YM=""
while IFS='|' read -r D PATH_STR; do
    [ -e "$PATH_STR" ] || continue
    if [[ "$D" != "99999999999999" && ${#D} -ge 6 ]]; then
        YM="${D:0:6}"
        if [[ "$YM" != "$LAST_YM" ]]; then
            LAST_YM="$YM"
            Y="${YM:0:4}"
            M="${YM:4:2}"
            M_NAME="${M_NAMES[$M]}"
            if [ -n "$M_NAME" ]; then
                CARD_PATH="$TITLE_DIR/${Y}-${M_NAME}.mp4"
                HERO="${HERO_VIDEO[$YM]:-${HERO_PHOTO[$YM]:-}}"
                # A card's inputs are its hero photo + the display resolution.
                # Rebuild whenever either changes (new biggest photo, a photo's
                # XMP date moving it across months, or a resolution change), or
                # when the hero file itself is newer than the card.
                FP_FILE="$TITLE_DIR/.src_${Y}-${M_NAME}"
                FP_NOW="${DISPLAY_RES}|${HERO}"
                FP_OLD="$(cat "$FP_FILE" 2>/dev/null || true)"
                need_card=0
                if [ ! -f "$CARD_PATH" ]; then need_card=1
                elif [ "$FP_NOW" != "$FP_OLD" ]; then need_card=1
                elif [ -n "$HERO" ] && [ "$HERO" -nt "$CARD_PATH" ]; then need_card=1
                fi
                if [ "$need_card" = 1 ]; then
                    echo "  Generating Animated Title Card: $M_NAME $Y..."
                    _ss_load_msg "$_SS_TITLE" "Creating title card — $M_NAME $Y"
                    if "$CFG_DIR/build-title.sh" "$Y" "$M_NAME" "$CARD_PATH" "$HERO"; then
                        printf '%s' "$FP_NOW" > "$FP_FILE"
                    fi
                fi
                echo "#EXTINF:-1,$M_NAME $Y" >> "$PLAYLIST.tmp"
                [ -f "$CARD_PATH" ] && echo "$CARD_PATH" >> "$PLAYLIST.tmp"
            fi
        fi
    fi
    echo "$PATH_STR" >> "$PLAYLIST.tmp"
done < "$PLAYLIST.raw"

mv "$PLAYLIST.tmp" "$PLAYLIST"
rm -f "$PLAYLIST.raw"
echo "$_SS_MC" > "$APP_DIR/media.count"

if [ -S "$LOAD_SOCK" ]; then
    # Playlist is ready — restore volume and hand off to the real content.
    # photo.lua clears the loading overlay automatically on the first file-loaded.
    printf '{"command":["set_property","volume",%s]}\n' "$VOLUME" | \
        socat -t 3 - "UNIX-CONNECT:$LOAD_SOCK" 2>/dev/null
    printf '{"command":["loadlist","%s","replace"]}\n' "$PLAYLIST" | \
        socat -t 3 - "UNIX-CONNECT:$LOAD_SOCK" 2>/dev/null
    rm -f "$LOAD_SOCK"; LOAD_SOCK=""
    wait "$MPV_LOAD_PID"
else
    # Fallback: IPC socket never appeared (mpv failed to start).
    mpv --config-dir="$CFG_DIR" \
        --sub-fonts-dir="$FONT_DIR" \
        --title="Start Screensaver" --x11-name="StartScreensaver" \
        --image-display-duration="$PHOTO_DURATION" \
        --volume="$VOLUME" \
        --playlist="$PLAYLIST"
fi
