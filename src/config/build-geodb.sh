#!/bin/bash
set -u
SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || { echo "build-geodb: missing config $SS_CONF — run the installer." >&2; exit 1; }

command -v curl  >/dev/null 2>&1 || { echo "build-geodb: curl not found."  >&2; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "build-geodb: unzip not found." >&2; exit 1; }

BASE="https://download.geonames.org/export/dump"
WORK="$MAP_DIR/geo"; mkdir -p "$WORK"
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
python3 - "$GEODB" "$CACHE/country.txt" "$CACHE/admin1.txt" "${DUMPS[@]}" <<'PY'
import sys, sqlite3, os
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
            if _is_broadcast(name):       # skip radio/TV stations (e.g. WLVV-FM)
                continue
            w, mk = LANDMARK[fcode]
            cur.execute("INSERT INTO feature VALUES(?,?,?,?,?,?,?)",
                        (name, lat, lon, fcode, elev, w, mk))
            nf += 1

cur.execute("CREATE INDEX ix_place_lat ON place(lat)")
cur.execute("CREATE INDEX ix_feat_lat  ON feature(lat)")
con.commit(); con.close()
sys.stderr.write("geodb: %d places, %d landmark features -> %s\n" % (np, nf, db))
PY
# Stamp the version so launch.sh knows this DB matches the current schema.
printf '%s' "${GEODB_VERSION:-1}" > "${GEODB}.version"
echo "✅ Offline place database ready."
