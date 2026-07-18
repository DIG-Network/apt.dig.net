# apt.dig.net

The DIG Network **APT repository** + its AWS infrastructure. Ubuntu/Debian users
install the DIG ecosystem with `apt` — `dig-node` (the node service, run via systemd)
and `dig-store` (the content-addressable store CLI) — from a flat, GPG-signed apt
repository served at **https://apt.dig.net**.

---

## For users — install the DIG ecosystem

```bash
# 1. Trust the DIG signing key
curl -fsSL https://apt.dig.net/dig.gpg | sudo gpg --dearmor -o /usr/share/keyrings/dig.gpg

# 2. Add the apt source (signed-by pins it to the DIG key)
echo "deb [signed-by=/usr/share/keyrings/dig.gpg] https://apt.dig.net stable main" \
  | sudo tee /etc/apt/sources.list.d/dig.list

# 3. Install
sudo apt update
sudo apt install dig-node dig-store

# 4. The node runs as a systemd service
systemctl status dig-node
```

### What you get

| Package    | Installs                                   | Service |
| ---------- | ------------------------------------------ | ------- |
| `dig-node` | `/usr/bin/dig-node` + `dig-node.service`   | yes — `systemctl enable --now dig-node` (loopback `127.0.0.1:9778`, runs as the `dig-node` system account, cache at `/var/lib/dig-node`) |
| `dig-store` | `/usr/bin/dig-store` + `/usr/bin/digs` (+ `/usr/bin/digstore` compat symlink) | no — just the CLI on `PATH` |

`digs` is a first-class alias binary for `dig-store` — `digs <args>` behaves identically
to `dig-store <args>`. It ships in the same upstream release tarball as `dig-store` and
is installed alongside it (see `PKG_dig_store_EXTRA_BINS` in `config.sh`).

The store CLI's repo/binary was renamed `digstore` → `dig-store` (#703). A transitional
`/usr/bin/digstore` → `dig-store` symlink ships in the `.deb`
(`PKG_dig_store_COMPAT_SYMLINKS`) so existing `digstore …` scripts keep working during
the rename.

Configure the node with `systemctl edit dig-node` (env: `DIG_NODE_HOST`,
`DIG_NODE_PORT`, `DIG_RPC_UPSTREAM`). `DIG_NODE_HOST` / `DIG_NODE_PORT` are the
dig-node binary's stable env-var names — the unit's `Environment=` lines match them.
See the docs: <https://docs.dig.net/docs/run-a-node>.

### Machine-readable

| Path | What |
| ---- | ---- |
| [`/llms.txt`](site/llms.txt) | Agent entry point (site map + install contract) |
| [`/sitemap.xml`](site/sitemap.xml) | XML sitemap (one public page) |
| [`/robots.txt`](site/robots.txt) | Crawl policy — full indexing allowed, points at `sitemap.xml` |
| `/feed.xml` | Atom feed listing the currently published packages (generated at build time by `generate_feed()` in `packaging/repo/generate-repo.sh`) |
| `/dig.gpg` | The signing public key |
| `/dists/stable/Release` | Repo metadata |

---

## Architecture

```
upstream GitHub releases                this repo (CI)                     AWS
─────────────────────────               ──────────────                    ───
DIG-Network/dig-store  ─┐   packaging/build-deb.sh   ─┐
DIG-Network/dig-node   ─┘   (download asset → lay     │   make repo →  S3 apt-dig-net
                            out deb → dpkg-deb)        ├─ pool/main/*.deb   └─ CloudFront
                            packaging/repo/            │   dists/stable/...    └─ apt.dig.net
                            generate-repo.sh           │   (Packages/Release/
                            (Packages/Release +        │    InRelease + dig.gpg)
                             GPG sign)                 ┘
```

- **`packaging/config.sh`** — the single source of truth: which repo publishes each
  package, the per-arch release-asset name template, the Debian control metadata, and
  whether the package installs a service. Add a package = edit this file.
- **`packaging/build-deb.sh`** — resolves the latest release of each package's repo,
  downloads the per-arch asset, lays out the `.deb` (control + binary on PATH +
  systemd unit/maintainer scripts for the service package), and builds it with
  `dpkg-deb`. **Missing assets are skipped, never fatal** (see "Upstream asset
  contract").
- **`packaging/repo/generate-repo.sh`** — turns the pool of `.debs` into a flat,
  GPG-signed apt repo (`Packages`/`Packages.gz`/`Release`/`Release.gpg`/`InRelease`)
  for `stable main`, exports the signing **public** key to `dig.gpg`, and writes
  `feed.xml` (an Atom feed of the currently published packages, via `generate_feed()`).
- **`site/`** — the static landing page (`index.html`), `llms.txt`, `sitemap.xml`, and
  `robots.txt`; copied verbatim into the repo root by `make repo`.
- **`infra/`** — Terraform for the S3 bucket + CloudFront + Route53 + ACM.
- **`.github/workflows/deploy.yml`** — build → sign → S3 sync → CloudFront invalidate.
- **`.github/workflows/ci.yml`** — shellcheck + actionlint + terraform fmt/validate +
  the test suite (real deb build + signed-repo round-trip).

---

## Upstream asset contract (important)

The packages are built **from the upstream GitHub release assets**, resolved at build
time. The asset names packaging expects are declared per package in `config.sh`:

| Package    | Repo                     | Expected asset (per arch)                              |
| ---------- | ------------------------ | ----------------------------------------------------- |
| `dig-store` | `DIG-Network/dig-store` | `dig-store-<ver>-{x86_64,aarch64}-unknown-linux-gnu.tar.gz` (contains `dig-store` + `digs` + a `digstore` compat entry) |
| `dig-node` | `DIG-Network/dig-node`   | `dig-node-<ver>-linux-{x64,arm64}` (bare binary)       |

**Asset availability:**

- `DIG-Network/dig-store`'s release publishes a raw per-arch
  `dig-store-<ver>-{x86_64,aarch64}-unknown-linux-gnu.tar.gz` release asset — which is
  what `config.sh` targets. The repo/binary was renamed `digstore` → `dig-store`
  (#703), so the release dual-publishes a transitional `digstore-<ver>-…` tarball too;
  packaging prefers the new `dig-store-*` name. The tarball carries `dig-store` + `digs`
  (a first-class alias binary, `digs <args>` == `dig-store <args>`, resolved as an
  **optional extra** — `PKG_dig_store_EXTRA_BINS` — and skipped non-fatally on any
  release that predates it). The `.deb` additionally ships a `/usr/bin/digstore` →
  `dig-store` compat symlink (`PKG_dig_store_COMPAT_SYMLINKS`).
- `DIG-Network/dig-node`'s `release.yml` publishes raw `dig-node-<ver>-linux-{x64,arm64}`
  binaries on a tag — which is what `config.sh` targets. (No `linux-arm64` asset is
  published yet, so arm64 is skipped non-fatally; see the note below.)

The build resolves each template; if the asset is absent it **skips** that package
(non-fatal), and the apt repo is published with whatever debs DID build. The pipeline
stays green. When upstream attaches matching assets, packaging picks them up with **no
code change**. To point at a different source without editing `config.sh`, set per-run
env overrides in CI: `DIG_STORE_TAG`, `DIG_STORE_ASSET_TEMPLATE`, `DIG_NODE_TAG`,
`DIG_NODE_ASSET_TEMPLATE`.

> `arm64` is best-effort: an arch with no matching asset is skipped the same way.

---

## Local development & deployment

Procedures live in `runbooks/` (CLAUDE.md §4.4):

- **[`runbooks/local-development.md`](runbooks/local-development.md)** — prerequisites,
  the `make test`/`lint`/`debs`/`repo` commands, and the test suite.
- **[`runbooks/deployment.md`](runbooks/deployment.md)** — the push-to-`main` OIDC deploy,
  the GPG-key + AWS-infra + deploy-role provisioning, how to verify it went live, and the
  secrets handling.

The repo is **public**: no secrets live in the code — the GPG **private** key is the CI
secret `APT_GPG_PRIVATE_KEY` (only the **public** key is exported to `/dig.gpg`) and AWS
access is via OIDC. Never print or commit a private key. Full detail in the deployment
runbook.

Normative contract: **[`SPEC.md`](SPEC.md)** — the asset-name template scheme, the Debian
package/service layout invariants, and the flat apt-repo structure.
