# lucid-attest

The trusted signing boundary for [lucid-assay](https://github.com/lucid-provenance/lucid-assay)
attestations.

## What this is (and isn't)

This is **not** a code-reuse convenience — it's a trust boundary. It exists
because a build job that runs a PR's own tests/dependencies/CodeQL analysis
must never also be the job that mints the Sigstore identity used to sign
what that build claims about itself. If both lived in the same job (or the
same repo, on the same ref), a compromise of the build step — a malicious
dependency, a tampered test fixture — could in principle tamper with both
the artifact *and* its own attestation at once.

Splitting signing into its own job (`id-token: write` granted nowhere else)
closes most of that gap already. This repo closes the rest: the signing
job now runs against an **immutable, Sigstore-signed container image**
(`env.TRUSTED_SIGNER_IMAGE_DIGEST` in `sign.yml`) built from a lucid-assay
commit SHA hardcoded in `build-signer-image.yml` (`env.SIGNER_SOURCE_SHA`)
— deliberately not a value any caller can supply, so even a PR that fully
rewrites `lucid-assay`'s own workflow file (or the pipeline code itself)
in the same PR cannot also change what this job trusts. Bumping either pin
is a separate, deliberate, reviewable commit to *this* repo alone. See
"Container image" below for why this moved from a per-run `uv sync` on
the runner to a pre-built image, and what that does and doesn't fix.

This repo is public deliberately: the signing logic isn't secret, and a
public, independently-inspectable trust boundary is more credible than a
private one to anyone verifying a `lucid-assay` attestation.

## What's here

- `.github/workflows/sign.yml` — the reusable `workflow_call` workflow.
  Called from `lucid-provenance/lucid-assay`'s own `assay.yml` `attest` job. See
  that file's header comment for the full contract (inputs, what it checks
  out, what it does and doesn't trust from the caller). Runs entirely via
  `docker run` against the pinned signer image — no `lucid-assay` checkout
  or dependency install happens on the runner itself anymore.
- `Dockerfile` — the immutable signer image. Packages *only*
  `cli/sign.py`, `cli/oidc_signer.py`, `cli/provenance.py`, and the small,
  dependency-free modules those three actually import — never
  `cli/main.py`, `cli/scorer.py`, `cli/builder.py`, or the rest of
  `cli/parsers/*`. See its own header comment for the full rationale and
  what containerizing does and doesn't close.
- `docker/signer_entrypoint.py` — this repo's own dispatcher (`sign` /
  `provenance`), owned here rather than borrowed from `lucid-assay`, so
  the narrow-footprint discipline above is enforced by whoever owns this
  trust boundary, not by trusting `lucid-assay` to never reintroduce a
  `cli.main` import into one of the packaged files.
- `.github/workflows/build-signer-image.yml` — builds, pushes (to GHCR),
  and Sigstore-signs the image `sign.yml` runs. Manually triggered
  (`workflow_dispatch`, no inputs) — publishing a new trusted image is a
  deliberate action, not routine CI. Its own `SIGNER_SOURCE_SHA` is the
  one place a `lucid-assay` commit is trusted to build from.

## Container image

Moved from checking out `lucid-assay`'s source and running `uv sync` on
the runner every invocation, to running a pre-built image, pinned by
digest (Lucid roadmap Milestone #18). Calibrated against what was actually
still unpinned: `uv.lock --frozen` already made dependency *versions*
deterministic and hash-verified before this change — a swapped/malicious
package would already have failed a hash check, not been silently
accepted. What containerizing actually buys:

1. Freezes OS/library drift (`runs-on: ubuntu-latest` rolls forward on
   GitHub's own schedule; glibc/OpenSSL/CA-cert versions aren't expressible
   in `uv.lock` at all).
2. Freezes the exact Python interpreter build, not just the pinned minor
   version (`"3.13"` resolves to whatever patch build is current the day a
   run executes otherwise).
3. Removes a live runtime dependency on PyPI's *availability* — not
   integrity — from every future signing event, forever, on the one job in
   this platform holding `id-token: write`.

**What this doesn't fix**: the actual pin-count problem — bumping the
trusted source now means updating two things in sequence
(`SIGNER_SOURCE_SHA` in `build-signer-image.yml`, then
`TRUSTED_SIGNER_IMAGE_DIGEST` in `sign.yml` once the resulting image is
built and signed) rather than one. Same number of trust decisions as
before, more mechanical steps to propagate one — see the Lucid roadmap's
"Signer SHA pinning pain" for the broader pattern this doesn't solve.

## Setup

Done: this repo exists, `.github/workflows/sign.yml` is on `main`, and a
branch-protection ruleset is in place — this file's integrity *is* the
trust boundary, so `main` should stay protected the same way
`lucid-provenance/lucid-assay`'s own default branch is.

To wire it up:

1. Note the commit SHA of whatever's currently on `main`. In
   `lucid-provenance/lucid-assay`'s `assay.yml`, swap the `attest` job's local
   placeholder steps for:

   ```yaml
   attest:
     needs: build
     permissions:
       id-token: write
       contents: read
     uses: lucid-provenance/lucid-attest/.github/workflows/sign.yml@<that-sha> # v3
     with:
       artifact-name: unsigned-statements
       statement-files: |
         lucid-assay.unsigned.json
       subject-name: ${{ needs.build.outputs.image-ref }}
       subject-digest: ${{ needs.build.outputs.image-digest }}
   ```

   `subject-name`/`subject-digest` are optional — omit both to keep this
   job doing exactly what it always did (sign the files named in
   `statement-files`, nothing else). Supplying them opts this run into
   also **constructing** a SLSA v1.0 provenance statement inside this
   isolated job itself (SLSA Build Level 3 — see `sign.yml`'s header
   comment) and signing it alongside the caller's own statement(s); the
   caller's `build` job should no longer construct its own SLSA
   provenance statement in that case (drop `--emit-slsa-provenance` from
   its `cli.main` invocation) since this job now does that from its own
   trusted context instead.

2. Whenever `lucid-assay`'s signing/provenance code (`cli/sign.py`,
   `cli/oidc_signer.py`, `cli/provenance.py`) changes in a way you want
   the signer to pick up, this is now a two-step, both-deliberate process:
   1. Bump `env.SIGNER_SOURCE_SHA` at the top of *this repo's*
      `build-signer-image.yml`, in a reviewed commit — never point it at
      a moving branch, and never re-expose it as a `lucid-assay`-supplied
      input.
   2. Manually run `build-signer-image.yml` (`workflow_dispatch`). Its job
      summary prints the newly published image's digest. Bump
      `env.TRUSTED_SIGNER_IMAGE_DIGEST` at the top of *this repo's*
      `sign.yml` to that digest, in its own separate reviewed commit —
      `sign.yml` never rebuilds or re-resolves anything itself, it only
      ever runs the digest it's pinned to.
3. Whenever this repo's own `sign.yml` changes, bump the SHA in the
   caller's `uses:` line the same way every other pinned action is
   bumped (full commit SHA, `# vX` comment, never a mutable tag alone).
