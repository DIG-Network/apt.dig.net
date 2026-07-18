#!/usr/bin/env bash
# test_dig_node_port.sh — the dig-node port drift guard.
#
# 9778 is the CANONICAL dig-node port (published upstream as
# `dig_constants::DIG_NODE_PORT`; §5.3 / SYSTEM.md). config.sh declares it ONCE as
# PKG_dig_node_PORT — this repo's single source of truth. This test enforces that
# single-sourcing two ways:
#   1. every file that quotes the port (the systemd unit, README, the site) matches
#      the value declared in config.sh, so a doc can't silently drift from the unit;
#   2. the old 8080 default (the dig_ecosystem #315 drift this repo already corrected)
#      appears as a node port NOWHERE in the tracked tree.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../packaging/lib/common.sh
. "$ROOT/packaging/lib/common.sh"
# shellcheck source=../packaging/config.sh
. "$ROOT/packaging/config.sh"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"

PORT="$(pkg_var dig-node PORT)"

# The canonical value is the one this suite pins; a bump lands here first, then flows.
check "config.sh declares the canonical dig-node port" "9778" "$PORT"

# Every file that quotes the port must quote the config value, binding docs to the unit.
for rel in \
  "packaging/debian/dig-node/dig-node.service" \
  "README.md" \
  "site/index.html" \
  "site/llms.txt"; do
  body="$(cat "$ROOT/$rel")"
  contains "$rel references the config port ($PORT)" "$body" "$PORT"
done

# Repo-wide: no file may USE 8080 as the node port (the #315 drift). We match port
# SYNTAX (`:8080`, `=8080`, `8080/`), not the bare number — so historical prose like
# the CHANGELOG's "from 8080 to 9778" and config.sh's explanatory comment don't trip it.
port_8080_hits="$(git -C "$ROOT" grep -nE '[:=]8080|8080/' \
  -- ':!tests/test_dig_node_port.sh' 2>/dev/null || true)"
if [ -n "$port_8080_hits" ]; then
  printf 'FAIL - 8080 still referenced as a node port:\n%s\n' "$port_8080_hits"
  fails=$((fails + 1))
else
  printf 'ok   - no 8080 node-port reference anywhere in the tree\n'
fi

assert_summary "dig-node port"
