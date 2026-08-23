---
name: dopamine-roothide-maintainer
description: Diagnose, modify, build, and device-validate the riboly/Dopamine3-RootHide fork, especially RootHide bootstrap, Sileo/Zebra, root-spawn, source persistence, safe removal, and iOS 18 regressions. Use for this fork's maintenance; do not use for generic iOS app development or app-specific jailbreak-detection bypasses.
---

# Dopamine RootHide Maintainer

Work from repository evidence and live-device observations. Read
[`docs/ROOTHIDE_DOPAMINE_MAINTENANCE.md`](../../docs/ROOTHIDE_DOPAMINE_MAINTENANCE.md)
before changing bootstrap paths, package-manager state, root-spawn, or removal
logic.

## Current Verified Baseline

- `3.0.29` is `DEVICE VERIFIED` on iPhone XS Max running iOS 18.2.1 as of 2026-08-22 for activation and trust-cache persistence. User-confirmed reboot-cycle tests no longer reproduce activation-time automatic reboot, abnormal two-to-three-minute black screens, or severe post-activation lag.
- After a full device reboot and another activation, previously registered third-party dynamic trust-cache entries are restored and apps injected by TrollFools and equivalent RootHide API clients launch normally.
- A later test ran normally for more than ten hours before one independent Sandbox `shenanigans!` panic occurred while the Dopamine GUI was starting. `3.0.30` removes that iOS 17+ GUI kerncred fallback and ports the applicable Dopamine 3.0.9 changes. Actions run `32615153841` and the downloaded artifact are verified, but the build is not device verified yet.
- Keep this result scoped to the tested device and OS. Other hardware and iOS versions still require independent device validation.
- A CDHash that never reached the persistent registry cannot be reconstructed from an App container. Seed that file once through its original tool before testing reboot persistence.

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
4. For a kernel panic, classify memory pressure separately from object-lifecycle corruption. Match panic `item/linkage/traits` against the exact XNU build before changing kernel writes.
5. For iOS 18 credential changes, treat `ucred_rw.crw_weak_ref` as a 32-bit `os_ref_atomic_t`. Never perform a raw weak `1 -> 0`; that transition requires `kauth_cred_retire()` and SMR hash removal.
6. Do not modify a live shared `ucred` hash key in place on iOS 17+. UID/GID/groups, saved IDs, audit data, and MAC labels must normally come from a fully constructed donor credential, published with balanced strong/weak references.
7. Never replace a GUI app with `kernproc`'s complete credential. During first activation, before launchdhook can create a donor, the narrow fallback is to pin only the app credential's mutable `ucred_rw` weak reference for the rest of that boot, verify the pointer is unchanged, then mutate only that pinned credential. Never release the weak pin or reuse this fallback for recurring daemon/service paths.
8. On iOS 17+, a jailbroken GUI process must use RootHide process-check-in sandbox extensions for bootstrap access. `runUnsandboxed` must never fall back to `jbclient_root_steal_ucred(0)` on these systems: Sandbox identifies the full kerncred and deliberately panics with `shenanigans!`. Move operations outside the granted RootHide paths into `jbctl` or another root helper.
9. Credential reference helpers that require an atomic mapped access must dispatch through `gPrimitives.physaccess_mapped`. Do not call the full-range `physrw_phystouaddr` mapping directly: A12 and other supported devices can use the single-page PTE window backend, and a direct `PPLRW_USER_MAPPING_OFFSET` access will SIGSEGV.
10. Audit every credential path, not only the one present in the panic stack: initial privilege elevation, get/drop root, setuid check-in, root credential borrowing, sandbox changes, and finalization can share the same corrupted hash lifecycle.
11. Treat launchd trust-cache requests as a critical section. On devices with initialized kcall, use `kalloc_data_external(size, Z_WAITOK)` for global trust-cache allocations; numeric flag `1` is `Z_NOWAIT` on XNU 11215 and can fail spuriously during activation. An IOSurface object whose ranges back a linked trust cache must never be destroyed. Never free a detached trust-cache page unless its allocator provenance is known; an in-place upgrade can contain both IOSurface-backed and data-heap pages. Deduplicate CDHashes under the mutation lock and propagate allocation or kernel I/O failures to the caller; never continue from a zero kernel address in PID 1.
12. Persist third-party dynamic trust at the shared `jb_trustcache_add_entries()` boundary. Store versioned, bounded, checksummed entries under the dynamically mapped RootHide writable root; use atomic replacement and restore in launchdhook after it recovers primitives. The boomerang completion message must not report success before restore completes, and must carry restore errors back to the activation UI without aborting launchd. During an in-place upgrade, import existing live `jb_trustcache` pages before completing launchd handoff. Do not scan ordinary App containers, depend on `_TrollStoreLite`, persist tool-specific paths, or include fixed basebin/dyld UUID trust caches.
13. Treat persistent trust as an explicit grant registry: old CDHashes remain until a successful explicit `trustcache clear`, and clear must update the kernel cache and persistent registry as one serialized operation. Never silently evict entries at the size limit or overwrite a malformed registry.
14. Make the smallest change that preserves user data and existing RootHide invariants.
15. Increment both `Application/Makefile` and `BaseBin/_external/basebin/.version` together.
16. Run `git diff --check`, inspect the complete diff, then build through `.github/workflows/roothide.yml`.
17. Verify the downloaded artifact digest, TIPA integrity, app/basebin versions, required Mach-O slices, and any new runtime marker before installation.
18. Validate on the device. For dynamic trust persistence, seed each pre-existing tool once after upgrading, record target CDHashes and the registry before reboot, then prove those hashes are restored before the tools or affected apps are launched after reboot. A CDHash absent from both the registry and live cache was never persisted and requires one successful tool registration before this test.
19. Update the maintenance document with the confirmed result, release artifact, commit, and remaining risks.

## Upstream Sync

- Find the exact common ancestor and review each upstream commit before applying it. Core RootHide files must be merged manually so an upstream context match cannot erase device-verified behavior.
- Port functional changes individually. An upstream commit that is already present or targets a feature intentionally disabled by RootHide may be skipped, but record why in the maintenance document.
- Do not copy upstream release numbers onto the RootHide fork. Advance the next RootHide version in both version files and document the upstream tag it includes.
- Re-run all RootHide regression checks after an upstream sync, especially activation credentials, launchd trust restore, respring, safe removal, package sources, and RootHide-only settings actions.

## Device Interpretation

An SSH process inside the active RootHide environment sees the hidden bootstrap
as `/`; `/var/jb` may intentionally be absent. The physical pair is rebranded
together under:

- `/var/containers/Bundle/Application/.jbroot-<brand>`
- `/var/mobile/Containers/Shared/AppGroup/.jbroot-<brand>`

Do not infer data loss from the absence of `/var/jb`. Resolve the active brand
and inspect the virtual `/etc/apt` and `/var/mobile` views instead.

## Service And Respring Triage

- Read package `postinst` before treating red launchctl output as an install failure. An explicit `exit 0` plus `dpkg-query` state and installed files can prove installation succeeded while service reload failed.
- On iOS 18, inspect `launchctl print user/foreground/<label>` as well as `system/<label>`. Do not add a global domain rewrite for one third-party package.
- A respring that looks like a phone reboot without a kernel panic can be Dopamine converting a watchdog userspace panic into `RB2_USERREBOOT`. Inspect `watchdoghook`, the caller's `sbreload` implementation, and any saved userspace-panic state.
- When enumerating `KERN_PROCARGS2`, allocate the argument buffer using the same `KERN_ARGMAX` value passed as the sysctl output size. Process-list byte length is not a safe substitute.
- Never trigger respring, service termination, userspace reboot, or phone reboot merely to reproduce a report. Obtain explicit authorization for that action.

## Completion Criteria

Do not call a device-facing fix complete from a successful build alone. Require
the relevant live behavior to pass, and state explicitly when installation or
a reboot-cycle test remains pending.
