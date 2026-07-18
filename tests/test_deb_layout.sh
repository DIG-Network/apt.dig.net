#!/usr/bin/env bash
# test_deb_layout.sh — pin the DEBIAN/control rendering + the deb on-disk layout,
# and (when dpkg-deb is present) build a real .deb from a fake binary and assert its
# contents/metadata. The control-file assertions run everywhere; the dpkg-deb build
# is skipped (not failed) where the tool is absent.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../packaging/lib/common.sh
. "$ROOT/packaging/lib/common.sh"
# shellcheck source=../packaging/config.sh
. "$ROOT/packaging/config.sh"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"

# --- control rendering: dig-store (no service) ---
ctrl="$(render_control dig-store v0.14.0 amd64 1234)"
contains "dig-store control has Package"        "$ctrl" "Package: dig-store"
contains "dig-store control has deb Version"    "$ctrl" "Version: 0.14.0"
contains "dig-store control has Architecture"   "$ctrl" "Architecture: amd64"
contains "dig-store control has Section"         "$ctrl" "Section: utils"
contains "dig-store control has Installed-Size" "$ctrl" "Installed-Size: 1234"
contains "dig-store control has Maintainer"     "$ctrl" "Maintainer: DIG Network"
contains "dig-store control has Description"    "$ctrl" "Description: DIG Network content-addressable store CLI"

# --- control rendering: dig-node (service; key-segment mapping) ---
nctrl="$(render_control dig-node v0.5.29 arm64)"
contains "dig-node control has Package"      "$nctrl" "Package: dig-node"
contains "dig-node control Version stripped" "$nctrl" "Version: 0.5.29"
contains "dig-node control Architecture"     "$nctrl" "Architecture: arm64"
contains "dig-node control Depends adduser"  "$nctrl" "adduser"
# Installed-Size omitted when not supplied.
case "$nctrl" in *"Installed-Size"*) printf 'FAIL - dig-node omits Installed-Size when unset\n'; fails=$((fails+1));;
  *) printf 'ok   - dig-node omits Installed-Size when unset\n';; esac

# --- extra_bin_path: the digs alias lives beside the main bin in the archive ---
check "extra_bin_path at archive root"     "digs"     "$(extra_bin_path dig-store digs)"
check "extra_bin_path under a subdir"      "bin/digs" "$(extra_bin_path bin/dig-store digs)"

# --- config: dig-store declares digs as an extra binary + digstore as a compat symlink ---
check "dig-store EXTRA_BINS declares digs"          "digs"     "$(pkg_var dig-store EXTRA_BINS)"
check "dig-store COMPAT_SYMLINKS declares digstore" "digstore" "$(pkg_var dig-store COMPAT_SYMLINKS)"

# --- a real dpkg-deb build round-trip (skipped if tooling absent) ---
if command -v dpkg-deb >/dev/null 2>&1; then
  work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
  # Lay out a minimal dig-node deb with a fake binary + the systemd unit, via the
  # same staging helper the real build uses.
  # shellcheck source=../packaging/build-deb.sh
  STAGE_ONLY=1 . "$ROOT/packaging/build-deb.sh"
  fakebin="$work/dig-node"; printf '#!/bin/sh\necho dig-node fake\n' > "$fakebin"
  out="$work/out"; mkdir -p "$out"
  stage_deb dig-node v0.5.29 amd64 "$fakebin" "$work/stage" "$out"
  deb="$(ls "$out"/dig-node_*_amd64.deb)"
  check "dpkg-deb produced a .deb" "1" "$([ -f "$deb" ] && echo 1 || echo 0)"

  # Inspect control + contents of the built deb.
  info="$(dpkg-deb -I "$deb")"
  contains "built deb control: Package" "$info" "Package: dig-node"
  contains "built deb control: amd64"   "$info" "Architecture: amd64"
  files="$(dpkg-deb -c "$deb")"
  contains "built deb ships the binary at /usr/bin/dig-node" "$files" "./usr/bin/dig-node"
  contains "built deb ships the systemd unit" "$files" "./lib/systemd/system/dig-node.service"
  # The maintainer scripts live in the CONTROL archive; dpkg-deb -e extracts them
  # regardless of the control-tarball compression (gz/xz/zst).
  ctrldir="$work/ctrl"; rm -rf "$ctrldir"; dpkg-deb -e "$deb" "$ctrldir"
  check "built deb ships postinst" "1" "$([ -x "$ctrldir/postinst" ] && echo 1 || echo 0)"
  check "built deb ships prerm"    "1" "$([ -x "$ctrldir/prerm" ] && echo 1 || echo 0)"
  check "built deb ships postrm"   "1" "$([ -x "$ctrldir/postrm" ] && echo 1 || echo 0)"
  contains "postinst enables the service" "$(cat "$ctrldir/postinst")" "enable --now dig-node"
  # The unit must enable+start dig-node and run loopback-bound as the service user.
  unit="$(dpkg-deb --fsys-tarfile "$deb" | tar xzO ./lib/systemd/system/dig-node.service 2>/dev/null || dpkg-deb --fsys-tarfile "$deb" | tar xO ./lib/systemd/system/dig-node.service)"
  contains "unit runs as dig-node user"   "$unit" "User=dig-node"
  contains "unit sets the cache dir"      "$unit" "/var/lib/dig-node"
  contains "unit is loopback-scoped"      "$unit" "127.0.0.1"
  contains "unit WantedBy multi-user"     "$unit" "WantedBy=multi-user.target"

  # --- dig-store ships the `digs` alias binary alongside `dig-store` (issue #434 /
  # digstore#16: `digs` is a first-class alias binary, `digs <args>` == `dig-store
  # <args>`) AND a transitional `digstore` -> `dig-store` compat symlink (the repo was
  # renamed digstore -> dig-store, #703/#704; the symlink keeps existing `digstore`
  # scripts working). stage_deb takes extra NAME:SRC pairs beyond the main binary and
  # renders the package's COMPAT_SYMLINKS. ---
  fakedigstore="$work/dig-store"; printf '#!/bin/sh\necho dig-store fake\n' > "$fakedigstore"
  fakedigs="$work/digs"; printf '#!/bin/sh\necho digs fake\n' > "$fakedigs"
  digstore_deb="$(stage_deb dig-store v0.14.0 amd64 "$fakedigstore" "$work/stage-dig-store" "$out" "digs:$fakedigs")"
  check "dig-store stage_deb produced a .deb" "1" "$([ -f "$digstore_deb" ] && echo 1 || echo 0)"
  digstore_files="$(dpkg-deb -c "$digstore_deb")"
  contains "dig-store deb ships /usr/bin/dig-store" "$digstore_files" "./usr/bin/dig-store"
  contains "dig-store deb ships /usr/bin/digs (alias binary)" "$digstore_files" "./usr/bin/digs"
  # The transitional symlink shows in `dpkg-deb -c` as `./usr/bin/digstore -> dig-store`.
  contains "dig-store deb ships /usr/bin/digstore compat symlink" "$digstore_files" "./usr/bin/digstore -> dig-store"
else
  printf 'skip - dpkg-deb not present; control rendering still asserted\n'
fi

assert_summary "deb-layout"
