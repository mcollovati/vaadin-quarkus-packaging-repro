package org.acme.probe.deployment;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Collection;

import io.quarkus.bootstrap.workspace.ArtifactSources;
import io.quarkus.bootstrap.workspace.SourceDir;
import io.quarkus.bootstrap.workspace.WorkspaceModule;
import io.quarkus.deployment.IsNormal;
import io.quarkus.deployment.annotations.BuildProducer;
import io.quarkus.deployment.annotations.BuildStep;
import io.quarkus.deployment.builditem.ArchiveRootBuildItem;
import io.quarkus.deployment.builditem.GeneratedResourceBuildItem;
import io.quarkus.deployment.pkg.PackageConfig;
import io.quarkus.deployment.pkg.builditem.CurateOutcomeBuildItem;
import io.quarkus.deployment.pkg.builditem.OutputTargetBuildItem;

/**
 * Reproduces, without Vaadin, the two things
 * {@code VaadinQuarkusProcessor.buildFrontendTask} does with the build output:
 * it writes a file into the resources output directory late in augmentation,
 * and it emits a second file as a {@link GeneratedResourceBuildItem}.
 * <p>
 * Whether each of those files turns up in the packaged application answers, per
 * packaging case, whether the emitter is load-bearing or redundant. Every line
 * it prints is prefixed {@code PROBE|} so it can be grepped out of both Maven
 * and Gradle output.
 */
public class PackagingProbeProcessor {

    /**
     * Written straight into the resources output directory, the way the Vaadin
     * build writes its bundle into {@code META-INF/VAADIN}. It reaches the
     * package only if the build tool had not already sealed that directory into
     * an archive.
     */
    private static final String LATE_FILE = "META-INF/PROBE/late.txt";

    /**
     * Emitted as a build item, the way {@code emitGeneratedFiles} emits the
     * Vaadin bundle. It always reaches the package.
     */
    private static final String EMITTED_FILE = "META-INF/PROBE/emitted.txt";

    @BuildStep(onlyIf = IsNormal.class)
    void probe(ArchiveRootBuildItem archiveRoot, PackageConfig packageConfig,
            CurateOutcomeBuildItem curateOutcome,
            OutputTargetBuildItem outputTarget,
            BuildProducer<GeneratedResourceBuildItem> producer) {

        log("jarType", packageConfig.jar().type());
        log("jarTypeUsesFastJarLayout",
                packageConfig.jar().type().usesFastJarLayout());
        log("outputTargetDirectory", outputTarget.getOutputDirectory());
        log("appArtifactPaths",
                curateOutcome.getApplicationModel().getAppArtifact()
                        .getResolvedPaths());

        for (Path path : archiveRoot.getResolvedPaths()) {
            log("archiveRootResolvedPath",
                    path + " isDirectory=" + Files.isDirectory(path));
        }
        for (Path dir : archiveRoot.getRootDirectories()) {
            log("archiveRootDirectory", dir + " fileSystem="
                    + dir.getFileSystem().getClass().getSimpleName());
        }

        Path resourcesOutputDir = resourcesOutputDirectory(curateOutcome,
                outputTarget);
        log("resourcesOutputDirectory", resourcesOutputDir);

        // The predicate proposed for vaadin/quarkus#337. Path.startsWith is
        // false across FileSystems, so a mounted ZipFS root never matches -
        // which is exactly the case where the build tool sealed the archive
        // before this build step ran.
        boolean rootArchiveIncludesOutput = resourcesOutputDir != null
                && archiveRoot.getRootDirectories().stream()
                        .anyMatch(resourcesOutputDir::startsWith);
        log("predicateRootArchiveIncludesOutput", rootArchiveIncludesOutput);

        producer.produce(new GeneratedResourceBuildItem(EMITTED_FILE,
                ("emitted as a GeneratedResourceBuildItem" + System.lineSeparator())
                        .getBytes(StandardCharsets.UTF_8)));
        log("emittedFile", EMITTED_FILE);

        writeLateFile(resourcesOutputDir);
    }

    /**
     * Mirrors {@code QuarkusPluginAdapter.resolveBuildDirectory}, which
     * resolves the Vaadin output against the main resources output directory -
     * {@code target/classes} under Maven, {@code build/resources/main} under
     * Gradle.
     */
    private static Path resourcesOutputDirectory(
            CurateOutcomeBuildItem curateOutcome,
            OutputTargetBuildItem outputTarget) {
        WorkspaceModule module = curateOutcome.getApplicationModel()
                .getApplicationModule();
        if (module == null) {
            log("workspaceModule", "<absent, falling back to output target>");
            return outputTarget.getOutputDirectory().resolve("classes");
        }
        log("workspaceModuleBuildDir", module.getBuildDir());
        if (module.hasMainSources()) {
            ArtifactSources mainSources = module.getMainSources();
            for (SourceDir sourceDir : mainSources.getSourceDirs()) {
                log("mainSourcesOutputDir", sourceDir.getOutputDir());
            }
            Collection<SourceDir> resourceDirs = mainSources.getResourceDirs();
            if (!resourceDirs.isEmpty()) {
                return resourceDirs.iterator().next().getOutputDir();
            }
        }
        return module.getBuildDir().toPath().resolve("classes");
    }

    private static void writeLateFile(Path resourcesOutputDir) {
        if (resourcesOutputDir == null) {
            log("lateFile", "<skipped, no resources output directory>");
            return;
        }
        Path target = resourcesOutputDir.resolve(LATE_FILE);
        try {
            Files.createDirectories(target.getParent());
            Files.writeString(target,
                    "written into the output directory during augmentation"
                            + System.lineSeparator());
        } catch (IOException e) {
            throw new UncheckedIOException(
                    "Failed to write the probe file to " + target, e);
        }
        log("lateFile", target);
    }

    private static void log(String key, Object value) {
        System.out.println("PROBE|" + key + "=" + value);
    }
}
