#!/usr/bin/env python3
# =============================================================================
#  news-build.py — assemble the morning briefing's content WITHOUT an AI call.
#
#  Grabs the top headlines straight from curated, politically balanced RSS feeds
#  (the feeds are the editorial judgment — no model decides what's important),
#  reads current weather from the Open-Meteo card, and pulls live prices for the
#  configured tickers. Emits the SAME JSON the old Grok parser did — a list of
#  {cat, line, url} items — so the rest of grok-briefing.sh (TTS + playback) and
#  photo.lua are unchanged. xAI is now used ONLY to read these lines aloud.
#
#  Inputs come from the environment:
#     WX_FILE     path to the weather-card.sh output (for the spoken weather line)
#     LOCATION    e.g. "Mooresville, NC"
#     TICKERS     comma-separated, e.g. "TSLA, AMD, PLTR"
#     NEWS_FEEDS  newline-separated RSS URLs for TOP NEWS (overrides the default)
#     TECH_FEEDS  newline-separated RSS URLs for TECH & FINANCE
#     NEWS_N      how many top-news items (default 3)
#     TECH_N      how many tech items (default 3)
#     DAY_NAME    e.g. "Friday" (for the closing sign-off)
#
#  Degrades section-by-section: any feed / weather / market that fails is simply
#  skipped. Always prints valid JSON (at minimum a closing remark).
# =============================================================================
import os, sys, re, json, html, datetime, urllib.request, urllib.parse
import xml.etree.ElementTree as ET

UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")

# Partisan / unscrapable hosts we never surface as a source (both directions),
# mirroring grok-briefing.sh's backstop so a syndicated feed link can't sneak a
# slanted article onto the right pane.
BAD_HOST = re.compile(
    r'youtube\.com|youtu\.be|reuters\.com'
    r'|theguardian\.com|guardian\.co\.uk|npr\.org|msnbc\.com|vox\.com'
    r'|huffpost\.com|huffingtonpost\.com|slate\.com|thenation\.com'
    r'|motherjones\.com|dailykos\.com|thedailybeast\.com'
    r'|foxnews\.com|foxbusiness\.com|breitbart\.com|dailywire\.com'
    r'|newsmax\.com|oann\.com|thefederalist\.com|theblaze\.com|dailycaller\.com',
    re.I)

DEFAULT_NEWS = [
    "https://feeds.bbci.co.uk/news/world/rss.xml",
    "https://www.cnbc.com/id/100003114/device/rss/rss.html",
    "https://thehill.com/news/feed/",
    "https://rss.csmonitor.com/feeds/usa",
]
DEFAULT_TECH = [
    "https://feeds.arstechnica.com/arstechnica/index",
    "https://www.theverge.com/rss/index.xml",
    "https://techcrunch.com/feed/",
    "https://www.engadget.com/rss.xml",
]


def get(url, timeout=12):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read().decode("utf-8", "replace")
    except Exception:
        return ""


def clean_title(t):
    t = re.sub(r'<[^>]+>', '', t or '')           # strip any inline tags
    t = html.unescape(t)
    t = re.sub(r'\s+', ' ', t).strip()
    # Drop a trailing " - Outlet" / " | Outlet" attribution.
    t = re.sub(r'\s+[\|\-–—]\s+[^\|\-–—]{1,32}$', '', t).strip()
    return t


def clean_desc(d):
    """A feed's <description>/<summary> stripped to plain prose, minus the
    common RSS boilerplate that adds no information when read aloud."""
    d = re.sub(r'<[^>]+>', '', html.unescape(d or ''))
    d = re.sub(r'\s+', ' ', d).strip()
    d = re.sub(r'\s*(continue reading.*|read more.*|the post .* appeared first on .*'
               r'|\[\s*…?\s*\]|\(more…?\))\s*$', '', d, flags=re.I).strip()
    return d.strip('…').strip()


def summary_for(title, desc):
    """One context sentence to speak after the headline — but only if it ADDS
    something (not a near-repeat of the title), trimmed to a sane spoken length."""
    desc = clean_desc(desc)
    if not desc:
        return ""
    tkey = re.sub(r'\W+', '', title.lower())
    dkey = re.sub(r'\W+', '', desc.lower())
    if not dkey or dkey[:45] == tkey[:45] or dkey in tkey or tkey in dkey:
        return ""
    if len(desc) > 260:                            # keep ~1–2 sentences, no walls of text
        cut = desc.rfind('.', 120, 260)
        desc = (desc[:cut + 1] if cut > 0 else desc[:260].rstrip() + '…')
    return desc


def parse_feed(xmltext):
    out = []
    if not xmltext:
        return out
    try:
        root = ET.fromstring(xmltext)
    except Exception:
        return out
    for it in root.iter():
        tag = it.tag.lower().split('}')[-1]
        if tag not in ('item', 'entry'):
            continue
        title = link = desc = ""
        for ch in it:
            c = ch.tag.lower().split('}')[-1]
            if c == 'title' and not title:
                title = ch.text or ""
            elif c in ('description', 'summary') and not desc:
                desc = ch.text or ""
            elif c == 'link':
                if ch.text and ch.text.strip():
                    link = link or ch.text.strip()
                else:                              # Atom: <link href=... rel=...>
                    href = ch.get('href')
                    if href and not link and ch.get('rel', 'alternate') in ('alternate', ''):
                        link = href
        title = clean_title(title)
        link = (link or "").strip()
        if title and link and not BAD_HOST.search(link):
            out.append((title, link, desc))
    return out


def collect(feeds, n):
    """Round-robin across feeds (one from each, then the next) for source
    balance, de-duplicating by headline and link. Each item carries the bare
    headline ('line', shown on screen) AND a richer spoken version ('say',
    headline + the feed's own summary sentence)."""
    parsed = [parse_feed(get(u)) for u in feeds]
    seen_t, seen_l, out = set(), set(), []
    for depth in range(8):
        for fi in parsed:
            if depth >= len(fi):
                continue
            title, link, desc = fi[depth]
            key = re.sub(r'\W+', '', title.lower())[:60]
            if not key or key in seen_t or link in seen_l:
                continue
            seen_t.add(key); seen_l.add(link)
            summ = summary_for(title, desc)
            say = title
            if summ:
                say = (title if title[-1:] in '.!?' else title + '.') + ' ' + summ
                if say[-1:] not in '.!?…':
                    say += '.'
            out.append({"line": title, "say": say, "url": link})
            if len(out) >= n:
                return out
    return out


def weather_line():
    f = os.environ.get("WX_FILE", "")
    if not f or not os.path.exists(f):
        return None
    try:
        data = open(f, encoding="utf-8").read()
    except Exception:
        return None
    now = re.search(r'(?m)^NOW\t(\d+)\t(\d+)\t([^\t]*)\t', data)
    if not now:
        return None
    temp, _feels, desc = now.group(1), now.group(2), now.group(3).strip().lower()
    hilo = re.search(r'(?m)^HILO\t(\d+)\t(\d+)', data)
    place = re.search(r'(?m)^PLACE\t(.*)$', data)
    loc = (place.group(1) if place else os.environ.get("LOCATION", "")).split(",")[0].strip()
    where = f" in {loc}" if loc else ""
    s = f"It's {temp} degrees and {desc}{where} right now"
    if hilo:
        s += f", with a high of {hilo.group(1)} and a low of {hilo.group(2)} today"
    return s + "."


def market_line(sym):
    sym = sym.strip().upper()
    if not sym:
        return None
    enc = urllib.parse.quote(sym)
    for host in ("query1", "query2"):
        txt = get(f"https://{host}.finance.yahoo.com/v8/finance/chart/{enc}?range=1d&interval=1d")
        if not txt:
            continue
        try:
            meta = json.loads(txt)["chart"]["result"][0]["meta"]
            price = meta.get("regularMarketPrice")
            prev = meta.get("chartPreviousClose") or meta.get("previousClose")
            if price is None:
                continue
            if prev:
                chg = (price - prev) / prev * 100.0
                dirn = "up" if chg >= 0 else "down"
                return f"{sym} is trading at ${price:,.2f}, {dirn} {abs(chg):.1f} percent today."
            return f"{sym} is trading at ${price:,.2f}."
        except Exception:
            continue
    return None


def closing_line():
    day = os.environ.get("DAY_NAME", "").strip()
    d = day or "day"
    options = [
        f"That's your morning briefing. Have a wonderful {d}!",
        f"And that's the rundown for this {d} morning. Make it a great one.",
        f"That's everything for now. Wishing you a productive {d}.",
        f"That wraps up the briefing. Enjoy your {d}!",
    ]
    idx = datetime.date.today().toordinal() % len(options)
    return options[idx]


def add(items, cat, line, url, say=None):
    # 'line' is shown on screen (kept short); 'say' is read aloud (can be richer).
    items.append({"cat": cat, "line": line, "say": say or line, "url": url})


def main():
    items = []
    wl = weather_line()
    if wl:
        add(items, "WEATHER", wl, "")

    news_feeds = [u for u in (os.environ.get("NEWS_FEEDS", "").splitlines()) if u.strip()] or DEFAULT_NEWS
    tech_feeds = [u for u in (os.environ.get("TECH_FEEDS", "").splitlines()) if u.strip()] or DEFAULT_TECH
    try:
        news_n = int(os.environ.get("NEWS_N", "5"))
    except ValueError:
        news_n = 5
    try:
        tech_n = int(os.environ.get("TECH_N", "4"))
    except ValueError:
        tech_n = 4

    for it in collect(news_feeds, news_n):
        add(items, "TOP NEWS", it["line"], it["url"], it["say"])
    for it in collect(tech_feeds, tech_n):
        add(items, "TECH & FINANCE", it["line"], it["url"], it["say"])

    for sym in (os.environ.get("TICKERS", "").split(",")):
        ml = market_line(sym)
        if ml:
            add(items, "MARKETS", ml, "")

    add(items, "CLOSING", closing_line(), "")
    print(json.dumps(items))


if __name__ == "__main__":
    main()
