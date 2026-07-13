#!/usr/bin/env bash
# test_dig_node_port.sh — ensure dig-node port is 9778, not 8080 (drift guard).
# §5.3 defines 9778 as the canonical dig_constants::DIG_NODE_PORT. This test fails
# if any file refers to 8080 as the dig-node port, ensuring the value never drifts
# back to the old default.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

fails=0

# Check packaging/debian/dig-node/dig-node.service for port references
if grep -q ':8080\|8080' "$ROOT/packaging/debian/dig-node/dig-node.service" 2>/dev/null; then
  echo "FAIL - dig-node.service still references 8080"
  grep -n ':8080\|8080' "$ROOT/packaging/debian/dig-node/dig-node.service" || true
  fails=$((fails + 1))
else
  echo "ok   - dig-node.service uses 9778 (not 8080)"
fi

# Check README.md for port references
if grep -q ':8080' "$ROOT/README.md" 2>/dev/null; then
  echo "FAIL - README.md still references 8080"
  grep -n ':8080' "$ROOT/README.md" || true
  fails=$((fails + 1))
else
  echo "ok   - README.md uses 9778 (not 8080)"
fi

# Check site/index.html for port references
if grep -q ':8080' "$ROOT/site/index.html" 2>/dev/null; then
  echo "FAIL - site/index.html still references 8080"
  grep -n ':8080' "$ROOT/site/index.html" || true
  fails=$((fails + 1))
else
  echo "ok   - site/index.html uses 9778 (not 8080)"
fi

# Check site/llms.txt for port references
if grep -q ':8080' "$ROOT/site/llms.txt" 2>/dev/null; then
  echo "FAIL - site/llms.txt still references 8080"
  grep -n ':8080' "$ROOT/site/llms.txt" || true
  fails=$((fails + 1))
else
  echo "ok   - site/llms.txt uses 9778 (not 8080)"
fi

# Verify that 9778 is actually present in the key files
for file in \
  "$ROOT/packaging/debian/dig-node/dig-node.service" \
  "$ROOT/README.md" \
  "$ROOT/site/index.html" \
  "$ROOT/site/llms.txt"; do
  if ! grep -q '9778' "$file" 2>/dev/null; then
    echo "FAIL - $file does not reference 9778"
    fails=$((fails + 1))
  else
    echo "ok   - $file references 9778"
  fi
done

if [ "$fails" -ne 0 ]; then
  printf '\n%d assertion(s) failed\n' "$fails" >&2
  exit 1
fi
printf '\nall dig-node port assertions passed\n'
