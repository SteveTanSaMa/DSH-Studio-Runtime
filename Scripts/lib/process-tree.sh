#!/usr/bin/env bash
# Process-tree helpers shared by runtime-smoke.sh and the offline test suite.
#
# Everything here works on PIDs that were observed while the process was still
# alive. Once a parent exits its children are reparented to launchd, so they can
# no longer be found from the parent: a check that only looks afterwards reports
# success while leaving a server running. Recording first and asserting later is
# the only order that catches that.

PTREE_RECORDED="${PTREE_RECORDED:-}"

# Prints every descendant of a PID, children first.
ptree_descendants() {
    local parent="$1" child
    for child in $(pgrep -P "$parent" 2>/dev/null || true); do
        ptree_descendants "$child"
        printf '%s\n' "$child"
    done
    return 0
}

# Adds a PID to the recorded set, ignoring empty values and duplicates.
ptree_record() {
    local pid="$1" recorded
    [ -n "$pid" ] || return 0
    for recorded in $PTREE_RECORDED; do
        [ "$recorded" = "$pid" ] && return 0
    done
    PTREE_RECORDED="$PTREE_RECORDED $pid"
    return 0
}

# Records a PID together with every descendant it has right now.
ptree_record_tree() {
    local pid
    ptree_record "$1"
    for pid in $(ptree_descendants "$1"); do
        ptree_record "$pid"
    done
    return 0
}

# The recording shell and its parent are never signalled: a cleanup that killed
# its own caller would be worse than the leak it is fixing.
ptree_is_protected() {
    [ "$1" = "$$" ] || [ "$1" = "$PPID" ]
}

ptree_alive() {
    kill -0 "$1" 2>/dev/null
}

# Prints the recorded PIDs that are still alive.
ptree_survivors() {
    local pid
    for pid in $PTREE_RECORDED; do
        ptree_is_protected "$pid" && continue
        ptree_alive "$pid" && printf '%s\n' "$pid"
    done
    return 0
}

ptree_any_alive() {
    [ -n "$(ptree_survivors)" ]
}

ptree_recorded_count() {
    local pid count=0
    for pid in $PTREE_RECORDED; do
        count=$((count + 1))
    done
    printf '%s\n' "$count"
}

# Prints PID, parent and command line for everything still alive, for failure
# messages.
ptree_describe_survivors() {
    local pid
    for pid in $(ptree_survivors); do
        ps -o pid=,ppid=,command= -p "$pid" 2>/dev/null | cut -c1-160 || true
    done
    return 0
}

# Waits (default 5s) for every recorded PID to exit on its own.
ptree_wait_until_gone() {
    local attempts="${1:-10}"
    for _ in $(seq 1 "$attempts"); do
        ptree_any_alive || return 0
        sleep 0.5
    done
    return 1
}

# Stops one PID: TERM, a short grace period, then KILL. Returns 1 when it had to
# escalate, so a caller can report that the process did not shut down cleanly.
ptree_stop_pid() {
    local pid="$1" attempts="${2:-20}"
    ptree_alive "$pid" || return 0
    kill -TERM "$pid" 2>/dev/null || true
    local attempt
    for attempt in $(seq 1 "$attempts"); do
        ptree_alive "$pid" || return 0
        sleep 0.5
    done
    return 1
}

# Best-effort sweep of the recorded set: TERM, a short grace period, then KILL
# for whatever is still alive. Only PIDs this run actually observed are
# signalled — never by name or pattern, so a CI runner or the developer's other
# processes cannot be hit — and the sweep always returns 0, because a process
# that exited on its own is the expected case rather than an error.
ptree_cleanup_recorded() {
    local pid
    for pid in $PTREE_RECORDED; do
        ptree_is_protected "$pid" && continue
        ptree_alive "$pid" || continue
        kill -TERM "$pid" 2>/dev/null || true
    done
    if ptree_wait_until_gone 6; then
        return 0
    fi
    for pid in $PTREE_RECORDED; do
        ptree_is_protected "$pid" && continue
        ptree_alive "$pid" || continue
        kill -KILL "$pid" 2>/dev/null || true
    done
    return 0
}
