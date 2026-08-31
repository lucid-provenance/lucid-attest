# syntax=docker/dockerfile:1.7

# Immutable signer execution image -- Lucid roadmap Milestone #18
# ("Immutable Signer Container (Bridge to #12)").
#
# Packages ONLY the narrow signing/provenance surface this repo's sign.yml
# already restricted itself to trusting from lucid-assay:
#   cli/sign.py, cli/oidc_signer.py, cli/provenance.py
# plus the small, dependency-free modules those three actually import:
#   cli/common.py, cli/slsa_provenance.py, cli/parsers/lockfiles.py
# Deliberately NEVER cli/main.py, cli/scorer.py, cli/builder.py, or the
# rest of cli/parsers/* -- verified empirically (not just by reading
# imports) on lucid-assay's own side: `import cli.sign; import
# cli.provenance` loads exactly the module list above and nothing else.
# See docker/signer_entrypoint.py for why this image's own entrypoint
# dispatches to cli.sign/cli.provenance directly instead of through
# lucid-assay's cli.main (which would silently reintroduce the whole
# scoring/parsing pipeline into this image's import graph).
#
# What this closes, precisely -- calibrated against the real threat model,
# not the broader "environment isn't pinned" framing the milestone was
# first proposed under. uv.lock --frozen (already in use below and in
# lucid-assay's own CI) already makes dependency *versions* deterministic
# and hash-verified; a runtime `uv sync --frozen` would fail closed on a
# hash mismatch, not silently accept a swapped package. What it does NOT
# already close, and what containerizing actually buys:
#   1. `runs-on: ubuntu-latest` OS/library drift (glibc, OpenSSL, CA certs)
#      -- none of that is expressible in uv.lock at all.
#   2. `actions/setup-python: "3.13"` resolving to whatever 3.13.x patch
#      build happens to be current the day a given run executes, not one
#      exact, reproducible interpreter build.
#   3. A live runtime dependency on PyPI's *availability* -- not integrity
#      -- on every future signing event, forever, from the one job in the
#      platform holding `id-token: write`. A yanked wheel or a PyPI outage
#      at the wrong moment breaks signing with no local recourse today;
#      this image vendors that dependency closure once, permanently, for
#      whatever lucid-assay commit it was built from.
# What this does NOT close: the actual pin-count problem this repo's own
# `sign.yml` already documents (see the Lucid roadmap's "Signer SHA
# pinning pain"). TRUSTED_SIGNER_IMAGE_DIGEST below still needs a
# deliberate, reviewed bump whenever lucid-assay's signing surface
# changes -- same discipline as the git-SHA pin it replaces, just a
# different identifier type. See build-signer-image.yml's own header for
# how a new digest actually gets produced.
#
# Build context contract: this Dockerfile is never built against this
# repo's own checkout alone. build-signer-image.yml checks out
# lucid-assay at its own pinned SIGNER_SOURCE_SHA into `_signer/` *before*
# invoking `docker build`, the same way sign.yml's pre-container version
# already checked out lucid-assay into a subdirectory. Every COPY below
# that reads from `_signer/` depends on that checkout having already
# happened -- this stage never fetches lucid-assay itself, network or
# otherwise.

# ---- uv's own static binary, vendored rather than pip-installed ----
# Digest pinned 2026-08-31 against ghcr.io/astral-sh/uv:0.9.5's real
# manifest-list digest. Re-resolve before bumping the tag:
#   docker buildx imagetools inspect ghcr.io/astral-sh/uv:<new-version>
FROM ghcr.io/astral-sh/uv:0.9.5@sha256:f459f6f73a8c4ef5d69f4e6fbbdb8af751d6fa40ec34b39a1ab469acd6e289b7 AS uv-binary

# ---- Stage 1: resolve + vendor the hash-pinned dependency closure ----
# Digest pinned 2026-08-31 against python:3.13-slim's real manifest-list
# digest (registry-1.docker.io/library/python). Re-resolve before bumping:
#   docker buildx imagetools inspect python:3.13-slim
FROM python:3.13-slim@sha256:7ce4b6dfe35e55397b7cda544f8a13f191b7ae28dc5aad71fe664dbc9bc2623f AS builder
COPY --from=uv-binary /uv /usr/local/bin/uv

WORKDIR /build

# Only the lockfile + project metadata are needed to resolve the
# dependency closure -- lucid-assay's own source isn't read in this stage
# at all; the narrow file list is COPYed directly into the runtime stage
# below, never installed as a package here.
COPY _signer/pyproject.toml _signer/uv.lock ./

# --no-emit-project: lucid-assay's own package is never installed as a
# distribution here -- this image never runs cli.main/cli.scorer/
# cli.builder/cli.parsers.ast, so there is nothing of the project itself
# for pip to install.
# --no-emit-package (tree-sitter + its four language grammars): these are
# unconditional top-level lucid-assay dependencies, needed only by
# cli/parsers/ast.py (assertion-integrity AST walking) -- completely
# unused by cli.sign/cli.oidc_signer/cli.provenance. Verified: exporting
# without these five --no-emit-package flags pulls in 37 packages;
# with them, 32 -- the signer genuinely never imports any of the five.
# Hashes are included by default (no --no-hashes flag) -- this is the
# actual integrity-pinning step, not just a version-pinning one.
RUN uv export --frozen --no-dev --no-emit-project \
      --no-emit-package tree-sitter \
      --no-emit-package tree-sitter-go \
      --no-emit-package tree-sitter-java \
      --no-emit-package tree-sitter-javascript \
      --no-emit-package tree-sitter-typescript \
      -o requirements.txt

# pip, not `uv pip`, for this one step: --require-hashes has long-
# documented, unambiguous semantics in pip -- refuse to install anything
# `uv export` didn't emit a hash for. This is where hash enforcement
# actually gets applied against the resolved closure above, the same
# guarantee `uv sync --frozen` already gives lucid-assay's own CI.
RUN pip install --no-cache-dir --require-hashes -r requirements.txt \
      --target=/build/site-packages

# ---- Stage 2: minimal runtime -- no compiler, no uv, no lockfile ----
FROM python:3.13-slim@sha256:7ce4b6dfe35e55397b7cda544f8a13f191b7ae28dc5aad71fe664dbc9bc2623f AS runtime

# ca-certificates explicitly, not assumed present: this image makes real
# TLS calls to GitHub's OIDC token endpoint and Sigstore's Fulcio/Rekor/
# TUF services -- a missing or stale CA bundle on the signing path is a
# security-relevant failure, not a cosmetic one, so it's installed and
# refreshed at image-build time rather than trusted to whatever the base
# image happened to ship with.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Fixed, non-root UID/GID -- stable across rebuilds, chosen to avoid
# colliding with any base-image user. This is the safe default for anyone
# running the image standalone; sign.yml itself overrides it per-
# invocation with `docker run --user "$(id -u):$(id -g)"` so writes to
# the GitHub Actions runner's own bind-mounted output directory succeed
# (a fixed in-image UID essentially never matches the runner's own UID).
RUN groupadd --gid 65532 signer \
 && useradd --uid 65532 --gid signer --no-create-home --shell /usr/sbin/nologin signer \
 && mkdir -p /workspace \
 && chown signer:signer /workspace

WORKDIR /app
COPY --from=builder /build/site-packages /app/site-packages

# The narrow file list -- see this file's header comment for exactly why
# each one is here and nothing else is. Left-hand paths are relative to
# the checked-out lucid-assay source at _signer/ (see the header comment's
# "Build context contract").
COPY _signer/cli/__init__.py            cli/__init__.py
COPY _signer/cli/common.py              cli/common.py
COPY _signer/cli/oidc_signer.py         cli/oidc_signer.py
COPY _signer/cli/sign.py                cli/sign.py
COPY _signer/cli/provenance.py          cli/provenance.py
COPY _signer/cli/slsa_provenance.py     cli/slsa_provenance.py
COPY _signer/cli/parsers/__init__.py    cli/parsers/__init__.py
COPY _signer/cli/parsers/lockfiles.py   cli/parsers/lockfiles.py

# This repo's own entrypoint -- NOT part of lucid-assay, deliberately, so
# the narrow-footprint dispatch discipline is enforced by whoever owns
# this trust boundary, not by trusting lucid-assay to never reintroduce a
# cli.main import into one of the files above. See its own docstring.
COPY docker/signer_entrypoint.py /app/entrypoint.py

# HOME=/tmp, not /home/signer: every real invocation (sign.yml) overrides
# the container's user via `--user "$(id -u):$(id -g)"` to the GitHub
# Actions runner's own arbitrary UID, not the baked-in `signer` (65532) --
# so at runtime, `/home/signer` (owned by signer:signer, normal
# permissions) can be traversed by that UID but not written to. A real CI
# run proved this the hard way: sigstore-python's own code wants to create
# a cache directory under $HOME (`~/.cache`, not the `~/.local/share/
# sigstore-python` TUF path this image originally special-cased and
# bind-mounted) and failed with a permission error, because that path was
# never pre-created for an arbitrary UID. Rather than special-case every
# path some dependency might someday want to write under $HOME, point
# HOME at /tmp -- world-writable (sticky bit, mode 1777) by default in
# this base image regardless of which UID is running.
ENV PYTHONPATH=/app:/app/site-packages \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/tmp

WORKDIR /workspace
USER signer
ENTRYPOINT ["python", "/app/entrypoint.py"]
