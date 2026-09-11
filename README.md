# Vaadin + Quarkus packaging reproducer

Why the Vaadin production bundle ends up in a Quarkus application twice in some
builds, and once — from one source only — in others.

Filed as [vaadin/quarkus#337](https://github.com/vaadin/quarkus/issues/337).

## The question

`VaadinQuarkusProcessor.buildFrontendTask` does two things with the frontend
bundle. It lets the Vaadin build write it into the build output directory, under
`META-INF/VAADIN`, and then it emits every one of those files again as a
`GeneratedResourceBuildItem`. Where Quarkus also packages the output directory,
the second step is redundant and the bundle is packaged twice.

So: can the emitter be dropped? Only if nothing depends on it. That is what this
repository measures.

## What decides it

Not the jar type, and not the build tool. Every Quarkus jar builder packages the
application through the same call — `copyFiles(applicationArchives.getRootArchive(), …)`
in `AbstractJarBuilder` and `AbstractFastJarBuilder` — so what matters is what
the *root archive* is:

- a **live directory** (`target/classes`, or Gradle's `build/classes/java/main`
  and `build/resources/main`): walked at packaging time, so it picks up whatever
  the Vaadin build wrote into it, and the emitter adds nothing;
- a **sealed archive**: its content was fixed before augmentation started, so the
  emitter is the only thing that delivers the bundle.

Which one you get is decided before any Quarkus build step runs, by when the
build tool resolved the application model relative to when it built the jar.
Under Maven that is a consequence of two things that have nothing to do with
packaging type:

- `<extensions>true</extensions>` on `quarkus-maven-plugin` keeps the
  session-scoped bootstrap provider open across goals. Without it,
  `QuarkusBootstrapMojo.execute` closes the provider after every goal, so `build`
  re-bootstraps — and by then `maven-jar-plugin` has run and
  `project.getArtifact().getFile()` is a jar.
- an early goal has to have bootstrapped the model in the first place. With only
  the `build` goal bound, the first bootstrap happens after `maven-jar-plugin`,
  and the root is the jar again.

## Cases

One folder per project shape. The jar type is a plain Quarkus property, so it is
varied by `run-all.sh` rather than by duplicating projects.

| folder | based on | shape |
|---|---|---|
| `maven-quarkus` | starter branch `investigation/quarkus-packaging` | `<packaging>quarkus</packaging>`, no `maven-jar-plugin` at all |
| `maven-jar` | starter branch `v25` | classic `<packaging>jar</packaging>`, `<extensions>true</extensions>`, `generate-code` bound — **what the official starter ships** |
| `maven-jar-no-extensions` | `maven-jar` minus `<extensions>true</extensions>` | isolates the Maven extension |
| `maven-jar-no-generate-code` | `maven-jar` with only the `build` goal | isolates the early bootstrap |
| `gradle` | starter branch `gradle-v25` | Gradle, `quarkusBuild` |

All five run Vaadin 25.2.6 and Quarkus 3.33.0, off identical sources, so the only
variables are the ones above. (Quarkus 3.33.0 rather than the starter's 3.32.0:
`vaadin-quarkus-deployment` 3.2.1 pulls the Quarkus deployment artifacts at
3.33.0, and under Gradle's highest-version resolution mixing the two produces a
`NoSuchMethodError` in `JarResultBuildStep`.)

## The probe

`probe-extension/` is a small Quarkus extension the five projects depend on. Its
single build step mirrors, without Vaadin, what `buildFrontendTask` does:

- it writes `META-INF/PROBE/late.txt` into the resources output directory, the
  way the Vaadin build writes its bundle;
- it emits `META-INF/PROBE/emitted.txt` as a `GeneratedResourceBuildItem`, the
  way `emitGeneratedFiles` emits that bundle;
- it prints the jar type, the archive root and its file system, and the verdict
  of the predicate proposed for #337.

Which of the two files reaches the packaged application then answers, per cell,
whether the emitter is required — and the `META-INF/VAADIN` counts show the
same thing for the real Vaadin bundle.

## Running it

```bash
./run-all.sh                 # every case against every jar type
./run-all.sh maven-jar       # or just some of them
./summarize.sh               # condense results/ into one table
```

`run-all.sh` installs the probe extension into the local Maven repository first.
Reports land in `results/`, one per cell, holding the probe output and a count of
the three markers in every archive the build produced. The native cells use
`quarkus.native.sources-only`, which reaches `NativeImageSourceJarBuilder`
without needing GraalVM, together with `quarkus.package.jar.enabled=false`,
without which the Gradle plugin refuses to emit a native and a JAR package in the
same build.

## Results

| case | jar type | build | archive root | predicate | emitter |
|---|---|---|---|---|---|
| gradle | fast-jar | SUCCESS | directory | true | redundant |
| gradle | legacy-jar | SUCCESS | directory | true | redundant |
| gradle | mutable-jar | SUCCESS | directory | true | redundant |
| gradle | native-sources | SUCCESS | directory | true | redundant |
| gradle | uber-jar | SUCCESS | directory | true | redundant |
| maven-jar | fast-jar | SUCCESS | directory | true | redundant |
| maven-jar | legacy-jar | SUCCESS | directory | true | redundant |
| maven-jar | mutable-jar | SUCCESS | directory | true | redundant |
| maven-jar | native-sources | SUCCESS | directory | true | redundant |
| maven-jar | uber-jar | SUCCESS | directory | true | redundant |
| maven-jar-no-extensions | fast-jar | SUCCESS | archive | false | required |
| maven-jar-no-extensions | legacy-jar | SUCCESS | archive | false | required |
| maven-jar-no-extensions | mutable-jar | SUCCESS | archive | false | required |
| maven-jar-no-extensions | native-sources | SUCCESS | archive | false | required |
| maven-jar-no-extensions | uber-jar | SUCCESS | archive | false | required |
| maven-jar-no-generate-code | fast-jar | FAILURE | archive | false | - |
| maven-jar-no-generate-code | legacy-jar | FAILURE | archive | false | - |
| maven-jar-no-generate-code | mutable-jar | FAILURE | archive | false | - |
| maven-jar-no-generate-code | native-sources | FAILURE | archive | false | - |
| maven-jar-no-generate-code | uber-jar | FAILURE | archive | false | - |
| maven-quarkus | fast-jar | SUCCESS | directory | true | redundant |
| maven-quarkus | legacy-jar | SUCCESS | directory | true | redundant |
| maven-quarkus | mutable-jar | SUCCESS | directory | true | redundant |
| maven-quarkus | native-sources | SUCCESS | directory | true | redundant |
| maven-quarkus | uber-jar | SUCCESS | directory | true | redundant |

"emitter: redundant" means an archive carried the bundle without the emitter
having put it there. "required" means the emitted copy was the only one.

The predicate agrees with the outcome in every cell, including the five where
the build fails before packaging.

## Removing the emitter for real

The table above infers "redundant" from a probe marker. `emitter-removal/`
settles it by actually removing the emitter: it builds five variants of the
extension at tag 3.2.1 and packages the same `maven-jar`-shaped application with
each.

```bash
./emitter-removal/run.sh                          # clones vaadin/quarkus at 3.2.1 into .work/
APPS="app app-no-extensions" ./emitter-removal/run.sh conditional
```

| variant | what changed | `app/<artifact>.jar` | verdict |
|---|---|---|---|
| `baseline` | nothing | 197 | bundle present, and duplicated in `generated-bytecode.jar` |
| `no-emitter` | the `emitGeneratedFiles(emitter)` call removed, the `BuildProducer<GeneratedResourceBuildItem>` parameter kept | **197** | bundle present, duplication gone |
| `no-producer` | the call *and* the parameter removed | — | **build fails**: "does not produce any build item and thus will never get executed" |
| `produce-artifact` | as `no-producer`, plus `@Produce(ArtifactResultBuildItem.class)` to keep the step alive | **3** | **bundle missing** - only `flow-build-info.json`, written earlier by `prepareFrontend`, made it in |
| `conditional` | `patches/conditional.patch` — the proposed fix, on top of #335 | **196** + 1 | one copy of everything, token included |

### The `conditional` variant

`patches/conditional.patch` is the fix as it would be written, applied on top of
vaadin/quarkus#335 (which deletes the token file from the build output directory
once the frontend build is done). It builds the emitter from the archive root:

```java
boolean packagedFromDirectory = archiveRoot.getRootDirectories().stream()
        .anyMatch(generatedResourcesDirectory::startsWith);
if (!packagedFromDirectory) {
    return (path, content) -> producer
            .produce(new GeneratedResourceBuildItem(path, content));
}
return (path, content) -> {
    if (path.endsWith("/" + FrontendUtils.TOKEN_FILE)) {
        producer.produce(new GeneratedResourceBuildItem(path, content));
    }
};
```

The token has to be emitted either way: #335 deletes it from the output
directory, so packaging cannot pick it up from there any more. Emitting nothing
at all would ship an application with no `flow-build-info.json`, which is a worse
failure than the duplication. The rule is therefore *emit exactly what packaging
will not pick up from the output directory*.

Measured on both sides of the predicate:

| app shape | archive root | `app/<artifact>.jar` | `generated-bytecode.jar` |
|---|---|---|---|
| `app` (`<extensions>true</extensions>`) | directory | 196 — the bundle | 3 — the token and its two directory entries |
| `app-no-extensions` | sealed jar | 0 | 197 — everything |

One copy of every file in both, with the token present exactly once. The
duplication is gone, the sealed-archive shape is unaffected, and #332's "first
match of '2' possible" warning goes away as a side effect, since there is no
longer a second `flow-build-info.json` to disagree with.


So the emitter really is redundant as a *source of files* in this shape. But the
`BuildProducer<GeneratedResourceBuildItem>` parameter is not redundant at all:
producing that item is what puts `buildFrontendTask` before `JarResultBuildStep`
in the build graph, because the jar step consumes
`List<GeneratedResourceBuildItem>`. Nothing has to actually be produced -
declaring the parameter is enough.

Take the parameter away and there are two outcomes, neither good. On Quarkus 3.33
the build fails outright. Replace it with `@Produce(ArtifactResultBuildItem.class)`
- which is exactly what that error message suggests - and the step runs
*unordered against packaging*: the jar is assembled while the Vaadin build is
still working, and the application ships without its bundle. The comment on the
parameter today says it is there "to make sure the build step gets executed",
which undersells it; it is there to make sure the step is executed **before the
application is packaged**.

## What this shows

**1. The duplication is not specific to `quarkus` packaging.** The official
starter — classic `jar` packaging with the Maven extension enabled — duplicates
the bundle exactly like the `quarkus`-packaged project. Under `uber-jar` the two
copies land in the *same* archive as duplicate zip entries: 387 `META-INF/VAADIN`
entries against 197 in the same build without the emitter.

**2. The emitter cannot simply be removed, but it can be made conditional.**
`maven-jar-no-extensions` depends on it entirely - nothing else puts the bundle
into that application - and `maven-jar-no-generate-code` would too, if its build
got as far as packaging. In both the Maven artifact itself never receives the
bundle either. The archive root is what the condition has to read:

```java
boolean rootArchiveIncludesOutput = archiveRoot.getRootDirectories().stream()
        .anyMatch(generatedDir::startsWith);
```

`ArchiveRootBuildItem` is an initial build item, so injecting it constrains
nothing, and `Path.startsWith` is false across file systems - which is exactly
the sealed-archive case. This reading works the same under Maven and
Gradle, and handles Gradle's two root directories without a special case.

Two constraints on that fix, both measured in **Removing the emitter for real**
above: the `BuildProducer<GeneratedResourceBuildItem>` parameter has to stay,
because it is the build-graph edge that puts the Vaadin build before packaging;
and the build info token has to be emitted on both branches, because #335 deletes
it from the output directory. `emitter-removal/patches/conditional.patch` is that
fix, and it measures clean on both sides of the predicate.

**3. A missing `generate-code` goal is a separate bug.** With only the `build`
goal bound, `VaadinPlugin.of` falls back to `WorkspaceInfo.load`, which returns
`null` because the workspace file is written by `WorkspaceInfoCollector` — a
`CodeGenProvider`, so it only runs during `generate-code`. The null then reaches
`QuarkusPluginAdapter`'s constructor:

```
java.lang.NullPointerException: Cannot invoke
"io.quarkus.bootstrap.workspace.WorkspaceModule.getModuleDir()" because "appModule" is null
    at com.vaadin.quarkus.deployment.vaadinplugin.QuarkusPluginAdapter.<init>(QuarkusPluginAdapter.java:94)
```

`VaadinPlugin.of` already has a `BuildException` for this, with a message about
`quarkus.bootstrap.workspace-discovery`; it just never fires, because the
fallback returns `null` instead of throwing.

## Related

- [vaadin/quarkus#337](https://github.com/vaadin/quarkus/issues/337) — the
  duplication
- [vaadin/quarkus#332](https://github.com/vaadin/quarkus/issues/332) — the
  production token file left in `target/classes`
- [vaadin/quarkus#335](https://github.com/vaadin/quarkus/pull/335) — the fix for
  #332, which deletes the token file only
