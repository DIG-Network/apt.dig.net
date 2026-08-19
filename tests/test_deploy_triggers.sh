#!/usr/bin/env bash
# test_deploy_triggers.sh — pin the events that re-ingest the upstream releases.
#
# WHY this test exists: apt.dig.net resolves each component's version at BUILD time
# (`gh_latest_tag` -> releases/latest), so the catalogue is never stale by pin — it is
# stale only because nothing re-runs the deploy. Before this change deploy.yml fired
# on this repo's own `v*` tags and manual dispatch alone, which is why the published
# index served dig-node 0.99.1 while upstream was on 0.126.1: apt.dig.net had simply
# not released in 27 upstream minors.
#
# The assertions read the `on:` block ONLY. A `schedule:` or `repository_dispatch:`
# mentioned in a comment (this file's own header is full of both words) must not
# satisfy them, so the block is extracted first and the rest of the file discarded.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"

WF="$ROOT/.github/workflows/deploy.yml"
[ -f "$WF" ] || { echo "FAIL - $WF missing"; exit 1; }

# The `on:` block = from the top-level `on:` key to the next top-level key.
on_block="$(awk '/^on:/{f=1;next} f && /^[A-Za-z]/{f=0} f' "$WF")"

contains "deploy re-ingests on a schedule"            "$on_block" "schedule:"
contains "the schedule declares a cron"               "$on_block" "cron:"
contains "deploy re-ingests on repository_dispatch"   "$on_block" "repository_dispatch:"
contains "the dispatch listens for upstream-release"  "$on_block" "upstream-release"
# The pre-existing triggers must survive.
contains "deploy still runs on this repo's own tags"  "$on_block" "tags:"
contains "deploy still runs on manual dispatch"       "$on_block" "workflow_dispatch:"

# A guard against the failure that made the old behaviour invisible: the deploy job
# must not be conditioned on the tag-push event, or the new triggers would fire runs
# that skip the only job and still report `completed`.
job_if="$(awk '/^  deploy:/{f=1;next} f && /^  [A-Za-z]/{f=0} f && /^    if:/' "$WF")"
check "the deploy job carries no event-conditional if:" "" "$job_if"

assert_summary "deploy-triggers"
