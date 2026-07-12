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

fails=0
check() { if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; else
  printf 'FAIL - %s\n     expected: %q\n     actual:   %q\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi; }
contains() { # contains DESC HAYSTACK NEEDLE
  case "$2" in *"$3"*) printf 'ok   - %s\n' "$1" ;;
    *) printf 'FAIL - %s\n     %q not found in output\n' "$1" "$3"; fails=$((fails + 1)) ;; esac; }

# --- control rendering: digstore (no service) ---
ctrl="$(render_control digstore v0.6.0 amd64 1234)"
contains "digstore control has Package"        "$ctrl" "Package: digstore"
contains "digstore control has deb Version"    "$ctrl" "Version: 0.6.0"
contains "digstore control has Architecture"   "$ctrl" "Architecture: amd64"
contains "digstore control has Section"         "$ctrl" "Section: utils"
contains "digstore control has Installed-Size" "$ctrl" "Installed-Size: 1234"
contains "digstore control has Maintainer"     "$ctrl" "Maintainer: DIG Network"
contains "digstore control has Description"    "$ctrl" "Description: DIG Network content-addressable store CLI"

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
check "extra_bin_path at archive root"     "digs"     "$(extra_bin_path digstore digs)"
check "extra_bin_path under a subdir"      "bin/digs" "$(extra_bin_path bin/digstore digs)"

# --- config: digstore declares digs as an extra binary to ship alongside it ---
check "digstore EXTRA_BINS declares digs" "digs" "$(pkg_var digstore EXTRA_BINS)"

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

  # --- digstore ships the `digs` alias binary alongside `digstore` (issue #434 /
  # digstore#16: `digs` is a first-class alias binary, `digs <args>` == `digstore
  # <args>`). stage_deb takes extra NAME:SRC pairs beyond the main binary. ---
  fakedigstore="$work/digstore"; printf '#!/bin/sh\necho digstore fake\n' > "$fakedigstore"
  fakedigs="$work/digs"; printf '#!/bin/sh\necho digs fake\n' > "$fakedigs"
  digstore_deb="$(stage_deb digstore v0.12.0 amd64 "$fakedigstore" "$work/stage-digstore" "$out" "digs:$fakedigs")"
  check "digstore stage_deb produced a .deb" "1" "$([ -f "$digstore_deb" ] && echo 1 || echo 0)"
  digstore_files="$(dpkg-deb -c "$digstore_deb")"
  contains "digstore deb ships /usr/bin/digstore" "$digstore_files" "./usr/bin/digstore"
  contains "digstore deb ships /usr/bin/digs (alias binary)" "$digstore_files" "./usr/bin/digs"
else
  printf 'skip - dpkg-deb not present; control rendering still asserted\n'
fi

if [ "$fails" -ne 0 ]; then printf '\n%d assertion(s) failed\n' "$fails" >&2; exit 1; fi
printf '\nall deb-layout assertions passed\n'
