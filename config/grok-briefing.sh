#!/bin/bash
# =============================================================================
#  grok-briefing.sh — scheduled spoken "morning briefing" (xAI Grok), integrated
#  with the screensaver.
#
#  CONTENT MODEL (one giant call, line/detail pairs):
#    The whole briefing is fetched in ONE web-search call and returned as a list
#    of ITEMS, each a PAIR:
#       * a ONE-LINER  — a single spoken headline sentence (read aloud)
#       * a DETAIL     — a few sentences expanding on it (shown beside the line)
#    Each one-liner gets its OWN TTS clip, so playback reads them one-by-one and
#    always knows which line it is on. The paired detail is published next to it
#    so photo.lua can show it automatically — no citations, no link-fetching.
#
#  * Subtitles show through the slideshow's own OSD: the script writes the
#    current one-liner to /tmp/ss_briefing.txt and its detail to
#    /tmp/ss_briefing.detail; photo.lua renders them.
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
TODAY_CACHE="$CACHE_DIR/$TODAY"
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

mkdir -p "$TODAY_CACHE" 2>/dev/null

# --- silent gate (applies to watch/prep/play; --check reports instead) -------
gate_ok() {
    [ "${GROK_BRIEFING:-0}" = "1" ] || return 1
    [ -n "$API_KEY" ] || return 1
    for c in jq curl ffplay ffmpeg socat mpv python3; do command -v "$c" >/dev/null 2>&1 || return 1; done
    return 0
}

have_net() { curl -s --max-time 8 -o /dev/null "$API/models" -H "Authorization: Bearer $API_KEY"; }

# --- the one giant prompt: whole briefing as line/detail pairs ----------------
TODAY_HUMAN="$(date '+%A, %B %d, %Y')"
BRIEFING_PROMPT=""; BRIEFING_HASH=""
build_prompt() {
    local loc="${LOCATION:-your area}" tick=""
    [ -n "$TICKERS" ] && tick=$'\n- MARKETS: one item for EACH of these tickers — '"$TICKERS"$' — the one-liner naming it with its current price and percent move; give a SOURCE that is a readable finance article or quote page.'
    BRIEFING_PROMPT="You are preparing a spoken morning briefing for $TODAY_HUMAN, for someone in $loc. Search the web for current, real information as of today.

Produce the briefing as a sequence of ITEMS. Each item has THREE parts:
  1) CATEGORY: one of these exact labels — WEATHER, TOP NEWS, TECH & FINANCE, MARKETS, WATCHLIST, CLOSING.
  2) ONE-LINER: a single spoken headline sentence in plain conversational English. Read aloud, so use NO markdown, NO URLs, NO bracketed citations, NO bullet markers, NO asterisks, NO emojis. Report news factually and neutrally: state plainly what happened, with no partisan framing, no loaded or emotive adjectives, no editorializing, and no opinion. If a story is politically contested, summarize it even-handedly.
  3) SOURCE: the full URL of the SINGLE web page you used for this item. It MUST be an ordinary news article page that opens and reads normally in a web browser. Hard rules for the URL: do NOT use youtube.com, youtu.be, or any video page; do NOT use reuters.com; avoid paywalled sites (Wall Street Journal, Bloomberg, Financial Times, New York Times, The Economist). For NEWS, the source MUST be politically BALANCED and centrist — pick straight-news wire-service or centrist reporting and avoid outlets with a strong partisan slant in EITHER direction. Do NOT use left-leaning outlets (The Guardian, NPR, MSNBC, Vox, HuffPost, Slate, The Nation, Mother Jones, Daily Kos, The Daily Beast) and do NOT use right-leaning outlets (Fox News, Breitbart, The Daily Wire, Newsmax, OAN, The Federalist, The Blaze, Daily Caller). PREFER neutral, centrist sources: AP News, BBC News, CNBC, Axios, The Hill, Christian Science Monitor, RealClearPolitics, and official company or government pages. For TECH items prefer The Verge, TechCrunch, Ars Technica, or Engadget; for sports, ESPN. For WEATHER and CLOSING items, leave the SOURCE line blank.

Output EXACTLY in this format and nothing else — no preamble, no extra headings, no commentary:
@@ITEM@@
@@CAT@@
<category label>
@@LINE@@
<one-liner sentence here>
@@SRC@@
<source article URL, or blank>
@@ITEM@@
@@CAT@@
<category label>
@@LINE@@
<one-liner sentence here>
@@SRC@@
<source article URL, or blank>

Cover these, in this exact order:
- WEATHER: today's weather for $loc (1 item; blank SOURCE).
- TOP NEWS: the three most important world or national stories right now (3 items).
- TECH & FINANCE: three technology stories and two financial-market stories (5 items).$tick
- WATCHLIST: two stocks or investments worth watching today, the one-liner naming it and why it is interesting today (2 items).
- CLOSING: one warm, brief sign-off wishing the listener a good day (1 item; blank SOURCE).

Never put URLs in the one-liners, and never put source names in brackets, citation numbers, asterisks, or emojis anywhere in the spoken text."
    BRIEFING_HASH="$(printf '%s' "$BRIEFING_PROMPT" | md5sum | cut -d' ' -f1)"
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

# --- generate the whole briefing: one call, parse pairs, TTS each one-liner ---
# Cached by prompt hash for the day. Pass 1 writes ALL item_NNN.line/.detail and
# item.count up front (so playback knows the full list as soon as anything lands);
# pass 2 TTS each one-liner into item_NNN.mp3 in order, a few at a time.
gen_briefing() {
    build_prompt
    local done_marker="$TODAY_CACHE/briefing_${BRIEFING_HASH}.done"
    [ -s "$done_marker" ] && return 0

    local resp
    resp="$(curl -s --max-time 120 "$API/responses" -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg m "$MODEL" --arg p "$BRIEFING_PROMPT" \
            '{model:$m, input:[{role:"user",content:$p}], tools:[{type:"web_search"}]}')")"
    # Keep the raw response beside the cache for diagnosis.
    printf '%s' "$resp" > "$TODAY_CACHE/briefing.resp" 2>/dev/null

    # Parse the response text into a JSON array of {cat, line, detail}. The model
    # is asked for a strict @@ITEM@@/@@CAT@@/@@LINE@@/@@DETAIL@@ format, which is
    # trivially separable; we still clean each part of stray markdown/URLs.
    local items
    items="$(BRIEF_RESP="$resp" python3 - <<'PY'
import os, re, json
try:
    resp = json.loads(os.environ.get("BRIEF_RESP", "") or "{}")
except Exception:
    resp = {}
text = ""
for it in (resp.get("output") or []):
    if it.get("type") != "message":
        continue
    for c in (it.get("content") or []):
        if c.get("type") == "output_text":
            text += (c.get("text") or "")
if not text:
    # plain chat-completions shape, just in case
    try:
        text = resp["choices"][0]["message"]["content"] or ""
    except Exception:
        text = ""
if not text:
    print("[]"); raise SystemExit

def clean(s):
    s = re.sub(r'\*\*|__', '', s)
    s = re.sub(r'(?m)^\s*#+\s*', '', s)
    s = re.sub(r'(?m)^\s*(?:[-*•]|\d+[.)])\s+', '', s)   # leading bullet/number
    s = re.sub(r'\[[0-9,\s]*\]', '', s)                        # [1] style citations
    s = re.sub(r'\((?:https?://)[^)]*\)', '', s)               # (http...) parenthetical
    s = re.sub(r'https?://\S+', '', s)                         # bare URLs
    s = re.sub(r'[ \t]+', ' ', s)
    s = re.sub(r' +([.,;:!?])', r'\1', s)                      # space before punctuation
    s = re.sub(r'\(\s*\)', '', s)                              # emptied parentheses
    return s.strip()

VALID = {"WEATHER", "TOP NEWS", "TECH & FINANCE", "MARKETS", "WATCHLIST", "CLOSING"}
# Hosts we never fetch a source article from: unscrapable/video (youtube,
# reuters) plus partisan outlets on BOTH sides, so even if the model ignores the
# "balanced sources" instruction the right pane never shows a slanted article
# (the spoken one-liner still plays; that item just has no source on the right).
BAD_HOST = re.compile(
    r'youtube\.com|youtu\.be|reuters\.com'
    # left-leaning
    r'|theguardian\.com|guardian\.co\.uk|npr\.org|msnbc\.com|vox\.com'
    r'|huffpost\.com|huffingtonpost\.com|slate\.com|thenation\.com'
    r'|motherjones\.com|dailykos\.com|thedailybeast\.com'
    # right-leaning
    r'|foxnews\.com|foxbusiness\.com|breitbart\.com|dailywire\.com'
    r'|newsmax\.com|oann\.com|oneamerica|thefederalist\.com'
    r'|theblaze\.com|dailycaller\.com',
    re.I)
def grab(ch, a, b):
    # text after marker a, up to marker b (or end)
    pat = r'@@\s*' + a + r'\s*@@(.*?)(?=@@\s*' + (b or 'ZZZ') + r'\s*@@|$)'
    m = re.search(pat, ch, re.S)
    return m.group(1) if m else ""

def pick_url(s):
    m = re.search(r'https?://\S+', s or "")
    if not m:
        return ""
    u = m.group(0).rstrip('.,);]\'"')
    return "" if BAD_HOST.search(u) else u

items = []
last_cat = "BRIEFING"
# Drop anything before the first marker (preamble), then split into items.
for ch in re.split(r'@@\s*ITEM\s*@@', text)[1:]:
    cat = re.sub(r'\s+', ' ', clean(grab(ch, 'CAT', 'LINE'))).strip().upper()
    line = re.sub(r'\s*\n\s*', ' ', clean(grab(ch, 'LINE', 'SRC'))).strip()
    url = pick_url(grab(ch, 'SRC', None))      # raw (do NOT clean — clean strips URLs)
    if not line:
        continue
    # Snap odd category spellings to the nearest valid label; keep the last seen
    # one if the model omitted it (so an item still groups with its neighbours).
    if cat not in VALID:
        cat = next((v for v in VALID if cat and (v in cat or cat in v)), last_cat)
    last_cat = cat
    items.append({"cat": cat, "line": line, "url": url})
print(json.dumps(items))
PY
)"
    local n; n="$(printf '%s' "$items" | jq 'length' 2>/dev/null)"
    [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null || return 1

    # Pass 1: write every line/detail/category and a manifest (category<TAB>line
    # per item, in order), so playback — and photo.lua's grouped left column —
    # see the full list the instant the first clip is ready.
    rm -f "$TODAY_CACHE"/item_*.line "$TODAY_CACHE"/item_*.url \
          "$TODAY_CACHE"/item_*.cat "$TODAY_CACHE"/item_*.mp3 "$TODAY_CACHE/briefing.manifest" 2>/dev/null
    local i num line url cat
    : > "$TODAY_CACHE/briefing.manifest"
    for (( i=0; i<n; i++ )); do
        num="$(printf '%03d' "$((i+1))")"
        cat="$(printf '%s' "$items" | jq -r ".[$i].cat")"
        line="$(printf '%s' "$items" | jq -r ".[$i].line")"
        url="$(printf '%s' "$items" | jq -r ".[$i].url")"
        printf '%s' "$cat"  > "$TODAY_CACHE/item_${num}.cat"
        printf '%s' "$line" > "$TODAY_CACHE/item_${num}.line"
        printf '%s' "$url"  > "$TODAY_CACHE/item_${num}.url"
        printf '%s\t%s\n' "$cat" "$line" >> "$TODAY_CACHE/briefing.manifest"
    done
    printf '%s' "$n" > "$TODAY_CACHE/item.count"

    # Pass 2: TTS each one-liner into its own clip, up to 4 at a time.
    for (( i=0; i<n; i++ )); do
        num="$(printf '%03d' "$((i+1))")"
        line="$(cat "$TODAY_CACHE/item_${num}.line")"
        tts_line "$line" "$TODAY_CACHE/item_${num}.mp3" &
        [ "$(( (i+1) % 4 ))" = 0 ] && wait
    done
    wait

    # Need at least the first clip to call it a success.
    [ -s "$TODAY_CACHE/item_001.mp3" ] || return 1
    printf 'ok' > "$done_marker"
    return 0
}

prep() { have_net || return 1; gen_briefing; }

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

play() {
    # single instance — don't start if a briefing is already playing
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null && return 0
    build_prompt
    have_net || return 1

    echo $$ > "$PID_FILE"
    trap on_skip SIGUSR1
    trap on_prev SIGUSR2
    trap end_play SIGTERM SIGINT EXIT

    # Generate in the background; DON'T touch the screensaver until the first
    # one-liner's clip is ready (it keeps playing normally meanwhile).
    prep >/dev/null 2>&1 & PREP_BG=$!

    local first="$TODAY_CACHE/item_001.mp3" waited=0
    while [ ! -s "$first" ] && [ "$waited" -lt 360 ] && [ "$SKIP" = 0 ]; do
        sleep 0.5; waited=$((waited+1))
    done
    [ -s "$first" ] || end_play     # nothing came back — abort quietly (nothing touched yet)

    # READY → flip into briefing mode (fade music down, hide HUD, start bgm).
    go_live
    [ -n "$BGM_PID" ] && sleep "$SPEAK_DELAY"
    play_welcome

    # The grouped left column needs the whole item list up front.
    set_manifest "$TODAY_CACHE/briefing.manifest"
    local total; total="$(cat "$TODAY_CACHE/item.count" 2>/dev/null)"
    [ -n "$total" ] || total=0
    local idx=1
    while [ "$idx" -le "$total" ] && [ "$idx" -ge 1 ]; do
        local num; num="$(printf '%03d' "$idx")"
        local mp3="$TODAY_CACHE/item_${num}.mp3"
        SKIP=0; STEP=1

        # Wait for this item's clip (up to ~45s); bail early if skipped/stopped.
        local w=0
        while [ ! -s "$mp3" ] && [ "$w" -lt 90 ] && [ "$SKIP" = 0 ]; do
            sleep 0.5; w=$((w+1))
        done
        [ "$SKIP" = 1 ] && { idx=$(( idx + STEP )); [ "$idx" -lt 1 ] && idx=1; continue; }
        [ -s "$mp3" ] || { idx=$((idx+1)); continue; }

        # Publish the source URL + current index FIRST, then the one-liner caption.
        set_url "$TODAY_CACHE/item_${num}.url"
        set_idx "$idx"
        [ -s "$TODAY_CACHE/item_${num}.line" ] && sub_show "$(cat "$TODAY_CACHE/item_${num}.line")" || sub_hide
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
            TODAY="$today"; TODAY_CACHE="$CACHE_DIR/$today"; mkdir -p "$TODAY_CACHE"
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
    printf "  gen:   generating today's briefing ... "
    if gen_briefing; then
        local cnt; cnt="$(cat "$TODAY_CACHE/item.count" 2>/dev/null)"
        echo "ok — ${cnt:-?} line/detail items, audio cached"
        echo "  => the briefing pipeline works. If it still doesn't fire on its"
        echo "     own, the scheduler isn't being started (reinstall to refresh"
        echo "     launch.sh), or the screensaver wasn't restarted."
    else
        echo "FAIL — the API returned no usable items for today's briefing"
    fi
    echo "────────────────────────────────────────────────────────"
}

case "$MODE" in
    --check) check ;;
    --prep)  gate_ok || exit 0; prep ;;
    --play)  gate_ok || exit 0; play ;;                 # play today's cached briefing
    --fresh) gate_ok || exit 0;                         # discard today's cache, make a new one
             rm -f "$TODAY_CACHE"/item_*.* "$TODAY_CACHE"/item.count \
                   "$TODAY_CACHE"/briefing.manifest "$TODAY_CACHE"/briefing_*.done 2>/dev/null
             play ;;
    *)       gate_ok || exit 0; watch_loop ;;
esac
