#!/usr/bin/env bash
# test_build_paths.sh — exercise build_one's two acquisition paths against a stubbed
# network, so the behaviour is proven without a GitHub release.
#
# WHY stub only `fetch_asset` and nothing else: everything downstream of the download
# — which template is resolved, whether a prebuilt .deb is copied or rebuilt, whether a
# separately-published binary reaches /usr/bin — is production code, and a test that
# stubbed it would be asserting its own doubles. `fetch_asset` is the single seam that
# touches the network; each stub below answers ONLY for the asset names the real
# upstream release publishes and returns 1 for anything else, so a template that
# resolves to a name upstream does not publish fails here exactly as it would in CI.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"
# shellcheck source=../packaging/lib/common.sh
. "$ROOT/packaging/lib/common.sh"
# shellcheck source=../packaging/config.sh
. "$ROOT/packaging/config.sh"
# STAGE_ONLY makes build-deb.sh define its functions without running main().
# shellcheck source=../packaging/build-deb.sh
STAGE_ONLY=1 . "$ROOT/packaging/build-deb.sh"

# NOT named `work`: build_one declares a `local work` scratch dir, and bash scoping is
# dynamic — a stub called from build_one would resolve a `$work` of its own to
# build_one's scratch, which is deleted before the assertions run.
TWORK="$(mktemp -d)"
trap 'rm -rf "$TWORK"' EXIT

# ---- path 1: a package that publishes its OWN .deb is passed through, not rebuilt ---
#
# The stub answers only for the real upstream amd64 name and refuses arm64 (which
# upstream genuinely does not publish), so the arm64 skip is exercised too. The payload
# is a recognisable byte string: a rebuild would produce a real ar archive and could not
# reproduce it, which is what makes "passed through" distinguishable from "rebuilt with
# equivalent metadata" rather than merely consistent with it.
PREBUILT_MARKER='UPSTREAM-DEB-PAYLOAD-NOT-REBUILT'
# shellcheck disable=SC2317,SC2329  # invoked indirectly, from build_one.
fetch_asset() {
  case "$3" in
    dig-dns_0.15.1-1_amd64.deb) printf '%s' "$PREBUILT_MARKER" > "$4"; return 0 ;;
    *) return 1 ;;
  esac
}
pool="$TWORK/pool-dns"; mkdir -p "$pool"
DIG_DNS_TAG=v0.15.1 build_one dig-dns "$pool" 2>"$TWORK/dns.log"

file_exists "dig-dns lands in the pool under its upstream filename" \
  "$pool/dig-dns_0.15.1-1_amd64.deb"
check "dig-dns .deb is upstream's bytes, verbatim" \
  "$PREBUILT_MARKER" "$(cat "$pool/dig-dns_0.15.1-1_amd64.deb" 2>/dev/null || true)"
# A prebuilt package must not also emit a rebuilt artifact under the derived name.
check "dig-dns is not additionally rebuilt" \
  "" "$(find "$pool" -maxdepth 1 -type f ! -name 'dig-dns_0.15.1-1_amd64.deb' -printf '%f ')"
contains "the missing arm64 .deb is a non-fatal skip" "$(cat "$TWORK/dns.log")" "arm64"

# ---- path 2: a rebuilt package ships its own binary, and nothing else ---------------
#
# stage_deb is replaced here (and only here) to record its arguments: the real one needs
# dpkg-deb, which is absent on most dev hosts, and the property under test is WHICH
# binaries reach staging. The stub still answers for `dign-12.28.0-linux-x64` — an asset
# dig-app genuinely publishes — so a build that reintroduced `/usr/bin/dign` would
# succeed at fetching it and be caught below, rather than passing because the download
# happened to fail.
# shellcheck disable=SC2317,SC2329  # invoked indirectly, from build_one.
fetch_asset() {
  case "$3" in
    dig-app-12.28.0-linux-x64-headless) printf 'DIG-APP-HEADLESS' > "$4"; return 0 ;;
    dign-12.28.0-linux-x64)             printf 'DIGN-CLI'         > "$4"; return 0 ;;
    *) return 1 ;;
  esac
}
# The recording goes to a FILE, not a variable: stage_deb is invoked inside a command
# substitution, so a variable assignment would be made in a subshell and lost — the
# test would then read an empty argument list and pass no matter what was staged.
staged_file="$TWORK/staged-args"
# shellcheck disable=SC2317,SC2329  # invoked indirectly, from build_one.
stage_deb() {
  printf '%s' "$*" > "$staged_file"
  local out="$6"
  printf 'deb' > "$out/$1_$(deb_version "$2")_$3.deb"
  printf '%s\n' "$out/$1_$(deb_version "$2")_$3.deb"
}
pool="$TWORK/pool-app"; mkdir -p "$pool"
DIG_APP_TAG=v12.28.0 build_one dig-app "$pool" 2>"$TWORK/app.log"

file_exists "dig-app produces a .deb for amd64" "$pool/dig-app_12.28.0_amd64.deb"
# stage_deb's arguments are PKG TAG ARCH BIN STAGE POOL, then one NAME:PATH pair per
# extra binary. A seventh argument means the package installs something beyond its own
# binary — for dig-app that would be `/usr/bin/dign`, which dig_ecosystem#1724 has not
# awarded to either dig-app or dig-node.
staged_args="$(cat "$staged_file" 2>/dev/null || true)"
check "dig-app stages exactly its own binary, with no extras" \
  "6" "$(set -- $staged_args; printf '%s' "$#")"
not_contains "dign is not packaged while its owner is undecided" "$staged_args" "dign"

assert_summary "build-paths"
