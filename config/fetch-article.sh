#!/bin/bash
# fetch-article.sh URL OUTFILE — fetch a web page and distill it to readable
# plain text for the in-screensaver reading pane. The first line is the page
# title with a leading "# "; section headings keep the marker too; paragraphs
# are separated by blank lines. Always writes OUTFILE (atomically), even on
# failure — photo.lua shows whatever lands there.
set -u
URL="${1:-}"; OUT="${2:-}"
[ -n "$URL" ] && [ -n "$OUT" ] || exit 1

publish() { printf '%s' "$1" > "$OUT.part" && mv -f "$OUT.part" "$OUT"; }

HTML="$(mktemp)"; trap 'rm -f "$HTML"' EXIT
if ! curl -sL --max-time 20 --compressed \
        -A "Mozilla/5.0 (X11; Linux x86_64; rv:125.0) Gecko/20100101 Firefox/125.0" \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
        -H "Accept-Language: en-US,en;q=0.9" \
        "$URL" -o "$HTML" 2>/dev/null || [ ! -s "$HTML" ]; then
    publish "Could not load the page."$'\n\n'"$URL"
    exit 0
fi

TEXT="$(python3 - "$HTML" "$URL" <<'PY' 2>/dev/null
import sys, re
from html.parser import HTMLParser

html = open(sys.argv[1], encoding="utf-8", errors="ignore").read()

class Distill(HTMLParser):
    SKIP  = {"script", "style", "noscript", "svg", "nav", "footer",
             "header", "aside", "form", "button", "figure", "iframe"}
    HEAD  = {"h1", "h2", "h3", "h4"}
    BLOCK = {"p", "li", "blockquote", "pre", "td"}
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.skip = 0; self.depth = 0; self.cur = []
        self.blocks = []           # (is_heading, text)
        self.title = ""; self.intitle = False; self.curhead = False
    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self.skip += 1
        elif tag == "title":
            self.intitle = True
        elif (tag in self.BLOCK or tag in self.HEAD) and not self.skip:
            if self.depth == 0:
                self.cur = []; self.curhead = tag in self.HEAD
            self.depth += 1
    def handle_endtag(self, tag):
        if tag in self.SKIP:
            self.skip = max(0, self.skip - 1)
        elif tag == "title":
            self.intitle = False
        elif (tag in self.BLOCK or tag in self.HEAD) and self.depth:
            self.depth -= 1
            if self.depth == 0:
                t = re.sub(r"\s+", " ", "".join(self.cur)).strip()
                if t:
                    self.blocks.append((self.curhead, t))
                self.cur = []
    def handle_data(self, d):
        if self.intitle and not self.title.strip():
            self.title = re.sub(r"\s+", " ", d).strip()
        if self.depth and not self.skip:
            self.cur.append(d)

d = Distill()
try:
    d.feed(html)
except Exception:
    pass

out, seen = [], set()
if d.title:
    out.append("# " + d.title)
    seen.add(d.title)
body_chars = 0
for head, t in d.blocks:
    if t in seen:
        continue
    # Keep headings; drop tiny non-heading crumbs (nav labels, buttons, bylines).
    if not head and len(t) < 60:
        continue
    seen.add(t)
    out.append(("# " + t) if head else t)
    if not head:
        body_chars += len(t)

# Many news sites render the article with JS but still ship the full text in a
# JSON-LD "articleBody" (or an og:description summary). Use it when the visible
# HTML gave us little — this is what gets Reuters/AP-style pages to show.
if body_chars < 400:
    import json as _json
    for m in re.finditer(r'<script[^>]+application/ld\+json[^>]*>(.*?)</script>',
                         html, re.S | re.I):
        try:
            data = _json.loads(m.group(1).strip())
        except Exception:
            continue
        stack = data if isinstance(data, list) else [data]
        for c in list(stack):
            if isinstance(c, dict):
                if isinstance(c.get("@graph"), list):
                    stack.extend(c["@graph"])
                ab = c.get("articleBody")
                if isinstance(ab, str):
                    for para in re.split(r'\n\s*\n', ab):
                        para = re.sub(r'\s+', " ", para).strip()
                        if len(para) >= 40 and para not in seen:
                            seen.add(para); out.append(para); body_chars += len(para)
    if body_chars < 200:
        m = re.search(r'<meta[^>]+(?:property|name)="(?:og:description|description)"[^>]+content="([^"]+)"',
                      html, re.I)
        if m:
            desc = re.sub(r'\s+', " ", m.group(1)).strip()
            if desc and desc not in seen:
                out.append(desc)

text = "\n\n".join(out)
if len([1 for line in out if not line.startswith("# ")]) == 0 and d.title:
    text += "\n\nThis page's text couldn't be extracted (it may load its content"
    text += " with JavaScript). Open it in a browser for the full article:\n\n" + sys.argv[2]
if len(text) > 60000:
    text = text[:60000] + "…"
if not text.strip():
    text = "No readable text found on this page.\n\n" + sys.argv[2]
print(text)
PY
)"

[ -n "$TEXT" ] || TEXT="Could not read the page."$'\n\n'"$URL"
publish "$TEXT"
exit 0
