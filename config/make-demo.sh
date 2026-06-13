#!/bin/bash
# =============================================================================
#  make-demo.sh — record a smooth, high-definition demo clip of the screensaver
#  WITHOUT the usual screen-record lag.
#
#  Usage:  make-demo.sh [seconds] [output.mp4]
#            seconds   how long to record           (default 60)
#            output    where to write the clip      (default ~/screensaver-demo.mp4)
#
#  Why recording normally lags: a real-time recorder runs an H.264 encoder on the
#  CPU while the screensaver is also drawing — they fight for the machine, so the
#  app drops frames and the clip stutters. This script removes that contention:
#
#    1. If your GPU has a hardware H.264 encoder (NVIDIA NVENC, AMD/Intel VAAPI,
#       or Intel QSV), the GPU does the encoding and the CPU stays free — the app
#       runs full-speed and the capture is smooth. (This is what OBS does.)
#    2. Otherwise it captures near-LOSSLESS at the cheapest CPU setting
#       (x264 ultrafast), which barely loads the machine, then RE-ENCODES that to
#       a clean HD file AFTERWARDS — the heavy "make the best version" pass runs
#       offline, when nothing is competing with it.
#
#  Either way the recording phase stays light, so the demo doesn't lag. Records
#  the real screen at its native resolution (best quality), with the music if a
#  PulseAudio/PipewWire monitor is available.
#
#  Knobs (env):  DEMO_FPS (default 60)   DEMO_RES (e.g. 1920x1080; default = whole
#                screen)   DEMO_AUDIO=0 to skip sound   DEMO_LAUNCH=1 to start the
#                screensaver first and stop it after.
# =============================================================================
set -u
SECS="${1:-60}"
OUT="${2:-$HOME/screensaver-demo.mp4}"
SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || true
APP_DIR="${APP_DIR:-$HOME/Screensaver-App}"

command -v ffmpeg >/dev/null 2>&1 || { echo "make-demo: ffmpeg is not installed." >&2; exit 1; }

# --- Wayland can't be grabbed with x11grab; point the user at wf-recorder ------
if [ -z "${DISPLAY:-}" ] && { [ "${XDG_SESSION_TYPE:-}" = "wayland" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
    cat >&2 <<EOF
make-demo: this looks like a Wayland session (no X DISPLAY). x11grab won't work.
Record with wf-recorder instead, which can hardware-encode (also lag-free):
    wf-recorder -c h264_vaapi -f "$OUT"        # AMD/Intel
    wf-recorder -c h264_nvenc -f "$OUT"        # NVIDIA
Stop it with Ctrl-C after ~${SECS}s. (Run the screensaver first.)
EOF
    exit 1
fi
DISP="${DISPLAY:-:0}"
FPS="${DEMO_FPS:-60}"

# --- Screen geometry (native resolution unless DEMO_RES forces one) -----------
RES="${DEMO_RES:-}"
if [ -z "$RES" ]; then
    if command -v xrandr >/dev/null 2>&1; then
        RES="$(xrandr 2>/dev/null | awk '/\*/{print $1; exit}')"
    fi
    [ -z "$RES" ] && command -v xdpyinfo >/dev/null 2>&1 \
        && RES="$(xdpyinfo 2>/dev/null | awk '/dimensions:/{print $2; exit}')"
fi
[ -z "$RES" ] && RES="1920x1080"
echo "make-demo: ${RES} @ ${FPS}fps, ${SECS}s  ->  $OUT"

# --- Optionally launch the screensaver, record, then stop it ------------------
APP_PID=""
if [ "${DEMO_LAUNCH:-0}" = "1" ] && [ -x "$APP_DIR/launch.sh" ]; then
    echo "make-demo: starting the screensaver…"
    setsid bash "$APP_DIR/launch.sh" >/dev/null 2>&1 &
    APP_PID=$!
    sleep 4    # let the first photo + HUD settle before the clip starts
fi
cleanup() { [ -n "$APP_PID" ] && kill -- -"$APP_PID" 2>/dev/null; }
trap cleanup EXIT INT TERM

# --- Audio: capture what's actually playing (the monitor of the default sink) -
AUDIO_IN=()
AUDIO_ENC=(-an)
if [ "${DEMO_AUDIO:-1}" = "1" ]; then
    SINK=""
    command -v pactl >/dev/null 2>&1 && SINK="$(pactl get-default-sink 2>/dev/null)"
    if [ -n "$SINK" ]; then
        AUDIO_IN=(-f pulse -i "${SINK}.monitor")
        AUDIO_ENC=(-c:a aac -b:a 192k)
    fi
fi

VIDEO_IN=(-f x11grab -framerate "$FPS" -video_size "$RES" -i "${DISP}+0,0")

# --- Pick the encoder: hardware first (no CPU contention), else light+offline -
# Probe each encoder for real — "listed" doesn't mean the hardware is present
# (h264_nvenc lists even with no NVIDIA card), so we actually try to init it.
enc_works() { ffmpeg -hide_banner -loglevel error -f lavfi \
    -i color=c=black:s=320x240:d=0.1 -c:v "$1" -f null - >/dev/null 2>&1; }
vaapi_works() { [ -e /dev/dri/renderD128 ] && ffmpeg -hide_banner -loglevel error \
    -vaapi_device /dev/dri/renderD128 -f lavfi -i color=c=black:s=320x240:d=0.1 \
    -vf 'format=nv12,hwupload' -c:v h264_vaapi -f null - >/dev/null 2>&1; }
TMP=""
run_capture() {
    # $@ = the video-encode args; runs the single capture command.
    ffmpeg -y -hide_banner -loglevel warning \
        "${VIDEO_IN[@]}" "${AUDIO_IN[@]}" \
        -t "$SECS" "$@" "${AUDIO_ENC[@]}" -movflags +faststart "$OUT"
}

if enc_works h264_nvenc; then
    echo "make-demo: NVIDIA NVENC (GPU encode, no lag)"
    run_capture -c:v h264_nvenc -preset p5 -cq 19 -pix_fmt yuv420p
elif vaapi_works; then
    echo "make-demo: VAAPI (GPU encode, no lag)"
    ffmpeg -y -hide_banner -loglevel warning \
        -vaapi_device /dev/dri/renderD128 \
        "${VIDEO_IN[@]}" "${AUDIO_IN[@]}" -t "$SECS" \
        -vf 'format=nv12,hwupload' -c:v h264_vaapi -qp 20 \
        "${AUDIO_ENC[@]}" -movflags +faststart "$OUT"
elif enc_works h264_qsv; then
    echo "make-demo: Intel QSV (GPU encode, no lag)"
    run_capture -c:v h264_qsv -global_quality 20 -pix_fmt nv12
else
    # No hardware encoder → capture light (near-lossless, cheap CPU) then make
    # the polished HD version OFFLINE so the recording phase never lags.
    echo "make-demo: no GPU encoder — light capture, then offline encode"
    TMP="$(mktemp --suffix=.mkv)"
    ffmpeg -y -hide_banner -loglevel warning \
        "${VIDEO_IN[@]}" "${AUDIO_IN[@]}" -t "$SECS" \
        -c:v libx264 -preset ultrafast -qp 0 -c:a flac "$TMP"
    cleanup; APP_PID=""        # stop the app BEFORE the heavy encode (free the CPU)
    echo "make-demo: encoding the final HD clip (offline, ~a minute)…"
    ffmpeg -y -hide_banner -loglevel warning -i "$TMP" \
        -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p \
        -c:a aac -b:a 192k -movflags +faststart "$OUT"
    rm -f "$TMP"
fi

if [ -s "$OUT" ]; then
    echo "make-demo: done -> $OUT"
else
    echo "make-demo: recording failed (is the screensaver on screen? is $DISP correct?)" >&2
    exit 1
fi
