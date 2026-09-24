#!/usr/bin/env bash
# Check that a release tag matches MARKETING_VERSION in project.yml.
#
# Usage: scripts/release-version.sh check <tag>
#
# Exit codes are part of the contract:
#   0  the tag matches
#   2  the tag is not a release tag (vX.Y.Z or vX.Y.Z-<prerelease>)
#   3  the version source is unreadable or ambiguous
#   4  the tag does not match MARKETING_VERSION
#
# PROJECT_YML overrides the project.yml path (the test seam); it defaults to
# <repo root>/project.yml, resolved from this script's own location.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
project_yml="${PROJECT_YML:-$root/project.yml}"

usage() {
    echo "usage: scripts/release-version.sh check <tag>" >&2
    exit 64
}

[ "$#" -eq 2 ] || usage
[ "$1" = "check" ] || usage
tag="$2"

# Core components have no leading zeros (semver); a prerelease is one or more
# dot-separated alphanumeric identifiers, none empty.
if ! printf '%s' "$tag" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$'; then
    echo "not a release tag: $tag" >&2
    exit 2
fi

if [ ! -f "$project_yml" ]; then
    echo "no project.yml at $project_yml" >&2
    exit 3
fi

versions="$(awk -F'"' '/^[[:space:]]*MARKETING_VERSION:/{print $2}' "$project_yml")"
count="$(printf '%s' "$versions" | grep -c . || true)"
if [ "$count" -ne 1 ]; then
    echo "expected exactly one MARKETING_VERSION in $project_yml, found $count" >&2
    exit 3
fi

core="${tag#v}"
core="${core%%-*}"
if [ "v$core" != "v$versions" ]; then
    echo "tag $tag does not match MARKETING_VERSION $versions in $project_yml" >&2
    exit 4
fi

echo "ok: $tag matches MARKETING_VERSION $versions"
