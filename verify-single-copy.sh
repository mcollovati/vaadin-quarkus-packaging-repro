#!/usr/bin/env bash
# Checks that the packaged application holds exactly one copy of the Vaadin
# production bundle. Counting entries per archive is not enough: 19 + 3 and 20
# are the same set of files, because directory entries are counted in both
# archives. So this compares the entry names themselves.
#
# Three checks, in order of importance:
#
#   1. no file under META-INF/VAADIN is in more than one archive
#   2. flow-build-info.json is in exactly one archive - zero copies breaks a
#      production start and is invisible in the counts
#   3. the application has a bundle at all
#
# Usage: ./verify-single-copy.sh <case-directory>
# Prints one line per failed check and a final verdict, and exits non-zero when
# the verdict is FAIL.
set -u

case_dir="${1:?usage: verify-single-copy.sh <case-directory>}"
token="META-INF/VAADIN/config/flow-build-info.json"

build_dir="$case_dir/target"
[ -d "$build_dir" ] || build_dir="$case_dir/build"
if [ ! -d "$build_dir" ]; then
    echo "no build output in $case_dir"
    echo "single copy: FAIL"
    exit 1
fi

# lib/ holds the unchanged third party dependencies, and the Gradle plugin
# stages copies of the whole application under build/quarkus-build before it
# writes the final one, which would look like duplicates.
entries=$(find "$build_dir" -name '*.jar' \
        -not -path '*/lib/*' -not -path '*/quarkus-build/*' \
        | sort | while read -r jar; do
    unzip -l "$jar" | awk -v jar="${jar#"$case_dir"/}" \
        '$4 ~ /^META-INF\/VAADIN\// && $4 !~ /\/$/ { print $4, jar }'
done)

failures=0

duplicated=$(printf '%s\n' "$entries" | awk 'NF' | awk '{print $1}' | sort \
        | uniq -d)
if [ -n "$duplicated" ]; then
    count=$(printf '%s\n' "$duplicated" | wc -l | tr -d ' ')
    echo "$count file(s) packaged more than once, for example:"
    printf '%s\n' "$duplicated" | head -3 | while read -r name; do
        printf '  %s\n    %s\n' "$name" \
            "$(printf '%s\n' "$entries" | awk -v n="$name" \
                '$1 == n { print $2 }' | paste -sd', ' -)"
    done
    failures=$((failures + 1))
fi

token_copies=$(printf '%s\n' "$entries" | awk -v t="$token" \
        '$1 == t { print $2 }' | wc -l | tr -d ' ')
if [ "$token_copies" != 1 ]; then
    echo "flow-build-info.json is in $token_copies archive(s), expected 1"
    failures=$((failures + 1))
fi

total=$(printf '%s\n' "$entries" | awk 'NF' | wc -l | tr -d ' ')
if [ "$total" -eq 0 ]; then
    echo "no META-INF/VAADIN files in the packaged application"
    failures=$((failures + 1))
fi

if [ "$failures" -eq 0 ]; then
    echo "single copy: PASS ($total files, each in one archive)"
    exit 0
fi
echo "single copy: FAIL"
exit 1
