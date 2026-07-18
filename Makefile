# apt.dig.net — build/test/lint entry points. The heavy targets (debs, repo) run on
# Linux with the Debian toolchain; `make test` self-skips legs whose tools are absent.

SHELL := /bin/bash
DIST  ?= dist          # the assembled repo site (synced to S3 by deploy.yml)
POOL  := $(DIST)/pool/main

.PHONY: all test lint debs repo clean fmt

all: repo

# Run the test suite (version resolution, deb layout, repo metadata).
test:
	bash tests/run.sh

# Lint shell scripts + the workflow + terraform. Each tool is optional locally; CI
# installs all of them. shellcheck over every script; actionlint over workflows;
# terraform fmt/validate over infra/.
lint:
	@command -v shellcheck >/dev/null 2>&1 && \
	  shellcheck -x packaging/lib/common.sh packaging/config.sh packaging/build-deb.sh \
	    packaging/repo/generate-repo.sh packaging/inject-site-version.sh \
	    tests/lib/assert.sh tests/*.sh \
	    || echo "shellcheck not installed — skipping"
	@command -v actionlint >/dev/null 2>&1 && actionlint || echo "actionlint not installed — skipping"
	@command -v terraform >/dev/null 2>&1 && ( cd infra && terraform fmt -check && terraform validate ) \
	  || echo "terraform not installed — skipping"

# Download upstream release assets + build every .deb into the pool.
debs:
	mkdir -p "$(POOL)"
	bash packaging/build-deb.sh "$(POOL)"

# Assemble + sign the repo. Pass GPG_FPR=<fingerprint> to sign (CI imports the key
# from $APT_GPG_PRIVATE_KEY and passes its fingerprint). The static site (index.html,
# llms.txt, sitemap.xml, robots.txt, og-image.svg, version.js) is copied into the repo
# root, then inject-site-version.sh substitutes the real package.json version into
# the %%APP_VERSION%% placeholder (CLAUDE.md §6.7) before the repo is signed.
repo: debs
	cp site/index.html site/llms.txt site/sitemap.xml site/robots.txt site/og-image.svg site/version.js "$(DIST)/" 2>/dev/null || true
	bash packaging/inject-site-version.sh "$(DIST)"
	bash packaging/repo/generate-repo.sh "$(DIST)" "$(GPG_FPR)"

fmt:
	cd infra && terraform fmt

clean:
	rm -rf "$(DIST)" build
