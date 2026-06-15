# Syncway — Project Guidance

> This file holds **project-specific** rules only. Personal/global AI rules
> (language, confirmation style, output format, etc.) belong in each AI tool's
> own global config — not in this public repo. This file must stay valid for a
> fresh public clone with no private files present.

## Project Overview

**Syncway** — bidirectional `rsync over ssh` between a remote server (anything
you can SSH into: VPS, bare-metal, Raspberry Pi, LAN box, or a Docker container)
and your local machine. Project-agnostic and **secrets-free**: the SSH target,
remote/local paths, excludes, SSH key, port, and Docker container are all passed
as arguments or environment variables. Nothing sensitive lives in the scripts,
so the repo is safe to publish and reuse across projects.

## Scripts

| Script | Direction |
|---|---|
| `script/sync-from-dev-server.ps1` / `.sh` | Download (remote → local) |
| `script/sync-to-dev-server.ps1` / `.sh`   | Upload (local → remote) |

- `.ps1` — Windows-first. Uses native `rsync.exe` (e.g. cwrsync); never starts
  WSL automatically (opt in with `-UseWsl` / `SYNCWAY_USE_WSL=1`).
- `.sh` — auto-detects cwrsync (Scoop) and converts paths to `/cygdrive` on Windows.

PowerShell and bash variants must stay **behaviorally in sync**: a change to one
direction or one option should be mirrored across both the `.ps1` and `.sh` of
that script, and across upload/download where the option is shared.

## Safety Invariants (do not regress)

These are the product's core promises — preserve them in every change:

1. **Dry-run first.** Examples and agent flows always preview with
   `-DryRun` / `--dry-run` before touching anything.
2. **Deletions OFF by default, in both directions.** `-Delete` / `--delete`
   alone is a **forced dry-run (preview only)**. Real deletion requires the
   explicit second flag `-ConfirmDelete` / `--confirm-delete`.
3. **No secrets in the repo.** Host, key path, port, and container name come
   from the user's local config and are passed as args/env — never hard-coded
   or committed. `.git/` is always excluded unless `-IncludeGit` / `--include-git`.
4. **Upload overwrite protection.** `-Update` / `--update` skips files newer on
   the remote so an older local copy never clobbers server-side changes.

## Cross-Variant Conventions

- **Option parity.** PowerShell switch ⇄ bash flag ⇄ env var must match the
  table in `README.md` (Options). Update the README when adding/renaming an option.
- **Path normalization.** Trailing slashes follow rsync semantics; scripts
  normalize source/destination so `myproj` and `myproj/` behave the same.
- **Line endings.** Enforced by `.gitattributes`: `*.sh` = LF (else
  `bad interpreter: .../bash^M` on Unix), `*.ps1` = CRLF. Do not fight this.

## docs/ Conventions

- `docs/local/` is gitignored — local-only operational notes (real server IPs,
  container names, key paths). Never put real connection values anywhere tracked.
- When creating `.md` files under `docs/`, follow the naming conventions used by
  your AI tool's global guides (`plan_*.md` / `bugfix_*.md` / `pending_*.md`).

## Working Rules (AI)

- **Never run a real sync without an explicit user go-ahead**, and never pass
  `-ConfirmDelete` / `--confirm-delete` unless the user has approved the delete
  preview. Default to additive (no deletions).
- **Do not commit, push, or build on your own initiative** — only when the user
  explicitly asks. Report what changed; don't ask "shall I commit?".
- When wiring Syncway into a project, always show the exact
  `source -> destination` from a dry-run before suggesting the real run.

## Entry Points for Other Agents

- Codex / generic agents: [AGENTS.md](AGENTS.md)
- This file (`CLAUDE.md`) is the source of truth; if guidance conflicts, follow it.
