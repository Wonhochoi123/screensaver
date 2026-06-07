#!/bin/bash
# =============================================================================
#  mpv Photo & Video Screensaver — Clean Architecture (App/PC/TV agnostic)
#
#  Single source of truth: the export block below. Each value is declared ONCE
#  in reference-preserving form — SINGLE-quoted, so $HOME / $APP_DIR stay
#  literal here (these are templates, not yet resolved). The installer writes
#  them to config/screensaver.conf through an UNQUOTED heredoc: one round of
#  expansion turns $APP_DIR into its value "$HOME/Screensaver-App", which still
#  carries the reference, so the written file stays portable (no machine-
#  specific absolute paths). The installer then SOURCES that file, which
#  resolves every level correctly, top-down — and from then on runs on the
#  exact values every runtime script will. Nothing downstream hardcodes a path.
#
#  Two rules make the source step resolve fully:
#    (1) every referenced var is present in the file, and
#    (2) it is listed before anything that references it (dependency order).
#  A single `eval` only expands ONE level, which is why we must NOT eval the
#  nested vars to resolve them — we source instead.
# =============================================================================
set -u

# -----------------------------------------------------------------------------
#  DEFINE ONCE: portable templates (single-quoted) + tunables.
# -----------------------------------------------------------------------------
export APP_DIR='$HOME/Screensaver-App'
export DATA_DIR='$APP_DIR/Data'
export CFG='$APP_DIR/config'
export BASE_DIR='$HOME/Pictures/Screensavers'
export MEDIA_DIR='$DATA_DIR/Media'
export MUSIC_DIR='$DATA_DIR/Music'
export MAP_DIR='$DATA_DIR/Maps'
export OPT_DIR='$DATA_DIR/Optimized_Vids'
export TITLE_DIR='$DATA_DIR/TitleCards'
export PLAYLIST_DIR='$DATA_DIR/Playlist'
export PLAYLIST='$PLAYLIST_DIR/playlist.m3u'
export POLICE='$APP_DIR/xmp-police.sh'
export FONT_DIR='$MEDIA_DIR/Fonts'
export AUDIO_SOCK='/tmp/ss_audio.sock'

export PHOTO_DURATION=7        # seconds each still photo is shown (videos play in full)
export VOLUME=70               # mpv startup volume (0-100)
export IDLE_TIMEOUT_MS=300000  # idle ms before the screensaver auto-launches (= 5 min)
export MIN_LOAD_SECS=2         # minimum seconds the "please wait" screen stays visible
export VID_RESCAN_SECS=300     # how often vid-daemon rescans Media/ for new videos

# Offline place-name resolution (GeoNames). The screensaver resolves the nearby
# prominent landmark + city/state/country ENTIRELY OFFLINE from a local SQLite
# built once by config/build-geodb.sh. No API key, no rate limit, no runtime
# network. GEONAMES_COUNTRIES is a space-separated list of ISO country codes to
# index (small, fast); leave it EMPTY to index the whole planet (~390MB
# download, larger DB). Data © GeoNames, licensed CC-BY 4.0.
export GEONAMES_COUNTRIES='US CA'
export GEODB='$MAP_DIR/geo/geonames.sqlite'

# Resolve ONLY APP_DIR (one level — it nests just $HOME) so we know where the
# config goes. Everything deeper is resolved by sourcing the file we write.
eval "REAL_APP=\"$APP_DIR\""
mkdir -p "$REAL_APP/config"

# -----------------------------------------------------------------------------
#  Compile the single source of truth. Unquoted heredoc + single-quoted sources
#  => the file keeps $HOME / $VAR references (portable). Order = dependency order.
# -----------------------------------------------------------------------------
echo "▶ Writing screensaver.conf (single source of truth)..."
cat > "$REAL_APP/config/screensaver.conf" << CONF
# =============================================================================
#  Screensaver-App — central configuration  (AUTO-GENERATED, single source).
#  Edit a value here and it applies everywhere; every script sources this file.
#  Keep entries in dependency order so they resolve cleanly when sourced.
# =============================================================================
export APP_DIR="$APP_DIR"
export DATA_DIR="$DATA_DIR"
export CFG_DIR="$CFG"
export BASE_DIR="$BASE_DIR"
export MEDIA_DIR="$MEDIA_DIR"
export MUSIC_DIR="$MUSIC_DIR"
export MAP_DIR="$MAP_DIR"
export OPT_DIR="$OPT_DIR"
export TITLE_DIR="$TITLE_DIR"
export PLAYLIST_DIR="$PLAYLIST_DIR"
export PLAYLIST="$PLAYLIST"
export POLICE="$POLICE"
export FONT_DIR="$FONT_DIR"
export AUDIO_SOCK="$AUDIO_SOCK"
export PHOTO_DURATION="$PHOTO_DURATION"
export VOLUME="$VOLUME"
export IDLE_TIMEOUT_MS="$IDLE_TIMEOUT_MS"
export MIN_LOAD_SECS="$MIN_LOAD_SECS"
export VID_RESCAN_SECS="$VID_RESCAN_SECS"
export GEONAMES_COUNTRIES="$GEONAMES_COUNTRIES"
export GEODB="$GEODB"
CONF

# Run the installer on its own config — this resolves every level, top-down.
. "$REAL_APP/config/screensaver.conf"
CFG="$CFG_DIR"   # legacy alias used by a few install steps below

echo "▶ Preparing strict folder architecture..."

rm -f "$HOME/.config/autostart/tv-watcher.desktop"
rm -f "$HOME/.local/share/applications/tv-screensaver-now.desktop"
pkill -f exif-daemon.sh 2>/dev/null || true
pkill -f xmp-police.sh 2>/dev/null || true
pkill -f vid-daemon.sh 2>/dev/null || true
pkill -f tv-watcher.sh 2>/dev/null || true
pkill -f idle-watcher.sh 2>/dev/null || true

if [ -d "$HOME/TV-Screensaver" ] && [ ! -d "$APP_DIR" ]; then
    mv "$HOME/TV-Screensaver" "$APP_DIR"
fi

mkdir -p "$CFG" "$MEDIA_DIR" "$MAP_DIR" "$MAP_DIR/geo" "$OPT_DIR" "$MUSIC_DIR" "$TITLE_DIR" "$PLAYLIST_DIR" \
         "$HOME/.config/autostart" "$HOME/.local/share/applications" "$FONT_DIR"

if [ -d "$BASE_DIR/_map" ]; then
    mv "$BASE_DIR/_map"/* "$MAP_DIR/" 2>/dev/null || true
    rm -rf "$BASE_DIR/_map"
fi
if [ -d "$BASE_DIR/optimized_vids" ]; then
    mv "$BASE_DIR/optimized_vids"/* "$OPT_DIR/" 2>/dev/null || true
    rm -rf "$BASE_DIR/optimized_vids"
fi

find "$BASE_DIR" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.webm' -o -iname '*.txt' \) -exec mv {} "$MEDIA_DIR/" \; 2>/dev/null || true

# =============================================================================
# 0. Dependencies (distro-aware, single transaction, VERIFIED)
# =============================================================================
echo "▶ Resolving and installing dependencies..."

REQUIRED_CMDS=(mpv exiftool python3 curl qrencode ffmpeg socat playerctl pactl fc-match unzip)

detect_pm() {
    for pm in dnf apt-get pacman zypper; do
        command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return; }
    done
    echo ""
}
PM="$(detect_pm)"

INSTALL=""
PKGS=""
case "$PM" in
  dnf)
    PKGS="mpv perl-Image-ExifTool python3 python3-qrcode python3-pillow curl qrencode ffmpeg socat playerctl pulseaudio-utils ImageMagick fontconfig xdotool unzip"
    INSTALL="sudo dnf install -y"
    ;;
  apt-get)
    PKGS="mpv libimage-exiftool-perl python3 python3-qrcode python3-pil curl qrencode ffmpeg socat playerctl pulseaudio-utils imagemagick fontconfig xdotool unzip"
    sudo apt-get update -y || true
    INSTALL="sudo apt-get install -y"
    ;;
  pacman)
    PKGS="mpv perl-image-exiftool python python-qrcode python-pillow curl qrencode ffmpeg socat playerctl libpulse imagemagick fontconfig xdotool unzip"
    INSTALL="sudo pacman -S --needed --noconfirm"
    ;;
  zypper)
    PKGS="mpv exiftool python3 python3-qrcode python3-Pillow curl qrencode ffmpeg socat playerctl pulseaudio-utils ImageMagick fontconfig xdotool unzip"
    INSTALL="sudo zypper install -y"
    ;;
  *)
    echo "⚠ No supported package manager (dnf/apt/pacman/zypper) found."
    ;;
esac

if [ -n "$INSTALL" ]; then
    echo "▶ Using ${PM}: installing all packages in one go..."
    $INSTALL $PKGS || echo "⚠ Package manager reported errors — verifying what actually landed below."
fi

echo "▶ Verifying runtime tools..."
MISSING=()
for c in "${REQUIRED_CMDS[@]}"; do
    if command -v "$c" >/dev/null 2>&1; then
        printf '   ✓ %s\n' "$c"
    else
        printf '   ✗ %s  (MISSING)\n' "$c"
        MISSING+=("$c")
    fi
done
if command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1; then
    printf '   ✓ ImageMagick (magick/convert)\n'
else
    printf '   ✗ ImageMagick (magick/convert)  (MISSING)\n'
    MISSING+=("ImageMagick")
fi

FONT_BASE="https://raw.githubusercontent.com/JulietaUla/Montserrat/master/fonts/ttf"
got_font=0
for w in ExtraBold SemiBold; do
    if curl -fsSL --create-dirs -o "$FONT_DIR/Montserrat-$w.ttf" "$FONT_BASE/Montserrat-$w.ttf"; then
        got_font=1
    else
        echo "⚠ Could not fetch Montserrat-$w."
    fi
done
find "$FONT_DIR" -name 'Montserrat-*.ttf' -size 0 -delete 2>/dev/null || true

# Media/Fonts is NOT on fontconfig's default search path, so register it. This
# is the only per-machine bit written outside the app dir — re-run the installer
# on a new computer to recreate it. (The mpv/ffmpeg calls also point at FONT_DIR
# explicitly, so the fonts still work if you copy the app folder without it.)
if [ "$got_font" = 1 ]; then
    FC_CONF_DIR="$HOME/.config/fontconfig/conf.d"
    mkdir -p "$FC_CONF_DIR"
    cat > "$FC_CONF_DIR/00-screensaver-fonts.conf" << FCEOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <dir>$FONT_DIR</dir>
</fontconfig>
FCEOF
    fc-cache -f "$FONT_DIR" >/dev/null 2>&1 || true
    echo "▶ Montserrat fonts installed to $FONT_DIR and registered."
fi

# =============================================================================
# 1. input.conf  (socket path injected from config via placeholder)
# =============================================================================
echo "▶ Writing input.conf..."
cat > "$CFG/input.conf" << 'EOF'
MBTN_LEFT   script-message handle-left-click
MBTN_RIGHT  quit
WHEEL_UP    quit
WHEEL_DOWN  quit
ESC         quit
q           quit

SPACE      script-message ss-toggle-pause
PLAY       script-message ss-toggle-pause
PAUSE      script-message ss-toggle-pause
PLAYPAUSE  script-message ss-toggle-pause
p          script-message ss-toggle-pause

RIGHT playlist-next
LEFT  playlist-prev
UP    script-message hud-zoom-in
DOWN  script-message hud-zoom-out

PGDWN script-message month-next
PGUP  script-message month-prev
END   script-message year-next
HOME  script-message year-prev

NEXT run bash -c "printf '%s\n' '{\"command\":[\"playlist-next\"]}' | socat - UNIX-CONNECT:@@AUDIO_SOCK@@ 2>/dev/null"
PREV run bash -c "printf '%s\n' '{\"command\":[\"playlist-prev\"]}' | socat - UNIX-CONNECT:@@AUDIO_SOCK@@ 2>/dev/null"
]    run bash -c "printf '%s\n' '{\"command\":[\"playlist-next\"]}' | socat - UNIX-CONNECT:@@AUDIO_SOCK@@ 2>/dev/null"
[    run bash -c "printf '%s\n' '{\"command\":[\"playlist-prev\"]}' | socat - UNIX-CONNECT:@@AUDIO_SOCK@@ 2>/dev/null"

= add volume 5
- add volume -5
EOF
sed -i "s#@@AUDIO_SOCK@@#${AUDIO_SOCK}#g" "$CFG/input.conf"

# =============================================================================
# 2. photo.lua  (paths come from the environment exported by the config)
# =============================================================================
echo "▶ Writing photo.lua..."
cat > "$CFG/photo.lua" << 'EOF'
local utils = require "mp.utils"
local msg   = require "mp.msg"

-- Paths come from the environment (exported by screensaver.conf, which
-- launch.sh sources before starting mpv). The env() fallbacks keep photo.lua
-- working even if it is ever loaded outside launch.sh.
local function env(name, default)
    local v = os.getenv(name)
    if v and v ~= "" then return v end
    return default
end

local APP_DIR    = env("APP_DIR",   (os.getenv("HOME") or "~") .. "/Screensaver-App")
local DATA_DIR   = env("DATA_DIR",   APP_DIR .. "/Data")
local CFG_DIR    = env("CFG_DIR",    APP_DIR .. "/config")
local MEDIA_DIR  = env("MEDIA_DIR",  DATA_DIR .. "/Media")
local OPT_DIR    = env("OPT_DIR",    DATA_DIR .. "/Optimized_Vids")
local MAP_DIR    = env("MAP_DIR",    DATA_DIR .. "/Maps")

local builder    = CFG_DIR .. "/build-minimap.sh"
local AUDIO_SOCK = env("AUDIO_SOCK", "/tmp/ss_audio.sock")

local ZOOMS        = {11, 14, 16}
local RING_COLORS  = {"#FFFFFF", "#B3E5FC", "#4FC3F7"}
local DEFAULT_ZIDX = 1

local ov       = mp.create_osd_overlay("ass-events")
local pause_ov = mp.create_osd_overlay("ass-events")
pause_ov.res_x = 1920
pause_ov.res_y = 1080
local qr_coord_ov  = mp.create_osd_overlay("ass-events")
local map_coord_ov = mp.create_osd_overlay("ass-events")

local seq       = 0
local prewarmed = {}
local cur       = { seq = 0, path = nil, orig = nil, lat = nil, lon = nil, mdir = nil, zidx = DEFAULT_ZIDX, w = 552, h = 616, auto = true }

local MONTHS = {jan=1,feb=2,mar=3,apr=4,may=5,jun=6,jul=7,aug=8,sep=9,oct=10,nov=11,dec=12}

local DISPLAY_W, DISPLAY_H = nil, nil
local BLUR_W, BLUR_H, BLUR_ROT = nil, nil, nil

local function refresh_display_size()
    local w = mp.get_property_number("display-width") or 0
    local h = mp.get_property_number("display-height") or 0
    if w < 320 or h < 320 then
        w = mp.get_property_number("osd-width") or 0
        h = mp.get_property_number("osd-height") or 0
    end
    if w >= 320 and h >= 320 then
        if DISPLAY_W ~= w or DISPLAY_H ~= h then
            DISPLAY_W, DISPLAY_H = w, h
            local f = io.open(APP_DIR .. "/display.conf", "w")
            if f then f:write(string.format("%dx%d", w, h)); f:close() end
        end
    end
    return DISPLAY_W or 1920, DISPLAY_H or 1080
end

local image_ext = {jpg=true, jpeg=true, png=true, webp=true, bmp=true,
                   tif=true, tiff=true, gif=true, jfif=true}

local function get_video_rotation(path)
    local rot = mp.get_property_number("video-params/rotate")
    if not rot then
        local tracks = mp.get_property_native("track-list")
        if tracks then
            for _, t in ipairs(tracks) do
                if t.type == "video" and t.selected and t["demux-rotation"] then
                    rot = t["demux-rotation"]
                    break
                end
            end
        end
    end
    
    if not rot and path then
        local pext = (path:match("%.([^%.]+)$") or ""):lower()
        if image_ext[pext] then
            local safe_path = path:gsub("'", "'\\''")
            local cmd = string.format("exiftool -s3 -n -Orientation '%s' 2>/dev/null", safe_path)
            local f = io.popen(cmd)
            if f then
                local val = f:read("*a")
                f:close()
                local o = tonumber(val and val:match("%d+"))
                if o == 6 then rot = 90
                elseif o == 8 then rot = 270
                elseif o == 3 then rot = 180
                end
            end
        end
    end

    rot = rot or 0
    return ((rot % 360) + 360) % 360
end

local function apply_image_blur_vf(path)
    local w, h = refresh_display_size()
    local rot = get_video_rotation(path)
    
    BLUR_W, BLUR_H, BLUR_ROT = w, h, rot

    if rot == 90 or rot == 270 then
        w, h = h, w
    end

    local vf = string.format(
        "lavfi=[split[bg][fg];" ..
        "[bg]scale=640:360,setsar=1,gblur=sigma=50,scale=%d:%d,setsar=1[b];" ..
        "[fg]scale=%d:%d:force_original_aspect_ratio=decrease,setsar=1[f];" ..
        "[b][f]overlay=(W-w)/2:(H-h)/2,setsar=1]",
        w, h, w, h)
    mp.set_property("vf", vf)
end

local is_video = {mp4=true, mkv=true, mov=true, m4v=true, webm=true}
mp.add_hook("on_load", 10, function()
    local path = mp.get_property("stream-open-filename")
    if not path then return end

    if path:find("/TitleCards/") then
        mp.set_property("vf", "")
        return
    end

    local ext = (path:match("%.([^%.]+)$") or ""):lower()

    if is_video[ext] then
        local dir, file = path:match("^(.-)/([^/]+)$")
        if dir and file and not dir:match("/Optimized_Vids$") then
            local base_name = file:match("(.+)%.[^%.]+$") or file
            local opt_path = OPT_DIR .. "/" .. base_name .. ".mp4"
            local fi = utils.file_info(opt_path)
            if fi and fi.size and fi.size > 0 then
                mp.set_property("stream-open-filename", opt_path)
            end
        end
        mp.set_property("vf", "")
        return
    end

    if image_ext[ext] then
        refresh_display_size()
        if DISPLAY_W then
            apply_image_blur_vf(path)
        else
            mp.set_property("vf", "")
        end
    end
end)

local function file_exists(p)
    local fi = utils.file_info(p)
    return fi and fi.size and fi.size > 0
end

local function normalize_date(s)
    if not s then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("(%a+),", "%1")
    local function mk(y, mo, d)
        y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
        if not (y and mo and d) then return s end
        if y < 100 then y = y + 2000 end
        if mo < 1 or mo > 12 or d < 1 or d > 31 then return s end
        local t = os.time{year = y, month = mo, day = d, hour = 12}
        return t and os.date("%b %d, %Y", t) or s
    end
    local dpart = s:match("^(.-)%s+%d%d?:%d%d") or s
    local y, mo, d = dpart:match("^(%d%d%d%d)[-/:.](%d%d?)[-/:.](%d%d?)")
    if y then return mk(y, mo, d) end
    y, mo, d = dpart:match("^(%d%d%d%d)(%d%d)(%d%d)$")
    if y then return mk(y, mo, d) end
    mo, d, y = dpart:match("^(%d%d?)[-/:.](%d%d?)[-/:.](%d%d%d%d)")
    if y then return mk(y, mo, d) end
    local mname, dd, yy = dpart:match("(%a+)%.?%s+(%d%d?)[a-z]*,?%s+(%d%d%d%d)")
    if mname and MONTHS[mname:sub(1,3):lower()] then return mk(yy, MONTHS[mname:sub(1,3):lower()], dd) end
    dd, mname, yy = dpart:match("^(%d%d?)[a-z]*%s+(%a+)%.?,?%s+(%d%d%d%d)")
    if mname and MONTHS[mname:sub(1,3):lower()] then return mk(yy, MONTHS[mname:sub(1,3):lower()], dd) end
    return s
end

local function parse_coord(s)
    if not s then return nil end
    s = tostring(s):gsub("%(.-%)", ""):upper()
    local nums = {}
    for n in s:gmatch("([%+%-]?%d+%.?%d*)") do table.insert(nums, tonumber(n)) end
    local dir = s:match("([NSEW])")
    local v = nil
    if #nums == 1 then v = nums[1]
    elseif #nums == 2 then v = nums[1] + (nums[2]/60)
    elseif #nums >= 3 then v = nums[1] + (nums[2]/60) + (nums[3]/3600)
    end
    if v and dir and (dir == "S" or dir == "W") then v = -math.abs(v) end
    return v
end

local function parse_gps(value)
    if not value then return nil, nil end
    value = value:gsub("%(.-%)", ""):upper()
    local nums = {}
    for n in value:gmatch("([%+%-]?%d+%.?%d*)") do table.insert(nums, tonumber(n)) end
    local dirs = {}
    for d in value:gmatch("([NSEW])") do table.insert(dirs, d) end
    if #nums == 2 then
        local lat, lon = nums[1], nums[2]
        if dirs[1] == "S" then lat = -math.abs(lat) end
        if dirs[2] == "W" or (dirs[1] == "W" and not dirs[2]) then lon = -math.abs(lon) end
        return lat, lon
    elseif #nums == 6 then
        local lat = nums[1] + (nums[2] or 0)/60 + (nums[3] or 0)/3600
        local lon = nums[4] + (nums[5] or 0)/60 + (nums[6] or 0)/3600
        if dirs[1] == "S" then lat = -math.abs(lat) end
        if dirs[2] == "W" or (dirs[1] == "W" and not dirs[2]) then lon = -math.abs(lon) end
        return lat, lon
    elseif #nums == 4 then
        local lat = nums[1] + (nums[2] or 0)/60
        local lon = nums[3] + (nums[4] or 0)/60
        if dirs[1] == "S" then lat = -math.abs(lat) end
        if dirs[2] == "W" or (dirs[1] == "W" and not dirs[2]) then lon = -math.abs(lon) end
        return lat, lon
    end
    return nil, nil
end

local function find_sidecar(path)
    for _, c in ipairs({ (path:gsub("%.%w+$", "")) .. ".txt", path .. ".txt" }) do
        local fi = utils.file_info(c)
        if fi and fi.size and fi.size > 0 then return c end
    end
    return nil
end

local function parse_sidecar(path)
    local sc = find_sidecar(path)
    if not sc then return nil end
    local f = io.open(sc, "r"); if not f then return nil end
    local raw = f:read("*a"); f:close()
    if not raw then return nil end
    local o = {}
    for line in raw:gmatch("[^\r\n]+") do
        local key, val = line:match("^%s*([%a%s]-)%s*[:=]%s*(.+)%s*$")
        if key then
            key = key:lower():gsub("%s+", "")
            val = val:gsub("^%s+", ""):gsub("%s+$", "")
            if key == "date" or key == "datetime" or key == "datetimeoriginal" or key == "createdate" then
                o.date = normalize_date(val)
            elseif key == "gps" or key == "coords" or key == "coordinates" or key == "latlon" or key == "latlng" then
                local la, lo = parse_gps(val); if la and lo then o.lat, o.lon = la, lo end
            elseif key == "lat" or key == "latitude" then
                o.lat = parse_coord(val)
            elseif key == "lon" or key == "lng" or key == "long" or key == "longitude" then
                o.lon = parse_coord(val)
            elseif key == "location" or key == "place" or key == "city" then
                local la, lo = parse_gps(val)
                if la and lo then o.lat, o.lon = la, lo else o.location = val end
            end
        else
            local la, lo = parse_gps(line)
            if la and lo and la >= -90 and la <= 90 and lo >= -180 and lo <= 180 then
                o.lat, o.lon = la, lo
            end
        end
    end
    return o
end

local function compact_date(s)
    if not s then return s end
    return (s:gsub(" 0(%d),", " %1,"))
end

local COUNTRY_ABBR = {
    ["united states"]="US",["united states of america"]="US",["usa"]="US",
    ["canada"]="CA",["united kingdom"]="UK",["great britain"]="UK",
    ["south korea"]="KR",["korea"]="KR",["republic of korea"]="KR",["north korea"]="KP",
    ["japan"]="JP",["china"]="CN",["taiwan"]="TW",["france"]="FR",["germany"]="DE",
    ["italy"]="IT",["spain"]="ES",["portugal"]="PT",["netherlands"]="NL",["belgium"]="BE",
}
local SUBDIV_ABBR = {
    ["alabama"]="AL",["alaska"]="AK",["arizona"]="AZ",["arkansas"]="AR",["california"]="CA",
    ["colorado"]="CO",["connecticut"]="CT",["delaware"]="DE",["florida"]="FL",["georgia"]="GA",
    ["hawaii"]="HI",["idaho"]="ID",["illinois"]="IL",["indiana"]="IN",["iowa"]="IA",
    ["kansas"]="KS",["kentucky"]="KY",["louisiana"]="LA",["maine"]="ME",["maryland"]="MD",
    ["massachusetts"]="MA",["michigan"]="MI",["minnesota"]="MN",["mississippi"]="MS",
    ["missouri"]="MO",["montana"]="MT",["nebraska"]="NE",["nevada"]="NV",["new hampshire"]="NH",
    ["new jersey"]="NJ",["new mexico"]="NM",["new york"]="NY",["north carolina"]="NC",
    ["north dakota"]="ND",["ohio"]="OH",["oklahoma"]="OK",["oregon"]="OR",["pennsylvania"]="PA",
    ["rhode island"]="RI",["south carolina"]="SC",["south dakota"]="SD",["tennessee"]="TN",
    ["texas"]="TX",["utah"]="UT",["vermont"]="VT",["virginia"]="VA",["washington"]="WA",
    ["west virginia"]="WV",["wisconsin"]="WI",["wyoming"]="WY",["district of columbia"]="DC",
    ["ontario"]="ON",["quebec"]="QC",["québec"]="QC",["british columbia"]="BC",["alberta"]="AB",
}

local function abbr_country(name, code)
    if code and code ~= "" then return code:upper() end
    if name and name ~= "" then return COUNTRY_ABBR[name:lower()] or name end
    return name
end
local function abbr_subdiv(name, iso)
    if iso then
        local c = iso:match("%-(%a%a%a?)$")
        if c then return c end
    end
    if name and name ~= "" then return SUBDIV_ABBR[name:lower()] or name end
    return name
end

local function niagara_fix(landmark, city, state, country)
    local function check(s) return s and s:lower():find("niagara falls", 1, true) end
    if (check(city) or check(landmark)) and country == "US" then
        return landmark, city, "ON", "CA"
    end
    return landmark, city, state, country
end

local function join_loc(landmark, city, state, country)
    local p = {}
    if landmark and landmark ~= "" then table.insert(p, landmark) end
    if city and city ~= "" then
        if not landmark or landmark:lower() ~= city:lower() then table.insert(p, city) end
    end
    if state and state ~= "" then
        if not city or state:lower() ~= city:lower() then table.insert(p, state) end
    end
    if country and country ~= "" then table.insert(p, country) end
    return table.concat(p, ", ")
end

local function hud_geom()
    local win_w, win_h = refresh_display_size()
    local S   = math.floor(win_h * 0.27); S = S - (S % 4)
    local pad = math.floor(win_h * 0.02)
    local fs  = math.floor(win_h * 0.025 + 0.5)
    local gap = math.floor(win_h * 0.006)
    local text_cy = win_h - pad - math.floor(fs * 0.7)
    local img_top = (text_cy - math.floor(fs * 0.7) - gap) - S
    return {
        win_w = win_w, win_h = win_h, S = S, pad = pad, fs = fs,
        img_top = img_top, text_cy = text_cy,
        qr_x  = pad,             qr_cx  = pad + math.floor(S / 2),
        map_x = win_w - S - pad, map_cx = win_w - pad - math.floor(S / 2),
    }
end

local function get_hud_size()
    local L = hud_geom()
    return L.S, L.S, L.win_w, L.win_h
end

local function map_path(mdir, z, lat, lon, w, h, color)
    local c = color:gsub("#", "")
    return string.format("%s/hud_sat_%d_%.5f_%.5f_%dx%d_%s.bgra", mdir, z, lat, lon, w, h, c)
end
local function qr_path(mdir, lat, lon, w, h)
    return string.format("%s/hud_qr_%.5f_%.5f_%dx%d.bgra", mdir, lat, lon, w, h)
end

local function dms(v, pos, neg)
    local sign = v >= 0 and pos or neg
    v = math.abs(v)
    local d = math.floor(v)
    local m = math.floor((v - d) * 60)
    local s = math.floor((v - d - m / 60) * 3600 + 0.5)
    if s == 60 then s = 0; m = m + 1 end
    if m == 60 then m = 0; d = d + 1 end
    return string.format("%d°%d'%d\"%s", d, m, s, sign)
end
local function fmt_dms(lat, lon) return dms(lat, "N", "S") .. "   " .. dms(lon, "E", "W") end
local function fmt_dd(lat, lon)
    return string.format("%.5f°%s   %.5f°%s",
        math.abs(lat), lat >= 0 and "N" or "S",
        math.abs(lon), lon >= 0 and "E" or "W")
end

local function coord_tags(x, y, fs)
    return string.format(
        "{\\an5\\pos(%d,%d)\\fnMontserrat SemiBold\\fs%d\\1c&HFFFFFF&\\bord1\\3c&H000000&\\shad1\\4c&H000000&\\4a&H50&}",
        x, y, fs)
end

local function draw_coord_labels(L, lat, lon)
    qr_coord_ov.res_x  = L.win_w; qr_coord_ov.res_y  = L.win_h
    map_coord_ov.res_x = L.win_w; map_coord_ov.res_y = L.win_h
    qr_coord_ov.data  = coord_tags(L.qr_cx,  L.text_cy, L.fs) .. fmt_dms(lat, lon)
    map_coord_ov.data = coord_tags(L.map_cx, L.text_cy, L.fs) .. fmt_dd(lat, lon)
    qr_coord_ov:update()
    map_coord_ov:update()
end

local function clear_hud_osd()
    pcall(mp.command_native, {"overlay-remove", 1})
    pcall(mp.command_native, {"overlay-remove", 2})
    qr_coord_ov:remove()
    map_coord_ov:remove()
end

local function apply_qr(bgra_path, L)
    mp.command_native({"overlay-add", 1, L.qr_x, L.img_top, bgra_path, 0, "bgra", L.S, L.S, L.S * 4})
end

local function apply_minimap(bgra_path, L)
    mp.command_native({"overlay-add", 2, L.map_x, L.img_top, bgra_path, 0, "bgra", L.S, L.S, L.S * 4})
end

local function build_one(lat, lon, z, w, h, color, mdir, cb)
    local mimg = map_path(mdir, z, lat, lon, w, h, color)
    local qimg = qr_path(mdir, lat, lon, w, h)
    if file_exists(mimg) and file_exists(qimg) then
        if cb then cb(true) end
        return
    end
    mp.command_native_async({
        name = "subprocess", capture_stdout = true, capture_stderr = true,
        args = { builder, string.format("%.6f", lat), string.format("%.6f", lon),
                 tostring(z), mimg, qimg, mdir, tostring(w), tostring(h), color },
    }, function(ok, res)
        local good = file_exists(mimg) and file_exists(qimg)
        if not good then
            local tail = res and res.stderr and res.stderr:sub(-200) or ""
            msg.warn("HUD build failed (z=" .. z .. "): " .. tail)
        end
        if cb then cb(good) end
    end)
end

local function build_all(lat, lon, w, h, mdir, cb, i)
    i = i or 1
    if i > #ZOOMS then if cb then cb() end return end
    build_one(lat, lon, ZOOMS[i], w, h, RING_COLORS[i], mdir, function()
        build_all(lat, lon, w, h, mdir, cb, i + 1)
    end)
end

-- Read the date / GPS / location / landmark the police already extracted into
-- the "<media>.xmp" sidecar — no per-slide subprocess, no runtime network.
-- Falls back to file mtime for the date, and a ".txt" override (read live)
-- still wins on top.
local function xml_unescape(s)
    if not s then return s end
    return (s:gsub("&lt;", "<")
             :gsub("&gt;", ">")
             :gsub("&quot;", '"')
             :gsub("&apos;", "'")
             :gsub("&#39;", "'")
             :gsub("&amp;", "&"))
end

local function read_xmp(xmp_path)
    local f = io.open(xmp_path, "r")
    if not f then return nil end
    local raw = f:read("*a"); f:close()
    if not raw or raw == "" then return nil end
    local function tag(name)
        local v = raw:match("<" .. name .. ">(.-)</" .. name .. ">")
        return v and xml_unescape(v) or nil
    end
    return {
        date_iso = tag("exif:DateTimeOriginal") or tag("xmp:CreateDate") or tag("photoshop:DateCreated"),
        lat      = tonumber(tag("exif:GPSLatitude")),
        lon      = tonumber(tag("exif:GPSLongitude")),
        city     = tag("photoshop:City"),
        state    = tag("photoshop:State"),
        country  = tag("photoshop:Country"),
        landmark = tag("ss:Landmark"),
    }
end

local function iso_to_display(iso)
    if not iso then return nil end
    local y, mo, d = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if not y then return nil end
    local t = os.time{year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12}
    return t and os.date("%b %d, %Y", t) or nil
end

local function resolve_meta(orig_path, cb)
    local date, location, lat, lon = nil, "", nil, nil

    -- 1) Base values straight from the sidecar (a tiny file read, no subprocess).
    local x = read_xmp(orig_path .. ".xmp")
    if x then
        date     = iso_to_display(x.date_iso)
        lat, lon = x.lat, x.lon
        local landmark, city, region, country =
            niagara_fix(x.landmark, x.city, abbr_subdiv(x.state, nil), abbr_country(x.country, nil))
        location = join_loc(landmark, city, region, country)
    end

    -- 2) Date fallback: file mtime, if the sidecar carried no date.
    if not date then
        local fi = utils.file_info(orig_path)
        if fi and fi.mtime then date = os.date("%b %d, %Y", fi.mtime) end
    end

    -- 3) Manual ".txt" override wins (read live, so edits apply immediately).
    local sc = parse_sidecar(orig_path)
    if sc then
        if sc.date then date = sc.date end
        if sc.location and sc.location ~= "" then location = sc.location end
        if sc.lat and sc.lon then lat, lon = sc.lat, sc.lon end
    end

    if lat and (lat < -90  or lat > 90 ) then lat = nil end
    if lon and (lon < -180 or lon > 180) then lon = nil end

    cb({ date = date, location = location, lat = lat, lon = lon, mdir = MAP_DIR })
end

local pq        = {}
local pq_active = false

local function pq_next()
    if #pq == 0 then pq_active = false return end
    pq_active = true
    local path = table.remove(pq, 1)
    resolve_meta(path, function(m)
        if m.lat and m.lon then
            build_all(m.lat, m.lon, cur.w, cur.h, m.mdir, function()
                mp.add_timeout(0.3, pq_next)
            end)
        else
            mp.add_timeout(0.02, pq_next)
        end
    end)
end

local function start_prewarm()
    local pl = mp.get_property_native("playlist") or {}
    for _, e in ipairs(pl) do
        local f = e.filename
        if f and not prewarmed[f] then
            prewarmed[f] = true
            pq[#pq + 1] = f
        end
    end
    if not pq_active then pq_next() end
end

local function set_pause_indicator(paused)
    if paused then
        pause_ov.data =
            "{\\an7\\pos(0,0)\\bord0\\shad4\\3c&H000000&\\4c&H000000&\\1c&HFFFFFF&\\alpha&H40&\\p1}"
            .. "m 1772 70 l 1792 70 l 1792 128 l 1772 128 "
            .. "m 1808 70 l 1828 70 l 1828 128 l 1808 128{\\p0}"
        pause_ov:update()
    else
        pause_ov:remove()
    end
end
mp.observe_property("pause", "bool", function(_, v) set_pause_indicator(v or false) end)

mp.register_script_message("ss-toggle-pause", function()
    local newp = not mp.get_property_bool("pause")
    mp.set_property_bool("pause", newp)
    local v = newp and "true" or "false"
    mp.commandv("run", "/bin/sh", "-c",
        "printf '%s\\n' '{\"command\":[\"set_property\",\"pause\"," .. v .. "]}' | socat - UNIX-CONNECT:" .. AUDIO_SOCK .. " 2>/dev/null")
end)

local function show_current_zoom()
    if not (cur.lat and cur.lon and cur.mdir) then return end
    local z = ZOOMS[cur.zidx]
    local color = RING_COLORS[cur.zidx]
    local s = cur.seq
    local L = hud_geom()
    build_one(cur.lat, cur.lon, z, L.S, L.S, color, cur.mdir, function(ok)
        if s ~= seq then return end
        if ok then apply_minimap(map_path(cur.mdir, z, cur.lat, cur.lon, L.S, L.S, color), L) end
    end)
end

mp.register_script_message("hud-zoom-in", function()
    cur.auto = false
    if not cur.lat then return end
    local ni = math.min(#ZOOMS, cur.zidx + 1)
    if ni == cur.zidx then return end
    cur.zidx = ni
    show_current_zoom()
end)

mp.register_script_message("hud-zoom-out", function()
    cur.auto = false
    if not cur.lat then return end
    local ni = math.max(1, cur.zidx - 1)
    if ni == cur.zidx then return end
    cur.zidx = ni
    show_current_zoom()
end)

mp.register_script_message("handle-left-click", function()
    if not (cur.lat and cur.lon) then
        mp.command("script-message ss-toggle-pause")
        return
    end

    local mouse = mp.get_property_native("mouse-pos")
    if not mouse then return end

    local L = hud_geom()
    local in_qr = (mouse.x >= L.qr_x) and (mouse.x <= L.qr_x + L.S) and
                  (mouse.y >= L.img_top) and (mouse.y <= L.img_top + L.S)
    local in_map = (mouse.x >= L.map_x) and (mouse.x <= L.map_x + L.S) and
                   (mouse.y >= L.img_top) and (mouse.y <= L.img_top + L.S)

    if in_qr then
        local url = string.format("https://www.google.com/maps/?q=%.6f,%.6f", cur.lat, cur.lon)
        mp.command_native_async({
            name = "subprocess",
            args = {"xdg-open", url}
        }, function() end)

    elseif in_map then
        cur.auto = false
        cur.zidx = (cur.zidx % #ZOOMS) + 1
        show_current_zoom()

    else
        mp.command("script-message ss-toggle-pause")
    end
end)

mp.register_event("file-loaded", function()
    local path = mp.get_property("path")
    if not path then return end

    local orig_path = path
    if path:find("/Optimized_Vids/") then
        local orig_file = path:match("([^/]+)%.mp4$")
        if orig_file then
            orig_path = MEDIA_DIR .. "/" .. orig_file
        end
    end

    clear_hud_osd()
    ov:remove()
    seq = seq + 1
    local my_seq = seq
    prewarmed[orig_path] = true

    if path:find("/TitleCards/") then
        return
    end

    local L = hud_geom()
    local w, h, win_w, win_h = L.S, L.S, L.win_w, L.win_h

    do
        local pext = (path:match("%.([^%.]+)$") or ""):lower()
        if image_ext[pext] and DISPLAY_W then
            local current_rot = get_video_rotation(path)
            if BLUR_W ~= DISPLAY_W or BLUR_H ~= DISPLAY_H or BLUR_ROT ~= current_rot then
                apply_image_blur_vf(path)
            end
        end
    end

    resolve_meta(orig_path, function(m)
        if my_seq ~= seq then return end

        cur = { seq = my_seq, path = path, orig = orig_path, lat = m.lat, lon = m.lon, mdir = m.mdir, zidx = 1, w = w, h = h, auto = true }

        local date     = m.date
        local location = m.location or ""
        local mdir     = m.mdir

        -- Everything (date, admin, landmark) already comes from the XMP sidecar,
        -- resolved offline by the police. No runtime network lookups here.
        local function draw_text()
            local d = compact_date(date)
            local text = ""
            if d and location ~= "" then text = d .. "  |  " .. location
            elseif d then text = d
            elseif location ~= "" then text = location end

            if text == "" then ov:remove(); return end

            local L  = hud_geom()
            local fs = math.floor(L.win_h * 0.045)
            local cx = math.floor(L.win_w / 2)
            local baseline = L.win_h - math.floor(L.win_h * 0.085)

            ov.res_x = L.win_w
            ov.res_y = L.win_h
            ov.data = string.format(
                "{\\an5\\pos(%d,%d)\\fnMontserrat ExtraBold\\fs%d\\bord1\\3c&H000000&\\shad2\\4c&H000000&}%s",
                cx, baseline, fs, text)
            ov:update()
        end
        draw_text()

        if not (m.lat and m.lon) then
            mp.add_timeout(1.0, start_prewarm)
            return
        end

        local z = ZOOMS[cur.zidx]
        local color = RING_COLORS[cur.zidx]

        draw_coord_labels(L, m.lat, m.lon)

        build_one(m.lat, m.lon, z, w, h, color, mdir, function(ok)
            if my_seq ~= seq then return end
            if ok then
                apply_qr(qr_path(mdir, m.lat, m.lon, w, h), L)
                apply_minimap(map_path(mdir, z, m.lat, m.lon, w, h, color), L)
            end

            build_all(m.lat, m.lon, w, h, mdir, function()
                mp.add_timeout(0.5, start_prewarm)
            end)

            mp.add_timeout(1.8, function()
                if my_seq ~= seq then return end
                if cur.auto and cur.zidx < 2 then
                    cur.zidx = 2
                    show_current_zoom()
                end
            end)

            mp.add_timeout(3.6, function()
                if my_seq ~= seq then return end
                if cur.auto and cur.zidx < 3 then
                    cur.zidx = 3
                    show_current_zoom()
                end
            end)
        end)
    end)
end)

mp.register_event("shutdown", function()
    ov:remove()
    pause_ov:remove()
end)

-- ----------------------------------------------------------------------------
-- Playlist Chapters (Jump by Month)
-- ----------------------------------------------------------------------------
local function jump_month(direction)
    local pl = mp.get_property_native("playlist")
    local pos = mp.get_property_number("playlist-pos")
    if not pl or not pos then return end
    
    local current_idx = pos + 1
    
    local active_title = nil
    for i = current_idx, 1, -1 do
        local t = pl[i].title
        if t and t ~= "" and t ~= "Unknown Date" then
            active_title = t
            break
        end
    end
    
    local target_idx = nil
    
    if direction > 0 then
        for i = current_idx + 1, #pl do
            local t = pl[i].title
            if t and t ~= "" and t ~= "Unknown Date" and t ~= active_title then
                target_idx = i
                break
            end
        end
    else
        for i = current_idx - 1, 1, -1 do
            local t = pl[i].title
            if t and t ~= "" and t ~= "Unknown Date" and t ~= active_title then
                target_idx = i
                break
            end
        end
        if not target_idx and current_idx > 1 then target_idx = 1 end
    end
    
    if target_idx then
        mp.set_property_number("playlist-pos", target_idx - 1)
        mp.osd_message("⏭ Chapter: " .. (pl[target_idx].title or ""), 3)
    else
        mp.osd_message(direction > 0 and "End of Playlist" or "Start of Playlist", 2)
    end
end

mp.register_script_message("month-next", function() jump_month(1) end)
mp.register_script_message("month-prev", function() jump_month(-1) end)

-- ----------------------------------------------------------------------------
-- Playlist Chapters (Jump by Year)
-- ----------------------------------------------------------------------------
local function extract_year(title)
    if not title or title == "" or title == "Unknown Date" then return nil end
    return title:match("(%d%d%d%d)$")
end

local function jump_year(direction)
    local pl = mp.get_property_native("playlist")
    local pos = mp.get_property_number("playlist-pos")
    if not pl or not pos then return end
    
    local current_idx = pos + 1
    
    local active_year = nil
    for i = current_idx, 1, -1 do
        local y = extract_year(pl[i].title)
        if y then
            active_year = y
            break
        end
    end
    
    local target_idx = nil
    
    if direction > 0 then
        for i = current_idx + 1, #pl do
            local y = extract_year(pl[i].title)
            if y and y ~= active_year then
                target_idx = i
                break
            end
        end
    else
        local prev_year = nil
        for i = current_idx - 1, 1, -1 do
            local y = extract_year(pl[i].title)
            if y and y ~= active_year then
                if not prev_year then
                    prev_year = y
                    target_idx = i
                elseif y == prev_year then
                    target_idx = i
                else
                    break
                end
            end
        end
        if not target_idx and current_idx > 1 then target_idx = 1 end
    end
    
    if target_idx then
        mp.set_property_number("playlist-pos", target_idx - 1)
        local target_year = extract_year(pl[target_idx].title) or pl[target_idx].title or ""
        mp.osd_message("⏭ Year Chapter: " .. target_year, 3)
    else
        mp.osd_message(direction > 0 and "End of Playlist" or "Start of Playlist", 2)
    end
end

mp.register_script_message("year-next", function() jump_year(1) end)
mp.register_script_message("year-prev", function() jump_year(-1) end)

EOF

# =============================================================================
# 3. build-minimap.sh
# =============================================================================
echo "▶ Writing build-minimap.sh..."
cat > "$CFG/build-minimap.sh" << 'EOF'
#!/bin/bash
set -u

LAT="$1"; LON="$2"; Z="$3"; OUT_MAP="$4"; OUT_QR="$5"; CACHE="$6"
HUD_W="${7:-552}"; HUD_H="${8:-616}"; MAP_RING_COLOR="${9:-#FFFFFF}"

UA="Screensaver-App/1.0"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$CACHE"

if [ -s "$OUT_MAP" ] && [ -s "$OUT_QR" ]; then exit 0; fi

need_map=1; [ -s "$OUT_MAP" ] && need_map=0
need_qr=1;  [ -s "$OUT_QR"  ] && need_qr=0

if command -v magick >/dev/null 2>&1; then IM="magick"; else IM="convert"; fi
MAP_STYLE="satellite"

D=500
MARKER_COLOR='#ff5a4d'
RING=5
PAD=26
CANVAS=$(( D + PAD*2 ))
FULLH=$CANVAS
CX=$(( CANVAS/2 ))
MY=$(( PAD + D/2 ))
R=$(( D/2 ))

if [ "$need_qr" = 1 ]; then
    G_MAPS_URL="https://maps.google.com/?q=${LAT},${LON}"

    STYLED=0
    if python3 - "$G_MAPS_URL" "$TMP/qr_styled.png" "$D" <<'PY' 2>/dev/null
import sys, random
try:
    import qrcode
    from qrcode.image.styledpil import StyledPilImage
    try:
        from qrcode.image.styles.moduledrawers.pil import CircleModuleDrawer
    except Exception:
        from qrcode.image.styles.moduledrawers import CircleModuleDrawer
    from qrcode.image.styles.colormasks import SolidFillColorMask
    from PIL import Image, ImageDraw
except Exception:
    sys.exit(2)

url, out_png, D = sys.argv[1], sys.argv[2], int(sys.argv[3])
qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_H, border=0)
qr.add_data(url); qr.make(fit=True)
n = qr.modules_count

mask = SolidFillColorMask(back_color=(255, 255, 255, 0), front_color=(0, 0, 0, 255))
qr_img = qr.make_image(image_factory=StyledPilImage,
                       module_drawer=CircleModuleDrawer(),
                       color_mask=mask).convert("RGBA")

canvas = Image.new("RGBA", (D, D), (0, 0, 0, 0))
draw = ImageDraw.Draw(canvas)
draw.ellipse([0, 0, D - 1, D - 1], fill=(255, 255, 255, 255))    

pattern = Image.new("RGBA", (D, D), (0, 0, 0, 0))
pdraw = ImageDraw.Draw(pattern)

cell = int((D * 0.68) / float(n))
func = cell * n

qr_img = qr_img.resize((func, func), Image.LANCZOS)
cx = cy = D / 2.0
R = D / 2.0
half = func / 2.0

random.seed(len(url) * 7 + 13)

first_mod_x = cx - half + (cell / 2.0)
first_mod_y = cy - half + (cell / 2.0)
start_x = first_mod_x - (int(first_mod_x / cell) * cell)
start_y = first_mod_y - (int(first_mod_y / cell) * cell)

yy = start_y
while yy < D:
    xx = start_x
    while xx < D:
        if (xx - cx) ** 2 + (yy - cy) ** 2 <= (R - cell * 1.3) ** 2:
            if xx < (cx - half) or xx > (cx + half) or yy < (cy - half) or yy > (cy + half):
                if random.random() < 0.5:
                    r = cell * 0.40
                    pdraw.ellipse([xx - r, yy - r, xx + r, yy + r], fill=(0, 0, 0, 255))
        xx += cell
    yy += cell

pattern.alpha_composite(qr_img, (int(cx - half), int(cy - half)))

gradient = Image.new("RGBA", (D, D), (0, 0, 0, 0))
gdraw = ImageDraw.Draw(gradient)

center_color = (130, 40, 180)
edge_color = (30, 0, 60)

for rad in range(int(R), 0, -1):
    ratio = rad / R
    ease = ratio ** 1.5 
    r_col = int(center_color[0] + (edge_color[0] - center_color[0]) * ease)
    g_col = int(center_color[1] + (edge_color[1] - center_color[1]) * ease)
    b_col = int(center_color[2] + (edge_color[2] - center_color[2]) * ease)
    gdraw.ellipse([cx - rad, cy - rad, cx + rad, cy + rad], fill=(r_col, g_col, b_col, 255))

gradient.putalpha(pattern.getchannel("A"))

canvas.alpha_composite(gradient)
canvas.save(out_png)
PY
    then STYLED=1; fi

    if [ "$STYLED" != 1 ]; then
        qrencode -s 12 -m 2 -o "$TMP/qr_raw.png" "$G_MAPS_URL" || exit 6
        QR_FIT=330
        $IM "$TMP/qr_raw.png" -transparent white -resize ${QR_FIT}x${QR_FIT} "$TMP/qr_scaled.png"
        $IM -size ${D}x${D} xc:none -fill '#ffffffF2' -draw "circle $R,$R $R,1" "$TMP/qr_disc.png"
        QR_OFF=$(( (D - QR_FIT) / 2 ))
        $IM "$TMP/qr_disc.png" "$TMP/qr_scaled.png" -gravity northwest -geometry +${QR_OFF}+${QR_OFF} \
            -compose over -composite "$TMP/qr_styled.png"
    fi

    $IM -size ${CANVAS}x${FULLH} xc:none -fill black \
        -draw "circle ${CX},$((MY+4)) ${CX},$((MY+4-R))" \
        -blur 0x9 -channel A -evaluate multiply 0.5 +channel "$TMP/QR_shadow.png"
    $IM -size ${CANVAS}x${FULLH} xc:none \
        "$TMP/qr_styled.png" -gravity northwest -geometry +${PAD}+${PAD} -compose over -composite "$TMP/QR_disc.png"
    $IM -size ${CANVAS}x${FULLH} xc:none -stroke "#FFFFFF" -strokewidth ${RING} -fill none \
        -draw "circle ${CX},${MY} ${CX},$((MY-R))" "$TMP/QR_ring.png"
    $IM "$TMP/QR_ring.png" \( +clone -blur 0x4 -channel A -evaluate multiply 1.2 +channel \) \
        -compose over -composite "$TMP/QR_ringglow.png"

    $IM -size ${CANVAS}x${FULLH} xc:none -colorspace sRGB \
        "$TMP/QR_shadow.png" -composite "$TMP/QR_disc.png" -composite \
        "$TMP/QR_ringglow.png" -composite "$TMP/QR_final.png" || exit 5

    $IM "$TMP/QR_final.png" -resize ${HUD_W}x${HUD_H}\! -depth 8 bgra:"$OUT_QR" || exit 7
fi

if [ "$need_map" = 1 ]; then
    read XT YT PX PY < <(python3 - "$LAT" "$LON" "$Z" <<'PY'
import math, sys
lat, lon, z = float(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3])
n = 2.0 ** z
xf = (lon + 180.0) / 360.0 * n
lr = math.radians(lat)
yf = (1.0 - math.log(math.tan(lr) + 1.0/math.cos(lr)) / math.pi) / 2.0 * n
xt, yt = math.floor(xf), math.floor(yf)
print(xt, yt, round((xf-(xt-1))*256), round((yf-(yt-1))*256))
PY
) || exit 1

    SUBS=(a b c)
    for dy in -1 0 1; do for dx in -1 0 1; do
        tx=$((XT+dx)); ty=$((YT+dy))
        if [ "$MAP_STYLE" = "satellite" ]; then
            tf="$CACHE/sat_${Z}_${tx}_${ty}.png"
            tf_lab="$CACHE/lab_${Z}_${tx}_${ty}.png"
            url="https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/${Z}/${ty}/${tx}"
            url_lab="https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/${Z}/${ty}/${tx}"
        else
            tf="$CACHE/${Z}_${tx}_${ty}.png"
            sub=${SUBS[$(( (tx+ty) % 3 ))]}
            url="https://${sub}.tile.openstreetmap.org/${Z}/${tx}/${ty}.png"
        fi
        
        if [ ! -s "$tf" ]; then
            curl -sf --max-time 8 --create-dirs -A "$UA" -o "$tf" "$url" &
        fi
        if [ "$MAP_STYLE" = "satellite" ] && [ ! -s "$tf_lab" ]; then
            curl -sf --max-time 8 --create-dirs -A "$UA" -o "$tf_lab" "$url_lab" &
        fi
    done; done
    wait 

    for dy in -1 0 1; do for dx in -1 0 1; do
        tx=$((XT+dx)); ty=$((YT+dy))
        if [ "$MAP_STYLE" = "satellite" ]; then
            tf="$CACHE/sat_${Z}_${tx}_${ty}.png"
            tf_lab="$CACHE/lab_${Z}_${tx}_${ty}.png"
            if [ -s "$tf_lab" ]; then
                $IM "$tf" "$tf_lab" -compose over -composite "$TMP/t_${dx}_${dy}.png"
            else
                cp "$tf" "$TMP/t_${dx}_${dy}.png"
            fi
        else
            tf="$CACHE/${Z}_${tx}_${ty}.png"
            cp "$tf" "$TMP/t_${dx}_${dy}.png"
        fi
    done; done

    $IM \
      \( "$TMP/t_-1_-1.png" "$TMP/t_0_-1.png" "$TMP/t_1_-1.png" +append \) \
      \( "$TMP/t_-1_0.png"  "$TMP/t_0_0.png"  "$TMP/t_1_0.png"  +append \) \
      \( "$TMP/t_-1_1.png"  "$TMP/t_0_1.png"  "$TMP/t_1_1.png"  +append \) \
      -append "$TMP/stitch.png" || exit 3

    OFFX=$(( PX - D/2 )); OFFY=$(( PY - D/2 ))
    $IM "$TMP/stitch.png" -crop ${D}x${D}+${OFFX}+${OFFY} +repage \
        -background none -gravity center -extent ${D}x${D} "$TMP/crop.png" || exit 4

    $IM -size ${D}x${D} xc:none -fill white -draw "circle $R,$R $R,1" "$TMP/mask.png"
    $IM "$TMP/crop.png" "$TMP/mask.png" -alpha off -compose CopyOpacity -composite "$TMP/disc.png"
    $IM -size ${CANVAS}x${FULLH} xc:none -fill black \
        -draw "circle ${CX},$((MY+4)) ${CX},$((MY+4-R))" \
        -blur 0x9 -channel A -evaluate multiply 0.5 +channel "$TMP/M_shadow.png"
    $IM -size ${CANVAS}x${FULLH} xc:none \
        "$TMP/disc.png" -gravity northwest -geometry +${PAD}+${PAD} -compose over -composite "$TMP/M_disc.png"
    $IM -size ${CANVAS}x${FULLH} xc:none -stroke "$MAP_RING_COLOR" -strokewidth ${RING} -fill none \
        -draw "circle ${CX},${MY} ${CX},$((MY-R))" "$TMP/M_ring.png"
    $IM "$TMP/M_ring.png" \( +clone -blur 0x4 -channel A -evaluate multiply 1.2 +channel \) \
        -compose over -composite "$TMP/M_ringglow.png"
    $IM -size ${CANVAS}x${FULLH} xc:none \
        -fill "$MARKER_COLOR" -draw "circle ${CX},${MY} ${CX},$((MY-7))" \
        -fill white          -draw "circle ${CX},${MY} ${CX},$((MY-3))" "$TMP/M_marker.png"

    $IM -size ${CANVAS}x${FULLH} xc:none -colorspace sRGB \
        "$TMP/M_shadow.png" -composite "$TMP/M_disc.png" -composite \
        "$TMP/M_ringglow.png" -composite "$TMP/M_marker.png" -composite "$TMP/M_final.png" || exit 5
    
    $IM "$TMP/M_final.png" -resize ${HUD_W}x${HUD_H}\! -depth 8 bgra:"$OUT_MAP" || exit 7
fi

exit 0
EOF
chmod +x "$CFG/build-minimap.sh"

# =============================================================================
# 3b. build-title.sh (Animated Cinematic Title Generator)
# =============================================================================
echo "▶ Writing build-title.sh..."
cat > "$CFG/build-title.sh" << 'EOF'
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
EOF
chmod +x "$CFG/build-title.sh"

# =============================================================================
# 3c. build-geodb.sh  (one-time: download GeoNames dumps -> offline SQLite)
#     Data © GeoNames, CC-BY 4.0 (https://www.geonames.org). Re-run to refresh
#     or after changing GEONAMES_COUNTRIES. Needs: curl, unzip, python3.
# =============================================================================
echo "▶ Writing build-geodb.sh..."
cat > "$CFG/build-geodb.sh" << 'EOF'
#!/bin/bash
set -u
SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || { echo "build-geodb: missing config $SS_CONF — run the installer." >&2; exit 1; }

command -v curl  >/dev/null 2>&1 || { echo "build-geodb: curl not found."  >&2; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "build-geodb: unzip not found." >&2; exit 1; }

BASE="https://download.geonames.org/export/dump"
WORK="$MAP_DIR/geo"; mkdir -p "$WORK"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "▶ Fetching GeoNames support tables..."
curl -fsSL -o "$TMP/admin1.txt"  "$BASE/admin1CodesASCII.txt" || { echo "download failed (admin1)"; exit 1; }
curl -fsSL -o "$TMP/country.txt" "$BASE/countryInfo.txt"      || { echo "download failed (countryInfo)"; exit 1; }

DUMPS=()
if [ -n "${GEONAMES_COUNTRIES:-}" ]; then
    for cc in $GEONAMES_COUNTRIES; do
        echo "▶ Fetching ${cc}.zip..."
        if curl -fsSL -o "$TMP/$cc.zip" "$BASE/$cc.zip"; then
            if (cd "$TMP" && unzip -oq "$cc.zip" "$cc.txt"); then
                DUMPS+=("$TMP/$cc.txt")
            else
                echo "⚠ could not unzip $cc.zip"
            fi
        else
            echo "⚠ could not fetch $cc.zip"
        fi
    done
else
    echo "▶ Fetching allCountries.zip (whole planet, ~390MB)..."
    if curl -fsSL -o "$TMP/all.zip" "$BASE/allCountries.zip" \
        && (cd "$TMP" && unzip -oq all.zip allCountries.txt); then
        DUMPS+=("$TMP/allCountries.txt")
    fi
fi
[ "${#DUMPS[@]}" -gt 0 ] || { echo "build-geodb: no dumps downloaded — aborting."; exit 1; }

echo "▶ Building offline place database -> $GEODB ..."
python3 - "$GEODB" "$TMP/country.txt" "$TMP/admin1.txt" "${DUMPS[@]}" <<'PY'
import sys, sqlite3, os
# GeoNames feature CODE -> (weight, max_km). Higher weight = more prominent;
# max_km = how far away the feature can still be the photo's "landmark".
LANDMARK = {
    "VLC":(10,40),"PK":(9,35),"MT":(9,35),"FLLS":(9,15),"GLCR":(8,25),
    "PRK":(7,30),"RESN":(7,30),"GYSR":(7,15),"TOWR":(7,8),
    "CSTL":(6,8),"FT":(6,8),"LTHSE":(6,10),"LK":(6,20),"BAY":(6,20),
    "CLF":(6,15),"ARCH":(6,15),"ISL":(6,30),"BCH":(6,15),
    "CAPE":(5,15),"MNMT":(5,6),"HSTS":(5,6),"RDGE":(5,20),"SPNG":(5,10),
    "MUS":(4,4),
}
db, cinfo, admin1, dumps = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]

country = {}
for ln in open(cinfo, encoding="utf-8", errors="ignore"):
    if ln.startswith("#"):
        continue
    c = ln.rstrip("\n").split("\t")
    if len(c) > 4 and c[0]:
        country[c[0]] = c[4]

a1 = {}
for ln in open(admin1, encoding="utf-8", errors="ignore"):
    c = ln.rstrip("\n").split("\t")
    if len(c) >= 2 and c[0]:
        a1[c[0]] = c[1]

os.makedirs(os.path.dirname(db), exist_ok=True)
if os.path.exists(db):
    os.remove(db)
con = sqlite3.connect(db); cur = con.cursor()
cur.execute("CREATE TABLE place(name TEXT, lat REAL, lon REAL, pop INTEGER, state TEXT, country TEXT)")
cur.execute("CREATE TABLE feature(name TEXT, lat REAL, lon REAL, fcode TEXT, elev REAL, weight INTEGER, maxkm REAL)")

np = nf = 0
for dump in dumps:
    for ln in open(dump, encoding="utf-8", errors="ignore"):
        c = ln.rstrip("\n").split("\t")
        if len(c) < 19:
            continue
        name, lat, lon, fclass, fcode, cc, adm1 = c[1], c[4], c[5], c[6], c[7], c[8], c[10]
        if not name:
            continue
        try:
            lat = float(lat); lon = float(lon)
        except ValueError:
            continue
        try:
            pop = int(c[14] or 0)
        except ValueError:
            pop = 0
        elev = 0.0
        for col in (c[15], c[16]):
            try:
                elev = float(col); break
            except (ValueError, IndexError):
                pass
        if fclass == "P" and fcode.startswith("PPL") and pop > 0:
            cur.execute("INSERT INTO place VALUES(?,?,?,?,?,?)",
                        (name, lat, lon, pop, a1.get(cc + "." + adm1, ""), country.get(cc, "")))
            np += 1
        elif fcode in LANDMARK:
            w, mk = LANDMARK[fcode]
            cur.execute("INSERT INTO feature VALUES(?,?,?,?,?,?,?)",
                        (name, lat, lon, fcode, elev, w, mk))
            nf += 1

cur.execute("CREATE INDEX ix_place_lat ON place(lat)")
cur.execute("CREATE INDEX ix_feat_lat  ON feature(lat)")
con.commit(); con.close()
sys.stderr.write("geodb: %d places, %d landmark features -> %s\n" % (np, nf, db))
PY
echo "✅ Offline place database ready."
EOF
chmod +x "$CFG/build-geodb.sh"

# =============================================================================
# 3d. geo-resolve.sh  (offline: nearest prominent landmark + city via GeoNames)
#     Prints "landmark<TAB>city<TAB>state<TAB>country". No network, no key.
# =============================================================================
echo "▶ Writing geo-resolve.sh..."
cat > "$CFG/geo-resolve.sh" << 'EOF'
#!/bin/bash
# geo-resolve.sh LAT LON -> "landmark<TAB>city<TAB>state<TAB>country"  (offline)
set -u
SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || true
LAT="${1:-}"; LON="${2:-}"
[ -z "$LAT" ] || [ -z "$LON" ] && exit 0
[ -s "${GEODB:-}" ] || exit 0          # DB not built yet -> no enrichment
command -v python3 >/dev/null 2>&1 || exit 0
python3 - "$GEODB" "$LAT" "$LON" <<'PY'
import sys, sqlite3, math
DB = sys.argv[1]; lat = float(sys.argv[2]); lon = float(sys.argv[3])

def hav(a, b, c, d):
    p1, p2 = math.radians(a), math.radians(c)
    x = math.sin(math.radians(c - a) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(d - b) / 2) ** 2
    return 2 * 6371.0 * math.asin(math.sqrt(x))

con = sqlite3.connect("file:%s?mode=ro" % DB, uri=True); cur = con.cursor()

def win(r):
    dla = r / 111.0
    dlo = r / (111.0 * max(0.05, math.cos(math.radians(lat))))
    return lat - dla, lat + dla, lon - dlo, lon + dlo

# --- landmark: weight + elevation bonus - distance, within per-code radius ---
la0, la1, lo0, lo1 = win(40)
best = None
for name, flat, flon, fcode, elev, w, mk in cur.execute(
        "SELECT name,lat,lon,fcode,elev,weight,maxkm FROM feature "
        "WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?", (la0, la1, lo0, lo1)):
    d = hav(lat, lon, flat, flon)
    if d > mk:
        continue
    s = w - d / 5.0
    if fcode in ("PK", "MT", "VLC") and elev:
        s += min(elev / 1500.0, 3.0)
    if best is None or s > best[0]:
        best = (s, name)
landmark = best[1] if best else ""

# --- city: nearest sizable populated place (population-aware) ----------------
la0, la1, lo0, lo1 = win(30)
bc = None
for name, plat, plon, pop, state, country in cur.execute(
        "SELECT name,lat,lon,pop,state,country FROM place "
        "WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?", (la0, la1, lo0, lo1)):
    d = hav(lat, lon, plat, plon)
    if d > 30:
        continue
    s = math.log10(pop + 10) - d / 10.0
    if bc is None or s > bc[0]:
        bc = (s, name, state, country)
city    = bc[1] if bc else ""
state   = bc[2] if bc else ""
country = bc[3] if bc else ""

print("\t".join([landmark, city, state, country]))
PY
EOF
chmod +x "$CFG/geo-resolve.sh"

# =============================================================================
# 4. xmp-police.sh  (non-destructive, incremental metadata -> XMP sidecars)
#    Supersedes the old exif-daemon.sh and apply-overrides.sh.
# =============================================================================
echo "▶ Writing xmp-police.sh..."
cat > "$APP_DIR/xmp-police.sh" << 'EOF'
#!/bin/bash
# Walks Media/ and writes one Immich-style "<media>.<ext>.xmp" sidecar per file,
# carrying the resolved capture date (+ GPS / city-state-country / nearby
# landmark when known). Incremental, non-destructive. Precedence: .txt override
# > embedded EXIF > filename timestamp. Geo enrichment is OFFLINE via GeoNames
# (config/geo-resolve.sh). Usage: xmp-police.sh [--once]
set -u

SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || { echo "xmp-police: missing config $SS_CONF — run the installer." >&2; exit 1; }

export GEO_RESOLVE="$CFG_DIR/geo-resolve.sh"

ONCE=0
[ "${1:-}" = "--once" ] && ONCE=1

if ! command -v exiftool >/dev/null 2>&1; then
    if [ "$ONCE" = 1 ]; then
        echo "xmp-police: exiftool not found - skipping sidecar refresh." >&2
        exit 0
    fi
    while ! command -v exiftool >/dev/null 2>&1; do sleep 10; done
fi

MEDIA_EXTS=( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp'
             -o -iname '*.tif' -o -iname '*.tiff' -o -iname '*.heic' -o -iname '*.heif'
             -o -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.m4v'
             -o -iname '*.webm' )

run_pass() {
    local STALE JSON
    STALE="$(mktemp)"; JSON="$(mktemp)"

    find "$MEDIA_DIR" -maxdepth 1 -type f \( "${MEDIA_EXTS[@]}" \) -print0 |
    while IFS= read -r -d '' m; do
        xmp="${m}.xmp"
        base="${m%.*}"
        txt=""
        [ -s "${base}.txt" ] && txt="${base}.txt"
        [ -s "${m}.txt" ]    && txt="${m}.txt"

        stale=0
        if   [ ! -s "$xmp" ];                        then stale=1
        elif [ "$m" -nt "$xmp" ];                    then stale=1
        elif [ -n "$txt" ] && [ "$txt" -nt "$xmp" ]; then stale=1
        fi
        [ "$stale" = 1 ] && printf '%s\n' "$m"
    done > "$STALE"

    if [ -s "$STALE" ]; then
        exiftool -q -m -j -d "%Y-%m-%dT%H:%M:%S" \
            -DateTimeOriginal -CreateDate -CreationDate -MediaCreateDate -DateTimeCreated \
            -GPSLatitude# -GPSLongitude# \
            -City -State -Province-State -Country \
            -api Geolocation -GeolocationCity -GeolocationRegion -GeolocationCountry \
            -@ "$STALE" > "$JSON" 2>/dev/null

        if [ -s "$JSON" ]; then
            python3 - "$JSON" <<'PY'
import sys, json, os, re, subprocess
from xml.sax.saxutils import escape

GEO_RESOLVE = os.environ.get("GEO_RESOLVE", "")

def resolve_geo(lat, lon):
    """Offline GeoNames lookup -> (landmark, city, state, country); blanks on miss."""
    if not GEO_RESOLVE or lat is None or lon is None:
        return "", None, None, None
    try:
        r = subprocess.run([GEO_RESOLVE, "%.6f" % lat, "%.6f" % lon],
                           capture_output=True, text=True, timeout=15)
        if r.returncode == 0 and r.stdout.strip():
            p = (r.stdout.rstrip("\n").split("\t") + ["", "", "", ""])[:4]
            return p[0], (p[1] or None), (p[2] or None), (p[3] or None)
    except Exception:
        pass
    return "", None, None, None

def parse_coord(s):
    s = re.sub(r'\(.*?\)', '', str(s)).upper()
    nums = [float(x) for x in re.findall(r'[-+]?\d+(?:\.\d+)?', s)]
    d = re.search(r'[NSEW]', s)
    v = None
    if   len(nums) == 1: v = nums[0]
    elif len(nums) == 2: v = nums[0] + nums[1]/60.0
    elif len(nums) >= 3: v = nums[0] + nums[1]/60.0 + nums[2]/3600.0
    if v is not None and d and d.group(0) in ('S', 'W'): v = -abs(v)
    return v

def parse_gps(value):
    s = re.sub(r'\(.*?\)', '', str(value)).upper()
    nums = [float(x) for x in re.findall(r'[-+]?\d+(?:\.\d+)?', s)]
    dirs = re.findall(r'[NSEW]', s)
    def sign(la, lo):
        if len(dirs) >= 1 and dirs[0] == 'S': la = -abs(la)
        if   len(dirs) >= 2 and dirs[1] == 'W': lo = -abs(lo)
        elif len(dirs) == 1 and dirs[0] == 'W': lo = -abs(lo)
        return la, lo
    if len(nums) == 2: return sign(nums[0], nums[1])
    if len(nums) == 6: return sign(nums[0]+nums[1]/60+nums[2]/3600, nums[3]+nums[4]/60+nums[5]/3600)
    if len(nums) == 4: return sign(nums[0]+nums[1]/60, nums[2]+nums[3]/60)
    return None, None

def find_txt(media):
    base = os.path.splitext(media)[0]
    for c in (base + ".txt", media + ".txt"):
        if os.path.isfile(c) and os.path.getsize(c) > 0:
            return c
    return None

def parse_txt(path):
    date, lat, lon, loc = "", None, None, ""
    try:
        lines = open(path, encoding="utf-8", errors="ignore").read().splitlines()
    except Exception:
        return date, lat, lon, loc
    for line in lines:
        line = line.strip()
        if not line:
            continue
        m = re.match(r'^\s*([A-Za-z ]+?)\s*[:=]\s*(.+?)\s*$', line)
        if m:
            k = m.group(1).lower().replace(' ', ''); val = m.group(2).strip()
            if k in ('date', 'datetime', 'datetimeoriginal', 'createdate'):
                date = val
            elif k in ('gps', 'coords', 'coordinates', 'latlon', 'latlng'):
                a, b = parse_gps(val)
                if a is not None and b is not None: lat, lon = a, b
            elif k in ('lat', 'latitude'):
                a = parse_coord(val); lat = a if a is not None else lat
            elif k in ('lon', 'lng', 'long', 'longitude'):
                a = parse_coord(val); lon = a if a is not None else lon
            elif k in ('location', 'place', 'city'):
                a, b = parse_gps(val)
                if a is not None and b is not None and -90 <= a <= 90 and -180 <= b <= 180:
                    lat, lon = a, b
                else:
                    loc = val
        else:
            a, b = parse_gps(line)
            if a is not None and b is not None and -90 <= a <= 90 and -180 <= b <= 180:
                lat, lon = a, b
    return date, lat, lon, loc

def to_iso(raw):
    raw = str(raw).strip()
    m = re.match(r'(\d{4})[-:./](\d{1,2})[-:./](\d{1,2})[ T]?(\d{1,2})?:?(\d{1,2})?:?(\d{1,2})?', raw)
    if not m:
        m = re.match(r'(\d{4})(\d{2})(\d{2})(?:[_ ]?(\d{2})(\d{2})(\d{2}))?$', raw)
    if not m:
        return None
    y, mo, d = m.group(1), m.group(2).zfill(2), m.group(3).zfill(2)
    hh = (m.group(4) or "12").zfill(2)
    mm = (m.group(5) or "00").zfill(2)
    ss = (m.group(6) or "00").zfill(2)
    if not (1 <= int(mo) <= 12 and 1 <= int(d) <= 31):
        return None
    return f"{y}-{mo}-{d}T{hh}:{mm}:{ss}"

def filename_date(media):
    name = os.path.basename(media)
    m = re.search(r'(\d{8})[_-]?(\d{6})', name)
    if m: return to_iso(m.group(1) + m.group(2))
    m = re.search(r'(?<!\d)(\d{8})(?!\d)', name)
    if m: return to_iso(m.group(1))
    return None

def write_xmp(media, date_iso, lat, lon, city, state, country, landmark=""):
    fields = []
    if date_iso:
        fields.append("   <exif:DateTimeOriginal>%s</exif:DateTimeOriginal>" % escape(date_iso))
        fields.append("   <xmp:CreateDate>%s</xmp:CreateDate>" % escape(date_iso))
        fields.append("   <photoshop:DateCreated>%s</photoshop:DateCreated>" % escape(date_iso))
    if lat is not None and lon is not None:
        fields.append("   <exif:GPSLatitude>%.7f</exif:GPSLatitude>" % lat)
        fields.append("   <exif:GPSLongitude>%.7f</exif:GPSLongitude>" % lon)
    if city:     fields.append("   <photoshop:City>%s</photoshop:City>" % escape(str(city)))
    if state:    fields.append("   <photoshop:State>%s</photoshop:State>" % escape(str(state)))
    if country:  fields.append("   <photoshop:Country>%s</photoshop:Country>" % escape(str(country)))
    if landmark: fields.append("   <ss:Landmark>%s</ss:Landmark>" % escape(str(landmark)))

    doc = ('<?xml version="1.0" encoding="UTF-8"?>\n'
           '<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Screensaver-Police 1.0">\n'
           ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
           '  <rdf:Description rdf:about=""\n'
           '   xmlns:exif="http://ns.adobe.com/exif/1.0/"\n'
           '   xmlns:xmp="http://ns.adobe.com/xap/1.0/"\n'
           '   xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"\n'
           '   xmlns:ss="https://screensaver.local/ns/1.0/">\n'
           + "\n".join(fields) + ("\n" if fields else "") +
           '  </rdf:Description>\n'
           ' </rdf:RDF>\n'
           '</x:xmpmeta>\n')

    xmp = media + ".xmp"
    tmp = xmp + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(doc)
    os.replace(tmp, xmp)

try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    data = []

for e in data:
    media = e.get("SourceFile")
    if not media or not os.path.exists(media):
        continue

    date_raw = (e.get("DateTimeOriginal") or e.get("CreateDate") or e.get("CreationDate")
                or e.get("MediaCreateDate") or e.get("DateTimeCreated") or "")

    def _f(v):
        try:    return float(v) if v not in (None, "") else None
        except Exception: return None
    lat = _f(e.get("GPSLatitude"))
    lon = _f(e.get("GPSLongitude"))

    city    = e.get("GeolocationCity")    or e.get("City") or ""
    state   = e.get("GeolocationRegion")  or e.get("State") or e.get("Province-State") or ""
    country = e.get("GeolocationCountry") or e.get("Country") or ""

    # Offline GeoNames enrichment: always take the landmark; fill any admin
    # field exiftool left blank (exiftool's geolocation stays primary).
    landmark, gcity, gstate, gcountry = resolve_geo(lat, lon)
    if not city    and gcity:    city = gcity
    if not state   and gstate:   state = gstate
    if not country and gcountry: country = gcountry

    txt = find_txt(media)
    if txt:
        td, tla, tlo, tloc = parse_txt(txt)
        if td:
            date_raw = td
        if tla is not None and tlo is not None:
            lat, lon = tla, tlo
        if tloc:
            parts = [p.strip() for p in tloc.split(",")]
            if len(parts) >= 1 and parts[0]: city    = parts[0]
            if len(parts) >= 2 and parts[1]: state   = parts[1]
            if len(parts) >= 3 and parts[2]: country = parts[2]

    date_iso = to_iso(date_raw) if date_raw else None
    if not date_iso:
        date_iso = filename_date(media)

    if lat is not None and not (-90  <= lat <= 90 ): lat = None
    if lon is not None and not (-180 <= lon <= 180): lon = None
    if lat is None or lon is None:
        lat = lon = None

    try:
        write_xmp(media, date_iso, lat, lon, city, state, country, landmark)
    except Exception as ex:
        sys.stderr.write("xmp-police: failed on %s: %s\n" % (media, ex))
PY
        fi
    fi

    find "$MEDIA_DIR" -maxdepth 1 -type f -name '*.xmp' -print0 |
    while IFS= read -r -d '' x; do
        media="${x%.xmp}"
        [ -e "$media" ] || rm -f "$x"
    done

    rm -f "$STALE" "$JSON"
}

if [ "$ONCE" = 1 ]; then
    run_pass
    exit 0
fi

trap 'exit 0' INT TERM HUP
while command -v exiftool >/dev/null 2>&1; do
    run_pass
    sleep 60
done
EOF
chmod +x "$APP_DIR/xmp-police.sh"

# =============================================================================
# 5. vid-daemon.sh
# =============================================================================
echo "▶ Writing vid-daemon.sh..."
cat > "$APP_DIR/vid-daemon.sh" << 'EOF'
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

        out_file="$OPT_DIR/${base}.mp4"
        skip_marker="$OPT_DIR/.skip_${base}"
        res_marker="$OPT_DIR/.res_${base}"
        tmp_file="$OPT_DIR/.tmp_${base}.mp4"
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
EOF
chmod +x "$APP_DIR/vid-daemon.sh"

# =============================================================================
# 6. mpv.conf  (image-display-duration + volume now come from launch.sh/config)
# =============================================================================
echo "▶ Writing mpv.conf..."
cat > "$CFG/mpv.conf" << 'EOF'
fullscreen=yes
loop-playlist=inf
shuffle=no
osc=no
osd-bar=no
keep-open=no
input-conf=~~/input.conf
script=~~/photo.lua
hwdec=auto-safe
EOF

# =============================================================================
# 7. launch.sh
# =============================================================================
echo "▶ Writing launch.sh..."
cat > "$APP_DIR/launch.sh" << 'LAUNCH_EOF'
#!/bin/bash
pgrep -f "Screensaver-App/config" >/dev/null 2>&1 && exit 0

# --- Load central config (single source of truth; required) ------------------
SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || { echo "Screensaver: missing config $SS_CONF — run the installer." >&2; exit 1; }

# --- Self-healing: recreate any folder that was deleted ----------------------
mkdir -p "$MEDIA_DIR" "$MUSIC_DIR" "$TITLE_DIR" "$PLAYLIST_DIR" "$MAP_DIR" "$MAP_DIR/geo" "$OPT_DIR" "$FONT_DIR"

command -v exiftool >/dev/null 2>&1 || \
    echo "WARN: exiftool not found - date/location HUD will be disabled. Run setup-screensaver.sh to install deps." >&2

# --- Build the offline place DB once, in the background, if it's missing -----
#     (only when GEONAMES_COUNTRIES is set; otherwise allCountries is large and
#     better triggered manually via config/build-geodb.sh).
if [ -n "${GEONAMES_COUNTRIES:-}" ] && [ ! -s "${GEODB:-/nonexistent}" ] \
   && command -v unzip >/dev/null 2>&1; then
    ( "$CFG_DIR/build-geodb.sh" >/dev/null 2>&1 & )
fi

MUSIC_PID=""
POLICE_PID=""
VID_PID=""
LOADING_PID=""

cleanup() {
    [ -n "$MUSIC_PID" ]   && kill "$MUSIC_PID" 2>/dev/null
    [ -n "$POLICE_PID" ]  && kill "$POLICE_PID" 2>/dev/null
    [ -n "$VID_PID" ]     && kill "$VID_PID" 2>/dev/null
    [ -n "$LOADING_PID" ] && kill "$LOADING_PID" 2>/dev/null
    rm -f "$AUDIO_SOCK"
}
trap cleanup EXIT INT TERM

rm -f "$AUDIO_SOCK"

nice -n 19 "$POLICE" >/dev/null 2>&1 &
POLICE_PID=$!

"$APP_DIR/vid-daemon.sh" >/dev/null 2>&1 &
VID_PID=$!

if [ -d "$MUSIC_DIR" ] && [ -n "$(ls -A "$MUSIC_DIR" 2>/dev/null)" ]; then
    mpv --no-video --loop-playlist=inf --shuffle --input-ipc-server="$AUDIO_SOCK" "$MUSIC_DIR" >/dev/null 2>&1 &
    MUSIC_PID=$!
fi

# =============================================================================
# CHRONOLOGICAL PLAYLIST BUILDER  (sidecar-driven, rebuilt every launch)
#   * EXTRACTION (police --once) stays INCREMENTAL.
#   * ASSEMBLY runs UNCONDITIONALLY and reconciles media / sidecars / playlist,
#     including dropping deleted media.
#   HEAVY only decides whether to show the loading screen.
# =============================================================================
HEAVY=0
if [ ! -f "$PLAYLIST" ]; then
    HEAVY=1
elif [ -z "$(ls -A "$TITLE_DIR" 2>/dev/null)" ]; then
    HEAVY=1
elif [ -n "$(find "$MEDIA_DIR" -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \
           -o -iname '*.tif' -o -iname '*.tiff' -o -iname '*.heic' -o -iname '*.heif' \
           -o -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.m4v' \
           -o -iname '*.webm' -o -iname '*.txt' \) \
        -newer "$PLAYLIST" -print -quit 2>/dev/null)" ]; then
    HEAVY=1
fi

if [ "$HEAVY" = 1 ]; then
    echo "Building playlist..."
    LOADING_ASS="/tmp/loading_$$.ass"
    python3 - "$LOADING_ASS" <<'PY'
import sys
ass = """[Script Info]
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, Alignment
Style: Default,Montserrat ExtraBold,70,&H00FFFFFF,5

[Events]
Format: Layer, Start, End, Style, Text
Dialogue: 0,00:00:00.00,99:00:00.00,Default,{\\fsp40}UPDATING PLAYLIST\\N\\N{\\fs40\\fsp20}PLEASE WAIT
"""
with open(sys.argv[1], "w") as f:
    f.write(ass)
PY
    mpv "av://lavfi:color=c=black:s=1920x1080" --no-config --fullscreen --no-osc --no-osd-bar \
        --no-input-default-bindings --input-conf=/dev/null --cursor-autohide=always \
        --sub-file="$LOADING_ASS" --sub-fonts-dir="$FONT_DIR" >/dev/null 2>&1 &
    LOADING_PID=$!
    SECONDS=0
fi

"$POLICE" --once

exiftool -q -m -j -d "%Y%m%d%H%M%S" \
    -DateTimeOriginal -CreateDate -CreationDate \
    -ext xmp "$MEDIA_DIR" > "$PLAYLIST.json" 2>/dev/null

python3 - "$PLAYLIST.json" <<'PY' > "$PLAYLIST.raw"
import sys, json, os
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    data = []
rows = []
for e in data:
    sf = e.get("SourceFile", "")
    media = sf[:-4] if sf.lower().endswith(".xmp") else sf
    if not media or not os.path.exists(media):
        continue
    d = e.get("DateTimeOriginal") or e.get("CreateDate") or e.get("CreationDate") or ""
    d = "".join(c for c in str(d) if c.isdigit())
    if len(d) < 6:
        d = "99999999999999"
    rows.append((d, media))
rows.sort()
for d, m in rows:
    print(d + "|" + m)
PY
rm -f "$PLAYLIST.json"

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

if [ -n "$LOADING_PID" ]; then
    [ "$SECONDS" -lt "$MIN_LOAD_SECS" ] && sleep "$((MIN_LOAD_SECS - SECONDS))"
    kill "$LOADING_PID" 2>/dev/null
    wait "$LOADING_PID" 2>/dev/null
    LOADING_PID=""
    rm -f "$LOADING_ASS"
fi

# Photo display time + volume come from the config, not mpv.conf.
# --sub-fonts-dir makes the HUD find Montserrat in Media/Fonts (a non-default
# font path) and keeps the app self-contained when copied between machines.
mpv --config-dir="$CFG_DIR" \
    --sub-fonts-dir="$FONT_DIR" \
    --image-display-duration="$PHOTO_DURATION" \
    --volume="$VOLUME" \
    --playlist="$PLAYLIST"
LAUNCH_EOF
chmod +x "$APP_DIR/launch.sh"

# =============================================================================
# 8. idle-watcher.sh
# =============================================================================
echo "▶ Writing idle-watcher.sh..."
cat > "$APP_DIR/idle-watcher.sh" << 'EOF'
#!/bin/bash

SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || { echo "idle-watcher: missing config $SS_CONF — run the installer." >&2; exit 1; }

IDLE_LIMIT="$IDLE_TIMEOUT_MS"
while true; do
    if playerctl -a status 2>/dev/null | grep -iq "playing"; then sleep 10; continue; fi

    if pactl list sink-inputs 2>/dev/null | grep -iq "state: RUNNING"; then sleep 10; continue; fi

    if dbus-send --session --dest=org.freedesktop.ScreenSaver --type=method_call --print-reply /org/freedesktop/ScreenSaver org.freedesktop.ScreenSaver.GetInhibitors 2>/dev/null | grep -q "string"; then 
        sleep 10; continue; 
    fi

    if gdbus call --session --dest org.gnome.SessionManager --object-path /org/gnome/SessionManager --method org.gnome.SessionManager.IsInhibited 8 2>/dev/null | grep -q "true"; then
        sleep 10; continue;
    fi

    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        RAW=$(gdbus call --session --dest org.gnome.Mutter.IdleMonitor --object-path /org/gnome/Mutter/IdleMonitor/Core --method org.gnome.Mutter.IdleMonitor.GetIdletime 2>/dev/null)
        IDLE_MS=$(echo "$RAW" | awk '{print $2}' | tr -d '[,)]')
    else
        IDLE_MS=$(xdotool getidletime 2>/dev/null)
    fi

    IDLE_MS=${IDLE_MS:-0}
    [ "$IDLE_MS" -gt "$IDLE_LIMIT" ] && "$APP_DIR/launch.sh"
    sleep 10
done
EOF
chmod +x "$APP_DIR/idle-watcher.sh"

# =============================================================================
# 9. Autostart + manual launcher  (absolute paths baked from config)
# =============================================================================
echo "▶ Writing autostart + app launcher..."
cat > "$HOME/.config/autostart/idle-watcher.desktop" << EOF
[Desktop Entry]
Type=Application
Exec=sh -c "$APP_DIR/idle-watcher.sh"
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=Screensaver Idle Watcher
Comment=Launches the photo screensaver after the configured idle time
EOF

cat > "$HOME/.local/share/applications/screensaver-now.desktop" << EOF
[Desktop Entry]
Type=Application
Exec=sh -c "$APP_DIR/launch.sh"
Icon=video-display
Terminal=false
Name=Start Screensaver
Comment=Launch the photo screensaver now
Categories=Utility;
EOF

# =============================================================================
# 10. Offline place database (build now if possible)
# =============================================================================
if command -v unzip >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    echo "▶ Building offline GeoNames place database (one-time)..."
    "$CFG/build-geodb.sh" || echo "⚠ Place DB build failed — you can re-run: $CFG/build-geodb.sh"
else
    echo "⚠ Skipping place DB build (need curl + unzip). Run later: $CFG/build-geodb.sh"
fi

# =============================================================================
# 11. Done
# =============================================================================
echo ""
echo "✅ Migration and Deployment finished!"
echo "Your structure is:"
echo "   App Code   : $APP_DIR"
echo "   Config     : $CFG/screensaver.conf  (edit this to change any setting)"
echo "   Media      : $MEDIA_DIR"
echo "   Caches     : $MAP_DIR & $OPT_DIR"
echo "   Place DB   : $GEODB  (offline; rebuild with $CFG/build-geodb.sh)"
echo "                Place data © GeoNames, CC-BY 4.0 (https://www.geonames.org)"
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo ""
    echo "⚠ Reminder: still missing -> ${MISSING[*]}"
    echo "  Install those, then re-run this script before launching."
fi
