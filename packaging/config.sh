# shellcheck shell=bash
# shellcheck disable=SC2034
# (PKG_* / APT_* are consumed by indirect expansion — pkg_var's ${!key} — and by the
#  sourcing scripts, which shellcheck cannot trace. This is a pure data file.)
# config.sh — declarative package catalogue for the DIG APT repository.
#
# WHY a data file (not logic): the .deb layout, the systemd unit, and the apt-repo
# generator are all driven from this single source of truth, so adding a package or
# bumping an asset-name pattern is a data edit, not a code change. `build-deb.sh`
# sources this and reads the `PKG_*` maps; tests source it to assert the contract.
#
# Each package declares:
#   - the GitHub repo that publishes its release binaries,
#   - the per-arch asset-name TEMPLATE (with {ver}/{arch} placeholders) used to find
#     the release asset to download,
#   - the Debian arch -> upstream-asset-arch token map,
#   - Debian control metadata (section, depends, description),
#   - whether the package installs a systemd service.
#
# Asset reality (2026-06): the digstore/dig-node GitHub releases do not yet publish a
# raw per-arch CLI binary tarball under these names. The patterns below are the names
# the packaging EXPECTS; build-deb.sh resolves them at build time and SKIPS (non-fatal)
# any arch whose asset is absent, so the pipeline stays green until upstream publishes
# matching assets. See README "Upstream asset contract".

# Debian architectures we attempt to build, in order. arm64 is best-effort: skipped
# when no matching upstream asset exists.
APT_ARCHES="amd64 arm64"

# The apt suite/component this repo publishes.
APT_SUITE="stable"
APT_COMPONENT="main"
APT_ORIGIN="DIG Network"
APT_LABEL="DIG"
APT_DESCRIPTION="DIG Network APT repository"

# Map a Debian arch -> the architecture token used in an upstream release asset name.
# Default token map (Rust target triples use x86_64/aarch64). A package whose release
# uses a different scheme (e.g. dig-node's `linux-x64`) overrides this via its own
# *_ASSET_ARCH_<debarch> var, looked up by asset_arch_for() below.
apt_asset_arch() {
  case "$1" in
    amd64) echo "x86_64" ;;
    arm64) echo "aarch64" ;;
    *)     echo "$1" ;;
  esac
}

# asset_arch_for PKG DEBARCH -> the upstream arch token for this package+arch,
# honouring a per-package override (PKG_<pkg>_ASSET_ARCH_<debarch>) and falling back
# to the default token map. Keeps the dig-node `linux-x64` naming out of the digstore
# path without special-casing in the builder.
asset_arch_for() {
  local override
  override="$(pkg_var "$1" "ASSET_ARCH_${2}")"
  if [ -n "$override" ]; then printf '%s' "$override"; else apt_asset_arch "$2"; fi
}

# ---- digstore (CLI; drops the binary on PATH, no service) -------------------------

PKG_digstore_REPO="DIG-Network/digstore"
PKG_digstore_BIN="digstore"
PKG_digstore_SECTION="utils"
PKG_digstore_DEPENDS="libc6"
PKG_digstore_HOMEPAGE="https://dig.net"
PKG_digstore_MAINTAINER="DIG Network <packages@dig.net>"
PKG_digstore_DESC_SHORT="DIG Network content-addressable store CLI"
PKG_digstore_DESC_LONG=" digstore is the Git-shaped, encrypted, content-addressable store engine
 for the DIG Network. It initialises stores, commits capsules, and pushes them
 to the network over the dig:// remote protocol, anchoring them on Chia mainnet."
PKG_digstore_SERVICE="no"
# Asset name template the release is expected to publish, per arch.
# {ver} = version without leading 'v'; {arch} = upstream asset arch token.
#
# Reality (2026-06): the digstore GitHub *releases* currently ship only the
# DigStore-Setup-*.AppImage / .dmg / .exe INSTALLERS — there is no raw `digstore`
# Linux CLI binary or per-arch tarball as a release asset. (publish-binary.yml builds
# a static-musl `digstore` but uploads it to S3, not the release.) So this template is
# the EXPECTED name for a raw per-arch CLI tarball; until upstream attaches one,
# build-deb.sh resolves it, finds nothing, and SKIPS digstore (non-fatal) — the apt
# repo simply omits the package and the pipeline stays green. When upstream publishes
# `digstore-<ver>-<arch>-unknown-linux-gnu.tar.gz`, packaging picks it up with no code
# change. (Override via the DIGSTORE_ASSET_TEMPLATE / DIGSTORE_ASSET_URL env in CI to
# point at any other source, e.g. the S3 object, without editing this file.)
PKG_digstore_ASSET_TEMPLATE="digstore-{ver}-{arch}-unknown-linux-gnu.tar.gz"
# Path of the binary inside the downloaded archive (relative to the archive root).
# Empty ("") means the asset IS the bare binary (no archive to unpack).
PKG_digstore_ARCHIVE_BIN_PATH="digstore"

# ---- dig-node (the node service; installs + enables a systemd unit) ----------------

PKG_dig_node_REPO="DIG-Network/dig-node"
PKG_dig_node_BIN="dig-node"
PKG_dig_node_SECTION="net"
PKG_dig_node_DEPENDS="libc6, adduser"
PKG_dig_node_HOMEPAGE="https://dig.net"
PKG_dig_node_MAINTAINER="DIG Network <packages@dig.net>"
PKG_dig_node_DESC_SHORT="DIG Network node service (dig:// content node)"
PKG_dig_node_DESC_LONG=" dig-node is the DIG Network node: it serves and caches DIG content, runs
 §21 whole-store sync, and exposes the dig RPC read interface on loopback.
 Installed as a systemd service (dig-node.service) running as the dig-node
 system account, bound to localhost."
PKG_dig_node_SERVICE="yes"
# The dig-node repo's release.yml (inherited from dig-companion) publishes raw
# per-OS binaries named `dig-companion-<ver>-linux-{x64,arm64}` — NOT a tarball and
# NOT the `dig-node` name. The Debian binary is installed as /usr/bin/dig-node, but
# the DOWNLOADED upstream asset is the dig-companion binary, so:
#   - the asset template uses the dig-companion / linux-x64 naming,
#   - ARCHIVE_BIN_PATH "" means the asset IS the bare binary (no archive to unpack),
#   - asset-arch overrides map amd64->x64, arm64->arm64.
# build-deb.sh installs that bare binary as /usr/bin/${PKG_dig_node_BIN}. When the
# repo later switches to a `dig-node-…tar.gz` scheme, only these three lines change.
PKG_dig_node_ASSET_TEMPLATE="dig-companion-{ver}-linux-{arch}"
PKG_dig_node_ASSET_ARCH_amd64="x64"
PKG_dig_node_ASSET_ARCH_arm64="arm64"
PKG_dig_node_ARCHIVE_BIN_PATH=""
# Service account + runtime layout (consumed by postinst and the unit).
PKG_dig_node_SERVICE_USER="dig-node"
PKG_dig_node_SERVICE_GROUP="dig-node"
PKG_dig_node_CACHE_DIR="/var/lib/dig-node"

# The packages this repo produces (underscored keys; '-' is not valid in a var name,
# so dig-node's keys use dig_node — see pkg_var()).
APT_PACKAGES="digstore dig-node"
