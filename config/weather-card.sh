#!/bin/bash
# =============================================================================
#  weather-card.sh — fetch a compact weather card for the morning briefing.
#
#  Usage:  weather-card.sh <outfile>
#
#  Pulls current conditions + an hourly strip for GROK_LOCATION from Open-Meteo
#  (free, no API key, no sign-up) and writes a small TAB-delimited block that
#  photo.lua parses into a drawn weather card on the briefing's right pane:
#
#     PLACE<TAB>Mooresville, NC
#     NOW<TAB>72<TAB>68<TAB>Partly cloudy<TAB>pcloud<TAB>1
#     HILO<TAB>78<TAB>61
#     WIND<TAB>8 mph
#     HUM<TAB>54%
#     SUN<TAB>6:21 AM<TAB>8:34 PM
#     HOUR<TAB>2 PM<TAB>73<TAB>pcloud<TAB>10
#     ...
#
#  NOW  = temp, feels-like, description, glyph-kind, is_day(1/0)
#  HOUR = label, temp, glyph-kind, precip-chance%
#
#  Glyph kinds (drawn as ASS vectors in photo.lua): sun moon pcloud npcloud
#  cloud fog drizzle rain snow storm.
#
#  Caches for 20 minutes so a replayed/repeated briefing doesn't re-hit the API.
#  Degrades SILENTLY: any failure writes nothing and exits 0.
# =============================================================================
set -u
OUT="${1:-/tmp/ss_weather_card.txt}"
SS_CONF="${SS_CONF:-$HOME/Screensaver-App/config/screensaver.conf}"
. "$SS_CONF" 2>/dev/null || exit 0

LOC="${GROK_LOCATION:-}"
[ -n "$LOC" ] || exit 0
command -v curl   >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

CACHE="/tmp/ss_weather_card.cache"
# Fresh cache (<20 min) → reuse, keyed by the location so a config change busts it.
if [ -f "$CACHE" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$CACHE" 2>/dev/null || echo 0) ))
  if [ "$age" -lt 1200 ] && [ "$(head -n1 "$CACHE" 2>/dev/null)" = "#$LOC" ]; then
    tail -n +2 "$CACHE" > "$OUT" 2>/dev/null && exit 0
  fi
fi

# --- Geocode the location (Open-Meteo geocoding; name = part before the comma,
#     admin = the rest, used to disambiguate same-named towns). -----------------
NAME="${LOC%%,*}"
ADMIN="$(printf '%s' "$LOC" | sed -n 's/^[^,]*,\s*//p')"
NAME_ENC="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$NAME" 2>/dev/null)"
[ -n "$NAME_ENC" ] || exit 0

GEO="$(curl -fsS --max-time 12 \
  "https://geocoding-api.open-meteo.com/v1/search?name=${NAME_ENC}&count=10&language=en&format=json" 2>/dev/null)"
[ -n "$GEO" ] || exit 0

read -r LAT LON RESOLVED < <(GEO_JSON="$GEO" ADMIN="$ADMIN" python3 - <<'PY' 2>/dev/null
import json, os
try:
    d = json.loads(os.environ.get("GEO_JSON", ""))
except Exception:
    raise SystemExit
res = d.get("results") or []
if not res:
    raise SystemExit
admin = (os.environ.get("ADMIN") or "").strip().lower()
# Common US state abbreviations → full names so "NC" matches "North Carolina".
ST = {"al":"alabama","ak":"alaska","az":"arizona","ar":"arkansas","ca":"california",
"co":"colorado","ct":"connecticut","de":"delaware","fl":"florida","ga":"georgia",
"hi":"hawaii","id":"idaho","il":"illinois","in":"indiana","ia":"iowa","ks":"kansas",
"ky":"kentucky","la":"louisiana","me":"maine","md":"maryland","ma":"massachusetts",
"mi":"michigan","mn":"minnesota","ms":"mississippi","mo":"missouri","mt":"montana",
"ne":"nebraska","nv":"nevada","nh":"new hampshire","nj":"new jersey","nm":"new mexico",
"ny":"new york","nc":"north carolina","nd":"north dakota","oh":"ohio","ok":"oklahoma",
"or":"oregon","pa":"pennsylvania","ri":"rhode island","sc":"south carolina",
"sd":"south dakota","tn":"tennessee","tx":"texas","ut":"utah","vt":"vermont",
"va":"virginia","wa":"washington","wv":"west virginia","wi":"wisconsin","wy":"wyoming"}
want = ST.get(admin, admin)
def score(r):
    a1 = (r.get("admin1") or "").lower()
    cc = (r.get("country_code") or "").lower()
    s = 0
    if want and (want in a1 or a1 in want): s += 10
    if not admin and cc == "us": s += 1
    return s
best = max(res, key=score)
print("%.4f %.4f %s" % (best["latitude"], best["longitude"], best.get("name","")))
PY
)
[ -n "${LAT:-}" ] || exit 0

# --- Forecast (current + hourly + today's hi/lo + sunrise/sunset). -----------
FC="$(curl -fsS --max-time 12 \
  "https://api.open-meteo.com/v1/forecast?latitude=${LAT}&longitude=${LON}\
&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,is_day\
&hourly=temperature_2m,weather_code,precipitation_probability\
&daily=temperature_2m_max,temperature_2m_min,sunrise,sunset\
&temperature_unit=fahrenheit&wind_speed_unit=mph&timezone=auto&forecast_days=2" 2>/dev/null)"
[ -n "$FC" ] || exit 0

CARD="$(FC_JSON="$FC" PLACE="$LOC" python3 - <<'PY' 2>/dev/null
import json, os, datetime
try:
    d = json.loads(os.environ.get("FC_JSON",""))
except Exception:
    raise SystemExit

def kind(code, day=True):
    if code in (0,1): return "sun" if day else "moon"
    if code == 2:     return "pcloud" if day else "npcloud"
    if code == 3:     return "cloud"
    if code in (45,48): return "fog"
    if code in (51,53,55,56,57): return "drizzle"
    if code in (61,63,65,66,67,80,81,82): return "rain"
    if code in (71,73,75,77,85,86): return "snow"
    if code in (95,96,99): return "storm"
    return "cloud"

def desc(code):
    return {0:"Clear sky",1:"Mainly clear",2:"Partly cloudy",3:"Overcast",
        45:"Fog",48:"Rime fog",51:"Light drizzle",53:"Drizzle",55:"Heavy drizzle",
        56:"Freezing drizzle",57:"Freezing drizzle",61:"Light rain",63:"Rain",
        65:"Heavy rain",66:"Freezing rain",67:"Freezing rain",71:"Light snow",
        73:"Snow",75:"Heavy snow",77:"Snow grains",80:"Light showers",
        81:"Showers",82:"Heavy showers",85:"Snow showers",86:"Snow showers",
        95:"Thunderstorm",96:"Storm w/ hail",99:"Storm w/ hail"}.get(code,"—")

def fmt_clock(iso):
    try:
        t = datetime.datetime.fromisoformat(iso)
        return t.strftime("%-I:%M %p")
    except Exception:
        return ""

cur = d.get("current") or {}
hr  = d.get("hourly") or {}
day = d.get("daily") or {}
out = []
place = os.environ.get("PLACE","")
out.append("PLACE\t" + place)
isday = int(cur.get("is_day",1) or 0)
ccode = int(round(cur.get("weather_code",0) or 0))
out.append("NOW\t%d\t%d\t%s\t%s\t%d" % (
    round(cur.get("temperature_2m",0) or 0),
    round(cur.get("apparent_temperature",0) or 0),
    desc(ccode), kind(ccode, isday==1), isday))
try:
    out.append("HILO\t%d\t%d" % (round(day["temperature_2m_max"][0]), round(day["temperature_2m_min"][0])))
except Exception:
    pass
out.append("WIND\t%d mph" % round(cur.get("wind_speed_10m",0) or 0))
out.append("HUM\t%d%%" % round(cur.get("relative_humidity_2m",0) or 0))
try:
    out.append("SUN\t%s\t%s" % (fmt_clock(day["sunrise"][0]), fmt_clock(day["sunset"][0])))
except Exception:
    pass

# Hourly strip: the next 8 hours from now.
times = hr.get("time") or []
temps = hr.get("temperature_2m") or []
codes = hr.get("weather_code") or []
pops  = hr.get("precipitation_probability") or []
now = datetime.datetime.now()
start = 0
for i, ts in enumerate(times):
    try:
        if datetime.datetime.fromisoformat(ts) >= now.replace(minute=0, second=0, microsecond=0):
            start = i; break
    except Exception:
        pass
cnt = 0
for i in range(start, len(times)):
    if cnt >= 8: break
    try:
        t = datetime.datetime.fromisoformat(times[i])
        lbl = t.strftime("%-I%p").lower()
        c = int(round(codes[i]))
        dh = 6 <= t.hour < 19
        out.append("HOUR\t%s\t%d\t%s\t%d" % (lbl, round(temps[i]), kind(c, dh), round(pops[i] if i < len(pops) else 0)))
        cnt += 1
    except Exception:
        pass
print("\n".join(out))
PY
)"

[ -n "$CARD" ] || exit 0
{ printf '#%s\n' "$LOC"; printf '%s\n' "$CARD"; } > "$CACHE" 2>/dev/null
printf '%s\n' "$CARD" > "$OUT" 2>/dev/null
exit 0
