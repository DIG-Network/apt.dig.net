#!/usr/bin/env bash
# run.sh — run the whole apt.dig.net test suite. Each test self-skips legs whose
# tooling (dpkg-deb / apt-ftparchive / gpg) is absent, so this is safe to run on a
# bare host; CI provides the full Debian toolchain for the real-build legs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in test_version_resolution.sh test_deb_layout.sh test_repo_metadata.sh test_site_baseline.sh; do
  printf '\n========== %s ==========\n' "$t"
  if bash "$HERE/$t"; then :; else rc=1; fi
done

# Accessibility gate (WCAG 2.2 AA via axe-core + Playwright). Needs Node deps +
# a Chromium build; self-skips when they are absent so a bare host still runs the
# shell suite. CI installs them (see .github/workflows/ci.yml -> a11y job).
printf '\n========== a11y (axe WCAG 2.2 AA) ==========\n'
if command -v node >/dev/null 2>&1 && [ -d "$HERE/a11y/node_modules/@axe-core" ]; then
  if ( cd "$HERE/a11y" && npm test ); then :; else rc=1; fi
else
  echo "SKIP - node / tests/a11y deps not installed (run: cd tests/a11y && npm ci && npx playwright install chromium)"
fi

exit "$rc"
