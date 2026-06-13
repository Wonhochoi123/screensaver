#!/bin/bash
# =============================================================================
#  mpv Photo & Video Screensaver — installer  (App/PC/TV agnostic)
#
#  Run it either way:
#    * curl -fsSL https://raw.githubusercontent.com/Wonhochoi123/screensaver/main/install.sh | bash
#    * git clone … && ./install.sh        (uses the local checkout's files)
#
#  When piped from curl there is no local source tree, so this script downloads
#  the repo tarball and installs the real files (config/*, app/*) from it. When
#  run from a checkout it uses the files sitting next to it.
#
#  All settings live in config/screensaver.conf — the single source of truth.
#  This installer SOURCES that file (so it runs on the exact same values every
#  runtime script will) and copies it into ~/Screensaver-App/config/. To change
#  a setting, edit config/screensaver.conf (in the repo, or the installed copy
#  at ~/Screensaver-App/config/screensaver.conf).
# =============================================================================
set -u

# -----------------------------------------------------------------------------
#  Locate the source tree (config/* and app/*). Use the local checkout when this
#  script runs from one; otherwise bootstrap by downloading the repo tarball.
# -----------------------------------------------------------------------------
REPO_TARBALL="https://github.com/Wonhochoi123/screensaver/archive/refs/heads/main.tar.gz"
SRC=""
if [ -n "${BASH_SOURCE:-}" ] && [ -f "${BASH_SOURCE:-/nonexistent}" ]; then
    SRC="$(cd "$(dirname "${BASH_SOURCE}")" && pwd)"
fi
if [ -z "$SRC" ] || [ ! -f "$SRC/config/screensaver.conf" ]; then
    echo "▶ Fetching screensaver source..."
    command -v curl >/dev/null 2>&1 || { echo "✗ curl is required to bootstrap." >&2; exit 1; }
    command -v tar  >/dev/null 2>&1 || { echo "✗ tar is required to bootstrap."  >&2; exit 1; }
    _SS_TMP="$(mktemp -d)"
    trap 'rm -rf "$_SS_TMP"' EXIT
    if ! curl -fsSL "$REPO_TARBALL" | tar -xz -C "$_SS_TMP"; then
        echo "✗ Failed to download or extract the source from $REPO_TARBALL" >&2
        exit 1
    fi
    SRC="$(echo "$_SS_TMP"/*/)"; SRC="${SRC%/}"   # the extracted screensaver-main/
fi
if [ ! -f "$SRC/config/screensaver.conf" ]; then
    echo "✗ Could not locate source files (looked in: $SRC)." >&2
    exit 1
fi

# install <relsrc> <dest> <mode>  — copy a source file into place with a mode.
copy_file() { install -m "$3" "$SRC/$1" "$2"; }

# -----------------------------------------------------------------------------
#  Load the central config (single source of truth). Sourcing resolves every
#  $VAR top-down, so from here the installer runs on the exact same values as
#  every runtime script. The file itself is copied into place verbatim below.
# -----------------------------------------------------------------------------
echo "▶ Loading config (config/screensaver.conf)..."
. "$SRC/config/screensaver.conf"
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

# Migrate the old "Maps" cache dir to its clearer name (preserves the ~390MB
# GeoNames DB, the minimap/QR caches, and the album-art thumbs — no re-download).
if [ -d "$DATA_DIR/Maps" ] && [ ! -e "$RES_DIR" ]; then
    mv "$DATA_DIR/Maps" "$RES_DIR"
fi

mkdir -p "$CFG" "$MEDIA_DIR" "$RES_DIR" "$RES_DIR/geo" "$OPT_DIR" "$MUSIC_DIR" "$TITLE_DIR" "$PLAYLIST_DIR" \
         "$HOME/.config/autostart" "$HOME/.local/share/applications" "$FONT_DIR"

# Music split: the slideshow plays Music/ScreenSaver, the briefing's bgm lives
# in Music/GrokMorning. Move any loose tracks sitting directly in Music/ into
# ScreenSaver/ (one-time), leaving these two subfolders.
mkdir -p "$MUSIC_DIR/ScreenSaver" "$MUSIC_DIR/GrokMorning"
find "$MUSIC_DIR" -maxdepth 1 -type f \
    \( -iname '*.mp3' -o -iname '*.flac' -o -iname '*.m4a' -o -iname '*.ogg' \
       -o -iname '*.opus' -o -iname '*.wav' -o -iname '*.aac' \) \
    -exec mv {} "$MUSIC_DIR/ScreenSaver/" \; 2>/dev/null || true

if [ -d "$BASE_DIR/_map" ]; then
    mv "$BASE_DIR/_map"/* "$RES_DIR/" 2>/dev/null || true
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

# Everything the package transaction provides, checked up front: when it is all
# already here (every re-install after the first), skip the package manager
# entirely — no apt/dnf metadata refresh, no sudo prompt, seconds instead of
# minutes. Anything missing -> full transaction as before.
deps_missing() {
    for c in "${REQUIRED_CMDS[@]}" xdotool; do
        command -v "$c" >/dev/null 2>&1 || return 0
    done
    command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1 || return 0
    python3 -c 'import qrcode, PIL' >/dev/null 2>&1 || return 0
    return 1
}

detect_pm() {
    for pm in dnf apt-get pacman zypper; do
        command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return; }
    done
    echo ""
}
INSTALL=""
PKGS=""
if deps_missing; then
    PM="$(detect_pm)"
else
    echo "▶ All dependencies already present — skipping package installation."
    PM="skip"
fi
case "$PM" in
  dnf)
    PKGS="mpv perl-Image-ExifTool python3 python3-qrcode python3-pillow curl qrencode ffmpeg socat playerctl pulseaudio-utils ImageMagick fontconfig xdotool unzip yt-dlp"
    INSTALL="sudo dnf install -y"
    ;;
  apt-get)
    PKGS="mpv libimage-exiftool-perl python3 python3-qrcode python3-pil curl qrencode ffmpeg socat playerctl pulseaudio-utils imagemagick fontconfig xdotool unzip yt-dlp"
    sudo apt-get update -y || true
    INSTALL="sudo apt-get install -y"
    ;;
  pacman)
    PKGS="mpv perl-image-exiftool python python-qrcode python-pillow curl qrencode ffmpeg socat playerctl libpulse imagemagick fontconfig xdotool unzip yt-dlp"
    INSTALL="sudo pacman -S --needed --noconfirm"
    ;;
  zypper)
    PKGS="mpv exiftool python3 python3-qrcode python3-Pillow curl qrencode ffmpeg socat playerctl pulseaudio-utils ImageMagick fontconfig xdotool unzip yt-dlp"
    INSTALL="sudo zypper install -y"
    ;;
  skip)
    ;;   # deps already satisfied above — nothing to install
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
    # Already installed: keep it. Skipping also avoids rewriting a font a running
    # mpv has mmap'd (overwriting mapped files can crash it with SIGBUS).
    if [ -s "$FONT_DIR/Montserrat-$w.ttf" ]; then
        got_font=1; continue
    fi
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
#  Install the config + app files from the source tree.
# =============================================================================
echo "▶ Installing config and app files..."

# config/  → $CFG
# screensaver.conf: on a FRESH install, lay it down. On an EXISTING install,
# keep every value the user has edited and only APPEND keys they don't have yet
# — so updates never clobber tunables (sleep hours, HUD sizes, …).
if [ -f "$CFG/screensaver.conf" ]; then
    _added=""
    while IFS= read -r _line; do
        case "$_line" in
            export\ *=*)
                _k="${_line#export }"; _k="${_k%%=*}"
                grep -qE "^[[:space:]]*export[[:space:]]+${_k}=" "$CFG/screensaver.conf" \
                    || _added="${_added}${_line}"$'\n'
                ;;
        esac
    done < "$SRC/config/screensaver.conf"
    if [ -n "$_added" ]; then
        printf '\n# --- new settings added by an update (see config/screensaver.conf in the repo for docs) ---\n%s' "$_added" >> "$CFG/screensaver.conf"
        echo "▶ Kept your screensaver.conf and appended new keys."
    fi
else
    copy_file config/screensaver.conf "$CFG/screensaver.conf" 0644
fi
copy_file config/input.conf       "$CFG/input.conf"       0644
sed -i "s#@@AUDIO_SOCK@@#${AUDIO_SOCK}#g" "$CFG/input.conf"   # inject socket path
copy_file config/photo.lua        "$CFG/photo.lua"        0644
copy_file config/mpv.conf         "$CFG/mpv.conf"         0644
copy_file config/grok-briefing.sh "$CFG/grok-briefing.sh" 0755
# Premade briefing greeting clips (play instantly while the first segment loads).
install -d -m 0755 "$CFG/welcome"
for w in "$SRC"/config/welcome/*; do [ -e "$w" ] && install -m 0644 "$w" "$CFG/welcome/"; done
copy_file config/build-minimap.sh "$CFG/build-minimap.sh" 0755
copy_file config/build-thumb.sh   "$CFG/build-thumb.sh"   0755
copy_file config/trash-media.sh   "$CFG/trash-media.sh"   0755
copy_file config/trash-music.sh   "$CFG/trash-music.sh"   0755
copy_file config/fetch-article.sh "$CFG/fetch-article.sh" 0755
copy_file config/build-title.sh   "$CFG/build-title.sh"   0755
copy_file config/build-geodb.sh   "$CFG/build-geodb.sh"   0755
copy_file config/geo-resolve.sh   "$CFG/geo-resolve.sh"   0755

# app/  → $APP_DIR
copy_file app/xmp-police.sh       "$APP_DIR/xmp-police.sh"   0755
copy_file app/vid-daemon.sh       "$APP_DIR/vid-daemon.sh"   0755
copy_file app/launch.sh           "$APP_DIR/launch.sh"       0755
copy_file app/idle-watcher.sh     "$APP_DIR/idle-watcher.sh" 0755

# =============================================================================
#  Autostart + manual launcher  (absolute paths baked from config)
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
StartupWMClass=mpv
EOF

# =============================================================================
#  Offline place database (build now if possible)
# =============================================================================
if command -v unzip >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    echo "▶ Building offline GeoNames place database (one-time)..."
    "$CFG/build-geodb.sh" || echo "⚠ Place DB build failed — you can re-run: $CFG/build-geodb.sh"
else
    echo "⚠ Skipping place DB build (need curl + unzip). Run later: $CFG/build-geodb.sh"
fi

# =============================================================================
#  Done
# =============================================================================
echo ""
echo "✅ Migration and Deployment finished!"
echo "Your structure is:"
echo "   App Code   : $APP_DIR"
echo "   Config     : $CFG/screensaver.conf  (edit this to change any setting)"
echo "   Media      : $MEDIA_DIR"
echo "   Caches     : $RES_DIR & $OPT_DIR"
echo "   Place DB   : $GEODB  (offline; rebuild with $CFG/build-geodb.sh)"
echo "                Place data © GeoNames, CC-BY 4.0 (https://www.geonames.org)"
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo ""
    echo "⚠ Reminder: still missing -> ${MISSING[*]}"
    echo "  Install those, then re-run this script before launching."
fi
