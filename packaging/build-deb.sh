#!/usr/bin/env bash
# build-deb.sh — build the DIG .deb packages from upstream RELEASE binaries.
#
# Usage:
#   packaging/build-deb.sh <pool-dir> [pkg...]
#     Resolve the latest GitHub release of each package's repo, download the per-arch
#     asset, lay out the deb (control + the binary on PATH + systemd unit/maintainer
#     scripts for the service package), build it with dpkg-deb, and drop the .deb into
#     <pool-dir>. With no pkg args, builds every package in $APT_PACKAGES.
#
# Resilience (the explicit task contract): an arch (or whole package) whose upstream
# release asset does not exist is SKIPPED with a warning — never fatal — so the
# pipeline stays green until upstream publishes matching assets. The set of .debs that
# DID build is whatever the apt repo then publishes.
#
# Sourcing contract: `STAGE_ONLY=1 . build-deb.sh` defines the functions
# (stage_deb / build_one) WITHOUT running main(), so the test suite can stage + build
# a deb from a fake binary with no network. (We build real .debs in tests; only the
# download is mocked out by passing the binary directly.)

set -euo pipefail

_BD_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$_BD_HERE/lib/common.sh"
# shellcheck source=config.sh
. "$_BD_HERE/config.sh"

# stage_deb PKG VERSION DEBARCH BIN_SRC STAGE_DIR OUT_DIR [NAME:SRC ...]
#   Lay out a single .deb under STAGE_DIR and build it into OUT_DIR. Pure filesystem
#   layout + dpkg-deb; no network. Returns the path of the built .deb on stdout.
#   This is the unit the deb-layout test pins.
#
#   Trailing NAME:SRC args install additional binaries alongside BIN_SRC at
#   /usr/bin/NAME — e.g. digstore's `digs` alias binary (PKG_*_EXTRA_BINS).
stage_deb() {
  local pkg="$1" version="$2" arch="$3" bin_src="$4" stage="$5" out="$6"
  shift 6
  local bin_name service root
  bin_name="$(pkg_var "$pkg" BIN)"
  service="$(pkg_var "$pkg" SERVICE)"

  rm -rf "$stage"
  root="$stage"
  install -d -m 0755 "$root/DEBIAN" "$root/usr/bin"
  install -m 0755 "$bin_src" "$root/usr/bin/$bin_name"

  # Extra binaries (NAME:SRC pairs) shipped alongside the main one.
  local pair extra_name extra_src
  for pair in "$@"; do
    extra_name="${pair%%:*}"
    extra_src="${pair#*:}"
    install -m 0755 "$extra_src" "$root/usr/bin/$extra_name"
  done

  # Installed-Size in KiB (du -k rounds up to disk blocks; close enough for apt's
  # UI), summed over every binary this package ships (usr/bin as a whole).
  local size_kb
  size_kb="$(du -k -s "$root/usr/bin" | awk '{print $1}')"

  # Service package: ship + register the systemd unit and maintainer scripts.
  if [ "$service" = "yes" ]; then
    install -d -m 0755 "$root/lib/systemd/system"
    install -m 0644 "$_BD_HERE/debian/$pkg/$pkg.service" \
      "$root/lib/systemd/system/$pkg.service"
    local s
    for s in postinst prerm postrm; do
      if [ -f "$_BD_HERE/debian/$pkg/$s" ]; then
        install -m 0755 "$_BD_HERE/debian/$pkg/$s" "$root/DEBIAN/$s"
      fi
    done
  fi

  render_control "$pkg" "$version" "$arch" "$size_kb" > "$root/DEBIAN/control"

  install -d -m 0755 "$out"
  # Reproducible-ish: fixed mtime via SOURCE_DATE_EPOCH if the env sets it.
  dpkg-deb --root-owner-group --build "$root" \
    "$out/${pkg}_$(deb_version "$version")_${arch}.deb" >&2
  printf '%s\n' "$out/${pkg}_$(deb_version "$version")_${arch}.deb"
}

# gh_latest_tag REPO -> the latest non-draft, non-prerelease release tag (or empty).
# Uses gh if authenticated, else the public REST API via curl. Empty (not error) when
# the repo has no releases yet — the caller treats that as "skip".
gh_latest_tag() {
  local repo="$1" tag=""
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    tag="$(gh release view --repo "$repo" --json tagName -q .tagName 2>/dev/null || true)"
  fi
  if [ -z "$tag" ] && command -v curl >/dev/null 2>&1; then
    tag="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name"[ ]*:[ ]*"\([^"]*\)".*/\1/p' | head -1 || true)"
  fi
  printf '%s' "$tag"
}

# fetch_asset REPO TAG ASSET_NAME DEST -> 0 if downloaded, 1 if the asset is absent.
# Honours a direct DIGSTORE_ASSET_URL / DIG_NODE_ASSET_URL override (see config notes).
fetch_asset() {
  local repo="$1" tag="$2" name="$3" dest="$4"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if gh release download "$tag" --repo "$repo" --pattern "$name" \
         --output "$dest" --clobber >/dev/null 2>&1; then
      return 0
    fi
  fi
  # Fallback: public release-asset URL.
  local url="https://github.com/$repo/releases/download/$tag/$name"
  if command -v curl >/dev/null 2>&1 && curl -fsSL "$url" -o "$dest" 2>/dev/null; then
    return 0
  fi
  return 1
}

# extract_binary ASSET_PATH ARCHIVE_BIN_PATH DEST -> place the binary at DEST.
# Handles: bare binary (ARCHIVE_BIN_PATH empty), .tar.gz/.tgz, and .zip.
# Returns 1 (DEST not created) when ARCHIVE_BIN_PATH does not exist inside the
# archive, WITHOUT erroring — callers that treat a given path as optional (e.g. an
# EXTRA_BINS entry an older upstream release predates) can check the exit status
# instead of the script dying under `set -e`; a caller that treats the path as
# required simply doesn't guard the call, so a real miss still aborts the build.
extract_binary() {
  local asset="$1" inner="$2" dest="$3" tmp rc=0
  case "$asset" in
    *.tar.gz | *.tgz)
      tmp="$(mktemp -d)"
      tar -xzf "$asset" -C "$tmp"
      if [ -f "$tmp/$inner" ]; then cp "$tmp/$inner" "$dest"; else rc=1; fi
      rm -rf "$tmp"
      ;;
    *.zip)
      tmp="$(mktemp -d)"
      (cd "$tmp" && unzip -q "$asset")
      if [ -f "$tmp/$inner" ]; then cp "$tmp/$inner" "$dest"; else rc=1; fi
      rm -rf "$tmp"
      ;;
    *)
      # Bare binary asset.
      cp "$asset" "$dest" || rc=1
      ;;
  esac
  [ "$rc" -eq 0 ] && chmod 0755 "$dest"
  return "$rc"
}

# build_one PKG POOL_DIR -> resolve + download + stage every available arch.
build_one() {
  local pkg="$1" pool="$2"
  local repo tag tmpl inner extra_bins override_tag override_tmpl
  repo="$(pkg_var "$pkg" REPO)"
  tmpl="$(pkg_var "$pkg" ASSET_TEMPLATE)"
  inner="$(pkg_var "$pkg" ARCHIVE_BIN_PATH)"
  extra_bins="$(pkg_var "$pkg" EXTRA_BINS)"

  # Per-package env overrides (UPPERCASED, '-'->'_'): <PKG>_TAG / <PKG>_ASSET_TEMPLATE.
  local envpkg
  envpkg="$(printf '%s' "$pkg" | tr 'a-z-' 'A-Z_')"
  override_tag="$(eval "printf '%s' \"\${${envpkg}_TAG-}\"")"
  override_tmpl="$(eval "printf '%s' \"\${${envpkg}_ASSET_TEMPLATE-}\"")"
  [ -n "$override_tmpl" ] && tmpl="$override_tmpl"

  if [ -n "$override_tag" ]; then
    tag="$override_tag"
  else
    tag="$(gh_latest_tag "$repo")"
  fi
  if [ -z "$tag" ]; then
    warn "$pkg: $repo has no resolvable release tag yet — skipping (no .deb built)."
    return 0
  fi
  log "$pkg: building from $repo@$tag"

  local arch upstream name dl bin built any=0 work
  work="$(mktemp -d)"
  for arch in $APT_ARCHES; do
    upstream="$(asset_arch_for "$pkg" "$arch")"
    name="$(asset_name "$tmpl" "$tag" "$upstream")"
    dl="$work/$name"
    if ! fetch_asset "$repo" "$tag" "$name" "$dl"; then
      warn "$pkg: no asset '$name' for $arch in $repo@$tag — skipping this arch."
      continue
    fi
    bin="$work/bin-$arch"
    extract_binary "$dl" "$inner" "$bin"

    # Extra binaries from the same archive (e.g. digstore's `digs` alias). Optional:
    # an upstream release that predates the extra bin simply ships without it.
    local extra_args=() eb eb_inner eb_dest
    for eb in $extra_bins; do
      eb_inner="$(extra_bin_path "$inner" "$eb")"
      eb_dest="$work/bin-$arch-$eb"
      if extract_binary "$dl" "$eb_inner" "$eb_dest"; then
        extra_args+=("$eb:$eb_dest")
      else
        warn "$pkg: extra binary '$eb' not found in $name (upstream release predates it) — shipping without it."
      fi
    done

    built="$(stage_deb "$pkg" "$tag" "$arch" "$bin" "$work/stage-$arch" "$pool" "${extra_args[@]}")"
    log "$pkg: built $(basename "$built")"
    any=1
  done
  rm -rf "$work"
  [ "$any" = 1 ] || warn "$pkg: no archs produced a .deb (no matching release assets)."
}

main() {
  local pool="${1:?usage: build-deb.sh <pool-dir> [pkg...]}"
  shift || true
  local pkgs=("$@")
  [ "${#pkgs[@]}" -eq 0 ] && read -r -a pkgs <<<"$APT_PACKAGES"
  install -d -m 0755 "$pool"
  local p
  for p in "${pkgs[@]}"; do
    build_one "$p" "$pool"
  done
  # Report what landed (machine-greppable).
  log "built debs:"
  ls -1 "$pool"/*.deb 2>/dev/null >&2 || warn "no .deb files were produced."
}

# Only run main when executed directly (not when sourced for tests).
if [ -z "${STAGE_ONLY:-}" ] && [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
