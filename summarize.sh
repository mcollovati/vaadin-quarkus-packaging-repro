#!/usr/bin/env bash
# Condenses results/ into one Markdown table row per cell.
set -u

root_dir="$(cd "$(dirname "$0")" && pwd)"

printf '| case | jar type | build | archive root | predicate | emitter |\n'
printf '|---|---|---|---|---|---|\n'

for report in "$root_dir"/results/*.txt; do
    [ -e "$report" ] || continue
    name=$(basename "$report" .txt)
    case_name="${name%.*}"
    jar_type="${name##*.}"

    build=$(awk -F': +' '/^build:/ {print $2}' "$report")
    predicate=$(awk -F= '/^PROBE\|predicateRootArchiveIncludesOutput/ {print $2}' "$report")
    root_kind=$(grep -q 'isDirectory=true' "$report" && echo directory || echo archive)
    grep -q '^PROBE|archiveRootResolvedPath' "$report" || root_kind='-'

    # The emitter is required wherever an archive carries the emitted
    # marker but not the late one: nothing else delivered the bundle there.
    if grep -qE 'late=[1-9].*emitted=0|late=[1-9]' "$report"; then
        emitter=redundant
    elif grep -q 'emitted=1' "$report"; then
        emitter='required'
    else
        emitter='-'
    fi
    [ "$build" = FAILURE ] && { predicate="${predicate:--}"; emitter='-'; }

    printf '| %s | %s | %s | %s | %s | %s |\n' \
        "$case_name" "$jar_type" "$build" "$root_kind" "${predicate:--}" "$emitter"
done
