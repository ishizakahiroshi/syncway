# Changelog

All notable changes to Syncway are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-06-11

Initial release. Bidirectional `rsync over ssh` between a remote server (any host you can SSH into) and your local machine.

### Added
- Download scripts `script/sync-from-dev-server.ps1` / `.sh` (remote -> local).
- Upload scripts `script/sync-to-dev-server.ps1` / `.sh` (local -> remote).
- Windows-first PowerShell scripts: auto-fallback from WSL `rsync` to native `rsync.exe`;
  bash scripts auto-detect cwrsync (Scoop) and convert paths to `/cygdrive`.
- Direct sync into a Docker container via `--rsync-path="docker exec -i <name> rsync"`,
  keeping dry-run, diff, delete-preview, and update protection fully working.
- Symmetric delete safety on both directions: deletions are OFF by default;
  `--delete` / `-Delete` only PREVIEWS (forced dry-run); `--confirm-delete` /
  `-ConfirmDelete` is required to actually remove files.
- `--update` / `-Update` (upload) to skip files that are newer on the remote.
- `.git/` excluded by default (`--include-git` / `-IncludeGit` to keep it),
  plus arbitrary extra excludes.
- No secrets in the scripts: SSH target, paths, key, port, and container name are
  all passed as arguments / environment variables.
- README in English and Japanese, an AI-agent auto-setup prompt, and an
  architecture diagram.

[0.1.0]: https://github.com/ishizakahiroshi/syncway/releases/tag/v0.1.0
