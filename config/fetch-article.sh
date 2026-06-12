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
for head, t in d.blocks:
    if t in seen:
        continue
    # Keep headings; drop tiny non-heading crumbs (nav labels, buttons, bylines).
    if not head and len(t) < 60:
        continue
    seen.add(t)
    out.append(("# " + t) if head else t)

text = "\n\n".join(out)
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
