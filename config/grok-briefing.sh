#!/bin/bash
# =============================================================================
#  grok-briefing.sh — scheduled spoken "morning briefing" (xAI Grok), integrated
#  with the screensaver.
#
#  * Subtitles show through the slideshow's own OSD (the script writes the
#    current line to /tmp/ss_briefing.txt; photo.lua renders it).
#  * Background music comes from Music/GrokMorning while the briefing plays; the
#    slideshow's own music (Music/ScreenSaver) is paused, then resumed after.
#  * Controls come from photo.lua via signals: SIGUSR1 = skip, SIGUSR2 = prev.
#    Pause is handled by photo.lua suspending the ffplay PID directly.
#
#  Modes:  --watch  (default; daily scheduler loop, started by launch.sh)
#          --prep   (generate today's segments into the cache, no playback)
#          --play   (play today's segments now)
#
#  Degrades SILENTLY — if the feature is off, the key/network is missing, or a
#  tool isn't installed, it just exits 0 with no output. No nagging, ever.
# =============================================================================
set -u
MODE="${1:---watch}"
SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || { [ "$MODE" = "--check" ] && echo "grok: cannot read $SS_CONF" >&2; exit 0; }

. "$HOME/.profile" 2>/dev/null || true
API_KEY="${XAI_API_KEY:-}"

MODEL="${GROK_MODEL:-grok-4.3}"
VOICE="${GROK_VOICE:-ara}"
GROK_TIME="${GROK_TIME:-07:30}"
LOCATION="${GROK_LOCATION:-}"
TICKERS="${GROK_TICKERS:-}"

GBGM_DIR="$MUSIC_DIR/GrokMorning"
GBGM_VOL="${GROK_BGM_VOLUME:-30}"
WELCOME_DIR="$CFG_DIR/welcome"           # premade greeting clips (play instantly)
CACHE_DIR="$DATA_DIR/Briefing"
TODAY="$(date '+%Y-%m-%d')"
TODAY_CACHE="$CACHE_DIR/$TODAY"
SUB_FILE="/tmp/ss_briefing.txt"          # photo.lua reads this for OSD subtitles
PID_FILE="/tmp/ss_briefing.pid"
FFPLAY_PID_FILE="/tmp/ss_briefing_ffplay.pid"
BGM_TXT="/tmp/ss_briefing_bgm.txt"       # "Title - Artist" of the bgm (for the marquee)
BGM_PATH_FILE="/tmp/ss_briefing_bgm_path"  # the bgm file path (for the cover thumb)
SPEAK_DELAY="${GROK_SPEAK_DELAY:-5}"     # seconds of music before the first words
SECTION_GAP="${GROK_SECTION_GAP:-2}"     # seconds of music between segments
API="https://api.x.ai/v1"

mkdir -p "$TODAY_CACHE" 2>/dev/null

# --- silent gate (applies to watch/prep/play; --check reports instead) -------
gate_ok() {
    [ "${GROK_BRIEFING:-0}" = "1" ] || return 1
    [ -n "$API_KEY" ] || return 1
    for c in jq curl ffplay ffmpeg socat; do command -v "$c" >/dev/null 2>&1 || return 1; done
    return 0
}

# --- segment list: id | use_search | prompt ---------------------------------
TODAY_HUMAN="$(date '+%A, %B %d, %Y')"
build_segments() {
    SEG_IDS=(); SEG_SEARCH=(); SEG_PROMPT=()
    local loc="${LOCATION:-your area}"
    SEG_IDS+=("weather");  SEG_SEARCH+=("true")
    SEG_PROMPT+=("Briefly summarize today's ($TODAY_HUMAN) weather for $loc. Keep it conversational, one short paragraph, no lists.")
    SEG_IDS+=("news");     SEG_SEARCH+=("true")
    SEG_PROMPT+=("Search the web and give me 3 of the most important general news headlines happening right now today, $TODAY_HUMAN. Be concise, one sentence each, plain spoken sentences, no bullets or emojis.")
    SEG_IDS+=("techfin");  SEG_SEARCH+=("true")
    SEG_PROMPT+=("Search the web for the latest interesting tech and finance news as of today, $TODAY_HUMAN. Give me 3 tech headlines and 2 financial market headlines, one sentence each, plain spoken, no bullets or emojis.")
    if [ -n "$TICKERS" ]; then
        SEG_IDS+=("stocks"); SEG_SEARCH+=("true")
        SEG_PROMPT+=("Search the web for the latest stock prices and news as of today, $TODAY_HUMAN for $TICKERS. For each: current price, percent change, and one key news item if there is one. Plain flowing spoken sentences — no bullet points, no emojis, no headers.")
    fi
    SEG_IDS+=("watch");    SEG_SEARCH+=("true")
    SEG_PROMPT+=("Search the web and recommend two interesting stocks or investments to watch today, $TODAY_HUMAN. Give the ticker, current price, why it's worth watching today specifically, and a one-sentence risk note. Casual spoken sentences — no bullet points, no emojis, no headers. Under 150 words.")
}

have_net() { curl -s --max-time 8 -o /dev/null "$API/models" -H "Authorization: Bearer $API_KEY"; }

# --- generate one segment (text + TTS), cached by prompt hash ----------------
gen_segment() {
    local id="$1" search="$2" prompt="$3"
    local hash; hash="$(printf '%s' "$prompt" | md5sum | cut -d' ' -f1)"
    local cmp3="$TODAY_CACHE/${id}_${hash}.mp3" ctxt="$TODAY_CACHE/${id}_${hash}.txt"
    [ -s "$cmp3" ] && [ -s "$ctxt" ] && return 0

    local resp text
    if [ "$search" = "true" ]; then
        resp="$(curl -s --max-time 90 "$API/responses" -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg m "$MODEL" --arg p "$prompt" \
                '{model:$m, input:[{role:"user",content:$p}], tools:[{type:"web_search"}]}')")"
        text="$(printf '%s' "$resp" | jq -r '[.output[]? | select(.type=="message") | .content[]? | select(.type=="output_text") | .text] | join("")')"
    else
        resp="$(curl -s --max-time 60 "$API/chat/completions" -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg m "$MODEL" --arg p "$prompt" \
                '{model:$m, messages:[{role:"user",content:$p}], temperature:0.7}')")"
        text="$(printf '%s' "$resp" | jq -r '.choices[0].message.content')"
    fi
    [ -z "$text" ] || [ "$text" = "null" ] && return 1     # quietly give up on this segment

    # strip markdown / citation noise (so TTS never reads URLs), collapse blanks
    text="$(printf '%s' "$text" | sed \
            -e 's/\*\*//g' -e 's/^#\+[[:space:]]*//' \
            -e 's/\[\[[0-9,]*\]\]([^)]*)//g' \
            -e 's/\[[0-9,]*\]([^)]*)//g' \
            -e 's/\[[^][]*\]([^)]*)//g' \
            -e 's/\[\[[0-9,]*\]\]//g' -e 's/\[[0-9,]*\]//g' \
            -e 's#https\?://[^ )]*##g' -e 's/  */ /g' | awk 'NF{p=1} p{print}')"

    local tmp; tmp="$(mktemp --suffix=.mp3)"
    if curl -s --max-time 90 -X POST "$API/tts" -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg t "$text" --arg v "$VOICE" '{text:$t, voice_id:$v, language:"en"}')" \
            --output "$tmp" \
       && [ -s "$tmp" ] && ! head -c1 "$tmp" | grep -q '{'; then
        printf '%s' "$text" > "$ctxt"
        mv -f "$tmp" "$cmp3"
        return 0
    fi
    rm -f "$tmp"; return 1
}

prep() {
    have_net || return 1
    build_segments
    local i ok=0
    for i in "${!SEG_IDS[@]}"; do
        gen_segment "${SEG_IDS[$i]}" "${SEG_SEARCH[$i]}" "${SEG_PROMPT[$i]}" && ok=1 &
    done
    wait
    return $([ "$ok" = 1 ] && echo 0 || echo 1)
}

# --- playback ----------------------------------------------------------------
ss_music_pause() { printf '{"command":["set_property","pause",%s]}\n' "$1" \
    | socat -t1 - "UNIX-CONNECT:$AUDIO_SOCK" 2>/dev/null; }
sub_show()  { printf '%s' "$1" > "$SUB_FILE"; }
sub_hide()  { printf '__HIDE__'  > "$SUB_FILE"; }

CUR_FFPLAY=""; BGM_PID=""; PREP_BG=""; SKIP=0; STEP=1
on_skip() { SKIP=1; STEP=1;  [ -n "$CUR_FFPLAY" ] && { kill -CONT "$CUR_FFPLAY" 2>/dev/null; kill "$CUR_FFPLAY" 2>/dev/null; }; }
on_prev() { SKIP=1; STEP=-1; [ -n "$CUR_FFPLAY" ] && { kill -CONT "$CUR_FFPLAY" 2>/dev/null; kill "$CUR_FFPLAY" 2>/dev/null; }; }
end_play() {
    [ -n "$CUR_FFPLAY" ] && { kill -CONT "$CUR_FFPLAY" 2>/dev/null; kill "$CUR_FFPLAY" 2>/dev/null; }
    [ -n "$BGM_PID" ] && kill "$BGM_PID" 2>/dev/null
    [ -n "$PREP_BG" ] && kill "$PREP_BG" 2>/dev/null    # stop background generation
    sub_hide; rm -f "$PID_FILE" "$FFPLAY_PID_FILE" "$BGM_TXT" "$BGM_PATH_FILE"
    ss_music_pause false        # resume the slideshow's own music
    exit 0
}

# Instant premade greeting while the first real segment is still generating.
play_welcome() {
    [ -d "$WELCOME_DIR" ] || return 0
    local wmp3 wtxt
    wmp3="$(find "$WELCOME_DIR" -maxdepth 1 -type f -iname '*.mp3' 2>/dev/null | shuf -n1)"
    [ -n "$wmp3" ] && [ -s "$wmp3" ] || return 0
    wtxt="${wmp3%.*}.txt"
    [ -s "$wtxt" ] && sub_show "$(cat "$wtxt")" || sub_hide
    SKIP=0; STEP=1
    ffplay -nodisp -autoexit -loglevel quiet "$wmp3" >/dev/null 2>&1 &
    CUR_FFPLAY=$!; echo "$CUR_FFPLAY" > "$FFPLAY_PID_FILE"
    wait "$CUR_FFPLAY" 2>/dev/null
    CUR_FFPLAY=""; rm -f "$FFPLAY_PID_FILE"; sub_hide
}

play() {
    # single instance — don't start if a briefing is already playing
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null && return 0
    build_segments
    have_net || return 1

    echo $$ > "$PID_FILE"
    trap on_skip SIGUSR1
    trap on_prev SIGUSR2
    trap end_play SIGTERM SIGINT EXIT

    ss_music_pause true          # duck the slideshow music

    # GrokMorning background music (random track, looped quietly) if any exist
    if [ -d "$GBGM_DIR" ] && [ -n "$(ls -A "$GBGM_DIR" 2>/dev/null)" ]; then
        local bgm; bgm="$(find "$GBGM_DIR" -maxdepth 1 -type f \( -iname '*.mp3' -o -iname '*.flac' -o -iname '*.m4a' -o -iname '*.ogg' -o -iname '*.wav' \) 2>/dev/null | shuf -n1)"
        if [ -n "$bgm" ]; then
            ffplay -nodisp -autoexit -loglevel quiet -loop 0 -volume "$GBGM_VOL" "$bgm" >/dev/null 2>&1 & BGM_PID=$!
            # Publish what's playing so the slideshow's music marquee can show it.
            local bt ba disp
            bt="$(ffprobe -v quiet -show_entries format_tags=title  -of default=nw=1:nk=1 "$bgm" 2>/dev/null | head -1)"
            ba="$(ffprobe -v quiet -show_entries format_tags=artist -of default=nw=1:nk=1 "$bgm" 2>/dev/null | head -1)"
            [ -n "$bt" ] || bt="$(basename "${bgm%.*}")"
            disp="$bt"; [ -n "$ba" ] && disp="$bt - $ba"
            printf '%s' "$disp" > "$BGM_TXT"
            printf '%s' "$bgm"  > "$BGM_PATH_FILE"
        fi
    fi

    # Generate EVERY segment up front, in parallel, in the background — so by the
    # time the welcome clip finishes the first one is ready, and later ones keep
    # loading while earlier ones play. (gen_segment no-ops anything already cached.)
    prep >/dev/null 2>&1 & PREP_BG=$!

    # Let the music breathe before the first words (only when there IS music).
    [ -n "$BGM_PID" ] && sleep "$SPEAK_DELAY"

    # Instant greeting covers the first segment's generation latency.
    play_welcome

    local idx=0 n="${#SEG_IDS[@]}"
    while [ "$idx" -lt "$n" ] && [ "$idx" -ge 0 ]; do
        local id="${SEG_IDS[$idx]}" prompt="${SEG_PROMPT[$idx]}"
        local hash; hash="$(printf '%s' "$prompt" | md5sum | cut -d' ' -f1)"
        local cmp3="$TODAY_CACHE/${id}_${hash}.mp3" ctxt="$TODAY_CACHE/${id}_${hash}.txt"
        SKIP=0; STEP=1

        # Wait for the background prep to produce this segment (up to ~45s),
        # rather than generating a duplicate. Bail early if skipped/stopped.
        local waited=0
        while [ ! -s "$cmp3" ] && [ "$waited" -lt 90 ] && [ "$SKIP" = 0 ]; do
            sleep 0.5; waited=$((waited+1))
        done
        # Honour a skip/prev pressed while still loading.
        [ "$SKIP" = 1 ] && { idx=$(( idx + STEP )); [ "$idx" -lt 0 ] && idx=0; continue; }
        # Last resort: if prep never made it, try once here.
        [ -s "$cmp3" ] || gen_segment "$id" "${SEG_SEARCH[$idx]}" "$prompt" || { idx=$((idx+1)); continue; }
        [ -s "$cmp3" ] || { idx=$((idx+1)); continue; }

        [ -s "$ctxt" ] && sub_show "$(cat "$ctxt")" || sub_hide
        ffplay -nodisp -autoexit -loglevel quiet "$cmp3" >/dev/null 2>&1 &
        CUR_FFPLAY=$!; echo "$CUR_FFPLAY" > "$FFPLAY_PID_FILE"
        wait "$CUR_FFPLAY" 2>/dev/null
        CUR_FFPLAY=""; rm -f "$FFPLAY_PID_FILE"; sub_hide

        idx=$(( idx + STEP ))
        [ "$idx" -lt 0 ] && idx=0
        # A short musical breather between sections (skip if the user skipped).
        [ "$SKIP" = 0 ] && [ "$idx" -lt "$n" ] && [ "$idx" -ge 0 ] && sleep "$SECTION_GAP"
    done
    end_play
}

# --- daily scheduler ---------------------------------------------------------
to_min() { case "$1" in *:*) echo $(( 10#${1%%:*} * 60 + 10#${1##*:} ));; *) echo $(( 10#$1 * 60 ));; esac; }

watch_loop() {
    local target prep_at last_prep="" last_play="" today now t
    while true; do
        # Re-read GROK_TIME from the conf each pass so editing it takes effect
        # within ~30s without restarting the screensaver. Keying last_prep/last_play
        # on "day+target" also lets a changed time re-fire later the same day.
        t="$(. "$SS_CONF" 2>/dev/null; printf '%s' "${GROK_TIME:-07:30}")"
        target="$(to_min "$t")"; prep_at=$(( target - 5 )); [ "$prep_at" -lt 0 ] && prep_at=0
        today="$(date '+%Y-%m-%d')"
        now=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
        if [ "$last_prep" != "$today/$target" ] && [ "$now" -ge "$prep_at" ] && [ "$now" -lt "$target" ]; then
            TODAY="$today"; TODAY_CACHE="$CACHE_DIR/$today"; mkdir -p "$TODAY_CACHE"
            prep >/dev/null 2>&1; last_prep="$today/$target"
        fi
        if [ "$last_play" != "$today/$target" ] && [ "$now" -ge "$target" ] && [ "$now" -lt $(( target + 5 )) ]; then
            # Run as its own process so its $$ (the controls' target) is correct
            # and its exit doesn't end this scheduler loop.
            "$0" --play; last_play="$today/$target"
        fi
        sleep 30
    done
}

# --- diagnostic: report every gate condition + test the API ------------------
check() {
    echo "── GrokMorning diagnostic ──────────────────────────────"
    echo "  conf:  $SS_CONF"
    [ "${GROK_BRIEFING:-0}" = "1" ] && echo "  [ok]   GROK_BRIEFING=1 (enabled)" \
        || echo "  [SKIP] GROK_BRIEFING=${GROK_BRIEFING:-unset} — set it to 1 to enable"
    [ -n "$API_KEY" ] && echo "  [ok]   XAI_API_KEY present (${#API_KEY} chars)" \
        || echo "  [FAIL] XAI_API_KEY not found — add 'export XAI_API_KEY=...' to ~/.profile"
    for c in jq curl ffplay ffmpeg socat; do
        command -v "$c" >/dev/null 2>&1 && echo "  [ok]   $c" || echo "  [FAIL] $c not installed"
    done
    echo "  time:  GROK_TIME=$GROK_TIME  now=$(date '+%H:%M')  (pre-generates ~5 min before)"
    if [ -d "$GBGM_DIR" ] && [ -n "$(ls -A "$GBGM_DIR" 2>/dev/null)" ]; then
        echo "  [ok]   background music in $GBGM_DIR"
    else
        echo "  [note] no tracks in $GBGM_DIR (briefing still plays, just silent bgm)"
    fi
    [ -S "$AUDIO_SOCK" ] && echo "  [ok]   screensaver audio socket present (it's running)" \
        || echo "  [note] no audio socket — the screensaver isn't running right now"
    if [ -z "$API_KEY" ]; then echo "── stop: no key, can't test the API ──"; return; fi
    printf "  net:   reaching api.x.ai ... "
    if have_net; then echo "ok"; else echo "FAIL (no network, or key rejected)"; echo "──"; return; fi
    printf "  gen:   generating one test segment ... "
    build_segments
    if gen_segment "${SEG_IDS[0]}" "${SEG_SEARCH[0]}" "${SEG_PROMPT[0]}"; then
        echo "ok — text + audio cached"
        echo "  => the briefing pipeline works. If it still doesn't fire on its"
        echo "     own, the scheduler isn't being started (reinstall to refresh"
        echo "     launch.sh), or the screensaver wasn't restarted."
    else
        echo "FAIL — the API returned no usable text/audio for the first segment"
    fi
    echo "────────────────────────────────────────────────────────"
}

case "$MODE" in
    --check) check ;;
    --prep)  gate_ok || exit 0; prep ;;
    --play)  gate_ok || exit 0; play ;;                 # replay today's cached briefing
    --fresh) gate_ok || exit 0;                         # discard today's cache, make a new one
             rm -f "$TODAY_CACHE"/*.mp3 "$TODAY_CACHE"/*.txt 2>/dev/null; play ;;
    *)       gate_ok || exit 0; watch_loop ;;
esac
