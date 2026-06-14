#!/bin/bash
# geo-resolve.sh LAT LON -> "landmark<TAB>city<TAB>state<TAB>country"  (offline)
# geo-resolve.sh --batch -> read one "LAT LON" pair per stdin line and print one
#                           result line per input line (same format). The DB is
#                           opened ONCE for the whole batch — this is what
#                           xmp-police.sh uses to resolve a library efficiently.
set -u
SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || true
BATCH=0; COORDS=""
if [ "${1:-}" = "--batch" ]; then
    # The python program itself rides on stdin (python3 - <<heredoc), so spool
    # the piped-in coordinate lines to a temp file and pass its path instead.
    BATCH=1; LAT=0; LON=0
    COORDS="$(mktemp)"; trap 'rm -f "$COORDS"' EXIT
    cat > "$COORDS"
else
    LAT="${1:-}"; LON="${2:-}"
    [ -z "$LAT" ] || [ -z "$LON" ] && exit 0
fi
[ -s "${GEODB:-}" ] || exit 0          # DB not built yet -> no enrichment
command -v python3 >/dev/null 2>&1 || exit 0
python3 - "$GEODB" "$BATCH" "$LAT" "$LON" "$COORDS" <<'PY'
import sys, sqlite3, math, unicodedata, json
DB = sys.argv[1]; BATCH = sys.argv[2] == "1"

def _has_hangul(s):
    # Match photo.lua's is_hangul ranges (it renders these in the Korean font).
    for ch in s:
        o = ord(ch)
        if (0x1100 <= o <= 0x11FF or 0x3130 <= o <= 0x318F or 0xA960 <= o <= 0xA97F
                or 0xAC00 <= o <= 0xD7A3 or 0xD7B0 <= o <= 0xD7FF):
            return True
    return False

def ascii_(s):
    # Korean (Hangul) names are kept as-is — the HUD renders them in a Hangul
    # font. Everything else is folded to plain ASCII (accents stripped, apostrophes
    # dropped); a non-Latin script that would render as tofu blanks out, as before.
    if not s: return s
    if _has_hangul(s):
        return s.strip()
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

# Administrative boundary polygons (point-in-polygon city resolution). Loaded once
# into memory — the table is small (only the configured countries) and reused for
# every coordinate in a batch. Empty / absent table => behave exactly as before.
BND = {1: [], 2: []}    # level -> [(minlat,maxlat,minlon,maxlon, name, metro, parts)]
try:
    for level, name, metro, minlat, maxlat, minlon, maxlon, rings in cur.execute(
            "SELECT level,name,metro,minlat,maxlat,minlon,maxlon,rings FROM boundary").fetchall():
        BND.setdefault(level, []).append(
            (minlat, maxlat, minlon, maxlon, name, metro, json.loads(rings)))
except sqlite3.OperationalError:
    pass                # older DB with no boundary table

def _ring(lat, lon, ring):
    inside = False; n = len(ring); j = n - 1
    for i in range(n):
        xi, yi = ring[i][0], ring[i][1]; xj, yj = ring[j][0], ring[j][1]
        if ((yi > lat) != (yj > lat)) and (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi):
            inside = not inside
        j = i
    return inside

def _pip(lat, lon, polys):
    # polys = [[outer, hole1, ...], ...]: inside outer AND outside every hole
    # (a province like 경기도 has Seoul cut out as a hole).
    for poly in polys:
        if _ring(lat, lon, poly[0]) and not any(_ring(lat, lon, h) for h in poly[1:]):
            return True
    return False

def boundary_lookup(lat, lon):
    # -> (adm1_name, adm1_is_metro, adm2_name); any may be None if no polygon hits.
    b1 = b2 = None; metro = 0
    for store, lvl in ((BND.get(1, []), 1), (BND.get(2, []), 2)):
        for minlat, maxlat, minlon, maxlon, name, mtr, parts in store:
            if minlat <= lat <= maxlat and minlon <= lon <= maxlon and _pip(lat, lon, parts):
                if lvl == 1:
                    b1 = name; metro = mtr
                else:
                    b2 = name
                break
    return b1, metro, b2

def resolve(lat, lon):
    def win(r):
        dla = r / 111.0
        dlo = r / (111.0 * max(0.05, math.cos(math.radians(lat))))
        return lat - dla, lat + dla, lon - dlo, lon + dlo

    # --- landmark: the nearest named features within a wide window — NO radius
    #     filter at all. Closest first, up to 5, joined with "|" to cycle through. ---
    la0, la1, lo0, lo1 = win(100)
    cands = []
    for name, flat, flon, fcode, elev, w, mk in cur.execute(
            "SELECT name,lat,lon,fcode,elev,weight,maxkm FROM feature "
            "WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?", (la0, la1, lo0, lo1)):
        cands.append((hav(lat, lon, flat, flon), name))
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

    # Boundary override: when a polygon actually CONTAINS the point, trust it over
    # the nearest-point guess (this is what stops a megacity from claiming a
    # neighbouring town). A 특별시/광역시 (metro) IS the city at ADM1, so its
    # district is dropped; a province (도) becomes the state and the 시/군 the city.
    b1, b1_metro, b2 = boundary_lookup(lat, lon)
    if b1 and b1_metro:
        city = b1; state = ""
    elif b2:
        city = b2
        if b1:
            state = b1
    elif b1:
        state = b1

    return "\t".join([landmark, ascii_(city), ascii_(state), ascii_(country)])

if BATCH:
    # One result line per input line (blank on a bad pair), so the caller can
    # zip inputs to outputs by position.
    for line in open(sys.argv[5]):
        try:
            p = line.split()
            print(resolve(float(p[0]), float(p[1])), flush=True)
        except Exception:
            print("", flush=True)
else:
    print(resolve(float(sys.argv[3]), float(sys.argv[4])))
PY
