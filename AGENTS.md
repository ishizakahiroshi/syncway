# Agent Entry Point (Syncway)

This repository's operational guidance is maintained in `CLAUDE.md`.

- Project overview, scripts & safety invariants: `./CLAUDE.md`
- User-facing docs: `./README.md` (and `./README.ja.md`)
- Local/private additions (if present, not committed): `./CLAUDE.local.md` / `./AGENTS.local.md`

Personal/global AI rules are intentionally kept outside this repository. Use each
AI tool's supported global instruction location for user-specific rules; this
file must remain valid for a fresh public clone with no private files.

## Non-negotiables (full detail in CLAUDE.md)

- **Dry-run first** — preview with `--dry-run` / `-DryRun` before any real sync.
- **Deletions OFF by default** — `--delete` / `-Delete` only previews; real
  removal needs the explicit `--confirm-delete` / `-ConfirmDelete`.
- **No secrets in the repo** — host, key path, port, container name are passed
  as args/env from the user's local config, never committed.
- **Keep `.ps1` and `.sh` in sync** — mirror behavior across both variants and
  the README options table.

If any project guidance conflicts, follow `CLAUDE.md`.
