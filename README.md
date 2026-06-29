# apt.dig.net

The DIG Network **APT repository** + its AWS infrastructure. Ubuntu/Debian users
install the DIG ecosystem with `apt` — `dig-node` (the node service, run via systemd)
and `digstore` (the content-addressable store CLI) — from a flat, GPG-signed apt
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
sudo apt install dig-node digstore

# 4. The node runs as a systemd service
systemctl status dig-node
```

### What you get

| Package    | Installs                                   | Service |
| ---------- | ------------------------------------------ | ------- |
| `dig-node` | `/usr/bin/dig-node` + `dig-node.service`   | yes — `systemctl enable --now dig-node` (loopback `127.0.0.1:8080`, runs as the `dig-node` system account, cache at `/var/lib/dig-node`) |
| `digstore` | `/usr/bin/digstore`                        | no — just the CLI on `PATH` |

Configure the node with `systemctl edit dig-node` (env: `DIG_COMPANION_HOST`,
`DIG_COMPANION_PORT`, `DIG_RPC_UPSTREAM`). The `DIG_COMPANION_*` names are the
binary's stable env-var names — kept under the node's legacy `dig-companion` name as a
config/wire contract even though the service is now `dig-node`. See the docs:
<https://docs.dig.net/docs/run-a-node>.

---

## Architecture

```
upstream GitHub releases                this repo (CI)                     AWS
─────────────────────────               ──────────────                    ───
DIG-Network/digstore   ─┐   packaging/build-deb.sh   ─┐
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
  for `stable main`, and exports the signing **public** key to `dig.gpg`.
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
| `digstore` | `DIG-Network/digstore`   | `digstore-<ver>-{x86_64,aarch64}-unknown-linux-gnu.tar.gz` |
| `dig-node` | `DIG-Network/dig-node`   | `dig-companion-<ver>-linux-{x64,arm64}` (bare binary)  |

**As of 2026-06, neither expected asset exists yet:**

- `DIG-Network/digstore` releases ship only the `DigStore-Setup-*.AppImage` / `.dmg`
  / `.exe` **installers** — there is no raw `digstore` Linux CLI binary as a release
  asset. (`publish-binary.yml` builds a static-musl `digstore` but uploads it to S3,
  not the release.)
- `DIG-Network/dig-node` has **no releases** yet. Its `release.yml` (inherited from
  dig-companion) is wired to publish `dig-companion-<ver>-linux-{x64,arm64}` binaries
  on a tag — which is what `config.sh` targets.

So today the build resolves the templates, finds nothing, **skips** the package
(non-fatal), and the apt repo is published with whatever debs DID build. The pipeline
stays green. When upstream attaches matching assets, packaging picks them up with **no
code change**. To point at a different source without editing `config.sh`, set per-run
env overrides in CI: `DIGSTORE_TAG`, `DIGSTORE_ASSET_TEMPLATE`, `DIG_NODE_TAG`,
`DIG_NODE_ASSET_TEMPLATE`.

> `arm64` is best-effort: an arch with no matching asset is skipped the same way.

---

## Local development

Requires a Linux host (or WSL) with `dpkg-dev` (`dpkg-deb`), `apt-utils`
(`apt-ftparchive`), and `gnupg`.

```bash
make test          # run the test suite (self-skips legs whose tooling is absent)
make lint          # shellcheck + actionlint + terraform fmt/validate (each optional)
make debs          # download upstream assets + build every available .deb into dist/pool/main
make repo GPG_FPR=<fingerprint>   # assemble + sign the repo into dist/ (omit GPG_FPR for unsigned)
```

### Tests

- `tests/test_version_resolution.sh` — version/tag normalisation + asset-name
  resolution (pure logic; runs anywhere).
- `tests/test_deb_layout.sh` — `DEBIAN/control` rendering + a real `dpkg-deb` build of
  a service package, asserting the binary lands on PATH, the unit ships + enables, and
  the maintainer scripts are present.
- `tests/test_repo_metadata.sh` — a real `apt-ftparchive` pool scan + `Release`
  generation + GPG **sign and verify** round-trip (proves `InRelease`/`Release.gpg`
  verify against the published `dig.gpg`).

---

## Deployment

The deploy is **push-to-main** (mirrors dig.net / status.dig.net): build the debs,
sign the repo, `aws s3 sync dist s3://<bucket> --delete`, `aws cloudfront
create-invalidation`. Auth is GitHub **OIDC** (no stored AWS keys).

It has two **no-op gates** so it is green before the infra/secret exist:

1. **Signing key** — without the `APT_GPG_PRIVATE_KEY` secret the repo is built
   *unsigned* and the S3 sync is **skipped** (an unsigned repo is useless to apt).
2. **Infra** — without the repo vars `APT_S3_BUCKET`,
   `APT_CLOUDFRONT_DISTRIBUTION_ID`, `CI_DEPLOY_ROLE_ARN` the sync is **skipped**
   (build still verified).

### What the parent must provision (out of band)

> Nothing here is provisioned yet. Until it is, the deploy builds + verifies and
> no-ops cleanly.

**1. GPG signing key (secret `APT_GPG_PRIVATE_KEY`)**

```bash
# Generate an ed25519 signing key (no passphrase, for CI), export the PRIVATE key,
# and store it as the repo/org secret APT_GPG_PRIVATE_KEY (ascii-armored).
cat > keygen <<'EOF'
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: sign
Name-Real: DIG Network
Name-Email: packages@dig.net
Expire-Date: 0
%commit
EOF
gpg --batch --gen-key keygen
FPR=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')
gpg --armor --export-secret-keys "$FPR" > apt-signing-private.asc
gh secret set APT_GPG_PRIVATE_KEY --repo DIG-Network/apt.dig.net < apt-signing-private.asc
# Keep apt-signing-private.asc OFFLINE/secret; CI exports the matching PUBLIC key
# to /dig.gpg automatically. Never commit either.
```

**2. AWS infra** — apply the Terraform (or create equivalently with the AWS CLI):

```bash
cd infra
terraform init
terraform apply   # defaults target bucket apt-dig-net, the *.dig.net cert + zone
# Note the outputs: s3_bucket, cloudfront_distribution_id
```

This creates: S3 bucket `apt-dig-net` (private, OAC), a CloudFront distribution
(reusing the `*.dig.net` ACM cert `aafcd24b-…`, with caching disabled for `dists/*` +
`dig.gpg` so `apt update` is never stale), and the `apt.dig.net` A/AAAA aliases in the
dig.net Route53 zone.

**3. OIDC deploy role + repo vars** — mirror the other sites' least-privilege role
(`s3:*Object`/`s3:ListBucket` on `apt-dig-net`, `cloudfront:CreateInvalidation` on the
distribution; trust `repo:DIG-Network/apt.dig.net` on `main`). Then set the repo vars:

```bash
gh variable set APT_S3_BUCKET --repo DIG-Network/apt.dig.net --body apt-dig-net
gh variable set APT_CLOUDFRONT_DISTRIBUTION_ID --repo DIG-Network/apt.dig.net --body <dist-id>
gh variable set CI_DEPLOY_ROLE_ARN --repo DIG-Network/apt.dig.net --body <role-arn>
```

Once the secret + vars exist, the next push to `main` publishes the signed repo and
`https://apt.dig.net` goes live.

---

## Security

This is a **public** repo. No secrets live in the code: the GPG **private** key is the
CI secret `APT_GPG_PRIVATE_KEY` (imported into a scratch keyring at deploy time and
never written to the repo output — only the **public** key is exported to `/dig.gpg`),
and AWS access is via OIDC (no stored keys). Never print or commit a private key.
