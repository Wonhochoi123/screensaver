#!/bin/bash
# =============================================================================
#  build.sh — assemble the distributable installer from src/.
#
#  Source of truth is src/: the orchestration skeleton (src/installer.tmpl) plus
#  the individual app files (src/config/*, src/app/*, src/desktop/*,
#  src/fontconfig/*). This script stitches them back into ScreenSaverMaster.sh,
#  the single-file installer that README's `curl … | bash` line fetches.
#
#  The template keeps each `cat > "<dest>" << DELIM` opener and its DELIM
#  terminator; only the body is replaced with a line `@@INCLUDE <relpath>`.
#  Because the heredoc quoting lives in the template (not the src files), every
#  file keeps its exact expansion behaviour: literal `<< 'EOF'` blocks stay
#  literal, and the unquoted ones (screensaver.conf, the .desktop files, the
#  fontconfig file) still expand $VARS at install time.
#
#  NEVER hand-edit ScreenSaverMaster.sh — edit src/ and re-run this.
# =============================================================================
set -eu
cd "$(dirname "$0")"

TMPL="src/installer.tmpl"
OUT="ScreenSaverMaster.sh"

[ -f "$TMPL" ] || { echo "build: missing $TMPL" >&2; exit 1; }

# Expand every "@@INCLUDE <relpath>" line with the verbatim contents of src/<relpath>.
awk '
/^@@INCLUDE / {
    rel = $2
    path = "src/" rel
    if ((getline probe < path) < 0) {
        print "build: missing include " path > "/dev/stderr"
        exit 1
    }
    close(path)
    while ((getline l < path) > 0) print l
    close(path)
    next
}
{ print }
' "$TMPL" > "$OUT.tmp"

mv "$OUT.tmp" "$OUT"
chmod +x "$OUT"
echo "built $OUT from $TMPL ($(wc -l < "$OUT") lines)"
