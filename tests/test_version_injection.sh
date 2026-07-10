#!/usr/bin/env bash
# test_version_injection.sh — CLAUDE.md §6.7: the site's build semver (package.json
# version) must be exposed on the page and must never drift. site/index.html and
# site/version.js carry a %%APP_VERSION%% placeholder; `make repo` runs
# packaging/inject-site-version.sh right after copying the site files into $DIST,
# which replaces the placeholder with the real package.json version.
#
# This test exercises packaging/inject-site-version.sh directly (in a scratch dist
# dir) rather than the full `make repo` chain, since that needs the Debian
# packaging toolchain (dpkg-deb/apt-ftparchive/gpg) not available on every dev
# host — the substitution logic itself has no such dependency.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

fails=0
contains() { # contains DESC HAYSTACK NEEDLE
  case "$2" in *"$3"*) printf 'ok   - %s\n' "$1" ;;
    *) printf 'FAIL - %s\n     %q not found in output\n' "$1" "$3"; fails=$((fails + 1)) ;; esac
}
not_contains() { # not_contains DESC HAYSTACK NEEDLE
  case "$2" in *"$3"*) printf 'FAIL - %s\n     %q unexpectedly found in output\n' "$1" "$3"; fails=$((fails + 1)) ;;
    *) printf 'ok   - %s\n' "$1" ;; esac
}
file_exists() { # file_exists DESC PATH
  if [ -f "$2" ]; then printf 'ok   - %s\n' "$1"; else
    printf 'FAIL - %s\n     %q does not exist\n' "$1" "$2"; fails=$((fails + 1)); fi
}

# --- source files carry the placeholder, not a hardcoded literal ------------------
file_exists "site/version.js exists" "$ROOT/site/version.js"
version_js="$(cat "$ROOT/site/version.js")"
contains "site/version.js sets window.__APP_VERSION__ from the placeholder" "$version_js" 'window.__APP_VERSION__ = "%%APP_VERSION%%"'

html="$(cat "$ROOT/site/index.html")"
contains "index.html carries the <meta app-version> placeholder" "$html" '<meta name="app-version" content="%%APP_VERSION%%"'
contains "index.html footer carries the version-tag placeholder" "$html" 'data-testid="footer-app-version"'
contains "index.html loads /version.js" "$html" 'src="/version.js"'
contains "index.html embeds the shared bug-report widget scoped to this repo" "$html" '<script src="https://bugreport.dig.net/widget.js" data-repo="apt.dig.net"'

# --- packaging/inject-site-version.sh actually performs the substitution ----------
file_exists "packaging/inject-site-version.sh exists" "$ROOT/packaging/inject-site-version.sh"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
cp "$ROOT/site/index.html" "$ROOT/site/version.js" "$SCRATCH/"
bash "$ROOT/packaging/inject-site-version.sh" "$SCRATCH"

pkg_version="$(grep -m1 '"version"' "$ROOT/package.json" | sed -E 's/.*"version": *"([^"]+)".*/\1/')"
contains "package.json has a real semver" "$pkg_version" "."

out_html="$(cat "$SCRATCH/index.html")"
out_js="$(cat "$SCRATCH/version.js")"
not_contains "injected index.html no longer carries the placeholder" "$out_html" "%%APP_VERSION%%"
not_contains "injected version.js no longer carries the placeholder" "$out_js" "%%APP_VERSION%%"
contains "injected index.html carries the real package.json version" "$out_html" "content=\"$pkg_version\""
contains "injected version.js carries the real package.json version" "$out_js" "window.__APP_VERSION__ = \"$pkg_version\""

# --- Makefile wiring: version.js copied + injector actually invoked ---------------
makefile="$(cat "$ROOT/Makefile")"
contains "Makefile copies version.js into dist" "$makefile" "version.js"
contains "Makefile invokes packaging/inject-site-version.sh" "$makefile" "inject-site-version.sh"

if [ "$fails" -ne 0 ]; then printf '\n%d assertion(s) failed\n' "$fails" >&2; exit 1; fi
printf '\nall version-injection assertions passed\n'
