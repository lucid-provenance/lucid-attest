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
job's *code* lives here, checked out at a commit SHA hardcoded in this
repo's own `sign.yml` (`env.TRUSTED_SIGNER_SHA`) — deliberately not a
value the caller can supply, so even a PR that fully rewrites
`lucid-assay`'s own workflow file (or the pipeline code itself) in the
same PR cannot also change what this job trusts. Bumping the pin is a
separate, deliberate, reviewable commit to *this* repo alone.

This repo is public deliberately: the signing logic isn't secret, and a
public, independently-inspectable trust boundary is more credible than a
private one to anyone verifying a `lucid-assay` attestation.

## What's here

- `.github/workflows/sign.yml` — the reusable `workflow_call` workflow.
  Called from `lucid-provenance/lucid-assay`'s own `assay.yml` `attest` job. See
  that file's header comment for the full contract (inputs, what it checks
  out, what it does and doesn't trust from the caller).

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
   the signer to pick up, bump `env.TRUSTED_SIGNER_SHA` at the top of
   *this repo's* `sign.yml`, in a deliberate, reviewed commit — never
   point it at a moving branch, and never re-expose it as a
   `lucid-assay`-supplied input.
3. Whenever this repo's own `sign.yml` changes, bump the SHA in the
   caller's `uses:` line the same way every other pinned action is
   bumped (full commit SHA, `# vX` comment, never a mutable tag alone).
