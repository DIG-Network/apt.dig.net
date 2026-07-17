# Changelog

All notable changes to this project are documented here.
This project adheres to [Semantic Versioning](https://semver.org) and
[Conventional Commits](https://www.conventionalcommits.org).

## [0.4.0] - 2026-07-16

### Features
- **packaging:** Cut over the store CLI package to the renamed `dig-store` binary +
  asset name (repo `DIG-Network/digstore` → `DIG-Network/dig-store`, binary `digstore`
  → `dig-store`). The `.deb` is now `dig-store` (`/usr/bin/dig-store`), keeps the `digs`
  alias, and ships a transitional `/usr/bin/digstore` → `dig-store` compat symlink so
  existing scripts keep working during the rename (#704, epic #703).

## [0.3.2] - 2026-07-13

### Chores
- Fix dig-node port from 8080 to 9778 (#4)

## [0.3.1] - 2026-07-12

### Bug Fixes
- Correct Discord invite (imposter link -> official) (#3)

## [0.3.0] - 2026-07-12

### Features
- **packaging:** Ship the digs alias binary in the digstore .deb (#2)

## [0.2.0] - 2026-07-10

### Features
- **frontend-baseline:** Embed bug-report widget + expose build version (#1)

## [0.1.0] - 2026-07-04

### Build
- Add package.json version for tag-driven release pipeline (#230)

### CI
- Enforce version increment in PRs (package.json / Cargo.toml)- Enforce Conventional Commits with commitlint on PRs- Enforce Conventional Commits with commitlint on PRs- Release automation — git-cliff changelog + tag on merge, deploy on tag (#230 Unit 2)

### Chores
- **changelog:** Add git-cliff config for Conventional-Commit changelog


