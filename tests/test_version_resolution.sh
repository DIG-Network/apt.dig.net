#!/usr/bin/env bash
# test_version_resolution.sh — pin the version + asset-name resolution contract.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../packaging/lib/common.sh
. "$ROOT/packaging/lib/common.sh"
# shellcheck source=../packaging/config.sh
. "$ROOT/packaging/config.sh"

fails=0
check() { # check DESC EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n     expected: %q\n     actual:   %q\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

# strip_v: tolerates both v-prefixed and bare tags.
check "strip_v drops leading v"        "1.2.3"   "$(strip_v v1.2.3)"
check "strip_v leaves bare untouched"  "1.2.3"   "$(strip_v 1.2.3)"
check "strip_v keeps inner v"          "1.2.3v"  "$(strip_v 1.2.3v)"

# deb_version: Debian-policy-valid upstream version.
check "deb_version strips v"            "0.6.0"   "$(deb_version v0.6.0)"
check "deb_version prerelease -> ~"     "0.6.0~rc1" "$(deb_version v0.6.0-rc1)"
check "deb_version multi -> ~"          "1.0.0~beta~2" "$(deb_version 1.0.0-beta-2)"

# asset_name: template substitution drives which release asset to download.
# (Accessed via pkg_var — the intended accessor — not the raw PKG_* var.)
check "asset_name dig-store amd64" \
  "dig-store-0.14.0-x86_64-unknown-linux-gnu.tar.gz" \
  "$(asset_name "$(pkg_var dig-store ASSET_TEMPLATE)" v0.14.0 "$(apt_asset_arch amd64)")"
check "asset_name dig-store arm64" \
  "dig-store-0.14.0-aarch64-unknown-linux-gnu.tar.gz" \
  "$(asset_name "$(pkg_var dig-store ASSET_TEMPLATE)" v0.14.0 "$(apt_asset_arch arm64)")"
# dig-node overrides the arch token (linux-x64), exercised via asset_arch_for.
check "asset_name dig-node amd64" \
  "dig-node-0.5.29-linux-x64" \
  "$(asset_name "$(pkg_var dig-node ASSET_TEMPLATE)" v0.5.29 "$(asset_arch_for dig-node amd64)")"
check "asset_name dig-node arm64" \
  "dig-node-0.5.29-linux-arm64" \
  "$(asset_name "$(pkg_var dig-node ASSET_TEMPLATE)" v0.5.29 "$(asset_arch_for dig-node arm64)")"

# apt_asset_arch: the default Debian-arch -> upstream-token map.
check "apt_asset_arch amd64"  "x86_64"  "$(apt_asset_arch amd64)"
check "apt_asset_arch arm64"  "aarch64" "$(apt_asset_arch arm64)"
# asset_arch_for honours per-package overrides + falls back to the default map.
check "asset_arch_for dig-node amd64 override" "x64"    "$(asset_arch_for dig-node amd64)"
check "asset_arch_for dig-store amd64 default"  "x86_64" "$(asset_arch_for dig-store amd64)"

# pkg_var: the dig-node -> dig_node key-segment mapping must resolve.
check "pkg_var dig-node BIN"    "dig-node" "$(pkg_var dig-node BIN)"
check "pkg_var dig-node SERVICE" "yes"     "$(pkg_var dig-node SERVICE)"
check "pkg_var dig-store SERVICE" "no"     "$(pkg_var dig-store SERVICE)"
check "pkg_var dig-store BIN"     "dig-store" "$(pkg_var dig-store BIN)"

if [ "$fails" -ne 0 ]; then
  printf '\n%d assertion(s) failed\n' "$fails" >&2
  exit 1
fi
printf '\nall version-resolution assertions passed\n'
