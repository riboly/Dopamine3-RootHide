# RootHide on Dopamine 3

RootHide on Dopamine 3 ports the RootHide jailbreak environment to the
Dopamine 3 codebase. It keeps Dopamine's device and exploit support while
providing RootHide's randomized jailbreak root and package environment.

Maintenance notes and device-safe validation procedures are in
[`docs/ROOTHIDE_DOPAMINE_MAINTENANCE.md`](docs/ROOTHIDE_DOPAMINE_MAINTENANCE.md).
The repository-local Codex workflow is in
[`skills/dopamine-roothide-maintainer/SKILL.md`](skills/dopamine-roothide-maintainer/SKILL.md).

This project is experimental. Back up important data before testing, and
remove incompatible tweaks if SpringBoard enters a respring loop.

## Downloads and changelog

Download signed builds and read the changelog on the
[GitHub Releases](https://github.com/riboly/Dopamine3-RootHide/releases) page. The
in-app update screen reads release notes from the same location.

## Target configuration

- iPhone XS Max (iPhone11,6, A12)
- iOS 18.2.1 (22C161)
- Dopamine 3.0.7 base

The RootHide behavior carried by this branch has a device-verified historical
baseline, but builds from this repository remain unverified until each commit
has completed a fresh device test. A successful GitHub Actions build only
establishes that the source compiles and packages correctly.

## Community

- Telegram: https://t.me/+WtnN67BeOsA1MGM5
- RootHide developer documentation: https://github.com/roothide/Developer

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
