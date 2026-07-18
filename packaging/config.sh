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
# Asset reality: the dig-store repo (DIG-Network/dig-store — renamed from `digstore`,
# #703/#704) and dig-node publish per-arch release assets under the names below.
# build-deb.sh resolves them at build time and SKIPS (non-fatal) any arch whose asset
# is absent, so the pipeline stays green until upstream publishes matching assets. See
# README "Upstream asset contract".

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
# to the default token map. Keeps the dig-node `linux-x64` naming out of the dig-store
# path without special-casing in the builder.
asset_arch_for() {
  local override
  override="$(pkg_var "$1" "ASSET_ARCH_${2}")"
  if [ -n "$override" ]; then printf '%s' "$override"; else apt_asset_arch "$2"; fi
}

# ---- dig-store (CLI; drops the binary on PATH, no service) ------------------------
#
# The var-key segment is `dig_store` (dig-store with '-'->'_', per pkg_var()): the
# package id in $APT_PACKAGES is `dig-store`, so its Debian package name AND the
# installed binary are both `dig-store`. The repo was renamed digstore -> dig-store
# (DIG-Network/dig-store, epic #703): the CLI binary is `dig-store`, `digs` stays a
# first-class alias, and a transitional `digstore` -> `dig-store` symlink ships in the
# .deb so existing `digstore …` scripts keep working during the rename.

PKG_dig_store_REPO="DIG-Network/dig-store"
PKG_dig_store_BIN="dig-store"
PKG_dig_store_SECTION="utils"
PKG_dig_store_DEPENDS="libc6"
PKG_dig_store_HOMEPAGE="https://dig.net"
PKG_dig_store_MAINTAINER="DIG Network <packages@dig.net>"
PKG_dig_store_DESC_SHORT="DIG Network content-addressable store CLI"
PKG_dig_store_DESC_LONG=" dig-store is the Git-shaped, encrypted, content-addressable store engine
 for the DIG Network. It initialises stores, commits capsules, and pushes them
 to the network over the dig:// remote protocol, anchoring them on Chia mainnet."
PKG_dig_store_SERVICE="no"
# Asset name template the release publishes, per arch.
# {ver} = version without leading 'v'; {arch} = upstream asset arch token.
#
# The dig-store release publishes a raw per-arch CLI tarball
# `dig-store-<ver>-<arch>-unknown-linux-gnu.tar.gz` (the rename dual-publishes a
# transitional `digstore-<ver>-…` tarball too, but packaging targets the new name).
# build-deb.sh resolves it, and SKIPS a missing arch/asset non-fatally so the pipeline
# stays green. (Override via the DIG_STORE_ASSET_TEMPLATE / DIG_STORE_TAG env in CI to
# point at any other source without editing this file.)
PKG_dig_store_ASSET_TEMPLATE="dig-store-{ver}-{arch}-unknown-linux-gnu.tar.gz"
# Path of the binary inside the downloaded archive (relative to the archive root).
# Empty ("") means the asset IS the bare binary (no archive to unpack).
PKG_dig_store_ARCHIVE_BIN_PATH="dig-store"
# Extra binaries shipped from the SAME archive, alongside the main one, and installed
# under /usr/bin next to it (space-separated names; see extra_bin_path() in
# common.sh). `digs` is a first-class alias binary for `dig-store` (`digs <args>` ==
# `dig-store <args>` — digstore#16 / dig_ecosystem#434): the release tarball carries
# both executables at its root. If a tarball predates `digs`, build-deb.sh resolves +
# skips it non-fatally so the pipeline stays green either way.
PKG_dig_store_EXTRA_BINS="digs"
# Transitional compat symlinks (space-separated names) created under /usr/bin pointing
# at BIN. The repo/binary rename digstore -> dig-store (#703/#704) keeps a `digstore`
# symlink so existing `digstore …` scripts keep resolving. Remove once the transition
# is complete.
PKG_dig_store_COMPAT_SYMLINKS="digstore"

# ---- dig-node (the node service; installs + enables a systemd unit) ----------------

PKG_dig_node_REPO="DIG-Network/dig-node"
PKG_dig_node_BIN="dig-node"
PKG_dig_node_SECTION="net"
PKG_dig_node_DEPENDS="libc6, adduser"
PKG_dig_node_HOMEPAGE="https://dig.net"
PKG_dig_node_MAINTAINER="DIG Network <packages@dig.net>"
PKG_dig_node_DESC_SHORT="DIG Network node service (chia:// content node)"
PKG_dig_node_DESC_LONG=" dig-node is the DIG Network node: it serves and caches verified DIG
 content (the chia:// content a browser or the DIG extension opens), runs
 §21 whole-store sync, and exposes the dig RPC read interface on loopback.
 Installed as a systemd service (dig-node.service) running as the dig-node
 system account, bound to localhost."
PKG_dig_node_SERVICE="yes"
# The dig-node repo's release.yml publishes raw per-OS binaries named
# `dig-node-<ver>-linux-{x64,arm64}` — NOT a tarball. The Debian binary is installed
# as /usr/bin/dig-node from that DOWNLOADED bare binary, so:
#   - the asset template uses the dig-node / linux-x64 naming,
#   - ARCHIVE_BIN_PATH "" means the asset IS the bare binary (no archive to unpack),
#   - asset-arch overrides map amd64->x64, arm64->arm64.
# build-deb.sh installs that bare binary as /usr/bin/${PKG_dig_node_BIN}. When the
# repo later switches to a `dig-node-…tar.gz` scheme, only these three lines change.
PKG_dig_node_ASSET_TEMPLATE="dig-node-{ver}-linux-{arch}"
PKG_dig_node_ASSET_ARCH_amd64="x64"
PKG_dig_node_ASSET_ARCH_arm64="arm64"
PKG_dig_node_ARCHIVE_BIN_PATH=""
# Service account + runtime layout (consumed by postinst and the unit).
PKG_dig_node_SERVICE_USER="dig-node"
PKG_dig_node_SERVICE_GROUP="dig-node"
PKG_dig_node_CACHE_DIR="/var/lib/dig-node"
# Loopback bind address the systemd unit sets via DIG_NODE_HOST / DIG_NODE_PORT.
# 9778 is the CANONICAL dig-node port — published upstream as `dig_constants::DIG_NODE_PORT`
# (SYSTEM.md: dig-node / dig-dns / dig-installer import that constant rather than
# hardcoding the literal). This declaration is THIS repo's single source of truth for the
# value: the unit ships it, the README + site quote it, and test_dig_node_port.sh asserts
# every one of those references matches the constant here and that the old 8080 default
# (dig_ecosystem #315 drift) appears nowhere. Change the port in ONE place — here.
PKG_dig_node_HOST="127.0.0.1"
PKG_dig_node_PORT="9778"

# The packages this repo produces (underscored keys; '-' is not valid in a var name,
# so dig-node's keys use dig_node — see pkg_var()).
APT_PACKAGES="dig-store dig-node"
