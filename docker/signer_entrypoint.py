#!/usr/bin/env python3
"""
Entrypoint for lucid-attest's immutable signer container (Lucid roadmap
Milestone #18).

Owned by *this* repo, not lucid-assay -- deliberately. Dispatches directly
to `cli.sign.main()` / `cli.provenance.main()`, never through lucid-assay's
own `cli.main` dispatcher (the thing today's `python -m cli.main sign ...`
invocation actually runs): importing `cli.main` pulls in `cli.scorer`,
`cli.builder`, and the rest of `cli.parsers.*` at module load time
regardless of which subcommand is chosen, because those are top-level
imports in `cli/main.py` -- see lucid-assay's `cli/sign.py` module
docstring for the full explanation. That defeats the entire point of this
image's narrow, reviewed code footprint (see this repo's `Dockerfile`
header comment for the exact file list it packages).

Keeping this dispatch here, rather than trusting lucid-assay to never
reintroduce a `cli.main` import into `cli/sign.py` or `cli/provenance.py`,
means the repo that owns the trust boundary (`lucid-attest`) is also what
enforces it -- the same reason `TRUSTED_SIGNER_SHA` lives in this repo's
own `sign.yml` rather than being caller-suppliable.

Usage:
    entrypoint.py sign <statement> [--out PATH] [--dry-run-sign]
    entrypoint.py provenance --subject-name ... --subject-digest ... [...]

Exit codes are exactly whatever `cli.sign.main()` / `cli.provenance.main()`
return -- this wrapper adds no exit-code semantics of its own beyond a
usage error (exit 2, matching argparse's own convention for bad CLI
invocations, so a malformed `docker run` invocation fails the same way a
malformed direct CLI invocation always has).
"""
from __future__ import annotations

import sys
from typing import List, Optional

_SUBCOMMANDS = ("sign", "provenance")


def main(argv: Optional[List[str]] = None) -> int:
    argv = list(sys.argv[1:]) if argv is None else list(argv)

    if not argv or argv[0] not in _SUBCOMMANDS:
        print(
            f"usage: entrypoint.py {{{'|'.join(_SUBCOMMANDS)}}} [args...]",
            file=sys.stderr,
        )
        return 2

    subcommand, rest = argv[0], argv[1:]

    if subcommand == "sign":
        from cli.sign import main as sign_main

        return sign_main(rest)

    from cli.provenance import main as provenance_main

    return provenance_main(rest)


if __name__ == "__main__":
    sys.exit(main())
