#!/usr/bin/env bash
# Lists every archive a case produced and counts the three markers in each:
#
#   VAADIN   entries under META-INF/VAADIN - the Vaadin production bundle
#   late     META-INF/PROBE/late.txt, written into the resources output
#            directory during augmentation
#   emitted  META-INF/PROBE/emitted.txt, produced as a GeneratedResourceBuildItem
#
# Usage: ./inspect.sh <case-directory>
set -u

case_dir="${1:?usage: inspect.sh <case-directory>}"
build_dir="$case_dir/target"
[ -d "$build_dir" ] || build_dir="$case_dir/build"

if [ ! -d "$build_dir" ]; then
    echo "no build output in $case_dir"
    exit 0
fi

# Any lib/ directory holds the unchanged third party dependencies.
find "$build_dir" -name '*.jar' -not -path '*/lib/*' \
        | sort | while read -r jar; do
    listing=$(unzip -l "$jar")
    printf '%-78s VAADIN=%-5s late=%-3s emitted=%s\n' \
        "${jar#"$case_dir"/}" \
        "$(printf '%s' "$listing" | grep -c 'META-INF/VAADIN')" \
        "$(printf '%s' "$listing" | grep -c 'META-INF/PROBE/late')" \
        "$(printf '%s' "$listing" | grep -c 'META-INF/PROBE/emitted')"
done
