#!/usr/bin/env bash
set -euo pipefail

# Chooses which Harness versions a scheduled Runtime build may try.
#
# Inputs are plain text: the upstream release list, the Runtime releases that
# already exist, a floor version, and an explicit skip list. Nothing here talks
# to the network or to GitHub, so the selection is fully testable offline and the
# workflow keeps owning the npm availability check.
#
# Usage: select-next-runtime-version.sh --releases TSV --published TXT --floor VERSION \
#            [--skips PATH] [--today YYYY-MM-DD]
#
#   --releases   one upstream release per line, "tag<TAB>published_at", in the
#                order they were published (the workflow sorts by published_at).
#   --published  one published Runtime release tag per line ("runtime-<version>").
#                Lines that do not look like that are ignored.
#   --floor      the version the scan starts after; versions up to and including
#                it are never selected. Missing from the input => no candidates.
#   --skips      "version | until | reason" per line; '#' comments and blank
#                lines are ignored. Both the date and the reason are mandatory.
#   --today      only used to evaluate skip expiry; defaults to the current UTC
#                date so a run is reproducible when it is passed explicitly.
#
# stdout: every eligible version, oldest first, one per line. The caller tries
#         them in order (it holds the npm check), so an empty stdout means
#         "nothing to build".
# stderr: one line per decision, "::warning::" for anything skipped, and a final
#         summary that says whether other versions are queued behind the first.
# exit:   0 when the selection ran (including "no candidates"); 2 on malformed input.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RELEASES_PATH=""
PUBLISHED_PATH=""
FLOOR=""
SKIPS_PATH=""
TODAY="$(date -u '+%Y-%m-%d')"

fail() {
    printf 'select-next-runtime-version: %s\n' "$1" >&2
    exit 2
}

warn() {
    printf '::warning::%s\n' "$1" >&2
}

note() {
    printf '::notice::%s\n' "$1" >&2
}

while [ "$#" -gt 0 ]; do
    case "${1:-}" in
        --releases) RELEASES_PATH="${2:-}"; shift 2 ;;
        --published) PUBLISHED_PATH="${2:-}"; shift 2 ;;
        --floor) FLOOR="${2:-}"; shift 2 ;;
        --skips) SKIPS_PATH="${2:-}"; shift 2 ;;
        --today) TODAY="${2:-}"; shift 2 ;;
        *) fail "unknown argument: ${1:-}" ;;
    esac
done

[ -n "$RELEASES_PATH" ] || fail "--releases is required"
[ -n "$PUBLISHED_PATH" ] || fail "--published is required"
[ -n "$FLOOR" ] || fail "--floor is required"
[ -f "$RELEASES_PATH" ] || fail "release list does not exist: $RELEASES_PATH"
[ -f "$PUBLISHED_PATH" ] || fail "published list does not exist: $PUBLISHED_PATH"

VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$'
# Month 01-12 and day 01-31: this is a deadline, so range validation is enough
# (a zero-padded ISO date also compares correctly as a string).
DATE_PATTERN='^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'
case "$FLOOR" in
    *[!A-Za-z0-9._-]*) fail "floor version contains unsupported characters: $FLOOR" ;;
esac
[[ "$FLOOR" =~ $VERSION_PATTERN ]] || fail "floor is not an upstream version: $FLOOR"
[[ "$TODAY" =~ $DATE_PATTERN ]] || fail "--today must be YYYY-MM-DD: $TODAY"

# The skip list is validated in full before anything is selected: a malformed
# record must stop the run rather than silently change which versions get built.
if [ -n "$SKIPS_PATH" ] && [ -f "$SKIPS_PATH" ]; then
    line_number=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        case "$line" in
            ''|'#'*) continue ;;
        esac
        version="$(printf '%s' "$line" | cut -d'|' -f1 | tr -d '[:space:]')"
        until_date="$(printf '%s' "$line" | cut -d'|' -f2 | tr -d '[:space:]')"
        reason="$(printf '%s' "$line" | cut -d'|' -f3- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$version" ] || fail "$SKIPS_PATH:$line_number: missing version"
        [ -n "$until_date" ] || fail "$SKIPS_PATH:$line_number: missing the mandatory until date ($version)"
        [ -n "$reason" ] || fail "$SKIPS_PATH:$line_number: missing a reason ($version)"
        [[ "$version" =~ $VERSION_PATTERN ]] || fail "$SKIPS_PATH:$line_number: not an upstream version: $version"
        [[ "$until_date" =~ $DATE_PATTERN ]] || fail \
            "$SKIPS_PATH:$line_number: until must be YYYY-MM-DD: $until_date"
    done < "$SKIPS_PATH"
else
    SKIPS_PATH=""
fi

# Prints "hit <until> <reason>" when the version is currently skipped,
# "expired <until> <reason>" when its record has lapsed, nothing otherwise.
skip_lookup() {
    local lookup_version="$1"
    [ -n "$SKIPS_PATH" ] || return 0
    local line version until_date reason
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        version="$(printf '%s' "$line" | cut -d'|' -f1 | tr -d '[:space:]')"
        [ "$version" = "$lookup_version" ] || continue
        until_date="$(printf '%s' "$line" | cut -d'|' -f2 | tr -d '[:space:]')"
        reason="$(printf '%s' "$line" | cut -d'|' -f3- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [ "$until_date" \> "$TODAY" ] || [ "$until_date" = "$TODAY" ]; then
            printf 'hit %s %s\n' "$until_date" "$reason"
        else
            printf 'expired %s %s\n' "$until_date" "$reason"
        fi
        return 0
    done < "$SKIPS_PATH"
    return 0
}

is_published() {
    local candidate="runtime-$1"
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        [ "$line" = "$candidate" ] && return 0
    done < "$PUBLISHED_PATH"
    return 1
}

candidates=0
skipped=0
expired_retries=0
baseline_reached=false
first_candidate=""
last_skip_until=""

while IFS=$'\t' read -r tag published_at || [ -n "${tag:-}" ]; do
    [ -n "${tag:-}" ] || continue
    case "$tag" in
        dsh-v*) harness_version="${tag#dsh-v}" ;;
        *) fail "unexpected upstream tag (expected dsh-v<version>): $tag" ;;
    esac
    [[ "$harness_version" =~ $VERSION_PATTERN ]] || fail "unexpected upstream version: $harness_version"

    if [ "$harness_version" = "$FLOOR" ]; then
        baseline_reached=true
        note "selection: floor $FLOOR reached (${published_at:-unknown}); scanning later versions"
        continue
    fi
    [ "$baseline_reached" = true ] || continue

    if is_published "$harness_version"; then
        note "selection: runtime-$harness_version already exists; skipping"
        continue
    fi

    decision="$(skip_lookup "$harness_version")"
    case "$decision" in
        hit\ *)
            until_date="$(printf '%s' "$decision" | cut -d' ' -f2)"
            reason="$(printf '%s' "$decision" | cut -d' ' -f3-)"
            warn "skipping $harness_version until $until_date — $reason (recorded in the skip list; not built, not forgotten)"
            skipped=$((skipped + 1))
            last_skip_until="$until_date"
            continue
            ;;
        expired\ *)
            until_date="$(printf '%s' "$decision" | cut -d' ' -f2)"
            reason="$(printf '%s' "$decision" | cut -d' ' -f3-)"
            warn "the skip recorded for $harness_version expired on $until_date ($reason); it is a candidate again and will be retried"
            expired_retries=$((expired_retries + 1))
            ;;
    esac

    printf '%s\n' "$harness_version"
    candidates=$((candidates + 1))
    [ -n "$first_candidate" ] || first_candidate="$harness_version"
done < "$RELEASES_PATH"

if [ "$baseline_reached" != true ]; then
    warn "the floor version $FLOOR is not in the upstream release list; refusing to select anything"
fi

if [ "$candidates" -eq 0 ]; then
    if [ "$skipped" -gt 0 ] && [ "$baseline_reached" = true ]; then
        note "selection: every candidate is skip-listed (latest until $last_skip_until); nothing will be built until a record expires or is removed"
    elif [ "$baseline_reached" = true ]; then
        note "selection: no candidate above $FLOOR is both unpublished and unskipped; nothing to build"
    fi
    exit 0
fi

if [ "$candidates" -eq 1 ]; then
    note "selection: $candidates candidate ($first_candidate); it is the only one, so a build failure blocks nothing else"
else
    note "selection: $candidates candidate(s); the workflow tries them oldest first and stops at the first one present on npm — if $first_candidate keeps failing, the other $((candidates - 1)) stay queued behind it until it is skipped or builds"
fi
if [ "$expired_retries" -gt 0 ]; then
    note "selection: $expired_retries version(s) re-entered the candidate list because their skip expired"
fi
exit 0
