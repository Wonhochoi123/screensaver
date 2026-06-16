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
# Persistent cache for live POI (Overpass) lookups, so a coordinate is queried at
# most once ever; survives reinstalls (lives under Data/, not /tmp).
if [ -n "${RES_DIR:-}" ]; then
    export GEO_POI_CACHE="$RES_DIR/geo/overpass_cache"
    mkdir -p "$GEO_POI_CACHE" 2>/dev/null || true
fi
export GEO_POI_SOURCE GEO_OVERPASS_URL
python3 - "$GEODB" "$BATCH" "$LAT" "$LON" "$COORDS" <<'PY'
import sys, sqlite3, math, unicodedata, json, os, time, urllib.request, urllib.parse
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

# Administrative boundary polygons (point-in-polygon city resolution). Candidate
# polygons for a point come from an R-tree on the bounding boxes, so this scales
# to the whole planet (~53k polygons) and only the few that overlap the point are
# ray-cast. Absent table => behave exactly as before (nearest-point only).
HAVE_BND = True
try:
    cur.execute("SELECT count(*) FROM boundary_rtree WHERE id<0")
except sqlite3.OperationalError:
    HAVE_BND = False
HAVE_POI = True
try:
    cur.execute("SELECT count(*) FROM osm_poi_rtree WHERE id<0")
except sqlite3.OperationalError:
    HAVE_POI = False

POI_SOURCE = os.environ.get("GEO_POI_SOURCE", "overpass").strip().lower()
OVERPASS_URL = os.environ.get("GEO_OVERPASS_URL", "https://overpass-api.de/api/interpreter")
POI_CACHE = os.environ.get("GEO_POI_CACHE", "")
_op_last = [0.0]    # rate-limit clock; _op_fail = consecutive failures (circuit breaker)
_op_fail = [0]

def overpass_pois(lat, lon):
    # Live OSM landmarks near a point -> [(name, plat, plon), ...]; None on network
    # failure (so the caller can fall back offline), [] if simply nothing nearby.
    # Cached on disk by ~110 m cell so each spot is queried at most once, ever.
    # The "q3" prefix is the query version — bump it whenever the filters/format
    # change so stale cached results are re-fetched instead of reused.
    key = "q5_%.3f_%.3f" % (lat, lon)
    cf = os.path.join(POI_CACHE, key + ".json") if POI_CACHE else ""
    if cf and os.path.exists(cf):
        try:
            return json.load(open(cf, encoding="utf-8"))
        except Exception:
            pass
    if _op_fail[0] >= 3:        # 3 strikes -> assume offline for the rest of this run
        return None
    R = 8000
    # Category filters MIRROR the offline keep-list (build-geodb.sh POI_KEEP) so a
    # travel photo OUTSIDE the downloaded regions gets the SAME kinds of landmarks
    # as one inside them: real attractions / historic sites / natural features /
    # parks — not the OSM firehose of plaques, benches and boundary stones (still no
    # tourism=artwork, no generic historic=yes). Radius was 2.5 km, which left spots
    # with nothing in the immediate block blank; widened so the nearest real sights
    # are still found, closer to the wide window the offline path searches. Not a
    # popularity score — purely OSM's own category tags.
    q = ("[out:json][timeout:30];("
         'nwr(around:%d,%f,%f)[tourism~"^(attraction|museum|viewpoint|theme_park|zoo|gallery|aquarium)$"][name];'
         'nwr(around:%d,%f,%f)[historic~"^(monument|memorial|castle|fort|fortress|ruins|archaeological_site|city_gate|citywalls|city_walls|monastery|palace|manor|tower|battlefield|aqueduct)$"][name];'
         'nwr(around:%d,%f,%f)[natural~"^(peak|volcano|waterfall|cave_entrance|beach|glacier|hot_spring|spring|cliff)$"][name];'
         'nwr(around:%d,%f,%f)[man_made~"^(tower|lighthouse|windmill|obelisk|observation_tower)$"][name];'
         'nwr(around:%d,%f,%f)[leisure~"^(park|garden|stadium|sports_centre|water_park|marina)$"][name];'
         'nwr(around:%d,%f,%f)[amenity~"^(arts_centre|fountain|place_of_worship|university|college|hospital|theatre|cinema|library|marketplace|townhall|courthouse|community_centre)$"][name];'
         'nwr(around:%d,%f,%f)[waterway~"^(waterfall)$"][name];'
         # neighbourhood/suburb level — a finer-than-city fallback for when the
         # exact POI you were at isn't mapped (e.g. 잠실동).
         'node(around:%d,%f,%f)[place~"^(suburb|neighbourhood|quarter|city_block|borough|hamlet|village)$"][name];'
         ");out center 200;") % ((R, lat, lon) * 8)
    body = urllib.parse.urlencode({"data": q}).encode()
    j = None
    for attempt in (0, 1):                         # one retry — Overpass load is spiky
        wait = 1.2 - (time.time() - _op_last[0])   # be polite: >=1.2 s between calls
        if wait > 0:
            time.sleep(wait)
        try:
            req = urllib.request.Request(OVERPASS_URL, data=body,
                                         headers={"User-Agent": "mpv-screensaver-geo/1"})
            with urllib.request.urlopen(req, timeout=25) as r:
                j = json.loads(r.read().decode("utf-8"))
            _op_last[0] = time.time(); _op_fail[0] = 0
            break
        except Exception:
            _op_last[0] = time.time()
            if attempt == 0 and _op_fail[0] == 0:  # retry once, but not when already failing
                time.sleep(3)                      # brief backoff, then retry once
                continue
            _op_fail[0] += 1
            return None
    out = []
    for el in j.get("elements", []):
        tags = el.get("tags", {}); nm = tags.get("name")
        if not nm:
            continue
        if el.get("type") == "node":
            plat, plon = el.get("lat"), el.get("lon")
        else:
            c = el.get("center", {}); plat, plon = c.get("lat"), c.get("lon")
        if plat is None:
            continue
        kind = "hood" if tags.get("place") else "poi"
        out.append([nm, plat, plon, kind])
    if cf:
        try:
            tmp = cf + ".tmp"; json.dump(out, open(tmp, "w", encoding="utf-8")); os.replace(tmp, cf)
        except Exception:
            pass
    return out

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
    # -> (adm1_name, adm1_metro, adm2_name, adm2_parent, adm2_pmetro, country, cc, adm2_polys)
    if not HAVE_BND:
        return None, 0, None, None, 0, None, None, None
    rows = cur.execute(
        "SELECT b.level,b.name,b.metro,b.parent,b.pmetro,b.country,b.cc,b.rings FROM boundary_rtree r "
        "JOIN boundary b ON b.id=r.id "
        "WHERE r.minlat<=? AND r.maxlat>=? AND r.minlon<=? AND r.maxlon>=?",
        (lat, lat, lon, lon)).fetchall()
    b1 = b2 = b2par = b2polys = None; metro = pmetro = 0; ctry1 = ctry2 = cc1 = cc2 = None
    for level, name, mtr, parent, pmtr, country, cc, rings in rows:
        if b1 is not None and b2 is not None:
            break
        polys = json.loads(rings)
        if not _pip(lat, lon, polys):
            continue
        if level == 1 and b1 is None:
            b1 = name; metro = mtr; ctry1 = country; cc1 = cc
        elif level == 2 and b2 is None:
            b2 = name; b2par = parent; pmetro = pmtr; ctry2 = country; cc2 = cc; b2polys = polys
    return b1, metro, b2, b2par, pmetro, (ctry2 or ctry1), (cc2 or cc1), b2polys

def resolve(lat, lon):
    def win(r):
        dla = r / 111.0
        dlo = r / (111.0 * max(0.05, math.cos(math.radians(lat))))
        return lat - dla, lat + dla, lon - dlo, lon + dlo

    # --- landmark: nearest named features, closest first, up to 10, "|"-joined for
    #     the HUD to cycle, with the nearest neighbourhood appended as a finer-than-
    #     city fallback. Source per GEO_POI_SOURCE:
    #       hybrid  -> OFFLINE OSM extract where the point is covered (reliable, no
    #                  network), else live Overpass (out of region), else GeoNames.
    #       overpass-> always live Overpass; offline -> only the extract; none/else
    #                  -> GeoNames features. ---
    HOOD_FCLASS = {"suburb", "neighbourhood", "quarter", "city_block", "borough",
                   "hamlet", "village", "town", "locality"}

    def _rank(cands, limit=10):
        cands.sort(key=lambda x: x[0])
        names, seen = [], set()
        for d, name in cands:
            n = ascii_(name)
            if n and n.lower() not in seen:
                seen.add(n.lower()); names.append(n)
            if len(names) >= limit:
                break
        return names

    def _assemble(pois, hoods):
        names = _rank(pois)                     # up to 10 real POIs, nearest first
        for nm in _rank(hoods, 1):              # + nearest neighbourhood fallback
            if nm.lower() not in {x.lower() for x in names}:
                names.append(nm)
        return names

    def _offline_osm():                         # downloaded extract; [] if no coverage
        la0, la1, lo0, lo1 = win(40)
        pois, hoods = [], []
        for name, flat, flon, fc in cur.execute(
                "SELECT p.name,p.lat,p.lon,p.fclass FROM osm_poi_rtree r JOIN osm_poi p ON p.id=r.id "
                "WHERE r.minlat BETWEEN ? AND ? AND r.minlon BETWEEN ? AND ?", (la0, la1, lo0, lo1)):
            (hoods if fc in HOOD_FCLASS else pois).append((hav(lat, lon, flat, flon), name))
        return _assemble(pois, hoods)

    def _overpass_landmarks():                  # live OSM; None on net fail, [] if none
        items = overpass_pois(lat, lon)
        if items is None:
            return None
        pois = [(hav(lat, lon, p[1], p[2]), p[0]) for p in items if (p[3] if len(p) > 3 else "poi") == "poi"]
        hoods = [(hav(lat, lon, p[1], p[2]), p[0]) for p in items if len(p) > 3 and p[3] == "hood"]
        return _assemble(pois, hoods)

    names = None
    if POI_SOURCE in ("hybrid", "offline") and HAVE_POI:
        names = _offline_osm()                  # reliable offline where downloaded
    if not names and POI_SOURCE in ("hybrid", "overpass"):
        names = _overpass_landmarks()           # out of region (or pure overpass)
    # No GeoNames landmark fallback any more — if OSM has nothing, the landmark is
    # simply blank (the city/neighbourhood still show), never the old temple junk.
    landmark = "|".join(names or [])

    # --- city: collect nearby populated places (kept for the boundary hybrid) ----
    la0, la1, lo0, lo1 = win(30)
    places = []     # (dist, score, name, plat, plon, state, country, fcode)
    bc = None
    for name, plat, plon, pop, state, country, fcode in cur.execute(
            "SELECT name,lat,lon,pop,state,country,fcode FROM place "
            "WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?", (la0, la1, lo0, lo1)):
        d = hav(lat, lon, plat, plon)
        if d > 30:
            continue
        s = math.log10(pop + 10) - d / 10.0
        places.append((d, s, name, plat, plon, state, country, fcode or ""))
        if bc is None or s > bc[0]:
            bc = (s, name, state, country)
    city    = bc[1] if bc else ""
    state   = bc[2] if bc else ""
    country = bc[3] if bc else ""

    # The administrative level that means "the city" differs by country. In Korea
    # (and the rest of East Asia) ADM2 IS the city (하남시; Seoul = ADM1 metro), so
    # the boundary name is used DIRECTLY — GeoNames is not consulted at all. In
    # North America ADM2 is a COUNTY and in Europe it's a department/province, so
    # the actual city is named from the nearest town/place inside the polygon
    # ('Santa Clara' county -> San Jose; 'Yvelines' -> Versailles). Extend
    # ADM2_IS_CITY with any other country whose ADM2 is the municipality.
    ADM2_IS_CITY = {"KR", "JP", "TW", "HK", "MO", "KP"}
    def _city_level(fc):
        return fc == "PPL" or fc == "PPLC" or fc == "PPLG" or fc.startswith("PPLA")
    # Tie-break by administrative rank so a capital/seat beats a sub-unit when both
    # are about equally close — picks 'Paris' over 'Paris 04', but distance still
    # dominates so a suburb (Cupertino) isn't overridden by the county seat.
    _RANK = {"PPLC": 0, "PPLA": 1, "PPLA2": 2, "PPLA3": 3, "PPLA4": 4, "PPLA5": 5}
    b1, b1_metro, b2, b2_parent, b2_pmetro, b_country, b_cc, b2polys = boundary_lookup(lat, lon)
    # Region label (province + country) comes from the SAME boundary polygons as the
    # city — just coarser levels — not a second nearest-point guess.
    if b_country:
        country = b_country
    # Province comes from the ADM2's own parent (consistent with the city), not a
    # separate ADM1 lookup that can disagree at simplified borders.
    prov = b2_parent if b2 else b1
    prov_metro = b2_pmetro if b2 else b1_metro
    if prov_metro:
        # a 특별시/광역시 IS the city and has NO province (Seoul -> 서울특별시, blank).
        city = prov or b1 or city; state = ""
    elif b2:
        if b_cc in ADM2_IS_CITY:
            city = b2                           # ADM2 already IS the city (하남시)
        else:
            # county/department -> name the actual town inside the polygon
            inside = [p for p in places if _pip(p[3], p[4], b2polys)]
            towns = [p for p in inside if _city_level(p[7])] or inside
            if towns:
                towns.sort(key=lambda p: p[0] + _RANK.get(p[7], 6) * 0.5)
                city = towns[0][2]
            else:
                city = b2                       # sparse data -> the admin name
        state = prov or state
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
