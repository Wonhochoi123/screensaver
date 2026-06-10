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

-- Tunable HUD sizes, all read from screensaver.conf (via the environment).
-- Text sizes are a fraction of screen HEIGHT; layout fracs are noted inline.
local function envn(name, default)
    return tonumber(os.getenv(name) or "") or default
end
local HUD_MUSIC_FS  = envn("HUD_MUSIC_FS",  0.030)  -- music info marquee
local HUD_DATE_FS   = envn("HUD_DATE_FS",   0.030)  -- date (top-right line 1)
local HUD_REGION_FS = envn("HUD_REGION_FS", 0.030)  -- region (top-right line 2)
local HUD_CITY_FS   = envn("HUD_CITY_FS",   0.066)  -- city headline
local HUD_COORD_FS  = envn("HUD_COORD_FS",  0.025)  -- GPS coordinates
local HUD_MAP_FRAC  = envn("HUD_MAP_FRAC",  0.27)   -- minimap/QR size (frac of height)
local MUSIC_WIN_FRAC = envn("MUSIC_WIN_FRAC", 0.30) -- marquee width (frac of width)
local HUD_THUMB_FRAC = envn("HUD_THUMB_FRAC", 0.07) -- album-art thumb size (frac of height)
local HUD_TEXT_BLUR  = envn("HUD_TEXT_BLUR", 0.10)  -- text shadow blur/spread (×font size)
local HUD_TEXT_GLOW  = envn("HUD_TEXT_GLOW", 0.002) -- text shadow strength = border width (×font size)

local THUMB_ID     = 3      -- mpv overlay id for the album-art thumb (1,2 = minimap)
local THUMB_FRAMES = 240    -- rotation frames (1.5° each) — fine enough to look smooth
local HUD_THUMB_SPIN_SECS = envn("HUD_THUMB_SPIN_SECS", 7.2)  -- seconds per revolution
local THUMB_TICK   = HUD_THUMB_SPIN_SECS / THUMB_FRAMES       -- ≈0.03s → ~33 fps

local ZOOMS        = {11, 14, 16}
local RING_COLORS  = {"#FFFFFF", "#B3E5FC", "#4FC3F7"}
local DEFAULT_ZIDX = 1

local ov       = mp.create_osd_overlay("ass-events")
local pause_ov = mp.create_osd_overlay("ass-events")  -- res set per-draw from the real display
local qr_coord_ov  = mp.create_osd_overlay("ass-events")
local map_coord_ov = mp.create_osd_overlay("ass-events")
local music_ov     = mp.create_osd_overlay("ass-events")
local music_bar_ov    = mp.create_osd_overlay("ass-events")  -- music played
local music_bar_bg_ov = mp.create_osd_overlay("ass-events")  -- music track
local music_measure_ov = mp.create_osd_overlay("ass-events") -- hidden; measures text width
local music_thumb_ov   = mp.create_osd_overlay("ass-events") -- album-art ring / empty target
local landmark_ov  = mp.create_osd_overlay("ass-events")
local progress_ov    = mp.create_osd_overlay("ass-events")  -- played
local progress_bg_ov = mp.create_osd_overlay("ass-events")  -- remaining (track)
local top_bar_ov     = mp.create_osd_overlay("ass-events")  -- global progress, played
local top_bar_bg_ov  = mp.create_osd_overlay("ass-events")  -- global progress, month sections
local top_label_ov   = mp.create_osd_overlay("ass-events")  -- hovered month label
local loading_ov   = mp.create_osd_overlay("ass-events")

-- Shared progress-bar styling: a translucent light-gray track with a
-- translucent white fill. Used by the bottom video bar and the music bar.
local BAR_TRACK = "\\1c&HC8C8C8&\\alpha&H9E&"   -- light gray, mostly transparent
local BAR_FILL  = "\\1c&HFFFFFF&\\alpha&H3C&"   -- white, mostly opaque

-- ----------------------------------------------------------------------------
-- Loading-screen input lock
--   The screensaver always opens on a black "please wait" screen while the
--   playlist is (re)built. That phase must be non-interactive: no pausing, no
--   skipping, no quitting. We grab every interactive key with forced bindings
--   that do nothing, and release them the instant real content loads. The lock
--   is engaged immediately (script load == the black screen appearing) so even
--   the very first keypress is swallowed.
-- ----------------------------------------------------------------------------
local LOADING_KEYS = {
    "SPACE","PLAY","PAUSE","PLAYPAUSE","p","RIGHT","LEFT","UP","DOWN",
    "PGDWN","PGUP","END","HOME","NEXT","PREV","[","]","DEL","=","-",
    "MBTN_LEFT","MBTN_RIGHT","WHEEL_UP","WHEEL_DOWN","ESC","q",
}
local ss_input_locked = false
local function lock_loading_input()
    if ss_input_locked then return end
    ss_input_locked = true
    for i, k in ipairs(LOADING_KEYS) do
        mp.add_forced_key_binding(k, "ssload_" .. i, function() end)
    end
end
local function unlock_loading_input()
    if not ss_input_locked then return end
    ss_input_locked = false
    for i = 1, #LOADING_KEYS do
        mp.remove_key_binding("ssload_" .. i)
    end
end
lock_loading_input()

-- Now-playing marquee state (forward-declared so the click handler, defined
-- earlier in the file, can reference them as upvalues).
local music_shown  = nil       -- full track string currently displayed
local music_hit    = nil       -- clickable box {x0,y0,x1,y1}; nil when no track
local poll_music               -- assigned later
local music_bar    = nil       -- {x,y,w,th,W,H} bar geometry under the marquee
local music_pct    = nil       -- 0..100 song position from the audio player
local draw_music_bar           -- assigned later
local thumb        = nil       -- {x,y,d,cx,cy,r,W,H} album-art circle; nil = none
local thumb_dir    = nil       -- dir of f000.bgra rotation frames; nil = no art
local thumb_idx    = 0         -- current rotation frame
local music_path   = nil       -- current audio file (drives thumb regeneration)
local music_playing = true     -- audio play state (spins the thumb when true)
local draw_thumb_ring          -- assigned later
local load_thumb_for           -- assigned later
local gp_sections              -- global month sections (forward; built later)
local gp_section_at            -- hit-test for the month bar (forward; defined later)
local progress_is_active       -- assigned later; true only for seekable videos
local main_shown   = nil       -- city currently shown center-bottom (skip re-animating if unchanged)

-- Strip distracting separators (comma, slash, hyphen, pipe, dot-sep, dashes…)
-- from display labels, collapsing to single spaces. Used everywhere EXCEPT the
-- coordinate read-outs (which keep their °, ', " punctuation).
local function clean_text(s)
    if not s then return s end
    s = s:gsub("[,/\\|;:_]", " ")
    s = s:gsub("%-", " ")
    s = s:gsub("\xc2\xb7", " ")          -- · middle dot
    s = s:gsub("\xe2\x80\x93", " ")      -- – en dash
    s = s:gsub("\xe2\x80\x94", " ")      -- — em dash
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- Soft glow: a blurred dark halo behind the text (border only — each caller
-- keeps its own fill colour/alpha). Scales with the font so it looks the same
-- at 1080p and 4K. HUD_TEXT_BLUR (config) controls the spread.
local function glow(fs)
    return string.format("\\bord%.2f\\blur%.2f\\shad0\\3c&H000000&\\4c&H000000&",
        fs * HUD_TEXT_GLOW, fs * HUD_TEXT_BLUR)
end

local seq       = 0
local prewarmed = {}
local cur       = { seq = 0, path = nil, orig = nil, lat = nil, lon = nil, mdir = nil, zidx = DEFAULT_ZIDX, w = 552, h = 616, auto = true }

local MONTHS = {jan=1,feb=2,mar=3,apr=4,may=5,jun=6,jul=7,aug=8,sep=9,oct=10,nov=11,dec=12}

local DISPLAY_W, DISPLAY_H = nil, nil
-- Seed from the last-known ACTUAL resolution (written to display.conf on every
-- run) so even the first frame uses the real screen shape, never a guessed
-- ratio. mpv's real size overrides this the moment it is known.
do
    local f = io.open(APP_DIR .. "/display.conf", "r")
    if f then
        local s = f:read("*a") or ""; f:close()
        local dw, dh = s:match("(%d+)x(%d+)")
        if dw and dh then DISPLAY_W, DISPLAY_H = tonumber(dw), tonumber(dh) end
    end
end
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
        if dir and file and not dir:match("/Optimized_Vids") then
            local base_name = file:match("(.+)%.[^%.]+$") or file
            local w, h = refresh_display_size()
            -- Optimized clips are encoded per screen resolution, so switching
            -- monitors/TVs reuses an existing folder instead of re-encoding.
            local opt_path = OPT_DIR .. string.format("/%dx%d/", w, h) .. base_name .. ".mp4"
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
    local S   = math.floor(win_h * HUD_MAP_FRAC); S = S - (S % 4)
    local pad = math.floor(win_h * 0.02)
    local fs  = math.floor(win_h * HUD_COORD_FS + 0.5)
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
        "{\\an5\\pos(%d,%d)\\fnMontserrat SemiBold\\fs%d\\fsp%d\\1c&HFFFFFF&%s\\alpha&H40&}",
        x, y, fs, math.floor(fs * 0.06 + 0.5), glow(fs))
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
    -- Simple by design: the bottom-center headline is just the CITY name, and
    -- the top-right line is the date + the broader region (state / country).
    -- No detailed-landmark lookup any more.
    local date, city, general, lat, lon = nil, "", "", nil, nil

    -- 1) Base values straight from the sidecar (a tiny file read, no subprocess).
    local x = read_xmp(orig_path .. ".xmp")
    if x then
        date     = iso_to_display(x.date_iso)
        lat, lon = x.lat, x.lon
        local _, c, region, country =
            niagara_fix(nil, x.city, abbr_subdiv(x.state, nil), abbr_country(x.country, nil))
        city    = c or ""
        general = join_loc(nil, nil, region, country)   -- state + country only
    end

    -- 2) Date fallback: file mtime, if the sidecar carried no date.
    if not date then
        local fi = utils.file_info(orig_path)
        if fi and fi.mtime then date = os.date("%b %d, %Y", fi.mtime) end
    end

    -- 3) Manual ".txt" override wins (read live, so edits apply immediately).
    --    A manual location string becomes the headline (city) label.
    local sc = parse_sidecar(orig_path)
    if sc then
        if sc.date then date = sc.date end
        if sc.location and sc.location ~= "" then city = sc.location; general = "" end
        if sc.lat and sc.lon then lat, lon = sc.lat, sc.lon end
    end

    if lat and (lat < -90  or lat > 90 ) then lat = nil end
    if lon and (lon < -180 or lon > 180) then lon = nil end

    -- HUD map/QR images are sized from the screen HEIGHT, so they are kept in a
    -- per-height folder (…/Maps/h_<height>). Switching to a screen of a height
    -- already seen reuses its folder instead of rebuilding every tile.
    local _, disp_h = refresh_display_size()
    cb({ date = date, city = city, general = general, lat = lat, lon = lon,
         mdir = MAP_DIR .. "/h_" .. tostring(disp_h) })
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
        -- Two vertical bars in the top-right, sized/placed as fractions of the
        -- ACTUAL display — adapts to any resolution or aspect ratio.
        local w, h = refresh_display_size()
        pause_ov.res_x = w; pause_ov.res_y = h
        local bw    = math.floor(h * 0.018)    -- bar width
        local bh    = math.floor(h * 0.054)    -- bar height
        local gap   = math.floor(h * 0.015)    -- gap between the two bars
        local right = math.floor(w * 0.025)    -- inset from the right edge
        local y0    = math.floor(h * 0.06)     -- inset from the top
        local y1    = y0 + bh
        local x2    = w - right                 -- right bar's right edge
        local x1L   = x2 - bw                    -- right bar's left edge
        local x0L   = x1L - gap - bw             -- left bar's left edge
        pause_ov.data = string.format(
            "{\\an7\\pos(0,0)\\bord0\\shad4\\3c&H000000&\\4c&H000000&\\1c&HFFFFFF&\\alpha&H40&\\p1}"
            .. "m %d %d l %d %d l %d %d l %d %d "
            .. "m %d %d l %d %d l %d %d l %d %d{\\p0}",
            x0L, y0, x0L + bw, y0, x0L + bw, y1, x0L, y1,
            x1L, y0, x1L + bw, y0, x1L + bw, y1, x1L, y1)
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
    local mouse = mp.get_property_native("mouse-pos")

    -- Click a month on the top global bar to jump straight to it.
    if mouse and gp_section_at then
        local hv = gp_section_at(mouse.x, mouse.y)
        if hv and gp_sections and gp_sections[hv] then
            mp.set_property_number("playlist-pos", gp_sections[hv].start - 1)
            return
        end
    end

    -- Click the album-art thumb (left of the marquee) to pause/play the MUSIC
    -- only (independent of the slideshow). Works even with no cover art (the
    -- empty ring is still a target).
    if mouse and thumb then
        local dx = mouse.x - thumb.cx
        local dy = mouse.y - thumb.cy
        if dx * dx + dy * dy <= thumb.r * thumb.r then
            mp.commandv("run", "/bin/sh", "-c",
                "printf '%s\\n' '{\"command\":[\"cycle\",\"pause\"]}' | socat - UNIX-CONNECT:" .. AUDIO_SOCK .. " 2>/dev/null")
            return
        end
    end

    -- Click the now-playing marquee (top-left) to skip to the next track.
    -- Checked first so it works regardless of whether the photo has GPS.
    if mouse and music_hit then
        if mouse.x >= music_hit.x0 and mouse.x <= music_hit.x1
           and mouse.y >= music_hit.y0 and mouse.y <= music_hit.y1 then
            mp.commandv("run", "/bin/sh", "-c",
                "printf '%s\\n' '{\"command\":[\"playlist-next\"]}' | socat - UNIX-CONNECT:" .. AUDIO_SOCK .. " 2>/dev/null")
            if poll_music then mp.add_timeout(0.35, poll_music) end
            return
        end
    end

    -- Click the razor-thin progress bar along the very bottom to seek. The
    -- visible bar is only a few pixels tall, so the clickable strip is a little
    -- taller (bottom 3% of the screen) to stay easy to hit. Only active when the
    -- bar is actually shown (real videos) — clicking the bottom of a photo or a
    -- title card does nothing, matching the hidden bar.
    if mouse and progress_is_active and progress_is_active() then
        local w, h = refresh_display_size()
        if w > 0 and mouse.y >= h - math.floor(h * 0.03) then
            local frac = mouse.x / w
            if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
            -- "exact" forces a frame-accurate seek. Without it mpv snaps to the
            -- nearest preceding keyframe, which on these veryfast-encoded clips
            -- (sparse keyframes) jumps the playhead back to ~0.
            mp.commandv("seek", frac * 100, "absolute-percent+exact")
            return
        end
    end

    if not (cur.lat and cur.lon) then
        mp.command("script-message ss-toggle-pause")
        return
    end

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

-- UTF-8-aware split into glyphs (mpv's Lua ships no utf8 library), so worldwide
-- landmark names with accents / non-Latin scripts animate one character at a time.
local function utf8_split(s)
    local t = {}
    local i, len = 1, #s
    while i <= len do
        local b = s:byte(i)
        local n = 1
        if     b >= 0xF0 then n = 4
        elseif b >= 0xE0 then n = 3
        elseif b >= 0xC0 then n = 2 end
        t[#t + 1] = s:sub(i, i + n - 1)
        i = i + n
    end
    return t
end

-- Animated landmark reveal, mirroring the title cards: each glyph fades in at a
-- random moment and settles at ~0.75 opacity (alpha &H40&). Driven by timers so
-- it animates reliably on the live OSD overlay (which has no event clock).
math.randomseed(os.time())
local LM_FINAL_ALPHA = 0x40
local lm_gen = 0

local function animate_landmark(text, cx, by, fs, fsp, win_w, win_h)
    lm_gen = lm_gen + 1
    local gen = lm_gen
    local glyphs = utf8_split(text)
    local n = #glyphs
    local header = string.format(
        "{\\an2\\pos(%d,%d)\\fnMontserrat ExtraBold\\fs%d\\fsp%d\\1c&HFFFFFF&%s}",
        cx, by, fs, fsp, glow(fs))
    local FADE, last = 0.55, 0
    local start_t = {}
    for i = 1, n do
        local st = math.random() * 0.9          -- spread reveals over 0..0.9s
        start_t[i] = st
        if st > last then last = st end
    end
    local total = last + FADE
    local t0 = mp.get_time()
    landmark_ov.res_x = win_w
    landmark_ov.res_y = win_h
    local function frame()
        if gen ~= lm_gen then return end
        local el = mp.get_time() - t0
        local parts = { header }
        for i = 1, n do
            local st, a = start_t[i], nil
            if el <= st then a = 0xFF
            elseif el >= st + FADE then a = LM_FINAL_ALPHA
            else a = math.floor(0xFF + (LM_FINAL_ALPHA - 0xFF) * ((el - st) / FADE) + 0.5) end
            parts[#parts + 1] = string.format("{\\alpha&H%02X&}%s", a, glyphs[i])
        end
        landmark_ov.data = table.concat(parts)
        landmark_ov:update()
        if el < total then mp.add_timeout(0.033, frame) end
    end
    frame()
end

mp.register_event("file-loaded", function()
    local path = mp.get_property("path")
    if not path then return end

    -- First real (non-loading) file: the playlist handoff is done — let input
    -- through again and drop the "please wait" overlay.
    if ss_input_locked and not path:find("lavfi", 1, true) then
        unlock_loading_input()
    end

    local orig_path = path
    if path:find("/Optimized_Vids/") then
        local orig_file = path:match("([^/]+)%.mp4$")
        if orig_file then
            orig_path = MEDIA_DIR .. "/" .. orig_file
        end
    end

    clear_hud_osd()
    ov:remove()
    lm_gen = lm_gen + 1   -- cancel any in-flight landmark animation
    landmark_ov:remove()
    loading_ov:remove()
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

        local date    = m.date
        local general = m.general or ""
        local mdir    = m.mdir

        -- Style matches the title cards: Montserrat ExtraBold, no outline, no
        -- shadow, white, alpha &H40&. Distracting separators are stripped from
        -- every label (the coordinate read-outs keep their punctuation).
        local function draw_text()
            local L = hud_geom()
            local m_top    = math.floor(L.win_h * 0.04)   -- top inset
            local m_right  = math.floor(L.win_h * 0.02)    -- right inset (matches the map's)
            local m_bottom = math.floor(L.win_h * 0.07)    -- bottom inset

            -- Top-right: date over the broader region (state / country). Each
            -- line carries its own \fs so HUD_DATE_FS and HUD_REGION_FS tune
            -- independently.
            local d   = clean_text(compact_date(date))
            local g   = clean_text(general)
            local fsd = math.floor(L.win_h * HUD_DATE_FS)
            local fsr = math.floor(L.win_h * HUD_REGION_FS)
            local stack = ""
            if d and d ~= "" and g and g ~= "" then
                stack = string.format("{\\fs%d}%s\\N{\\fs%d}%s", fsd, d, fsr, g)
            elseif d and d ~= "" then stack = string.format("{\\fs%d}%s", fsd, d)
            elseif g and g ~= "" then stack = string.format("{\\fs%d}%s", fsr, g) end

            ov.res_x = L.win_w
            ov.res_y = L.win_h
            if stack == "" then
                ov:remove()
            else
                local fs  = math.max(fsd, fsr)   -- glow sized to the larger line
                local fsp = math.floor(L.win_h * 0.003 + 0.5)
                ov.data = string.format(
                    "{\\an9\\pos(%d,%d)\\fnMontserrat ExtraBold\\fsp%d\\1c&HFFFFFF&%s\\alpha&H40&}%s",
                    L.win_w - m_right, m_top, fsp, glow(fs), stack)
                ov:update()
            end

            -- Bottom-center headline: just the CITY name. Doubled letter spacing.
            -- The glyph-by-glyph reveal only plays when the city actually CHANGES
            -- — repeated same-city photos just show it (no rebuild animation).
            local city = clean_text(m.city or ""):upper()
            local fs   = math.floor(L.win_h * HUD_CITY_FS)   -- bigger headline
            local fsp  = math.floor(fs * 0.3636 + 0.5)       -- spacing scales with size
            local cx   = math.floor(L.win_w / 2)
            local by   = L.win_h - m_bottom
            if city == "" then
                main_shown = nil
                lm_gen = lm_gen + 1
                landmark_ov:remove()
            elseif city ~= main_shown then
                main_shown = city
                animate_landmark(city, cx, by, fs, fsp, L.win_w, L.win_h)
            else
                lm_gen = lm_gen + 1   -- cancel any stray animation; show statically
                landmark_ov.res_x = L.win_w
                landmark_ov.res_y = L.win_h
                landmark_ov.data = string.format(
                    "{\\an2\\pos(%d,%d)\\fnMontserrat ExtraBold\\fs%d\\fsp%d\\1c&HFFFFFF&%s\\alpha&H40&}%s",
                    cx, by, fs, fsp, glow(fs), city)
                landmark_ov:update()
            end
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

-- Now-playing marquee (top-left). Same title-card style as the rest of the HUD:
-- Montserrat ExtraBold, no outline, no shadow, white. Stays on. The window is a
-- fraction of the screen width; titles that don't fit bounce (ping-pong) so the
-- whole string is revealed and then it returns, never scrolling past the end to
-- hide content. A \clip masks overflow. A progress bar sits just beneath it.
-- Click it to skip to the next track.
-- The marquee window width (MUSIC_WIN_FRAC, read at the top) is a fraction of
-- the screen width, so it's "way longer" on bigger displays.
local music_scroll_gen = 0  -- bumped on each new track; cancels the old scroller

local function set_music(text)
    if not text or text == "" then return end
    text = text:sub(1, 160)                     -- caller already cleaned it
    if text == "" then return end
    if text == music_shown then return end
    music_shown = text
    music_pct   = 0                            -- new track → bar restarts empty
    music_scroll_gen = music_scroll_gen + 1
    local gen = music_scroll_gen

    local w, h = refresh_display_size()
    local fs   = math.floor(h * HUD_MUSIC_FS)
    local fsp  = math.floor(h * 0.003 + 0.5)
    local py   = math.floor(h * 0.04)
    local y_top  = py - math.floor(fs * 0.25)
    local y_bot  = py + math.floor(fs * 1.30)
    local bar_th = math.max(1, math.floor(h * 0.00117 + 0.5))   -- thin (≈1/3 of old)
    local bar_y  = py + math.floor(fs * 1.45)    -- just under the text

    -- Album-art thumb sits at the left margin; the text starts to its right.
    -- Left inset matches the QR/minimap's (hud_geom pad = win_h * 0.02).
    local left_x  = math.floor(h * 0.02)
    local thumb_d = math.floor(h * HUD_THUMB_FRAC)
    local px      = left_x
    if thumb_d > 0 then
        local block_cy = math.floor((y_top + bar_y + bar_th) / 2)
        thumb = { x = left_x, y = block_cy - math.floor(thumb_d / 2), d = thumb_d,
                  cx = left_x + math.floor(thumb_d / 2), cy = block_cy,
                  r = math.floor(thumb_d / 2), W = w, H = h }
        px = left_x + thumb_d + math.floor(thumb_d * 0.30)   -- gap after the thumb
        draw_thumb_ring()
    else
        thumb = nil; music_thumb_ov:remove()
        mp.command_native({"overlay-remove", THUMB_ID})
    end
    local win_px = math.floor(w * MUSIC_WIN_FRAC)

    music_ov.res_x = w
    music_ov.res_y = h

    local label   = text
    local style   = string.format(
        "\\fnMontserrat ExtraBold\\fs%d\\fsp%d\\1c&HFFFFFF&%s\\alpha&H40&", fs, fsp, glow(fs))

    -- Measure the real rendered width (a hidden compute-bounds overlay), so the
    -- scroll stops exactly when the last glyph reaches the window edge — no
    -- per-glyph estimate, no over-scroll past the end. Falls back to an estimate
    -- if the measurement is unavailable.
    local text_px
    music_measure_ov.res_x = w; music_measure_ov.res_y = h
    music_measure_ov.hidden = true
    music_measure_ov.compute_bounds = true
    music_measure_ov.data = string.format("{\\an7\\pos(0,0)%s}%s", style, label)
    local mb = music_measure_ov:update()
    music_measure_ov:remove()
    if mb and mb.x0 and mb.x1 and mb.x1 > mb.x0 then
        text_px = math.ceil(mb.x1 - mb.x0)
    else
        text_px = math.floor((fs * 0.60 + fsp) * #utf8_split(label))
    end

    if text_px <= win_px then
        -- Fits: static, no scroll, no clip. Hit box + bar hug the text width.
        music_ov.data = string.format("{\\an7\\pos(%d,%d)%s}%s", px, py, style, label)
        music_ov:update()
        music_hit = { x0 = px - fs, y0 = y_top, x1 = px + text_px + fs, y1 = y_bot }
        music_bar = { x = px, y = bar_y, w = text_px, th = bar_th, W = w, H = h }
        draw_music_bar()
        return
    end

    -- Too long for the window: bounce (ping-pong). Scroll left only far enough
    -- to reveal the end of the string, dwell, then scroll back to the start and
    -- dwell. Never loops past the end to hide content. A \clip masks overflow.
    local clip       = string.format("\\clip(%d,%d,%d,%d)", px, y_top, px + win_px, y_bot)
    local SPEED      = math.max(1, fs * 0.045)    -- px per frame (~50 px/s)
    local DWELL      = 30                          -- frames (~0.9s) held at each end
    local max_offset = text_px - win_px            -- how far left fully reveals the end
    music_hit = { x0 = px - fs, y0 = y_top, x1 = px + win_px + fs, y1 = y_bot }
    music_bar = { x = px, y = bar_y, w = win_px, th = bar_th, W = w, H = h }
    draw_music_bar()

    local sx   = 0
    local dir  = 1        -- 1 = scrolling left (revealing end), -1 = back to start
    local hold = DWELL    -- start with a pause showing the beginning
    local function frame()
        if gen ~= music_scroll_gen then return end
        if hold > 0 then
            hold = hold - 1
        else
            sx = sx + dir * SPEED
            if sx >= max_offset then sx = max_offset; dir = -1; hold = DWELL
            elseif sx <= 0 then sx = 0; dir = 1; hold = DWELL end
        end
        music_ov.data = string.format("{\\an7\\pos(%d,%d)%s%s}%s",
            math.floor(px - sx), py, clip, style, label)
        music_ov:update()
        mp.add_timeout(0.03, frame)
    end
    frame()
end

-- Music progress bar drawn under the marquee, the same width as the info text.
-- Driven by the audio player's percent-pos (polled below). Same translucent
-- look as the bottom video bar.
function draw_music_bar()
    local b = music_bar
    if not b then
        music_bar_ov:remove(); music_bar_bg_ov:remove(); return
    end
    local function rect(x0, x1)
        return string.format("m %d %d l %d %d l %d %d l %d %d",
            x0, b.y, x1, b.y, x1, b.y + b.th, x0, b.y + b.th)
    end

    music_bar_bg_ov.res_x = b.W; music_bar_bg_ov.res_y = b.H
    music_bar_bg_ov.data = string.format(
        "{\\an7\\pos(0,0)\\bord0\\shad0%s\\p1}%s{\\p0}", BAR_TRACK, rect(b.x, b.x + b.w))
    music_bar_bg_ov:update()

    music_bar_ov.res_x = b.W; music_bar_ov.res_y = b.H
    local pct = music_pct
    if pct and pct > 0 then
        local fw = math.floor(b.w * math.max(0, math.min(pct, 100)) / 100 + 0.5)
        if fw > 0 then
            music_bar_ov.data = string.format(
                "{\\an7\\pos(0,0)\\bord0\\shad0%s\\p1}%s{\\p0}", BAR_FILL, rect(b.x, b.x + fw))
            music_bar_ov:update()
        else
            music_bar_ov:remove()
        end
    else
        music_bar_ov:remove()
    end
end

-- A circle as an ASS vector path (4 cubic beziers), for the thumb's ring and
-- its empty (no-cover) state.
local function ass_circle(cx, cy, r)
    local k = math.floor(r * 0.5523 + 0.5)
    return string.format(
        "m %d %d b %d %d %d %d %d %d b %d %d %d %d %d %d b %d %d %d %d %d %d b %d %d %d %d %d %d",
        cx, cy - r,
        cx + k, cy - r, cx + r, cy - k, cx + r, cy,
        cx + r, cy + k, cx + k, cy + r, cx, cy + r,
        cx - k, cy + r, cx - r, cy + k, cx - r, cy,
        cx - r, cy - k, cx - k, cy - r, cx, cy - r)
end

-- The thumb's faint ring — drawn whenever there's a thumb, so the album art has
-- a border and the empty (no-cover) state still shows a clickable target.
function draw_thumb_ring()
    if not thumb then music_thumb_ov:remove(); return end
    local t = thumb
    -- Opaque light-grey ring (no alpha), transparent fill so the art shows through.
    music_thumb_ov.res_x = t.W; music_thumb_ov.res_y = t.H
    music_thumb_ov.data = string.format(
        "{\\an7\\pos(0,0)\\p1\\1a&HFF&\\bord%d\\3c&HC8C8C8&\\3a&H00&\\shad0}%s{\\p0}",
        math.max(1, math.floor(t.d * 0.03 + 0.5)), ass_circle(t.cx, t.cy, t.r))
    music_thumb_ov:update()
end

-- Generate (or reuse cached) rotation frames for the current track's cover art,
-- then show the first frame. build-thumb.sh prints its output dir, or nothing
-- when the file has no embedded art (then the thumb stays an empty ring).
function load_thumb_for(path)
    if not thumb or path == nil or path == "" then return end
    local d = thumb.d
    mp.command_native_async({
        name = "subprocess", capture_stdout = true, playback_only = false,
        args = { CFG_DIR .. "/build-thumb.sh", path, tostring(d), tostring(THUMB_FRAMES) },
    }, function(ok, res)
        if music_path ~= path or not thumb then return end   -- track moved on
        local dir = (ok and res and res.stdout or ""):gsub("%s+$", "")
        if dir ~= "" and file_exists(dir .. "/.frames") then
            thumb_dir = dir; thumb_idx = 0
            mp.command_native({"overlay-add", THUMB_ID, thumb.x, thumb.y,
                string.format("%s/f000.bgra", dir), 0, "bgra", thumb.d, thumb.d, thumb.d * 4})
        else
            thumb_dir = nil
            mp.command_native({"overlay-remove", THUMB_ID})
        end
    end)
end

-- New audio file → reset the thumb and (re)generate its frames.
local function on_music_path(p)
    if p == music_path then return end
    music_path = p
    thumb_dir = nil; thumb_idx = 0
    mp.command_native({"overlay-remove", THUMB_ID})
    load_thumb_for(p)
end

-- Spin the thumb like a vinyl record while the music plays (freeze on the
-- current frame when paused). Reversed direction, ~7.2s per revolution.
local function thumb_tick()
    if thumb and thumb_dir and music_playing then
        thumb_idx = (thumb_idx - 1) % THUMB_FRAMES   -- reverse spin
        mp.command_native({"overlay-add", THUMB_ID, thumb.x, thumb.y,
            string.format("%s/f%03d.bgra", thumb_dir, thumb_idx),
            0, "bgra", thumb.d, thumb.d, thumb.d * 4})
    end
    mp.add_timeout(THUMB_TICK, thumb_tick)
end
thumb_tick()

-- Poll the audio player (separate mpv on AUDIO_SOCK): position for the bar, file
-- path for the thumb, and pause state for the spin. One round-trip for all three.
local function poll_music_pos()
    if not music_shown then return end
    mp.command_native_async({
        name = "subprocess", capture_stdout = true, playback_only = false,
        args = { "/bin/sh", "-c",
            "printf '%s\\n%s\\n%s\\n' "
            .. "'{\"command\":[\"get_property\",\"percent-pos\"],\"request_id\":1}' "
            .. "'{\"command\":[\"get_property\",\"path\"],\"request_id\":2}' "
            .. "'{\"command\":[\"get_property\",\"pause\"],\"request_id\":3}' "
            .. "| socat -t1 - UNIX-CONNECT:" .. AUDIO_SOCK .. " 2>/dev/null" },
    }, function(ok, res)
        -- Each property only updates on a successful read; nothing is cleared on
        -- a slow/empty poll, so the bar holds its position instead of flickering
        -- off (this is what made it look broken on some mp3/flac files).
        local new_path
        if ok and res and res.stdout then
            for line in res.stdout:gmatch("[^\n]+") do
                local j = utils.parse_json(line)
                if j and j.error == "success" and j.request_id then
                    if j.request_id == 1 and type(j.data) == "number" then
                        music_pct = j.data
                    elseif j.request_id == 2 and type(j.data) == "string" then
                        new_path = j.data
                    elseif j.request_id == 3 then
                        music_playing = (j.data ~= true)
                    end
                end
            end
        end
        if new_path then on_music_path(new_path) end
        draw_music_bar()
    end)
end
mp.add_periodic_timer(1, poll_music_pos)

-- Poll the audio player; only rebuild the marquee when the track changes.
function poll_music()
    mp.command_native_async({
        name = "subprocess", capture_stdout = true,
        args = { "/bin/sh", "-c",
            "printf '%s\\n' '{\"command\":[\"get_property\",\"metadata\"]}' | socat -t1 - UNIX-CONNECT:" .. AUDIO_SOCK .. " 2>/dev/null" },
    }, function(ok, res)
        local title, artist
        if ok and res and res.stdout and res.stdout ~= "" then
            local j = utils.parse_json(res.stdout)
            if j and j.data and j.error == "success" then
                local meta = j.data
                title  = meta.title  or meta.Title  or meta.TITLE
                artist = meta.artist or meta.Artist or meta.ARTIST
            end
        end
        if title and title ~= "" then
            local line = clean_text(title)
            if artist and artist ~= "" then
                local a = clean_text(artist)
                if a ~= "" then line = line .. " - " .. a end   -- title - artist
            end
            set_music(line)
            return
        end
        -- No embedded title tag: fall back to the filename (media-title).
        mp.command_native_async({
            name = "subprocess", capture_stdout = true,
            args = { "/bin/sh", "-c",
                "printf '%s\\n' '{\"command\":[\"get_property\",\"media-title\"]}' | socat -t1 - UNIX-CONNECT:" .. AUDIO_SOCK .. " 2>/dev/null" },
        }, function(ok2, res2)
            if ok2 and res2 and res2.stdout and res2.stdout ~= "" then
                local j2 = utils.parse_json(res2.stdout)
                if j2 and j2.data and j2.error == "success" then
                    set_music(clean_text(tostring(j2.data):gsub("%.[^%.]+$", "")))
                end
            end
        end)
    end)
end
mp.add_periodic_timer(3, poll_music)
poll_music()

mp.register_script_message("ss-show-loading", function(title, subtitle)
    lock_loading_input()   -- defensive: stay non-interactive while loading
    title    = (title    and title    ~= "") and title    or "LOADING"
    subtitle = (subtitle and subtitle ~= "") and subtitle or "Please wait..."
    local w, h = refresh_display_size()
    local fs   = math.floor(h * 0.066)
    local fsp  = math.floor(h * 0.024 + 0.5)
    local fs2  = math.floor(h * 0.040)
    local fsp2 = math.floor(h * 0.016 + 0.5)
    loading_ov.res_x = w; loading_ov.res_y = h
    loading_ov.data = string.format(
        "{\\an5\\pos(%d,%d)\\fnMontserrat ExtraBold\\fs%d\\fsp%d\\1c&HFFFFFF&%s\\alpha&H00&}%s"
        .. "\\N\\N{\\fnMontserrat SemiBold\\fs%d\\fsp%d\\alpha&H80&}%s",
        math.floor(w / 2), math.floor(h / 2) - math.floor(fs * 0.5),
        fs, fsp, glow(fs), title, fs2, fsp2, subtitle)
    loading_ov:update()
end)

mp.register_event("shutdown", function()
    ov:remove()
    pause_ov:remove()
    music_ov:remove()
    music_bar_ov:remove()
    music_bar_bg_ov:remove()
    music_measure_ov:remove()
    music_thumb_ov:remove()
    pcall(mp.command_native, {"overlay-remove", THUMB_ID})
    landmark_ov:remove()
    loading_ov:remove()
    progress_ov:remove()
    progress_bg_ov:remove()
    top_bar_ov:remove()
    top_bar_bg_ov:remove()
    top_label_ov:remove()
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

-- ----------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
-- Now-playing progress bar (razor-thin strip across the very bottom)
--   Driven by mpv's NATIVE percent-pos — the same position data behind mpv's
--   built-in OSD bar — so pausing, seeking and looping are all handled by the
--   player itself; no wall-clock bookkeeping, no drift.
--   Shown for real videos only. Stills are skipped because mpv keeps
--   time-pos/duration at 0 for images (there is no position to show), and
--   month title cards are skipped by request. percent-pos updates per frame
--   while a video plays, which is plenty smooth.
--   Click anywhere along the bottom strip to seek (handled in
--   handle-left-click above).
-- ----------------------------------------------------------------------------
local prog_fill = -1

-- The bar (and click-to-seek) is for real videos only: stills have no position
-- and month title cards are excluded by request.
function progress_is_active()
    local path = mp.get_property("path") or ""
    return mp.get_property_number("percent-pos") ~= nil
        and (mp.get_property_number("duration") or 0) > 0
        and not path:find("/TitleCards/", 1, true)
        and not path:find("lavfi", 1, true)
end

local function draw_progress(_, pp)
    if not (pp and progress_is_active()) then
        if prog_fill ~= -1 then
            progress_ov:remove(); progress_bg_ov:remove(); prog_fill = -1
        end
        return
    end

    local w, h  = refresh_display_size()
    local fillw = math.floor(w * math.max(0, math.min(pp, 100)) / 100 + 0.5)
    if fillw == prog_fill then return end
    prog_fill = fillw

    local th = math.max(2, math.floor(h * 0.003 + 0.5))
    local y0 = h - th
    local function rect(x0, x1)
        return string.format("m %d %d l %d %d l %d %d l %d %d", x0, y0, x1, y0, x1, h, x0, h)
    end

    progress_bg_ov.res_x = w; progress_bg_ov.res_y = h
    if fillw < w then
        progress_bg_ov.data = string.format(
            "{\\an7\\pos(0,0)\\bord0\\shad0%s\\p1}%s{\\p0}", BAR_TRACK, rect(fillw, w))
        progress_bg_ov:update()
    else
        progress_bg_ov:remove()
    end

    progress_ov.res_x = w; progress_ov.res_y = h
    if fillw > 0 then
        progress_ov.data = string.format(
            "{\\an7\\pos(0,0)\\bord0\\shad0%s\\p1}%s{\\p0}", BAR_FILL, rect(0, fillw))
        progress_ov:update()
    else
        progress_ov:remove()
    end
end

mp.observe_property("percent-pos", "number", draw_progress)
mp.register_event("file-loaded", function() prog_fill = -1 end)

-- ----------------------------------------------------------------------------
-- Global progress bar (very top of screen), chaptered by month — YouTube-style.
--   The playlist is grouped into month sections (each begins with a title
--   card); a section's width is proportional to how many items that month
--   holds, so busier months are wider. The fill shows how far through the whole
--   library we are. Hovering a month thickens that section and shows its label
--   (e.g. "Nov 2023"); clicking jumps to that month. All relative to the display.
-- ----------------------------------------------------------------------------
gp_sections        = nil    -- { {start=1-based, count=, x0=, w=, label=}, … }
local gp_built_for = -1     -- playlist-count the sections were last built for
local gp_W, gp_H   = 0, 0   -- display size the sections were laid out for
local gp_hover     = nil    -- index of the hovered section; nil = none

local function gp_geom()
    local w, h = refresh_display_size()
    local margin = math.floor(h * 0.02)                         -- side inset (matches HUD)
    local th     = math.max(2, math.floor(h * 0.003 + 0.5))     -- same as the bottom bar
    local th_hi  = math.max(th + 2, math.floor(h * 0.010 + 0.5))-- hovered section thickness
    local gap    = math.max(2, math.floor(w * 0.0016 + 0.5))    -- gap between months
    return w, h, margin, th, th_hi, gap
end

local function gp_rect(x0, x1, th)   -- flush to the top edge (y = 0)
    return string.format("m %d 0 l %d 0 l %d %d l %d %d", x0, x1, x1, th, x0, th)
end

-- "Nov 2023" from a section's lead entry (its title card).
local function gp_label(entry)
    local t = entry.title
    if t and t ~= "" then
        local mon, yr = t:match("(%a+)%s+(%d+)")
        if mon and yr then return mon:sub(1, 3) .. " " .. yr end
        return t
    end
    local yr, mon = (entry.filename or ""):match("(%d%d%d%d)%-(%a+)")
    if yr and mon then return mon:sub(1, 3) .. " " .. yr end
    return ""
end

-- Which section is under (mx,my)? Only the top band counts as the hover zone, so
-- the thin bar is still easy to hit.
function gp_section_at(mx, my)
    if not gp_sections or not mx then return nil end
    local w, h = refresh_display_size()
    if my > h * 0.03 then return nil end
    for i, s in ipairs(gp_sections) do
        if mx >= s.x0 and mx <= s.x0 + s.w then return i end
    end
    return nil
end

local function draw_top_bar()
    if not gp_sections then top_bar_ov:remove(); top_bar_bg_ov:remove(); top_label_ov:remove(); return end
    local w, h, _, th, th_hi = gp_geom()
    local idx = (mp.get_property_number("playlist-pos") or 0) + 1
    local track, fill = {}, {}
    for i, s in ipairs(gp_sections) do
        local sth = (gp_hover == i) and th_hi or th
        track[#track + 1] = gp_rect(s.x0, s.x0 + s.w, sth)
        local s_end = s.start + s.count - 1
        if idx > s_end then
            fill[#fill + 1] = gp_rect(s.x0, s.x0 + s.w, sth)
        elseif idx >= s.start then
            local fw = math.floor(s.w * (idx - s.start + 1) / s.count + 0.5)
            if fw > 0 then fill[#fill + 1] = gp_rect(s.x0, s.x0 + fw, sth) end
        end
    end

    top_bar_bg_ov.res_x = w; top_bar_bg_ov.res_y = h
    top_bar_bg_ov.data = string.format("{\\an7\\pos(0,0)\\bord0\\shad0%s\\p1}%s{\\p0}",
        BAR_TRACK, table.concat(track, " "))
    top_bar_bg_ov:update()

    top_bar_ov.res_x = w; top_bar_ov.res_y = h
    if #fill > 0 then
        top_bar_ov.data = string.format("{\\an7\\pos(0,0)\\bord0\\shad0%s\\p1}%s{\\p0}",
            BAR_FILL, table.concat(fill, " "))
        top_bar_ov:update()
    else
        top_bar_ov:remove()
    end

    if gp_hover and gp_sections[gp_hover] then
        local s  = gp_sections[gp_hover]
        local fs = math.floor(h * HUD_DATE_FS)
        top_label_ov.res_x = w; top_label_ov.res_y = h
        top_label_ov.data = string.format(
            "{\\an8\\pos(%d,%d)\\fnMontserrat ExtraBold\\fs%d\\fsp%d\\1c&HFFFFFF&%s\\alpha&H40&}%s",
            s.x0 + math.floor(s.w / 2), th_hi + math.floor(h * 0.008),
            fs, math.max(1, math.floor(fs * 0.05 + 0.5)), glow(fs), s.label)
        top_label_ov:update()
    else
        top_label_ov:remove()
    end
end

local function build_month_sections()
    local pl = mp.get_property_native("playlist")
    local n  = pl and #pl or 0
    gp_built_for = n
    if n <= 1 then                                   -- loading screen / nothing to chapter
        gp_sections = nil
        top_bar_ov:remove(); top_bar_bg_ov:remove(); top_label_ov:remove()
        return
    end
    -- Group into sections: a new one starts at each title card (and at index 1).
    local secs = {}
    for i = 1, n do
        local fn = pl[i].filename or ""
        if #secs == 0 or fn:find("/TitleCards/", 1, true) then
            secs[#secs + 1] = { start = i, count = 0, label = gp_label(pl[i]) }
        end
        secs[#secs].count = secs[#secs].count + 1
    end

    local w, h, margin, _, _, gap = gp_geom()
    local avail = (w - 2 * margin) - (#secs - 1) * gap
    if avail < 1 then avail = w - 2 * margin; gap = 0 end
    local x = margin
    for _, s in ipairs(secs) do
        s.w  = math.max(1, math.floor(avail * s.count / n + 0.5))
        s.x0 = x
        x = x + s.w + gap
    end
    gp_sections = secs; gp_W = w; gp_H = h
    draw_top_bar()
end

mp.register_event("file-loaded", function()
    local n = mp.get_property_number("playlist-count") or 0
    local w, h = refresh_display_size()
    if n ~= gp_built_for or w ~= gp_W or h ~= gp_H then
        build_month_sections()
    else
        draw_top_bar()
    end
end)

-- Hover: thicken the month under the cursor and show its label.
mp.observe_property("mouse-pos", "native", function(_, mpos)
    if not mpos then return end
    local hv = gp_section_at(mpos.x, mpos.y)
    if hv ~= gp_hover then gp_hover = hv; draw_top_bar() end
end)

-- ----------------------------------------------------------------------------
-- Delete the current media (DEL key)
--   Moves the photo/video and everything derived from it to the system trash —
--   the .xmp / .txt sidecars and every per-resolution optimized clip — drops it
--   from the playlist, and immediately advances to the next item.
-- ----------------------------------------------------------------------------
mp.register_script_message("ss-delete-current", function()
    local pos = mp.get_property_number("playlist-pos")
    if not pos then return end
    local path = mp.get_property("playlist/" .. pos .. "/filename")
    if not path or path == "" then return end

    -- Never delete generated title cards.
    if path:find("/TitleCards/") then
        mp.osd_message("Title card — not deleting", 1.5)
        return
    end

    -- Resolve an optimized-clip path back to the original media file.
    local orig = path
    if path:find("/Optimized_Vids/") then
        local f = path:match("([^/]+)%.mp4$")
        if f then orig = MEDIA_DIR .. "/" .. f end
    end

    mp.command_native_async({
        name = "subprocess", playback_only = false,
        args = { CFG_DIR .. "/trash-media.sh", orig },
    }, function() end)

    mp.osd_message("🗑 Deleted", 1.0)

    -- Advance right away. Removing the current entry plays the next one; if it
    -- was the only item left, quit cleanly.
    local count = mp.get_property_number("playlist-count") or 1
    if count <= 1 then
        mp.command("quit")
    else
        mp.commandv("playlist-remove", "current")
    end
end)

