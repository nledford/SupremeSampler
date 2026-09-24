#!/usr/bin/env bash
# Acceptance tests for scripts/release-version.sh.
#
# Each scenario is a Given/When/Then example: it writes a synthetic project.yml
# into a temp directory, points the script at it via PROJECT_YML (the script's
# only test seam), runs `check <tag>`, and asserts on the exit code and output.
#
# Run: bash scripts/tests/release-version-test.sh
set -uo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/release-version.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
scenario=0

# run_check <project-yml-contents-or-__MISSING__> <tag>
# Sets: status, out, err
run_check() {
    local contents="$1" tag="$2"
    scenario=$((scenario + 1))
    local dir="$tmp/$scenario"
    mkdir -p "$dir"
    if [ "$contents" != "__MISSING__" ]; then
        printf '%s\n' "$contents" > "$dir/project.yml"
    fi
    out="$(PROJECT_YML="$dir/project.yml" bash "$script" check "$tag" 2>"$dir/err")"
    status=$?
    err="$(cat "$dir/err")"
}

pass() { echo "ok - $1"; }
fail() { echo "not ok - $1" >&2; failures=$((failures + 1)); }

assert_status() {
    local want="$1" name="$2"
    if [ "$status" -eq "$want" ]; then pass "$name (exit $status)"; else
        fail "$name: expected exit $want, got $status (stderr: $err)"
    fi
}

assert_stdout_contains() {
    local needle="$1" name="$2"
    case "$out" in *"$needle"*) pass "$name (stdout)";; *)
        fail "$name: stdout missing '$needle' (got: $out)";; esac
}

assert_stderr_contains() {
    local needle="$1" name="$2"
    case "$err" in *"$needle"*) pass "$name (stderr)";; *)
        fail "$name: stderr missing '$needle' (got: $err)";; esac
}

# --- Scenario 1: matching tag succeeds -------------------------------------
run_check 'settings:
  base:
    MARKETING_VERSION: "0.1.0"' v0.1.0
assert_status 0 test_givenTagMatchesMarketingVersion_whenChecking_thenSucceeds
assert_stdout_contains 'ok: v0.1.0 matches MARKETING_VERSION 0.1.0' \
    test_givenTagMatchesMarketingVersion_whenChecking_thenSucceeds

# --- Scenario 2: mismatched tag fails, naming both values ------------------
run_check 'settings:
  base:
    MARKETING_VERSION: "0.1.0"' v0.2.0
assert_status 4 test_givenTagDiffersFromMarketingVersion_whenChecking_thenFailsWithBothValues
assert_stderr_contains 'v0.2.0' test_givenTagDiffersFromMarketingVersion_whenChecking_thenFailsWithBothValues
assert_stderr_contains '0.1.0' test_givenTagDiffersFromMarketingVersion_whenChecking_thenFailsWithBothValues

# --- Scenario 3: non-semver tags are rejected ------------------------------
for bad in 0.1.0 v0.1 release-1 v0.1.0- v0.1.0-rc..1 v0.1.0-rc. v01.1.1 v0.1.0+build; do
    run_check 'settings:
  base:
    MARKETING_VERSION: "0.1.0"' "$bad"
    assert_status 2 "test_givenTagIsNotSemver_whenChecking_thenFailsAsNotAReleaseTag [$bad]"
    assert_stderr_contains 'not a release tag' \
        "test_givenTagIsNotSemver_whenChecking_thenFailsAsNotAReleaseTag [$bad]"
done

# --- Scenario 4: prerelease sharing the core version succeeds --------------
run_check 'settings:
  base:
    MARKETING_VERSION: "0.2.0"' v0.2.0-rc.1
assert_status 0 test_givenPrereleaseTagSharesCoreVersion_whenChecking_thenSucceeds

# --- Scenario 5: prerelease with a different core fails --------------------
run_check 'settings:
  base:
    MARKETING_VERSION: "0.2.0"' v0.3.0-rc.1
assert_status 4 test_givenPrereleaseTagHasDifferentCore_whenChecking_thenFails

# --- Scenario 6: no MARKETING_VERSION is an error --------------------------
run_check 'settings:
  base:
    SWIFT_VERSION: "5.10"' v0.1.0
assert_status 3 test_givenProjectYmlHasNoMarketingVersion_whenChecking_thenFails
assert_stderr_contains 'MARKETING_VERSION' test_givenProjectYmlHasNoMarketingVersion_whenChecking_thenFails

# --- Scenario 7: two MARKETING_VERSIONs is ambiguous -----------------------
run_check 'settings:
  base:
    MARKETING_VERSION: "0.1.0"
  other:
    MARKETING_VERSION: "0.2.0"' v0.1.0
assert_status 3 test_givenProjectYmlHasTwoMarketingVersions_whenChecking_thenFails

# --- Scenario 8: missing project.yml is an error ---------------------------
run_check '__MISSING__' v0.1.0
assert_status 3 test_givenProjectYmlIsMissing_whenChecking_thenFails

echo
if [ "$failures" -eq 0 ]; then
    echo "all scenarios passed"
else
    echo "$failures assertion(s) failed" >&2
    exit 1
fi
