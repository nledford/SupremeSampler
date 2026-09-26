#!/usr/bin/env bash
# Watch a release tag's GitHub Actions runs, then check the published release.
#
# Usage: scripts/release-watch.sh <tag>      (run from inside the repo)
#
# Finds the runs for the tag's commit (not by title: CI and Release share
# one), waits for the CI and Release workflows to start, watches every run
# to the end, then waits for the GitHub release and checks it has a .dmg
# and SHA256SUMS.
#
# Exit codes are part of the contract:
#   0   every run passed and the release has its assets
#   2   the tag doesn't exist locally
#   3   a required workflow never started
#   4   a run failed
#   5   the release never appeared, or is missing an asset
#   6   a run's result couldn't be read from GitHub
#   64  usage error
#
# Test seams: GH (the gh binary), RELEASE_WATCH_INTERVAL (seconds between
# checks, default 10), RELEASE_WATCH_ATTEMPTS (checks before giving up,
# default 60, i.e. ten minutes).
#
# Always run with bash (the shebang, or `bash scripts/...`): 2026-09-26, an
# ad-hoc zsh watcher passed two run IDs as one word and reported a false
# failure, since zsh doesn't split unquoted variables.
set -euo pipefail

gh_cmd="${GH:-gh}"
interval="${RELEASE_WATCH_INTERVAL:-10}"
attempts="${RELEASE_WATCH_ATTEMPTS:-60}"
required_workflows="CI Release"

usage() {
    echo "usage: scripts/release-watch.sh <tag>" >&2
    exit 64
}

[ "$#" -eq 1 ] || usage
tag="$1"

sha="$(git rev-list -n 1 "$tag" 2>/dev/null)" || {
    echo "no such tag here: $tag (fetch tags, or check the name)" >&2
    exit 2
}

# 1. Wait for every required workflow to have a run on the tag's commit.
# Plain strings, not arrays: macOS's bash 3.2 errors on an empty array
# under `set -u`.
attempt=0
while :; do
    attempt=$((attempt + 1))
    runs="$("$gh_cmd" run list --commit "$sha" \
        --json databaseId,workflowName --jq '.[] | "\(.databaseId) \(.workflowName)"')"
    missing=""
    for workflow in $required_workflows; do
        printf '%s\n' "$runs" | grep -q " $workflow\$" || missing="$missing $workflow"
    done
    [ -z "$missing" ] && break
    if [ "$attempt" -ge "$attempts" ]; then
        echo "no run started for$missing on $tag ($sha) after $attempts checks" >&2
        exit 3
    fi
    sleep "$interval"
done

# 2. Watch each run to the end, one `gh run watch` per ID, and keep going
# after a failure so every result is reported. `gh run watch` also exits
# non-zero on its own errors (network, API), so a non-zero exit is checked
# against the run's recorded conclusion before calling the run failed.
failed=""
unreadable=""
while read -r id workflow; do
    [ -n "$id" ] || continue
    echo "watching $workflow (run $id)..."
    # gh's live progress goes to stdout; its errors still reach stderr.
    if "$gh_cmd" run watch "$id" --exit-status >/dev/null; then
        echo "ok: $workflow"
        continue
    fi
    if ! conclusion="$("$gh_cmd" run view "$id" --json conclusion --jq .conclusion)"; then
        echo "couldn't read the result of $workflow (run $id)" >&2
        unreadable="$unreadable $workflow"
    elif [ "$conclusion" = "success" ]; then
        echo "note: gh run watch errored, but GitHub records $workflow as success" >&2
        echo "ok: $workflow"
    else
        echo "failed: $workflow (run $id): $conclusion" >&2
        failed="$failed $workflow"
    fi
done <<< "$runs"
if [ -n "$failed" ]; then
    echo "runs failed for $tag:$failed" >&2
    exit 4
fi
if [ -n "$unreadable" ]; then
    echo "couldn't confirm$unreadable for $tag; rerun: just release-watch $tag" >&2
    exit 6
fi

# 3. Wait for the release, then check its assets.
attempt=0
while :; do
    attempt=$((attempt + 1))
    if assets="$("$gh_cmd" release view "$tag" --json assets --jq '.assets[].name' 2>/dev/null)"; then
        break
    fi
    if [ "$attempt" -ge "$attempts" ]; then
        echo "no GitHub release for $tag after $attempts checks" >&2
        exit 5
    fi
    sleep "$interval"
done

missing=""
printf '%s\n' "$assets" | grep -q '\.dmg$' || missing="$missing a .dmg"
printf '%s\n' "$assets" | grep -qx 'SHA256SUMS' || missing="$missing SHA256SUMS"
if [ -n "$missing" ]; then
    echo "release $tag is missing:$missing (has: $(printf '%s ' $assets))" >&2
    exit 5
fi

echo "ok: release $tag has $(printf '%s\n' "$assets" | paste -sd ',' - | sed 's/,/, /g')"
