# shellcheck shell=bash
# common.sh — pure, testable helpers shared by the deb builder and the repo generator.
#
# Everything here is deliberately side-effect-free string logic (version parsing,
# variable lookup, control-file rendering, asset-name resolution) so the test suite
# can assert it without GitHub, AWS, or root. The I/O-heavy steps (download, dpkg-deb,
# gpg) live in build-deb.sh / generate-repo.sh and call these.

set -euo pipefail

# log MSG... -> stderr (so --json/stdout payloads stay clean per AGENT_FRIENDLY.md).
log()  { printf '%s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# pkg_var PKG SUFFIX -> value of PKG_<sanitised>_<SUFFIX>.
# '-' is illegal in a shell var name, so a package id like "dig-node" maps to the
# "dig_node" key segment. This is the single place that mapping lives.
pkg_var() {
  local pkg="$1" suffix="$2" key
  key="PKG_$(printf '%s' "$pkg" | tr '-' '_')_${suffix}"
  printf '%s' "${!key-}"
}

# strip_v VERSION -> VERSION without a single leading 'v' (v1.2.3 -> 1.2.3; 1.2.3 -> 1.2.3).
strip_v() {
  local v="$1"
  printf '%s' "${v#v}"
}

# deb_version VERSION -> a Debian-policy-valid upstream version.
# Debian forbids a leading non-digit in the upstream version, and disallows '-' except
# as the debian-revision separator. We strip the leading 'v' and translate any '-'
# inside a prerelease (e.g. 1.2.3-rc1) to '~' (which sorts *before* the release, the
# correct semver-prerelease ordering in dpkg).
deb_version() {
  local v
  v="$(strip_v "$1")"
  printf '%s' "${v//-/\~}"
}

# asset_name TEMPLATE VER ARCH -> the concrete asset file name.
# Substitutes {ver} (version sans 'v') and {arch} (upstream arch token).
asset_name() {
  local tmpl="$1" ver="$2" arch="$3"
  ver="$(strip_v "$ver")"
  tmpl="${tmpl//\{ver\}/$ver}"
  tmpl="${tmpl//\{arch\}/$arch}"
  printf '%s' "$tmpl"
}

# extra_bin_path ARCHIVE_BIN_PATH NAME -> the archive-relative path of an "extra"
# binary (e.g. dig-store's `digs` alias, PKG_*_EXTRA_BINS) that ships in the SAME
# release archive, alongside the main binary at ARCHIVE_BIN_PATH — same directory,
# different filename. Root-level main bin ("dig-store") -> root-level extra ("digs");
# a nested main bin ("bin/dig-store") -> the same nested dir ("bin/digs").
extra_bin_path() {
  local inner="$1" name="$2" dir
  dir="$(dirname -- "$inner")"
  if [ "$dir" = "." ]; then
    printf '%s' "$name"
  else
    printf '%s/%s' "$dir" "$name"
  fi
}

# render_control PKG VERSION DEBARCH INSTALLED_SIZE_KB -> a DEBIAN/control file on stdout.
# Pure string rendering from config.sh + the args; no filesystem reads. This is the
# contract the deb-layout test pins.
render_control() {
  local pkg="$1" version="$2" arch="$3" size_kb="${4:-}"
  local section depends maintainer homepage desc_short desc_long
  section="$(pkg_var "$pkg" SECTION)"
  depends="$(pkg_var "$pkg" DEPENDS)"
  maintainer="$(pkg_var "$pkg" MAINTAINER)"
  homepage="$(pkg_var "$pkg" HOMEPAGE)"
  desc_short="$(pkg_var "$pkg" DESC_SHORT)"
  desc_long="$(pkg_var "$pkg" DESC_LONG)"

  printf 'Package: %s\n' "$pkg"
  printf 'Version: %s\n' "$(deb_version "$version")"
  printf 'Architecture: %s\n' "$arch"
  printf 'Maintainer: %s\n' "$maintainer"
  printf 'Section: %s\n' "$section"
  printf 'Priority: optional\n'
  [ -n "$depends" ] && printf 'Depends: %s\n' "$depends"
  [ -n "$homepage" ] && printf 'Homepage: %s\n' "$homepage"
  [ -n "$size_kb" ] && printf 'Installed-Size: %s\n' "$size_kb"
  printf 'Description: %s\n' "$desc_short"
  # desc_long is already indented with a leading space per Debian control multiline rules.
  [ -n "$desc_long" ] && printf '%s\n' "$desc_long"
}

# sha256_of FILE -> lowercase hex sha256 (portable: sha256sum or shasum -a 256).
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
