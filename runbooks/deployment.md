# Runbook — deployment

How the signed apt repository is published to AWS, the credentials/secrets it needs, and
how to verify it went live.

## Trigger

The deploy is **push-to-`main`** (mirrors dig.net / status.dig.net):
`.github/workflows/deploy.yml` builds the debs, signs the repo, `aws s3 sync dist
s3://<bucket> --delete`, then `aws cloudfront create-invalidation`. Auth is GitHub
**OIDC** — no stored AWS keys.

## No-op gates (green before the infra/secret exist)

1. **Signing key** — without the `APT_GPG_PRIVATE_KEY` secret the repo is built *unsigned*
   and the S3 sync is **skipped** (an unsigned repo is useless to apt).
2. **Infra** — without the repo vars `APT_S3_BUCKET`, `APT_CLOUDFRONT_DISTRIBUTION_ID`,
   `CI_DEPLOY_ROLE_ARN` the sync is **skipped** (build still verified).

## What the parent must provision (out of band)

> As of this writing nothing is provisioned yet; until it is, the deploy builds + verifies
> and no-ops cleanly.

### 1. GPG signing key (secret `APT_GPG_PRIVATE_KEY`)

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

### 2. AWS infra — apply the Terraform (or create equivalently with the AWS CLI)

```bash
cd infra
terraform init
terraform apply   # defaults target bucket apt-dig-net, the *.dig.net cert + zone
# Note the outputs: s3_bucket, cloudfront_distribution_id
```

This creates: S3 bucket `apt-dig-net` (private, OAC), a CloudFront distribution (reusing
the `*.dig.net` ACM cert `aafcd24b-…`, with caching disabled for `dists/*` + `dig.gpg` so
`apt update` is never stale), and the `apt.dig.net` A/AAAA aliases in the dig.net Route53
zone.

### 3. OIDC deploy role + repo vars

Mirror the other sites' least-privilege role (`s3:*Object`/`s3:ListBucket` on
`apt-dig-net`, `cloudfront:CreateInvalidation` on the distribution; trust
`repo:DIG-Network/apt.dig.net` on `main`). Then set the repo vars:

```bash
gh variable set APT_S3_BUCKET --repo DIG-Network/apt.dig.net --body apt-dig-net
gh variable set APT_CLOUDFRONT_DISTRIBUTION_ID --repo DIG-Network/apt.dig.net --body <dist-id>
gh variable set CI_DEPLOY_ROLE_ARN --repo DIG-Network/apt.dig.net --body <role-arn>
```

## Verify it went live

Once the secret + vars exist, the next push to `main` publishes the signed repo. Confirm:

```bash
# The signing key + a signed Release are reachable and verify.
curl -fsSL https://apt.dig.net/dig.gpg | gpg --show-keys
curl -fsSL https://apt.dig.net/dists/stable/InRelease | gpg --verify -

# A clean client can add the source and see the packages.
sudo apt update && apt-cache policy dig-node dig-store
```

## Secrets

This is a **public** repo. No secrets live in the code: the GPG **private** key is the CI
secret `APT_GPG_PRIVATE_KEY` (imported into a scratch keyring at deploy time and never
written to the repo output — only the **public** key is exported to `/dig.gpg`), and AWS
access is via OIDC (no stored keys). Never print or commit a private key.
