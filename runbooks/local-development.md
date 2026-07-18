# Runbook — local development

How to build, test, and lint apt.dig.net on a developer machine.

## Prerequisites

A Linux host (or WSL) with:

- `dpkg-dev` (provides `dpkg-deb`) — build the `.deb` packages,
- `apt-utils` (provides `apt-ftparchive`) — generate the repo metadata,
- `gnupg` — sign + verify the repository.

`make test` self-skips any leg whose tooling is absent, so the shell suite runs on a
bare host; CI provides the full Debian toolchain for the real-build legs.

## Commands

```bash
make test          # run the test suite (self-skips legs whose tooling is absent)
make lint          # shellcheck + actionlint + terraform fmt/validate (each optional)
make debs          # download upstream assets + build every available .deb into dist/pool/main
make repo GPG_FPR=<fingerprint>   # assemble + sign the repo into dist/ (omit GPG_FPR for unsigned)
```

## Test suite

The shell suite lives under `tests/` and shares one assertion vocabulary
(`tests/lib/assert.sh` — `check`/`contains`/`not_contains`/`file_exists` +
`assert_summary`). `tests/run.sh` runs every test and then the accessibility gate.

- `tests/test_version_resolution.sh` — version/tag normalisation + asset-name resolution
  (pure logic; runs anywhere).
- `tests/test_dig_node_port.sh` — the dig-node port drift guard: every reference matches
  the canonical `PKG_dig_node_PORT` (9778) declared in `config.sh`, and `8080` appears as
  a node port nowhere.
- `tests/test_deb_layout.sh` — `DEBIAN/control` rendering + a real `dpkg-deb` build of a
  service package, asserting the binary lands on PATH, the unit ships + enables, and the
  maintainer scripts are present.
- `tests/test_repo_metadata.sh` — a real `apt-ftparchive` pool scan + `Release`
  generation + GPG **sign and verify** round-trip (proves `InRelease`/`Release.gpg`
  verify against the published `dig.gpg`).
- `tests/test_site_baseline.sh` — the frontend-baseline contract (llms.txt / a11y / SEO)
  for the `site/` assets.
- `tests/test_version_injection.sh` — the build-version placeholder injection (§6.7).
- `tests/a11y/` — the WCAG 2.2 AA axe-core + Playwright accessibility gate (needs
  `cd tests/a11y && npm ci && npx playwright install chromium`).
