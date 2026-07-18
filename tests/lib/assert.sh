# shellcheck shell=bash
# assert.sh — the shared assertion vocabulary for the apt.dig.net shell test suite.
#
# WHY one file: every tests/*.sh needs the same four assertions (equality, substring,
# absence, file-existence) tracking a single failure counter, then exits non-zero if
# any failed. Factoring them here mirrors packaging/lib/common.sh — one source of truth
# for the test vocabulary, so each test file reads as a list of intent rather than a
# re-declaration of boilerplate. Source it, write assertions, end with
# `assert_summary "<suite name>"`.

# Count of failed assertions in the sourcing test; the helpers increment it in place.
fails=0

# check DESC EXPECTED ACTUAL — assert two strings are equal.
check() {
  if [ "$2" = "$3" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n     expected: %q\n     actual:   %q\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

# contains DESC HAYSTACK NEEDLE — assert NEEDLE is a substring of HAYSTACK.
contains() {
  case "$2" in
    *"$3"*) printf 'ok   - %s\n' "$1" ;;
    *) printf 'FAIL - %s\n     %q not found in output\n' "$1" "$3"; fails=$((fails + 1)) ;;
  esac
}

# not_contains DESC HAYSTACK NEEDLE — assert NEEDLE is NOT a substring of HAYSTACK.
not_contains() {
  case "$2" in
    *"$3"*) printf 'FAIL - %s\n     %q unexpectedly found in output\n' "$1" "$3"; fails=$((fails + 1)) ;;
    *) printf 'ok   - %s\n' "$1" ;;
  esac
}

# file_exists DESC PATH — assert PATH is an existing regular file.
file_exists() {
  if [ -f "$2" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n     %q does not exist\n' "$1" "$2"
    fails=$((fails + 1))
  fi
}

# assert_summary NAME — print the tally and exit non-zero if any assertion failed.
# The trailing line mirrors the per-suite "all <name> assertions passed" convention.
assert_summary() {
  if [ "$fails" -ne 0 ]; then
    printf '\n%d assertion(s) failed\n' "$fails" >&2
    exit 1
  fi
  printf '\nall %s assertions passed\n' "$1"
}
