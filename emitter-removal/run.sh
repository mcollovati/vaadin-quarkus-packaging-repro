#!/usr/bin/env bash
# Builds five variants of the Vaadin Quarkus extension at tag 3.2.1 and, for
# each, packages the same application with it. This answers directly - by
# removing the emitter rather than by inferring from a probe marker - whether
# the bundle still reaches the packaged application.
#
#   baseline          unchanged 3.2.1
#   no-emitter        emitGeneratedFiles(emitter) call removed, the
#                     BuildProducer<GeneratedResourceBuildItem> parameter kept
#   no-producer       the call and the parameter both removed
#   produce-artifact  the call and the parameter removed, the build step kept
#                     alive with @Produce(ArtifactResultBuildItem.class)
#   conditional       the proposed fix: patches/conditional.patch, which emits
#                     only what packaging will not pick up from the output
#                     directory, on top of vaadin/quarkus#335
#
# The default app is the `maven-jar` shape: classic <packaging>jar</packaging>
# with <extensions>true</extensions> and generate-code bound, i.e. what
# base-starter-flow-quarkus ships - the shape where the archive root is a live
# directory. APPS selects which apps to package, for instance
#
#   APPS="app app-no-extensions" ./run.sh conditional
#
# to check both sides of the predicate: app-no-extensions drops
# <extensions>true</extensions>, which is the shape whose archive root is a
# sealed jar and which therefore still needs everything emitted.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
work="$here/.work"
src="$work/quarkus-3.2.1"
apps="${APPS:-app}"
reports="$here/results"
processor="$src/deployment/src/main/java/com/vaadin/quarkus/deployment/VaadinQuarkusProcessor.java"
plugin="$src/deployment/src/main/java/com/vaadin/quarkus/deployment/vaadinplugin/VaadinPlugin.java"

mkdir -p "$work" "$reports"

if [ ! -d "$src" ]; then
    echo "==> cloning vaadin/quarkus at 3.2.1"
    git clone -q --depth 1 --branch 3.2.1 https://github.com/vaadin/quarkus.git "$src"
    # 3.2.1 was released against the then-current Flow snapshot; pin it to the
    # Flow the app uses, or flow-plugin-base and flow-server disagree at runtime.
    perl -0pi -e 's{<vaadin\.flow\.version>[^<]+</vaadin\.flow\.version>}{<vaadin.flow.version>25.2.6</vaadin.flow.version>}' \
        "$src/pom.xml"
fi

reset_sources() {
    git -C "$src" checkout -q -- deployment/src
    perl -0pi -e 's{<vaadin\.flow\.version>[^<]+</vaadin\.flow\.version>}{<vaadin.flow.version>25.2.6</vaadin.flow.version>}' \
        "$src/pom.xml"
}

drop_emitter_call() {
    perl -0pi -e 's{        emitGeneratedFiles\(emitter\);}{        // emitGeneratedFiles(emitter); - removed by emitter-removal/run.sh}' \
        "$plugin"
}

drop_producer_parameter() {
    perl -0pi -e '
        s{            QuarkusBuildCloseablesBuildItem closeablesBuildItem,\n\n            // Parameter used only to make sure the build step gets executed\n            \@SuppressWarnings\("unused"\) BuildProducer<GeneratedResourceBuildItem> producer\)}{            QuarkusBuildCloseablesBuildItem closeablesBuildItem)};
        s{            BiConsumer<String, byte\[\]> emitter = \(path, content\) -> producer\n                    \.produce\(new GeneratedResourceBuildItem\(path, content\)\);}{            BiConsumer<String, byte[]> emitter = (path, content) -> \{\n            \};};
    ' "$processor"
}

add_produce_artifact() {
    perl -0pi -e '
        s{import io\.quarkus\.deployment\.pkg\.builditem\.CurateOutcomeBuildItem;}{import io.quarkus.deployment.pkg.builditem.ArtifactResultBuildItem;\nimport io.quarkus.deployment.pkg.builditem.CurateOutcomeBuildItem;};
        s{    \@BuildStep\(onlyIf = IsNormal\.class\)\n    void buildFrontendTask}{    \@BuildStep(onlyIf = IsNormal.class)\n    \@Produce(ArtifactResultBuildItem.class)\n    void buildFrontendTask};
    ' "$processor"
}

variants="${*:-baseline no-emitter no-producer produce-artifact conditional}"

for variant in $variants; do
    echo "==> $variant"
    reset_sources
    case "$variant" in
        no-emitter)       drop_emitter_call ;;
        no-producer)      drop_emitter_call; drop_producer_parameter ;;
        produce-artifact) drop_emitter_call; drop_producer_parameter; add_produce_artifact ;;
        conditional)      git -C "$src" apply "$here/patches/conditional.patch" ;;
    esac

    version="3.2.1-$variant"
    (cd "$src" \
        && mvn -q -B versions:set -DnewVersion="$version" -DgenerateBackupPoms=false \
        && mvn -q -B -N install -DskipTests -Dgpg.skip=true \
        && mvn -q -B -pl runtime,deployment install -DskipTests \
               -Dmaven.javadoc.skip=true -Dgpg.skip=true) \
        || { echo "    extension build failed"; continue; }

    for app_name in $apps; do
        app="$here/$app_name"
        report="$reports/$variant.txt"
        [ "$app_name" = app ] || report="$reports/$variant.$app_name.txt"

        log=$(mktemp)
        (cd "$app" && mvn -B clean package -DskipTests \
            -Dvaadin.quarkus.version="$version") >"$log" 2>&1
        status=$?

        {
            echo "variant: $variant"
            echo "app:     $app_name"
            echo "build:   $([ $status -eq 0 ] && echo SUCCESS || echo FAILURE)"
            echo
            echo "--- archives ---"
            "$here/../inspect.sh" "$app"
            if [ $status -ne 0 ]; then
                echo
                echo "--- build failure ---"
                grep -E '^\[ERROR\]' "$log" | head -5
            fi
        } >"$report"
        rm -f "$log"

        sed -n '1,3p' "$report" | tr '\n' ' '
        echo
    done
done

reset_sources
(cd "$src" && mvn -q -B versions:set -DnewVersion=3.2.1 -DgenerateBackupPoms=false)
echo
echo "reports written to $reports"
