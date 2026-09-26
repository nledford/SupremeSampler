#!/usr/bin/env bash
# Acceptance tests for scripts/release-watch.sh.
#
# Each scenario is a Given/When/Then example: it makes a throwaway git repo
# with a tagged commit, puts a fake `gh` on the script's GH seam, scripts
# what the fake reports (which runs exist, how each ends, what the release
# holds, and how many checks pass before each appears), runs the watcher
# with no delay between checks, and asserts on the exit code, the output
# and what the fake was asked.
#
# Run: bash scripts/tests/release-watch-test.sh
set -uo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/release-watch.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
scenario=0

# The fake gh. State lives in $FAKE_GH_STATE:
#   runs            "<id> <workflow>" lines that `run list` prints
#   runs-delay      `run list` calls that print nothing first (default 0)
#   list-fail       `run list` calls that fail first, as gh does on a
#                   network or API error (default 0; "all" = every call)
#   watch-<id>      exit status of `run watch <id>` (default 0)
#   conclusion-<id> what `run view <id>` reports (default success);
#                   "__ERROR__" makes `run view` itself fail
#   watched         each `run watch` ID argument, as "[<arg>]" (written)
#   assets          asset names `release view` prints; absent = no release
#   release-delay   `release view` calls that fail first (default 0)
#   release-error   what a failing `release view` prints (default
#                   "release not found")
# It logs every call's arguments to calls.log.
cat > "$tmp/gh" <<'FAKE'
#!/usr/bin/env bash
set -u
state="$FAKE_GH_STATE"
echo "$*" >> "$state/calls.log"
count() {  # count <name>: bump and print a call counter
    local n=$(( $(cat "$state/$1.count" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$state/$1.count"
    echo "$n"
}
case "$1 $2" in
    "run list")
        n="$(count list)"
        fails="$(cat "$state/list-fail" 2>/dev/null || echo 0)"
        if [ "$fails" = all ] || [ "$n" -le "$fails" ]; then
            echo "error connecting to api.github.com" >&2
            exit 1
        fi
        if [ "$n" -gt "$(cat "$state/runs-delay" 2>/dev/null || echo 0)" ]; then
            cat "$state/runs" 2>/dev/null
        fi
        ;;
    "run watch")
        # Brackets keep argument boundaries visible: one argument holding
        # "101<newline>102" logs as one bracketed pair, not two.
        printf '[%s]\n' "$3" >> "$state/watched"
        exit "$(cat "$state/watch-$3" 2>/dev/null || echo 0)"
        ;;
    "run view")
        c="$(cat "$state/conclusion-$3" 2>/dev/null || echo success)"
        if [ "$c" = "__ERROR__" ]; then echo "HTTP 502" >&2; exit 1; fi
        echo "$c"
        ;;
    "release view")
        n="$(count release)"
        if [ ! -f "$state/assets" ] \
            || [ "$n" -le "$(cat "$state/release-delay" 2>/dev/null || echo 0)" ]; then
            { cat "$state/release-error" 2>/dev/null || echo "release not found"; } >&2
            exit 1
        fi
        cat "$state/assets"
        ;;
    *) echo "fake gh: unexpected call: $*" >&2; exit 99 ;;
esac
FAKE
chmod +x "$tmp/gh"

# given_release <tag>: a fresh repo with one commit tagged <tag>, and an
# empty fake-gh state. Sets: dir, state, sha
given_release() {
    scenario=$((scenario + 1))
    dir="$tmp/$scenario"
    state="$dir/state"
    mkdir -p "$dir/repo" "$state"
    git -C "$dir/repo" init -q
    git -C "$dir/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m release
    git -C "$dir/repo" tag "$1"
    sha="$(git -C "$dir/repo" rev-parse HEAD)"
}

# watch [args...]: run the watcher in the scenario's repo. Sets: status, out, err
watch() {
    out="$(cd "$dir/repo" && GH="$tmp/gh" FAKE_GH_STATE="$state" \
        RELEASE_WATCH_INTERVAL=0 RELEASE_WATCH_ATTEMPTS=3 \
        bash "$script" "$@" 2>"$dir/err")"
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

# assert_file_equals <file> <expected contents> <name>
assert_file_equals() {
    local got
    got="$(cat "$1" 2>/dev/null)"
    if [ "$got" = "$2" ]; then pass "$3"; else
        fail "$3: expected '$2' in $(basename "$1"), got '$got'"
    fi
}

both_runs='101 CI
102 Release'
full_assets='SupremeSampler-0.3.1.dmg
SHA256SUMS'

# --- Scenario 1: both runs pass and the release has its assets -------------
given_release v0.3.1
printf '%s\n' "$both_runs" > "$state/runs"
printf '%s\n' "$full_assets" > "$state/assets"
watch v0.3.1
assert_status 0 test_givenPassingRunsAndACompleteRelease_whenWatching_thenSucceeds
assert_stdout_contains 'ok: CI' test_givenPassingRunsAndACompleteRelease_whenWatching_thenSucceeds
assert_stdout_contains 'ok: Release' test_givenPassingRunsAndACompleteRelease_whenWatching_thenSucceeds
assert_stdout_contains 'SupremeSampler-0.3.1.dmg' test_givenPassingRunsAndACompleteRelease_whenWatching_thenSucceeds

# --- Scenario 2: each run is watched on its own (regression) ---------------
# 2026-09-26: an ad-hoc watcher run under zsh passed both IDs to one
# `gh run watch` call, joined by a newline, and reported a false failure.
assert_file_equals "$state/watched" '[101]
[102]' test_givenTwoRuns_whenWatching_thenEachRunIsWatchedSeparately

# --- Scenario 3: runs are found by the tag's commit, not by title ----------
case "$(cat "$state/calls.log")" in
    *"run list --commit $sha "*) pass test_givenATag_whenFindingRuns_thenItQueriesTheTagsCommit ;;
    *) fail "test_givenATag_whenFindingRuns_thenItQueriesTheTagsCommit: no 'run list --commit $sha' in: $(cat "$state/calls.log")" ;;
esac

# --- Scenario 4: a failed run fails the watch, naming the workflow ---------
given_release v0.3.1
printf '%s\n' "$both_runs" > "$state/runs"
echo 1 > "$state/watch-101"
echo failure > "$state/conclusion-101"
printf '%s\n' "$full_assets" > "$state/assets"
watch v0.3.1
assert_status 4 test_givenAFailedRun_whenWatching_thenFailsNamingTheWorkflow
assert_stderr_contains 'CI (run 101): failure' test_givenAFailedRun_whenWatching_thenFailsNamingTheWorkflow
assert_file_equals "$state/watched" '[101]
[102]' test_givenAFailedRun_whenWatching_thenTheOtherRunIsStillWatched

# --- Scenario 4b: a gh hiccup on a run that passed is not a failure -------
# `gh run watch` exits non-zero on its own errors too (network, API), not
# only when the run failed; the run's recorded conclusion decides.
given_release v0.3.1
printf '%s\n' "$both_runs" > "$state/runs"
echo 1 > "$state/watch-101"
printf '%s\n' "$full_assets" > "$state/assets"
watch v0.3.1
assert_status 0 test_givenGhErrorsWhileWatchingAPassingRun_whenWatching_thenItStillPasses
assert_stdout_contains 'ok: CI' test_givenGhErrorsWhileWatchingAPassingRun_whenWatching_thenItStillPasses

# --- Scenario 4c: a run whose result can't be read is reported as such ----
given_release v0.3.1
printf '%s\n' "$both_runs" > "$state/runs"
echo 1 > "$state/watch-101"
echo __ERROR__ > "$state/conclusion-101"
printf '%s\n' "$full_assets" > "$state/assets"
watch v0.3.1
assert_status 6 test_givenARunWhoseResultCantBeRead_whenWatching_thenSaysItCouldNotCheck
assert_stderr_contains "couldn't read the result of CI (run 101)" \
    test_givenARunWhoseResultCantBeRead_whenWatching_thenSaysItCouldNotCheck

# --- Scenario 5: runs that appear late are waited for ----------------------
given_release v0.3.1
printf '%s\n' "$both_runs" > "$state/runs"
echo 2 > "$state/runs-delay"
printf '%s\n' "$full_assets" > "$state/assets"
watch v0.3.1
assert_status 0 test_givenRunsThatAppearLate_whenWatching_thenItWaitsForThem

# --- Scenario 6: a workflow that never starts times out, named -------------
given_release v0.3.1
echo '101 CI' > "$state/runs"
watch v0.3.1
assert_status 3 test_givenAWorkflowThatNeverStarts_whenWatching_thenFailsNamingIt
assert_stderr_contains 'Release' test_givenAWorkflowThatNeverStarts_whenWatching_thenFailsNamingIt

# --- Scenario 6b: a gh error while listing runs is retried, not fatal -----
# Adversarial review, 2026-09-26: one failed `gh run list` ended the watch
# with exit 1 (not in the contract) instead of polling again.
given_release v0.3.1
printf '%s\n' "$both_runs" > "$state/runs"
echo 2 > "$state/list-fail"
printf '%s\n' "$full_assets" > "$state/assets"
watch v0.3.1
assert_status 0 test_givenGhFailsWhileListingRunsAtFirst_whenWatching_thenItKeepsPolling

# --- Scenario 6c: gh failing every time says so, with gh's error ----------
given_release v0.3.1
echo all > "$state/list-fail"
watch v0.3.1
assert_status 6 test_givenGhFailsEveryTimeItListsRuns_whenWatching_thenItReportsGitHubCouldNotBeRead
assert_stderr_contains 'error connecting to api.github.com' \
    test_givenGhFailsEveryTimeItListsRuns_whenWatching_thenItReportsGitHubCouldNotBeRead

# --- Scenario 7: a release published late is waited for --------------------
given_release v0.3.1
printf '%s\n' "$both_runs" > "$state/runs"
printf '%s\n' "$full_assets" > "$state/assets"
echo 2 > "$state/release-delay"
watch v0.3.1
assert_status 0 test_givenAReleasePublishedLate_whenWatching_thenItWaitsForIt

# --- Scenario 8: a release that never appears fails ------------------------
given_release v0.3.1
printf '%s\n' "$both_runs" > "$state/runs"
watch v0.3.1
assert_status 5 test_givenNoReleaseEverAppears_whenWatching_thenFails
assert_stderr_contains 'v0.3.1' test_givenNoReleaseEverAppears_whenWatching_thenFails

# --- Scenario 8b: gh's own error is shown when the release never appears --
# An auth failure or outage used to be retried silently, then reported
# only as "no GitHub release".
given_release v0.3.1
printf '%s\n' "$both_runs" > "$state/runs"
echo 'HTTP 401: Bad credentials' > "$state/release-error"
watch v0.3.1
assert_status 5 test_givenGhErrorsWhileReadingTheRelease_whenItNeverAppears_thenTheErrorIsShown
assert_stderr_contains 'HTTP 401: Bad credentials' \
    test_givenGhErrorsWhileReadingTheRelease_whenItNeverAppears_thenTheErrorIsShown

# --- Scenario 9: missing assets fail, each one named ------------------------
given_release v0.3.1
printf '%s\n' "$both_runs" > "$state/runs"
echo 'SupremeSampler-0.3.1.dmg' > "$state/assets"
watch v0.3.1
assert_status 5 test_givenAReleaseWithoutChecksums_whenWatching_thenFailsNamingIt
assert_stderr_contains 'SHA256SUMS' test_givenAReleaseWithoutChecksums_whenWatching_thenFailsNamingIt

given_release v0.3.1
printf '%s\n' "$both_runs" > "$state/runs"
echo 'SHA256SUMS' > "$state/assets"
watch v0.3.1
assert_status 5 test_givenAReleaseWithoutADmg_whenWatching_thenFailsNamingIt
assert_stderr_contains '.dmg' test_givenAReleaseWithoutADmg_whenWatching_thenFailsNamingIt

# --- Scenario 10: an unknown tag is refused before asking GitHub -----------
given_release v0.3.1
watch v9.9.9
assert_status 2 test_givenAnUnknownTag_whenWatching_thenFailsWithoutCallingGitHub
assert_stderr_contains 'v9.9.9' test_givenAnUnknownTag_whenWatching_thenFailsWithoutCallingGitHub
if [ -e "$state/calls.log" ]; then
    fail "test_givenAnUnknownTag_whenWatching_thenFailsWithoutCallingGitHub: gh was called"
else
    pass test_givenAnUnknownTag_whenWatching_thenFailsWithoutCallingGitHub
fi

# --- Scenario 11: no tag is a usage error ----------------------------------
given_release v0.3.1
watch
assert_status 64 test_givenNoTag_whenWatching_thenPrintsUsage
assert_stderr_contains 'usage' test_givenNoTag_whenWatching_thenPrintsUsage

echo
if [ "$failures" -eq 0 ]; then
    echo "all scenarios passed"
else
    echo "$failures assertion(s) failed" >&2
    exit 1
fi
