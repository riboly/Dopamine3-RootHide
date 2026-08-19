# GitHub Actions build

The RootHide workflow is `.github/workflows/roothide.yml`.

1. Open the repository's **Actions** tab.
2. Select **Build roothide Dopamine**.
3. Choose **Run workflow** on the `roothide-3.x` branch.
4. Select `focused` to compile only `systemhook.dylib`, or `full` to build the
   installable TIPA.
5. Download the artifact after the job finishes. GitHub wraps artifacts in a
   ZIP; the full-build ZIP contains `roothide-Dopamine-<version>-<commit>.tipa`.

The workflow checks out submodules, applies the versioned RootHide patches,
uses Xcode 15.4 and the RootHide Theos toolchain, and builds without requiring
a local Mac.

A green full build verifies compilation and packaging only. Record the commit,
workflow run URL, artifact SHA-256, and a separate device-test result before
calling a release stable.
