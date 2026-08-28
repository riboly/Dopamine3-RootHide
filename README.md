# RootHide on Dopamine 3

RootHide on Dopamine 3 ports the RootHide jailbreak environment to the
Dopamine 3 codebase. It keeps Dopamine's device and exploit support while
providing RootHide's randomized jailbreak root and package environment.

Maintenance notes and device-safe validation procedures are in
[`docs/ROOTHIDE_DOPAMINE_MAINTENANCE.md`](docs/ROOTHIDE_DOPAMINE_MAINTENANCE.md).
The repository-local Codex workflow is in
[`skills/dopamine-roothide-maintainer/SKILL.md`](skills/dopamine-roothide-maintainer/SKILL.md).

## AI maintenance handoff

The repository copies are the portable source of truth. A new computer, AI
coding agent, or session must not depend on an earlier local skill install,
conversation, or memory export. Start the agent at the repository root on the
`roothide-3.x` branch and give it this instruction:

```text
Before working on Dopamine3-RootHide, read
skills/dopamine-roothide-maintainer/SKILL.md completely, then read
docs/ROOTHIDE_DOPAMINE_MAINTENANCE.md completely. Follow their safety
boundaries and verified baselines. Treat the repository copies as
authoritative and update them when a device result changes.
```

If the agent supports installable skills, the repository-local skill may be
installed or linked into that agent's skill directory, but the checked-in
[`SKILL.md`](skills/dopamine-roothide-maintainer/SKILL.md) remains canonical.
Before editing, the agent must inspect the worktree, preserve unrelated user
changes and the untracked `$d/` directory, and obtain explicit authorization
before rebooting, performing a userspace reboot or respring, terminating a
system service, or deleting device files.

This project is experimental. Back up important data before testing, and
remove incompatible tweaks if SpringBoard enters a respring loop.

## Downloads and changelog

Download signed builds and read the changelog on the
[GitHub Releases](https://github.com/riboly/Dopamine3-RootHide/releases) page. The
in-app update screen reads release notes from the same location.

## Target configuration

- iPhone XS Max (iPhone11,6, A12)
- iOS 18.2.1 (22C161)
- Dopamine 3.0.9 applicable upstream update set

Version 3.0.30 is `DEVICE VERIFIED` on this target: activation, third-party
dynamic trust-cache restoration, injected apps, and the Dopamine GUI all work
normally, with no automatic reboot during the reported test window. Version
3.0.31 materially reduced active-use heat and UI jank, but device testing found
a NetworkExtension regression: a newly spawned `/usr/libexec/neagent` received
RootHide/TweakLoader injection and repeatedly aborted in `libroothide` before a
VPN provider could start, leaving on-demand VPN stuck connecting and making
Wi-Fi appear offline. Version 3.0.32 excludes only that complete Apple system
path on iOS 18. Its Frida settings action uses the 3.0.31 behavior again and
downloads the RootHide arm64e 17.17.0 DEB when installation is requested;
there is no bundled Frida package. Version 3.0.33 packages this current source
and makes manual workflow runs default to a full TIPA build. It is the current
device-verified stable baseline; the later `thermalmonitord` userspace panic was
traced to an incompatible CPU/thermal tweak rather than a 3.0.33 core failure.
Version 3.0.34 protects the complete Apple path `/usr/libexec/thermalmonitord`
from RootHide/tweak injection and adds a bounded watchdog quarantine for a
small reviewed set of dedicated Apple services. Quarantine rules can be
inspected with `jbctl stability quarantine list` and cleared as root with
`jbctl stability quarantine clear`; clearing does not remove fixed safety
exclusions. Manual Actions run `32981228809` produced
`roothide-Dopamine-3.0.33-ed8387a.tipa`. Actions run
`32921982914` and artifact
`roothide-Dopamine-3.0.32-a2619ac.tipa` are `BUILD VERIFIED`. On 2026-08-26,
the target device completed activation and successfully connected multiple VPN
tools, confirming the `neagent`/NetworkExtension fix. That artifact predates
the Frida-only installer reversion. A successful GitHub Actions build only
establishes that the source compiles and packages correctly.



## Building

See [BUILD.md](BUILD.md) for GitHub Actions instructions. The workflow used by
this repository is available at [.github/workflows/roothide.yml](.github/workflows/roothide.yml).

The `3.x` branch tracks opa334's upstream. RootHide releases are developed on
`roothide-3.x`: update `3.x` from upstream first, then rebase or replay the
RootHide-only commits and rerun both focused and full Actions builds.

## Credits

- Dopamine: https://github.com/opa334/Dopamine
- RootHide: https://github.com/roothide
- Dopamine2-roothide: https://github.com/roothide/Dopamine2-roothide

This repository retains the licenses and attribution of its upstream
components.
