#!/bin/bash
# =============================================================================
#  stock-card.sh — fetch one ticker's data for the briefing's MARKETS card.
#
#  Usage:  stock-card.sh <SYMBOL> <outfile>
#
#  Stocks: quote from CNBC + intraday/history line from Nasdaq (both keyless and
#  reliable, unlike Yahoo which 429s). Crypto (BTC, ETH, …): everything from
#  CoinGecko (price, 24h volume, change, and 1D/1M/1Y charts). Writes a TAB block
#  photo.lua draws as a Google-Finance-style vector card. Cached 20 min. Degrades
#  silently. Includes an ASOF tag so a weekend/holiday move isn't labelled "today".
#
#  Output (TAB-separated):
#     NAME, PRICE, CHG<pts><pct><dir>, PREV, DAY<lo><hi>, W52<lo><hi>, VOL,
#     ASOF<today|Fri|…>, SERIES (1D), SR1M (1 month), SR1Y (1 year)
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

# Crypto aliases → (CoinGecko id, display name). Plain BTC/ETH/… in GROK_TICKERS.
CRYPTO = {
    "BTC": ("bitcoin", "Bitcoin"), "BITCOIN": ("bitcoin", "Bitcoin"),
    "ETH": ("ethereum", "Ethereum"), "ETHEREUM": ("ethereum", "Ethereum"),
    "SOL": ("solana", "Solana"), "SOLANA": ("solana", "Solana"),
    "DOGE": ("dogecoin", "Dogecoin"), "DOGECOIN": ("dogecoin", "Dogecoin"),
    "XRP": ("ripple", "XRP"), "LTC": ("litecoin", "Litecoin"),
    "ADA": ("cardano", "Cardano"), "BNB": ("binancecoin", "BNB"),
}
raw = sys.argv[1].strip().upper()
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")


def get(url, accept="*/*"):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": accept})
        with urllib.request.urlopen(req, timeout=12) as r:
            return r.read().decode("utf-8", "replace")
    except Exception:
        return ""


def jget(url, accept="*/*"):
    try:
        return json.loads(get(url, accept))
    except Exception:
        return None


def num(s):
    if s is None:
        return None
    s = str(s).replace(",", "").replace("%", "").replace("$", "").replace("+", "").strip()
    try:
        return float(s)
    except Exception:
        return None


def downsample(vals, n=72):
    vals = [v for v in vals if v is not None]
    if len(vals) <= n:
        return vals
    step = len(vals) / n
    return [vals[min(len(vals) - 1, int(i * step))] for i in range(n)]


def human(v):
    if v is None:
        return None
    v = float(v)
    for div, suf in ((1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")):
        if abs(v) >= div:
            return f"{v / div:.1f}{suf}"
    return f"{v:.0f}"


def fmt(v):
    if v is None:
        return None
    v = float(v)
    if abs(v) >= 1000:
        return f"{v:,.0f}"
    if abs(v) >= 1:
        return f"{v:,.2f}"
    return f"{v:.4f}"


out = []

# ============================ CRYPTO (CoinGecko) =============================
if raw in CRYPTO:
    cg, disp = CRYPTO[raw]
    base = "https://api.coingecko.com/api/v3"
    d = (jget(f"{base}/simple/price?ids={cg}&vs_currencies=usd"
              "&include_24hr_vol=true&include_24hr_change=true") or {}).get(cg) or {}
    price = d.get("usd")
    if price is None:
        sys.exit(1)
    chgpct = d.get("usd_24h_change")
    vol = d.get("usd_24h_vol")

    def cseries(days):
        j = jget(f"{base}/coins/{cg}/market_chart?vs_currency=usd&days={days}")
        try:
            return downsample([p[1] for p in j["prices"]])
        except Exception:
            return []

    s = {"1D": cseries(1), "1M": cseries(30), "1Y": cseries(365)}
    dirn = "up" if (chgpct or 0) > 0 else ("down" if (chgpct or 0) < 0 else "flat")
    prev = price / (1 + chgpct / 100.0) if chgpct else None
    pts = (price - prev) if prev is not None else None

    out.append(f"NAME\t{disp}")
    out.append(f"PRICE\t{fmt(price)}")
    if chgpct is not None:
        out.append(f"CHG\t{fmt(abs(pts)) if pts is not None else ''}\t{abs(chgpct):.2f}\t{dirn}")
    if prev is not None:
        out.append(f"PREV\t{fmt(prev)}")
    if s["1D"]:
        out.append(f"DAY\t{fmt(min(s['1D']))}\t{fmt(max(s['1D']))}")
    if s["1Y"]:
        out.append(f"W52\t{fmt(min(s['1Y']))}\t{fmt(max(s['1Y']))}")
    if vol:
        out.append(f"VOL\t${human(vol)}")          # crypto volume is in dollars
    out.append("ASOF\ttoday")                       # crypto trades 24/7
    for tag, key in (("SERIES", "1D"), ("SR1M", "1M"), ("SR1Y", "1Y")):
        if len(s[key]) >= 2:
            out.append(f"{tag}\t" + " ".join(f"{v:.6g}" for v in s[key]))
    print("\n".join(out))
    sys.exit(0)

# ============================ STOCKS (CNBC + Nasdaq) ========================
sym = raw
enc = urllib.parse.quote(sym)
q = jget("https://quote.cnbc.com/quote-html-webservice/restQuote/symbolType/symbol"
         f"?symbols={enc}&requestMethod=itv&noform=1&partnerId=2&fund=1&exthrs=1&output=json")
try:
    q = q["FormattedQuoteResult"]["FormattedQuote"][0]
except Exception:
    q = {}

name = q.get("name") or sym
price = num(q.get("last"))
prev = num(q.get("previous_day_closing"))
chg = num(q.get("change"))
pct = num(q.get("change_pct"))
ctype = (q.get("changetype") or "").upper()
dlo, dhi = num(q.get("low")), num(q.get("high"))
wlo, whi = num(q.get("yrloprice")), num(q.get("yrhiprice"))
vol_alt, vol_raw = q.get("volume_alt"), q.get("volume")

if price is None:
    pd = (jget(f"https://api.nasdaq.com/api/quote/{enc}/info?assetclass=stocks",
               accept="application/json") or {})
    try:
        pd = pd["data"]["primaryData"]
        price, chg, pct = num(pd.get("lastSalePrice")), num(pd.get("netChange")), num(pd.get("percentageChange"))
    except Exception:
        pass
if price is None:
    sys.exit(1)

if ctype in ("UP", "DOWN"):
    dirn = ctype.lower()
elif chg is not None:
    dirn = "up" if chg > 0 else ("down" if chg < 0 else "flat")
elif prev is not None:
    dirn = "up" if price > prev else ("down" if price < prev else "flat")
else:
    dirn = "flat"
if prev is None and chg is not None:
    prev = price - chg
if chg is None and prev is not None:
    chg = price - prev
if pct is None and prev:
    pct = (price - prev) / prev * 100.0

# As-of: if the last trade wasn't today (weekend/holiday/pre-open), say which day
# it was instead of "today".
asof = "today"
lt = q.get("last_time")
if lt:
    try:
        d_lt = datetime.date.fromisoformat(lt)
        if d_lt != datetime.date.today():
            asof = d_lt.strftime("%a")        # Fri, Mon, …
    except Exception:
        pass


def nasdaq_series(url):
    j = jget(url, accept="application/json")
    try:
        return downsample([num(p.get("y")) for p in j["data"]["chart"] if isinstance(p, dict)])
    except Exception:
        return []


today = datetime.date.today()
ser = {
    "1D": nasdaq_series(f"https://api.nasdaq.com/api/quote/{enc}/chart?assetclass=stocks"),
    "1M": nasdaq_series(f"https://api.nasdaq.com/api/quote/{enc}/chart?assetclass=stocks"
                        f"&fromdate={today - datetime.timedelta(days=31)}&todate={today}"),
    "1Y": nasdaq_series(f"https://api.nasdaq.com/api/quote/{enc}/chart?assetclass=stocks"
                        f"&fromdate={today - datetime.timedelta(days=365)}&todate={today}"),
}

out.append(f"NAME\t{name}")
out.append(f"PRICE\t{price:.2f}")
if pct is not None:
    out.append(f"CHG\t{abs(chg):.2f}\t{abs(pct):.2f}\t{dirn}"
               if chg is not None else f"CHG\t\t{abs(pct):.2f}\t{dirn}")
if prev is not None:
    out.append(f"PREV\t{prev:.2f}")
if dlo is not None and dhi is not None:
    out.append(f"DAY\t{dlo:.2f}\t{dhi:.2f}")
if wlo is not None and whi is not None and wlo > 0:
    out.append(f"W52\t{wlo:.2f}\t{whi:.2f}")
hv = vol_alt if vol_alt else human(num(vol_raw))
if hv:
    out.append(f"VOL\t{hv}")
out.append(f"ASOF\t{asof}")
for tag, key in (("SERIES", "1D"), ("SR1M", "1M"), ("SR1Y", "1Y")):
    if len(ser[key]) >= 2:
        out.append(f"{tag}\t" + " ".join(f"{v:.2f}" for v in ser[key]))
print("\n".join(out))
PY

if [ -s "$OUT.tmp" ]; then
    mv -f "$OUT.tmp" "$OUT"
    cp -f "$OUT" "$CACHE" 2>/dev/null
else
    rm -f "$OUT.tmp"
fi
