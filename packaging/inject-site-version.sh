#!/usr/bin/env bash
# inject-site-version.sh — replace the %%APP_VERSION%% build-version placeholder
# (CLAUDE.md §6.7) in the copied static site files with the real semver from
# package.json. Called by `make repo` right after site/index.html + site/version.js
# are copied into $DIST, so the exposed version can never drift from package.json
# (the SAME version that drives the tag-on-merge release pipeline).
set -euo pipefail
DIST="${1:?usage: inject-site-version.sh <dist-dir>}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

VERSION="$(grep -m1 '"version"' "$HERE/package.json" | sed -E 's/.*"version": *"([^"]+)".*/\1/')"
if [ -z "$VERSION" ]; then
  echo "inject-site-version.sh: could not read version from $HERE/package.json" >&2
  exit 1
fi

injected=0
for f in "$DIST/index.html" "$DIST/version.js"; do
  if [ -f "$f" ]; then
    sed -i "s/%%APP_VERSION%%/$VERSION/g" "$f"
    injected=$((injected + 1))
  fi
done

echo "inject-site-version.sh: injected app version $VERSION into $injected file(s) under $DIST"
