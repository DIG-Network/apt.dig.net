#!/usr/bin/env bash
# test_repo_metadata.sh — pin the apt-repo metadata generation:
#   * Packages stanza has the required fields + hashes + Filename pointing into pool/,
#   * Release lists the component/arch + the MD5Sum/SHA256 index of Packages,
#   * a signed repo yields Release.gpg + InRelease verifiable against the public key.
# The Packages/Release assertions need only coreutils; the GPG sign+verify leg is
# skipped (not failed) when gpg is unavailable.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../packaging/lib/common.sh
. "$ROOT/packaging/lib/common.sh"
# shellcheck source=../packaging/config.sh
. "$ROOT/packaging/config.sh"

fails=0
contains() { case "$2" in *"$3"*) printf 'ok   - %s\n' "$1" ;;
  *) printf 'FAIL - %s\n     %q not found\n' "$1" "$3"; fails=$((fails + 1)) ;; esac; }
check() { if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; else
  printf 'FAIL - %s\n     expected: %q actual: %q\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi; }

# We need dpkg-scanpackages or apt-ftparchive to build a Packages index from a pool.
SCAN=""
command -v apt-ftparchive   >/dev/null 2>&1 && SCAN="apt-ftparchive"
command -v dpkg-scanpackages >/dev/null 2>&1 && SCAN="${SCAN:-dpkg-scanpackages}"
if [ -z "$SCAN" ] || ! command -v dpkg-deb >/dev/null 2>&1; then
  printf 'skip - need dpkg-deb + (apt-ftparchive|dpkg-scanpackages) to test repo metadata\n'
  exit 0
fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# Build a couple of tiny real .debs into a pool via the staging helper.
# shellcheck source=../packaging/build-deb.sh
STAGE_ONLY=1 . "$ROOT/packaging/build-deb.sh"
pool="$work/site/pool/$APT_COMPONENT"; mkdir -p "$pool"
for spec in "digstore:v0.6.0:amd64" "dig-node:v0.5.29:amd64"; do
  IFS=: read -r pkg ver arch <<<"$spec"
  bin="$work/$pkg"; printf '#!/bin/sh\necho %s\n' "$pkg" > "$bin"
  stage_deb "$pkg" "$ver" "$arch" "$bin" "$work/stage-$pkg" "$pool"
done

# Generate the signed repo (no key -> unsigned: still produces Packages/Release).
# shellcheck source=../packaging/repo/generate-repo.sh
. "$ROOT/packaging/repo/generate-repo.sh"
GNUPGHOME=""
key_fpr=""
if command -v gpg >/dev/null 2>&1; then
  GNUPGHOME="$work/gnupg"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"; export GNUPGHOME
  cat > "$work/keygen" <<'EOF'
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: sign
Name-Real: DIG APT Test
Name-Email: apt-test@dig.net
Expire-Date: 0
%commit
EOF
  gpg --batch --gen-key "$work/keygen" >/dev/null 2>&1
  key_fpr="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')"
fi

generate_repo "$work/site" "$key_fpr"

pkgs="$work/site/dists/$APT_SUITE/$APT_COMPONENT/binary-amd64/Packages"
rel="$work/site/dists/$APT_SUITE/Release"

check "Packages index exists" "1" "$([ -f "$pkgs" ] && echo 1 || echo 0)"
body="$(cat "$pkgs")"
contains "Packages lists digstore"            "$body" "Package: digstore"
contains "Packages lists dig-node"            "$body" "Package: dig-node"
contains "Packages has SHA256"                "$body" "SHA256:"
contains "Packages Filename points into pool" "$body" "Filename: pool/$APT_COMPONENT/"

check "Release exists" "1" "$([ -f "$rel" ] && echo 1 || echo 0)"
relbody="$(cat "$rel")"
contains "Release Suite"      "$relbody" "Suite: $APT_SUITE"
contains "Release Component"  "$relbody" "Components: $APT_COMPONENT"
contains "Release Arch amd64" "$relbody" "amd64"
contains "Release Origin"     "$relbody" "Origin: $APT_ORIGIN"
contains "Release SHA256 block" "$relbody" "SHA256:"
contains "Release indexes Packages" "$relbody" "$APT_COMPONENT/binary-amd64/Packages"

if [ -n "$key_fpr" ]; then
  contains "InRelease exists + is clearsigned" "$(cat "$work/site/dists/$APT_SUITE/InRelease")" "BEGIN PGP SIGNED MESSAGE"
  check "Release.gpg exists" "1" "$([ -f "$work/site/dists/$APT_SUITE/Release.gpg" ] && echo 1 || echo 0)"
  # Verify the detached sig against our generated key.
  gpg --armor --export "$key_fpr" > "$work/pub.asc"
  if gpg --no-default-keyring --keyring "$work/verify.gpg" --import "$work/pub.asc" >/dev/null 2>&1 &&
     gpg --no-default-keyring --keyring "$work/verify.gpg" --verify \
       "$work/site/dists/$APT_SUITE/Release.gpg" "$rel" >/dev/null 2>&1; then
    printf 'ok   - Release.gpg verifies against the public key\n'
  else
    printf 'FAIL - Release.gpg did not verify\n'; fails=$((fails + 1))
  fi
  # The exported public key file must exist for users (dig.gpg).
  contains "public key dig.gpg published at site root" \
    "$(cat "$work/site/dig.gpg" 2>/dev/null || true)" "BEGIN PGP PUBLIC KEY BLOCK"
else
  printf 'skip - gpg not present; signature legs not exercised\n'
fi

if [ "$fails" -ne 0 ]; then printf '\n%d assertion(s) failed\n' "$fails" >&2; exit 1; fi
printf '\nall repo-metadata assertions passed\n'
