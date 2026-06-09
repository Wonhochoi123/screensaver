#!/bin/bash
set -u

SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || { echo "vid-daemon: missing config $SS_CONF — run the installer." >&2; exit 1; }

LOG_FILE="$APP_DIR/vid-daemon.log"
STATUS_FILE="$APP_DIR/vid-status"

mkdir -p "$OPT_DIR"
touch "$LOG_FILE"

log() { echo "[$(date +'%H:%M:%S')] $*" >> "$LOG_FILE"; }

FFMPEG_PID=""
WATCHER_PID=""
SLEEP_PID=""

shutdown() {
    log "↘ Signal received, shutting down."
    for p in "$FFMPEG_PID" "$WATCHER_PID" "$SLEEP_PID"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null
    done
    if [ -n "$FFMPEG_PID" ]; then
        for _ in 1 2 3; do
            kill -0 "$FFMPEG_PID" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$FFMPEG_PID" 2>/dev/null
    fi
    rm -f "$STATUS_FILE" "$STATUS_FILE.raw"
    exit 0
}
trap shutdown INT TERM HUP

echo "idle" > "$STATUS_FILE"

while command -v ffmpeg >/dev/null 2>&1; do

    while IFS= read -r -d '' vid; do
        [ -f "$vid" ] || continue

        filename="$(basename "$vid")"
        base="${filename%.*}"

        TARGET_W=3840; TARGET_H=2160
        DISPLAY_CONF="$APP_DIR/display.conf"
        if [ -s "$DISPLAY_CONF" ]; then
            res="$(tr -dc '0-9x' < "$DISPLAY_CONF")"
            if [[ "$res" =~ ^([0-9]+)x([0-9]+)$ ]]; then
                TARGET_W="${BASH_REMATCH[1]}"; TARGET_H="${BASH_REMATCH[2]}"
            fi
        fi
        TARGET="fp1-${TARGET_W}x${TARGET_H}"

        # Encode into a per-resolution folder so switching monitors/TVs reuses an
        # existing folder instead of re-encoding every clip each time.
        OUT_SUBDIR="$OPT_DIR/${TARGET_W}x${TARGET_H}"
        mkdir -p "$OUT_SUBDIR"
        out_file="$OUT_SUBDIR/${base}.mp4"
        skip_marker="$OUT_SUBDIR/.skip_${base}"
        res_marker="$OUT_SUBDIR/.res_${base}"
        tmp_file="$OUT_SUBDIR/.tmp_${base}.mp4"
        prev_res="$(cat "$res_marker" 2>/dev/null || true)"

        if [ -f "$out_file" ]; then
            if [ "$vid" -nt "$out_file" ] || [ "$prev_res" != "$TARGET" ]; then
                if [ "$prev_res" != "$TARGET" ]; then
                    log "↻ Re-optimizing (target ${prev_res:-none}→$TARGET): $filename"
                else
                    log "↻ Re-optimizing (source changed): $filename"
                fi
                rm -f "$out_file" "$skip_marker" "$res_marker"
            fi
        elif [ -f "$skip_marker" ]; then
            if [ "$vid" -nt "$skip_marker" ] || [ "$prev_res" != "$TARGET" ]; then
                rm -f "$skip_marker" "$res_marker"
            fi
        fi
        [ -f "$out_file" ] && continue
        [ -f "$skip_marker" ] && continue

        PROBE=$(python3 - "$vid" "$TARGET_W" "$TARGET_H" <<'PY'
import sys, subprocess, json
try:
    vid = sys.argv[1]
    tw = float(sys.argv[2]); th = float(sys.argv[3])
    out = subprocess.check_output(
        ['ffprobe', '-v', 'error', '-select_streams', 'v:0',
         '-show_streams', '-show_entries', 'format=duration',
         '-print_format', 'json', vid],
        stdin=subprocess.DEVNULL
    ).decode('utf-8')
    d = json.loads(out)
    s = d['streams'][0]
    dur = float(d.get('format', {}).get('duration', 0))
    w = float(s.get('width', 0))
    h = float(s.get('height', 0))
    rot = 0
    if 'rotate' in s.get('tags', {}):
        rot = int(float(s['tags']['rotate']))
    for sd in s.get('side_data_list', []):
        if 'rotation' in sd:
            rot = int(float(sd['rotation']))
    rot = ((rot % 360) + 360) % 360
    eff_w, eff_h = (h, w) if rot in (90, 270) else (w, h)
    if eff_h == 0:
        print("ERROR\t0"); sys.exit(0)
    ratio = eff_w / eff_h
    target_ratio = tw / th
    needs = (abs(ratio - target_ratio) > 0.02) or (eff_w > tw) or (eff_h > th)
    print(f"{'YES' if needs else 'NO'}\t{int(dur)}")
except Exception:
    print("ERROR\t0")
PY
)
        IFS=$'\t' read -r STATUS DURATION_S <<< "$PROBE"

        if [ "$STATUS" = "ERROR" ] || [ -z "$STATUS" ]; then
            log "⚠ Skip (probe failed): $filename"
            continue
        fi
        if [ "$STATUS" = "NO" ]; then
            touch "$skip_marker"
            echo "$TARGET" > "$res_marker"
            log "⏭ Skip (native, matches ${TARGET}): $filename"
            continue
        fi

        FILTER="[0:v]split[bg][fg];[bg]scale=640:360,setsar=1,gblur=sigma=50,scale=${TARGET_W}:${TARGET_H},setsar=1[b];[fg]scale=${TARGET_W}:${TARGET_H}:force_original_aspect_ratio=decrease,setsar=1[f];[b][f]overlay=(W-w)/2:(H-h)/2,setsar=1"

        log "⚙ Optimizing: $filename (dur=${DURATION_S}s)"
        echo "$filename — starting..." > "$STATUS_FILE"
        rm -f "$STATUS_FILE.raw"

        ffmpeg -nostdin -y -v error \
            -i "$vid" \
            -filter_complex "$FILTER" \
            -map_metadata -1 -metadata:s:v:0 rotate=0 \
            -c:v libx264 -preset veryfast -crf 23 \
            -c:a aac -b:a 128k \
            -movflags +faststart \
            -progress "$STATUS_FILE.raw" \
            "$tmp_file" </dev/null 2>>"$LOG_FILE" &
        FFMPEG_PID=$!

        (
            while kill -0 "$FFMPEG_PID" 2>/dev/null; do
                if [ -s "$STATUS_FILE.raw" ] && [ "$DURATION_S" -gt 0 ]; then
                    t_us=$(grep '^out_time_us=' "$STATUS_FILE.raw" 2>/dev/null | tail -1 | cut -d= -f2)
                    if [[ "$t_us" =~ ^[0-9]+$ ]]; then
                        pct=$(( t_us / 10000 / DURATION_S ))
                        [ "$pct" -gt 100 ] && pct=100
                        printf '%s — %d%%\n' "$filename" "$pct" > "$STATUS_FILE"
                    fi
                fi
                sleep 2
            done
        ) &
        WATCHER_PID=$!

        wait "$FFMPEG_PID"
        FF_RC=$?
        FFMPEG_PID=""
        kill "$WATCHER_PID" 2>/dev/null
        wait "$WATCHER_PID" 2>/dev/null
        WATCHER_PID=""
        rm -f "$STATUS_FILE.raw"

        if [ "$FF_RC" -eq 0 ]; then
            mv "$tmp_file" "$out_file"
            echo "$TARGET" > "$res_marker"
            log "✓ Done ($TARGET): $filename"
            echo "$filename — done" > "$STATUS_FILE"
        else
            rm -f "$tmp_file"
            log "❌ Failed (rc=$FF_RC): $filename — see preceding stderr in log"
            echo "$filename — FAILED" > "$STATUS_FILE"
        fi

    done < <(find "$MEDIA_DIR" -maxdepth 1 -type f \
        \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.m4v' -o -iname '*.webm' \) \
        -print0)

    echo "idle (next scan in $((VID_RESCAN_SECS / 60)) min)" > "$STATUS_FILE"
    sleep "$VID_RESCAN_SECS" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null
    SLEEP_PID=""
done
