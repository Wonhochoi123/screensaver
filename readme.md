# Screensaver

A polished, **mpv-based photo & video screensaver** for Linux that turns your own
media into a chronological slideshow with a rich, glanceable HUD:

- 📅 **Chronological slideshow** of your photos and videos, with animated
  **month/year title cards** between sections.
- 🗺️ **Offline location HUD** — for geotagged photos it shows the city, region,
  GPS coordinates, a **minimap**, and a scannable **QR code** of the spot, all
  resolved from a local GeoNames database (no network, no API key at runtime).
- 🏛️ **Landmark labels you can cycle** — the nearest named landmarks are listed
  per photo; press `l` to step through them and the choice is remembered.
- 🎵 **Now-playing music** with album-art thumbnail, title/artist marquee, and a
  seek/progress bar — plays your own music folder alongside the slideshow.
- 🌙 **Quiet hours** that mute music + video on a schedule, plus an optional
  **idle blackout** that blanks the screen *without dropping the HDMI signal*.
- 🤖 **Optional AI "Morning Briefing"** (xAI Grok): a spoken weather / news /
  tech / finance / your-stocks briefing at a set time, with background music and
  on-screen captions.
- 🖥️ **Auto-launch when idle** (and a manual "Start Screensaver" launcher), with
  smart inhibitors so it never interrupts you while media is playing.
- ⚙️ **On-screen settings menu** — press `s` to change any option from the
  couch; no config-file editing required.

Everything is driven by your own files and **one config file** — no accounts, no
cloud, no telemetry.

---

## Requirements

- **Linux** with one of: `dnf`, `apt`, `pacman`, or `zypper` (the installer picks
  the right package list automatically).
- A desktop session — works on **X11** (full idle auto-launch via `xdotool`) and
  **Wayland** (idle auto-launch via the GNOME/Mutter idle monitor).
- The installer pulls in everything else: `mpv`, `ffmpeg`, `exiftool`,
  `python3` (+ qrcode/pillow), `qrencode`, `socat`, `playerctl`, `imagemagick`,
  `fontconfig`, and the Montserrat fonts.

The AI Morning Briefing is the **only** feature that needs the network, and only
while it runs. Everything else works fully offline.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Wonhochoi123/screensaver/main/install.sh | bash
```

Or clone and run it locally (it uses the checkout's files directly):

```bash
git clone https://github.com/Wonhochoi123/screensaver
cd screensaver && ./install.sh
```

The installer:

1. installs/verifies all dependencies,
2. creates the app under **`~/Screensaver-App/`**,
3. registers an **autostart idle-watcher** and a **"Start Screensaver"** launcher,
4. builds the **offline place database** (one-time), and
5. installs the **Montserrat** fonts.

**Re-run it any time to update.** On an existing install it never clobbers your
settings — it keeps your `screensaver.conf` and only appends keys that are new.

---

## Add your media

Drop files into these folders (created by the installer):

| Put this here | Folder |
|---|---|
| **Photos & videos** | `~/Screensaver-App/Data/Library/Media/` |
| **Slideshow music** | `~/Screensaver-App/Data/Library/Music/ScreenSaver/` |
| **Briefing background music** (optional) | `~/Screensaver-App/Data/Library/Music/GrokMorning/` |

Notes:

- **Order is chronological**, by each file's capture date (EXIF) or modification
  time. Animated **month/year title cards** are generated automatically between
  sections.
- **Location HUD** (city / coords / minimap / QR / landmarks) appears for photos
  that contain **GPS EXIF tags**. Photos without GPS simply show no location HUD.
- **Videos** are transcoded in the background for smooth playback (cached under
  `Data/Optimized_Vids/`); the first pass may take a little while.
- Supported media: `jpg/jpeg/png` images and `mp4/mkv/mov/webm` videos; music in
  `mp3/flac/m4a/ogg/opus/wav/aac`.
- **Empty library?** The screensaver shows a guidance screen telling you where to
  put your photos, and starts automatically the moment files appear.

---

## Running it

- **Automatically:** the autostart **idle-watcher** launches the screensaver
  after `IDLE_TIMEOUT_MS` of inactivity (default 5 min). It will *not* start while
  music/video is playing or while an app is inhibiting the screensaver.
- **Manually:** open **"Start Screensaver"** from your app launcher, or run
  `~/Screensaver-App/launch.sh`.
- **Quit:** press `Esc` or `q`.

---

## Controls

### Slideshow

| Key / action | Does |
|---|---|
| `→` / `←` | Next / previous item |
| Mouse wheel | Step through the slideshow (or scroll the song chooser when open) |
| `Space` / `p` / media keys | Pause / resume the **screensaver** (freezes the slideshow + the music) |
| `↑` / `↓` | Zoom the **minimap** in / out |
| `Page Down` / `Page Up` | Jump to next / previous **month** |
| `End` / `Home` | Jump to next / previous **year** |
| `l` | Cycle the **landmark** label for the current photo (remembered) |
| `h` / `?` | Toggle the on-screen **controls cheat-sheet** |
| `s` | Open the **settings menu** — edit every option from the screen |
| `Delete` | Move the current photo/video to the trash |
| `=` / `-` | Slideshow volume up / down |
| `Esc` / `q` | Quit |

### Mouse

- **Click the album-art thumbnail** (top-left) to pause/play the music.
- **Click the music marquee** to open the song chooser; wheel to scroll, click a
  row to play it, or click the **× on the right** of a row to remove that track
  from the rotation (the file is moved to the trash, so it won't come back).
- **Hover the month bar** (bottom) to see a month label; **left-click** it to jump
  to the photo at that point; **right-click** it to jump to that month's start.
- Quit with **`Esc`** or **`q`** (right-click no longer quits — too easy to do by
  accident).

### Morning Briefing (only while a briefing plays)

| Key | Does |
|---|---|
| `←` / `→` | Previous / next item |
| `Space` | Pause / resume the voice |
| `↑` / `↓` | Scroll the right pane |
| `x` | Stop the briefing |
| `c` | Hide / show captions |
| `.` `,` `b` | Old aliases for next / previous / pause (still work) |

While a briefing plays the arrows, `Space`, and the wheel do the obvious thing —
no need to remember the letter keys.

The briefing's content comes **straight from the news, not from an AI**. Curated,
politically **balanced** RSS feeds (BBC World, CNBC, The Hill, Christian Science
Monitor for top news; Ars Technica, The Verge, TechCrunch, Engadget for tech)
supply the top headlines — the feeds *are* the editorial judgment, so links are
real, balanced, and always open. Each item is **spoken as the headline plus the
feed's own summary sentence**, so the audio has real context while the on-screen
line stays a clean headline (and its full article opens on the right). Weather
comes from [Open-Meteo](https://open-meteo.com), live ticker prices from Yahoo
Finance, and the sign-off is a friendly template. **xAI is used only to read the
lines aloud** (text-to-speech) — no web-search or language-model call decides or
writes the news. Feeds and how many headlines to include are configurable in
`screensaver.conf` (`GROK_NEWS_FEEDS`, `GROK_TECH_FEEDS`, `GROK_NEWS_N`,
`GROK_TECH_N`).

While it plays the screen **stays split**: the **left** lists every one-liner in
the **current category** stacked together, with the line being read **right now
highlighted in blue** and the rest dimmed, so you can see where you are; the
**right** auto-fetches and shows that line's **real source article**, distilled
to readable text. The one exception is the **weather** item, whose right pane is a
**live weather card** — a vector condition glyph + big temperature, today's
high/low, wind, humidity, sunrise and sunset, and an **8-hour strip with a
temperature sparkline**. The **markets** items are special too: the left half
draws a **Google-Finance-style stock card** — ticker chips (the active one in
blue), the company name, big price, today's change, a line chart with clickable
**1D / 1M / 1Y range buttons** (it gently auto-cycles them until you click one;
each is labelled with its % move, and the 1-day view has a dashed previous-close
line), and a day/52-week range + volume row — while the right half
shows a **one-paragraph Grok analysis** of that ticker — what moved it, the
context, and a **clear, opinionated recommendation** (Buy / Accumulate / Hold /
Trim / Sell with the levels it's watching, reasoned over the real live numbers).
It's the only place AI touches content. After your own tickers, a **WATCHLIST**
(`GROK_WATCHLIST`, on by default) adds the day's biggest large-cap movers — real
Nasdaq-100 movers data (not an AI guess), excluding your own tickers — each its
own live card + analysis. Every briefing screen also shows a **chapter label**
top-left (WEATHER, TOP NEWS, MARKETS, STOCKS TO WATCH…) so you always know which
part you're on. The chat model is auto-resolved — if
`GROK_MODEL` is wrong it falls back to the first working grok model on your key.
If the analysis ever comes up blank, run
`~/Screensaver-App/config/grok-briefing.sh --stocktest TSLA` for a one-shot
diagnosis (resolved model, the live card, the analysis, and any raw API error).
Live quotes + the intraday line come from **CNBC + Nasdaq** (keyless, and not
rate-limited like Yahoo), cached per run. Nothing to click — it tracks the voice line-by-line,
fading softly as each new category appears, and the wheel scrolls a long article.
A partisan or unscrapable link is dropped on both sides (so the right pane never
shows a slanted article); items with no source (markets, the sign-off) just leave
the right side clean. Each one-liner is its own spoken clip, so `←` / `→` step one
item at a time, and the briefing ends on a closing remark rather than cutting off.

The **"MORNING BRIEFING"** badge at center-top reveals on mouse-hover. Click it
for a **Replay / Refresh** chooser (or **Generate** if none is cached yet) to run
one on demand; a small caption shows **when the last run was made**. **Replay**
plays that last run instantly (no network needed); **Refresh** builds a brand-new
run but keeps the previous ones, so each generation is saved under
`Data/Briefing/<date>/<time>/` and a failed refresh never loses the last good
briefing. When the screensaver is idle, a small line under the clock shows
**what's coming up** — the next briefing and the quiet-hours window — with the
sooner of the two on top and brighter as it approaches.

---

## The HUD, explained

- **Top-left:** now-playing **album art** + **title/artist** (hover to reveal the
  full text) + a thin **seek bar**.
- **Top-right:** the photo's **date** and **region** (state / country).
- **Bottom-center:** the **city** headline, with the optional **landmark** line
  above it (cycle with `l`).
- **Bottom corners:** the **QR code** (left) and **minimap** (right), each a
  little stack — the square, a label line under it (the QR's scan invitation /
  the map's `ZOOM: 1:x` scale), and the **GPS coordinates** at the bottom
  (zoom with `↑`/`↓`).
- **Very bottom:** a hair-thin **now-playing progress** strip and a **month bar**
  showing your position across the whole timeline.

---

## Quiet hours & idle blackout

Configured in `screensaver.conf`:

- **Quiet hours** (`MUSIC_SLEEP_START` / `MUSIC_SLEEP_END`, 24h `HH:MM`): during
  this window the **music is paused and the video volume is muted**, and stays
  that way until the window ends. Overnight windows (e.g. `20:00`→`06:00`) are
  fine. Leave both empty to disable.
- **Idle blackout** (`BLACKOUT_ENABLE`, `BLACKOUT_IDLE_MIN`): *during quiet hours
  only*, after `BLACKOUT_IDLE_MIN` minutes with no input the screen is painted
  **black to look "off."** Crucially, mpv keeps rendering the black frame, so the
  **HDMI signal never drops** — your TV won't lose the source and you won't have
  to re-select the input in the morning. Any mouse move / key / click, or a
  scheduled briefing, wakes it instantly. Set `BLACKOUT_ENABLE=no` to disable.

---

## AI Morning Briefing (optional, xAI Grok)

A spoken briefing — **weather, news, tech/finance, and your stocks** — plays at
`GROK_TIME` with background music (from `Music/GrokMorning`) and on-screen
captions. While it runs the slideshow pauses to a calm blurred backdrop. It
pre-generates a few minutes before `GROK_TIME` and only fires while the
screensaver is running.

**Setup:**

1. Set your xAI API key in your **session environment** so the autostart/launcher
   inherit it. For most desktops, add this line to `~/.profile` (or
   `~/.config/environment.d/xai.conf` on systemd-user sessions) and log out/in:

   ```bash
   export XAI_API_KEY="your-xai-key-here"
   ```

   > Keep this key private — don't commit it or paste it anywhere public.

2. In `screensaver.conf`, enable and personalize it:

   ```bash
   export GROK_BRIEFING=1
   export GROK_TIME="07:30"                  # 24h HH:MM
   export GROK_LOCATION="Mooresville, NC"    # used for the weather segment
   export GROK_TICKERS="TSLA, AMD, PLTR"     # stock segment; empty skips it
   ```

3. Drop a few tracks into `~/Screensaver-App/Data/Library/Music/GrokMorning/` for
   the background bed.

If `XAI_API_KEY` is missing or there's no network, the feature simply does
nothing (no errors). Voice, model, volumes, fades, and timing are all tunable —
see the `GROK_*` keys below.

---

## Offline place database (GeoNames)

The location HUD resolves names entirely offline from a local SQLite DB built
once by `geo/build-geodb.sh`. No API key, no runtime network.

- `GEONAMES_COUNTRIES` — space-separated ISO country codes to index (small, fast,
  e.g. `"US CA GB"`). **Leave it empty to index the whole planet** (~390 MB
  download, larger DB).
- `GEO_LOCALIZE` — show place names in their **own script** for these languages
  instead of romanized. Default `'ko'` makes Korean places display in Korean
  (서울, 경복궁, 대한민국) in a proper Hangul font; the city, province, country and
  landmark all localize. It pulls the correct name from GeoNames'
  `alternateNamesV2` table (preferred, non-historic — so Seoul → 서울, not the
  old name 한양), adding a one-time ~200 MB download at build time. It matches any
  name written in the language's script, not just rows tagged with the language
  code (GeoNames often leaves Korean names untagged), so ~9 in 10 Korean places —
  and nearly all sizable cities — resolve to Korean; the rest fall back to
  romanized where GeoNames simply has no local name. Empty = romanized everywhere
  (the original behaviour). Codes map to their country (`ko`→KR, `ja`→JP…).
- `GEO_BOUNDARIES` — resolve the **city** by which administrative boundary
  actually *contains* the photo's coordinates (point-in-polygon), instead of
  snapping to the nearest populated point. Without it, a megacity's huge
  population lets it claim neighbouring towns (a photo in Misa/Hanam came out as
  "Seoul"). `'*'` (default) covers the **whole planet** via
  [geoBoundaries](https://www.geoboundaries.org)' CGAZ composite (CC-BY; one-time
  ~160 MB, parsed with a built-in pure-Python shapefile reader — no extra
  dependency). Or give a space/comma list of ISO-2 codes (`'KR JP'`) for a
  smaller index. Naming is a **hybrid**: the polygon decides which unit you're in,
  then the city is the nearest *town* (GeoNames `PPL*` — neighbourhood sections
  like a 동, an arrondissement, or "Times Square" are skipped) **inside** it. So
  ADM2 = county (US "Santa Clara") still shows the town you're in (San Jose /
  Cupertino), and ADM2 = department (France "Yvelines") shows Versailles; where
  places are sparse it falls back to the admin name (KR 하남시). Polygon holes are
  honoured (경기도 excludes Seoul); an R-tree keeps lookups instant across ~53k
  polygons. Empty = nearest-point only.
- `GEO_POI_SOURCE` — where **landmarks** come from (GeoNames' own list is thin and
  skewed — no Lotte World Tower, full of minor temples):
  - `'hybrid'` (default) — **offline** OpenStreetMap for your `GEO_POI_REGIONS`
    (reliable, no network, accurate — e.g. Korea) and **live Overpass only for
    photos outside** those regions. Best of both: your usual area is offline +
    instant + dependable, travel still gets worldwide POIs. Falls back to GeoNames
    features if neither has anything.
  - `'overpass'` — always query **OpenStreetMap live** (Overpass), whole world, no
    download — but depends on the public Overpass servers and sends each photo's
    GPS to them.
  - `'offline'` — ONLY the downloaded regions; never goes online.
  - `'none'` — GeoNames features only.
  - Both OSM paths keep only real attraction/natural categories with a name; the
    place-of-worship layer is excluded so minor temples don't dominate. No
    popularity score — purely OSM's own tags.
- `GEO_POI_REGIONS` — [Geofabrik](https://download.geofabrik.de) slugs to download
  for offline POIs (default `'asia/south-korea'`; e.g. add `'asia/japan'`). Used by
  `hybrid` and `offline`.
- Rebuild any time with `~/Screensaver-App/config/build-geodb.sh`, or bump
  `GEODB_VERSION` to force a one-time rebuild on the next launch.

Place data © [GeoNames](https://www.geonames.org), CC-BY 4.0.

---

## Record a demo video (lag-free)

```
~/Screensaver-App/config/make-demo.sh [seconds] [output.mp4]
# e.g. make-demo.sh 60 ~/demo.mp4        (defaults: 60s, ~/screensaver-demo.mp4)
```

Normal screen recorders stutter because the H.264 encoder fights the screensaver
for the machine in real time. `make-demo.sh` removes that contention so the clip
stays smooth at your screen's **native HD resolution**:

- If your GPU has a hardware encoder (**NVENC / VAAPI / QSV**) the GPU does the
  encoding and the CPU stays free — it probes each one and uses the first that
  actually works.
- Otherwise it captures near-lossless at the cheapest CPU setting, then
  **re-encodes the polished HD file offline** (after recording), so the capture
  phase never lags.

Knobs (env): `DEMO_FPS` (60), `DEMO_RES` (e.g. `1920x1080`; default = whole
screen), `DEMO_AUDIO=0` to skip sound, `DEMO_LAUNCH=1` to start the screensaver
first and stop it after. Have the screensaver on screen before you run it (or use
`DEMO_LAUNCH=1`). X11/XWayland only — on a pure Wayland session it points you at
`wf-recorder` (which also hardware-encodes).

---

## Settings menu (press `s`)

You don't need a text editor to configure anything. Press **`s`** while the
screensaver is running and a settings panel opens with every option, grouped
the same way as the tables below:

- **`↑` / `↓`** (or the mouse wheel) moves between options.
- **`←` / `→`** nudges the selected value — numbers step within a sane range,
  switches toggle, times move in 5–15 minute steps.
- **`Enter`** lets you **type** a value (briefing location, stock tickers, an
  exact time…). Empty is allowed where it means "off".
- **`Esc`** closes the menu. **`r`** restarts the screensaver in place.

Every change is saved **immediately** into `screensaver.conf` (comments and
layout preserved — the file stays human-editable). Options the running show
can pick up — HUD text sizes, volume, photo duration, quiet hours, the idle
blackout — say *"applied live"* and take effect on the spot. The rest say
*"applies next start"*; press **`r`** to restart right away, or just let it
apply next time the screensaver comes up. Changing the indexed country list
also bumps `GEODB_VERSION` for you so the place database rebuilds.

The menu contains **every behavioural option**. The only conf entries not in
it are the install paths (`APP_DIR`, `MEDIA_DIR`, …) and the internal
database fields (`GEODB`, `GEODB_VERSION` — managed for you), which can still
be edited in the file directly. If a brand-new option isn't in your conf file
yet, the menu shows its built-in default and writes the line on first change.

## Configuration reference

**Everything is controlled by one file:** `config/screensaver.conf` (repo copy)
which installs to `~/Screensaver-App/config/screensaver.conf`. The settings
menu above edits the installed copy for you; to do it by hand, edit the
**installed copy** to change your running setup immediately, or the **repo
copy** to change what a fresh install lays down. Every script sources this
file, so a value set here applies everywhere.

> HUD text sizes are **fractions of the screen height** (e.g. `0.030` ≈ 3% of
> height), so they look the same on any display. Raise to enlarge.

### Playback / behaviour

| Key | Default | Meaning |
|---|---|---|
| `PHOTO_DURATION` | `10` | Seconds each still photo is shown (videos play in full) |
| `VOLUME` | `70` | mpv startup volume (0–100) |
| `IDLE_TIMEOUT_MS` | `300000` | Idle time before auto-launch (ms; 300000 = 5 min) |
| `MIN_LOAD_SECS` | `2` | Minimum time the "please wait" screen stays up |
| `VID_RESCAN_SECS` | `300` | How often new videos are picked up for transcoding |

### HUD text & layout

| Key | Default | Meaning |
|---|---|---|
| `HUD_MUSIC_FS` | `0.026` | Now-playing marquee size |
| `HUD_DATE_FS` | `0.026` | Date (top-right) size |
| `HUD_REGION_FS` | `0.026` | Region (top-right) size |
| `HUD_CITY_FS` | `0.066` | City headline size |
| `HUD_COORD_FS` | `0.025` | GPS coordinates size |
| `HUD_TEXT_BLUR` | `0.25` | Text shadow blur/spread (× font size) |
| `HUD_TEXT_GLOW` | `0.001` | Text shadow strength (× font size) |
| `MUSIC_WIN_FRAC` | `0.2` | Marquee width (fraction of screen width) |
| `HUD_MAP_FRAC` | `0.27` | Minimap + QR size (fraction of height) |
| `HUD_THUMB` | `1` | Album-art thumbnail on (1) / off (0) |
| `HUD_MAP_ZOOMS` | `"6 7 8 9 10 11 12 13 14 15 16"` | Minimap zoom levels (`↑`/`↓` cycles them) — list as many as you like; during playback the zoom auto-steps inward, giving each level an equal share of the item's play time |
| `HUD_RING_COLORS` | `"#FFFFFF #4FC3F7"` | GPS ring colour **gradient stops** — the ring blends from the first colour to the last across your zoom levels; two colours (start → destination) are all you need |
| `HUD_AUTO_ZOOM` | `yes` | Auto-step the minimap inward while each item plays (`yes`/`no`); the approximate map scale (e.g. `ZOOM: 1:150K` for a town view) shows above the map, and `↑`/`↓` always zoom manually |
| `HUD_QR_TEXT` | `"SCAN TO VISIT THIS SPOT"` | Invitation shown above the QR code (scanning opens the spot in Google Maps); empty hides it |

### Quiet hours & blackout

| Key | Default | Meaning |
|---|---|---|
| `MUSIC_SLEEP_START` | `"20:00"` | Quiet hours start (24h `HH:MM`; empty disables) |
| `MUSIC_SLEEP_END` | `"6:00"` | Quiet hours end |
| `BLACKOUT_ENABLE` | `yes` | Idle blackout during quiet hours (`yes`/`no`) |
| `BLACKOUT_IDLE_MIN` | `15` | Minutes of no input before going black |

### Morning briefing (Grok)

| Key | Default | Meaning |
|---|---|---|
| `GROK_BRIEFING` | `1` | Enable (1) / disable (0) |
| `GROK_TIME` | `"05:39"` | When it plays (24h `HH:MM`) |
| `GROK_LOCATION` | `"Mooresville, NC"` | Location for the weather segment |
| `GROK_TICKERS` | `"TSLA, AMD, PLTR, BTC, SPCX"` | Stocks/crypto segment (empty skips it). Stock tickers, crypto by name (BTC, ETH, SOL…), and private-market names CNBC carries (e.g. `SPCX` = SpaceX). |
| `GROK_MODEL` | `"grok-4.3"` | xAI model |
| `GROK_VOICE` | `"ara"` | Voice |
| `GROK_BGM_VOLUME` | `60` | Briefing music volume (0–100) |
| `GROK_VOICE_VOLUME` | `150` | Spoken-voice gain (% of recorded; >100 louder) |
| `GROK_SPEAK_DELAY` | `5` | Seconds of music before the first words |
| `GROK_SECTION_GAP` | `2` | Seconds of music between sections |
| `GROK_FADE_IN` | `1.2` | Soft-drop of slideshow music when entering |
| `GROK_FADE_OUT` | `2.5` | Soft-drop of briefing music when leaving |
| `GROK_FADE_RESUME` | `2.0` | Soft resume of slideshow music after |

> `XAI_API_KEY` is **not** stored in this file — set it in your shell/session
> environment (see the briefing setup above).

### Place database

| Key | Default | Meaning |
|---|---|---|
| `GEONAMES_COUNTRIES` | `''` | ISO country codes to index; empty = whole planet |
| `GEO_LOCALIZE` | `'ko'` | Languages whose places show in their own script (ko→Korean); empty = romanized |
| `GEO_BOUNDARIES` | `'*'` | Point-in-polygon city resolution; `'*'` = whole planet, or ISO-2 list; empty = nearest-point |
| `GEO_POI_SOURCE` | `'hybrid'` | Landmarks: `hybrid` (offline regions + Overpass elsewhere), `overpass`, `offline`, `none` |
| `GEO_POI_REGIONS` | `'asia/south-korea'` | Geofabrik slugs to download for offline POIs (`hybrid`/`offline`) |
| `GEODB_VERSION` | `'15'` | Bump to force a one-time DB rebuild |

(Path keys like `APP_DIR`, `DATA_DIR`, `MEDIA_DIR`, `MUSIC_DIR`, `GEODB`, … are
also defined at the top of the file; they keep `$HOME`/`$VAR` references so the
config stays portable across machines.)

---

## Repository layout

These are the real files, installed as-is (there is no generated bundle). The
repo groups sources by subsystem, but the installer flattens them into the
layout the running app expects — `daemons/` → `~/Screensaver-App/`, everything
else → `~/Screensaver-App/config/` — so the repo grouping is purely for humans
and changes nothing at runtime.

```
install.sh              deps, folders, fonts, autostart, DB build

config/                 core config            → ~/Screensaver-App/config/
  screensaver.conf        single source of truth for ALL settings
  mpv.conf  input.conf    mpv options + key bindings
hud/                    the mpv HUD            → ~/Screensaver-App/config/
  photo.lua               main HUD / slideshow script
  photo_modules/ssfmt.lua pure formatting/parsing helpers (required by photo.lua)
daemons/                long-running procs     → ~/Screensaver-App/
  launch.sh               starts the screensaver (orchestrates everything)
  idle-watcher.sh         auto-launches after idle (X11 / Wayland)
  vid-daemon.sh           background video transcoder
  xmp-police.sh           writes per-photo location metadata (.xmp) from GPS
briefing/               AI morning briefing    → ~/Screensaver-App/config/
  grok-briefing.sh        the briefing engine (TTS + playback)
  news-build.py           assembles the briefing from RSS feeds (no AI)
  stock-card.sh  weather-card.sh   live market + weather cards
  fetch-article.sh        pulls the source article for the right pane
  welcome/                greeting clips played while the first briefing loads
geo/                    offline location       → ~/Screensaver-App/config/
  build-geodb.sh          builds the offline GeoNames place DB
  geo-resolve.sh          lat/lon → landmark + city/region
media/                  asset builders + media ops  → ~/Screensaver-App/config/
  build-title.sh          animated month/year title cards
  build-minimap.sh  build-thumb.sh   minimap/QR + album-art generators
  trash-media.sh  trash-music.sh     Delete-key handlers
tools/                  standalone utilities you run by hand (not part of the loop)
  fix-flac.sh             one-off FLAC repair
  make-demo.sh            demo-clip recorder  (installed to config/ so you can run it)
```

`~/Screensaver-App/Data/` splits in two: **`Library/`** holds *your* files —
`Media/` (photos + videos, with their `.xmp`/`.txt` sidecars) and `Music/` — and
is the only folder you ever manage. **`Generated/`** holds everything the app
builds (transcoded videos, minimaps/QR, the place DB, title cards, fonts, the
playlist, briefing cache); it's safe to delete and rebuilds itself.

---

## Updating & uninstalling

- **Update:** re-run `install.sh` (curl one-liner or from a clone). Your
  `screensaver.conf` is preserved; only brand-new keys are appended.
- **Stop auto-launch:** remove `~/.config/autostart/idle-watcher.desktop`.
- **Remove the app:** delete `~/Screensaver-App/`, the two `.desktop` files
  (`~/.config/autostart/idle-watcher.desktop` and
  `~/.local/share/applications/screensaver-now.desktop`), and
  `~/.config/fontconfig/conf.d/00-screensaver-fonts.conf`.

---

## Troubleshooting

- **No location HUD on a photo** → it probably has no GPS EXIF data, or the place
  DB hasn't finished building yet (it builds in the background on first launch).
- **Landmarks are blank / wrong** → press `l` to cycle candidates; rebuild the DB
  with `geo/build-geodb.sh` if you changed `GEONAMES_COUNTRIES`.
- **Briefing never runs** → confirm `XAI_API_KEY` is in the session environment
  (`echo "${XAI_API_KEY:+set}"` should print `set`), `GROK_BRIEFING=1`, and you
  have a network connection.
- **It won't auto-launch** → it's inhibited while media plays or an app blocks the
  screensaver; also check `IDLE_TIMEOUT_MS`.
- **A setting didn't apply** → edit the **installed** copy at
  `~/Screensaver-App/config/screensaver.conf` (the repo copy only affects fresh
  installs).

---

## Credits

Place data © [GeoNames](https://www.geonames.org) (CC-BY 4.0). Fonts:
[Montserrat](https://github.com/JulietaUla/Montserrat) by Julieta Ulanovsky.
Built on [mpv](https://mpv.io) and [ffmpeg](https://ffmpeg.org). The Morning
Briefing uses the [xAI](https://x.ai) Grok API.
