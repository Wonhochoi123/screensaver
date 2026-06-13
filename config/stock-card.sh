#!/bin/bash
# =============================================================================
#  stock-card.sh — fetch one ticker's data for the briefing's MARKETS card.
#
#  Usage:  stock-card.sh <SYMBOL> <outfile>
#
#  Quote comes from CNBC's public quote service; the intraday line from Nasdaq's
#  chart API (both keyless, and — unlike Yahoo, which rate-limits/429s many IPs —
#  they answer reliably). Writes a TAB-delimited block photo.lua draws as a
#  Google-Finance-style vector card. Cached 20 min per symbol. Degrades silently.
#
#  Output (TAB-separated):
#     NAME<TAB>Tesla Inc
#     PRICE<TAB>406.43
#     CHG<TAB>7.28<TAB>1.82<TAB>up          (points, percent, up/down/flat)
#     PREV<TAB>399.15
#     DAY<TAB>386.76<TAB>406.68             (day low, day high)
#     W52<TAB>288.77<TAB>498.83             (52-week low, high)
#     VOL<TAB>60.3M
#     SERIES<TAB>398.0 399.5 ...            (downsampled intraday closes)
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
import sys, json, datetime, urllib.request, urllib.parse

# Friendly aliases for crypto → CNBC's Coin Metrics symbols, so you can put plain
# BTC / ETH in GROK_TICKERS. (SpaceX is private — no ticker; DXYZ is a proxy.)
CRYPTO = {"BTC": "BTC.CM=", "BITCOIN": "BTC.CM=", "ETH": "ETH.CM=", "ETHEREUM": "ETH.CM=",
          "SOL": "SOL.CM=", "SOLANA": "SOL.CM=", "DOGE": "DOGE.CM=", "DOGECOIN": "DOGE.CM=",
          "XRP": "XRP.CM=", "LTC": "LTC.CM=", "ADA": "ADA.CM="}
sym = sys.argv[1].strip().upper()
sym = CRYPTO.get(sym, sym)
is_crypto = sym.endswith("=")
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")


def get(url, accept="*/*"):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": accept})
        with urllib.request.urlopen(req, timeout=12) as r:
            return r.read().decode("utf-8", "replace")
    except Exception:
        return ""


def num(s):
    if s is None:
        return None
    s = str(s).replace(",", "").replace("%", "").replace("$", "").replace("+", "").strip()
    try:
        return float(s)
    except Exception:
        return None


# --- Quote from CNBC (name, price, change, ranges, volume) --------------------
q = {}
txt = get("https://quote.cnbc.com/quote-html-webservice/restQuote/symbolType/symbol"
          f"?symbols={urllib.parse.quote(sym)}&requestMethod=itv&noform=1&partnerId=2"
          "&fund=1&exthrs=1&output=json")
try:
    q = json.loads(txt)["FormattedQuoteResult"]["FormattedQuote"][0]
except Exception:
    q = {}

name = q.get("name") or sym
if is_crypto and "/" in name:           # "Bitcoin/USD Coin Metrics" → "Bitcoin"
    name = name.split("/")[0].strip()
price = num(q.get("last"))
prev = num(q.get("previous_day_closing"))
chg = num(q.get("change"))
pct = num(q.get("change_pct"))
ctype = (q.get("changetype") or "").upper()
dlo, dhi = num(q.get("low")), num(q.get("high"))
wlo, whi = num(q.get("yrloprice")), num(q.get("yrhiprice"))
vol_alt = q.get("volume_alt")           # already human ("60.3M")
vol_raw = q.get("volume")               # raw ("60,272,904")

# Fallback quote from Nasdaq if CNBC gave nothing.
if price is None:
    nd = get(f"https://api.nasdaq.com/api/quote/{urllib.parse.quote(sym)}/info?assetclass=stocks",
             accept="application/json")
    try:
        pd = json.loads(nd)["data"]["primaryData"]
        price = num(pd.get("lastSalePrice"))
        chg = num(pd.get("netChange"))
        pct = num(pd.get("percentageChange"))
    except Exception:
        pass

if price is None:
    sys.exit(1)

# Direction.
if ctype in ("UP", "DOWN"):
    dirn = ctype.lower()
elif chg is not None:
    dirn = "up" if chg > 0 else ("down" if chg < 0 else "flat")
elif prev is not None:
    dirn = "up" if price > prev else ("down" if price < prev else "flat")
else:
    dirn = "flat"
# Derive change/pct/prev from each other where possible.
if prev is None and chg is not None:
    prev = price - chg
if chg is None and prev is not None:
    chg = price - prev
if pct is None and prev:
    pct = (price - prev) / prev * 100.0

# --- Price series from Nasdaq, several ranges (for the switchable line chart) --
# 1D = today's intraday; 1M / 1Y = daily history via fromdate/todate. (Crypto
# isn't on Nasdaq's stock API, so those cards show price/stats without a line.)
def downsample(vals, n=72):
    if len(vals) <= n:
        return vals
    step = len(vals) / n
    return [vals[min(len(vals) - 1, int(i * step))] for i in range(n)]


def nasdaq_series(url):
    try:
        chart = json.loads(get(url, accept="application/json"))["data"]["chart"]
        vals = [num(p.get("y")) for p in chart if isinstance(p, dict)]
        return downsample([v for v in vals if v is not None])
    except Exception:
        return []


enc = urllib.parse.quote(sym)
ranges = {}
if not is_crypto:
    today = datetime.date.today()
    ranges["1D"] = nasdaq_series(f"https://api.nasdaq.com/api/quote/{enc}/chart?assetclass=stocks")
    ranges["1M"] = nasdaq_series(f"https://api.nasdaq.com/api/quote/{enc}/chart?assetclass=stocks"
                                 f"&fromdate={today - datetime.timedelta(days=31)}&todate={today}")
    ranges["1Y"] = nasdaq_series(f"https://api.nasdaq.com/api/quote/{enc}/chart?assetclass=stocks"
                                 f"&fromdate={today - datetime.timedelta(days=365)}&todate={today}")


def human(v):
    if v is None:
        return None
    v = float(v)
    for div, suf in ((1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")):
        if abs(v) >= div:
            return f"{v / div:.1f}{suf}"
    return f"{v:.0f}"


out = [f"NAME\t{name}", f"PRICE\t{price:.2f}"]
if pct is not None:
    out.append(f"CHG\t{abs(chg):.2f}\t{abs(pct):.2f}\t{dirn}"
               if chg is not None else f"CHG\t\t{abs(pct):.2f}\t{dirn}")
if prev is not None:
    out.append(f"PREV\t{prev:.2f}")
if dlo is not None and dhi is not None:
    out.append(f"DAY\t{dlo:.2f}\t{dhi:.2f}")
if wlo is not None and whi is not None:
    out.append(f"W52\t{wlo:.2f}\t{whi:.2f}")
hv = vol_alt if vol_alt else human(num(vol_raw))
if hv:
    out.append(f"VOL\t{hv}")
# SERIES = 1D (kept for compatibility); SR1M / SR1Y = the longer ranges.
for tag, key in (("SERIES", "1D"), ("SR1M", "1M"), ("SR1Y", "1Y")):
    s = ranges.get(key) or []
    if len(s) >= 2:
        out.append(f"{tag}\t" + " ".join(f"{v:.2f}" for v in s))
print("\n".join(out))
PY

if [ -s "$OUT.tmp" ]; then
    mv -f "$OUT.tmp" "$OUT"
    cp -f "$OUT" "$CACHE" 2>/dev/null
else
    rm -f "$OUT.tmp"
fi
