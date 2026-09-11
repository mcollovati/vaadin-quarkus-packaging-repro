#!/usr/bin/env bash
# Builds every case against every jar type and writes one report per cell into
# results/. Run ./run-all.sh <case> ... to limit it to some of the cases.
set -u

root_dir="$(cd "$(dirname "$0")" && pwd)"
results_dir="$root_dir/results"
mkdir -p "$results_dir"

all_cases="maven-quarkus maven-jar maven-jar-no-extensions maven-jar-no-generate-code gradle"
cases="${*:-$all_cases}"

# The jar type is a plain Quarkus property, so it needs no separate project.
# sources-only reaches the native source jar builder without GraalVM.
jar_types="${JAR_TYPES:-fast-jar uber-jar legacy-jar mutable-jar native-sources}"

flags_for() {
    case "$1" in
        native-sources)
            # jar.enabled=false because the Gradle plugin refuses to emit a
            # native and a JAR package in the same build.
            echo "-Dquarkus.native.enabled=true -Dquarkus.native.sources-only=true -Dquarkus.package.jar.enabled=false" ;;
        *)
            echo "-Dquarkus.package.jar.type=$1" ;;
    esac
}

# Version overrides, so the matrix can run against a locally built extension.
# See "Running against a local snapshot" in the README.
overrides_for() {
    local overrides=""
    if [ -n "${VAADIN_QUARKUS_VERSION:-}" ]; then
        if [ "$1" = gradle ]; then
            overrides="-PvaadinQuarkusVersion=$VAADIN_QUARKUS_VERSION"
        else
            overrides="-Dvaadin.quarkus.version=$VAADIN_QUARKUS_VERSION"
        fi
    fi
    if [ -n "${FLOW_VERSION:-}" ]; then
        if [ "$1" = gradle ]; then
            overrides="$overrides -PflowVersion=$FLOW_VERSION"
        else
            overrides="$overrides -Dvaadin.flow.version=$FLOW_VERSION"
        fi
    fi
    echo "$overrides"
}

install_probe() {
    echo "==> installing the probe extension"
    (cd "$root_dir/probe-extension" && mvn -q -B install -DskipTests) \
        || { echo "the probe extension failed to build"; exit 1; }
}

install_probe

for case_name in $cases; do
    case_dir="$root_dir/$case_name"
    if [ ! -d "$case_dir" ]; then
        echo "no such case: $case_name" >&2
        continue
    fi
    for jar_type in $jar_types; do
        report="$results_dir/$case_name.$jar_type.txt"
        echo "==> $case_name / $jar_type"

        log=$(mktemp)
        if [ "$case_name" = gradle ]; then
            (cd "$case_dir" && ./gradlew --no-daemon clean quarkusBuild \
                $(flags_for "$jar_type") $(overrides_for gradle)) >"$log" 2>&1
        else
            (cd "$case_dir" && mvn -B clean package -DskipTests \
                $(flags_for "$jar_type") $(overrides_for maven)) >"$log" 2>&1
        fi
        status=$?

        {
            echo "case:     $case_name"
            echo "jar type: $jar_type"
            echo "build:    $([ $status -eq 0 ] && echo SUCCESS || echo FAILURE)"
            echo
            echo "--- probe ---"
            grep '^PROBE|' "$log" || echo "(the probe did not run)"
            echo
            echo "--- archives ---"
            "$root_dir/inspect.sh" "$case_dir"
            if [ $status -ne 0 ]; then
                echo
                echo "--- build failure ---"
                grep -E '^\[ERROR\]|error\]:' "$log" | head -20
            fi
        } >"$report"

        rm -f "$log"
        sed -n '1,3p' "$report" | tr '\n' ' '
        echo
    done
done

echo
echo "reports written to $results_dir"
