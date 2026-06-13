#!/bin/bash
# =============================================================================
#  grok-briefing.sh — scheduled spoken "morning briefing", integrated with the
#  screensaver.
#
#  CONTENT MODEL (feeds, not AI — xAI is used ONLY to read the lines aloud):
#    config/news-build.py assembles the whole briefing as a list of {cat,line,url}
#    ITEMS with NO web-search / language-model call:
#       * WEATHER       — a spoken line built from the Open-Meteo weather card
#       * TOP NEWS      — top headlines from curated, balanced RSS feeds
#       * TECH & FINANCE— top headlines from curated tech RSS feeds
#       * MARKETS       — live prices for GROK_TICKERS (Yahoo Finance, best-effort)
#       * CLOSING       — a templated warm sign-off
#    The feeds ARE the editorial judgment, so links are real, balanced, and always
#    open. Each one-liner still gets its OWN xAI TTS clip, so playback reads them
#    one-by-one and knows which line it is on; photo.lua fetches each item's real
#    source article (or, for WEATHER, draws a live weather card) on the right.
#
#  * Subtitles show through the slideshow's own OSD: the script writes the
#    current one-liner to /tmp/ss_briefing.txt; photo.lua renders it.
#  * Background music comes from Music/GrokMorning while the briefing plays; the
#    slideshow's own music (Music/ScreenSaver) is paused, then resumed after.
#  * Controls come from photo.lua via signals: SIGUSR1 = skip, SIGUSR2 = prev.
#    Pause is handled by photo.lua suspending the ffplay PID directly.
#
#  Modes:  --watch  (default; daily scheduler loop, started by launch.sh)
#          --prep   (generate today's briefing into the cache, no playback)
#          --play   (play today's cached briefing now)
#          --fresh  (discard today's cache, regenerate, then play)
#          --check  (diagnostic)
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
GBGM_VOL="${GROK_BGM_VOLUME:-60}"        # briefing music volume (0-100)
VOICE_VOL="${GROK_VOICE_VOLUME:-150}"    # spoken-voice gain in % (100 = as recorded)
VOICE_GAIN="$(awk "BEGIN{print ${VOICE_VOL}/100}")"   # ffplay -af volume factor
WELCOME_DIR="$CFG_DIR/welcome"           # premade greeting clips (play instantly)
CACHE_DIR="$DATA_DIR/Briefing"
TODAY="$(date '+%Y-%m-%d')"
TODAY_DIR="$CACHE_DIR/$TODAY"            # the day's folder, holds one subdir per run
RUN_DIR=""                              # the timestamped run we generate into / play from
SUB_FILE="/tmp/ss_briefing.txt"          # photo.lua reads this for the current one-liner
URL_FILE="/tmp/ss_briefing.url"          # photo.lua fetches this — the current line's source article
MANIFEST_FILE="/tmp/ss_briefing.manifest"  # all items "category<TAB>line" (left column grouping)
IDX_FILE="/tmp/ss_briefing.idx"          # 1-based index of the line being read right now
PID_FILE="/tmp/ss_briefing.pid"          # exists for the whole process (controls/single-instance)
LIVE_FILE="/tmp/ss_briefing_live"        # exists ONLY once it's actually playing (drives the HUD)
FFPLAY_PID_FILE="/tmp/ss_briefing_ffplay.pid"
BGM_TXT="/tmp/ss_briefing_bgm.txt"       # "Title - Artist" of the bgm (for the marquee)
BGM_PATH_FILE="/tmp/ss_briefing_bgm_path"  # the bgm file path (for the cover thumb)
BGM_SOCK="/tmp/ss_bgm.sock"              # bgm's own mpv IPC socket (for fading)
SPEAK_DELAY="${GROK_SPEAK_DELAY:-5}"     # seconds of music before the first words
SECTION_GAP="${GROK_SECTION_GAP:-1}"     # seconds of music between one-liners
API="https://api.x.ai/v1"

# --- silent gate (applies to watch/prep/play; --check reports instead) -------
gate_ok() {
    [ "${GROK_BRIEFING:-0}" = "1" ] || return 1
    [ -n "$API_KEY" ] || return 1
    for c in jq curl ffplay ffmpeg socat mpv python3; do command -v "$c" >/dev/null 2>&1 || return 1; done
    return 0
}

have_net() { curl -s --max-time 8 -o /dev/null "$API/models" -H "Authorization: Bearer $API_KEY"; }

# --- per-day cache key --------------------------------------------------------
# The content now comes from RSS feeds + weather + live prices (no AI call), so
# the cache key is just the day plus the inputs that change what's gathered.
# Bump the leading version tag to force every machine to regenerate.
TODAY_HUMAN="$(date '+%A, %B %d, %Y')"
BRIEFING_HASH=""
build_meta() {
    BRIEFING_HASH="$(printf '%s' "feeds-v1|$(date +%F)|${LOCATION:-}|${TICKERS:-}|${GROK_NEWS_FEEDS:-}|${GROK_TECH_FEEDS:-}" \
        | md5sum | cut -d' ' -f1)"
}

# --- run directories ----------------------------------------------------------
# Every generation gets its OWN timestamped folder under the day —
#   Data/Briefing/<YYYY-MM-DD>/<HHMMSS>/
# so refreshing keeps each earlier run intact (you can still replay the last one)
# and replay can pick whichever run is newest. Folder names sort chronologically.
new_run() {                              # fresh run dir for a NEW generation
    RUN_DIR="$TODAY_DIR/$(date '+%H%M%S')"
    mkdir -p "$RUN_DIR" 2>/dev/null
    # Keep only the newest 12 runs in today's folder so it can't grow forever.
    ls -1d "$TODAY_DIR"/*/ 2>/dev/null | sort | head -n -12 \
        | while IFS= read -r d; do rm -rf "$d"; done
}
# Newest run (any day) that actually has playable audio. Echoes its path, or ''.
latest_run() {
    local d
    for d in $(ls -1d "$CACHE_DIR"/*/*/ 2>/dev/null | sort -r); do
        [ -s "${d}item_001.mp3" ] && { printf '%s' "${d%/}"; return 0; }
    done
    return 1
}
# Newest playable run for TODAY only (used to skip regenerating an identical one).
latest_run_today() {
    local d
    for d in $(ls -1d "$TODAY_DIR"/*/ 2>/dev/null | sort -r); do
        [ -s "${d}item_001.mp3" ] && { printf '%s' "${d%/}"; return 0; }
    done
    return 1
}

# --- TTS one one-liner into its own mp3 (atomic; rejects JSON error bodies) ---
tts_line() {
    local text="$1" out="$2" tmp
    tmp="$(mktemp --suffix=.mp3)"
    if curl -s --max-time 90 -X POST "$API/tts" -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg t "$text" --arg v "$VOICE" '{text:$t, voice_id:$v, language:"en"}')" \
            --output "$tmp" \
       && [ -s "$tmp" ] && ! head -c1 "$tmp" | grep -q '{'; then
        mv -f "$tmp" "$out"; return 0
    fi
    rm -f "$tmp"; return 1
}

# --- build the whole briefing INTO $RUN_DIR (caller sets + mkdir's it) --------
# Pass 1 writes ALL item_NNN.cat/.line/.url and item.count up front (so playback
# knows the full list as soon as anything lands); pass 2 TTS each one-liner into
# item_NNN.mp3 in order, a few at a time. Stamps briefing.hash on success.
gen_into_run() {
    build_meta
    [ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ] || return 1

    # Weather card data (drives the spoken weather line AND primes the 20-min
    # cache that photo.lua's right-pane card reuses).
    local wxf="$RUN_DIR/weather.card"
    bash "$CFG_DIR/weather-card.sh" "$wxf" 2>/dev/null

    # Build the WHOLE briefing from curated balanced RSS feeds + live ticker
    # prices — no AI call. Same {cat,line,url} JSON the old parser produced, so
    # everything below (TTS, manifest, playback, photo.lua) is unchanged.
    local items
    items="$(WX_FILE="$wxf" LOCATION="${LOCATION:-}" TICKERS="${TICKERS:-}" \
             DAY_NAME="$(date '+%A')" \
             NEWS_FEEDS="${GROK_NEWS_FEEDS:-}" TECH_FEEDS="${GROK_TECH_FEEDS:-}" \
             python3 "$CFG_DIR/news-build.py" 2>/dev/null)"
    printf '%s' "$items" > "$RUN_DIR/briefing.resp" 2>/dev/null   # keep for diagnosis

    local n; n="$(printf '%s' "$items" | jq 'length' 2>/dev/null)"
    [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null || return 1

    # Pass 1: write every line/url/category and a manifest (category<TAB>line
    # per item, in order), so playback — and photo.lua's grouped left column —
    # see the full list the instant the first clip is ready.
    local i num line url cat
    : > "$RUN_DIR/briefing.manifest"
    for (( i=0; i<n; i++ )); do
        num="$(printf '%03d' "$((i+1))")"
        cat="$(printf '%s' "$items" | jq -r ".[$i].cat")"
        line="$(printf '%s' "$items" | jq -r ".[$i].line")"
        url="$(printf '%s' "$items" | jq -r ".[$i].url")"
        printf '%s' "$cat"  > "$RUN_DIR/item_${num}.cat"
        printf '%s' "$line" > "$RUN_DIR/item_${num}.line"
        printf '%s' "$url"  > "$RUN_DIR/item_${num}.url"
        printf '%s\t%s\n' "$cat" "$line" >> "$RUN_DIR/briefing.manifest"
    done
    printf '%s' "$n" > "$RUN_DIR/item.count"

    # Pass 2: TTS each one-liner into its own clip, up to 4 at a time.
    for (( i=0; i<n; i++ )); do
        num="$(printf '%03d' "$((i+1))")"
        line="$(cat "$RUN_DIR/item_${num}.line")"
        tts_line "$line" "$RUN_DIR/item_${num}.mp3" &
        [ "$(( (i+1) % 4 ))" = 0 ] && wait
    done
    wait

    # Need at least the first clip to call it a success.
    [ -s "$RUN_DIR/item_001.mp3" ] || return 1
    printf '%s' "$BRIEFING_HASH" > "$RUN_DIR/briefing.hash"
    return 0
}

# Decide which run a generation request should use, then build it (foreground).
# $1="force" → always a brand-new run; otherwise reuse today's run if its inputs
# are unchanged (same hash), so the scheduler's pre-gen + the play that follows
# don't generate twice.
prep() {
    have_net || return 1
    build_meta
    if [ "${1:-}" != "force" ]; then
        local prev; prev="$(latest_run_today)"
        if [ -n "$prev" ] && [ "$(cat "$prev/briefing.hash" 2>/dev/null)" = "$BRIEFING_HASH" ]; then
            RUN_DIR="$prev"; return 0
        fi
    fi
    new_run
    gen_into_run
}

# --- playback ----------------------------------------------------------------
ss_music_pause() { printf '{"command":["set_property","pause",%s]}\n' "$1" \
    | socat -t1 - "UNIX-CONNECT:$AUDIO_SOCK" 2>/dev/null; }
sub_show()   { printf '%s' "$1" > "$SUB_FILE"; }
sub_hide()   { printf '__HIDE__' > "$SUB_FILE"; rm -f "$URL_FILE" "$IDX_FILE" "$MANIFEST_FILE"; }
# Publish (or clear) the current one-liner's source URL — photo.lua fetches it
# into the right pane. Atomic (tmp+mv); published BEFORE the caption so photo.lua
# never pairs a new line with the previous item's URL. A blank/missing url file
# means "no source" (weather, closing, or a filtered-out link).
set_url() {
    if [ -n "$1" ] && [ -s "$1" ]; then
        cp -f "$1" "$URL_FILE.part" 2>/dev/null && mv -f "$URL_FILE.part" "$URL_FILE"
    else
        rm -f "$URL_FILE"
    fi
}
# Publish the full item list (so photo.lua can show a category's lines together),
# and the index of the line being read (so it can highlight where we are). Both
# atomic. set_idx clears when given nothing (welcome greeting → no grouping).
set_manifest() {
    if [ -n "$1" ] && [ -s "$1" ]; then
        cp -f "$1" "$MANIFEST_FILE.part" 2>/dev/null && mv -f "$MANIFEST_FILE.part" "$MANIFEST_FILE"
    else
        rm -f "$MANIFEST_FILE"
    fi
}
set_idx() {
    if [ -n "$1" ]; then
        printf '%s' "$1" > "$IDX_FILE.part" && mv -f "$IDX_FILE.part" "$IDX_FILE"
    else
        rm -f "$IDX_FILE"
    fi
}

# --- soft volume fades over an mpv IPC socket --------------------------------
jsock()   { printf '%s\n' "$2" | socat -t1 - "UNIX-CONNECT:$1" 2>/dev/null; }
get_vol() { jsock "$1" '{"command":["get_property","volume"]}' \
    | sed -n 's/.*"data":\([0-9.][0-9.]*\).*/\1/p' | head -1; }
set_vol() { jsock "$1" "{\"command\":[\"set_property\",\"volume\",$2]}" >/dev/null 2>&1; }
fade_vol() {  # sock from to seconds
    local sock="$1" from="$2" to="$3" secs="$4" steps=20 i v st
    st="$(awk "BEGIN{print $secs/$steps}")"
    for i in $(seq 1 "$steps"); do
        v="$(awk "BEGIN{printf \"%.1f\", $from + ($to-$from)*$i/$steps}")"
        set_vol "$sock" "$v"; sleep "$st"
    done
}
FADE_IN="${GROK_FADE_IN:-1.2}"      # soft-drop of the slideshow music on entry
FADE_OUT="${GROK_FADE_OUT:-2.5}"    # longer soft-drop of the bgm on exit
FADE_RESUME="${GROK_FADE_RESUME:-2.0}"  # soft resume of the slideshow music

CUR_FFPLAY=""; BGM_PID=""; PREP_BG=""; SKIP=0; STEP=1; ENDED=0; SS_VOL=""; WENT_LIVE=0
on_skip() { SKIP=1; STEP=1;  [ -n "$CUR_FFPLAY" ] && { kill -CONT "$CUR_FFPLAY" 2>/dev/null; kill "$CUR_FFPLAY" 2>/dev/null; }; }
on_prev() { SKIP=1; STEP=-1; [ -n "$CUR_FFPLAY" ] && { kill -CONT "$CUR_FFPLAY" 2>/dev/null; kill "$CUR_FFPLAY" 2>/dev/null; }; }
end_play() {
    [ "$ENDED" = 1 ] && exit 0; ENDED=1     # runs once (called directly + via EXIT trap)
    [ -n "$CUR_FFPLAY" ] && { kill -CONT "$CUR_FFPLAY" 2>/dev/null; kill "$CUR_FFPLAY" 2>/dev/null; }
    [ -n "$PREP_BG" ] && kill "$PREP_BG" 2>/dev/null    # stop background generation
    sub_hide
    if [ "$WENT_LIVE" = 1 ]; then
        rm -f "$LIVE_FILE"                  # HUD comes back, mute lifts
        if [ -n "$BGM_PID" ]; then
            fade_vol "$BGM_SOCK" "$GBGM_VOL" 0 "$FADE_OUT"
            jsock "$BGM_SOCK" '{"command":["quit"]}' >/dev/null 2>&1
            kill "$BGM_PID" 2>/dev/null
        fi
        [ -n "$SS_VOL" ] || SS_VOL="$VOLUME"
        set_vol "$AUDIO_SOCK" 0
        ss_music_pause false
        fade_vol "$AUDIO_SOCK" 0 "$SS_VOL" "$FADE_RESUME"
    fi
    rm -f "$PID_FILE" "$FFPLAY_PID_FILE" "$BGM_TXT" "$BGM_PATH_FILE" "$BGM_SOCK"
    exit 0
}

# Transition the screensaver INTO briefing mode — only once content is ready.
go_live() {
    WENT_LIVE=1
    echo $$ > "$LIVE_FILE"                  # photo.lua: mute + hide HUD + show the title
    SS_VOL="$(get_vol "$AUDIO_SOCK")"; [ -n "$SS_VOL" ] || SS_VOL="$VOLUME"
    fade_vol "$AUDIO_SOCK" "$SS_VOL" 0 "$FADE_IN"
    ss_music_pause true
    if [ -d "$GBGM_DIR" ] && [ -n "$(ls -A "$GBGM_DIR" 2>/dev/null)" ]; then
        local bgm; bgm="$(find "$GBGM_DIR" -maxdepth 1 -type f \( -iname '*.mp3' -o -iname '*.flac' -o -iname '*.m4a' -o -iname '*.ogg' -o -iname '*.wav' \) 2>/dev/null | shuf -n1)"
        if [ -n "$bgm" ]; then
            rm -f "$BGM_SOCK"
            mpv --no-config --no-video --no-terminal --idle=no --loop-file=inf \
                --volume="$GBGM_VOL" --input-ipc-server="$BGM_SOCK" "$bgm" >/dev/null 2>&1 & BGM_PID=$!
            local bt ba disp
            bt="$(ffprobe -v quiet -show_entries format_tags=title  -of default=nw=1:nk=1 "$bgm" 2>/dev/null | head -1)"
            ba="$(ffprobe -v quiet -show_entries format_tags=artist -of default=nw=1:nk=1 "$bgm" 2>/dev/null | head -1)"
            [ -n "$bt" ] || bt="$(basename "${bgm%.*}")"
            disp="$bt"; [ -n "$ba" ] && disp="$bt - $ba"
            printf '%s' "$disp" > "$BGM_TXT"
            printf '%s' "$bgm"  > "$BGM_PATH_FILE"
        fi
    fi
}

# Instant premade greeting while the briefing is still generating.
play_welcome() {
    [ -d "$WELCOME_DIR" ] || return 0
    local wmp3 wtxt
    wmp3="$(find "$WELCOME_DIR" -maxdepth 1 -type f -iname '*.mp3' 2>/dev/null | shuf -n1)"
    [ -n "$wmp3" ] && [ -s "$wmp3" ] || return 0
    wtxt="${wmp3%.*}.txt"
    set_url ""; set_idx ""              # the greeting has no source and no grouping
    [ -s "$wtxt" ] && sub_show "$(cat "$wtxt")" || sub_hide
    SKIP=0; STEP=1
    ffplay -nodisp -autoexit -loglevel quiet -af "volume=${VOICE_GAIN}" "$wmp3" >/dev/null 2>&1 &
    CUR_FFPLAY=$!; echo "$CUR_FFPLAY" > "$FFPLAY_PID_FILE"
    wait "$CUR_FFPLAY" 2>/dev/null
    CUR_FFPLAY=""; rm -f "$FFPLAY_PID_FILE"
}

# $1="force" → REFRESH (always build a new run). Otherwise REPLAY/scheduled:
# play the newest finished run as-is, building one only if none exists yet.
play() {
    build_meta
    # ATOMIC single-instance lock. Claim the PID file with noclobber BEFORE any
    # slow work (the network probe). The old guard checked then wrote the PID
    # file only AFTER an up-to-8s have_net call, leaving a window in which a
    # double-click — or an overlapping scheduled run — started a SECOND briefing:
    # two background tracks and two voices at once. This closes that window.
    if ! ( set -o noclobber; printf '%s' "$$" > "$PID_FILE" ) 2>/dev/null; then
        local op; op="$(cat "$PID_FILE" 2>/dev/null)"
        [ -n "$op" ] && kill -0 "$op" 2>/dev/null && return 0   # a briefing is live
        printf '%s' "$$" > "$PID_FILE"                          # stale lock → take over
    fi
    trap on_skip SIGUSR1
    trap on_prev SIGUSR2
    trap end_play SIGTERM SIGINT EXIT

    local force="${1:-}"
    RUN_DIR=""
    [ "$force" != "force" ] && RUN_DIR="$(latest_run)"   # replay the newest run

    if [ -z "$RUN_DIR" ] || [ ! -s "$RUN_DIR/item_001.mp3" ]; then
        # No run to play (first-ever GENERATE) or a forced REFRESH → build one.
        # Decide the folder HERE so the background generator and this loop agree
        # on the path; fill the wait with an instant welcome clip.
        # Offline? Replay the last good run rather than failing with nothing.
        if ! have_net; then RUN_DIR="$(latest_run)"; [ -n "$RUN_DIR" ] || end_play; fi
        if [ "$force" != "force" ] && [ -z "$RUN_DIR" ]; then
            local prev; prev="$(latest_run_today)"
            [ -n "$prev" ] && [ "$(cat "$prev/briefing.hash" 2>/dev/null)" = "$BRIEFING_HASH" ] && RUN_DIR="$prev"
        fi
        if [ -z "$RUN_DIR" ] || [ ! -s "$RUN_DIR/item_001.mp3" ]; then
            new_run
            gen_into_run >/dev/null 2>&1 & PREP_BG=$!
            local first="$RUN_DIR/item_001.mp3" waited=0
            while [ ! -s "$first" ] && [ "$waited" -lt 360 ] && [ "$SKIP" = 0 ]; do
                sleep 0.5; waited=$((waited+1))
            done
            if [ ! -s "$first" ]; then
                # Build gave up (no net / feeds / TTS). Rather than show nothing,
                # fall back to the last good run if there is one.
                local fb; fb="$(latest_run)"
                [ -n "$fb" ] && { RUN_DIR="$fb"; PREP_BG=""; } || end_play
            fi
        fi
    fi

    # READY → flip into briefing mode (fade music down, hide HUD, start bgm).
    go_live
    [ -n "$BGM_PID" ] && sleep "$SPEAK_DELAY"
    [ -n "$PREP_BG" ] && play_welcome     # only the still-generating path needs filler

    # The grouped left column needs the whole item list up front.
    set_manifest "$RUN_DIR/briefing.manifest"
    local total; total="$(cat "$RUN_DIR/item.count" 2>/dev/null)"
    [ -n "$total" ] || total=0
    local idx=1
    while [ "$idx" -le "$total" ] && [ "$idx" -ge 1 ]; do
        local num; num="$(printf '%03d' "$idx")"
        local mp3="$RUN_DIR/item_${num}.mp3"
        SKIP=0; STEP=1

        # Wait for this item's clip (up to ~45s); bail early if skipped/stopped.
        local w=0
        while [ ! -s "$mp3" ] && [ "$w" -lt 90 ] && [ "$SKIP" = 0 ]; do
            sleep 0.5; w=$((w+1))
        done
        [ "$SKIP" = 1 ] && { idx=$(( idx + STEP )); [ "$idx" -lt 1 ] && idx=1; continue; }
        [ -s "$mp3" ] || { idx=$((idx+1)); continue; }

        # Publish the source URL + current index FIRST, then the one-liner caption.
        set_url "$RUN_DIR/item_${num}.url"
        set_idx "$idx"
        [ -s "$RUN_DIR/item_${num}.line" ] && sub_show "$(cat "$RUN_DIR/item_${num}.line")" || sub_hide
        ffplay -nodisp -autoexit -loglevel quiet -af "volume=${VOICE_GAIN}" "$mp3" >/dev/null 2>&1 &
        CUR_FFPLAY=$!; echo "$CUR_FFPLAY" > "$FFPLAY_PID_FILE"
        wait "$CUR_FFPLAY" 2>/dev/null
        CUR_FFPLAY=""; rm -f "$FFPLAY_PID_FILE"

        idx=$(( idx + STEP ))
        [ "$idx" -lt 1 ] && idx=1
        # A short musical breather between lines (skip if the user skipped).
        [ "$SKIP" = 0 ] && [ "$idx" -le "$total" ] && [ "$idx" -ge 1 ] && sleep "$SECTION_GAP"
    done
    end_play
}

# --- daily scheduler ---------------------------------------------------------
to_min() { case "$1" in *:*) echo $(( 10#${1%%:*} * 60 + 10#${1##*:} ));; *) echo $(( 10#$1 * 60 ));; esac; }

watch_loop() {
    local target prep_at last_prep="" last_play="" last_clean="" today now t
    while true; do
        t="$(. "$SS_CONF" 2>/dev/null; printf '%s' "${GROK_TIME:-07:30}")"
        target="$(to_min "$t")"; prep_at=$(( target - 5 )); [ "$prep_at" -lt 0 ] && prep_at=0
        today="$(date '+%Y-%m-%d')"
        now=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
        if [ "$last_clean" != "$today" ]; then
            find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -type d ! -name "$today" -mtime +1 \
                -exec rm -rf {} + 2>/dev/null
            last_clean="$today"
        fi
        if [ "$last_prep" != "$today/$target" ] && [ "$now" -ge "$prep_at" ] && [ "$now" -lt "$target" ]; then
            TODAY="$today"; TODAY_DIR="$CACHE_DIR/$today"
            prep >/dev/null 2>&1; last_prep="$today/$target"
        fi
        if [ "$last_play" != "$today/$target" ] && [ "$now" -ge "$target" ] && [ "$now" -lt $(( target + 5 )) ]; then
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
    for c in jq curl ffplay ffmpeg socat mpv python3; do
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
    printf "  gen:   building today's briefing from feeds ... "
    if prep force; then
        local cnt; cnt="$(cat "$RUN_DIR/item.count" 2>/dev/null)"
        echo "ok — ${cnt:-?} items (weather + news feeds + markets) in ${RUN_DIR#$CACHE_DIR/}"
        echo "  => the briefing pipeline works. If it still doesn't fire on its"
        echo "     own, the scheduler isn't being started (reinstall to refresh"
        echo "     launch.sh), or the screensaver wasn't restarted."
    else
        echo "FAIL — couldn't build any items (check network / feeds / TTS key)"
    fi
    echo "────────────────────────────────────────────────────────"
}

case "$MODE" in
    --check) check ;;
    --prep)  gate_ok || exit 0; prep ;;
    --play)  gate_ok || exit 0; play ;;        # replay the newest run (build only if none)
    --fresh) gate_ok || exit 0; play force ;;  # REFRESH: always build a new run, keep old ones
    *)       gate_ok || exit 0; watch_loop ;;
esac
