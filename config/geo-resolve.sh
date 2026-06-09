#!/bin/bash
# geo-resolve.sh LAT LON -> "landmark<TAB>city<TAB>state<TAB>country"  (offline)
set -u
SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || true
LAT="${1:-}"; LON="${2:-}"
[ -z "$LAT" ] || [ -z "$LON" ] && exit 0
[ -s "${GEODB:-}" ] || exit 0          # DB not built yet -> no enrichment
command -v python3 >/dev/null 2>&1 || exit 0
python3 - "$GEODB" "$LAT" "$LON" <<'PY'
import sys, sqlite3, math
DB = sys.argv[1]; lat = float(sys.argv[2]); lon = float(sys.argv[3])

def hav(a, b, c, d):
    p1, p2 = math.radians(a), math.radians(c)
    x = math.sin(math.radians(c - a) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(d - b) / 2) ** 2
    return 2 * 6371.0 * math.asin(math.sqrt(x))

con = sqlite3.connect("file:%s?mode=ro" % DB, uri=True); cur = con.cursor()

def win(r):
    dla = r / 111.0
    dlo = r / (111.0 * max(0.05, math.cos(math.radians(lat))))
    return lat - dla, lat + dla, lon - dlo, lon + dlo

# --- landmark: score within each feature's own radius, with a minimum score so
#     that when nothing relevant is close we show NO landmark rather than a
#     far-fetched guess. (Interim heuristic; the real prominence fix comes in the
#     OSM/Wikidata rework.) ---
la0, la1, lo0, lo1 = win(35)
MIN_SCORE = 4.0
best = None
for name, flat, flon, fcode, elev, w, mk in cur.execute(
        "SELECT name,lat,lon,fcode,elev,weight,maxkm FROM feature "
        "WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?", (la0, la1, lo0, lo1)):
    d = hav(lat, lon, flat, flon)
    if d > mk:
        continue
    s = w - 7.0 * (d / mk)
    if fcode in ("PK", "MT", "VLC", "CNYN", "CRTR") and elev:
        s += min(elev / 2000.0, 2.0)
    if best is None or s > best[0]:
        best = (s, name)
landmark = best[1] if (best and best[0] >= MIN_SCORE) else ""

# --- city: nearest sizable populated place (population-aware) ----------------
la0, la1, lo0, lo1 = win(30)
bc = None
for name, plat, plon, pop, state, country in cur.execute(
        "SELECT name,lat,lon,pop,state,country FROM place "
        "WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?", (la0, la1, lo0, lo1)):
    d = hav(lat, lon, plat, plon)
    if d > 30:
        continue
    s = math.log10(pop + 10) - d / 10.0
    if bc is None or s > bc[0]:
        bc = (s, name, state, country)
city    = bc[1] if bc else ""
state   = bc[2] if bc else ""
country = bc[3] if bc else ""

print("\t".join([landmark, city, state, country]))
PY
