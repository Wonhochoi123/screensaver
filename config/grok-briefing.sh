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
GBGM_VOL="${GROK_BGM_VOLUME:-60}"        # briefing music volume (0-100)
VOICE_VOL="${GROK_VOICE_VOLUME:-150}"    # spoken-voice gain in % (100 = as recorded)
VOICE_GAIN="$(awk "BEGIN{print ${VOICE_VOL}/100}")"   # ffplay -af volume factor
WELCOME_DIR="$CFG_DIR/welcome"           # premade greeting clips (play instantly)
CACHE_DIR="$DATA_DIR/Briefing"
TODAY="$(date '+%Y-%m-%d')"
TODAY_CACHE="$CACHE_DIR/$TODAY"
SUB_FILE="/tmp/ss_briefing.txt"          # photo.lua reads this for OSD subtitles
PID_FILE="/tmp/ss_briefing.pid"          # exists for the whole process (controls/single-instance)
LIVE_FILE="/tmp/ss_briefing_live"        # exists ONLY once it's actually playing (drives the HUD)
FFPLAY_PID_FILE="/tmp/ss_briefing_ffplay.pid"
BGM_TXT="/tmp/ss_briefing_bgm.txt"       # "Title - Artist" of the bgm (for the marquee)
BGM_PATH_FILE="/tmp/ss_briefing_bgm_path"  # the bgm file path (for the cover thumb)
BGM_SOCK="/tmp/ss_bgm.sock"              # bgm's own mpv IPC socket (for fading)
SPEAK_DELAY="${GROK_SPEAK_DELAY:-5}"     # seconds of music before the first words
SECTION_GAP="${GROK_SECTION_GAP:-2}"     # seconds of music between segments
API="https://api.x.ai/v1"

mkdir -p "$TODAY_CACHE" 2>/dev/null

# --- silent gate (applies to watch/prep/play; --check reports instead) -------
gate_ok() {
    [ "${GROK_BRIEFING:-0}" = "1" ] || return 1
    [ -n "$API_KEY" ] || return 1
    for c in jq curl ffplay ffmpeg socat mpv; do command -v "$c" >/dev/null 2>&1 || return 1; done
    return 0
}

# --- segment list: id | use_search | prompt ---------------------------------
TODAY_HUMAN="$(date '+%A, %B %d, %Y')"
build_segments() {
    SEG_IDS=(); SEG_SEARCH=(); SEG_PROMPT=()
    local loc="${LOCATION:-your area}"
    # Shared output contract: ONE topic per line, each carrying its own real
    # source URL after a ||SRC|| marker. This is what lets every item be split
    # and linked separately (the marker + URL are metadata, never read aloud).
    local FMT=$'\n\nFormatting rules (important): Write plain spoken sentences only — NO markdown, bullets, numbering, emojis, or symbols in the spoken text, because it is read aloud. Put each distinct item on its OWN line. Every line MUST end with a space, the literal marker ||SRC||, another space, and the full URL of the web page you actually used for that item — you searched the web for this, so each item has a source; do NOT leave it blank. Example line:\nApple announced a new chip this morning. ||SRC|| https://www.reuters.com/technology/apple-chip\nThe ||SRC|| marker and URL are metadata and will NOT be read aloud.'
    SEG_IDS+=("weather");  SEG_SEARCH+=("true")
    SEG_PROMPT+=("Briefly summarize today's ($TODAY_HUMAN) weather for $loc in one or two conversational sentences on a single line.$FMT")
    SEG_IDS+=("news");     SEG_SEARCH+=("true")
    SEG_PROMPT+=("Search the web and give me the 3 most important general news headlines happening right now today, $TODAY_HUMAN. One headline per line, one sentence each.$FMT")
    SEG_IDS+=("techfin");  SEG_SEARCH+=("true")
    SEG_PROMPT+=("Search the web for the latest interesting tech and finance news as of today, $TODAY_HUMAN. Give me 3 tech headlines and 2 financial market headlines — one headline per line, one sentence each.$FMT")
    if [ -n "$TICKERS" ]; then
        SEG_IDS+=("stocks"); SEG_SEARCH+=("true")
        SEG_PROMPT+=("Search the web for the latest stock price and news as of today, $TODAY_HUMAN for these tickers: $TICKERS. Put EACH ticker on its own separate line with its current price, percent change, and one key news item if there is one.$FMT")
    fi
    SEG_IDS+=("watch");    SEG_SEARCH+=("true")
    SEG_PROMPT+=("Search the web and recommend two interesting stocks or investments to watch today, $TODAY_HUMAN. Put EACH recommendation on its own separate line with the ticker, current price, why it's worth watching today specifically, and a one-sentence risk note. Keep each line under 60 words.$FMT")
}

have_net() { curl -s --max-time 8 -o /dev/null "$API/models" -H "Authorization: Bearer $API_KEY"; }

# --- generate one segment (text + TTS), cached by prompt hash ----------------
gen_segment() {
    local id="$1" search="$2" prompt="$3"
    local hash; hash="$(printf '%s' "$prompt" | md5sum | cut -d' ' -f1)"
    local cmp3="$TODAY_CACHE/${id}_${hash}.mp3" ctxt="$TODAY_CACHE/${id}_${hash}.txt"
    local clinks="$TODAY_CACHE/${id}_${hash}.links"  # per-sentence "sentence<TAB>url" map
    [ -s "$cmp3" ] && [ -s "$ctxt" ] && return 0

    local resp raw
    if [ "$search" = "true" ]; then
        resp="$(curl -s --max-time 90 "$API/responses" -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg m "$MODEL" --arg p "$prompt" \
                '{model:$m, input:[{role:"user",content:$p}], tools:[{type:"web_search"}]}')")"
        raw="$(printf '%s' "$resp" | jq -r '[.output[]? | select(.type=="message") | .content[]? | select(.type=="output_text") | .text] | join("")')"
    else
        resp="$(curl -s --max-time 60 "$API/chat/completions" -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg m "$MODEL" --arg p "$prompt" \
                '{model:$m, messages:[{role:"user",content:$p}], temperature:0.7}')")"
        raw="$(printf '%s' "$resp" | jq -r '.choices[0].message.content')"
    fi
    [ -z "$raw" ] || [ "$raw" = "null" ] && return 1       # quietly give up on this segment
    # Keep the raw response beside the cache for diagnosis (e.g. "why did this
    # item get no link?"); the daily cache cleanup prunes it with everything else.
    printf '%s' "$resp" > "$TODAY_CACHE/${id}_${hash}.resp" 2>/dev/null

    # Split the answer into sentences and attach EACH sentence's OWN reference,
    # taken from xAI's real citations — the web_search response carries url
    # citations as annotations with character spans into the text (and/or a
    # citations list with inline [n] markers). We map every reference to the
    # sentence it covers, so a page with N sources yields up to N independently
    # clickable caption lines. The spoken/displayed text never contains a URL;
    # links live only in the per-sentence map, and the voice reads the whole
    # cleaned text as one. python parses the response (sentence split matches
    # photo.lua, which trusts this list); plain cleaning is the fallback.
    local text links_tsv=""
    if command -v python3 >/dev/null 2>&1; then
        local parsed
        parsed="$(SEG_RESP="$resp" SEG_SEARCH_FLAG="$search" python3 - <<'PY'
import os, re, json
try:
    resp = json.loads(os.environ.get("SEG_RESP", "") or "{}")
except Exception:
    resp = {}
search = os.environ.get("SEG_SEARCH_FLAG", "") == "true"

def host_bad(u):
    return bool(re.search(r'api\.x\.ai|//x\.ai|grok\.com', u or ""))

text, anns_off, citations = "", [], []     # (start,end,url) with offsets; ordered url list
if search:
    base = 0
    for item in (resp.get("output") or []):
        if item.get("type") != "message":
            continue
        for c in (item.get("content") or []):
            if c.get("type") != "output_text":
                continue
            for a in (c.get("annotations") or []):
                u = a.get("url") or ""
                if not u:
                    continue
                s, e = a.get("start_index"), a.get("end_index")
                if isinstance(s, int) and isinstance(e, int):
                    anns_off.append((base + s, base + e, u))
                else:
                    citations.append(u)
            text += (c.get("text") or "")
            base = len(text)
    for u in (resp.get("citations") or []):
        if isinstance(u, str):
            citations.append(u)
else:
    try:
        text = resp["choices"][0]["message"]["content"] or ""
    except Exception:
        text = ""

if not text:
    print("{}"); raise SystemExit

def clean(s):
    s = re.sub(r'\|\|SRC\|\|.*$', '', s)              # drop the source marker + url
    s = re.sub(r'\*\*', '', s)
    s = re.sub(r'(?m)^#+\s*', '', s)
    s = re.sub(r'^\s*(?:[-*•]|\d+[.)])\s+', '', s)  # leading bullet / number
    s = re.sub(r'\[\[[0-9,]*\]\]\([^)]*\)', '', s)
    s = re.sub(r'\[[0-9,]*\]\([^)]*\)', '', s)
    s = re.sub(r'\[[^\[\]]*\]\([^)]*\)', '', s)
    s = re.sub(r'\[\[[0-9,]*\]\]', '', s)
    s = re.sub(r'\[[0-9,]*\]', '', s)
    s = re.sub(r'https?://[^ )]*', '', s)
    s = re.sub(r'\(\s*\)', '', s)
    s = re.sub(r'\s+([.,;:!?])', r'\1', s)
    return re.sub(r'\s+', ' ', s).strip()

def url_in(s, ls, le):
    m = re.search(r'\|\|SRC\|\|\s*(\S+)?', s)         # the model's own per-item source
    if m and m.group(1):
        u = m.group(1).rstrip('.,);]')
        if u.startswith('http') and not host_bad(u):
            return u
    if citations:                                    # inline [n] -> citations[n-1]
        m = re.search(r'\[(\d+)\]', s)
        if m:
            k = int(m.group(1)) - 1
            if 0 <= k < len(citations) and not host_bad(citations[k]):
                return citations[k]
    for a_s, a_e, u in anns_off:                      # citation span overlapping this item
        if not host_bad(u) and a_s < le and a_e > ls:
            return u
    m = re.search(r'https?://[^\s)\]]+', s)           # any inline url
    if m and not host_bad(m.group(0)):
        return m.group(0).rstrip('.,);]')
    return ""

# Divide into ITEMS by line — the model is asked to put one topic per line, so
# each news story / ticker / pick becomes its own clickable block. Offsets are
# tracked into the original text so citation spans still map. If the model
# ignored the line format (one blob), fall back to sentence splitting.
def split_lines(s):
    out, pos = [], 0
    for line in s.split('\n'):
        out.append((pos, pos + len(line), line)); pos += len(line) + 1
    return [(a, b, ln) for (a, b, ln) in out if ln.strip()]

def split_sentences(s):
    flat = re.sub(r'\|\|SRC\|\|\s*\S*', '', s)
    flat = re.sub(r'[\r\n]', ' ', flat)
    out, i = [], 0
    for m in re.finditer(r'[.!?]+(?:\s+|$)', flat):
        out.append((i, m.end(), flat[i:m.end()])); i = m.end()
    if i < len(flat):
        out.append((i, len(flat), flat[i:]))
    return out

units = split_lines(text)
if len(units) <= 1 and '||SRC||' not in text:         # one blob with no markers:
    units = split_sentences(text)                     # model ignored the format

sents, links = [], []
for ls, le, chunk in units:
    u = url_in(chunk, ls, le)
    c = clean(chunk)
    if c:
        sents.append(c); links.append(u)

# Last resort: if NO item got a url, harvest every external url anywhere in the
# response (search-tool results, nested annotations, any shape) in order, and
# only when the count matches the items 1:1, zip them on. An exact count match
# is the only case where positional assignment is trustworthy.
if search and links and not any(links):
    pool, seen = [], set()
    def walk(o):
        if isinstance(o, dict):
            for v in o.values(): walk(v)
        elif isinstance(o, list):
            for v in o: walk(v)
        elif isinstance(o, str):
            for m in re.finditer(r'https?://[^\s"\\)\]]+', o):
                u = m.group(0).rstrip('.,);]')
                if not host_bad(u) and u not in seen:
                    seen.add(u); pool.append(u)
    walk(resp)
    if len(pool) == len(links):
        links = pool

print(json.dumps({"text": " ".join(sents),
                  "sentences": [{"t": s, "u": u} for s, u in zip(sents, links)]}))
PY
)"
        text="$(printf '%s' "$parsed" | jq -r '.text' 2>/dev/null)"
        if [ -n "$text" ] && [ "$text" != "null" ]; then
            links_tsv="$(printf '%s' "$parsed" | jq -r '.sentences[] | [.t, .u] | @tsv' 2>/dev/null)"
        else
            text=""
        fi
    fi
    # Fallback (no python, or it produced nothing): the original plain cleaning.
    if [ -z "$text" ]; then
        text="$(printf '%s' "$raw" | sed \
                -e 's/\*\*//g' -e 's/^#\+[[:space:]]*//' \
                -e 's/\[\[[0-9,]*\]\]([^)]*)//g' \
                -e 's/\[[0-9,]*\]([^)]*)//g' \
                -e 's/\[[^][]*\]([^)]*)//g' \
                -e 's/\[\[[0-9,]*\]\]//g' -e 's/\[[0-9,]*\]//g' \
                -e 's#https\?://[^ )]*##g' -e 's/  */ /g' | awk 'NF{p=1} p{print}')"
        links_tsv=""
    fi
    [ -z "$text" ] && return 1

    local tmp; tmp="$(mktemp --suffix=.mp3)"
    if curl -s --max-time 90 -X POST "$API/tts" -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg t "$text" --arg v "$VOICE" '{text:$t, voice_id:$v, language:"en"}')" \
            --output "$tmp" \
       && [ -s "$tmp" ] && ! head -c1 "$tmp" | grep -q '{'; then
        printf '%s' "$text" > "$ctxt"
        [ -n "$links_tsv" ] && printf '%s\n' "$links_tsv" > "$clinks" || rm -f "$clinks"
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
LINKS_FILE="/tmp/ss_briefing.links"      # per-item "text<TAB>url" map photo.lua clicks
sub_show()    { printf '%s' "$1" > "$SUB_FILE"; }
sub_hide()    { printf '__HIDE__'  > "$SUB_FILE"; rm -f "$LINKS_FILE"; }
# Publish (or clear) the current segment's link map. Atomic (tmp+mv), and the
# callers publish it BEFORE the caption text so photo.lua never pairs new text
# with the previous segment's links.
set_links() {
    if [ -n "$1" ] && [ -s "$1" ]; then
        cp -f "$1" "$LINKS_FILE.part" 2>/dev/null && mv -f "$LINKS_FILE.part" "$LINKS_FILE"
    else
        rm -f "$LINKS_FILE"
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
    # Only undo the screensaver changes if we actually went live (if we aborted
    # while still getting ready, the screensaver was never touched).
    if [ "$WENT_LIVE" = 1 ]; then
        rm -f "$LIVE_FILE"                  # HUD comes back, mute lifts
        # Longer soft-drop of the grokmorning music, then stop it.
        if [ -n "$BGM_PID" ]; then
            fade_vol "$BGM_SOCK" "$GBGM_VOL" 0 "$FADE_OUT"
            jsock "$BGM_SOCK" '{"command":["quit"]}' >/dev/null 2>&1
            kill "$BGM_PID" 2>/dev/null
        fi
        # Soft RESUME of the slideshow's own music (start silent, unpause, fade up).
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
                                            # (MUST be non-empty — file_exists needs size>0)
    # Soft-drop the slideshow's own music, then pause it (remember its volume).
    SS_VOL="$(get_vol "$AUDIO_SOCK")"; [ -n "$SS_VOL" ] || SS_VOL="$VOLUME"
    fade_vol "$AUDIO_SOCK" "$SS_VOL" 0 "$FADE_IN"
    ss_music_pause true
    # GrokMorning bgm via its own mpv (looped) so we can fade it out later.
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

# Instant premade greeting while the first real segment is still generating.
play_welcome() {
    [ -d "$WELCOME_DIR" ] || return 0
    local wmp3 wtxt
    wmp3="$(find "$WELCOME_DIR" -maxdepth 1 -type f -iname '*.mp3' 2>/dev/null | shuf -n1)"
    [ -n "$wmp3" ] && [ -s "$wmp3" ] || return 0
    wtxt="${wmp3%.*}.txt"
    set_links ""                        # the premade greeting has no source links
    [ -s "$wtxt" ] && sub_show "$(cat "$wtxt")" || sub_hide
    SKIP=0; STEP=1
    ffplay -nodisp -autoexit -loglevel quiet -af "volume=${VOICE_GAIN}" "$wmp3" >/dev/null 2>&1 &
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

    # Generate everything in parallel, but DON'T touch the screensaver yet — it
    # keeps playing normally (music + HUD on) through the whole "getting ready"
    # phase, until the first segment is actually ready.
    prep >/dev/null 2>&1 & PREP_BG=$!

    local f_id="${SEG_IDS[0]}" f_prompt="${SEG_PROMPT[0]}"
    local f_hash; f_hash="$(printf '%s' "$f_prompt" | md5sum | cut -d' ' -f1)"
    local f_mp3="$TODAY_CACHE/${f_id}_${f_hash}.mp3"
    local waited=0
    while [ ! -s "$f_mp3" ] && [ "$waited" -lt 180 ] && [ "$SKIP" = 0 ]; do
        sleep 0.5; waited=$((waited+1))
    done
    [ -s "$f_mp3" ] || gen_segment "$f_id" "${SEG_SEARCH[0]}" "$f_prompt"
    [ -s "$f_mp3" ] || end_play    # nothing came back — abort quietly (nothing was touched yet)

    # READY → flip the screensaver into briefing mode (fade music down, hide HUD,
    # start bgm). photo.lua shows the "GROK <time of day>" title at this moment.
    go_live
    [ -n "$BGM_PID" ] && sleep "$SPEAK_DELAY"   # a little music before the first words
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

        set_links "$TODAY_CACHE/${id}_${hash}.links"
        [ -s "$ctxt" ] && sub_show "$(cat "$ctxt")" || sub_hide
        ffplay -nodisp -autoexit -loglevel quiet -af "volume=${VOICE_GAIN}" "$cmp3" >/dev/null 2>&1 &
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
    local target prep_at last_prep="" last_play="" last_clean="" today now t
    while true; do
        # Re-read GROK_TIME from the conf each pass so editing it takes effect
        # within ~30s without restarting the screensaver. Keying last_prep/last_play
        # on "day+target" also lets a changed time re-fire later the same day.
        t="$(. "$SS_CONF" 2>/dev/null; printf '%s' "${GROK_TIME:-07:30}")"
        target="$(to_min "$t")"; prep_at=$(( target - 5 )); [ "$prep_at" -lt 0 ] && prep_at=0
        today="$(date '+%Y-%m-%d')"
        now=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
        # Once a day, drop stale cache dirs (briefings that were never used).
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
    for c in jq curl ffplay ffmpeg socat mpv; do
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
