#!/usr/bin/env bash
# generate-repo.sh — turn a pool of .debs into a signed, flat APT repository.
#
# Layout produced under <site>/:
#   pool/<component>/*.deb                         (the packages; populated by build-deb.sh)
#   dists/<suite>/<component>/binary-<arch>/Packages[.gz]
#   dists/<suite>/Release                          (indexes every Packages with sizes+hashes)
#   dists/<suite>/Release.gpg                       (detached signature — if a key is given)
#   dists/<suite>/InRelease                         (inline-signed Release — if a key is given)
#   dig.gpg                                         (the ascii-armored PUBLIC key for users)
#
# Signing: the GPG key fingerprint to sign with is passed as $2 (empty == produce an
# UNSIGNED repo, still valid metadata — used by tests and pre-key CI). The PRIVATE key
# itself is never handled here: CI imports $APT_GPG_PRIVATE_KEY into the gpg keyring
# out of band and passes the resulting fingerprint in. No key material is ever written
# to the repo except the exported PUBLIC key (dig.gpg).
#
# Sourcing contract: define generate_repo() without side effects when sourced (tests
# call generate_repo directly); run main() only when executed.

set -euo pipefail

_GR_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$_GR_HERE/../lib/common.sh"
# shellcheck source=../config.sh
. "$_GR_HERE/../config.sh"

# scan_packages POOL ARCH -> a Packages index on stdout (relative Filename into pool/).
# Prefers apt-ftparchive; falls back to dpkg-scanpackages. Run from <site> so the
# Filename field is pool-relative (what apt expects under the repo root).
scan_packages() {
  local site="$1" arch="$2"
  ( cd "$site"
    if command -v apt-ftparchive >/dev/null 2>&1; then
      # apt-ftparchive emits ALL debs under the dir; filter to this arch + 'all'.
      apt-ftparchive --arch "$arch" packages "pool/$APT_COMPONENT"
    else
      dpkg-scanpackages --arch "$arch" "pool/$APT_COMPONENT" /dev/null 2>/dev/null
    fi )
}

# write_release SITE -> write dists/<suite>/Release indexing every Packages file with
# its size + MD5/SHA1/SHA256, using apt-ftparchive's release generator when available
# (it is on every Ubuntu runner), else a portable hand-rolled fallback.
write_release() {
  local site="$1"
  local dist="$site/dists/$APT_SUITE"
  local archlist="$APT_ARCHES"

  if command -v apt-ftparchive >/dev/null 2>&1; then
    apt-ftparchive \
      -o "APT::FTPArchive::Release::Origin=$APT_ORIGIN" \
      -o "APT::FTPArchive::Release::Label=$APT_LABEL" \
      -o "APT::FTPArchive::Release::Suite=$APT_SUITE" \
      -o "APT::FTPArchive::Release::Codename=$APT_SUITE" \
      -o "APT::FTPArchive::Release::Components=$APT_COMPONENT" \
      -o "APT::FTPArchive::Release::Architectures=$archlist" \
      -o "APT::FTPArchive::Release::Description=$APT_DESCRIPTION" \
      release "$dist" > "$dist/Release"
    return
  fi

  # Portable fallback: header + a SHA256/MD5Sum block over each index file.
  {
    printf 'Origin: %s\n' "$APT_ORIGIN"
    printf 'Label: %s\n' "$APT_LABEL"
    printf 'Suite: %s\n' "$APT_SUITE"
    printf 'Codename: %s\n' "$APT_SUITE"
    printf 'Components: %s\n' "$APT_COMPONENT"
    printf 'Architectures: %s\n' "$archlist"
    printf 'Date: %s\n' "$(date -u '+%a, %d %b %Y %H:%M:%S UTC')"
    printf 'Description: %s\n' "$APT_DESCRIPTION"
    local algo cmd
    for algo in MD5Sum:md5sum SHA256:sha256sum; do
      printf '%s\n' "${algo%%:*}:"
      cmd="${algo##*:}"
      ( cd "$dist"
        find . -type f \( -name Packages -o -name 'Packages.gz' \) | sed 's|^\./||' | sort |
        while read -r f; do
          printf ' %s %16d %s\n' "$($cmd "$f" | awk '{print $1}')" "$(wc -c < "$f")" "$f"
        done )
    done
  } > "$dist/Release"
}

# xml_escape STR -> STR with XML-significant characters escaped, on stdout.
xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  printf '%s' "$s"
}

# generate_feed SITE -> write SITE/feed.xml: an Atom feed listing the currently
# published packages (one <entry> per Package/Version stanza in the amd64 Packages
# index — versions are identical across arches, so amd64 is representative). This is
# a PACKAGE-LIST feed, not a version-history changelog: build_one() resolves each
# package's version live from the upstream GitHub release at build time and nothing
# persists prior versions, so there is no history to diff yet (unlike
# status.dig.net's committed history.json, which drives ITS Atom feed of state
# TRANSITIONS). A feed reader/agent can still subscribe to this to see what's
# currently installable without polling+diffing the Packages index by hand.
generate_feed() {
  local site="$1"
  local dist="$site/dists/$APT_SUITE"
  local pkgs="$dist/$APT_COMPONENT/binary-amd64/Packages"
  local updated
  updated="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<feed xmlns="http://www.w3.org/2005/Atom">\n'
    printf '  <id>https://apt.dig.net/</id>\n'
    printf '  <title>DIG Network APT repository — packages</title>\n'
    printf '  <subtitle>Currently published packages in the apt.dig.net %s/%s repository.</subtitle>\n' \
      "$APT_SUITE" "$APT_COMPONENT"
    printf '  <updated>%s</updated>\n' "$updated"
    printf '  <link rel="self" type="application/atom+xml" href="https://apt.dig.net/feed.xml" />\n'
    printf '  <link rel="alternate" type="text/html" href="https://apt.dig.net/" />\n'

    if [ -f "$pkgs" ]; then
      local name="" version=""
      emit_entry() {
        local ename eversion
        ename="$(xml_escape "$1")"
        eversion="$(xml_escape "$2")"
        printf '  <entry>\n'
        printf '    <id>https://apt.dig.net/#%s-%s</id>\n' "$ename" "$eversion"
        printf '    <title>%s %s</title>\n' "$ename" "$eversion"
        printf '    <updated>%s</updated>\n' "$updated"
        printf '    <link href="https://apt.dig.net/" />\n'
        printf '    <content type="text">%s %s is published in the apt.dig.net %s/%s repository.</content>\n' \
          "$ename" "$eversion" "$APT_SUITE" "$APT_COMPONENT"
        printf '  </entry>\n'
      }
      while IFS= read -r line; do
        case "$line" in
          "Package: "*) name="${line#Package: }" ;;
          "Version: "*) version="${line#Version: }" ;;
          "")
            [ -n "$name" ] && emit_entry "$name" "$version"
            name=""; version=""
            ;;
        esac
      done < "$pkgs"
      # Packages stanzas are blank-line-separated; the last one has no trailing
      # blank line to trigger the flush above, so flush it here too.
      [ -n "$name" ] && emit_entry "$name" "$version"
    fi

    printf '</feed>\n'
  } > "$site/feed.xml"
}

# generate_repo SITE [KEY_FPR]
#   Build Packages[.gz] for every arch, the Release index, and (if KEY_FPR given) the
#   InRelease + Release.gpg signatures and the exported public key dig.gpg.
generate_repo() {
  local site="$1" key="${2:-}"
  local dist="$site/dists/$APT_SUITE"
  install -d -m 0755 "$site/pool/$APT_COMPONENT"

  local arch dir
  for arch in $APT_ARCHES; do
    dir="$dist/$APT_COMPONENT/binary-$arch"
    install -d -m 0755 "$dir"
    scan_packages "$site" "$arch" > "$dir/Packages"
    gzip -9 -c "$dir/Packages" > "$dir/Packages.gz"
    # A binary-<arch>/Release pins the component+arch (apt reads it during fetch).
    {
      printf 'Archive: %s\n' "$APT_SUITE"
      printf 'Component: %s\n' "$APT_COMPONENT"
      printf 'Origin: %s\n' "$APT_ORIGIN"
      printf 'Label: %s\n' "$APT_LABEL"
      printf 'Architecture: %s\n' "$arch"
    } > "$dir/Release"
  done

  write_release "$site"
  generate_feed "$site"

  if [ -n "$key" ]; then
    # Detached + inline signatures over the Release file.
    gpg --batch --yes --local-user "$key" --armor --detach-sign \
      --output "$dist/Release.gpg" "$dist/Release"
    gpg --batch --yes --local-user "$key" --clearsign \
      --output "$dist/InRelease" "$dist/Release"
    # Publish the PUBLIC key at a stable path for users (curl …/dig.gpg).
    gpg --armor --export "$key" > "$site/dig.gpg"
    log "repo signed with $key; public key at $site/dig.gpg"
  else
    warn "no signing key supplied — repo metadata is UNSIGNED (apt will reject it)."
  fi
}

main() {
  local site="${1:?usage: generate-repo.sh <site-dir> [gpg-fingerprint]}"
  generate_repo "$site" "${2:-${APT_GPG_KEY_FPR:-}}"
}

if [ -z "${STAGE_ONLY:-}" ] && [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
