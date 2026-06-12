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
local RES_DIR    = env("RES_DIR",    DATA_DIR .. "/HudResources")

local builder    = CFG_DIR .. "/build-minimap.sh"
local AUDIO_SOCK = env("AUDIO_SOCK", "/tmp/ss_audio.sock")
local BGM_SOCK   = "/tmp/ss_bgm.sock"   -- grok-briefing.sh's bgm mpv (matches that script)

-- ============================================================================
--  CONFIG IS THE SINGLE SOURCE OF TRUTH  →  screensaver.conf
--
--  >>> FOR ANY HUMAN OR AI EDITING THIS FILE <<<
--  Every tunable is read with cfg*()/below. Those look at the live environment
--  first (launch.sh exports the conf before mpv starts), then parse the conf
--  file itself as a backup (so this script also works run standalone). The
--  DEFAULT for each knob lives in screensaver.conf and NOWHERE ELSE.
--
--  Do NOT write literal default values here (no `cfgnum("X", 0.03)`, no
--  `local X = 0.03`). If you need a new knob: add it to screensaver.conf, then
--  read it here with cfgnum/cfgstr/cfglist and no baked-in number. A missing
--  numeric key warns and returns 0 on purpose, so the omission is obvious.
--  (Defaults kept getting duplicated here and drifting from the conf — that is
--  the bug this design exists to prevent. Keep the conf authoritative.)
-- ============================================================================
local conf_raw = {}
do
    local f = io.open(CFG_DIR .. "/screensaver.conf", "r")
    if f then
        for line in f:lines() do
            local k, rest = line:match("^%s*export%s+([%w_]+)=(.*)$")
            if k then
                rest = rest:gsub("^%s+", "")
                local q = rest:match('^"(.-)"') or rest:match("^'(.-)'")
                if q then rest = q else rest = rest:gsub("%s*#.*$", ""):gsub("%s+$", "") end
                conf_raw[k] = rest
            end
        end
        f:close()
    end
end
local function cfgraw(name)
    local v = os.getenv(name)
    if v == nil or v == "" then v = conf_raw[name] end
    return v
end
local function cfgnum(name)            -- numeric knob; 0 + warning if absent
    local n = tonumber(cfgraw(name) or "")
    if n == nil then msg.warn("screensaver.conf: missing numeric key " .. name); return 0 end
    return n
end
local function cfgstr(name) return cfgraw(name) end           -- string knob (may be nil)
local function cfglist(name, conv)     -- space-separated list -> array
    local t = {}
    for tok in (cfgraw(name) or ""):gmatch("%S+") do t[#t + 1] = conv and conv(tok) or tok end
    return t
end

local HUD_MUSIC_FS   = cfgnum("HUD_MUSIC_FS")     -- music info marquee
local HUD_DATE_FS    = cfgnum("HUD_DATE_FS")      -- date (top-right line 1)
local HUD_REGION_FS  = cfgnum("HUD_REGION_FS")    -- region (top-right line 2)
local HUD_CITY_FS    = cfgnum("HUD_CITY_FS")      -- city headline
local HUD_COORD_FS   = cfgnum("HUD_COORD_FS")     -- GPS coordinates
local HUD_MAP_FRAC   = cfgnum("HUD_MAP_FRAC")     -- minimap/QR size (frac of height)
local MUSIC_WIN_FRAC = cfgnum("MUSIC_WIN_FRAC")   -- marquee width (frac of width)
local SHOW_THUMB     = cfgraw("HUD_THUMB") ~= "0" -- album-art thumb shown unless set to 0
local HUD_TEXT_BLUR  = cfgnum("HUD_TEXT_BLUR")    -- text shadow blur/spread (×font size)
local HUD_TEXT_GLOW  = cfgnum("HUD_TEXT_GLOW")    -- text shadow strength (×font size)
-- (MUSIC_SCROLL_SPEED / MUSIC_SCROLL_DWELL retired — the marquee no longer scrolls.)

local GROK_ENABLED = cfgraw("GROK_BRIEFING") == "1"
local GROK_TIME    = cfgstr("GROK_TIME") or ""    -- "HH:MM" — for the clock countdown
-- The briefing logo is now drawn (vector ASS), not a PNG — see the briefing
-- section at the bottom. GROK_LOGO in the conf is no longer used.

local THUMB_ID     = 3      -- mpv overlay id for the album-art thumb (1,2 = minimap); internal

-- Minimap zoom levels + ring colours (emergency arrays only if the conf can't
-- be read — arrays can't degrade to 0; the real values live in the conf).
local ZOOMS        = cfglist("HUD_MAP_ZOOMS", tonumber)
if #ZOOMS == 0 then ZOOMS = {6, 8, 10, 12, 14, 16} end
local RING_COLORS  = cfglist("HUD_RING_COLORS")
if #RING_COLORS == 0 then RING_COLORS = {"#FFFFFF", "#4FC3F7"} end
local DEFAULT_ZIDX = 1

-- Ring colour for zoom level i. RING_COLORS are gradient stops, not a 1:1
-- list: the zoom levels are spread evenly across them and each level's colour
-- is interpolated, so any number of zooms works with any number of colours
-- (3 zooms over 3 stops lands exactly on the stops — the classic config is
-- unchanged). Global function: the main chunk is at Lua's 200-local cap.
function ring_color(i)
    local m, n = #RING_COLORS, #ZOOMS
    if m == 0 then return "#FFFFFF" end
    local function rgb(s)
        local r, g, b = (s or ""):match("#?(%x%x)(%x%x)(%x%x)")
        return tonumber(r or "", 16) or 255, tonumber(g or "", 16) or 255,
               tonumber(b or "", 16) or 255
    end
    if i <= 1 or m == 1 or n <= 1 then return string.format("#%02X%02X%02X", rgb(RING_COLORS[1])) end
    if i >= n then return string.format("#%02X%02X%02X", rgb(RING_COLORS[m])) end
    local t = (i - 1) / (n - 1) * (m - 1)   -- position along the stop chain
    local k = math.floor(t)
    local f = t - k
    local r1, g1, b1 = rgb(RING_COLORS[k + 1])
    local r2, g2, b2 = rgb(RING_COLORS[math.min(k + 2, m)])
    return string.format("#%02X%02X%02X",
        math.floor(r1 + (r2 - r1) * f + 0.5),
        math.floor(g1 + (g2 - g1) * f + 0.5),
        math.floor(b1 + (b2 - b1) * f + 0.5))
end

local ov       = mp.create_osd_overlay("ass-events")
local pause_ov = mp.create_osd_overlay("ass-events")  -- res set per-draw from the real display
local qr_coord_ov  = mp.create_osd_overlay("ass-events")
local map_coord_ov = mp.create_osd_overlay("ass-events")
local music_ov     = mp.create_osd_overlay("ass-events")
local music_menu_ov   = mp.create_osd_overlay("ass-events")  -- song chooser (below the bar)
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
local briefing_ov    = mp.create_osd_overlay("ass-events")  -- morning-briefing subtitles
local logo_ov        = mp.create_osd_overlay("ass-events")  -- stylish briefing logo (drawn)
local controls_ov    = mp.create_osd_overlay("ass-events")  -- briefing transport / replay menu
local logo_text_ov   = mp.create_osd_overlay("ass-events")  -- "getting ready" under the logo
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
-- Marquee + song-chooser data, grouped in one table (Lua caps main-chunk locals
-- at 200). layout = marquee layout; hover = mouse over the marquee; chooser =
-- chooser open; rows = visible chooser hit boxes; entries = the playlist;
-- scroll = first visible row (0-based); bounds = chooser panel box; poll_* = the
-- audio-player poll throttle.
local MQ = { layout = nil, hover = false, chooser = false, rows = {},
             entries = nil, scroll = 0, maxscroll = 0, bounds = nil, sbar = nil,
             poll_t = 0, poll_busy = false }
local render_marquee           -- assigned later; redraws the marquee for hover state
local chooser_hit              -- assigned later; hit-test a chooser row
local open_chooser             -- assigned later
local draw_chooser             -- assigned later; (re)draw the chooser at MQ.scroll
local thumb        = nil       -- {x,y,d,cx,cy,r,W,H} album-art circle; nil = none
-- Album-art state, grouped: TH.color/gray = bgra paths, TH.shown = blitted variant,
-- TH.path = current audio file (drives regeneration).
local TH = { color = nil, gray = nil, shown = nil, path = nil }
local music_playing = true     -- audio play state (color when true, gray when paused)
local draw_thumb_ring          -- assigned later
local load_thumb_for           -- assigned later
local gp_sections              -- global month sections (forward; built later)
local gp_section_at            -- hit-test for the month bar (forward; defined later)
local logo                    -- briefing logo geometry {x,y,w,h,...}; drawn, not a bitmap
local logo_hit                -- hit-test for the logo plaque (forward; defined later)
local logo_menu_hit           -- hit-test for the Replay/Refresh menu (forward)
local controls_hit            -- hit-test for the transport buttons (forward)
-- Badge/menu click state in one table (Lua caps main-chunk locals at 200).
-- menu_open = pinned open by a click; menu_vis = on screen (hover or pinned);
-- preparing = between a click and the first spoken line; t0 = when preparing began.
local BD = { menu_open = false, menu_vis = false, preparing = false, t0 = 0 }
local briefing_active         -- is a briefing process running? (forward)
local progress_is_active       -- assigned later; true only for seekable videos
local main_shown   = nil       -- city currently shown center-bottom (skip re-animating if unchanged)

-- Strip distracting separators (comma, slash, hyphen, pipe, dot-sep, dashes…)
-- from display labels, collapsing to single spaces. Used everywhere EXCEPT the
-- coordinate read-outs (which keep their °, ', " punctuation).
-- Fold accented/foreign Latin letters to plain ASCII, and drop apostrophes, so
-- place/song names read in the regular English alphabet (é→e, ñ→n, "d'Azur"→dAzur).
TRANSLIT = {
    ["à"]="a",["á"]="a",["â"]="a",["ã"]="a",["ä"]="a",["å"]="a",["ā"]="a",["ą"]="a",
    ["è"]="e",["é"]="e",["ê"]="e",["ë"]="e",["ē"]="e",["ė"]="e",["ę"]="e",
    ["ì"]="i",["í"]="i",["î"]="i",["ï"]="i",["ī"]="i",["į"]="i",
    ["ò"]="o",["ó"]="o",["ô"]="o",["õ"]="o",["ö"]="o",["ø"]="o",["ō"]="o",
    ["ù"]="u",["ú"]="u",["û"]="u",["ü"]="u",["ū"]="u",["ů"]="u",
    ["ñ"]="n",["ń"]="n",["ç"]="c",["ć"]="c",["č"]="c",["ž"]="z",["ź"]="z",["ż"]="z",
    ["š"]="s",["ś"]="s",["ý"]="y",["ÿ"]="y",["ß"]="ss",["ł"]="l",["đ"]="d",["ð"]="d",["þ"]="th",["æ"]="ae",["œ"]="oe",
    ["À"]="A",["Á"]="A",["Â"]="A",["Ã"]="A",["Ä"]="A",["Å"]="A",
    ["È"]="E",["É"]="E",["Ê"]="E",["Ë"]="E",["Ì"]="I",["Í"]="I",["Î"]="I",["Ï"]="I",
    ["Ò"]="O",["Ó"]="O",["Ô"]="O",["Õ"]="O",["Ö"]="O",["Ø"]="O",
    ["Ù"]="U",["Ú"]="U",["Û"]="U",["Ü"]="U",["Ñ"]="N",["Ç"]="C",["Ž"]="Z",["Š"]="S",
    ["'"]="",["`"]="",["´"]="",["’"]="",["‘"]="",   -- apostrophes / quotes removed
}
local function clean_text(s)
    if not s then return s end
    for k, v in pairs(TRANSLIT) do s = s:gsub(k, v) end
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

    -- During a briefing the screensaver becomes a calm backdrop: just the blurred,
    -- stretched-to-fill photo, no sharp foreground.
    if briefing_active and briefing_active() then
        mp.set_property("vf", string.format(
            "lavfi=[scale=640:360,setsar=1,gblur=sigma=50,scale=%d:%d,setsar=1]", w, h))
        return
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
local function abbr_country(name, code)
    if code and code ~= "" then return code:upper() end
    if name and name ~= "" then return COUNTRY_ABBR[name:lower()] or name end
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
    if briefing_active and briefing_active() then qr_coord_ov:remove(); map_coord_ov:remove(); return end
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
    if ZL then ZL.ov:remove() end
end

-- While a briefing is on screen, every HUD except the music block is hidden.
-- (Music marquee / thumb / bar stay; this clears map, QR, coords, date/region,
-- city headline and the month bar.)
local function clear_other_hud()
    clear_hud_osd()           -- map (2), QR (1), both coord read-outs
    ov:remove()               -- date / region (top-right)
    landmark_ov:remove()      -- city headline (bottom-center)
    top_bar_ov:remove(); top_bar_bg_ov:remove(); top_label_ov:remove()
end

-- SIGBUS guard for all bitmap overlays: overlay-add mmaps the file at the size
-- we claim, and mpv crashes (bus error) reading past EOF if the file is shorter
-- (half-written, or rendered for a different size). Verify before every blit.
function bgra_complete(path, S)   -- GLOBAL: main chunk is at the 200-local cap
    local fi = utils.file_info(path)
    return fi and fi.size and fi.size >= S * S * 4
end

local function apply_qr(bgra_path, L)
    if briefing_active and briefing_active() then return end
    if not bgra_complete(bgra_path, L.S) then return end
    mp.command_native({"overlay-add", 1, L.qr_x, L.img_top, bgra_path, 0, "bgra", L.S, L.S, L.S * 4})
end

ZL = { ov = mp.create_osd_overlay("ass-events") }   -- zoom-scale label (global: local cap)
local function apply_minimap(bgra_path, L)
    if briefing_active and briefing_active() then return end
    if not bgra_complete(bgra_path, L.S) then return end
    mp.command_native({"overlay-add", 2, L.map_x, L.img_top, bgra_path, 0, "bgra", L.S, L.S, L.S * 4})
    -- Zoom-scale read-out floated just ABOVE the map square: overlay-add
    -- bitmaps render on top of all ASS text, so a label inside the square
    -- would be buried under the map. Styled like the coordinate labels;
    -- cleared with the map in clear_hud_osd.
    local z = ZOOMS[cur.zidx]
    if z then
        ZL.ov.res_x = L.win_w; ZL.ov.res_y = L.win_h
        ZL.ov.data = coord_tags(L.map_cx, L.img_top - math.floor(L.fs * 0.7), L.fs) .. "Z" .. z
        ZL.ov:update()
    end
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
    build_one(lat, lon, ZOOMS[i], w, h, ring_color(i), mdir, function()
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

-- Per-media landmark choice (which of the candidate landmarks to show above the
-- city, cycled by the 'l' key). LP[path] = 1..N, or nil for "city only".
-- Remembered across sessions as "path<TAB>index" lines.
local LP = {}
do
    local f = io.open(DATA_DIR .. "/landmark_prefs.txt", "r")
    if f then
        for line in f:lines() do
            local p, i = line:match("^(.-)\t(%d+)$")
            if p and i then LP[p] = tonumber(i) end
        end
        f:close()
    end
end
local function save_landmark_prefs()
    local f = io.open(DATA_DIR .. "/landmark_prefs.txt", "w")
    if not f then return end
    for k, v in pairs(LP) do f:write(k, "\t", tostring(v), "\n") end
    f:close()
end

-- "A|B|C" (from the xmp) → cleaned candidate list {"A","B","C"}.
function split_landmarks(s)
    local out = {}
    if s and s ~= "" then
        for part in (s .. "|"):gmatch("([^|]*)|") do
            part = clean_text(part)
            if part and part ~= "" then out[#out + 1] = part end
        end
    end
    return out
end

local function resolve_meta(orig_path, cb)
    -- The bottom-center headline is the CITY name by default, or the LANDMARK when
    -- this media is toggled to it ('l' key). Top-right is the date + region.
    local date, city, general, lat, lon, landmark = nil, "", "", nil, nil, ""

    -- 1) Base values straight from the sidecar (a tiny file read, no subprocess).
    local x = read_xmp(orig_path .. ".xmp")
    if x then
        date     = iso_to_display(x.date_iso)
        lat, lon = x.lat, x.lon
        landmark = x.landmark or ""
        local _, c, region, country =
            niagara_fix(nil, x.city, x.state, abbr_country(x.country, nil))   -- full state name
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
    -- per-height folder (…/HudResources/h_<height>). Switching to a screen of a height
    -- already seen reuses its folder instead of rebuilding every tile.
    local _, disp_h = refresh_display_size()
    cb({ date = date, city = city, general = general, lat = lat, lon = lon,
         landmark = landmark, mdir = RES_DIR .. "/h_" .. tostring(disp_h) })
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
    if not paused then pause_ov:remove(); return end
    -- Draw in the OSD's OWN pixel space (osd-width/height) so the bars are never
    -- stretched on odd aspect ratios — and size both dimensions off h so the bar
    -- shape stays constant. No shadow; soft translucent white like the rest of
    -- the HUD. Sits a bit lower than before.
    local w = mp.get_property_number("osd-width") or 0
    local h = mp.get_property_number("osd-height") or 0
    if w < 1 or h < 1 then w, h = refresh_display_size() end
    pause_ov.res_x = w; pause_ov.res_y = h
    local bw    = math.floor(h * 0.016)    -- bar width
    local bh    = math.floor(h * 0.050)    -- bar height (≈3× width)
    local gap   = math.floor(h * 0.014)    -- gap between the two bars
    local right = math.floor(w * 0.020)    -- inset from the right edge
    local y0    = math.floor(h * 0.11)     -- lower inset from the top
    local y1    = y0 + bh
    local x1L   = w - right - bw            -- right bar's left edge
    local x0L   = x1L - gap - bw            -- left bar's left edge
    pause_ov.data = string.format(
        "{\\an7\\pos(0,0)\\bord0\\shad0\\1c&HFFFFFF&\\alpha&H30&\\p1}"
        .. "m %d %d l %d %d l %d %d l %d %d "
        .. "m %d %d l %d %d l %d %d l %d %d{\\p0}",
        x0L, y0, x0L + bw, y0, x0L + bw, y1, x0L, y1,
        x1L, y0, x1L + bw, y0, x1L + bw, y1, x1L, y1)
    pause_ov:update()
end
mp.observe_property("pause", "bool", function(_, v) set_pause_indicator(v or false) end)

mp.register_script_message("ss-toggle-pause", function()
    if bo_wake() then return end
    -- During a briefing OR quiet hours the music is held silent and must not be
    -- (re)started by space / clicks.
    if (briefing_active and briefing_active()) or (is_sleep_time and is_sleep_time()) then return end
    local newp = not mp.get_property_bool("pause")
    mp.set_property_bool("pause", newp)
    local v = newp and "true" or "false"
    mp.commandv("run", "/bin/sh", "-c",
        "printf '%s\\n' '{\"command\":[\"set_property\",\"pause\"," .. v .. "]}' | socat - UNIX-CONNECT:" .. AUDIO_SOCK .. " 2>/dev/null")
end)

local function show_current_zoom()
    if not (cur.lat and cur.lon and cur.mdir) then return end
    local z = ZOOMS[cur.zidx]
    local color = ring_color(cur.zidx)
    local s = cur.seq
    local L = hud_geom()
    build_one(cur.lat, cur.lon, z, L.S, L.S, color, cur.mdir, function(ok)
        if s ~= seq then return end
        if ok then apply_minimap(map_path(cur.mdir, z, cur.lat, cur.lon, L.S, L.S, color), L) end
    end)
end

mp.register_script_message("hud-zoom-in", function()
    if bo_wake() then return end
    cur.auto = false
    if not cur.lat then return end
    local ni = math.min(#ZOOMS, cur.zidx + 1)
    if ni == cur.zidx then return end
    cur.zidx = ni
    show_current_zoom()
end)

mp.register_script_message("hud-zoom-out", function()
    if bo_wake() then return end
    cur.auto = false
    if not cur.lat then return end
    local ni = math.max(1, cur.zidx - 1)
    if ni == cur.zidx then return end
    cur.zidx = ni
    show_current_zoom()
end)

mp.register_script_message("handle-left-click", function()
    if bo_wake() then return end
    local mouse = mp.get_property_native("mouse-pos")

    -- Morning-briefing badge (center-top). While speaking it shows a transport row
    -- (prev / pause / next / stop). Otherwise the Replay/Refresh chooser appears on
    -- hover (or when pinned by a click) — clicking a button runs it.
    if mouse then
        local active = briefing_active and briefing_active()
        if active then
            local act = controls_hit and controls_hit(mouse.x, mouse.y)
            if act then act(); return end
        else
            if BD.menu_vis then
                local act = logo_menu_hit and logo_menu_hit(mouse.x, mouse.y)
                if act then act(); BD.menu_open = false; return end
            end
            if logo_hit and logo_hit(mouse.x, mouse.y) then
                BD.menu_open = not BD.menu_open    -- pin/unpin (works without hover)
                return
            end
            if BD.menu_open then BD.menu_open = false; return end  -- click away unpins
        end
    end

    -- Left-click the month bar: jump to the EXACT media under the cursor (the
    -- horizontal position within the month maps to its item). (Right-click jumps
    -- to the month's start — see handle-right-click.) Inert during a briefing.
    if mouse and gp_section_at and not (briefing_active and briefing_active()) then
        local hv = gp_section_at(mouse.x, mouse.y)
        if hv and gp_sections and gp_sections[hv] then
            local s = gp_sections[hv]
            local frac = (mouse.x - s.x0) / math.max(1, s.w)
            frac = math.max(0, math.min(0.999, frac))
            local item = math.min(s.start + math.floor(frac * s.count), s.start + s.count - 1)
            mp.set_property_number("playlist-pos", item - 1)
            return
        end
    end

    -- Click the album-art thumb (left of the marquee) to pause/play the MUSIC —
    -- exactly the same toggle, just aimed at whichever player owns the marquee:
    -- the slideshow's music normally, or the briefing's bgm during a briefing.
    if mouse and thumb then
        local dx = mouse.x - thumb.cx
        local dy = mouse.y - thumb.cy
        if dx * dx + dy * dy <= thumb.r * thumb.r then
            local brief = briefing_active and briefing_active()
            -- Quiet hours: the slideshow music can't be (re)started from the thumb.
            if not brief and is_sleep_time and is_sleep_time() then return end
            local sock = brief and BGM_SOCK or AUDIO_SOCK
            mp.commandv("run", "/bin/sh", "-c",
                "printf '%s\\n' '{\"command\":[\"cycle\",\"pause\"]}' | socat - UNIX-CONNECT:" .. sock .. " 2>/dev/null")
            return
        end
    end

    -- Song chooser (open below the bar): click a row to jump to that track, click
    -- the scrollbar to jump there, or use the mouse wheel (handled separately).
    if mouse and MQ.chooser then
        if MQ.sbar and mouse.x >= MQ.sbar.x0 and mouse.x <= MQ.sbar.x1
           and mouse.y >= MQ.sbar.y0 and mouse.y <= MQ.sbar.y1 then
            local frac = (mouse.y - MQ.sbar.y0) / math.max(1, MQ.sbar.y1 - MQ.sbar.y0)
            MQ.scroll = math.floor(frac * MQ.maxscroll + 0.5); draw_chooser(); return
        end
        local r = chooser_hit and chooser_hit(mouse.x, mouse.y)
        if r and r.idx ~= nil then
            mp.commandv("run", "/bin/sh", "-c",
                "printf '%s\\n' '{\"command\":[\"set_property\",\"playlist-pos\"," .. r.idx
                .. "]}' | socat - UNIX-CONNECT:" .. AUDIO_SOCK .. " 2>/dev/null")
            MQ.chooser = false; music_menu_ov:remove()
            if poll_music then mp.add_timeout(0.35, poll_music) end
            return
        end
        -- A click inside the panel (just not on a row) is ignored; a click outside
        -- it — and not on the marquee toggle below — closes it.
        local in_panel = MQ.bounds and mouse.x >= MQ.bounds.x0 and mouse.x <= MQ.bounds.x1
            and mouse.y >= MQ.bounds.y0 and mouse.y <= MQ.bounds.y1
        local on_marquee = music_hit and mouse.x >= music_hit.x0 and mouse.x <= music_hit.x1
            and mouse.y >= music_hit.y0 and mouse.y <= music_hit.y1
        if in_panel then return end
        if not on_marquee then MQ.chooser = false; music_menu_ov:remove(); return end
    end

    -- Click the now-playing marquee (top-left) to open/close the song chooser.
    if mouse and music_hit and not (briefing_active and briefing_active()) then
        if mouse.x >= music_hit.x0 and mouse.x <= music_hit.x1
           and mouse.y >= music_hit.y0 and mouse.y <= music_hit.y1 then
            if MQ.chooser then MQ.chooser = false; music_menu_ov:remove()
            else open_chooser() end
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
local lm_gen  = 0
local lm_anim = nil   -- the in-flight reveal: {glyphs,start_t,t0,header,total,gen,W,H,fade}

-- Render the reveal at the current wall-clock time. Idempotent, so it can be
-- driven from several sources. Over VIDEO, mp.add_timeout callbacks get starved
-- by decode, so the reveal is also ticked from the percent-pos observer (which
-- fires every video frame — the same thing that keeps the bottom bar moving).
-- Over stills the timer drives it (percent-pos doesn't advance for an image).
local function lm_render()
    local a = lm_anim
    -- The city headline shares the bottom-center with the captions, so hide it
    -- during a briefing — EXCEPT the "GROK <time of day>" title (mode "title"),
    -- which is meant to play right as the briefing goes live.
    if briefing_active and briefing_active() and not (a and a.mode == "title") then
        landmark_ov:remove(); lm_anim = nil; return
    end
    if not a or a.gen ~= lm_gen then return end

    if a.mode == "title" then        -- "GROK <time of day>", built exactly like a
        -- month card: per-letter reveal (to pure white), brief hold, then a global
        -- fade-out. No outline/shadow/glow, no zoom — just the build-up + fade.
        local el = mp.get_time() - a.t0
        local total = a.build + a.hold + a.fout
        if el >= total then landmark_ov:remove(); lm_anim = nil; return end
        local gout = 0
        if el > a.build + a.hold then gout = (el - a.build - a.hold) / a.fout end  -- 0..1
        local parts = { a.header }
        for i = 1, #a.glyphs do
            local st, fd = a.start_t[i], a.fade_t[i]
            local ain                                  -- per-letter build-up: FF -> 00
            if el <= st then ain = 0xFF
            elseif el >= st + fd then ain = 0x00
            else ain = math.floor(0xFF * (1 - (el - st) / fd) + 0.5) end
            local alpha = math.floor(ain + (0xFF - ain) * gout + 0.5)   -- + global fade-out
            parts[#parts + 1] = string.format("{\\alpha&H%02X&}%s", alpha, a.glyphs[i])
        end
        landmark_ov.res_x = a.W; landmark_ov.res_y = a.H
        landmark_ov.data = table.concat(parts)
        landmark_ov:update()
        return
    end

    local el = mp.get_time() - a.t0
    local parts = { a.header }
    -- Optional first line (the landmark, smaller) above the main line (the city),
    -- with a \N break between them. Per-letter reveal across both.
    parts[#parts + 1] = (a.lm_n > 0)
        and string.format("{\\fs%d\\fsp%d}", a.lm_fs, a.lm_fsp)
        or  string.format("{\\fs%d\\fsp%d}", a.fs, a.fsp)
    for i = 1, #a.glyphs do
        if a.lm_n > 0 and i == a.lm_n + 1 then
            parts[#parts + 1] = string.format("\\N{\\fs%d\\fsp%d}", a.fs, a.fsp)
        end
        local st, alpha = a.start_t[i], nil
        if el <= st then alpha = 0xFF
        elseif el >= st + a.fade then alpha = LM_FINAL_ALPHA
        else alpha = math.floor(0xFF + (LM_FINAL_ALPHA - 0xFF) * ((el - st) / a.fade) + 0.5) end
        parts[#parts + 1] = string.format("{\\alpha&H%02X&}%s", alpha, a.glyphs[i])
    end
    landmark_ov.res_x = a.W; landmark_ov.res_y = a.H
    landmark_ov.data = table.concat(parts)
    landmark_ov:update()
    if el >= a.total then lm_anim = nil end   -- finished (final state just drawn)
end

local function animate_landmark(text, cx, by, fs, fsp, win_w, win_h, top)
    lm_gen = lm_gen + 1
    local gen = lm_gen
    -- Optional landmark line (smaller) revealed above the city line.
    local lm_glyphs = (top and top ~= "") and utf8_split(top) or {}
    local glyphs = {}
    for _, g in ipairs(lm_glyphs) do glyphs[#glyphs + 1] = g end
    for _, g in ipairs(utf8_split(text)) do glyphs[#glyphs + 1] = g end
    local lm_fs  = math.floor(fs * 0.6)
    local lm_fsp = math.floor(lm_fs * 0.3636 + 0.5)
    -- Header carries everything except \fs/\fsp (set per line in lm_render).
    local header = string.format(
        "{\\an2\\pos(%d,%d)\\fnMontserrat ExtraBold\\1c&HFFFFFF&%s}", cx, by, glow(fs))
    local FADE, last = 0.55, 0
    local start_t = {}
    for i = 1, #glyphs do
        local st = math.random() * 0.9          -- spread reveals over 0..0.9s
        start_t[i] = st
        if st > last then last = st end
    end
    lm_anim = { glyphs = glyphs, start_t = start_t, t0 = mp.get_time(), header = header,
                total = last + FADE, gen = gen, W = win_w, H = win_h, fade = FADE,
                lm_n = #lm_glyphs, fs = fs, fsp = fsp, lm_fs = lm_fs, lm_fsp = lm_fsp }
    lm_render()
    local function tick()
        if not lm_anim or lm_anim.gen ~= gen then return end
        lm_render()
        if lm_anim then mp.add_timeout(0.033, tick) end
    end
    mp.add_timeout(0.033, tick)
end

-- One-shot center title ("GROK MORNING/…") built exactly like a month card:
-- Montserrat ExtraBold, same size/letter-spacing, per-letter reveal to PURE WHITE
-- (no outline/shadow/glow, no zoom), brief hold, then fade out. Reuses the
-- landmark animator (lm_anim/lm_render) so it costs no extra state.
local function animate_gtitle(text, w, h)
    lm_gen = lm_gen + 1
    local gen = lm_gen
    local glyphs = utf8_split(text)
    local fs  = math.floor(h * 0.111)   -- month-card size (120 @ 1080)
    local fsp = math.floor(h * 0.046)   -- month-card letter-spacing (50 @ 1080)
    local header = string.format(
        "{\\an5\\pos(%d,%d)\\fnMontserrat ExtraBold\\fs%d\\fsp%d\\1c&HFFFFFF&\\bord0\\shad0}",
        math.floor(w / 2), math.floor(h / 2), fs, fsp)
    local start_t, fade_t, last = {}, {}, 0
    for i = 1, #glyphs do
        local st = 0.1 + math.random() * 1.4    -- reveal starts 0.1–1.5s in
        local fd = 0.5 + math.random() * 0.3    -- over 0.5–0.8s (as the month card)
        start_t[i] = st; fade_t[i] = fd
        if st + fd > last then last = st + fd end
    end
    lm_anim = { mode = "title", glyphs = glyphs, start_t = start_t, fade_t = fade_t,
                header = header, t0 = mp.get_time(), gen = gen, W = w, H = h,
                build = last, hold = 0.5, fout = 0.8 }
    lm_render()
    local function tick()
        if not lm_anim or lm_anim.gen ~= gen then return end
        lm_render()
        if lm_anim then mp.add_timeout(0.033, tick) end
    end
    mp.add_timeout(0.033, tick)
end

-- Per-video-frame tick for the reveal (fires while a video plays; no-op otherwise).
mp.observe_property("percent-pos", "number", function() lm_render() end)

mp.register_event("file-loaded", function()
    local path = mp.get_property("path")
    if not path then return end

    -- First real (non-loading) file: the playlist handoff is done — let input
    -- through again and drop the "please wait" overlay.
    if ss_input_locked and not path:find("lavfi", 1, true) then
        unlock_loading_input()
    end

    -- During a briefing the screensaver is a calm, light backdrop: skip videos &
    -- title cards, and show photos blurred + stretched (no geo/HUD work). This is
    -- BEFORE the HUD/landmark clears below so it never cancels the GROK title.
    if briefing_active and briefing_active() and not path:find("lavfi", 1, true) then
        local ext = (path:match("%.([^%.]+)$") or ""):lower()
        if is_video[ext] or path:find("/Optimized_Vids/", 1, true) or path:find("/TitleCards/", 1, true) then
            mp.add_timeout(0.1, function() mp.command("playlist-next") end)
        else
            apply_image_blur_vf(path)
        end
        return
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
            -- A briefing hides every HUD except the music block.
            if briefing_active and briefing_active() then
                ov:remove(); landmark_ov:remove(); main_shown = nil; lm_gen = lm_gen + 1
                return
            end
            local L = hud_geom()
            local m_top    = math.floor(L.win_h * 0.055)  -- top inset (a bit lower)
            local m_right  = math.floor(L.win_h * 0.02)    -- right inset (matches the map's)
            local m_bottom = math.floor(L.win_h * 0.10)    -- bottom inset (lifted higher)

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

            -- Bottom-center headline: the CITY name. The 'l' key cycles through the
            -- candidate LANDMARKS — the chosen one shows on a smaller line ABOVE the
            -- city. The glyph reveal plays only when the headline actually changes.
            local city  = clean_text(m.city or ""):upper()
            local cands = split_landmarks(m.landmark)
            local idx   = LP[cur.orig]
            local top   = (idx and cands[idx]) and cands[idx]:upper() or nil
            local fs   = math.floor(L.win_h * HUD_CITY_FS)   -- bigger headline
            local fsp  = math.floor(fs * 0.3636 + 0.5)       -- spacing scales with size
            local cx   = math.floor(L.win_w / 2)
            local by   = L.win_h - m_bottom
            -- Stash what the 'l' cycle needs to redraw this headline.
            cur.city = m.city or ""; cur.landmarks = cands
            cur.head = { cx = cx, by = by, fs = fs, fsp = fsp, ww = L.win_w, wh = L.win_h }
            local key = city .. "|" .. (top or "")
            if city == "" and not top then
                main_shown = nil
                lm_gen = lm_gen + 1
                landmark_ov:remove()
            elseif key ~= main_shown then
                main_shown = key
                animate_landmark(city, cx, by, fs, fsp, L.win_w, L.win_h, top)
            else
                lm_gen = lm_gen + 1   -- cancel any stray animation; show statically
                landmark_ov.res_x = L.win_w
                landmark_ov.res_y = L.win_h
                local s = string.format(
                    "{\\an2\\pos(%d,%d)\\fnMontserrat ExtraBold\\1c&HFFFFFF&%s\\alpha&H40&}", cx, by, glow(fs))
                if top then
                    local lf = math.floor(fs * 0.6)
                    s = s .. string.format("{\\fs%d\\fsp%d}%s\\N", lf, math.floor(lf * 0.3636 + 0.5), top)
                end
                landmark_ov.data = s .. string.format("{\\fs%d\\fsp%d}%s", fs, fsp, city)
                landmark_ov:update()
            end
        end
        draw_text()

        if not (m.lat and m.lon) then
            mp.add_timeout(1.0, start_prewarm)
            return
        end

        local z = ZOOMS[cur.zidx]
        local color = ring_color(cur.zidx)

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

            -- Auto zoom-in for VIDEOS rides the percent-pos observer below
            -- (a still image renders one frame, so percent-pos never moves).
            -- For PHOTOS, spread the steps across the display duration with
            -- timers — safe here, since timers only starve under video decode.
            if mp.get_property_native("current-tracks/video/image") then
                -- NB: "duration" is 0 for stills — the display time lives in
                -- the image-display-duration property (set by launch.sh).
                local dur = mp.get_property_number("image-display-duration")
                if not dur or dur <= 0 or dur > 86400 then dur = cfgnum("PHOTO_DURATION") end
                local n = #ZOOMS
                if dur > 0 and n > 1 then
                    for k = 1, n - 1 do
                        mp.add_timeout(dur * k / n, function()
                            if my_seq ~= seq then return end
                            auto_zoom_step(k + 1)
                        end)
                    end
                end
            end
        end)
    end)
end)

-- Cinematic auto zoom-in, paced by the media itself: the item's play time is
-- split evenly across the zoom levels, so each level gets a fair share —
-- 1/n of PHOTO_DURATION on a photo, 1/n of the clip's length on a video.
-- Videos are driven by percent-pos (not timers, which starve during decode);
-- photos by the timer chain above, both stepping through auto_zoom_step. It
-- only ever steps inward, and any manual ↑/↓ sets cur.auto=false and stops
-- it for the rest of the item. Global functions: chunk is at the local cap.
function auto_zoom_step(target)
    if (cfgstr("HUD_AUTO_ZOOM") or "yes"):lower() == "no" then return end
    if not cur.auto then return end
    if not (cur.lat and cur.lon and cur.mdir) then return end
    if target > #ZOOMS then target = #ZOOMS end
    if target > cur.zidx then
        cur.zidx = target
        show_current_zoom()
    end
end
function auto_zoom_tick(pct)
    if not pct then return end
    local n = #ZOOMS
    if n <= 1 then return end
    auto_zoom_step(math.floor(pct / 100 * n) + 1)
end
mp.observe_property("percent-pos", "number", function(_, pct) auto_zoom_tick(pct) end)

-- Now-playing marquee (top-left). Montserrat ExtraBold, white. It never scrolls:
-- a title too long for its window is shown static and simply FADES OUT toward the
-- right edge where it's cut off (per-glyph alpha ramp). Hovering the marquee
-- reveals the whole title+artist; clicking it opens a song chooser below the bar.
-- The window width (MUSIC_WIN_FRAC) is a fraction of the screen width.
local function music_style(fs, fsp)
    return string.format("\\fnMontserrat ExtraBold\\fs%d\\fsp%d\\1c&HFFFFFF&%s\\alpha&H40&",
        fs, fsp, glow(fs))
end

-- Redraw the marquee for the current hover state (full when hovered, otherwise
-- faded at the cut-off). Uses the layout stashed by set_music.
function render_marquee()
    local L = MQ.layout
    if not L then music_ov:remove(); return end
    music_ov.res_x = L.w; music_ov.res_y = L.h
    if MQ.hover or L.text_px <= L.win_px then
        -- Reveal everything (no fade, no clip).
        music_ov.data = string.format("{\\an7\\pos(%d,%d)%s}%s", L.px, L.py, L.style, L.label)
    else
        -- Fade the glyphs that fall in the last stretch before the cut-off; make
        -- anything past the window edge fully transparent (so it reads as cut off).
        local fade  = math.max(L.fs * 1.5, L.win_px * 0.18)
        local edge  = L.px + L.win_px           -- right cut-off (transparent past here)
        local start = edge - fade               -- fade begins here
        local avg   = L.text_px / math.max(1, #L.glyphs)
        local parts = { string.format("{\\an7\\pos(%d,%d)%s}", L.px, L.py, L.style) }
        for i, g in ipairs(L.glyphs) do
            local gx = L.px + (i - 0.5) * avg    -- glyph centre (uniform estimate)
            local a
            if gx <= start then a = 0x40
            elseif gx >= edge then a = 0xFF
            else a = math.floor(0x40 + (0xFF - 0x40) * ((gx - start) / fade) + 0.5) end
            parts[#parts + 1] = string.format("{\\alpha&H%02X&}%s", a, g)
        end
        music_ov.data = table.concat(parts)
    end
    music_ov:update()
end

local function set_music(text)
    if not text or text == "" then return end
    text = text:sub(1, 160)                     -- caller already cleaned it
    if text == "" then return end
    if text == music_shown then return end
    music_shown = text
    music_pct   = 0                            -- new track → bar restarts empty
    MQ.chooser = false; music_menu_ov:remove()   -- close the chooser on track change

    local w, h = refresh_display_size()
    local fs   = math.floor(h * HUD_MUSIC_FS)
    local fsp  = math.floor(h * 0.003 + 0.5)
    local py   = math.floor(h * 0.055)   -- a bit lower
    local y_top  = py - math.floor(fs * 0.25)
    local y_bot  = py + math.floor(fs * 1.30)
    local bar_th = math.max(1, math.floor(h * 0.00117 + 0.5))   -- thin (≈1/3 of old)
    local bar_y  = py + math.floor(fs * 1.45)    -- just under the text

    -- Album-art thumb sits at the left margin; the text starts to its right. The
    -- diameter is 1.8× the text+bar group height, centred vertically on it.
    local left_x  = math.floor(h * 0.02)
    local grp_top = y_top
    local grp_bot = bar_y + bar_th
    local thumb_d = math.floor((grp_bot - grp_top) * 1.8)
    local px      = left_x
    if SHOW_THUMB and thumb_d > 0 then
        local block_cy = math.floor((grp_top + grp_bot) / 2)
        thumb = { x = left_x, y = block_cy - math.floor(thumb_d / 2), d = thumb_d,
                  cx = left_x + math.floor(thumb_d / 2), cy = block_cy,
                  r = math.floor(thumb_d / 2), W = w, H = h }
        px = left_x + thumb_d + math.floor(thumb_d * 0.22)   -- gap after the thumb
        draw_thumb_ring()
    else
        thumb = nil; music_thumb_ov:remove()
        mp.command_native({"overlay-remove", THUMB_ID})
    end
    local win_px = math.floor(w * MUSIC_WIN_FRAC)
    local style  = music_style(fs, fsp)

    -- Measure the real rendered width (hidden compute-bounds overlay).
    local text_px
    music_measure_ov.res_x = w; music_measure_ov.res_y = h
    music_measure_ov.hidden = true
    music_measure_ov.compute_bounds = true
    music_measure_ov.data = string.format("{\\an7\\pos(0,0)%s}%s", style, text)
    local mb = music_measure_ov:update()
    music_measure_ov:remove()
    if mb and mb.x0 and mb.x1 and mb.x1 > mb.x0 then
        text_px = math.ceil(mb.x1 - mb.x0)
    else
        text_px = math.floor((fs * 0.60 + fsp) * #utf8_split(text))
    end

    local vis_w = math.min(text_px, win_px)      -- width the bar hugs (visible window)
    MQ.layout = { label = text, glyphs = utf8_split(text), px = px, py = py,
                     style = style, win_px = win_px, text_px = text_px,
                     fs = fs, w = w, h = h }
    -- Hit/hover box spans the FULL title so hovering the revealed text is stable.
    music_hit = { x0 = px - fs, y0 = y_top, x1 = px + text_px + fs, y1 = y_bot }
    music_bar = { x = px, y = bar_y, w = vis_w, th = bar_th, W = w, H = h }
    render_marquee()
    draw_music_bar()
end

-- Music progress bar drawn under the marquee, the same width as the info text.
-- Driven by the audio player's percent-pos (polled below). Same translucent
-- look as the bottom video bar.
function draw_music_bar()
    -- A briefing's looping bgm has no position feed, so hide the bar then (the
    -- marquee still shows the bgm's title/artist).
    if briefing_active and briefing_active() then
        music_bar_ov:remove(); music_bar_bg_ov:remove(); return
    end
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

-- ----------------------------------------------------------------------------
-- Song chooser — a short list of tracks shown below the progress bar when the
-- marquee is clicked. Click a row to jump to that track on the audio player.
-- ----------------------------------------------------------------------------
local CHOOSER_MAX = 8           -- (const; not a separate state local)

local function entry_name(e)
    local s = e.title
    if not s or s == "" then
        s = (e.filename or ""):gsub("^.*/", ""):gsub("%.[^%.]+$", "")
    end
    return clean_text(s)
end

function draw_chooser()
    MQ.rows = {}; MQ.bounds = nil; MQ.sbar = nil
    local entries = MQ.entries
    if not MQ.chooser or not music_bar or not entries or #entries == 0 then
        music_menu_ov:remove(); return
    end
    local b = music_bar
    local w, h = b.W, b.H
    local fs   = math.floor(h * HUD_MUSIC_FS)        -- same size + font as the marquee
    local fsp  = math.floor(h * 0.003 + 0.5)
    local rowh = math.floor(fs * 1.7)
    local gapy = math.max(1, math.floor(rowh * 0.10))
    local pad  = math.floor(fs * 0.2)
    local boxw = math.max(b.w, math.floor(w * 0.26))
    local x0   = b.x

    -- Clamp the scroll window. MQ.scroll = index of the first visible row (0-based).
    local n = #entries
    local maxscroll = math.max(0, n - CHOOSER_MAX)
    MQ.maxscroll = maxscroll
    if MQ.scroll < 0 then MQ.scroll = 0 elseif MQ.scroll > maxscroll then MQ.scroll = maxscroll end
    local first = MQ.scroll + 1
    local last  = math.min(n, first + CHOOSER_MAX - 1)
    local count = last - first + 1
    local has_above, has_below = MQ.scroll > 0, last < n
    local FADE = 1.8                                  -- rows over which the edge fades

    local top_y = b.y + b.th + math.floor(rowh * 0.5)
    local y, parts = top_y, {}
    local mstyle = music_style(fs, fsp)               -- Montserrat ExtraBold + glow
    for i = first, last do
        local e = entries[i]
        local p = i - first                           -- 0 = top visible row
        local ry0 = y
        -- Edge fade: dim the rows nearest a scrollable edge (so it reads as "more").
        local vis = 1
        if has_above then vis = math.min(vis, math.max(0.10, (p + 0.5) / FADE)) end
        if has_below then vis = math.min(vis, math.max(0.10, (count - 1 - p + 0.5) / FADE)) end
        local alpha = math.floor(0x40 + (0xFF - 0x40) * (1 - vis) + 0.5)
        local tc = e.current and "&H50C0FF&" or "&HFFFFFF&"   -- current track in gold
        parts[#parts + 1] = string.format(
            "{\\an4\\pos(%d,%d)%s\\1c%s\\alpha&H%02X&\\clip(%d,%d,%d,%d)}%s",
            x0 + pad, ry0 + math.floor(rowh / 2), mstyle, tc, alpha,
            x0, ry0, x0 + boxw, ry0 + rowh, entry_name(e))
        MQ.rows[#MQ.rows + 1] = { x0 = x0, y0 = ry0, x1 = x0 + boxw, y1 = ry0 + rowh, idx = i - 1 }
        y = ry0 + rowh + gapy
    end
    local bottom_y = y - gapy

    -- A thin vertical scrollbar on the right (YouTube-style): faint track + a
    -- brighter thumb sized/positioned to the visible window. Click it to jump.
    local right = x0 + boxw
    if n > CHOOSER_MAX then
        local sbw = math.max(2, math.floor(fs * 0.16))
        local sbx = right + math.floor(fs * 0.5)
        local th  = bottom_y - top_y
        local thumb_h = math.max(math.floor(rowh * 0.8), math.floor(th * count / n))
        local thumb_y = top_y + math.floor((th - thumb_h) * MQ.scroll / maxscroll)
        parts[#parts + 1] = "{\\an7\\pos(0,0)\\bord0\\shad0\\1c&HFFFFFF&\\alpha&HCC&\\p1}"
            .. rrect_path(sbx, top_y, sbw, th, math.floor(sbw / 2)) .. "{\\p0}"
        parts[#parts + 1] = "{\\an7\\pos(0,0)\\bord0\\shad0\\1c&HFFFFFF&\\alpha&H30&\\p1}"
            .. rrect_path(sbx, thumb_y, sbw, thumb_h, math.floor(sbw / 2)) .. "{\\p0}"
        MQ.sbar = { x0 = sbx - sbw, y0 = top_y, x1 = sbx + sbw * 2, y1 = bottom_y }
        right = sbx + sbw
    end

    MQ.bounds = { x0 = x0, y0 = b.y + b.th, x1 = right, y1 = bottom_y }
    music_menu_ov.res_x = w; music_menu_ov.res_y = h
    music_menu_ov.data = table.concat(parts, "\n")
    music_menu_ov:update()
end

function chooser_hit(mx, my)
    for _, r in ipairs(MQ.rows) do
        if mx >= r.x0 and mx <= r.x1 and my >= r.y0 and my <= r.y1 then return r end
    end
end

-- Query the audio player's playlist, then show the chooser scrolled to the
-- current track.
function open_chooser()
    if not music_bar or (briefing_active and briefing_active()) then return end
    mp.command_native_async({ name = "subprocess", capture_stdout = true,
        args = { "/bin/sh", "-c",
            "printf '%s\\n' '{\"command\":[\"get_property\",\"playlist\"]}' "
            .. "| socat -t1 - UNIX-CONNECT:" .. AUDIO_SOCK .. " 2>/dev/null" } },
        function(ok, res)
            local entries = {}
            if ok and res and res.stdout then
                local j = utils.parse_json(res.stdout)
                if j and j.error == "success" and type(j.data) == "table" then entries = j.data end
            end
            local cur = 1
            for i, e in ipairs(entries) do if e.current then cur = i; break end end
            MQ.entries = entries
            MQ.scroll  = math.max(0, cur - 1 - math.floor(CHOOSER_MAX / 2))
            MQ.chooser = true
            draw_chooser()
        end)
end

-- Mouse wheel: scroll the open song chooser; otherwise step the slideshow (only
-- between photos during a briefing, so it never reaches a video).
mp.register_script_message("ss-wheel", function(dir)
    if bo_wake() then return end
    if MQ.chooser then
        MQ.scroll = MQ.scroll + (dir == "up" and -2 or 2)
        draw_chooser()
    else
        local d = (dir == "up") and -1 or 1
        if backdrop_step and backdrop_step(d) then return end
        mp.command(d < 0 and "playlist-prev" or "playlist-next")
    end
end)

-- Slideshow prev/next (arrow keys). Photo-only during a briefing.
mp.register_script_message("ss-nav", function(dir)
    if bo_wake() then return end
    local d = (dir == "next") and 1 or -1
    if backdrop_step and backdrop_step(d) then return end
    mp.command(d > 0 and "playlist-next" or "playlist-prev")
end)

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
        math.max(1, math.floor(t.d * 0.018 + 0.5)), ass_circle(t.cx, t.cy, t.r))
    music_thumb_ov:update()
end

-- Blit the album art: colour while the music plays, grayscale while paused (so
-- you can tell at a glance it's stopped). Only re-blits when the variant changes.
local function draw_thumb()
    if not thumb then TH.shown = nil; return end
    local want = music_playing and TH.color or TH.gray
    if not want then return end          -- no cover art yet → just the empty ASS ring
    -- SIGBUS guard: overlay-add mmaps the file at the size WE claim, and mpv
    -- crashes (bus error) reading past EOF if the file is smaller. Never blit
    -- art rendered for a different diameter (window resized since the build) —
    -- re-render at the current size instead.
    if TH.d ~= thumb.d then
        TH.shown = nil
        if TH.path and not TH.busy then load_thumb_for(TH.path) end
        return
    end
    if want == TH.shown then return end
    local fi = utils.file_info(want)
    if not (fi and fi.size and fi.size >= thumb.d * thumb.d * 4) then return end
    TH.shown = want
    music_thumb_ov:remove()              -- the bitmap has its own baked ring on top
    mp.command_native({"overlay-add", THUMB_ID, thumb.x, thumb.y,
        want, 0, "bgra", thumb.d, thumb.d, thumb.d * 4})
end

-- Generate (or reuse cached) the cover-art thumbnails for the current track,
-- then show one. build-thumb.sh prints its output dir, or nothing when the file
-- has no embedded art (then the thumb stays an empty ring).
function load_thumb_for(path)
    if not thumb or path == nil or path == "" then return end
    local d = thumb.d
    TH.busy = true
    mp.command_native_async({
        name = "subprocess", capture_stdout = true, playback_only = false,
        args = { CFG_DIR .. "/build-thumb.sh", path, tostring(d) },
    }, function(ok, res)
        TH.busy = false
        if TH.path ~= path or not thumb then return end   -- track moved on
        local dir = (ok and res and res.stdout or ""):gsub("%s+$", "")
        if dir ~= "" and file_exists(dir .. "/color.bgra") then   -- non-empty art file
            TH.color = dir .. "/color.bgra"
            TH.gray  = dir .. "/gray.bgra"
            TH.d     = d         -- the diameter this art was actually rendered at
            TH.shown = nil
            draw_thumb()
        else
            TH.color = nil; TH.gray = nil; TH.shown = nil; TH.d = nil
            mp.command_native({"overlay-remove", THUMB_ID})
        end
    end)
end

-- New audio file → reset the thumb and (re)generate its art.
local function on_music_path(p)
    if p == TH.path then return end
    TH.path = p
    TH.color = nil; TH.gray = nil; TH.shown = nil; TH.d = nil
    mp.command_native({"overlay-remove", THUMB_ID})
    draw_thumb_ring()        -- empty ring while the new art is generated
    load_thumb_for(p)
    -- The metadata poll runs on a 3s timer that video decode starves, so the song
    -- name lags on track changes during video. The path poll IS decode-proof (it's
    -- driven by percent-pos), so refresh the marquee text here too.
    if poll_music then poll_music() end
end

-- Poll the audio player (separate mpv on AUDIO_SOCK): position for the bar, file
-- path for the thumb, and pause state for the spin. One round-trip for all three.
-- Throttled to ~1 Hz with an in-flight guard, and driven from BOTH a periodic
-- timer and the percent-pos observer: on a heavy (e.g. 4K) machine, video decode
-- starves the periodic timer, so the observer — which fires every presented
-- frame, the same signal that keeps the bottom bar alive — keeps the poll going.
local function poll_music_pos()
    if not music_shown then return end
    if BO and BO.on then return end   -- blacked out: nothing visible to update
    local now = mp.get_time()
    if MQ.poll_busy or (now - MQ.poll_t) < 0.8 then return end
    MQ.poll_t = now
    -- During a briefing the marquee/thumb track the bgm's own mpv: reflect ITS
    -- pause state (so the thumb greys out when you pause it), and hide the bar
    -- (a looping bgm has no meaningful position).
    if briefing_active and briefing_active() then
        mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false,
            args = { "/bin/sh", "-c",
                "printf '%s\\n' '{\"command\":[\"get_property\",\"pause\"]}' "
                .. "| socat -t1 - UNIX-CONNECT:" .. BGM_SOCK .. " 2>/dev/null" } },
            function(ok, res)
                if ok and res and res.stdout then
                    local j = utils.parse_json(res.stdout)
                    if j and j.error == "success" then music_playing = (j.data ~= true) end
                end
                draw_thumb()
            end)
        draw_music_bar(); return
    end
    MQ.poll_busy = true
    mp.command_native_async({
        name = "subprocess", capture_stdout = true, playback_only = false,
        args = { "/bin/sh", "-c",
            "printf '%s\\n%s\\n%s\\n' "
            .. "'{\"command\":[\"get_property\",\"percent-pos\"],\"request_id\":1}' "
            .. "'{\"command\":[\"get_property\",\"path\"],\"request_id\":2}' "
            .. "'{\"command\":[\"get_property\",\"pause\"],\"request_id\":3}' "
            .. "| socat -t1 - UNIX-CONNECT:" .. AUDIO_SOCK .. " 2>/dev/null" },
    }, function(ok, res)
        MQ.poll_busy = false
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
        draw_thumb()      -- swap colour/grayscale if the play/pause state changed
        draw_music_bar()
    end)
end
mp.add_periodic_timer(1, poll_music_pos)                       -- stills / idle
mp.observe_property("percent-pos", "number", poll_music_pos)  -- videos (decode-proof)

-- Poll the audio player; only rebuild the marquee when the track changes.
function poll_music()
    if BO and BO.on then return end   -- blacked out: nothing visible to update
    -- During a briefing the slideshow's own music is paused; show the GrokMorning
    -- background track instead (grok-briefing.sh publishes its title/path to /tmp).
    if briefing_active and briefing_active() then
        local f = io.open("/tmp/ss_briefing_bgm.txt", "r")
        local t = f and (f:read("*a") or "") or ""
        if f then f:close() end
        t = t:gsub("%s+$", "")
        if t ~= "" then
            local pf = io.open("/tmp/ss_briefing_bgm_path", "r")
            local p = pf and (pf:read("*l") or "") or ""
            if pf then pf:close() end
            music_playing = true
            if p ~= "" then on_music_path(p) end
            set_music(clean_text(t))
        end
        return
    end
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

-- Hover the marquee to reveal the full title+artist (re-render only on change).
mp.observe_property("mouse-pos", "native", function(_, m)
    local over = m and music_hit and m.x >= music_hit.x0 and m.x <= music_hit.x1
        and m.y >= music_hit.y0 and m.y <= music_hit.y1 or false
    if over ~= MQ.hover then MQ.hover = over; render_marquee() end
end)

-- ----------------------------------------------------------------------------
-- Quiet hours: pause the music during a configured sleep window (e.g. overnight)
-- and resume it after. MUSIC_SLEEP_START/END are 24h "HH:MM" (or a bare hour);
-- leave either empty to disable. Acts only on the sleep<->wake transition, so
-- manual play/pause still works the rest of the time.
-- ----------------------------------------------------------------------------
local function parse_hm(s)
    if not s or s == "" then return nil end
    local h, m = s:match("^(%d+):(%d+)")
    if h then return tonumber(h) * 60 + tonumber(m) end
    local hh = tonumber(s)
    return hh and math.floor(hh * 60) or nil
end

function is_sleep_time()      -- global: the click handler (defined earlier) uses it
    local a = parse_hm(cfgstr("MUSIC_SLEEP_START"))
    local b = parse_hm(cfgstr("MUSIC_SLEEP_END"))
    if not a or not b or a == b then return false end     -- disabled
    local t   = os.date("*t")
    local now = t.hour * 60 + t.min
    if a < b then return now >= a and now < b              -- same-day window
    else        return now >= a or now < b end             -- crosses midnight
end

local function set_audio_pause(p)
    mp.commandv("run", "/bin/sh", "-c",
        "printf '%s\\n' '{\"command\":[\"set_property\",\"pause\"," .. (p and "true" or "false") ..
        "]}' | socat - UNIX-CONNECT:" .. AUDIO_SOCK .. " 2>/dev/null")
end

-- Quiet hours: pause the music AND mute the slideshow's own (video) volume, and
-- keep it that way (re-applied each check so it can't be nudged back on). Restore
-- the volume on the way out.
local music_asleep = nil
local SLEEP_VOL = nil
local function check_sleep()
    local s = is_sleep_time()
    if s then
        if not music_asleep then
            music_asleep = true
            local v = mp.get_property_number("volume")
            if v and v > 0 then SLEEP_VOL = v end       -- remember the real volume
        end
        set_audio_pause(true)
        mp.set_property_number("volume", 0)
    elseif music_asleep then
        music_asleep = false
        set_audio_pause(false)
        mp.set_property_number("volume", SLEEP_VOL or 70)
    end
end
mp.add_periodic_timer(15, check_sleep)
check_sleep()

-- ----------------------------------------------------------------------------
-- Quiet-hours blackout: during the sleep window only, after BLACKOUT_IDLE_MIN
-- minutes with no input (mouse move / key / click) paint the whole screen black
-- so it looks "off". Crucially we keep mpv rendering a black frame rather than
-- using DPMS / display-off, so the HDMI signal never drops and the TV doesn't
-- lose the source. Any activity, or a scheduled briefing, wakes it instantly.
-- ----------------------------------------------------------------------------
-- NOTE: photo.lua sits at Lua's 200-local-per-chunk cap, so everything here
-- lives in the global BO table and the helpers are GLOBAL functions — adding new
-- top-level `local`s overflows the cap and stops the whole script from loading.
BO = {
    ov     = mp.create_osd_overlay("ass-events"),
    on     = false,
    last   = mp.get_time(),
    enable = ((cfgstr("BLACKOUT_ENABLE") or "yes"):lower() ~= "no"),
    idle   = (function() local m = cfgnum("BLACKOUT_IDLE_MIN"); if m <= 0 then m = 15 end; return m * 60 end)(),
}
BO.ov.z = 2000        -- above every other overlay
function bo_show()
    if BO.on then return end
    BO.on = true
    BO.was_paused = mp.get_property_bool("pause")
    -- Gentle ~1.2s fade to black; decode pauses only once fully dark. A wake
    -- mid-fade cancels via the gen counter.
    BO.gen = (BO.gen or 0) + 1
    local g, t0 = BO.gen, mp.get_time()
    local function tick()
        if g ~= BO.gen or not BO.on then return end
        local f = math.min(1, (mp.get_time() - t0) / 1.2)
        local a = math.floor(0xFF * (1 - f) + 0.5)   -- FF transparent -> 00 opaque
        BO.ov.res_x = 1280; BO.ov.res_y = 720
        BO.ov.data = string.format(
            "{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H000000&\\1a&H%02X&\\p1}m 0 0 l 1280 0 1280 720 0 720{\\p0}", a)
        BO.ov:update()
        if f < 1 then
            mp.add_timeout(0.05, tick)
        else
            mp.set_property_bool("pause", true)      -- fully black: stop decoding
        end
    end
    tick()
end
function bo_hide()
    if not BO.on then return end
    BO.on = false
    BO.gen = (BO.gen or 0) + 1                       -- cancel an in-flight fade
    BO.ov:remove()
    if not BO.was_paused then mp.set_property_bool("pause", false) end
end
-- Reset the idle clock; if we were blacked out, wake and report it (so the input
-- that woke us is swallowed instead of also triggering its action, like a phone).
function bo_wake()
    BO.last = mp.get_time()
    if BO.on then bo_hide(); return true end
    return false
end
function bo_check()
    if not BO.enable then return end
    if (briefing_active and briefing_active()) or not is_sleep_time() then
        bo_hide(); return                         -- never black during a briefing / awake hours
    end
    if not BO.on and (mp.get_time() - BO.last) >= BO.idle then bo_show() end
end
mp.add_periodic_timer(5, bo_check)
-- Mouse movement is activity: reset the timer (and wake) whenever the pointer moves.
mp.observe_property("mouse-pos", "native", function(_, m)
    if not m then return end
    if m.x ~= BO.px or m.y ~= BO.py then BO.px, BO.py = m.x, m.y; bo_wake() end
end)

-- The loading screen, with a stylish fade-in on first appearance.
local LC = { gen = 0 }
function loading_render(frac)
    local w, h = LC.w, LC.h
    local fs   = math.floor(h * 0.066)
    local fsp  = math.floor(h * 0.024 + 0.5)
    local fs2  = math.floor(h * 0.040)
    local fsp2 = math.floor(h * 0.016 + 0.5)
    local ta = math.floor(0xFF + (0x00 - 0xFF) * frac + 0.5)   -- title    FF -> 00
    local sa = math.floor(0xFF + (0x80 - 0xFF) * frac + 0.5)   -- subtitle FF -> 80
    loading_ov.res_x = w; loading_ov.res_y = h
    loading_ov.data = string.format(
        "{\\an5\\pos(%d,%d)\\fnMontserrat ExtraBold\\fs%d\\fsp%d\\1c&HFFFFFF&%s\\alpha&H%02X&}%s"
        .. "\\N\\N{\\fnMontserrat SemiBold\\fs%d\\fsp%d\\alpha&H%02X&}%s",
        math.floor(w / 2), math.floor(h / 2) - math.floor(fs * 0.5),
        fs, fsp, glow(fs), ta, LC.title, fs2, fsp2, sa, LC.subtitle)
    loading_ov:update()
end
mp.register_script_message("ss-show-loading", function(title, subtitle)
    lock_loading_input()   -- defensive: stay non-interactive while loading
    title    = (title    and title    ~= "") and title    or "LOADING"
    subtitle = (subtitle and subtitle ~= "") and subtitle or "Please wait..."
    local new_title = (title ~= LC.title)
    LC.title, LC.subtitle = title, subtitle
    LC.w, LC.h = refresh_display_size()
    if new_title then                       -- first time / new heading → fade in
        LC.t0 = mp.get_time(); LC.gen = LC.gen + 1
        local gen = LC.gen
        local function tick()
            if gen ~= LC.gen then return end
            local frac = math.min(1, (mp.get_time() - LC.t0) / 0.6)
            loading_render(frac)
            if frac < 1 then mp.add_timeout(0.033, tick) end
        end
        tick()
    else
        loading_render(1)                   -- subtitle updates: no re-fade
    end
end)

mp.register_event("shutdown", function()
    ov:remove()
    pause_ov:remove()
    music_ov:remove()
    music_menu_ov:remove()
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
    briefing_ov:remove()
    logo_ov:remove()
    controls_ov:remove()
    logo_text_ov:remove()
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

mp.register_script_message("month-next", function() if bo_wake() then return end; if not briefing_active() then jump_month(1) end end)
mp.register_script_message("month-prev", function() if bo_wake() then return end; if not briefing_active() then jump_month(-1) end end)

-- Right-click the month bar → jump to that month's START; right-click anywhere
-- else still quits the screensaver.
mp.register_script_message("handle-right-click", function()
    if bo_wake() then return end
    local mouse = mp.get_property_native("mouse-pos")
    if mouse and gp_section_at and not (briefing_active and briefing_active()) then
        local hv = gp_section_at(mouse.x, mouse.y)
        if hv and gp_sections and gp_sections[hv] then
            mp.set_property_number("playlist-pos", gp_sections[hv].start - 1)
            return
        end
    end
    mp.command("quit")
end)

-- 'l' toggles whether THIS media shows its landmark (e.g. "Eiffel Tower") instead
-- of its city ("Paris") in the bottom-center headline; the choice is remembered.
mp.register_script_message("ss-toggle-landmark", function()
    if bo_wake() then return end
    if briefing_active and briefing_active() then return end
    local cands = cur.landmarks or {}
    if #cands == 0 then mp.osd_message("No landmarks for this one", 1.5); return end
    -- Cycle: city only → 1 → 2 → … → N → city only.
    local idx = (LP[cur.orig] or 0) + 1
    if idx > #cands then idx = 0 end
    LP[cur.orig] = (idx > 0) and idx or nil
    save_landmark_prefs()
    local city = clean_text(cur.city or ""):upper()
    local top  = (idx > 0) and cands[idx]:upper() or nil
    main_shown = nil; lm_gen = lm_gen + 1
    if cur.head and (city ~= "" or top) then
        main_shown = city .. "|" .. (top or "")
        animate_landmark(city, cur.head.cx, cur.head.by, cur.head.fs, cur.head.fsp,
                         cur.head.ww, cur.head.wh, top)
    else
        landmark_ov:remove()
    end
    mp.osd_message(top and ("Landmark: " .. cands[idx]) or "Landmark: off", 1.2)
end)

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

mp.register_script_message("year-next", function() if bo_wake() then return end; if not briefing_active() then jump_year(1) end end)
mp.register_script_message("year-prev", function() if bo_wake() then return end; if not briefing_active() then jump_year(-1) end end)

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
    if briefing_active and briefing_active() then top_bar_ov:remove(); top_bar_bg_ov:remove(); top_label_ov:remove(); return end
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
-- Morning briefing (xAI Grok) — subtitles + key controls.
--   grok-briefing.sh writes the current line to /tmp/ss_briefing.txt (or
--   "__HIDE__"); we render it centered near the bottom. Controls are sent here
--   from input.conf and forwarded to the briefing process by signal — all of
--   it is inert (no PID file) when no briefing is running.
-- ----------------------------------------------------------------------------
local BRIEF_TXT = "/tmp/ss_briefing.txt"
local briefing_subs_hidden = false
local briefing_paused = false
local briefing_shown = nil

-- Rounded-rectangle ASS path (absolute coords; pair with \an7\pos(0,0)\p1).
-- Shared by the subtitle boxes below and the logo/menu/controls further down.
function rrect_path(x0, y0, W, H, r)
    local x1, y1 = x0 + W, y0 + H
    return string.format(
        "m %d %d l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d "
        .. "l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d",
        x0 + r, y0,  x1 - r, y0,   x1, y0, x1, y0, x1, y0 + r,
        x1, y1 - r,  x1, y1, x1, y1, x1 - r, y1,
        x0 + r, y1,  x0, y1, x0, y1, x0, y1 - r,
        x0, y0 + r,  x0, y0, x0, y0, x0 + r, y0)
end

-- Split into sentences (keeps the terminal . ! ? with each), so the captions
-- can be laid out one sentence-block at a time — much easier to read.
local function split_sentences(s)
    s = s:gsub("([%.%!%?])%s+", "%1\1")
    local out = {}
    for part in (s .. "\1"):gmatch("(.-)\1") do
        part = part:gsub("^%s+", ""):gsub("%s+$", "")
        if part ~= "" then out[#out + 1] = part end
    end
    return out
end

local function wrap_words(s, maxc, into)
    local line = ""
    for word in s:gmatch("%S+") do
        if line ~= "" and #line + #word + 1 > maxc then
            into[#into + 1] = { text = line }; line = word
        else
            line = (line == "") and word or (line .. " " .. word)
        end
    end
    if line ~= "" then into[#into + 1] = { text = line } end
end

-- Caption "fancy appear": each line fades in (staggered), like the rest of the
-- stylish text. (Backdrop is photos-only during a briefing, so add_timeout isn't
-- starved by video decode.)
local BC = { lines = {}, w = 0, h = 0, t0 = 0, gen = 0 }
function briefing_fade()
    local gen = BC.gen
    local el  = mp.get_time() - BC.t0
    local parts = {}
    for i, L in ipairs(BC.lines) do
        local p = (el - (i - 1) * 0.06) / 0.35           -- 0.35s fade, 0.06s/line stagger
        local a = (p <= 0) and 0xFF or (p >= 1) and 0x12
            or math.floor(0xFF + (0x12 - 0xFF) * p + 0.5)
        parts[#parts + 1] = string.format(
            "{\\an5\\pos(%d,%d)\\fnMontserrat ExtraBold\\fs%d\\fsp%d\\1c&HFFFFFF&%s\\alpha&H%02X&}%s",
            L.cx, L.cy, L.fs, L.fsp, glow(L.fs), a, L.text)
    end
    briefing_ov.res_x = BC.w; briefing_ov.res_y = BC.h
    briefing_ov.data = table.concat(parts, "\n")
    briefing_ov:update()
    if el < (#BC.lines - 1) * 0.06 + 0.36 then
        mp.add_timeout(0.033, function() if gen == BC.gen then briefing_fade() end end)
    end
end

local function draw_briefing()
    local f = io.open(BRIEF_TXT, "r")
    local txt = f and (f:read("*a") or "") or ""
    if f then f:close() end
    txt = txt:gsub("%s+$", "")
    if txt == briefing_shown then return end          -- only redraw on change
    if txt ~= "" and txt ~= "__HIDE__" then briefing_paused = false end  -- new segment
    briefing_shown = txt
    if txt == "" or txt == "__HIDE__" or briefing_subs_hidden then
        BC.gen = BC.gen + 1   -- cancel any in-flight fade
        briefing_ov:remove(); return
    end

    local w, h = refresh_display_size()
    local sentences = split_sentences(txt:gsub("[\r\n]+", " "))
    -- Fill the screen below the badge/controls at the top.
    local regionTop = math.floor(h * 0.20)
    local regionH   = h - regionTop - math.floor(h * 0.04)
    local maxH, maxW = regionH, w * 0.88

    -- Captions are the main content while a briefing plays: no background (they
    -- sit on the blurred backdrop), centered, and auto-sized as BIG as will fit.
    local function layout(fs)
        local fsp  = math.floor(fs * 0.02 + 0.5)
        local maxc = math.max(10, math.floor(maxW / (fs * 0.52)))
        local lines = {}
        for si, sent in ipairs(sentences) do
            local mark = #lines + 1
            wrap_words(sent, maxc, lines)
            if si > 1 and lines[mark] then lines[mark].gap_before = true end
        end
        local lineH = math.floor(fs * 1.42)
        local sgap  = math.floor(fs * 0.55)
        local totalH = 0
        for _, L in ipairs(lines) do totalH = totalH + lineH + (L.gap_before and sgap or 0) end
        return lines, lineH, sgap, fsp, totalH
    end

    local fs = math.floor(h * 0.060)
    local lines, lineH, sgap, fsp, totalH
    for _ = 1, 9 do
        lines, lineH, sgap, fsp, totalH = layout(fs)
        if totalH <= maxH or fs <= math.floor(h * 0.020) then break end
        fs = math.floor(fs * 0.88)
    end
    if #lines == 0 then briefing_ov:remove(); return end

    -- Stash the positioned lines; briefing_fade animates them in.
    local y = regionTop + math.floor((regionH - totalH) / 2)   -- centered below the top
    BC.lines, BC.w, BC.h = {}, w, h
    for _, L in ipairs(lines) do
        if L.gap_before then y = y + sgap end
        BC.lines[#BC.lines + 1] = { text = L.text, cx = math.floor(w / 2),
                                    cy = y + math.floor(lineH / 2), fs = fs, fsp = fsp }
        y = y + lineH
    end
    BC.t0 = mp.get_time(); BC.gen = BC.gen + 1
    briefing_fade()
end
mp.add_periodic_timer(0.3, draw_briefing)

-- Forward a signal to the briefing process (skip / previous).
local function briefing_sig(sig)
    mp.commandv("run", "/bin/sh", "-c",
        'p=$(cat /tmp/ss_briefing.pid 2>/dev/null); [ -n "$p" ] && kill -' .. sig .. ' "$p" 2>/dev/null')
end
mp.register_script_message("ss-briefing-skip", function() briefing_sig("USR1") end)
mp.register_script_message("ss-briefing-prev", function() briefing_sig("USR2") end)
mp.register_script_message("ss-briefing-pause", function()   -- suspend/resume the ffplay process
    briefing_paused = not briefing_paused
    local s = briefing_paused and "STOP" or "CONT"
    mp.commandv("run", "/bin/sh", "-c",
        'p=$(cat /tmp/ss_briefing_ffplay.pid 2>/dev/null); [ -n "$p" ] && kill -' .. s .. ' "$p" 2>/dev/null')
end)
mp.register_script_message("ss-briefing-subs", function()
    briefing_subs_hidden = not briefing_subs_hidden
    briefing_shown = nil; draw_briefing()
end)
mp.register_script_message("ss-briefing-stop", function()  -- end the briefing now
    mp.commandv("run", "/bin/sh", "-c",
        'p=$(cat /tmp/ss_briefing.pid 2>/dev/null); [ -n "$p" ] && kill -TERM "$p" 2>/dev/null')
end)

-- ----------------------------------------------------------------------------
-- Morning-briefing badge (center-top), drawn as vector ASS (no image file).
--   * Idle: shows the live clock (sun + current time). Clicking it opens a
--     Replay / Refresh chooser (Replay = today's cached briefing, Refresh = new).
--   * While a briefing is speaking: the badge becomes the "MORNING BRIEFING"
--     logo with a transport row under it — previous / pause-play / next / stop —
--     the city headline hides, and the whole screensaver is muted (its own music
--     can't be resumed).
-- Only active when GROK_BRIEFING=1.
-- ----------------------------------------------------------------------------
local control_boxes    = {}     -- {x0,y0,x1,y1,act} transport buttons (while speaking)
local menu_boxes       = {}     -- {x0,y0,x1,y1,act} Replay/Refresh chooser
-- Briefing/badge state (one table to stay under Lua's 200-local cap).
local LB = { muted = false, vol = nil, spoke = false, hud_off = false, label = nil, near = false }

-- "Active" = actually playing (mute, hide-HUD, bgm marquee key off this). The
-- PID file exists earlier, during the "getting ready" phase, when the screensaver
-- must stay normal — so this keys off the LIVE marker, written once it starts.
-- Stat of the live-marker cached briefly: briefing_active() sits on per-frame
-- paths (percent-pos observers), so don't hit the filesystem every frame.
-- (Globals, not locals — the main chunk is at Lua's 200-local cap.)
BA_T, BA_V = -1, false
function briefing_active()
    local now = mp.get_time()
    if now - BA_T > 0.25 then
        BA_T = now; BA_V = file_exists("/tmp/ss_briefing_live")
    end
    return BA_V
end

function logo_hit(mx, my)
    return (logo ~= nil) and mx >= logo.x and mx <= logo.x + logo.w
       and my >= logo.y and my <= logo.y + logo.h
end
function controls_hit(mx, my)
    for _, b in ipairs(control_boxes) do
        if mx >= b.x0 and mx <= b.x1 and my >= b.y0 and my <= b.y1 then return b.act end
    end
end
function logo_menu_hit(mx, my)
    for _, b in ipairs(menu_boxes) do
        if mx >= b.x0 and mx <= b.x1 and my >= b.y0 and my <= b.y1 then return b.act end
    end
end


-- --- small ASS vector helpers (all coords absolute; pair with \an7\pos(0,0)) --
-- (rrect_path is defined up in the briefing section and shared.)
local function sun_path(cx, cy, r)      -- a filled disc ringed by 8 rays
    local f, p = math.floor, {}
    local N = 24
    for i = 0, N do
        local a = (i / N) * 2 * math.pi
        p[#p + 1] = string.format("%s %d %d", (i == 0) and "m" or "l",
            f(cx + r * math.cos(a) + 0.5), f(cy + r * math.sin(a) + 0.5))
    end
    local r1, r2, hw = r * 1.30, r * 1.85, r * 0.17
    for k = 0, 7 do
        local a = (k / 8) * 2 * math.pi
        local ca, sa = math.cos(a), math.sin(a)
        local pa, ps = math.cos(a + math.pi / 2), math.sin(a + math.pi / 2)
        p[#p + 1] = string.format("m %d %d l %d %d %d %d",
            f(cx + ca * r1 + pa * hw + 0.5), f(cy + sa * r1 + ps * hw + 0.5),
            f(cx + ca * r2 + 0.5),           f(cy + sa * r2 + 0.5),
            f(cx + ca * r1 - pa * hw + 0.5), f(cy + sa * r1 - ps * hw + 0.5))
    end
    return table.concat(p, " ")
end

-- A crescent moon: a full disc with an offset, opposite-wound disc punched out
-- (opposite winding leaves a hole).
local function moon_path(cx, cy, r)
    local f, N = math.floor, 24
    local function disc(dx, dy, dr, ccw)
        local p = {}
        for i = 0, N do
            local a = ((ccw and (N - i) or i) / N) * 2 * math.pi
            p[#p + 1] = string.format("%s %d %d", (i == 0) and "m" or "l",
                f(dx + dr * math.cos(a) + 0.5), f(dy + dr * math.sin(a) + 0.5))
        end
        return table.concat(p, " ")
    end
    return disc(cx, cy, r, false) .. " "
        .. disc(cx + f(r * 0.55), cy - f(r * 0.12), f(r * 0.82), true)
end

local function rect_path(x0, y0, x1, y1)
    return string.format("m %d %d l %d %d %d %d %d %d", x0, y0, x1, y0, x1, y1, x0, y1)
end

local function icon_path(kind, cx, cy, s)   -- transport glyphs, centered on cx,cy
    local f = math.floor
    if kind == "play" then
        return string.format("m %d %d l %d %d %d %d", cx - f(s * 0.7), cy - s, cx + s, cy, cx - f(s * 0.7), cy + s)
    elseif kind == "pause" then
        return rect_path(cx - f(s * 0.7), cy - s, cx - f(s * 0.15), cy + s) .. " "
            .. rect_path(cx + f(s * 0.15), cy - s, cx + f(s * 0.7), cy + s)
    elseif kind == "stop" then
        return rect_path(cx - f(s * 0.8), cy - f(s * 0.8), cx + f(s * 0.8), cy + f(s * 0.8))
    elseif kind == "next" then
        return string.format("m %d %d l %d %d %d %d", cx - s, cy - s, cx + f(s * 0.3), cy, cx - s, cy + s)
            .. " " .. rect_path(cx + f(s * 0.4), cy - s, cx + f(s * 0.8), cy + s)
    elseif kind == "prev" then
        return string.format("m %d %d l %d %d %d %d", cx + s, cy - s, cx - f(s * 0.3), cy, cx + s, cy + s)
            .. " " .. rect_path(cx - f(s * 0.8), cy - s, cx - f(s * 0.4), cy + s)
    end
    return ""
end

local function compute_logo(w, h, label, mode)
    if not w or w <= 0 then return end
    label = label or "MORNING BRIEFING"
    if mode == "clock" then
        -- Just the time: thinner (SemiBold), bigger, no frame.
        local fs = math.floor(h * 0.052)
        local tw = math.floor(#label * fs * 0.56)
        local LH = math.floor(fs * 1.25)
        logo = { mode = "clock", x = math.floor((w - tw) / 2), y = math.floor(h * 0.05),
                 w = tw, h = LH, fs = fs, fsp = math.floor(fs * 0.04 + 0.5),
                 text = label, W = w, H = h }
        return
    end
    local LH  = math.floor(h * 0.072)
    local fs  = math.floor(LH * 0.40)
    local fsp = math.floor(fs * 0.06 + 0.5)
    local tw  = math.floor(#label * fs * 0.58 + (#label - 1) * fsp)
    local pad = math.floor(LH * 0.45)
    local sw  = math.floor(LH * 0.95)
    local gap = math.floor(LH * 0.32)
    local LW  = pad + sw + gap + tw + pad
    logo = { mode = "brief", x = math.floor((w - LW) / 2), y = math.floor(h * 0.045),
             w = LW, h = LH, fs = fs, fsp = fsp, text = label,
             pad = pad, sun_w = sw, gap = gap, W = w, H = h }
end

-- Badge theme by time of day: icon (sun/moon) + colours (ASS BGR).
local function brief_theme()
    local hr = tonumber(os.date("%H")) or 0
    if hr >= 5 and hr < 12 then        -- morning: warm gold sun
        return { icon = "sun",  sun = "&H3FC0FF&", bord = "&H4FB8E8&", plaque = "&H120E0A&" }
    elseif hr >= 12 and hr < 17 then   -- afternoon: bright yellow sun, sky-blue trim
        return { icon = "sun",  sun = "&H4FE0FF&", bord = "&HF0C87E&", plaque = "&H1A1408&" }
    elseif hr >= 17 and hr < 21 then   -- evening: sunset orange, coral trim
        return { icon = "sun",  sun = "&H3F7AFF&", bord = "&H6E9EFF&", plaque = "&H140A12&" }
    else                               -- night: silver moon, purple trim
        return { icon = "moon", sun = "&HFFD0BF&", bord = "&HE87A9E&", plaque = "&H120A14&" }
    end
end

local function draw_logo(show)
    -- Runs every logo_tick (0.3s): only push an update when the rendered text
    -- actually changed (the clock changes once a minute), so libass isn't
    -- re-rastering a static overlay all day.
    if not show or not logo then
        if logo_ov.data and logo_ov.data ~= "" then logo_ov:remove(); logo_ov.data = "" end
        return
    end
    local L  = logo
    local s
    if L.mode == "clock" then
        -- Frameless clock: thinner (SemiBold), bigger, styled exactly like the
        -- rest of the HUD text (soft glow + semi-transparent), no drop shadow.
        s = string.format(
            "{\\an8\\pos(%d,%d)\\fnMontserrat SemiBold\\fs%d\\fsp%d\\1c&HFFFFFF&%s\\alpha&H40&}%s",
            math.floor(L.W / 2), L.y, L.fs, L.fsp, glow(L.fs), L.text)
    else
        local th = brief_theme()
        local cx = L.x + L.pad + math.floor(L.sun_w / 2)
        local cy = L.y + math.floor(L.h / 2)
        local r  = math.floor(L.h * 0.19)
        local tx = L.x + L.pad + L.sun_w + L.gap
        local rad = math.floor(L.h * 0.30)
        local icon = (th.icon == "moon") and moon_path(cx, cy, r) or sun_path(cx, cy, r)
        s = table.concat({
            "{\\an7\\pos(0,0)\\bord2\\shad0\\1c" .. th.plaque .. "\\1a&H2A&\\3c" .. th.bord
                .. "\\3a&H20&\\p1}" .. rrect_path(L.x, L.y, L.w, L.h, rad) .. "{\\p0}",
            "{\\an7\\pos(0,0)\\bord0\\shad0\\1c" .. th.sun .. "\\p1}" .. icon .. "{\\p0}",
            string.format("{\\an4\\pos(%d,%d)\\fnMontserrat ExtraBold\\fs%d\\fsp%d\\bord0"
                .. "\\shad1\\4c&H000000&\\4a&H60&\\1c&HFFFFFF&}%s", tx, cy, L.fs, L.fsp, L.text),
        }, "\n")
    end
    if s == logo_ov.data and logo_ov.res_x == L.W and logo_ov.res_y == L.H then return end
    logo_ov.res_x = L.W; logo_ov.res_y = L.H
    logo_ov.data = s
    logo_ov:update()
end

-- Transport row while a briefing speaks: prev / pause-play / next / stop.
local function draw_controls()
    control_boxes = {}
    if not logo then controls_ov:remove(); return end
    local L  = logo
    local bw = math.floor(L.h * 0.82)
    local bh = math.floor(L.h * 0.60)
    local g  = math.floor(L.h * 0.16)
    local rad = math.floor(bh * 0.30)
    local defs = {
        { kind = "prev",  msg = "ss-briefing-prev"  },
        { kind = briefing_paused and "play" or "pause", msg = "ss-briefing-pause" },
        { kind = "next",  msg = "ss-briefing-skip"  },
        { kind = "stop",  msg = "ss-briefing-stop"  },
    }
    local th = brief_theme()
    local totalw = #defs * bw + (#defs - 1) * g
    local bx = L.x + math.floor((L.w - totalw) / 2)
    local by = L.y + L.h + math.floor(L.h * 0.16)
    local parts = {}
    for i, d in ipairs(defs) do
        local x0 = bx + (i - 1) * (bw + g)
        local x1, y0, y1 = x0 + bw, by, by + bh
        local cx, cy = x0 + math.floor(bw / 2), y0 + math.floor(bh / 2)
        parts[#parts + 1] = "{\\an7\\pos(0,0)\\bord1\\shad0\\1c" .. th.plaque .. "\\1a&H22&\\3c"
            .. th.bord .. "\\3a&H40&\\p1}" .. rrect_path(x0, y0, bw, bh, rad) .. "{\\p0}"
        parts[#parts + 1] = "{\\an7\\pos(0,0)\\bord0\\shad0\\1c&HFFFFFF&\\p1}"
            .. icon_path(d.kind, cx, cy, math.floor(bh * 0.23)) .. "{\\p0}"
        control_boxes[#control_boxes + 1] = { x0 = x0, y0 = y0, x1 = x1, y1 = y1,
            act = (function(m) return function() mp.command("script-message " .. m) end end)(d.msg) }
    end
    controls_ov.res_x = L.W; controls_ov.res_y = L.H
    controls_ov.data = table.concat(parts, "\n")
    controls_ov:update()
end

-- True if today's briefing is already generated (has cached audio).
function briefing_has_cache()
    local files = utils.readdir(DATA_DIR .. "/Briefing/" .. os.date("%Y-%m-%d"), "files")
    if files then for _, f in ipairs(files) do if f:match("%.mp3$") then return true end end end
    return false
end

-- Idle chooser: Replay/Refresh once today's briefing exists, else a single
-- GENERATE (there's nothing to replay yet).
local function draw_menu()
    menu_boxes = {}
    if not logo then controls_ov:remove(); return end
    local L  = logo
    local fs = math.floor(L.h * 0.30)
    local bh = math.floor(L.h * 0.66)
    local g  = math.floor(L.h * 0.22)
    local rad = math.floor(bh * 0.32)
    local defs = briefing_has_cache()
        and { { t = "REPLAY", mode = "--play" }, { t = "REFRESH", mode = "--fresh" } }
        or  { { t = "GENERATE", mode = "--play" } }
    local th = brief_theme()
    local bws, totalw = {}, 0
    for i, d in ipairs(defs) do
        bws[i] = math.floor(#d.t * fs * 0.66 + fs * 1.6); totalw = totalw + bws[i]
    end
    totalw = totalw + (#defs - 1) * g
    local bx = L.x + math.floor((L.w - totalw) / 2)
    local by = L.y + L.h + math.floor(L.h * 0.16)
    local parts = {}
    local cursor = bx
    for i, d in ipairs(defs) do
        local bw = bws[i]
        local x0, x1, y0, y1 = cursor, cursor + bw, by, by + bh
        parts[#parts + 1] = "{\\an7\\pos(0,0)\\bord1\\shad0\\1c" .. th.plaque .. "\\1a&H1A&\\3c"
            .. th.bord .. "\\3a&H30&\\p1}" .. rrect_path(x0, y0, bw, bh, rad) .. "{\\p0}"
        parts[#parts + 1] = string.format("{\\an5\\pos(%d,%d)\\fnMontserrat ExtraBold\\fs%d"
            .. "\\fsp%d\\bord0\\shad0\\1c&HFFFFFF&}%s",
            x0 + math.floor(bw / 2), y0 + math.floor(bh / 2), fs, math.floor(fs * 0.05 + 0.5), d.t)
        menu_boxes[#menu_boxes + 1] = { x0 = x0, y0 = y0, x1 = x1, y1 = y1,
            act = (function(mode) return function()
                mp.commandv("run", CFG_DIR .. "/grok-briefing.sh", mode)
                BD.preparing = true; BD.t0 = mp.get_time(); LB.spoke = false
            end end)(d.mode) }
        cursor = cursor + bw + g
    end
    controls_ov.res_x = L.W; controls_ov.res_y = L.H
    controls_ov.data = table.concat(parts, "\n")
    controls_ov:update()
end

-- Time-of-day word, shared by the badge label and the GROK title.
local function tod_word()
    local hr = tonumber(os.date("%H")) or 0
    return (hr >= 5 and hr < 12 and "MORNING")
        or (hr >= 12 and hr < 17 and "AFTERNOON")
        or (hr >= 17 and hr < 21 and "EVENING") or "NIGHT"
end
local function tod_briefing_label() return tod_word() .. " BRIEFING" end

-- Reveal area around the badge. Bounded ABOVE (so it doesn't cover the month bar
-- at the very top), but extends well BELOW to cover the controls / Replay-Refresh
-- buttons that sit under the badge — so the mouse can travel down to them.
local function logo_zone(mx, my)
    if not logo then return false end
    local mar = math.floor(logo.h * 1.2)
    return mx >= logo.x - mar and mx <= logo.x + logo.w + mar
       and my >= logo.y - math.floor(logo.h * 0.5)
       and my <= logo.y + logo.h + math.floor(logo.h * 1.8)
end

-- Advance the briefing backdrop to the next PHOTO every ~10s (self-rescheduling
-- while the briefing is live). Only photo indices are ever selected, so videos
-- never load.
function backdrop_tick()
    if not LB.hud_off or not LB.photos or #LB.photos == 0 then return end
    LB.pidx = (LB.pidx % #LB.photos) + 1
    mp.set_property_number("playlist-pos", LB.photos[LB.pidx])
    mp.add_timeout(10, backdrop_tick)
end

-- Manual photo step during a briefing (so RIGHT/LEFT/wheel never reach a video).
-- Returns true if it handled it (i.e. a briefing is live).
function backdrop_step(d)
    if not LB.hud_off then return false end
    if LB.photos and #LB.photos > 0 then
        LB.pidx = LB.pidx + d
        if LB.pidx < 1 then LB.pidx = #LB.photos elseif LB.pidx > #LB.photos then LB.pidx = 1 end
        mp.set_property_number("playlist-pos", LB.photos[LB.pidx])
    end
    return true
end

local function logo_tick()
    if not GROK_ENABLED then return end
    local w, h = refresh_display_size()
    if w <= 0 then return end
    local active = briefing_active()
    -- A scheduled briefing lifts the quiet-hours blackout immediately (don't
    -- wait for bo_check's slower tick — its audio is already starting).
    if active and BO and BO.on then bo_hide() end

    -- The badge shows the live clock when idle; it flips to the framed "<time of
    -- day> BRIEFING" badge (sun + click target) when the mouse is near it, the
    -- chooser menu is open, or a briefing is preparing/speaking.
    local brief = active or BD.preparing or BD.menu_open or LB.near
    local mode  = brief and "brief" or "clock"
    local label = brief and tod_briefing_label() or os.date("%I:%M %p"):gsub("^0", "")
    if not logo or logo.W ~= w or logo.H ~= h or label ~= LB.label or logo.mode ~= mode then
        compute_logo(w, h, label, mode); LB.label = label
    end
    if not logo then return end

    -- Mute the whole screensaver while a briefing speaks; restore after.
    if active and not LB.muted then
        LB.vol = mp.get_property_number("volume") or LB.vol
        mp.set_property_number("volume", 0); LB.muted = true
    elseif not active and LB.muted then
        mp.set_property_number("volume", LB.vol or 70); LB.muted = false
        LB.spoke = false
    end

    -- Hide every non-music HUD while a briefing is on screen, and turn the
    -- slideshow into a calm blurred-PHOTO backdrop; restore normal once it ends.
    if active and not LB.hud_off then
        LB.hud_off = true
        clear_other_hud()
        animate_gtitle("GROK " .. tod_word(), w, h)   -- "GROK MORNING/…" build-up
        -- Backdrop: only ever load PHOTO playlist entries (so videos/title cards
        -- never decode or flash through), advanced slowly by backdrop_tick.
        LB.idd = mp.get_property("image-display-duration")
        mp.set_property("image-display-duration", "inf")   -- stop auto-advance; we drive it
        LB.photos = {}
        local pl = mp.get_property_native("playlist") or {}
        for i, e in ipairs(pl) do
            local ex = ((e.filename or ""):match("%.([^%.]+)$") or ""):lower()
            if image_ext[ex] then LB.photos[#LB.photos + 1] = i - 1 end
        end
        if #LB.photos > 0 then
            local pos = mp.get_property_number("playlist-pos") or 0
            LB.pidx = 1
            for k, idx in ipairs(LB.photos) do if idx >= pos then LB.pidx = k; break end end
            mp.set_property_number("playlist-pos", LB.photos[LB.pidx])
            mp.add_timeout(10, backdrop_tick)
        end
        -- Blur the photo on screen right now (if the position didn't change, the
        -- file won't reload, so the full-blur vf wouldn't get applied otherwise).
        local cp = cur.path or ""
        if cp ~= "" and image_ext[(cp:match("%.([^%.]+)$") or ""):lower()] then
            apply_image_blur_vf(cp)
        end
    elseif not active and LB.hud_off then
        LB.hud_off = false
        if LB.idd then mp.set_property("image-display-duration", LB.idd); LB.idd = nil end
        LB.photos = nil
        draw_top_bar()
        mp.command("playlist-next")                   -- resume a fresh normal photo (sharp + HUD)
    end

    -- The badge is always visible (clock when idle). Under it: transport while
    -- speaking; the Replay/Refresh chooser when the mouse is near (or the menu was
    -- clicked open); nothing while preparing or fully idle.
    if active then
        BD.menu_open = false; BD.menu_vis = false
        draw_logo(true); draw_controls(); menu_boxes = {}
    elseif BD.preparing then
        BD.menu_vis = false
        draw_logo(true); controls_ov:remove(); control_boxes = {}; menu_boxes = {}
    elseif LB.near or BD.menu_open then
        BD.menu_vis = true
        draw_logo(true); draw_menu(); control_boxes = {}
    else
        BD.menu_vis = false
        draw_logo(true)
        controls_ov:remove(); control_boxes = {}; menu_boxes = {}
    end

    -- "GETTING READY…" shows only during the prep phase (after a click, before it
    -- goes live). Once it's live (active) or speaking, the prep phase is over.
    local f = io.open("/tmp/ss_briefing.txt", "r")
    local s = f and (f:read("*a") or "") or ""
    if f then f:close() end
    s = s:gsub("%s+$", "")
    local speaking = (s ~= "" and s ~= "__HIDE__")
    if speaking then LB.spoke = true end
    -- Prep ends when it goes live/speaks, or if the process died (PID gone) — but
    -- give it a few seconds after the click for that PID file to appear.
    local proc = file_exists("/tmp/ss_briefing.pid")
    if speaking or active or (not proc and mp.get_time() - BD.t0 > 3) then BD.preparing = false end
    local idle = not (active or BD.preparing or LB.near or BD.menu_open)
    local hh, mm = GROK_TIME:match("(%d+):(%d+)")
    -- (Like draw_logo, only re-upload this overlay when its text changes — it is
    -- recomputed every 0.3s but static for minutes at a time.)
    local lt
    if BD.preparing and not LB.spoke and (mp.get_time() - BD.t0 <= 185) then
        local fs = math.floor(h * 0.024)
        lt = string.format(
            "{\\an8\\pos(%d,%d)\\fnMontserrat ExtraBold\\fs%d\\fsp%d\\1c&HFFFFFF&%s\\alpha&H30&}GETTING READY…",
            math.floor(w / 2), logo.y + logo.h + math.floor(logo.h * 0.95),
            fs, math.floor(fs * 0.05 + 0.5), glow(fs))
    elseif idle and hh then
        -- Under the idle clock: when the next briefing is scheduled.
        local H, M = tonumber(hh), tonumber(mm)
        local h12  = H % 12; if h12 == 0 then h12 = 12 end
        local when = string.format("%d:%02d %s", h12, M, (H < 12) and "AM" or "PM")
        local fs   = math.floor(h * 0.018)
        lt = string.format(
            "{\\an8\\pos(%d,%d)\\fnMontserrat SemiBold\\fs%d\\fsp%d\\1c&HFFFFFF&%s\\alpha&H50&}"
            .. "BRIEFING SCHEDULED AT: %s",
            math.floor(w / 2), logo.y + logo.h + math.floor(logo.h * 0.12),
            fs, math.floor(fs * 0.05 + 0.5), glow(fs), when)
    end
    if lt then
        if lt ~= logo_text_ov.data or logo_text_ov.res_x ~= w or logo_text_ov.res_y ~= h then
            logo_text_ov.res_x = w; logo_text_ov.res_y = h
            logo_text_ov.data = lt
            logo_text_ov:update()
        end
    elseif logo_text_ov.data and logo_text_ov.data ~= "" then
        logo_text_ov:remove(); logo_text_ov.data = ""
    end
end
mp.add_periodic_timer(0.3, logo_tick)

-- Reveal the briefing badge as the mouse approaches the clock.
mp.observe_property("mouse-pos", "native", function(_, m)
    if not GROK_ENABLED then return end
    LB.near = (m ~= nil) and logo_zone(m.x, m.y) or false
end)

-- ----------------------------------------------------------------------------
-- Delete the current media (DEL key)
--   Moves the photo/video and everything derived from it to the system trash —
--   the .xmp / .txt sidecars and every per-resolution optimized clip — drops it
--   from the playlist, and immediately advances to the next item.
-- ----------------------------------------------------------------------------
mp.register_script_message("ss-delete-current", function()
    if bo_wake() then return end
    if briefing_active and briefing_active() then return end   -- not during a briefing
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


-- ----------------------------------------------------------------------------
-- Help overlay ('?' or 'h'): a styled cheat-sheet of every control, so the
-- features are discoverable from the screen itself. Toggles; auto-hides after
-- 30s. (Globals — the main chunk is at Lua's 200-local cap.)
-- ----------------------------------------------------------------------------
HELP = { ov = mp.create_osd_overlay("ass-events"), on = false, gen = 0 }
function help_hide()
    HELP.on = false; HELP.gen = HELP.gen + 1
    HELP.ov:remove(); HELP.ov.data = ""
end
function help_show()
    local w, h = refresh_display_size()
    if w <= 0 then return end
    local fs  = math.floor(h * 0.021)
    local tfs = math.floor(h * 0.032)
    local lines = {
        string.format("{\\fs%d\\fnMontserrat ExtraBold}CONTROLS{\\fs%d\\fnMontserrat SemiBold}", tfs, fs),
        "",
        "\\h←\\h\\h→\\h\\h\\hprevious / next photo",
        "SCROLL\\h\\hbrowse\\h\\h\\h•\\h\\h\\hSPACE\\h\\hplay / pause music",
        "\\h↑\\h\\h↓\\h\\h\\hzoom the minimap",
        "PGUP / PGDN\\h\\hmonth\\h\\h\\h•\\h\\h\\hHOME / END\\h\\hyear",
        "L\\h\\hcycle landmark names\\h\\h\\h•\\h\\h\\hS\\h\\hsettings menu",
        "DEL\\h\\hmove photo to trash",
        "=\\h/\\h−\\h\\hvolume\\h\\h\\h•\\h\\h\\hESC / Q\\h\\hquit",
        "",
        "CLICK\\h\\halbum art: play / pause\\h\\h\\h•\\h\\h\\hsong title: chooser",
        "CLICK\\h\\hmonth bar: jump there\\h\\h\\h•\\h\\h\\hRIGHT-CLICK\\h\\hquit",
        "",
        "{\\fnMontserrat ExtraBold}MORNING BRIEFING{\\fnMontserrat SemiBold}\\h\\h(while playing)",
        ".\\h\\hskip\\h\\h\\h,\\h\\hback\\h\\h\\hB\\h\\hpause\\h\\h\\hC\\h\\hcaptions\\h\\h\\hX\\h\\hstop",
    }
    local lh = math.floor(fs * 1.55)
    local bh = #lines * lh + math.floor(tfs * 1.2) + lh * 2
    local bw = math.floor(w * 0.40)
    local bx = math.floor((w - bw) / 2)
    local by = math.floor((h - bh) / 2)
    HELP.ov.res_x = w; HELP.ov.res_y = h
    HELP.ov.data = table.concat({
        "{\\an7\\pos(0,0)\\bord2\\shad0\\1c&H101010&\\1a&H28&\\3c&H707070&\\3a&H50&\\p1}"
            .. rrect_path(bx, by, bw, bh, math.floor(h * 0.018)) .. "{\\p0}",
        string.format("{\\an5\\pos(%d,%d)\\fnMontserrat SemiBold\\fs%d\\fsp%d\\bord0"
            .. "\\shad1\\4c&H000000&\\4a&H60&\\1c&HFFFFFF&}%s",
            math.floor(w / 2), math.floor(h / 2), fs, math.floor(fs * 0.04 + 0.5),
            table.concat(lines, "\\N")),
    }, "\n")
    HELP.ov:update()
    HELP.on = true
    HELP.gen = HELP.gen + 1
    local g = HELP.gen
    mp.add_timeout(30, function() if HELP.on and g == HELP.gen then help_hide() end end)
end
mp.register_script_message("ss-help", function()
    if bo_wake() then return end
    if HELP.on then help_hide() else help_show() end
end)


-- ----------------------------------------------------------------------------
-- Settings menu ('s'): every screensaver.conf knob, editable from the screen.
-- ↑/↓ selects, ←/→ adjusts, ENTER types a value (text fields use mpv's input
-- line), ESC closes. Every change is written straight into screensaver.conf
-- (comments and layout preserved, atomic .part+rename). Knobs the running
-- script can re-read apply instantly; the rest take effect next launch — R
-- quits and relaunches right away. (Globals — main chunk is at the local cap.)
-- ----------------------------------------------------------------------------
SET = {
    ov   = mp.create_osd_overlay("ass-events"),
    on   = false, sel = 2, top = 1, gen = 0,
    vals = {}, over = {}, note = "",
}
SET.ov.z = 1500

-- Edited values must win over the stale environment launch.sh exported, so
-- knobs the script re-reads at runtime (the quiet-hours window) go live the
-- moment they're saved. Wrap cfgraw with an override table checked first.
SET.cfg_orig = cfgraw
cfgraw = function(name)
    local o = SET.over[name]
    if o ~= nil then return o end
    return SET.cfg_orig(name)
end

-- One entry per knob. typ: int | num | bool | time | str.  live: true when the
-- conf override alone is enough, or a function to push the change into running
-- state; absent = takes effect next launch.
SET.schema = {
    { head = "PLAYBACK" },
    { key = "PHOTO_DURATION", label = "Photo duration", typ = "int", min = 2, max = 60, step = 1, unit = "s",
      live = function(v) mp.set_property_number("image-display-duration", tonumber(v)) end,
      desc = "Seconds each photo stays up — videos always play in full." },
    { key = "VOLUME", label = "Volume", typ = "int", min = 0, max = 100, step = 5,
      live = function(v) if not briefing_active() then mp.set_property_number("volume", tonumber(v)) end end,
      desc = "Playback volume for the screensaver (music and video sound)." },
    { key = "IDLE_TIMEOUT_MS", label = "Start after idle", typ = "int", min = 60000, max = 3600000, step = 60000,
      fmt = function(v) return string.format("%d min", math.floor((tonumber(v) or 0) / 60000 + 0.5)) end,
      desc = "How long the computer sits untouched before the screensaver starts." },
    { key = "MIN_LOAD_SECS", label = "Loading screen minimum", typ = "int", min = 0, max = 10, step = 1, unit = "s",
      desc = "Shortest time the loading screen stays visible." },
    { key = "VID_RESCAN_SECS", label = "Video rescan every", typ = "int", min = 60, max = 3600, step = 60,
      fmt = function(v) return string.format("%d min", math.floor((tonumber(v) or 0) / 60 + 0.5)) end,
      desc = "How often new videos dropped into Media are found and optimized." },

    { head = "HUD TEXT" },
    { key = "HUD_CITY_FS", label = "City headline size", typ = "num", min = 0.020, max = 0.150, step = 0.004, dec = 3,
      live = function(v) HUD_CITY_FS = tonumber(v) end,
      desc = "All sizes are a share of screen height, so they fit any display." },
    { key = "HUD_DATE_FS", label = "Date size", typ = "num", min = 0.010, max = 0.080, step = 0.002, dec = 3,
      live = function(v) HUD_DATE_FS = tonumber(v) end,
      desc = "The date in the top-right corner." },
    { key = "HUD_REGION_FS", label = "Region size", typ = "num", min = 0.010, max = 0.080, step = 0.002, dec = 3,
      live = function(v) HUD_REGION_FS = tonumber(v) end,
      desc = "The state / country line under the date." },
    { key = "HUD_MUSIC_FS", label = "Music text size", typ = "num", min = 0.010, max = 0.080, step = 0.002, dec = 3,
      live = function(v) HUD_MUSIC_FS = tonumber(v) end,
      desc = "The now-playing song title and artist, top-left." },
    { key = "HUD_COORD_FS", label = "Coordinates size", typ = "num", min = 0.010, max = 0.080, step = 0.002, dec = 3,
      live = function(v) HUD_COORD_FS = tonumber(v) end,
      desc = "The GPS coordinates under the QR code and minimap." },
    { key = "HUD_TEXT_BLUR", label = "Text shadow softness", typ = "num", min = 0, max = 0.50, step = 0.02, dec = 2,
      live = function(v) HUD_TEXT_BLUR = tonumber(v) end,
      desc = "Bigger = softer, wider dark halo behind HUD text." },
    { key = "HUD_TEXT_GLOW", label = "Text shadow strength", typ = "num", min = 0, max = 0.020, step = 0.001, dec = 3,
      live = function(v) HUD_TEXT_GLOW = tonumber(v) end,
      desc = "Weight of the dark halo — smaller is fainter." },

    { head = "HUD LAYOUT" },
    { key = "MUSIC_WIN_FRAC", label = "Music marquee width", typ = "num", min = 0.10, max = 0.60, step = 0.02, dec = 2,
      live = function(v) MUSIC_WIN_FRAC = tonumber(v) end,
      desc = "Share of the screen width the now-playing marquee may use." },
    { key = "HUD_MAP_FRAC", label = "Minimap / QR size", typ = "num", min = 0.10, max = 0.50, step = 0.01, dec = 2,
      desc = "Share of screen height for the minimap and QR squares." },
    { key = "HUD_THUMB", label = "Album-art thumbnail", typ = "bool", on = "1", off = "0", def = "1",
      live = function(v) SHOW_THUMB = (v ~= "0") end,
      desc = "Cover art next to the music bar — click it to play / pause." },
    { key = "HUD_AUTO_ZOOM", label = "Auto zoom", typ = "bool", on = "yes", off = "no", live = true, def = "yes",
      desc = "Step the minimap inward while each item plays; ↑/↓ always work." },
    { key = "HUD_MAP_ZOOMS", label = "Minimap zoom levels", typ = "str",
      desc = "Space-separated zoom levels the ↑/↓ keys cycle through — any count." },
    { key = "HUD_RING_COLORS", label = "GPS ring colours", typ = "str",
      desc = "#RRGGBB gradient stops — ring blends first→last across the zooms." },

    { head = "QUIET HOURS" },
    { key = "MUSIC_SLEEP_START", label = "Music off at", typ = "time", step = 15, live = true,
      desc = "Music pauses nightly at this time — ENTER to type, empty = no quiet hours." },
    { key = "MUSIC_SLEEP_END", label = "Music back at", typ = "time", step = 15, live = true,
      desc = "Music resumes at this time; overnight windows are fine." },
    { key = "BLACKOUT_ENABLE", label = "Idle blackout", typ = "bool", on = "yes", off = "no", def = "yes",
      live = function(v) BO.enable = (v:lower() ~= "no") end,
      desc = "Looks off when idle in quiet hours, but HDMI stays alive." },
    { key = "BLACKOUT_IDLE_MIN", label = "Blackout after", typ = "int", min = 1, max = 120, step = 1, unit = "min",
      live = function(v) BO.idle = (tonumber(v) or 15) * 60 end,
      desc = "Minutes without input before the screen fades to black." },

    { head = "MORNING BRIEFING" },
    { key = "GROK_BRIEFING", label = "Briefing enabled", typ = "bool", on = "1", off = "0", def = "0",
      desc = "Spoken AI morning briefing — needs XAI_API_KEY in your environment." },
    { key = "GROK_TIME", label = "Briefing time", typ = "time", step = 5,
      desc = "When the briefing plays each morning (24h)." },
    { key = "GROK_LOCATION", label = "Weather location", typ = "str",
      desc = "City for the weather segment, e.g. \"Mooresville, NC\"." },
    { key = "GROK_TICKERS", label = "Stock tickers", typ = "str",
      desc = "Comma-separated tickers for the stocks segment — empty skips it." },
    { key = "GROK_VOICE", label = "Voice", typ = "str",
      desc = "The xAI voice the briefing speaks with." },
    { key = "GROK_MODEL", label = "Model", typ = "str",
      desc = "The xAI model that writes the briefing." },
    { key = "GROK_BGM_VOLUME", label = "Briefing music volume", typ = "int", min = 0, max = 100, step = 5,
      desc = "Background-music level under the spoken briefing." },
    { key = "GROK_VOICE_VOLUME", label = "Voice gain", typ = "int", min = 50, max = 300, step = 10, unit = "%",
      desc = "Spoken-voice loudness — 100 = as recorded, higher is louder." },
    { key = "GROK_SPEAK_DELAY", label = "Intro music", typ = "int", min = 0, max = 30, step = 1, unit = "s",
      desc = "Seconds of music before the first words." },
    { key = "GROK_SECTION_GAP", label = "Section gap", typ = "int", min = 0, max = 10, step = 1, unit = "s",
      desc = "Seconds of music between briefing sections." },
    { key = "GROK_FADE_IN", label = "Fade in", typ = "num", min = 0, max = 10, step = 0.1, dec = 1, unit = "s",
      desc = "Soft-drop of the slideshow music when the briefing starts." },
    { key = "GROK_FADE_OUT", label = "Fade out", typ = "num", min = 0, max = 10, step = 0.1, dec = 1, unit = "s",
      desc = "Soft-drop of the briefing music when it ends." },
    { key = "GROK_FADE_RESUME", label = "Music resume fade", typ = "num", min = 0, max = 10, step = 0.1, dec = 1, unit = "s",
      desc = "Soft return of the slideshow music afterwards." },

    { head = "PLACE NAMES" },
    { key = "GEONAMES_COUNTRIES", label = "Countries indexed", typ = "str",
      onsave = function()
          local cur = tonumber((set_conf_read().GEODB_VERSION or "1"):match("%d+") or "1") or 1
          set_conf_write("GEODB_VERSION", tostring(cur + 1), { quote = true })
      end,
      desc = "ISO codes, space-separated — empty = whole planet. Changing this rebuilds the place database next launch." },
}
SET.rows = SET.schema

function set_conf_read()
    local t = {}
    local f = io.open(CFG_DIR .. "/screensaver.conf", "r")
    if f then
        for line in f:lines() do
            local k, rest = line:match("^%s*export%s+([%w_]+)=(.*)$")
            if k then
                rest = rest:gsub("^%s+", "")
                local q = rest:match('^"(.-)"') or rest:match("^'(.-)'")
                if q then rest = q else rest = rest:gsub("%s*#.*$", ""):gsub("%s+$", "") end
                t[k] = rest
            end
        end
        f:close()
    end
    return t
end

-- Replace one knob's value in screensaver.conf, keeping the line's trailing
-- comment and everything else in the file byte-identical. Atomic publish.
function set_conf_write(key, val, it)
    local path = CFG_DIR .. "/screensaver.conf"
    local f = io.open(path, "r")
    if not f then return false end
    local lines, found = {}, false
    for line in f:lines() do
        if not found then
            local pre = line:match("^(%s*export%s+" .. key .. "=)")
            if pre then
                found = true
                local rest, tail = line:sub(#pre + 1), ""
                local q = rest:sub(1, 1)
                if q == '"' or q == "'" then
                    local close = rest:find(q, 2, true)
                    if close then tail = rest:sub(close + 1) end
                else
                    local sp, cm = rest:match("^[^#]-(%s*)(#.*)$")
                    if cm then tail = sp .. cm end
                end
                local enc = val
                if it and (it.typ == "str" or it.typ == "time" or it.quote) then
                    enc = '"' .. val:gsub('[\\"$`]', "") .. '"'
                end
                line = pre .. enc .. tail
            end
        end
        lines[#lines + 1] = line
    end
    f:close()
    if not found then
        local enc = val
        if it and (it.typ == "str" or it.typ == "time" or it.quote) then enc = '"' .. val .. '"' end
        lines[#lines + 1] = "export " .. key .. "=" .. enc
    end
    local out = io.open(path .. ".part", "w")
    if not out then return false end
    out:write(table.concat(lines, "\n"), "\n")
    out:close()
    return os.rename(path .. ".part", path) ~= nil
end

function set_fmt(it, v)
    v = v or ""
    if it.typ == "bool" then return (v == (it.on or "1")) and "ON" or "OFF" end
    if it.typ == "time" then return (v == "") and "off" or v end
    if it.fmt then return it.fmt(v) end
    local s
    if it.typ == "num" then s = string.format("%." .. (it.dec or 2) .. "f", tonumber(v) or 0)
    elseif it.typ == "int" then s = string.format("%d", tonumber(v) or 0)
    else
        s = v
        if s == "" then s = "—" end
        if #s > 26 then s = s:sub(1, 25) .. "…" end
    end
    if it.unit then s = s .. " " .. it.unit end
    return s
end

function set_draw()
    local w, h = refresh_display_size()
    if w <= 0 or h <= 0 then return end
    local fs   = math.floor(h * 0.0185)
    local tfs  = math.floor(h * 0.030)
    local lh   = math.floor(fs * 1.62)
    local pad  = math.floor(h * 0.030)
    local nvis = math.min(#SET.rows, math.floor((h * 0.72) / lh))
    if SET.sel < SET.top then SET.top = SET.sel end
    if SET.sel > SET.top + nvis - 1 then SET.top = SET.sel - nvis + 1 end
    -- pull a section header into view when its first item is the top row
    if SET.top > 1 and SET.rows[SET.top - 1].head and SET.sel < SET.top + nvis - 1 then
        SET.top = SET.top - 1
    end
    local bw = math.floor(w * 0.46)
    local fh = math.floor(fs * 1.45)                -- footer line height
    local bh = pad + math.floor(tfs * 1.7) + nvis * lh + math.floor(fh * 2.4) + pad
    local bx = math.floor((w - bw) / 2)
    local by = math.floor((h - bh) / 2)
    local xl = bx + pad
    local xv = bx + math.floor(bw * 0.60)
    local y0 = by + pad + math.floor(tfs * 1.7)
    local ev = {}
    ev[#ev + 1] = "{\\an7\\pos(0,0)\\bord2\\shad0\\1c&H101010&\\1a&H20&\\3c&H707070&\\3a&H50&\\p1}"
        .. rrect_path(bx, by, bw, bh, math.floor(h * 0.018)) .. "{\\p0}"
    local selvis = SET.sel - SET.top
    if selvis >= 0 and selvis < nvis then
        ev[#ev + 1] = "{\\an7\\pos(0,0)\\bord0\\shad0\\1c&HFFFFFF&\\1a&HE0&\\p1}"
            .. rrect_path(bx + math.floor(pad / 2), y0 + selvis * lh, bw - pad, lh, math.floor(lh * 0.25))
            .. "{\\p0}"
    end
    ev[#ev + 1] = string.format("{\\an8\\pos(%d,%d)\\fnMontserrat ExtraBold\\fs%d\\bord0"
        .. "\\shad1\\4c&H000000&\\4a&H60&\\1c&HFFFFFF&}SETTINGS",
        bx + math.floor(bw / 2), by + pad, tfs)
    for i = 0, nvis - 1 do
        local r = SET.rows[SET.top + i]
        if not r then break end
        local yc = y0 + i * lh + math.floor(lh / 2)
        if r.head then
            ev[#ev + 1] = string.format("{\\an4\\pos(%d,%d)\\fnMontserrat ExtraBold\\fs%d"
                .. "\\bord0\\shad0\\1c&HF7C34F&}%s", xl, yc, math.floor(fs * 0.92), r.head)
        else
            local sel = (SET.top + i == SET.sel)
            ev[#ev + 1] = string.format("{\\an4\\pos(%d,%d)\\fnMontserrat SemiBold\\fs%d"
                .. "\\bord0\\shad0\\1c&H%s&}%s",
                xl, yc, fs, sel and "FFFFFF" or "C8C8C8", r.label)
            local vtxt = set_fmt(r, SET.vals[r.key])
            if sel then
                vtxt = (r.typ == "str") and (vtxt .. "\\h\\h(ENTER)") or ("‹\\h\\h" .. vtxt .. "\\h\\h›")
            end
            ev[#ev + 1] = string.format("{\\an4\\pos(%d,%d)\\fnMontserrat SemiBold\\fs%d"
                .. "\\bord0\\shad0\\1c&H%s&}%s",
                xv, yc, fs, sel and "FFFFFF" or "FCE5B3", vtxt)
        end
    end
    if SET.top > 1 then
        ev[#ev + 1] = string.format("{\\an6\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c&H909090&}▲",
            bx + bw - math.floor(pad / 2), y0 + math.floor(lh / 2), math.floor(fs * 0.8))
    end
    if SET.top + nvis - 1 < #SET.rows then
        ev[#ev + 1] = string.format("{\\an6\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c&H909090&}▼",
            bx + bw - math.floor(pad / 2), y0 + (nvis - 1) * lh + math.floor(lh / 2), math.floor(fs * 0.8))
    end
    local it = SET.rows[SET.sel]
    local note = SET.note ~= "" and SET.note or (it and it.desc or "")
    local fy = y0 + nvis * lh + math.floor(fh * 0.4)
    ev[#ev + 1] = string.format("{\\an8\\pos(%d,%d)\\fnMontserrat SemiBold\\fs%d\\bord0\\shad0\\1c&H%s&}%s",
        bx + math.floor(bw / 2), fy, math.floor(fs * 0.82),
        SET.note ~= "" and "F7C34F" or "A0A0A0", note)
    ev[#ev + 1] = string.format("{\\an8\\pos(%d,%d)\\fnMontserrat SemiBold\\fs%d\\bord0\\shad0\\1c&H808080&}"
        .. "↑↓ select\\h\\h\\h‹ › change\\h\\h\\hENTER type\\h\\h\\hR restart now\\h\\h\\hESC close",
        bx + math.floor(bw / 2), fy + fh, math.floor(fs * 0.82))
    SET.ov.res_x = w; SET.ov.res_y = h
    SET.ov.data = table.concat(ev, "\n")
    SET.ov:update()
end

function set_arm()
    SET.gen = SET.gen + 1
    local g = SET.gen
    mp.add_timeout(120, function() if SET.on and g == SET.gen then set_hide() end end)
end

function set_move(dir)
    local i = SET.sel
    repeat i = i + dir until not SET.rows[i] or SET.rows[i].key
    if SET.rows[i] then SET.sel = i; SET.note = ""; set_draw() end
end

function set_apply(it, v)
    SET.vals[it.key] = v
    SET.over[it.key] = v
    local ok = set_conf_write(it.key, v, it)
    if it.onsave then pcall(it.onsave, v) end
    if type(it.live) == "function" then pcall(it.live, v) end
    if not ok then SET.note = "Could not write screensaver.conf!"
    elseif it.live then SET.note = "Saved — applied live"
    else SET.note = "Saved — applies next start (R restarts now)" end
    set_draw()
end

function set_adjust(dir)
    local it = SET.rows[SET.sel]
    if not it or not it.key then return end
    local v = SET.vals[it.key] or ""
    if it.typ == "bool" then
        v = (v == (it.on or "1")) and (it.off or "0") or (it.on or "1")
    elseif it.typ == "time" then
        local hh, mm = v:match("^(%d+):(%d+)$")
        if not hh then hh, mm = v:match("^(%d+)$"), "0" end
        local mins = hh and ((tonumber(hh) % 24) * 60 + (tonumber(mm) % 60)) or 0
        mins = (mins + dir * (it.step or 15)) % 1440
        if mins < 0 then mins = mins + 1440 end
        v = string.format("%02d:%02d", math.floor(mins / 60), mins % 60)
    elseif it.typ == "int" or it.typ == "num" then
        local n = (tonumber(v) or 0) + dir * (it.step or 1)
        if it.min and n < it.min then n = it.min end
        if it.max and n > it.max then n = it.max end
        v = (it.typ == "int") and string.format("%d", n)
            or string.format("%." .. (it.dec or 2) .. "f", n)
    else
        return                          -- str: ENTER opens the text input
    end
    set_apply(it, v)
end

function set_submit(it, text)
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if it.typ == "time" and text ~= "" then
        local hh, mm = text:match("^(%d?%d):(%d?%d)$")
        if not hh then hh, mm = text:match("^(%d?%d)$"), "0" end
        local H, M = tonumber(hh), tonumber(mm)
        if not H or H > 23 or not M or M > 59 then
            SET.note = "Use 24h HH:MM — or leave empty for off"
            set_draw(); return
        end
        text = string.format("%02d:%02d", H, M)
    elseif it.typ == "int" or it.typ == "num" then
        local n = tonumber(text)
        if not n then SET.note = "Enter a number"; set_draw(); return end
        if it.min and n < it.min then n = it.min end
        if it.max and n > it.max then n = it.max end
        text = (it.typ == "int") and string.format("%d", n)
            or string.format("%." .. (it.dec or 2) .. "f", n)
    end
    set_apply(it, text)
end

function set_edit()
    local it = SET.rows[SET.sel]
    if not it or not it.key then return end
    if it.typ == "bool" then set_adjust(1); return end
    local ok, input = pcall(require, "mp.input")
    if not ok or not input or not input.get then
        SET.note = "Typing needs mpv ≥ 0.38 — use ‹ › or edit the conf file"
        set_draw(); return
    end
    input.get({
        prompt = it.label .. " >",
        default_text = SET.vals[it.key] or "",
        submit = function(text)
            input.terminate()
            set_submit(it, text)
        end,
    })
end

-- Quit and relaunch so every saved knob takes effect. The helper waits for the
-- whole app to wind down before launch.sh runs again; "confi[g]" keeps the
-- helper's own command line from matching the pattern it greps for.
function set_restart()
    SET.note = "Restarting…"; set_draw()
    mp.commandv("run", "bash", "-c",
        '(for i in $(seq 1 60); do pgrep -f "Screensaver-App/confi[g]" >/dev/null || break; sleep 0.5; done; '
        .. 'sleep 1; exec "' .. APP_DIR .. '/launch.sh") >/dev/null 2>&1 &')
    mp.add_timeout(0.4, function() mp.command("quit") end)
end

function set_bind()
    local function wrap(fn)
        return function()
            if bo_wake() then return end
            set_arm(); fn()
        end
    end
    mp.add_forced_key_binding("UP",         "ss-set-up",    wrap(function() set_move(-1) end), { repeatable = true })
    mp.add_forced_key_binding("DOWN",       "ss-set-down",  wrap(function() set_move(1) end),  { repeatable = true })
    mp.add_forced_key_binding("WHEEL_UP",   "ss-set-wup",   wrap(function() set_move(-1) end))
    mp.add_forced_key_binding("WHEEL_DOWN", "ss-set-wdn",   wrap(function() set_move(1) end))
    mp.add_forced_key_binding("LEFT",       "ss-set-left",  wrap(function() set_adjust(-1) end), { repeatable = true })
    mp.add_forced_key_binding("RIGHT",      "ss-set-right", wrap(function() set_adjust(1) end),  { repeatable = true })
    mp.add_forced_key_binding("ENTER",      "ss-set-enter", wrap(set_edit))
    mp.add_forced_key_binding("KP_ENTER",   "ss-set-kpent", wrap(set_edit))
    mp.add_forced_key_binding("r",          "ss-set-rst",   wrap(set_restart))
    mp.add_forced_key_binding("ESC",        "ss-set-esc",   function() set_hide() end)
    -- Swallow clicks so they don't pause music / quit underneath the menu.
    mp.add_forced_key_binding("MBTN_LEFT",  "ss-set-clk",   wrap(function() end))
    mp.add_forced_key_binding("MBTN_RIGHT", "ss-set-rclk",  function() set_hide() end)
end

function set_unbind()
    for _, n in ipairs({ "ss-set-up", "ss-set-down", "ss-set-wup", "ss-set-wdn",
                         "ss-set-left", "ss-set-right", "ss-set-enter", "ss-set-kpent",
                         "ss-set-rst", "ss-set-esc", "ss-set-clk", "ss-set-rclk" }) do
        mp.remove_key_binding(n)
    end
end

function set_hide()
    SET.on = false
    SET.gen = SET.gen + 1
    set_unbind()
    SET.ov:remove(); SET.ov.data = ""
end

function set_show()
    if HELP and HELP.on then help_hide() end
    SET.vals = set_conf_read()
    -- A knob can exist in the code before its line exists in an older
    -- installed conf (the installer appends it on the next update). Show the
    -- real effective value instead of a blank: environment first, then the
    -- same built-in fallback the feature code uses (each def below mirrors
    -- an inline code default and nothing else — the conf stays the source
    -- of truth). Editing such a knob appends its line to the conf.
    for _, r in ipairs(SET.rows) do
        if r.key and SET.vals[r.key] == nil then
            SET.vals[r.key] = SET.cfg_orig(r.key) or r.def
        end
    end
    if not SET.rows[SET.sel] or not SET.rows[SET.sel].key then SET.sel = 2 end
    SET.note = ""
    SET.on = true
    set_bind()
    set_draw()
    set_arm()
end

mp.register_script_message("ss-settings", function()
    if bo_wake() then return end
    if SET.on then set_hide() else set_show() end
end)
