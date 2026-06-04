#!/bin/bash
# =============================================================================
#  mpv Photo & Video Screensaver — Clean Architecture (App/PC/TV agnostic)
#  Dependencies are installed in ONE transaction and then VERIFIED.
# =============================================================================
set -u

APP_DIR="$HOME/Screensaver-App"
CFG="$APP_DIR/config"
BASE_DIR="$HOME/Pictures/Screensavers"
MEDIA_DIR="$BASE_DIR/Media"
MAP_DIR="$BASE_DIR/Maps"
OPT_DIR="$BASE_DIR/Optimized_Vids"
MUSIC_DIR="$HOME/Music/ScreenSaver"

echo "▶ Preparing strict folder architecture..."

rm -f "$HOME/.config/autostart/tv-watcher.desktop"
rm -f "$HOME/.local/share/applications/tv-screensaver-now.desktop"
pkill -f exif-daemon.sh 2>/dev/null || true
pkill -f vid-daemon.sh 2>/dev/null || true
pkill -f tv-watcher.sh 2>/dev/null || true
pkill -f idle-watcher.sh 2>/dev/null || true

if [ -d "$HOME/TV-Screensaver" ] && [ ! -d "$APP_DIR" ]; then
    mv "$HOME/TV-Screensaver" "$APP_DIR"
fi

mkdir -p "$CFG" "$MEDIA_DIR" "$MAP_DIR" "$OPT_DIR" "$MUSIC_DIR" "$HOME/.config/autostart" "$HOME/.local/share/applications" "$HOME/.local/share/fonts"

if [ -d "$BASE_DIR/_map" ]; then
    mv "$BASE_DIR/_map"/* "$MAP_DIR/" 2>/dev/null || true
    rm -rf "$BASE_DIR/_map"
fi
if [ -d "$BASE_DIR/optimized_vids" ]; then
    mv "$BASE_DIR/optimized_vids"/* "$OPT_DIR/" 2>/dev/null || true
    rm -rf "$BASE_DIR/optimized_vids"
fi

find "$BASE_DIR" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.webm' -o -iname '*.txt' \) -exec mv {} "$MEDIA_DIR/" \; 2>/dev/null || true

echo "▶ Purging broken strides from cache..."
find "$MAP_DIR" -type f -name '*.bgra' -delete 2>/dev/null || true

# =============================================================================
# 0. Dependencies (distro-aware, single transaction, VERIFIED)
#    Done first so a missing tool is reported loudly before anything else.
# =============================================================================
echo "▶ Resolving and installing dependencies..."

# Runtime tools the app actually calls. ImageMagick (magick OR convert) is
# checked separately below since either binary satisfies it.
REQUIRED_CMDS=(mpv exiftool python3 curl qrencode ffmpeg socat playerctl pactl fc-match)

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
    PKGS="mpv perl-Image-ExifTool python3 python3-qrcode python3-pillow curl qrencode ffmpeg socat playerctl pulseaudio-utils ImageMagick fontconfig xdotool"
    INSTALL="sudo dnf install -y"
    ;;
  apt-get)
    PKGS="mpv libimage-exiftool-perl python3 python3-qrcode python3-pil curl qrencode ffmpeg socat playerctl pulseaudio-utils imagemagick fontconfig xdotool"
    sudo apt-get update -y || true
    INSTALL="sudo apt-get install -y"
    ;;
  pacman)
    PKGS="mpv perl-image-exiftool python python-qrcode python-pillow curl qrencode ffmpeg socat playerctl libpulse imagemagick fontconfig xdotool"
    INSTALL="sudo pacman -S --needed --noconfirm"
    ;;
  zypper)
    PKGS="mpv exiftool python3 python3-qrcode python3-Pillow curl qrencode ffmpeg socat playerctl pulseaudio-utils ImageMagick fontconfig xdotool"
    INSTALL="sudo zypper install -y"
    ;;
  *)
    echo "⚠ No supported package manager (dnf/apt/pacman/zypper) found."
    echo "  Install manually: mpv exiftool imagemagick python3 curl qrencode ffmpeg socat playerctl pactl fontconfig"
    ;;
esac

if [ -n "$INSTALL" ]; then
    echo "▶ Using ${PM}: installing all packages in one go..."
    echo "  $PKGS"
    # NOTE: errors are intentionally NOT hidden. If install fails, you see why.
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

if [ "${#MISSING[@]}" -gt 0 ]; then
    echo ""
    echo "❌ Missing: ${MISSING[*]}"
    echo "   Slideshow will still play, but the date/location HUD and minimaps"
    echo "   depend on: exiftool, ImageMagick, qrencode, curl, python3."
    echo "   Install the missing tools, then re-run this script."
    echo ""
else
    echo "✅ All runtime tools present."
fi

# Fonts (independent of package install). The old google/fonts static URLs now
# 404 because Montserrat ships as a variable font, which neither libass nor
# ImageMagick weight-select reliably — so we pull STATIC weights from the
# official designer's repo: ExtraBold for the date/location label, SemiBold for
# the map/QR coordinate strips.
FONT_DIR="$HOME/.local/share/fonts"
FONT_BASE="https://raw.githubusercontent.com/JulietaUla/Montserrat/master/fonts/ttf"
got_font=0
for w in ExtraBold SemiBold; do
    if curl -fsSL --create-dirs -o "$FONT_DIR/Montserrat-$w.ttf" "$FONT_BASE/Montserrat-$w.ttf"; then
        got_font=1
    else
        echo "⚠ Could not fetch Montserrat-$w."
    fi
done
# Clean up any zero-byte leftovers from the previously-broken download.
find "$FONT_DIR" -name 'Montserrat-*.ttf' -size 0 -delete 2>/dev/null || true
if [ "$got_font" = 1 ]; then
    fc-cache -f "$FONT_DIR" >/dev/null 2>&1 || true
    echo "▶ Montserrat fonts installed (ExtraBold + SemiBold)."
else
    echo "⚠ Montserrat unavailable — text will fall back to a system sans."
fi

# =============================================================================
# 1. input.conf
# =============================================================================
echo "▶ Writing input.conf..."
cat > "$CFG/input.conf" << 'EOF'
MBTN_LEFT    script-message handle-left-click
MBTN_RIGHT   quit
WHEEL_UP     quit
WHEEL_DOWN   quit
ESC          quit
q            quit

SPACE      script-message ss-toggle-pause
PLAY       script-message ss-toggle-pause
PAUSE      script-message ss-toggle-pause
PLAYPAUSE  script-message ss-toggle-pause
p          script-message ss-toggle-pause

RIGHT playlist-next
LEFT  playlist-prev
UP    script-message hud-zoom-in
DOWN  script-message hud-zoom-out

NEXT run bash -c "printf '%s\n' '{\"command\":[\"playlist-next\"]}' | socat - UNIX-CONNECT:/tmp/ss_audio.sock 2>/dev/null"
PREV run bash -c "printf '%s\n' '{\"command\":[\"playlist-prev\"]}' | socat - UNIX-CONNECT:/tmp/ss_audio.sock 2>/dev/null"
]    run bash -c "printf '%s\n' '{\"command\":[\"playlist-next\"]}' | socat - UNIX-CONNECT:/tmp/ss_audio.sock 2>/dev/null"
[    run bash -c "printf '%s\n' '{\"command\":[\"playlist-prev\"]}' | socat - UNIX-CONNECT:/tmp/ss_audio.sock 2>/dev/null"

= add volume 5
- add volume -5
EOF

# =============================================================================
# 2. photo.lua
# =============================================================================
echo "▶ Writing photo.lua..."
cat > "$CFG/photo.lua" << 'EOF'
local utils = require "mp.utils"
local msg   = require "mp.msg"

local APP_DIR    = (os.getenv("HOME") or "~") .. "/Screensaver-App"
local BASE_DIR   = (os.getenv("HOME") or "~") .. "/Pictures/Screensavers"
local builder    = APP_DIR .. "/config/build-minimap.sh"
local AUDIO_SOCK = "/tmp/ss_audio.sock"

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

-- ----------------------------------------------------------------------------
-- Display-size detection (adapts the screensaver to ANY resolution / aspect)
-- ----------------------------------------------------------------------------
local DISPLAY_W, DISPLAY_H = nil, nil
local BLUR_W, BLUR_H = nil, nil   -- dimensions of the blur filter currently applied

local function refresh_display_size()
    -- display-width/height = the physical monitor the window is on (best).
    -- osd-width/height     = the render surface (good fallback once VO exists).
    -- Both are stable across files, unlike per-image osd-dimensions.
    local w = mp.get_property_number("display-width") or 0
    local h = mp.get_property_number("display-height") or 0
    if w < 320 or h < 320 then
        w = mp.get_property_number("osd-width") or 0
        h = mp.get_property_number("osd-height") or 0
    end
    if w >= 320 and h >= 320 then
        if DISPLAY_W ~= w or DISPLAY_H ~= h then
            DISPLAY_W, DISPLAY_H = w, h          -- remember the last good reading
            -- Publish it for the video daemon (which has no display access).
            local f = io.open(APP_DIR .. "/display.conf", "w")
            if f then f:write(string.format("%dx%d", w, h)); f:close() end
        end
    end
    return DISPLAY_W or 1920, DISPLAY_H or 1080  -- 1080p only until first real read
end

local image_ext = {jpg=true, jpeg=true, png=true, webp=true, bmp=true,
                   tif=true, tiff=true, gif=true, jfif=true}

-- Blur-fill background sized to the ACTUAL display, not a fixed 4K/16:9 canvas.
-- Blur is computed cheaply at 640x360 then upscaled to the real WxH; the sharp
-- photo is contained and centered over it. Because the output frame matches the
-- display aspect exactly, mpv fills the screen with no black bars on any ratio
-- (16:9, 16:10, 21:9, 4:3, portrait, ...).
local function apply_image_blur_vf()
    local w, h = refresh_display_size()
    local vf = string.format(
        "lavfi=[split[bg][fg];" ..
        "[bg]scale=640:360,setsar=1,gblur=sigma=50,scale=%d:%d,setsar=1[b];" ..
        "[fg]scale=%d:%d:force_original_aspect_ratio=decrease,setsar=1[f];" ..
        "[b][f]overlay=(W-w)/2:(H-h)/2,setsar=1]",
        w, h, w, h)
    mp.set_property("vf", vf)
    BLUR_W, BLUR_H = w, h
end

-- ----------------------------------------------------------------------------
-- on_load: optimized-video redirect + per-type filter selection
-- ----------------------------------------------------------------------------
local is_video = {mp4=true, mkv=true, mov=true, m4v=true, webm=true}
mp.add_hook("on_load", 10, function()
    local path = mp.get_property("stream-open-filename")
    if not path then return end

    local ext = (path:match("%.([^%.]+)$") or ""):lower()

    if is_video[ext] then
        local dir, file = path:match("^(.-)/([^/]+)$")
        if dir and file and not dir:match("/Optimized_Vids$") then
            -- Strip the original extension to match the strict .mp4 naming
            local base_name = file:match("(.+)%.[^%.]+$") or file
            local opt_path = BASE_DIR .. "/Optimized_Vids/" .. base_name .. ".mp4"
            local fi = utils.file_info(opt_path)
            if fi and fi.size and fi.size > 0 then
                mp.set_property("stream-open-filename", opt_path)
            end
        end
        mp.set_property("vf", "")    -- videos: framed already / blur baked by daemon
        return
    end

    if image_ext[ext] then
        -- Pre-apply the blur ONLY if we already know the real display size
        -- (cached from a previous file). On Wayland the size is usually not
        -- readable this early on the very first file, so we defer to file-loaded
        -- rather than bake in a wrong 16:9 fallback.
        refresh_display_size()
        if DISPLAY_W then
            apply_image_blur_vf()
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

-- HUD geometry, all derived from the REAL display size so it adapts to any
-- resolution/aspect. The map/QR bitmaps are SQUARE (disc / card only — no baked
-- text). The lat/lon strings are drawn separately as crisp libass OSD text just
-- below each bitmap (draw_coord_labels): vector-sharp and, unlike a baked-in
-- bitmap, never rescaled — which is what made the text rough before.
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

-- Back-compat shim for callers that only need the bitmap side + display size.
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

-- Coordinate strings (formatted here, drawn via libass) --------------------
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
    -- white fill, thin black outline + soft shadow so it reads over any imagery
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

local function resolve_meta(orig_path, cb)
    local sc = parse_sidecar(orig_path)
    local fallback_date
    local fi = utils.file_info(orig_path)
    if fi and fi.mtime then fallback_date = os.date("%b %d, %Y", fi.mtime) end

    local mdir = BASE_DIR .. "/Maps"

    mp.command_native_async({
        name = "subprocess", capture_stdout = true,
        args = {
            "exiftool", "-api", "Geolocation", "-j", "-d", "%b %d, %Y", "-c", "%f",
            "-DateTimeOriginal", "-CreateDate", "-CreationDate", "-DateCreated", "-ModifyDate",
            "-GeolocationCity", "-GeolocationRegion", "-GeolocationCountry",
            "-City", "-State", "-Province-State", "-Country", "-Location", "-LocationName",
            "-GPSLatitude", "-GPSLongitude", orig_path,
        },
    }, function(ok, res)
        local date, location, lat, lon = fallback_date, "", nil, nil
        if ok and res and res.stdout and res.stdout ~= "" then
            local data = utils.parse_json(res.stdout)
            local t = data and data[1]
            if t then
                date = t.DateTimeOriginal or t.CreateDate or t.CreationDate
                    or t.DateCreated or t.ModifyDate or fallback_date
                local landmark = t.LocationName or t.Location
                local city     = t.GeolocationCity or t.City
                local region   = abbr_subdiv(t.GeolocationRegion or t.State or t["Province-State"], nil)
                local country  = abbr_country(t.GeolocationCountry or t.Country, nil)
                landmark, city, region, country = niagara_fix(landmark, city, region, country)
                location = join_loc(landmark, city, region, country)
                lat = parse_coord(t.GPSLatitude)
                lon = parse_coord(t.GPSLongitude)
            end
        end
        if sc then
            if sc.date then date = sc.date end
            if sc.location and sc.location ~= "" then location = sc.location end
            if sc.lat and sc.lon then lat, lon = sc.lat, sc.lon end
        end
        if lat and (lat < -90  or lat > 90 ) then lat = nil end
        if lon and (lon < -180 or lon > 180) then lon = nil end
        cb({ date = date, location = location, lat = lat, lon = lon, mdir = mdir })
    end)
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
            orig_path = BASE_DIR .. "/Media/" .. orig_file
        end
    end

    clear_hud_osd()
    ov:remove()
    seq = seq + 1
    local my_seq = seq
    prewarmed[orig_path] = true

    local L = hud_geom()
    local w, h, win_w, win_h = L.S, L.S, L.win_w, L.win_h

    -- get_hud_size just refreshed the real display size. If this is an image and
    -- the blur was applied at a different (fallback) size during on_load, redo it
    -- now at the correct full-screen dimensions. No-op on every later image, so
    -- there's no per-slide flicker — only the first image can ever re-trigger.
    do
        local pext = (path:match("%.([^%.]+)$") or ""):lower()
        if image_ext[pext] and DISPLAY_W and (BLUR_W ~= DISPLAY_W or BLUR_H ~= DISPLAY_H) then
            apply_image_blur_vf()
        end
    end

    resolve_meta(orig_path, function(m)
        if my_seq ~= seq then return end

        cur = { seq = my_seq, path = path, orig = orig_path, lat = m.lat, lon = m.lon, mdir = m.mdir, zidx = 1, w = w, h = h, auto = true }

        local date     = m.date
        local location = m.location or ""
        local mdir     = m.mdir

        local loc_cache
        if m.lat and m.lon and location == "" then
            loc_cache = mdir .. string.format("/place_%.4f_%.4f.txt", m.lat, m.lon)
            if file_exists(loc_cache) then
                local lf = io.open(loc_cache, "r")
                if lf then location = (lf:read("*a") or ""):gsub("[\r\n]+", ""); lf:close() end
            end
        end

        local function draw_text()
            local d = compact_date(date)
            local text = ""
            if d and location ~= "" then text = d .. "  |  " .. location
            elseif d then text = d
            elseif location ~= "" then text = location end

            if text == "" then ov:remove(); return end

            local L  = hud_geom()
            local fs = math.floor(L.win_h * 0.045)                   -- ~48 at 1080p, scales up on 4K
            local cx = math.floor(L.win_w / 2)
            local baseline = L.win_h - math.floor(L.win_h * 0.085)   -- lower-third placement

            ov.res_x = L.win_w
            ov.res_y = L.win_h
            ov.data = string.format(
                "{\\an5\\pos(%d,%d)\\fnMontserrat ExtraBold\\fs%d\\bord1\\3c&H000000&\\shad2\\4c&H000000&}%s",
                cx, baseline, fs, text)
            ov:update()
        end
        draw_text()

        if m.lat and m.lon and location == "" and loc_cache then
            mp.command_native_async({
                name = "subprocess", capture_stdout = true,
                args = {
                    "curl", "-sf", "--max-time", "5",
                    "-A", "Screensaver-App/1.0",
                    "https://nominatim.openstreetmap.org/reverse?format=json&addressdetails=1&lat="
                        .. string.format("%.6f", m.lat) .. "&lon=" .. string.format("%.6f", m.lon)
                        .. "&zoom=18&accept-language=en",
                },
            }, function(rok, rres)
                if my_seq ~= seq then return end
                if rok and rres and rres.stdout then
                    local j = utils.parse_json(rres.stdout)
                    if j and j.address then
                        local a = j.address
                        local landmark = nil
                        local poi_keys = {
                            "historic","tourism","national_park","park","nature_reserve",
                            "castle","palace","monument","ruins","museum","attraction",
                            "theme_park","viewpoint","zoo","aquarium","stadium","peak",
                            "mountain","volcano","beach","bay","island","waterfall",
                            "natural","leisure","bridge","building","aeroway","amenity","man_made"
                        }
                        for _, k in ipairs(poi_keys) do
                            if a[k] and type(a[k]) == "string" then landmark = a[k] break end
                        end
                        local city  = a.city or a.town or a.village or a.hamlet
                        local state = abbr_subdiv(a.state or a.province, a["ISO3166-2-lvl4"] or a["ISO3166-2-lvl3"])
                        local ctry  = abbr_country(a.country, a.country_code)
                        landmark, city, state, ctry = niagara_fix(landmark, city, state, ctry)
                        local loc = join_loc(landmark, city, state, ctry)
                        if loc ~= "" then
                            location = loc
                            os.execute("mkdir -p '" .. mdir:gsub("'", "'\\''") .. "'")
                            local cf = io.open(loc_cache, "w")
                            if cf then cf:write(location); cf:close() end
                            draw_text()
                        end
                    end
                end
            end)
        end

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

# NOTE: coordinate text is no longer baked into these bitmaps. The map/QR images
# are now pure disc; the lat/lon strings are drawn separately as crisp libass
# OSD text by photo.lua, so they are vector-sharp and never rescaled.

if [ "$need_qr" = 1 ]; then
    G_MAPS_URL="https://maps.google.com/?q=${LAT},${LON}"

    # Stylish circular QR: rounded modules + a decorative dot-fill so the pattern
    # fills the whole disc. The surround is purely decorative (no finder patterns,
    # so scanners ignore it); the actual scannable code is the high error-
    # correction core, isolated by its own white quiet-zone halo. Needs python3 +
    # qrcode + Pillow. If any are missing we fall back to a plain qrencode square
    # on a white disc so the HUD never breaks.
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
mask = SolidFillColorMask(back_color=(255, 255, 255, 0), front_color=(17, 17, 17, 255))
qr_img = qr.make_image(image_factory=StyledPilImage,
                       module_drawer=CircleModuleDrawer(),
                       color_mask=mask).convert("RGBA")
canvas = Image.new("RGBA", (D, D), (0, 0, 0, 0))
draw = ImageDraw.Draw(canvas)
draw.ellipse([0, 0, D - 1, D - 1], fill=(255, 255, 255, 255))      # 0.4 alpha white disc

# 1. Maximize QR size while keeping corners safely inside the circular disc.
# We calculate an exact integer cell size to guarantee pixel-perfect grid alignment.
cell = int((D * 0.68) / float(n))
func = cell * n

qr_img = qr_img.resize((func, func), Image.LANCZOS)
cx = cy = D / 2.0
R = D / 2.0
half = func / 2.0    # Set gap to exactly 0

dot = (17, 17, 17, 255)
random.seed(len(url) * 7 + 13)

# 2. Synchronize the fake background grid exactly with the real QR code grid
first_mod_x = cx - half + (cell / 2.0)
first_mod_y = cy - half + (cell / 2.0)
start_x = first_mod_x - (int(first_mod_x / cell) * cell)
start_y = first_mod_y - (int(first_mod_y / cell) * cell)

yy = start_y
while yy < D:
    xx = start_x
    while xx < D:
        # If inside the main circular disc
        if (xx - cx) ** 2 + (yy - cy) ** 2 <= (R - cell * 1.3) ** 2:
            # If OUTSIDE the real QR core bounds
            if xx < (cx - half) or xx > (cx + half) or yy < (cy - half) or yy > (cy + half):
                if random.random() < 0.5:
                    r = cell * 0.40
                    draw.ellipse([xx - r, yy - r, xx + r, yy + r], fill=dot)
        xx += cell
    yy += cell

# 3. No rounded_rectangle (quiet zone) is drawn here so the alphas don't overlap.
# This completely removes the border, making the dots bleed seamlessly.
canvas.alpha_composite(qr_img, (int(cx - half), int(cy - half)))
canvas.save(out_png)
PY
    then STYLED=1; fi

    if [ "$STYLED" != 1 ]; then
        # Fallback: plain square QR inscribed on a white disc.
        qrencode -s 12 -m 2 -o "$TMP/qr_raw.png" "$G_MAPS_URL" || exit 6
        QR_FIT=330
        $IM "$TMP/qr_raw.png" -transparent white -resize ${QR_FIT}x${QR_FIT} "$TMP/qr_scaled.png"
        $IM -size ${D}x${D} xc:none -fill '#ffffffF2' -draw "circle $R,$R $R,1" "$TMP/qr_disc.png"
        QR_OFF=$(( (D - QR_FIT) / 2 ))
        $IM "$TMP/qr_disc.png" "$TMP/qr_scaled.png" -gravity northwest -geometry +${QR_OFF}+${QR_OFF} \
            -compose over -composite "$TMP/qr_styled.png"
    fi

    # Shadow / disc / outer stroke / ring + glow — identical treatment to the
    # minimap so the two badges read as a matched pair.
    $IM -size ${CANVAS}x${FULLH} xc:none -fill black \
        -draw "circle ${CX},$((MY+4)) ${CX},$((MY+4-R))" \
        -blur 0x9 -channel A -evaluate multiply 0.5 +channel "$TMP/QR_shadow.png"
    $IM -size ${CANVAS}x${FULLH} xc:none \
        "$TMP/qr_styled.png" -gravity northwest -geometry +${PAD}+${PAD} -compose over -composite "$TMP/QR_disc.png"
    $IM -size ${CANVAS}x${FULLH} xc:none -stroke '#0d2236' -strokewidth 2 -fill none \
        -draw "circle ${CX},${MY} ${CX},$((MY-R-2))" "$TMP/QR_outer.png"
    $IM -size ${CANVAS}x${FULLH} xc:none -stroke "#FFFFFF" -strokewidth ${RING} -fill none \
        -draw "circle ${CX},${MY} ${CX},$((MY-R))" "$TMP/QR_ring.png"
    $IM "$TMP/QR_ring.png" \( +clone -blur 0x4 -channel A -evaluate multiply 1.2 +channel \) \
        -compose over -composite "$TMP/QR_ringglow.png"

    $IM -size ${CANVAS}x${FULLH} xc:none -colorspace sRGB \
        "$TMP/QR_shadow.png" -composite "$TMP/QR_disc.png" -composite \
        "$TMP/QR_outer.png" -composite "$TMP/QR_ringglow.png" -composite "$TMP/QR_final.png" || exit 5

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
            url="https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/${Z}/${ty}/${tx}"
        else
            tf="$CACHE/${Z}_${tx}_${ty}.png"
            sub=${SUBS[$(( (tx+ty) % 3 ))]}
            url="https://${sub}.tile.openstreetmap.org/${Z}/${tx}/${ty}.png"
        fi
        if [ ! -s "$tf" ]; then
            curl -sf --max-time 8 --create-dirs -A "$UA" -o "$tf" "$url" &
        fi
    done; done
    wait 

    for dy in -1 0 1; do for dx in -1 0 1; do
        tx=$((XT+dx)); ty=$((YT+dy))
        if [ "$MAP_STYLE" = "satellite" ]; then tf="$CACHE/sat_${Z}_${tx}_${ty}.png"
        else tf="$CACHE/${Z}_${tx}_${ty}.png"; fi
        cp "$tf" "$TMP/t_${dx}_${dy}.png"
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
    $IM -size ${CANVAS}x${FULLH} xc:none -stroke '#0d2236' -strokewidth 2 -fill none \
        -draw "circle ${CX},${MY} ${CX},$((MY-R-2))" "$TMP/M_outer.png"
    $IM -size ${CANVAS}x${FULLH} xc:none -stroke "$MAP_RING_COLOR" -strokewidth ${RING} -fill none \
        -draw "circle ${CX},${MY} ${CX},$((MY-R))" "$TMP/M_ring.png"
    $IM "$TMP/M_ring.png" \( +clone -blur 0x4 -channel A -evaluate multiply 1.2 +channel \) \
        -compose over -composite "$TMP/M_ringglow.png"
    $IM -size ${CANVAS}x${FULLH} xc:none \
        -fill "$MARKER_COLOR" -draw "circle ${CX},${MY} ${CX},$((MY-7))" \
        -fill white          -draw "circle ${CX},${MY} ${CX},$((MY-3))" "$TMP/M_marker.png"

    # Disc only — coordinates are drawn as crisp libass OSD text by photo.lua.
    $IM -size ${CANVAS}x${FULLH} xc:none -colorspace sRGB \
        "$TMP/M_shadow.png" -composite "$TMP/M_disc.png" -composite "$TMP/M_outer.png" -composite \
        "$TMP/M_ringglow.png" -composite "$TMP/M_marker.png" -composite "$TMP/M_final.png" || exit 5
    
    $IM "$TMP/M_final.png" -resize ${HUD_W}x${HUD_H}\! -depth 8 bgra:"$OUT_MAP" || exit 7
fi

exit 0
EOF
chmod +x "$CFG/build-minimap.sh"

# =============================================================================
# 4. apply-overrides.sh 
# =============================================================================
echo "▶ Writing apply-overrides.sh..."
cat > "$APP_DIR/apply-overrides.sh" << 'EOF'
#!/bin/bash
set -u
PHOTO_DIR="${1:-$HOME/Pictures/Screensavers/Media}"
KEEP_BACKUP="${KEEP_BACKUP:-1}"

command -v exiftool >/dev/null 2>&1 || { echo "exiftool not installed"; exit 1; }

find_sidecar() {
    local f="$1" base="${1%.*}"
    [ -s "$base.txt" ] && { echo "$base.txt"; return; }
    [ -s "$f.txt" ]    && { echo "$f.txt"; return; }
}

parse_sidecar() {
    python3 - "$1" <<'PY'
import sys, re
date_raw, lat, lon, loc = "", None, None, ""

def pc(s):
    s = re.sub(r'\(.*?\)', '', s).upper()
    nums = [float(x) for x in re.findall(r'[-+]?\d+(?:\.\d+)?', s)]
    d = re.search(r'[NSEW]', s)
    v = None
    if len(nums) == 1: v = nums[0]
    elif len(nums) == 2: v = nums[0] + nums[1]/60.0
    elif len(nums) >= 3: v = nums[0] + nums[1]/60.0 + nums[2]/3600.0
    if v is not None and d and d.group(0) in ('S', 'W'): v = -abs(v)
    return v

def pg(v):
    v = re.sub(r'\(.*?\)', '', v).upper()
    nums = [float(x) for x in re.findall(r'[-+]?\d+(?:\.\d+)?', v)]
    dirs = re.findall(r'[NSEW]', v)
    if len(nums) == 2:
        la, lo = nums[0], nums[1]
        if len(dirs) >= 1 and dirs[0] == 'S': la = -abs(la)
        if len(dirs) >= 2 and dirs[1] == 'W': lo = -abs(lo)
        elif len(dirs) == 1 and dirs[0] == 'W': lo = -abs(lo)
        return la, lo
    elif len(nums) == 6:
        la = nums[0] + nums[1]/60.0 + nums[2]/3600.0
        lo = nums[3] + nums[4]/60.0 + nums[5]/3600.0
        if len(dirs) >= 1 and dirs[0] == 'S': la = -abs(la)
        if len(dirs) >= 2 and dirs[1] == 'W': lo = -abs(lo)
        elif len(dirs) == 1 and dirs[0] == 'W': lo = -abs(lo)
        return la, lo
    elif len(nums) == 4:
        la = nums[0] + nums[1]/60.0
        lo = nums[2] + nums[3]/60.0
        if len(dirs) >= 1 and dirs[0] == 'S': la = -abs(la)
        if len(dirs) >= 2 and dirs[1] == 'W': lo = -abs(lo)
        elif len(dirs) == 1 and dirs[0] == 'W': lo = -abs(lo)
        return la, lo
    return None, None

for line in open(sys.argv[1], encoding='utf-8', errors='ignore'):
    line = line.strip()
    if not line: continue
    m = re.match(r'^\s*([A-Za-z ]+?)\s*[:=]\s*(.+?)\s*$', line)
    if m:
        k = m.group(1).lower().replace(' ', ''); val = m.group(2).strip()
        if k in ('date','datetime','datetimeoriginal','createdate'): date_raw = val
        elif k in ('gps','coords','coordinates','latlon','latlng'):
            a,b = pg(val);  lat,lon = (a,b) if a is not None and b is not None else (lat,lon)
        elif k in ('lat','latitude'):  a = pc(val); lat = a if a is not None else lat
        elif k in ('lon','lng','long','longitude'): a = pc(val); lon = a if a is not None else lon
        elif k in ('location','place','city'):
            a,b = pg(val)
            if a is not None and b is not None and -90<=a<=90 and -180<=b<=180: lat,lon = a,b
            else: loc = val
    else:
        a,b = pg(line)
        if a is not None and b is not None and -90<=a<=90 and -180<=b<=180: lat,lon = a,b

if lat is not None and not (-90  <= lat <= 90 ): lat = None
if lon is not None and not (-180 <= lon <= 180): lon = None
fmt = lambda x: '' if x is None else f'{x:.7f}'
print('\t'.join([date_raw, fmt(lat), fmt(lon), loc]))
PY
}

count=0
while IFS= read -r -d '' f; do
    sc="$(find_sidecar "$f")"; [ -n "$sc" ] || continue
    IFS=$'\t' read -r RAWDATE LAT LON LOC < <(parse_sidecar "$sc")

    args=()
    if [ -n "$RAWDATE" ]; then
        if [[ "$RAWDATE" =~ ^[0-9]{4}:[0-9]{2}:[0-9]{2} ]]; then
            EXIFDATE="$RAWDATE"
        else
            EXIFDATE="$(date -d "$RAWDATE" +'%Y:%m:%d %H:%M:%S' 2>/dev/null)"
            if [ -z "$EXIFDATE" ]; then
                CLEANED="${RAWDATE//./-}"
                EXIFDATE="$(date -d "$CLEANED" +'%Y:%m:%d %H:%M:%S' 2>/dev/null)"
            fi
        fi
        if [ -n "${EXIFDATE:-}" ]; then
            args+=( "-DateTimeOriginal=$EXIFDATE" "-CreateDate=$EXIFDATE" )
        fi
    fi

    if [ -n "$LAT" ] && [ -n "$LON" ]; then
        ABS_LAT=${LAT#-}
        REF_LAT="N"
        if [[ "$LAT" == -* ]]; then REF_LAT="S"; fi
        ABS_LON=${LON#-}
        REF_LON="E"
        if [[ "$LON" == -* ]]; then REF_LON="W"; fi
        args+=( "-GPSLatitude=$ABS_LAT" "-GPSLatitudeRef=$REF_LAT" "-GPSLongitude=$ABS_LON" "-GPSLongitudeRef=$REF_LON" )
    fi
    if [ -n "$LOC" ]; then
        IFS=',' read -r C S K <<< "$LOC"
        C="$(echo "$C" | sed 's/^ *//;s/ *$//')"; S="$(echo "$S" | sed 's/^ *//;s/ *$//')"; K="$(echo "$K" | sed 's/^ *//;s/ *$//')"
        [ -n "$C" ] && args+=( "-City=$C" )
        [ -n "$S" ] && args+=( "-State=$S" )
        [ -n "$K" ] && args+=( "-Country=$K" )
    fi

    [ ${#args[@]} -eq 0 ] && continue

    if [ "$KEEP_BACKUP" = "1" ]; then
        EXIF_CMD=(exiftool "${args[@]}" "$f")
    else
        EXIF_CMD=(exiftool -overwrite_original "${args[@]}" "$f")
    fi

    if "${EXIF_CMD[@]}" >/dev/null 2>&1; then
        count=$((count+1))
    else
        ext="${f##*.}"
        if [ "${ext,,}" = "png" ]; then
            new_jpg="${f%.*}.jpg"
            if command -v magick >/dev/null 2>&1; then IM="magick"; else IM="convert"; fi
            if $IM "$f" "$new_jpg" >/dev/null 2>&1; then
                if [ "$KEEP_BACKUP" = "1" ]; then
                    exiftool "${args[@]}" "$new_jpg" >/dev/null 2>&1
                else
                    exiftool -overwrite_original "${args[@]}" "$new_jpg" >/dev/null 2>&1
                fi
                rm -f "$f"
                count=$((count+1))
            fi
        fi
    fi
done < <(find "$PHOTO_DIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
        -o -iname '*.webp' -o -iname '*.tif' -o -iname '*.tiff' -o -iname '*.heic' -o -iname '*.heif' \) -print0)
EOF
chmod +x "$APP_DIR/apply-overrides.sh"

# =============================================================================
# 5. exif-daemon.sh
# =============================================================================
echo "▶ Writing exif-daemon.sh..."
cat > "$APP_DIR/exif-daemon.sh" << 'EOF'
#!/bin/bash
set -u
PHOTO_DIR="$HOME/Pictures/Screensavers/Media"

while ! command -v exiftool >/dev/null 2>&1; do sleep 10; done

parse_sidecar() {
    python3 - "$1" <<'PY'
import sys, re
date_raw, lat, lon, loc = "", None, None, ""

def pg(v):
    v = re.sub(r'\(.*?\)', '', v).upper()
    nums = [float(x) for x in re.findall(r'[-+]?\d+(?:\.\d+)?', v)]
    dirs = re.findall(r'[NSEW]', v)
    if len(nums) == 2:
        la, lo = nums[0], nums[1]
        if len(dirs) >= 1 and dirs[0] == 'S': la = -abs(la)
        if len(dirs) >= 2 and dirs[1] == 'W': lo = -abs(lo)
        elif len(dirs) == 1 and dirs[0] == 'W': lo = -abs(lo)
        return la, lo
    elif len(nums) == 6:
        la = nums[0] + nums[1]/60.0 + nums[2]/3600.0
        lo = nums[3] + nums[4]/60.0 + nums[5]/3600.0
        if len(dirs) >= 1 and dirs[0] == 'S': la = -abs(la)
        if len(dirs) >= 2 and dirs[1] == 'W': lo = -abs(lo)
        elif len(dirs) == 1 and dirs[0] == 'W': lo = -abs(lo)
        return la, lo
    elif len(nums) == 4:
        la = nums[0] + nums[1]/60.0
        lo = nums[2] + nums[3]/60.0
        if len(dirs) >= 1 and dirs[0] == 'S': la = -abs(la)
        if len(dirs) >= 2 and dirs[1] == 'W': lo = -abs(lo)
        elif len(dirs) == 1 and dirs[0] == 'W': lo = -abs(lo)
        return la, lo
    return None, None

for line in open(sys.argv[1], encoding='utf-8', errors='ignore'):
    line = line.strip()
    if not line: continue
    m = re.match(r'^\s*([A-Za-z ]+?)\s*[:=]\s*(.+?)\s*$', line)
    if m:
        k = m.group(1).lower().replace(' ', ''); val = m.group(2).strip()
        if k in ('date','datetime','datetimeoriginal','createdate'): date_raw = val
        elif k in ('gps','coords','coordinates','latlon','latlng'):
            a,b = pg(val);  lat,lon = (a,b) if a is not None and b is not None else (lat,lon)
        elif k in ('location','place','city'):
            a,b = pg(val)
            if a is not None and b is not None and -90<=a<=90 and -180<=b<=180: lat,lon = a,b
            else: loc = val
    else:
        a,b = pg(line)
        if a is not None and b is not None and -90<=a<=90 and -180<=b<=180: lat,lon = a,b

if lat is not None and not (-90  <= lat <= 90 ): lat = None
if lon is not None and not (-180 <= lon <= 180): lon = None
fmt = lambda x: '' if x is None else f'{x:.7f}'
print('\t'.join([date_raw, fmt(lat), fmt(lon), loc]))
PY
}

while true; do
    find "$PHOTO_DIR" -type f -name '*.txt' -print0 | while IFS= read -r -d '' txt_file; do
        base="${txt_file%.txt}"
        media_file=""

        if [ -f "$base" ]; then
            media_file="$base"
        else
            for ext in jpg jpeg png webp tif tiff heic heif mp4 mkv; do
                if [ -f "${base}.${ext}" ]; then media_file="${base}.${ext}"; break; fi
                if [ -f "${base}.${ext^^}" ]; then media_file="${base}.${ext^^}"; break; fi
            done
        fi

        [ -z "$media_file" ] && continue
        
        # --- NEW: Auto-orient anomalous EXIF rotations ---
        if [ "${ext,,}" = "jpg" ] || [ "${ext,,}" = "jpeg" ]; then
            # Check if Orientation exists and is NOT 1 (Normal)
            ORIENT=$(exiftool -s -s -s -Orientation -n "$media_file" 2>/dev/null)
            if [ -n "$ORIENT" ] && [ "$ORIENT" -ne 1 ]; then
                if command -v magick >/dev/null 2>&1; then
                    magick mogrify -auto-orient "$media_file"
                    touch "$media_file" # Update timestamp so mpv picks up the change
                fi
            fi
        fi
        # -------------------------------------------------
        
        

        if [ "$txt_file" -nt "$media_file" ]; then
            IFS=$'\t' read -r RAWDATE LAT LON LOC < <(parse_sidecar "$txt_file")
            args=()

            if [ -n "$RAWDATE" ]; then
                if [[ "$RAWDATE" =~ ^[0-9]{4}:[0-9]{2}:[0-9]{2} ]]; then
                    EXIFDATE="$RAWDATE"
                else
                    EXIFDATE="$(date -d "$RAWDATE" +'%Y:%m:%d %H:%M:%S' 2>/dev/null)"
                    if [ -z "$EXIFDATE" ]; then
                        CLEANED="${RAWDATE//./-}"
                        EXIFDATE="$(date -d "$CLEANED" +'%Y:%m:%d %H:%M:%S' 2>/dev/null)"
                    fi
                fi
                if [ -n "${EXIFDATE:-}" ]; then
                    args+=( "-DateTimeOriginal=$EXIFDATE" "-CreateDate=$EXIFDATE" )
                fi
            fi

            if [ -n "$LAT" ] && [ -n "$LON" ]; then
                ABS_LAT=${LAT#-}
                REF_LAT="N"
                if [[ "$LAT" == -* ]]; then REF_LAT="S"; fi
                ABS_LON=${LON#-}
                REF_LON="E"
                if [[ "$LON" == -* ]]; then REF_LON="W"; fi
                args+=( "-GPSLatitude=$ABS_LAT" "-GPSLatitudeRef=$REF_LAT" "-GPSLongitude=$ABS_LON" "-GPSLongitudeRef=$REF_LON" )
            fi

            if [ ${#args[@]} -gt 0 ]; then
                if exiftool -overwrite_original "${args[@]}" "$media_file" >/dev/null 2>&1; then
                    touch "$media_file"
                else
                    ext="${media_file##*.}"
                    if [ "${ext,,}" = "png" ]; then
                        new_jpg="${media_file%.*}.jpg"
                        if command -v magick >/dev/null 2>&1; then IM="magick"; else IM="convert"; fi
                        if $IM "$media_file" "$new_jpg" >/dev/null 2>&1; then
                            exiftool -overwrite_original "${args[@]}" "$new_jpg" >/dev/null 2>&1
                            rm -f "$media_file"
                            touch "$new_jpg"
                        fi
                    fi
                fi
            fi
        fi
    done
    sleep 60
done
EOF
chmod +x "$APP_DIR/exif-daemon.sh"

# =============================================================================
# 5b. vid-daemon.sh 
# =============================================================================
echo "▶ Writing vid-daemon.sh..."
cat > "$APP_DIR/vid-daemon.sh" << 'EOF'
#!/bin/bash
set -u
MEDIA_DIR="$HOME/Pictures/Screensavers/Media"
OPT_DIR="$HOME/Pictures/Screensavers/Optimized_Vids"
LOG_FILE="$HOME/Screensaver-App/vid-daemon.log"
STATUS_FILE="$HOME/Screensaver-App/vid-status"

mkdir -p "$OPT_DIR"
touch "$LOG_FILE"

log() { echo "[$(date +'%H:%M:%S')] $*" >> "$LOG_FILE"; }

# Signal handling — trap so Ctrl+C cleanly stops mid-encode and so the daemon
# dies with its parent shell instead of orphaning. huponexit is off by default
# on Fedora bash, which is the other half of why orphans happened before.
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

    # Process substitution (not pipe) so the loop runs in THIS shell, where
    # the trap can actually reach the active ffmpeg child.
    while IFS= read -r -d '' vid; do
        [ -f "$vid" ] || continue

        filename="$(basename "$vid")"
        base="${filename%.*}"

        # Target = the real display size published by photo.lua (display.conf).
        # Falls back to 4K 16:9 until mpv has reported a size at least once.
        TARGET_W=3840; TARGET_H=2160
        DISPLAY_CONF="$HOME/Screensaver-App/display.conf"
        if [ -s "$DISPLAY_CONF" ]; then
            res="$(tr -dc '0-9x' < "$DISPLAY_CONF")"
            if [[ "$res" =~ ^([0-9]+)x([0-9]+)$ ]]; then
                TARGET_W="${BASH_REMATCH[1]}"; TARGET_H="${BASH_REMATCH[2]}"
            fi
        fi
        TARGET="fp1-${TARGET_W}x${TARGET_H}"

        # Clean output filenames — same name as source, just with .mp4 extension.
        # Matches what photo.lua's redirect lookup expects.
        out_file="$OPT_DIR/${base}.mp4"
        skip_marker="$OPT_DIR/.skip_${base}"
        res_marker="$OPT_DIR/.res_${base}"
        tmp_file="$OPT_DIR/.tmp_${base}.mp4"
        prev_res="$(cat "$res_marker" 2>/dev/null || true)"

        # Redo prior work if the source changed OR the display resolution changed
        # (a clip blur-filled for 16:9 is wrong once the target is 32:9, etc.).
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

        # Probe ONLY to decide whether the video needs optimization and to grab
        # duration for the progress %. Rotation is detected here for the aspect-
        # ratio test, NOT to drive a transpose — ffmpeg auto-rotation handles
        # the pixels for us downstream.
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
    # Effective dimensions are what the user sees AFTER ffmpeg auto-rotates.
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

        # No transpose: ffmpeg's default -autorotate handles orientation for us
        # using the display-matrix side data, so pixels arrive upright.
        # Filter chain matches photo.lua's adaptive blur exactly: blur a cheap
        # 640x360 downscale (σ=50) then upscale to the REAL display size; contain
        # the sharp clip and center it over the blur. setsar=1 after each scale
        # forces square pixels so a non-16:9 target (e.g. 32:9) isn't reinterpreted
        # back to 16:9 by the encoder. The trailing stages bake in the SAME frosted
        # subtitle panel photo.lua uses for images: the video behind the date/
        # location text is gaussian-blurred + gently darkened with feathered edges,
        # so videos get a live frosted-glass backdrop instead of a flat box.
        FILTER="[0:v]split[bg][fg];[bg]scale=640:360,setsar=1,gblur=sigma=50,scale=${TARGET_W}:${TARGET_H},setsar=1[b];[fg]scale=${TARGET_W}:${TARGET_H}:force_original_aspect_ratio=decrease,setsar=1[f];[b][f]overlay=(W-w)/2:(H-h)/2,setsar=1"

        log "⚙ Optimizing: $filename (dur=${DURATION_S}s)"
        echo "$filename — starting..." > "$STATUS_FILE"
        rm -f "$STATUS_FILE.raw"

        # </dev/null hard-disconnects stdin so ffmpeg can never drop into the
        # interactive "Enter command:" mode. -map_metadata -1 + rotate=0 strips
        # any stale rotation tags — pixels are already upright in the output.
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

        # Progress watcher: reads -progress key=value output, writes percent
        # to STATUS_FILE every 2s. Tail it with: watch -n1 cat ~/Screensaver-App/vid-status
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

    echo "idle (next scan in 5 min)" > "$STATUS_FILE"
    sleep 300 &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null
    SLEEP_PID=""
done
EOF
chmod +x "$APP_DIR/vid-daemon.sh"

# =============================================================================
# 6. mpv.conf
# =============================================================================
echo "▶ Writing mpv.conf..."
cat > "$CFG/mpv.conf" << 'EOF'
fullscreen=yes
loop-playlist=inf
shuffle=yes
image-display-duration=7
osc=no
osd-bar=no
keep-open=no
input-conf=~~/input.conf
script=~~/photo.lua
hwdec=auto-safe
volume=70

# Per-file video filters are now set dynamically by photo.lua (on_load), sized
# to the REAL display so the blurred-fill background adapts to any aspect ratio.
# Static vf profiles are intentionally omitted here — they would override the
# adaptive filter and force a fixed 4K/16:9 canvas.
EOF

# =============================================================================
# 7. launch.sh
# =============================================================================
echo "▶ Writing launch.sh..."
cat > "$APP_DIR/launch.sh" << 'LAUNCH_EOF'
#!/bin/bash
pgrep -f "Screensaver-App/config" >/dev/null 2>&1 && exit 0

AUDIO_SOCK="/tmp/ss_audio.sock"
MUSIC_DIR="$HOME/Music/ScreenSaver"
MEDIA_DIR="$HOME/Pictures/Screensavers/Media"

# Non-fatal sanity check: if the HUD's core tool is missing, say so once.
command -v exiftool >/dev/null 2>&1 || \
    echo "⚠ exiftool not found — date/location HUD will be disabled. Run setup-screensaver.sh to install deps." >&2

MUSIC_PID=""
EXIF_PID=""
VID_PID=""

cleanup() {
    [ -n "$MUSIC_PID" ] && kill "$MUSIC_PID" 2>/dev/null
    [ -n "$EXIF_PID" ] && kill "$EXIF_PID" 2>/dev/null
    [ -n "$VID_PID" ]  && kill "$VID_PID" 2>/dev/null
    rm -f "$AUDIO_SOCK"
}
trap cleanup EXIT INT TERM

rm -f "$AUDIO_SOCK"

nice -n 19 "$HOME/Screensaver-App/exif-daemon.sh" >/dev/null 2>&1 &
EXIF_PID=$!

"$HOME/Screensaver-App/vid-daemon.sh" >/dev/null 2>&1 &
VID_PID=$!

if [ -d "$MUSIC_DIR" ] && [ -n "$(ls -A "$MUSIC_DIR" 2>/dev/null)" ]; then
    mpv --no-video --loop-playlist=inf --shuffle --input-ipc-server="$AUDIO_SOCK" "$MUSIC_DIR" >/dev/null 2>&1 &
    MUSIC_PID=$!
fi

mpv --config-dir="$HOME/Screensaver-App/config" "$MEDIA_DIR"
LAUNCH_EOF
chmod +x "$APP_DIR/launch.sh"

# =============================================================================
# 8. idle-watcher.sh
# =============================================================================
echo "▶ Writing idle-watcher.sh..."
cat > "$APP_DIR/idle-watcher.sh" << 'EOF'
#!/bin/bash
IDLE_LIMIT=300000
while true; do
    if playerctl -a status 2>/dev/null | grep -iq "playing"; then sleep 10; continue; fi
    if pactl list sink-inputs 2>/dev/null | grep -iq "state: RUNNING"; then sleep 10; continue; fi
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        RAW=$(gdbus call --session --dest org.gnome.Mutter.IdleMonitor --object-path /org/gnome/Mutter/IdleMonitor/Core --method org.gnome.Mutter.IdleMonitor.GetIdletime 2>/dev/null)
        IDLE_MS=$(echo "$RAW" | awk '{print $2}' | tr -d '[,)]')
    else
        IDLE_MS=$(xdotool getidletime 2>/dev/null)
    fi
    IDLE_MS=${IDLE_MS:-0}
    [ "$IDLE_MS" -gt "$IDLE_LIMIT" ] && "$HOME/Screensaver-App/launch.sh"
    sleep 10
done
EOF
chmod +x "$APP_DIR/idle-watcher.sh"

# =============================================================================
# 9. Autostart + manual launcher
# =============================================================================
echo "▶ Writing autostart + app launcher..."
cat > "$HOME/.config/autostart/idle-watcher.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Exec=sh -c "$HOME/Screensaver-App/idle-watcher.sh"
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=Screensaver Idle Watcher
Comment=Launches the photo screensaver after 5 minutes idle
EOF

cat > "$HOME/.local/share/applications/screensaver-now.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Exec=sh -c "$HOME/Screensaver-App/launch.sh"
Icon=video-display
Terminal=false
Name=Start Screensaver
Comment=Launch the 4K photo screensaver now
Categories=Utility;
EOF

# =============================================================================
# 10. Done
# =============================================================================
echo ""
echo "✅ Migration and Deployment finished!"
echo "Your structure is:"
echo "   App Code   : $APP_DIR"
echo "   Media      : $MEDIA_DIR"
echo "   Caches     : $MAP_DIR & $OPT_DIR"
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo ""
    echo "⚠ Reminder: still missing -> ${MISSING[*]}"
    echo "  Install those, then re-run this script before launching."
fi
