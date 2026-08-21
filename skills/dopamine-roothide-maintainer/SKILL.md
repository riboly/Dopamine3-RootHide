---
name: dopamine-roothide-maintainer
description: Diagnose, modify, build, and device-validate the riboly/Dopamine3-RootHide fork, especially RootHide bootstrap, Sileo/Zebra, root-spawn, source persistence, safe removal, and iOS 18 regressions. Use for this fork's maintenance; do not use for generic iOS app development or app-specific jailbreak-detection bypasses.
---

# Dopamine RootHide Maintainer

Work from repository evidence and live-device observations. Read
[`docs/ROOTHIDE_DOPAMINE_MAINTENANCE.md`](../../docs/ROOTHIDE_DOPAMINE_MAINTENANCE.md)
before changing bootstrap paths, package-manager state, root-spawn, or removal
logic.

## Safety Boundaries

- Treat device filesystem deletion, reboot, userspace reboot, and system-service termination as separate destructive actions. Do not perform them without explicit authorization for that action.
- Never delete a path merely because its name resembles a jailbreak root. Validate its type, marker, parent directory, and paired RootHide path first; abort on ambiguity.
- Preserve user-added package sources. Dopamine owns only the managed source files listed in the maintenance document.
- Do not overwrite Zebra's `sources.list` after its first creation.
- Preserve unrelated worktree changes and the repository's untracked `$d/` directory.
- In Chinese user-facing text for this project, use “月余” consistently.

## Workflow

1. Capture the exact device state and reproduce the narrow failure with read-only commands.
2. Identify the shared subsystem before patching individual apps. Sileo and Zebra failures can both originate in RootHide path translation, root-spawn, permissions, or bootstrap re-randomization.
3. Compare device paths with `DOBootstrapper.m`, `DOEnvironmentManager.m`, `libjailbreak`, `launchdhook`, and `systemhook` ownership boundaries.
4. Make the smallest change that preserves user data and existing RootHide invariants.
5. Increment both `Application/Makefile` and `BaseBin/_external/basebin/.version` together.
6. Run `git diff --check`, inspect the complete diff, then build through `.github/workflows/roothide.yml`.
7. Verify the downloaded artifact digest, TIPA integrity, app/basebin versions, required Mach-O slices, and any new runtime marker before installation.
8. Validate on the device. For persistence fixes, capture source file names and checksums before reboot, then compare them after reboot and reactivation.
9. Update the maintenance document with the confirmed result, release artifact, commit, and remaining risks.

## Device Interpretation

An SSH process inside the active RootHide environment sees the hidden bootstrap
as `/`; `/var/jb` may intentionally be absent. The physical pair is rebranded
together under:

- `/var/containers/Bundle/Application/.jbroot-<brand>`
- `/var/mobile/Containers/Shared/AppGroup/.jbroot-<brand>`

Do not infer data loss from the absence of `/var/jb`. Resolve the active brand
and inspect the virtual `/etc/apt` and `/var/mobile` views instead.

## Completion Criteria

Do not call a device-facing fix complete from a successful build alone. Require
the relevant live behavior to pass, and state explicitly when installation or
a reboot-cycle test remains pending.
