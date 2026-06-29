#!/usr/bin/env bash
# run.sh — run the whole apt.dig.net test suite. Each test self-skips legs whose
# tooling (dpkg-deb / apt-ftparchive / gpg) is absent, so this is safe to run on a
# bare host; CI provides the full Debian toolchain for the real-build legs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in test_version_resolution.sh test_deb_layout.sh test_repo_metadata.sh; do
  printf '\n========== %s ==========\n' "$t"
  if bash "$HERE/$t"; then :; else rc=1; fi
done
exit "$rc"
