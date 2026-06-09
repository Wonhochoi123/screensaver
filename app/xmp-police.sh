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
        elif [ -n "${GEODB:-}" ] && [ -s "$GEODB" ] && [ "$GEODB" -nt "$xmp" ]; then stale=1
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

    # GeoNames (offline DB) is the PRIMARY geocoder; ExifTool's Geolocation and
    # any embedded EXIF/IPTC tags are only fallbacks when GeoNames has no match.
    landmark, gcity, gstate, gcountry = resolve_geo(lat, lon)
    city    = gcity    or e.get("GeolocationCity")    or e.get("City") or ""
    state   = gstate   or e.get("GeolocationRegion")  or e.get("State") or e.get("Province-State") or ""
    country = gcountry or e.get("GeolocationCountry") or e.get("Country") or ""

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
