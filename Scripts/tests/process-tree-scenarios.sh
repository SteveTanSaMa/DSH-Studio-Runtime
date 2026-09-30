#!/usr/bin/env bash
# Scenarios that exercise Scripts/lib/process-tree.sh against real processes.
#
# A leaked child process is a real process, so the only honest way to test the
# cleanup path is to leak one and watch it die. Each scenario runs in its own
# process (the offline suite invokes this script once per scenario), starts only
# processes it can name, and stops everything it started before returning.
#
# Usage: process-tree-scenarios.sh SCENARIO

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/process-tree.sh
. "$SCRIPT_DIR/../lib/process-tree.sh"

PARENT_PID=""
DECOY_PID=""

# Stands in for a Harness that starts a helper and keeps running: the helper is a
# child while the parent lives and becomes an orphan once the parent is stopped.
start_leaking_tree() {
    bash -c 'sleep 600 & sleep 600' &
    PARENT_PID=$!
    sleep 1
    PTREE_RECORDED=""
    ptree_record_tree "$PARENT_PID"
}

# Stands in for any other process on the machine: it is never recorded, so the
# sweep must not touch it.
start_decoy() {
    sleep 600 &
    DECOY_PID=$!
    sleep 0.5
}

fail() {
    printf 'process-tree-scenarios: %s\n' "$1" >&2
    return 1
}

cleanup_scenario() {
    ptree_cleanup_recorded
    for pid in "$DECOY_PID" "$PARENT_PID"; do
        [ -n "$pid" ] || continue
        kill -TERM "$pid" 2>/dev/null || true
    done
    return 0
}
trap cleanup_scenario EXIT

# A tree that is running is recorded completely, before anything can reparent it.
scenario_records() {
    start_leaking_tree
    [ "$(ptree_recorded_count)" -ge 2 ] || fail "the descendant tree was not recorded"
    ptree_any_alive || fail "the recorded processes should still be running"
    return 0
}

# A child that outlives its parent is reported, not silently missed.
scenario_detects_leak() {
    start_leaking_tree
    local children
    children="$(ptree_survivors | grep -v "^$PARENT_PID$")"
    [ -n "$children" ] || fail "the child was not recorded"
    ptree_stop_pid "$PARENT_PID" 20 || fail "the parent did not exit on SIGTERM"
    if ptree_wait_until_gone 4; then
        fail "the orphaned child was reported as gone"
    fi
    ptree_survivors | grep -q . || fail "the orphan was not reported as a survivor"
    return 0
}

# After a leak is detected, the recorded descendants are cleaned up.
scenario_cleans_leak() {
    start_leaking_tree
    ptree_stop_pid "$PARENT_PID" 20 || fail "the parent did not exit on SIGTERM"
    ptree_cleanup_recorded
    ptree_any_alive && fail "recorded processes survived the sweep"
    return 0
}

# A descendant that ignores SIGTERM is escalated to SIGKILL.
scenario_escalates() {
    bash -c 'trap "" TERM; while :; do sleep 1; done' &
    PARENT_PID=$!
    sleep 1
    PTREE_RECORDED=""
    ptree_record_tree "$PARENT_PID"
    ptree_cleanup_recorded
    ptree_any_alive && fail "a SIGTERM-ignoring descendant survived the sweep"
    return 0
}

# A recorded process that already exited is not an error.
scenario_best_effort() {
    local pid
    sleep 0.1 &
    pid=$!
    wait "$pid" 2>/dev/null || true
    PTREE_RECORDED=""
    ptree_record "$pid"
    ptree_cleanup_recorded || fail "the sweep reported a failure for an exited process"
    return 0
}

# Processes that were never recorded are left alone.
scenario_leaves_unrelated_alone() {
    start_decoy
    start_leaking_tree
    ptree_stop_pid "$PARENT_PID" 20 || fail "the parent did not exit on SIGTERM"
    ptree_cleanup_recorded
    ptree_alive "$DECOY_PID" || fail "the sweep signalled a process it had not recorded"
    return 0
}

# The recording shell and its parent can never be signalled.
scenario_protects_itself() {
    ptree_is_protected "$$" || fail "the recording shell is not protected"
    ptree_is_protected "1" && fail "an unrelated PID is treated as protected"
    PTREE_RECORDED=""
    ptree_record "$$"
    ptree_cleanup_recorded
    ptree_alive "$$" || fail "the recording shell was signalled"
    return 0
}

case "${1:-}" in
    records) scenario_records ;;
    detects-leak) scenario_detects_leak ;;
    cleans-leak) scenario_cleans_leak ;;
    escalates) scenario_escalates ;;
    best-effort) scenario_best_effort ;;
    leaves-unrelated-alone) scenario_leaves_unrelated_alone ;;
    protects-itself) scenario_protects_itself ;;
    *)
        printf 'usage: process-tree-scenarios.sh SCENARIO\n' >&2
        printf 'scenarios: records detects-leak cleans-leak escalates best-effort leaves-unrelated-alone protects-itself\n' >&2
        exit 2
        ;;
esac
