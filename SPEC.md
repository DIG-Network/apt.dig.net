# apt.dig.net — normative specification

This is the authoritative contract for the DIG Network APT repository: the `.deb`
packages it produces, the upstream release assets they are built from, and the flat,
GPG-signed apt repository layout it publishes. An independent reimplementation MUST be
able to reproduce a byte-compatible repository from this document alone.

The keywords MUST, MUST NOT, SHOULD, and MAY are used per RFC 2119.

Cross-references: the cross-repo interaction map is `SYSTEM.md` in the superproject; the
canonical dig-node port is `dig_constants::DIG_NODE_PORT` (§3.4).

---

## 1. Source of truth

`packaging/config.sh` is the single declarative source of truth for the package
catalogue. It is a pure data file: no logic, sourced by the builder and by the tests.
Every package fact — the publishing repo, the per-arch asset-name template, the Debian
control metadata, service layout, and (for dig-node) the loopback bind address — is a
data entry there. Adding or changing a package MUST be a data edit to `config.sh`, not a
code change to the builder.

The declared set of packages is `$APT_PACKAGES` (currently `dig-store dig-node`). A
package id containing `-` maps to a variable key segment with `-`→`_` (`dig-node` →
`PKG_dig_node_*`), resolved through the single accessor `pkg_var PKG SUFFIX`.

---

## 2. Asset-name resolution — the `{ver}`/`{arch}` template scheme

Each package declares `PKG_<pkg>_ASSET_TEMPLATE`, the name of the upstream GitHub release
asset to download per architecture. The template contains two placeholders:

- `{ver}` — the release version with any single leading `v` stripped (`v1.2.3` → `1.2.3`).
- `{arch}` — the upstream architecture token for the target Debian arch (§2.1).

`asset_name(TEMPLATE, VER, ARCH)` MUST substitute both placeholders literally and return
the concrete asset file name. It MUST strip a single leading `v` from `VER` before
substitution and MUST NOT otherwise transform the template.

### 2.1 Architecture token mapping

The repo attempts the Debian arches in `$APT_ARCHES` (`amd64 arm64`, in order). The
default Debian-arch → upstream-token map (`apt_asset_arch`) is:

| Debian arch | default token |
| ----------- | ------------- |
| `amd64`     | `x86_64`      |
| `arm64`     | `aarch64`     |

A package whose release names assets with a different scheme MUST override per arch via
`PKG_<pkg>_ASSET_ARCH_<debarch>`; `asset_arch_for(PKG, DEBARCH)` returns the override when
present, else the default map. (dig-node overrides to Node's `x64`/`arm64` naming.)

### 2.2 Concrete asset contract

| Package     | Repo                    | Asset template                                          | Bin in archive |
| ----------- | ----------------------- | ------------------------------------------------------- | -------------- |
| `dig-store` | `DIG-Network/digs` | `dig-store-{ver}-{arch}-unknown-linux-gnu.tar.gz`       | `dig-store`    |
| `dig-node`  | `DIG-Network/dig-node`  | `dig-node-{ver}-linux-{arch}` (bare binary, no archive) | (bare)         |

`PKG_<pkg>_ARCHIVE_BIN_PATH` is the path of the binary inside the downloaded archive; an
empty value means the asset IS the bare binary (no unpack). A `.tar.gz`/`.tgz`/`.zip`
asset MUST be unpacked and the binary taken from `ARCHIVE_BIN_PATH`.

### 2.3 Missing-asset resilience (MUST)

Resolution is best-effort per arch AND per package. If an upstream release, tag, or
per-arch asset does not exist, the builder MUST skip that arch/package with a warning and
MUST NOT fail the build. The repository is published with whatever `.deb`s did build. The
per-run env overrides `<PKG>_TAG` and `<PKG>_ASSET_TEMPLATE` (e.g. `DIG_STORE_TAG`)
redirect resolution without editing `config.sh`.

---

## 3. Debian package + service layout invariants

For every package the built `.deb` MUST:

- install the binary as `/usr/bin/<PKG_*_BIN>`, mode `0755`;
- carry a `DEBIAN/control` rendered purely from `config.sh` + the build args, with fields
  in order: `Package`, `Version`, `Architecture`, `Maintainer`, `Section`, `Priority:
  optional`, `Depends` (when set), `Homepage` (when set), `Installed-Size` (when supplied),
  `Description` (short) + the indented long description.

### 3.1 Debian version normalisation

`deb_version(VER)` MUST produce a Debian-policy-valid upstream version: strip a single
leading `v`, and translate every `-` (a semver prerelease separator, forbidden in a
Debian upstream version) to `~`, which sorts BEFORE the release in dpkg ordering
(`1.2.3-rc1` → `1.2.3~rc1`).

### 3.2 Extra binaries and compat symlinks

`PKG_<pkg>_EXTRA_BINS` names additional executables shipped from the SAME upstream archive
alongside the main binary, installed under `/usr/bin`. An extra binary that a given
upstream release predates MUST be skipped non-fatally. `PKG_<pkg>_COMPAT_SYMLINKS` names
`/usr/bin` symlinks pointing at the main binary (relative link, same directory). dig-store
ships `digs` (a first-class alias binary) as an extra and `digstore` as a transitional
compat symlink.

### 3.3 Service packages

A package with `PKG_<pkg>_SERVICE="yes"` MUST additionally:

- install its systemd unit at `/lib/systemd/system/<pkg>.service`, mode `0644`;
- ship the `postinst`/`prerm`/`postrm` maintainer scripts present under
  `packaging/debian/<pkg>/` into `DEBIAN/`, mode `0755`;
- enable + start the service on install (`systemctl enable --now <pkg>`), run as the
  unprivileged `PKG_<pkg>_SERVICE_USER` account (never root), and use the persistent
  state directory `PKG_<pkg>_CACHE_DIR`.

### 3.4 dig-node bind address (single-source, MUST)

The dig-node unit MUST bind loopback-only, at `PKG_dig_node_HOST:PKG_dig_node_PORT`
(`127.0.0.1:9778`). `9778` is the CANONICAL dig-node port, published upstream as
`dig_constants::DIG_NODE_PORT`; it MUST NOT be `8080` (the historical drift corrected in
dig_ecosystem #315). `config.sh` (`PKG_dig_node_PORT`) is this repo's single source of
truth for the value; the unit sets it via `Environment=DIG_NODE_PORT=`, the README and
site quote it, and `tests/test_dig_node_port.sh` asserts every reference matches the
constant and that `8080` appears as a node port nowhere. The RPC surface is a LOCAL read
interface, not a public service.

---

## 4. Flat apt-repository structure

`generate-repo.sh` MUST assemble a flat (single-suite) apt repository publishing the
`stable` suite, `main` component, over the pool of built `.deb`s:

```
/                       repo root (served at https://apt.dig.net)
  pool/main/*.deb       the package pool
  dists/stable/
    main/binary-<arch>/
      Packages          the per-arch package index (uncompressed)
      Packages.gz       the gzip-compressed index
    Release             the suite Release file (Origin/Label/Suite/Component/
                        Architectures + MD5Sum/SHA256 index of every Packages file)
    Release.gpg         detached ascii-armored signature over Release
    InRelease           inline-signed Release
  dig.gpg               the DIG signing PUBLIC key (ascii-armored)
  feed.xml              Atom feed of currently published packages
```

Invariants:

- `Packages` MUST list, per package, the control fields plus `Filename` (pointing into
  `pool/main/`), `Size`, and the `MD5sum`/`SHA1`/`SHA256` of the `.deb`.
- `Release` MUST declare `Origin: DIG Network`, `Label: DIG`, `Suite: stable`,
  `Component: main`, the `Architectures` list, and a checksum index of every `Packages`
  and `Packages.gz` file.
- When a signing key fingerprint is supplied, both `Release.gpg` (detached) AND
  `InRelease` (inline) MUST be produced and MUST verify against the exported `dig.gpg`
  public key. When no key is supplied the repository is built UNSIGNED and the S3 sync is
  skipped (an unsigned repo is not published — apt requires a signature).
- Only the PUBLIC key is ever written to the repository output. The private signing key
  (`APT_GPG_PRIVATE_KEY`) is imported into a scratch keyring at deploy time and MUST NOT
  be written to the repository or committed.

Consumers install via:

```
deb [signed-by=/usr/share/keyrings/dig.gpg] https://apt.dig.net stable main
```

---

## 5. Machine-readable surface

The published root MUST expose `llms.txt`, `sitemap.xml`, `robots.txt`, and `feed.xml`
(an Atom feed of currently published packages, generated at build time). The static site
(`index.html` + the machine files) is copied verbatim into the repo root by `make repo`,
after which the real `package.json` version is substituted into the `%%APP_VERSION%%`
placeholder (CLAUDE.md §6.7 build attribution).
