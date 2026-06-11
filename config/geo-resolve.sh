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
import sys, sqlite3, math, unicodedata
DB = sys.argv[1]; lat = float(sys.argv[2]); lon = float(sys.argv[3])

def ascii_(s):
    # Fold accents to plain ASCII and drop apostrophes (regular English alphabet).
    if not s: return s
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    for ch in ("'", "’", "‘", "`", "´"):
        s = s.replace(ch, "")
    return s.encode("ascii", "ignore").decode("ascii").strip()

def hav(a, b, c, d):
    p1, p2 = math.radians(a), math.radians(c)
    x = math.sin(math.radians(c - a) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(d - b) / 2) ** 2
    return 2 * 6371.0 * math.asin(math.sqrt(x))

con = sqlite3.connect("file:%s?mode=ro" % DB, uri=True); cur = con.cursor()

def win(r):
    dla = r / 111.0
    dlo = r / (111.0 * max(0.05, math.cos(math.radians(lat))))
    return lat - dla, lat + dla, lon - dlo, lon + dlo

# --- landmark: the nearest few named features (each within its own radius),
#     closest first, up to 5. Joined with "|" so the app can cycle through them. ---
la0, la1, lo0, lo1 = win(35)
cands = []
for name, flat, flon, fcode, elev, w, mk in cur.execute(
        "SELECT name,lat,lon,fcode,elev,weight,maxkm FROM feature "
        "WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?", (la0, la1, lo0, lo1)):
    d = hav(lat, lon, flat, flon)
    if d > mk:
        continue
    cands.append((d, name))
cands.sort(key=lambda x: x[0])
names, seen = [], set()
for d, name in cands:
    n = ascii_(name)
    if n and n.lower() not in seen:
        seen.add(n.lower()); names.append(n)
    if len(names) >= 5:
        break
landmark = "|".join(names)

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

print("\t".join([landmark, ascii_(city), ascii_(state), ascii_(country)]))
PY
