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
#  Single source of truth: the export block below. Each value is declared ONCE
#  in reference-preserving form — SINGLE-quoted, so $HOME / $APP_DIR stay
#  literal here (templates, not yet resolved). It is written to
#  config/screensaver.conf through an UNQUOTED heredoc: one round of expansion
#  turns $APP_DIR into "$HOME/Screensaver-App", which still carries the $HOME
#  reference, so the written file stays portable (no machine-specific absolute
#  paths). The installer then SOURCES that file, resolving every level top-down,
#  and every runtime script sources it too. Nothing downstream hardcodes a path.
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
export GEONAMES_COUNTRIES=''
export GEODB='$MAP_DIR/geo/geonames.sqlite'
# Bump GEODB_VERSION whenever the DB's contents change (country set or the
# landmark feature-code table). On the next launch a version mismatch forces a
# one-time rebuild so the change actually takes effect.
export GEODB_VERSION='6'

# -----------------------------------------------------------------------------
#  Locate the source tree (config/* and app/*). Use the local checkout when this
#  script runs from one; otherwise bootstrap by downloading the repo tarball.
# -----------------------------------------------------------------------------
REPO_TARBALL="https://github.com/Wonhochoi123/screensaver/archive/refs/heads/main.tar.gz"
SRC=""
if [ -n "${BASH_SOURCE:-}" ] && [ -f "${BASH_SOURCE:-/nonexistent}" ]; then
    SRC="$(cd "$(dirname "${BASH_SOURCE}")" && pwd)"
fi
if [ -z "$SRC" ] || [ ! -f "$SRC/config/photo.lua" ]; then
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
if [ ! -f "$SRC/config/photo.lua" ]; then
    echo "✗ Could not locate source files (looked in: $SRC)." >&2
    exit 1
fi

# install <relsrc> <dest> <mode>  — copy a source file into place with a mode.
copy_file() { install -m "$3" "$SRC/$1" "$2"; }

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
export GEODB_VERSION="$GEODB_VERSION"
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
#  Install the app files from the source tree.
# =============================================================================
echo "▶ Installing config and app files..."

# config/  → $CFG
copy_file config/input.conf       "$CFG/input.conf"       0644
sed -i "s#@@AUDIO_SOCK@@#${AUDIO_SOCK}#g" "$CFG/input.conf"   # inject socket path
copy_file config/photo.lua        "$CFG/photo.lua"        0644
copy_file config/mpv.conf         "$CFG/mpv.conf"         0644
copy_file config/build-minimap.sh "$CFG/build-minimap.sh" 0755
copy_file config/trash-media.sh   "$CFG/trash-media.sh"   0755
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
echo "   Caches     : $MAP_DIR & $OPT_DIR"
echo "   Place DB   : $GEODB  (offline; rebuild with $CFG/build-geodb.sh)"
echo "                Place data © GeoNames, CC-BY 4.0 (https://www.geonames.org)"
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo ""
    echo "⚠ Reminder: still missing -> ${MISSING[*]}"
    echo "  Install those, then re-run this script before launching."
fi
