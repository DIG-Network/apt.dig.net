#!/usr/bin/env bash
# test_catalogue_coverage.sh — pin WHICH components apt.dig.net serves, and pin each
# one's asset resolution against the asset names its upstream release ACTUALLY
# publishes.
#
# WHY the exact upstream names are hard-coded here: the failure this suite exists to
# catch is not "the catalogue forgot a package" — it is "the catalogue names an asset
# that upstream does not publish", which build-deb.sh swallows as a non-fatal per-arch
# skip and reports as a green build producing no .deb. A catalogue entry is therefore
# only proven by resolving to a string observed in a real GitHub release. Every
# expectation below was read from `gh release view` on the named tag; when upstream
# renames an asset, this test is the thing that must fail.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../packaging/lib/common.sh
. "$ROOT/packaging/lib/common.sh"
# shellcheck source=../packaging/config.sh
. "$ROOT/packaging/config.sh"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"

# ---- the served set ---------------------------------------------------------------
# Exact, not "contains": a partial add is the regression, so the whole set is pinned.
check "APT_PACKAGES is the full component set" \
  "dig-store dig-node dig-dns dig-app" "$APT_PACKAGES"

# ---- dig-dns: ingested as the upstream-built .deb, not rebuilt ---------------------
# dig-dns publishes its own maintainer-authored .deb (with its own systemd unit), so
# this repo passes it through rather than re-deriving packaging it does not own.
# Observed on DIG-Network/dig-dns v0.15.1: `dig-dns_0.15.1-1_amd64.deb`.
check "dig-dns declares a prebuilt .deb rather than a binary template" \
  "" "$(pkg_var dig-dns ASSET_TEMPLATE)"
check "dig-dns prebuilt .deb name matches the published asset (amd64)" \
  "dig-dns_0.15.1-1_amd64.deb" \
  "$(asset_name "$(pkg_var dig-dns PREBUILT_DEB_TEMPLATE)" v0.15.1 amd64)"
# The prebuilt path is keyed on the DEBIAN arch, never the Rust-triple token map:
# `dig-dns_0.15.1-1_aarch64.deb` is a name upstream never publishes.
check "dig-dns prebuilt .deb name uses the Debian arch (arm64)" \
  "dig-dns_0.15.1-1_arm64.deb" \
  "$(asset_name "$(pkg_var dig-dns PREBUILT_DEB_TEMPLATE)" v0.15.1 arm64)"

# ---- dig-app: bare per-arch binaries, plus the `dign` CLI from a SEPARATE asset ----
# Observed on DIG-Network/dig-app v12.28.0: `dig-app-12.28.0-linux-x64-headless` and
# `dign-12.28.0-linux-x64`. The headless variant is what apt serves (see config.sh).
check "dig-app asset name matches the published headless binary (amd64)" \
  "dig-app-12.28.0-linux-x64-headless" \
  "$(asset_name "$(pkg_var dig-app ASSET_TEMPLATE)" v12.28.0 "$(asset_arch_for dig-app amd64)")"
check "dig-app ships the bare binary, not an archive member" \
  "" "$(pkg_var dig-app ARCHIVE_BIN_PATH)"
# `dign` is its own release asset, so it cannot come through EXTRA_BINS (which reads
# members of the SAME archive). It resolves through its own template.
check "dig-app carries no same-archive extra binaries" \
  "" "$(pkg_var dig-app EXTRA_BINS)"
check "dig-app declares dign as a separate release asset" \
  "dign:dign-{ver}-linux-{arch}" "$(pkg_var dig-app EXTRA_ASSET_BINS)"
check "dign asset name matches the published CLI binary (amd64)" \
  "dign-12.28.0-linux-x64" \
  "$(asset_name "dign-{ver}-linux-{arch}" v12.28.0 "$(asset_arch_for dig-app amd64)")"

# ---- the packages that were already served must not regress ------------------------
check "dig-node still resolves its published binary (amd64)" \
  "dig-node-0.126.1-linux-x64" \
  "$(asset_name "$(pkg_var dig-node ASSET_TEMPLATE)" v0.126.1 "$(asset_arch_for dig-node amd64)")"
check "dig-store still resolves its published tarball (amd64)" \
  "dig-store-0.25.0-x86_64-unknown-linux-gnu.tar.gz" \
  "$(asset_name "$(pkg_var dig-store ASSET_TEMPLATE)" v0.25.0 "$(asset_arch_for dig-store amd64)")"

assert_summary "catalogue-coverage"
