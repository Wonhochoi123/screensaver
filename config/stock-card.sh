#!/bin/bash
# =============================================================================
#  stock-card.sh — fetch one ticker's data for the briefing's MARKETS card.
#
#  Usage:  stock-card.sh <SYMBOL> <outfile>
#
#  Pulls today's intraday series + key stats from the free Yahoo Finance chart
#  endpoint (no API key) and writes a TAB-delimited block photo.lua draws as a
#  Google-Finance-style vector card (price, change, 1-day line vs previous close,
#  day/52-week range, volume). Cached 20 min per symbol. Degrades silently — on
#  any failure it writes nothing, and the card falls back to the spoken price.
#
#  Output (TAB-separated), e.g.:
#     NAME<TAB>Tesla Inc
#     PRICE<TAB>248.50
#     CHG<TAB>3.20<TAB>1.30<TAB>up          (points, percent, up/down/flat)
#     PREV<TAB>245.30
#     DAY<TAB>244.00<TAB>250.10             (day low, day high)
#     W52<TAB>138.80<TAB>278.98             (52-week low, high)
#     VOL<TAB>98.2M
#     SERIES<TAB>248.1 247.9 248.4 ...      (downsampled intraday closes)
# =============================================================================
set -u
SYM="${1:-}"; OUT="${2:-}"
[ -n "$SYM" ] && [ -n "$OUT" ] || exit 0

CACHE="/tmp/ss_stock_$(printf '%s' "$SYM" | tr -c 'A-Za-z0-9._-' '_').cache"
if [ -s "$CACHE" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$CACHE" 2>/dev/null || echo 0) ))
    [ "$age" -lt 1200 ] && { cp -f "$CACHE" "$OUT" 2>/dev/null; exit 0; }
fi

python3 - "$SYM" > "$OUT.tmp" 2>/dev/null <<'PY'
import sys, json, urllib.request, urllib.parse

sym = sys.argv[1].strip().upper()
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")


def get(url):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=12) as r:
            return r.read().decode("utf-8", "replace")
    except Exception:
        return ""


def fetch(rng, interval):
    for host in ("query1", "query2"):
        t = get(f"https://{host}.finance.yahoo.com/v8/finance/chart/"
                f"{urllib.parse.quote(sym)}?range={rng}&interval={interval}")
        if t:
            try:
                return json.loads(t)["chart"]["result"][0]
            except Exception:
                continue
    return None


res = fetch("1d", "5m")
# Pre-market / closed day can come back empty — fall back to a 5-day view.
def closes_of(r):
    try:
        return [c for c in r["indicators"]["quote"][0]["close"] if c is not None]
    except Exception:
        return []

if not res or len(closes_of(res)) < 3:
    res = fetch("5d", "15m") or res
if not res:
    sys.exit(1)

meta = res.get("meta", {})
price = meta.get("regularMarketPrice")
prev = meta.get("chartPreviousClose") or meta.get("previousClose")
if price is None:
    sys.exit(1)

name = meta.get("shortName") or meta.get("longName") or sym
series = closes_of(res)
if not series:
    series = [price]

# Downsample to ~72 points so the on-screen line stays smooth but light.
MAXP = 72
if len(series) > MAXP:
    step = len(series) / MAXP
    series = [series[min(len(series) - 1, int(i * step))] for i in range(MAXP)]


def human(v):
    try:
        v = float(v)
    except Exception:
        return "—"
    for div, suf in ((1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")):
        if abs(v) >= div:
            return f"{v / div:.1f}{suf}"
    return f"{v:.0f}"


out = []
out.append(f"NAME\t{name}")
out.append(f"PRICE\t{price:.2f}")
if prev:
    pts = price - prev
    pct = pts / prev * 100.0
    dirn = "up" if pts > 0.0001 else ("down" if pts < -0.0001 else "flat")
    out.append(f"CHG\t{pts:.2f}\t{abs(pct):.2f}\t{dirn}")
    out.append(f"PREV\t{prev:.2f}")
dl, dh = meta.get("regularMarketDayLow"), meta.get("regularMarketDayHigh")
if dl is not None and dh is not None:
    out.append(f"DAY\t{dl:.2f}\t{dh:.2f}")
wl, wh = meta.get("fiftyTwoWeekLow"), meta.get("fiftyTwoWeekHigh")
if wl is not None and wh is not None:
    out.append(f"W52\t{wl:.2f}\t{wh:.2f}")
vol = meta.get("regularMarketVolume")
if vol:
    out.append(f"VOL\t{human(vol)}")
out.append("SERIES\t" + " ".join(f"{v:.2f}" for v in series))
print("\n".join(out))
PY

if [ -s "$OUT.tmp" ]; then
    mv -f "$OUT.tmp" "$OUT"
    cp -f "$OUT" "$CACHE" 2>/dev/null
else
    rm -f "$OUT.tmp"
fi
