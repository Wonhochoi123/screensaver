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
        && (cd "$TMP" && unzip -oq "$CACHE/alternateNamesV2.zip" alternateNamesV2.txt); then
        ALTFILE="$TMP/alternateNamesV2.txt"
    else
        echo "⚠ could not fetch/unzip alternateNamesV2 — names will stay romanized."
    fi
fi

# Administrative boundary polygons (point-in-polygon city resolution). Without
# them the resolver picks the nearest populated POINT, so a megacity's huge
# population lets it claim neighbouring towns (Misa/Hanam reported as "Seoul").
# With them, the city is whichever 시/군/구 polygon actually CONTAINS the point.
# Source: geoBoundaries gbOpen (CC-BY) ADM1+ADM2 GeoJSON, per configured country.
BND_MANIFEST=""
BND_COUNTRIES="$(printf '%s' "${GEO_BOUNDARIES:-}" | tr ',' ' ')"
if [ -n "$BND_COUNTRIES" ]; then
    BND_MANIFEST="$TMP/boundaries.manifest"; : > "$BND_MANIFEST"
    # Use the github.com/raw/<ref> form, not raw.githubusercontent.com: these
    # GeoJSON files are git-LFS, and only this host resolves the LFS object (the
    # raw.githubusercontent path returns a 131-byte pointer).
    GB_BASE="https://github.com/wmgeolab/geoBoundaries/raw/main/releaseData/gbOpen"
    for cc in $BND_COUNTRIES; do
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
            printf '%s\t%s\t%s\t%s\n' "$cc" "${lvl#ADM}" "$out" "$iso3" >> "$BND_MANIFEST"
        done
    done
fi

DUMPS=()
if [ -n "${GEONAMES_COUNTRIES:-}" ]; then
    for cc in $GEONAMES_COUNTRIES; do
        if fetch_cached "$cc.zip" "$CACHE/$cc.zip"; then
            if (cd "$TMP" && unzip -oq "$CACHE/$cc.zip" "$cc.txt"); then
                DUMPS+=("$TMP/$cc.txt")
            else
                echo "⚠ could not unzip $cc.zip"
            fi
        else
            echo "⚠ could not fetch $cc.zip"
        fi
    done
else
    echo "▶ Whole-planet dump (allCountries.zip, ~390MB; cached after first time)..."
    if fetch_cached "allCountries.zip" "$CACHE/allCountries.zip" \
        && (cd "$TMP" && unzip -oq "$CACHE/allCountries.zip" allCountries.txt); then
        DUMPS+=("$TMP/allCountries.txt")
    fi
fi
[ "${#DUMPS[@]}" -gt 0 ] || { echo "build-geodb: no dumps available — aborting."; exit 1; }

echo "▶ Building offline place database -> $GEODB ..."
python3 - "$GEODB" "$CACHE/country.txt" "$CACHE/admin1.txt" "$ALTFILE" "$LOCALIZE" "$BND_MANIFEST" "${DUMPS[@]}" <<'PY'
import sys, sqlite3, os, json
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
# Countries that get boundary polygons -> their admin points are collected so the
# polygons can be named in the local language (the polygon files are romanized).
bnd_cc = set()
if bnd_manifest and os.path.exists(bnd_manifest):
    for ln in open(bnd_manifest, encoding="utf-8"):
        p = ln.rstrip("\n").split("\t")
        if p and p[0]:
            bnd_cc.add(p[0])

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
for ln in open(cinfo, encoding="utf-8", errors="ignore"):
    if ln.startswith("#"):
        continue
    c = ln.rstrip("\n").split("\t")
    if len(c) > 4 and c[0]:
        country[c[0]] = c[4]
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
cur.execute("CREATE TABLE place(name TEXT, lat REAL, lon REAL, pop INTEGER, state TEXT, country TEXT)")
cur.execute("CREATE TABLE feature(name TEXT, lat REAL, lon REAL, fcode TEXT, elev REAL, weight INTEGER, maxkm REAL)")
# boundary: one row per admin polygon. level 1=province/metro, 2=city/district.
# rings is JSON [[[lon,lat],...], ...] (outer ring per polygon part). metro=1 for
# 특별시/광역시 (where the ADM1 itself is the city, e.g. Seoul). Queried by bbox.
cur.execute("CREATE TABLE boundary(level INT, name TEXT, metro INT, "
            "minlat REAL, maxlat REAL, minlon REAL, maxlon REAL, rings TEXT)")

# adm_pts[level] = [(lat, lon, localized_name), ...] for boundary countries, used
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
        # Stash admin centres (ADM1/ADM2) for boundary countries so we can give the
        # polygons their local-language name (Hanam-si polygon -> 하남시).
        if cc in bnd_cc and fcode in ("ADM1", "ADM2"):
            adm_pts[1 if fcode == "ADM1" else 2].append((lat, lon, name))
        if fclass == "P" and fcode.startswith("PPL") and pop > 0:
            akey = cc + "." + adm1
            state = localize_name(a1_gid.get(akey, ""), cc, a1.get(akey, ""))
            ctry = localize_name(country_gid.get(cc, ""), cc, country.get(cc, ""))
            cur.execute("INSERT INTO place VALUES(?,?,?,?,?,?)",
                        (name, lat, lon, pop, state, ctry))
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
nb = 0
if bnd_manifest and os.path.exists(bnd_manifest):
    for ln in open(bnd_manifest, encoding="utf-8"):
        p = ln.rstrip("\n").split("\t")
        if len(p) < 3:
            continue
        cc, level, path = p[0], int(p[1]), p[2]
        if not os.path.exists(path):
            continue
        try:
            gj = json.load(open(path, encoding="utf-8"))
        except (ValueError, OSError):
            sys.stderr.write("geodb: could not read boundary file %s\n" % path)
            continue
        pts = adm_pts.get(level, [])
        for feat in gj.get("features", []):
            geom = feat.get("geometry") or {}
            gtype = geom.get("type"); coords = geom.get("coordinates")
            if gtype == "Polygon":
                polys = [coords]                          # one polygon: [outer, holes...]
            elif gtype == "MultiPolygon":
                polys = coords                            # [[outer, holes...], ...]
            else:
                continue
            # bbox over the outer rings only (poly[0])
            xs = [pt[0] for poly in polys for pt in poly[0]]
            ys = [pt[1] for poly in polys for pt in poly[0]]
            if not xs:
                continue
            minlon, maxlon, minlat, maxlat = min(xs), max(xs), min(ys), max(ys)
            # name the polygon from the GeoNames admin centre that falls inside it;
            # fall back to the romanized geoBoundaries shapeName.
            name = (feat.get("properties") or {}).get("shapeName", "") or ""
            for plat, plon, pname in pts:
                if minlat <= plat <= maxlat and minlon <= plon <= maxlon and _pip(plat, plon, polys):
                    name = pname
                    break
            metro = 1 if (level == 1 and (name.endswith(_METRO_SUFFIX) or name in _METRO_ROMAN)) else 0
            cur.execute("INSERT INTO boundary VALUES(?,?,?,?,?,?,?,?)",
                        (level, name, metro, minlat, maxlat, minlon, maxlon,
                         json.dumps(polys, separators=(",", ":"))))
            nb += 1
    cur.execute("CREATE INDEX ix_bnd ON boundary(minlat, maxlat)")

con.commit(); con.close()
sys.stderr.write("geodb: %d places, %d landmark features, %d boundaries -> %s\n" % (np, nf, nb, db))
PY
# Stamp the version so launch.sh knows this DB matches the current schema.
printf '%s' "${GEODB_VERSION:-1}" > "${GEODB}.version"
echo "✅ Offline place database ready."
