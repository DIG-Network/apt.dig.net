#!/usr/bin/env bash
# test_site_baseline.sh — guard the CLAUDE.md frontend-baseline contract
# (llms.txt + accessibility + SEO) for the site/ static assets that `make repo`
# copies verbatim into the repo root (see Makefile's `repo` target: `cp
# site/index.html site/llms.txt "$DIST/"`). site/sitemap.xml and
# site/robots.txt are copied the same way once added to that cp line, so this
# test also pins the Makefile wiring itself — a file only in site/ but not
# copied by `make repo` would silently never reach the live site.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SITE="$ROOT/site"

fails=0
check() { if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; else
  printf 'FAIL - %s\n     expected: %q\n     actual:   %q\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi; }
contains() { # contains DESC HAYSTACK NEEDLE
  case "$2" in *"$3"*) printf 'ok   - %s\n' "$1" ;;
    *) printf 'FAIL - %s\n     %q not found in output\n' "$1" "$3"; fails=$((fails + 1)) ;; esac; }
file_exists() { # file_exists DESC PATH
  if [ -f "$2" ]; then printf 'ok   - %s\n' "$1"; else
    printf 'FAIL - %s\n     %q does not exist\n' "$1" "$2"; fails=$((fails + 1)); fi; }

file_exists "site/llms.txt exists" "$SITE/llms.txt"
llms="$(cat "$SITE/llms.txt")"
contains "llms.txt references sitemap.xml" "$llms" "sitemap.xml"
file_exists "site/sitemap.xml exists" "$SITE/sitemap.xml"
file_exists "site/robots.txt exists" "$SITE/robots.txt"
file_exists "site/index.html exists" "$SITE/index.html"

html="$(cat "$SITE/index.html")"
sitemap="$(cat "$SITE/sitemap.xml" 2>/dev/null || true)"
robots="$(cat "$SITE/robots.txt" 2>/dev/null || true)"

# --- robots.txt: allows indexing, points at the sitemap -----------------
contains "robots.txt allows all user-agents" "$robots" "User-agent: *"
contains "robots.txt allows /"               "$robots" "Allow: /"
contains "robots.txt points at sitemap.xml"  "$robots" "Sitemap: https://apt.dig.net/sitemap.xml"

# --- sitemap.xml: well-formed, lists the public page ---------------------
contains "sitemap.xml is a urlset"        "$sitemap" "<urlset"
contains "sitemap.xml lists the site root" "$sitemap" "<loc>https://apt.dig.net/</loc>"
contains "sitemap.xml has a lastmod"       "$sitemap" "<lastmod>"

# --- index.html: SEO meta -------------------------------------------------
contains "index.html has a <title>"        "$html" "<title>"
contains "index.html has a meta description" "$html" 'name="description"'
contains "index.html has a canonical link" "$html" 'rel="canonical" href="https://apt.dig.net/"'
contains "index.html has og:title"         "$html" 'property="og:title"'
contains "index.html has og:description"   "$html" 'property="og:description"'
contains "index.html has og:type"          "$html" 'property="og:type"'
contains "index.html has og:url"           "$html" 'property="og:url"'
contains "index.html has og:image"         "$html" 'property="og:image"'
contains "index.html has twitter:card"     "$html" 'name="twitter:card"'
contains "index.html has twitter:title"    "$html" 'name="twitter:title"'
contains "index.html has JSON-LD structured data" "$html" 'application/ld+json'
contains "index.html links the feed for discoverability" "$html" 'type="application/atom+xml"'

# JSON-LD must be valid JSON (only checked if a JSON tool is available).
if command -v python3 >/dev/null 2>&1; then
  ld="$(printf '%s' "$html" | python3 -c "
import sys, re, json
html = sys.stdin.read()
m = re.search(r'<script type=\"application/ld\+json\">(.*?)</script>', html, re.S)
assert m, 'no JSON-LD script tag'
data = json.loads(m.group(1))
assert '@context' in data and '@type' in data
print('valid')
" 2>&1)"
  check "JSON-LD parses as valid JSON with @context/@type" "valid" "$ld"
fi

# --- index.html: accessibility ---------------------------------------------
contains "index.html declares lang=en"     "$html" '<html lang="en">'
contains "index.html has a skip-to-content link" "$html" 'class="skip-link"'
h1_count="$(printf '%s' "$html" | grep -c '<h1')"
check "index.html has exactly one <h1>" "1" "$h1_count"
contains "index.html defines :focus-visible styling" "$html" ":focus-visible"
contains "index.html respects prefers-reduced-motion" "$html" "prefers-reduced-motion"

# --- Makefile wiring: site/sitemap.xml + robots.txt actually get published ---
makefile="$(cat "$ROOT/Makefile")"
contains "Makefile copies sitemap.xml into dist" "$makefile" "sitemap.xml"
contains "Makefile copies robots.txt into dist"  "$makefile" "robots.txt"
contains "Makefile copies og-image.svg into dist" "$makefile" "og-image.svg"
file_exists "site/og-image.svg exists" "$SITE/og-image.svg"

if [ "$fails" -ne 0 ]; then printf '\n%d assertion(s) failed\n' "$fails" >&2; exit 1; fi
printf '\nall frontend-baseline assertions passed\n'
