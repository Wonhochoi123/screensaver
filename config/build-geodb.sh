#!/bin/bash
set -u
SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || { echo "build-geodb: missing config $SS_CONF — run the installer." >&2; exit 1; }

command -v curl  >/dev/null 2>&1 || { echo "build-geodb: curl not found."  >&2; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "build-geodb: unzip not found." >&2; exit 1; }

BASE="https://download.geonames.org/export/dump"
WORK="$RES_DIR/geo"; mkdir -p "$WORK"
CACHE="$WORK/cache"; mkdir -p "$CACHE"     # persistent: raw downloads live here
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Download to the persistent cache only when the file is missing. This is what
# stops the ~390MB GeoNames dump from being re-fetched every time the landmark
# scoring changes — a rebuild then just re-runs the local processing below.
# Force a fresh pull anytime with:  REFRESH=1 build-geodb.sh
fetch_cached() {   # $1 = remote filename, $2 = local cache path
    if [ "${REFRESH:-0}" != 1 ] && [ -s "$2" ]; then
        echo "  ✓ using cached $(basename "$2")"
        return 0
    fi
    echo "▶ Downloading $1 ..."
    curl -fsSL -o "$2.part" "$BASE/$1" && mv -f "$2.part" "$2"
}

# Stream a zip member through a FIFO instead of extracting it to disk: the
# whole-planet allCountries.txt (~1.6GB) and alternateNamesV2.txt (~2GB) would
# otherwise need ~3.6GB of temp space and fill a small disk. The reader (python)
# consumes each sequentially, so a pipe is all that's needed.
#   stream_member <zip> <member> <dest-var>   -> sets <dest-var> to a fifo path
_FIFO_N=0
stream_member() {
    _FIFO_N=$((_FIFO_N + 1)); local f="$TMP/stream_${_FIFO_N}.fifo"
    rm -f "$f"; mkfifo "$f" 2>/dev/null || return 1
    unzip -p "$1" "$2" > "$f" 2>/dev/null &
    printf -v "$3" '%s' "$f"
}

echo "▶ Fetching GeoNames support tables..."
fetch_cached "admin1CodesASCII.txt" "$CACHE/admin1.txt"  || { echo "download failed (admin1)"; exit 1; }
fetch_cached "countryInfo.txt"      "$CACHE/country.txt" || { echo "download failed (countryInfo)"; exit 1; }

# Localized names (e.g. Korean for KR places): pull GeoNames' alternateNamesV2,
# which is language-tagged with preferred/historic flags. Normalize the config
# list ("ko" / "ko,ja" / "ko ja") to a comma list; empty = romanized everywhere.
LOCALIZE="$(printf '%s' "${GEO_LOCALIZE:-}" | tr ' ' ',' | tr -s ',' | sed 's/^,//;s/,$//')"
ALTFILE=""
if [ -n "$LOCALIZE" ]; then
    echo "▶ Localized place names enabled ($LOCALIZE) — fetching alternateNamesV2 (one-time ~200MB)..."
    if fetch_cached "alternateNamesV2.zip" "$CACHE/alternateNamesV2.zip" \
        && stream_member "$CACHE/alternateNamesV2.zip" alternateNamesV2.txt ALTFILE; then
        :
    else
        ALTFILE=""
        echo "⚠ could not fetch/stream alternateNamesV2 — names will stay romanized."
    fi
fi

# Administrative boundary polygons (point-in-polygon city resolution). Without
# them the resolver picks the nearest populated POINT, so a megacity's huge
# population lets it claim neighbouring towns (Misa/Hanam reported as "Seoul").
# With them, the city is whichever admin polygon actually CONTAINS the point.
# '*' => the whole planet via geoBoundaries' CGAZ composite (one ~160MB shapefile
# per level); otherwise a per-country list pulls gbOpen GeoJSON. Both feed a
# manifest the Python below reads: "kind<TAB>level<TAB>arg1<TAB>arg2" where
# kind=shp -> arg1=.shp arg2=.dbf ; kind=geojson -> arg1=path arg2=ISO2 cc.
BND_MANIFEST="$TMP/geo.manifest"; : > "$BND_MANIFEST"   # shared by boundaries + POIs
BND_RAW="$(printf '%s' "${GEO_BOUNDARIES:-}" | tr ',' ' ')"
if [ -n "$BND_RAW" ]; then
    if printf '%s' "$BND_RAW" | grep -q '[*]'; then
        # Whole planet: one CGAZ shapefile zip per level (non-LFS, reliable).
        CGAZ="https://github.com/wmgeolab/geoBoundaries/raw/main/releaseData/CGAZ"
        for lvl in 1 2; do
            zip="$CACHE/cgaz_ADM${lvl}.zip"; dir="$CACHE/cgaz_ADM${lvl}"
            if [ "${REFRESH:-0}" != 1 ] && [ -s "$dir/geoBoundariesCGAZ_ADM${lvl}.shp" ]; then
                echo "  ✓ using cached CGAZ ADM${lvl}"
            else
                echo "▶ Downloading global boundaries CGAZ ADM${lvl} (one-time)..."
                curl -fsSL -o "$zip.part" "$CGAZ/geoBoundariesCGAZ_ADM${lvl}.zip" \
                    && mv -f "$zip.part" "$zip" && mkdir -p "$dir" \
                    && unzip -oq "$zip" -d "$dir" \
                    || { echo "⚠ boundaries: CGAZ ADM${lvl} download/unzip failed"; rm -f "$zip.part"; continue; }
            fi
            shp="$dir/geoBoundariesCGAZ_ADM${lvl}.shp"; dbf="$dir/geoBoundariesCGAZ_ADM${lvl}.dbf"
            [ -s "$shp" ] && [ -s "$dbf" ] && printf 'shp\t%s\t%s\t%s\n' "$lvl" "$shp" "$dbf" >> "$BND_MANIFEST"
        done
    else
        # Selected countries: gbOpen per-country GeoJSON (git-LFS — must use the
        # github.com/raw/<ref> host; raw.githubusercontent returns a pointer).
        GB_BASE="https://github.com/wmgeolab/geoBoundaries/raw/main/releaseData/gbOpen"
        for cc in $BND_RAW; do
            iso3="$(awk -F'\t' -v c="$cc" '$1==c && $1!~/^#/{print $2; exit}' "$CACHE/country.txt")"
            [ -n "$iso3" ] || { echo "⚠ boundaries: no ISO3 for '$cc' — skipping."; continue; }
            for lvl in ADM1 ADM2; do
                out="$CACHE/bnd_${cc}_${lvl}.geojson"
                url="$GB_BASE/$iso3/$lvl/geoBoundaries-$iso3-$lvl.geojson"
                if [ "${REFRESH:-0}" != 1 ] && [ -s "$out" ]; then
                    echo "  ✓ using cached $(basename "$out")"
                else
                    echo "▶ Downloading boundaries $cc/$lvl ..."
                    curl -fsSL -o "$out.part" "$url" && mv -f "$out.part" "$out" \
                        || { echo "⚠ boundaries: download failed for $cc/$lvl ($iso3)"; rm -f "$out.part"; continue; }
                fi
                printf 'geojson\t%s\t%s\t%s\n' "${lvl#ADM}" "$out" "$cc" >> "$BND_MANIFEST"
            done
        done
    fi
fi

# OpenStreetMap points-of-interest (richer, better-categorised landmarks than the
# thin GeoNames feature set). Per Geofabrik region, pull the free shapefile
# extract and feed the POI/natural layers to the Python (kind=poi). The
# place-of-worship layer (gis_osm_pofw_*) is deliberately NOT included.
POI_RAW="$(printf '%s' "${GEO_POI_REGIONS:-}" | tr ',' ' ')"
for region in $POI_RAW; do
    slug="$(printf '%s' "$region" | tr '/' '_')"
    zip="$CACHE/osm_${slug}.shp.zip"; dir="$CACHE/osm_${slug}"
    if [ "${REFRESH:-0}" != 1 ] && [ -s "$dir/gis_osm_pois_free_1.shp" ]; then
        echo "  ✓ using cached OSM POIs for $region"
    else
        echo "▶ Downloading OSM POIs for $region (one-time, a few hundred MB)..."
        curl -fsSL -o "$zip.part" "https://download.geofabrik.de/${region}-latest-free.shp.zip" \
            && mv -f "$zip.part" "$zip" && mkdir -p "$dir" \
            && unzip -oq "$zip" 'gis_osm_pois_free_1.*' 'gis_osm_pois_a_free_1.*' \
                               'gis_osm_natural_free_1.*' 'gis_osm_natural_a_free_1.*' \
                               'gis_osm_places_free_1.*' -d "$dir" \
            || { echo "⚠ POIs: download/unzip failed for $region"; rm -f "$zip.part"; continue; }
    fi
    for lyr in gis_osm_pois_free_1 gis_osm_pois_a_free_1 gis_osm_natural_free_1 gis_osm_natural_a_free_1 gis_osm_places_free_1; do
        [ -s "$dir/$lyr.shp" ] && [ -s "$dir/$lyr.dbf" ] \
            && printf 'poi\t0\t%s\t%s\n' "$dir/$lyr.shp" "$dir/$lyr.dbf" >> "$BND_MANIFEST"
    done
done

DUMPS=()
if [ -n "${GEONAMES_COUNTRIES:-}" ]; then
    for cc in $GEONAMES_COUNTRIES; do
        if fetch_cached "$cc.zip" "$CACHE/$cc.zip"; then
            if stream_member "$CACHE/$cc.zip" "$cc.txt" _DUMP; then
                DUMPS+=("$_DUMP")
            else
                echo "⚠ could not stream $cc.zip"
            fi
        else
            echo "⚠ could not fetch $cc.zip"
        fi
    done
else
    echo "▶ Whole-planet dump (allCountries.zip, ~390MB; cached after first time)..."
    if fetch_cached "allCountries.zip" "$CACHE/allCountries.zip" \
        && stream_member "$CACHE/allCountries.zip" allCountries.txt _DUMP; then
        DUMPS+=("$_DUMP")
    fi
fi
[ "${#DUMPS[@]}" -gt 0 ] || { echo "build-geodb: no dumps available — aborting."; exit 1; }

echo "▶ Building offline place database -> $GEODB ..."
python3 - "$GEODB" "$CACHE/country.txt" "$CACHE/admin1.txt" "$ALTFILE" "$LOCALIZE" "$BND_MANIFEST" "${DUMPS[@]}" <<'PY'
import sys, sqlite3, os, json, struct
# GeoNames feature CODE -> (weight, max_km). Higher weight = more prominent;
# max_km = how far away the feature can still be the photo's "landmark".
LANDMARK = {
    # --- iconic cultural / historic: small radius so PROXIMITY decides. ---
    "PAL":(11,3),"CSTL":(11,3),                    # palace (Gyeongbokgung), castle
    "PYR":(11,5),"PYRS":(11,5),                    # pyramid(s)
    "ANS":(10,3),"HSTS":(10,3),"RUIN":(10,3),      # ancient/historic site, ruins
    "MNMT":(10,2.5),"MNMTS":(10,2.5),              # monument(s)
    "TMPL":(9,2),"SHRN":(8,2),"PGDA":(9,2),        # temple, shrine, pagoda
    "MSTY":(9,3),"CTHL":(9,3),"MSQE":(7,2),        # monastery, cathedral, mosque
    "FT":(9,3),"GATE":(8,1.5),"WALLA":(8,3),       # fort, gate, ancient wall
    "AMTH":(9,3),"TOWR":(8,3),                     # amphitheatre, tower (callsigns filtered)
    # --- attractions / civic (tight: you're there) ---
    "MUS":(7,2),"OPRA":(8,2),"OBS":(7,3),          # museum, opera, observatory
    "STDM":(7,2.5),"ZOO":(7,2.5),"GDN":(6,2),      # stadium, zoo, garden
    "AMUS":(8,3),"LTHSE":(7,4),"BTL":(8,4),        # amusement park, lighthouse, battlefield
    # --- parks / protected areas (span a wide area) ---
    "PRK":(7,12),"RESN":(5,12),"RESW":(5,12),
    # --- prominent natural features (can be "at" them from farther off) ---
    "VLC":(11,30),"MT":(8,15),"PK":(9,18),"PKS":(9,18),
    "FLLS":(9,8),"GLCR":(8,15),"GYSR":(8,8),
    "CNYN":(9,18),"CRTR":(8,15),"VAL":(6,12),"DUNE":(6,10),"DSRT":(7,30),
    "LK":(8,12),"LKS":(8,12),"BAY":(6,12),
    "CLF":(6,8),"CAPE":(6,10),"ISL":(7,20),"ISLS":(7,20),
    "BCH":(7,6),"SPNG":(5,5),
}
import re as _re
_CALLSIGN = _re.compile(r'^[KWC][A-Z]{2,3}(-(FM|AM|TV|LP|LD|CD|CA|DT))?$')
def _is_broadcast(nm):
    return bool(_CALLSIGN.match(nm)) or '-FM' in nm or '-AM' in nm or '-TV' in nm
db, cinfo, admin1 = sys.argv[1], sys.argv[2], sys.argv[3]
altfile, localize, bnd_manifest = sys.argv[4], sys.argv[5], sys.argv[6]
dumps = sys.argv[7:]

# Language → country code: localize a place into a script only for its own
# country (so "ko" gives Korean for KR places, not for every place with a Korean
# alternate name like Tokyo). Extend this map to add more languages.
LANG_CC = {"ko": "KR", "ja": "JP", "zh": "CN", "ru": "RU", "th": "TH", "ar": "SA",
           "el": "GR", "he": "IL", "hi": "IN", "uk": "UA"}
langs = [x for x in localize.replace(" ", ",").split(",") if x]
loc_cc = {LANG_CC[l] for l in langs if l in LANG_CC}      # countries we localize
want_lang = set(langs)

# Per-language SCRIPT test: many Korean names in GeoNames are stored with a BLANK
# isolanguage tag rather than "ko", so a tag-only match finds just ~59% of KR
# places. Also accepting any name written in the language's own script lifts that
# to ~89% — and a Hangul-script name is unambiguously Korean, so it's safe.
def _is_hangul(s):
    return any(0xAC00 <= ord(c) <= 0xD7A3 or 0x1100 <= ord(c) <= 0x11FF
               or 0x3130 <= ord(c) <= 0x318F for c in s)
SCRIPT = {"ko": _is_hangul}

# loc_name[geonameid] = best localized display name (preferred, non-historic). A
# name qualifies if it's TAGGED as a wanted language OR written in its script.
# Score: exact-tag (2) + preferred (4) + short (1); ties break to the shorter
# string, so the canonical "서울" wins over "서울특별시". The country gate at insert
# time keeps these from ever being applied to a place in another country.
loc_name, loc_score = {}, {}
if altfile and os.path.exists(altfile) and want_lang:
    for ln in open(altfile, encoding="utf-8", errors="ignore"):
        c = ln.rstrip("\n").split("\t")
        if len(c) < 4:
            continue
        gid, lang, name = c[1], c[2], c[3]
        if not name:
            continue
        is_hist = len(c) > 7 and c[7] == "1"
        if is_hist:                       # skip historical names (한양/경성 for Seoul)
            continue
        tag_ok = lang in want_lang
        script_ok = any(l in SCRIPT and SCRIPT[l](name) for l in want_lang)
        if not (tag_ok or script_ok):
            continue
        is_pref = len(c) > 4 and c[4] == "1"
        is_short = len(c) > 5 and c[5] == "1"
        score = (2 if tag_ok else 0) + (4 if is_pref else 0) + (1 if is_short else 0)
        prev = loc_score.get(gid)
        if prev is None or score > prev or (score == prev and len(name) < len(loc_name[gid])):
            loc_name[gid] = name
            loc_score[gid] = score


def localize_name(geoid, cc, fallback):
    if cc in loc_cc and geoid in loc_name:
        return loc_name[geoid]
    return fallback


country = {}       # cc -> english name
country_gid = {}   # cc -> the country's own geonameid (to localize the name)
iso3to2 = {}       # geoBoundaries shapeGroup (ISO3) -> ISO2 used everywhere else
for ln in open(cinfo, encoding="utf-8", errors="ignore"):
    if ln.startswith("#"):
        continue
    c = ln.rstrip("\n").split("\t")
    if len(c) > 4 and c[0]:
        country[c[0]] = c[4]
        if len(c) > 1 and c[1]:
            iso3to2[c[1]] = c[0]
        if len(c) > 16:
            country_gid[c[0]] = c[16]

# admin1: keep both the romanized name and the province's geonameid so KR
# provinces can be localized too (admin1CodesASCII cols: code, name, ascii, gid).
a1, a1_gid = {}, {}
for ln in open(admin1, encoding="utf-8", errors="ignore"):
    c = ln.rstrip("\n").split("\t")
    if len(c) >= 2 and c[0]:
        a1[c[0]] = c[1]
        if len(c) >= 4:
            a1_gid[c[0]] = c[3]

os.makedirs(os.path.dirname(db), exist_ok=True)
if os.path.exists(db):
    os.remove(db)
con = sqlite3.connect(db); cur = con.cursor()
cur.execute("CREATE TABLE place(name TEXT, lat REAL, lon REAL, pop INTEGER, state TEXT, country TEXT, fcode TEXT)")
cur.execute("CREATE TABLE feature(name TEXT, lat REAL, lon REAL, fcode TEXT, elev REAL, weight INTEGER, maxkm REAL)")
# boundary: one row per admin polygon. level 1=province/state, 2=city/county/
# district. rings is JSON [[outer, hole...], ...]. metro=1 for 특별시/광역시 (where
# the ADM1 itself is the city, e.g. Seoul). parent/pmetro (level-2 rows) carry the
# containing ADM1's name + metro flag, computed at build from the ADM2's interior
# point — so a Seoul district KNOWS it's in Seoul (no province) even though CGAZ
# simplifies the ADM1 and ADM2 layers independently and their edges don't match.
# An R-tree indexes the bounding boxes so a point lookup is O(log n) over ~53k.
cur.execute("CREATE TABLE boundary(id INTEGER PRIMARY KEY, level INT, name TEXT, "
            "metro INT, parent TEXT, pmetro INT, country TEXT, cc TEXT, rings TEXT)")
cur.execute("CREATE VIRTUAL TABLE boundary_rtree USING rtree(id, minlat, maxlat, minlon, maxlon)")
# osm_poi: named OpenStreetMap landmarks for the configured regions (preferred
# over the GeoNames feature table where present). Its own R-tree for fast lookup.
cur.execute("CREATE TABLE osm_poi(id INTEGER PRIMARY KEY, name TEXT, lat REAL, lon REAL, fclass TEXT)")
cur.execute("CREATE VIRTUAL TABLE osm_poi_rtree USING rtree(id, minlat, maxlat, minlon, maxlon)")

# adm_pts[level] = [(lat, lon, localized_name), ...] for localized countries, used
# to name the (romanized) geoBoundaries polygons in the local language.
adm_pts = {1: [], 2: []}

np = nf = 0
for dump in dumps:
    for ln in open(dump, encoding="utf-8", errors="ignore"):
        c = ln.rstrip("\n").split("\t")
        if len(c) < 19:
            continue
        geoid, name, lat, lon, fclass, fcode, cc, adm1 = c[0], c[1], c[4], c[5], c[6], c[7], c[8], c[10]
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
        # For places in a localized country, show the local-script name (서울)
        # instead of the romanized one (Seoul); everywhere else stays romanized.
        name = localize_name(geoid, cc, name)
        # Stash admin centres (ADM1/ADM2) for LOCALIZED countries so we can give the
        # romanized geoBoundaries polygons their local-language name (Hanam-si
        # polygon -> 하남시). Other countries just keep the polygon's own name.
        if cc in loc_cc and fcode in ("ADM1", "ADM2"):
            adm_pts[1 if fcode == "ADM1" else 2].append((lat, lon, name))
        if fclass == "P" and fcode.startswith("PPL") and pop > 0:
            akey = cc + "." + adm1
            state = localize_name(a1_gid.get(akey, ""), cc, a1.get(akey, ""))
            ctry = localize_name(country_gid.get(cc, ""), cc, country.get(cc, ""))
            cur.execute("INSERT INTO place VALUES(?,?,?,?,?,?,?)",
                        (name, lat, lon, pop, state, ctry, fcode))
            np += 1
        elif fcode in LANDMARK:
            if _is_broadcast(name):       # skip radio/TV stations (e.g. WLVV-FM)
                continue
            w, mk = LANDMARK[fcode]
            cur.execute("INSERT INTO feature VALUES(?,?,?,?,?,?,?)",
                        (name, lat, lon, fcode, elev, w, mk))
            nf += 1

cur.execute("CREATE INDEX ix_place_lat ON place(lat)")
cur.execute("CREATE INDEX ix_feat_lat  ON feature(lat)")

# --- administrative boundary polygons ---------------------------------------
def _ring(lat, lon, ring):
    # ray cast; ring pts are [lon, lat]
    inside = False; n = len(ring); j = n - 1
    for i in range(n):
        xi, yi = ring[i][0], ring[i][1]; xj, yj = ring[j][0], ring[j][1]
        if ((yi > lat) != (yj > lat)) and (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi):
            inside = not inside
        j = i
    return inside

def _pip(lat, lon, polys):
    # polys = [[outer, hole1, ...], ...]. Inside the outer ring AND outside every
    # hole — essential because a province like 경기도 has Seoul cut out as a hole.
    for poly in polys:
        if _ring(lat, lon, poly[0]) and not any(_ring(lat, lon, h) for h in poly[1:]):
            return True
    return False

# A 특별시/광역시/특별자치시 (Seoul, Busan…) IS the city at ADM1; provinces (도) are
# not. Detect by the local-name suffix, or a romanized fallback set.
_METRO_SUFFIX = ("특별시", "광역시", "특별자치시")
_METRO_ROMAN = {"Seoul", "Busan", "Daegu", "Incheon", "Gwangju", "Daejeon",
                "Ulsan", "Sejong", "Sejong-si"}

# --- pure-Python ESRI shapefile reader (Polygon type 5) + parallel DBF --------
def _dbf_rows(path):
    f = open(path, "rb"); hdr = f.read(32)
    nrec = struct.unpack("<I", hdr[4:8])[0]; hlen = struct.unpack("<H", hdr[8:10])[0]
    rlen = struct.unpack("<H", hdr[10:12])[0]; nf = (hlen - 33) // 32
    fields = []
    for _ in range(nf):
        fd = f.read(32); fields.append((fd[:11].split(b"\x00")[0].decode("latin1"), fd[16]))
    f.read(1)                                              # header terminator
    for _ in range(nrec):
        rec = f.read(rlen); off = 1; row = {}
        for nm, ln in fields:
            b = rec[off:off + ln]; off += ln
            try:                                 # OSM dbf is UTF-8; CGAZ is cp1252
                row[nm] = b.decode("utf-8").strip()
            except UnicodeDecodeError:
                row[nm] = b.decode("cp1252", "replace").strip()
        yield row

# OSM POI categories worth showing as a landmark — real attractions + natural
# features. NOT a popularity score: just OSM's own fclass tags. The separate
# place-of-worship layer is never loaded, so minor temples don't dominate.
POI_KEEP = {
    "attraction", "viewpoint", "tower", "monument", "memorial", "museum",
    "castle", "ruins", "archaeological", "fort", "theme_park", "zoo", "aquarium",
    "lighthouse", "windmill", "battlefield", "fountain", "observation_tower",
    "gallery", "arts_centre", "park", "garden",
    "peak", "volcano", "waterfall", "cave_entrance", "spring", "beach", "cliff", "glacier",
}
# Settlement / neighbourhood level — a finer-than-city fallback (kept distinct via
# fclass so the resolver can append the nearest one after the real POIs).
HOOD_KEEP = {"suburb", "neighbourhood", "quarter", "city_block", "borough",
             "hamlet", "village", "town", "locality"}

def _shp_anypoint(path):
    # yields a representative (lon, lat) per record — the point itself for point
    # shapes, the area-weighted centroid for polygons; None for null/empty.
    f = open(path, "rb"); f.seek(100)
    while True:
        h = f.read(8)
        if len(h) < 8:
            break
        clen = struct.unpack(">I", h[4:8])[0] * 2
        c = f.read(clen); t = struct.unpack("<i", c[:4])[0]
        if t == 1:
            yield struct.unpack("<dd", c[4:20]); continue
        if t != 5:
            yield None; continue
        nparts = struct.unpack("<i", c[36:40])[0]; npts = struct.unpack("<i", c[40:44])[0]
        if npts < 3:
            yield None; continue
        po = 44 + 4 * nparts
        pts = [struct.unpack("<dd", c[po + i * 16:po + i * 16 + 16]) for i in range(npts)]
        yield _rep_point([[pts]])

def _shp_polys(path):
    # yields [[outer, hole...], ...] per record ([] for null shapes), rings=[lon,lat]
    f = open(path, "rb"); f.seek(100)
    while True:
        h = f.read(8)
        if len(h) < 8:
            break
        clen = struct.unpack(">I", h[4:8])[0] * 2
        c = f.read(clen)
        if struct.unpack("<i", c[:4])[0] != 5:            # not a polygon
            yield []; continue
        nparts = struct.unpack("<i", c[36:40])[0]; npts = struct.unpack("<i", c[40:44])[0]
        po = 44; parts = struct.unpack("<%di" % nparts, c[po:po + 4 * nparts]); po += 4 * nparts
        pts = [struct.unpack("<dd", c[po + i * 16:po + i * 16 + 16]) for i in range(npts)]
        polys = []
        for k in range(nparts):
            s = parts[k]; e = parts[k + 1] if k + 1 < nparts else npts
            ring = pts[s:e]
            a = 0.0
            for i in range(len(ring) - 1):
                a += ring[i][0] * ring[i + 1][1] - ring[i + 1][0] * ring[i][1]
            if a < 0 or not polys:                         # CW outer ring (or first)
                polys.append([ring])
            else:                                          # CCW hole of current outer
                polys[-1].append(ring)
        yield polys

def _round_polys(polys, nd=5):                             # shrink stored coords (~1m)
    return [[[[round(x, nd), round(y, nd)] for x, y in ring] for ring in poly] for poly in polys]

def _rep_point(polys):
    # area-weighted centroid of the largest outer ring -> an interior (lon,lat)
    best = None; barea = -1.0
    for poly in polys:
        r = poly[0]; a = cx = cy = 0.0
        for i in range(len(r) - 1):
            f = r[i][0] * r[i + 1][1] - r[i + 1][0] * r[i][1]
            a += f; cx += (r[i][0] + r[i + 1][0]) * f; cy += (r[i][1] + r[i + 1][1]) * f
        if a != 0 and abs(a) > barea:
            barea = abs(a); best = (cx / (3 * a), cy / (3 * a))
    return best

def _parent_adm1(lon, lat):
    # which already-inserted level-1 polygon contains this point -> (name, metro)
    for nm, mt, rings in cur.execute(
            "SELECT b.name,b.metro,b.rings FROM boundary_rtree r JOIN boundary b ON b.id=r.id "
            "WHERE b.level=1 AND r.minlat<=? AND r.maxlat>=? AND r.minlon<=? AND r.maxlon>=?",
            (lat, lat, lon, lon)).fetchall():
        if _pip(lat, lon, json.loads(rings)):
            return nm, mt
    return "", 0

bid = [0]; nb = 0
def add_boundary(level, cc, shape_name, polys):
    global nb
    if not polys:
        return
    xs = [pt[0] for poly in polys for pt in poly[0]]
    ys = [pt[1] for poly in polys for pt in poly[0]]
    if not xs:
        return
    minlon, maxlon, minlat, maxlat = min(xs), max(xs), min(ys), max(ys)
    # name: localized countries get the GeoNames admin centre that falls inside the
    # polygon (Hanam-si -> 하남시); everyone else keeps the romanized shapeName.
    name = shape_name or ""
    if cc in loc_cc:
        for plat, plon, pname in adm_pts.get(level, []):
            if minlat <= plat <= maxlat and minlon <= plon <= maxlon and _pip(plat, plon, polys):
                name = pname
                break
    metro = 1 if (level == 1 and (name.endswith(_METRO_SUFFIX) or name in _METRO_ROMAN)) else 0
    parent = ""; pmetro = 0
    if level == 2:                                  # tie each city to its province
        rp = _rep_point(polys)
        if rp:
            parent, pmetro = _parent_adm1(rp[0], rp[1])
    # the region's country, localized like everything else (대한민국, not "South
    # Korea") — so the HUD's region label uses the SAME data as the city, not a
    # second nearest-point guess.
    ctry = localize_name(country_gid.get(cc, ""), cc, country.get(cc, ""))
    bid[0] += 1; rid = bid[0]
    cur.execute("INSERT INTO boundary VALUES(?,?,?,?,?,?,?,?,?)",
                (rid, level, name, metro, parent, pmetro, ctry, cc,
                 json.dumps(_round_polys(polys), separators=(",", ":"))))
    cur.execute("INSERT INTO boundary_rtree VALUES(?,?,?,?,?)",
                (rid, minlat, maxlat, minlon, maxlon))
    nb += 1

pid = [0]; npoi = 0
def add_poi(name, lon, lat, fclass):
    global npoi
    pid[0] += 1; rid = pid[0]
    cur.execute("INSERT INTO osm_poi VALUES(?,?,?,?,?)", (rid, name, lat, lon, fclass))
    cur.execute("INSERT INTO osm_poi_rtree VALUES(?,?,?,?,?)", (rid, lat, lat, lon, lon))
    npoi += 1

if bnd_manifest and os.path.exists(bnd_manifest):
    for ln in open(bnd_manifest, encoding="utf-8"):
        p = ln.rstrip("\n").split("\t")
        if len(p) < 4:
            continue
        kind, level, a1arg, a2arg = p[0], int(p[1]), p[2], p[3]
        if kind == "poi":                                  # OSM landmarks (shp + dbf)
            if not (os.path.exists(a1arg) and os.path.exists(a2arg)):
                continue
            rows = _dbf_rows(a2arg)
            for pt in _shp_anypoint(a1arg):
                rec = next(rows, None)
                if pt is None or rec is None:
                    continue
                nm = rec.get("name", ""); fc = rec.get("fclass", "")
                if nm and (fc in POI_KEEP or fc in HOOD_KEEP):
                    add_poi(nm, pt[0], pt[1], fc)
        elif kind == "shp":                                # whole-planet CGAZ shapefile
            if not (os.path.exists(a1arg) and os.path.exists(a2arg)):
                continue
            rows = _dbf_rows(a2arg)
            for polys in _shp_polys(a1arg):
                rec = next(rows, None)
                if not polys or rec is None:
                    continue
                cc = iso3to2.get(rec.get("shapeGroup", ""), "")
                add_boundary(level, cc, rec.get("shapeName", ""), polys)
        else:                                              # per-country gbOpen GeoJSON
            if not os.path.exists(a1arg):
                continue
            try:
                gj = json.load(open(a1arg, encoding="utf-8"))
            except (ValueError, OSError):
                sys.stderr.write("geodb: could not read boundary file %s\n" % a1arg)
                continue
            for feat in gj.get("features", []):
                geom = feat.get("geometry") or {}
                gtype = geom.get("type"); coords = geom.get("coordinates")
                if gtype == "Polygon":
                    polys = [coords]
                elif gtype == "MultiPolygon":
                    polys = coords
                else:
                    continue
                add_boundary(level, a2arg, (feat.get("properties") or {}).get("shapeName", ""), polys)

con.commit(); con.close()
sys.stderr.write("geodb: %d places, %d landmark features, %d boundaries, %d OSM POIs -> %s\n"
                 % (np, nf, nb, npoi, db))
PY
# Stamp the version so launch.sh knows this DB matches the current schema.
printf '%s' "${GEODB_VERSION:-1}" > "${GEODB}.version"
echo "✅ Offline place database ready."
