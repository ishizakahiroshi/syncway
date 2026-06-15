# Syncway

[日本語版 README](README.ja.md)

Bidirectional `rsync over ssh` between a remote server — anything you can SSH into — and your local machine, with no secrets baked into the scripts.

<p align="center">
  <img src="assets/how-it-works.svg" alt="Syncway: upload (local to remote) and download (remote to local) over rsync/ssh, with optional Docker container sync and delete safety" width="860">
</p>

"Remote server" here means anything reachable over SSH — a VPS, a dedicated/bare-metal box, a Raspberry Pi, another machine on your LAN, or a Docker container on any of them. It is project-agnostic: the SSH target, remote/local paths, excludes, SSH key, port, and Docker container are all passed as arguments or environment variables. Nothing sensitive lives in the scripts, so the repo is safe to publish and reuse across projects.

## Features

- **Bidirectional** — download (remote → local) and upload (local → remote).
- **Windows-first** — PowerShell scripts use native `rsync.exe` (e.g. cwrsync) and never start WSL automatically; opt in to WSL's `rsync` with `-UseWsl`. bash scripts auto-detect cwrsync (Scoop) and convert paths to `/cygdrive`.
- **Direct Docker container sync** — when the files live only inside a container's filesystem, sync straight into/out of it with `--rsync-path="docker exec -i <name> rsync"`. Unlike a `tar` stream, dry-run, diffing, delete-preview, and update-protection all keep working.
- **Symmetric delete safety** — deletions are OFF by default in **both** directions. `--delete` / `-Delete` only PREVIEWS (forced dry-run); you must add `--confirm-delete` / `-ConfirmDelete` to actually remove anything.
- **No secrets in the scripts** — host, key path, port, and container name come from your local config, never the repo.

## Scripts

| Script | Direction |
|---|---|
| `script/sync-from-dev-server.ps1` / `.sh` | Download (remote → local) |
| `script/sync-to-dev-server.ps1` / `.sh`   | Upload (local → remote) |

## Two Ways to Use It

Syncway is just scripts, so you can drive it however you like:

- **Run the scripts directly (default).** Clone the repo and call
  `script/*.ps1` / `*.sh` with arguments. Full control, easy to repeat for a
  sync you run often. Start here — the Quick Start below is exactly this.
- **Hand it to an AI agent (optional).** Open your AI coding agent inside the
  Syncway folder and let it ask for the details and pick the right script for
  you. See [Set It Up With an AI Agent](#set-it-up-with-an-ai-agent). Handy for
  first-time wiring; you still confirm the dry-run yourself.

Either way the safety rules are the same: dry-run first, no deletions without an
explicit second confirmation, and no secrets in the repo.

## Quick Start

Always start with `-DryRun` / `--dry-run` to preview before touching anything.

### Download (remote → local)

PowerShell:

```powershell
.\script\sync-from-dev-server.ps1 `
  -Remote     ubuntu@dev.example.com `
  -RemotePath /home/<user>/dev/myproj/ `
  -LocalPath  C:\projects\myproj `
  -Exclude    node_modules/,docs/local/ `
  -DryRun
```

bash:

```bash
REMOTE_PATH=/home/<user>/dev/myproj/ LOCAL_PATH=/c/projects/myproj/ \
  ./script/sync-from-dev-server.sh ubuntu@dev.example.com --dry-run
```

### Upload (local → remote)

PowerShell:

```powershell
.\script\sync-to-dev-server.ps1 `
  -Remote     ubuntu@dev.example.com `
  -RemotePath /home/<user>/dev/myproj/ `
  -LocalPath  C:\projects\myproj `
  -SshKey     C:\projects\.ssh\id_ed25519 `
  -Exclude    node_modules/,dist/ `
  -DryRun
```

bash:

```bash
REMOTE_PATH=/home/<user>/dev/myproj/ LOCAL_PATH=/c/projects/myproj/ SSH_KEY=/c/projects/.ssh/id_ed25519 \
  ./script/sync-to-dev-server.sh ubuntu@dev.example.com --dry-run
```

## Delete Safety (mirror)

By default, neither direction deletes anything — extra files at the destination are left alone. To make the destination an exact mirror (remove files that no longer exist at the source), use a deliberate two-step:

```powershell
# 1) Preview what would be removed (-Delete alone is a forced dry-run — nothing changes)
.\script\sync-to-dev-server.ps1 -Remote ... -RemotePath ... -LocalPath ... -Delete

# 2) Once the "deleting ..." list looks right, apply it
.\script\sync-to-dev-server.ps1 -Remote ... -RemotePath ... -LocalPath ... -Delete -ConfirmDelete
```

bash uses `--delete` (preview) → `--delete --confirm-delete` (apply). The same applies to the download scripts — there, deletions affect your **local** files. The upload scripts also offer `-Update` / `--update` to skip files that are newer on the remote, so an older local copy never clobbers server-side changes.

## Sync Into a Docker Container

When the target files live only inside a container's filesystem, point rsync at it. The container must have `rsync` installed; `RemotePath` is then interpreted **inside** the container.

```powershell
# Upload into a container
.\script\sync-to-dev-server.ps1 `
  -Remote     ubuntu@dev.example.com `
  -RemotePath /home/<user>/work/myproj/ `
  -LocalPath  C:\projects\myproj `
  -SshKey     C:\projects\.ssh\id_ed25519 `
  -Container  my_container
```

```bash
# Download out of a container
REMOTE_PATH=/app/ LOCAL_PATH=/c/projects/app/ \
  ./script/sync-from-dev-server.sh ubuntu@dev.example.com --container=my_container --dry-run
```

## Set It Up With an AI Agent

If you use an AI coding agent (Claude Code, Codex, Cursor, etc.), you can let it wire up the sync for you. Clone this repo, open your agent **inside the Syncway folder**, and paste the prompt below.

```text
Set up Syncway in this repo to sync my project with my remote server.

1. Ask me for: the SSH target (user@host), the remote path, the local path,
   the SSH key path and port if non-default, and whether the files live inside
   a Docker container.
2. Decide direction from what I want (pull from the server = download script,
   push to the server = upload script).
3. ALWAYS run a dry-run first, and show me the exact source -> destination it
   will use plus what would change.
4. Never pass --confirm-delete / -ConfirmDelete unless I explicitly approve the
   delete preview. Default to additive sync (no deletions).
5. Give me back the exact command to re-run the sync myself.

Stay safe: dry-run first, no deletions without my explicit confirmation, and
never put my host, key path, or container name into any committed file.
```

> **Review the dry-run yourself.** An agent can guess the wrong remote path or
> direction — confirm the `source -> destination` line in the dry-run output
> before you let it run for real.

## Options (Upload)

| PowerShell | bash | Description |
|---|---|---|
| `-Remote` | 1st arg | SSH target `user@host` (required) |
| `-RemotePath` | `REMOTE_PATH` | Remote destination directory (required) |
| `-LocalPath` | `LOCAL_PATH` | Local source directory (required) |
| `-SshKey` | `SSH_KEY` | SSH private key path |
| `-Port` | `SSH_PORT` | SSH port (default 22) |
| `-Exclude` | `EXCLUDES` | Extra exclude patterns (`.git/` always excluded) |
| `-Container` | `--container=` / `CONTAINER` | Sync into a Docker container |
| `-Update` | `--update` | Skip files newer on the remote (overwrite protection) |
| `-Delete` | `--delete` | Mirror (preview only by itself) |
| `-ConfirmDelete` | `--confirm-delete` | Required with `-Delete` to actually delete |
| `-IncludeGit` | `--include-git` | Do not exclude `.git/` |
| `-StrictHostKey` | `--strict-host-key` | Require the remote host key to already be in `~/.ssh/known_hosts` (`StrictHostKeyChecking=yes`). Default is `accept-new` — see [SSH host key policy](#ssh-host-key-policy-tofu) below |
| `-UseWsl` | n/a (bash never uses WSL) | Opt in to WSL's rsync (default uses native `rsync.exe` only; also `SYNCWAY_USE_WSL=1`) |
| `-DryRun` | `--dry-run` / `-d` | Preview only |

The download scripts share the same options (minus `-Update`, which is upload-only); there `-Delete` affects local files.

## Notes

- Pass the real connection values (host / key path / container name) from your own local config. Keep them out of the repo.
- Trailing slashes follow rsync semantics; the scripts normalize the source/destination so `myproj` and `myproj/` behave the same.
- `docs/local/` and `.claude/` are gitignored for local-only operational notes and settings.

### SSH host key policy (TOFU)

All scripts pass `-o StrictHostKeyChecking=accept-new` to ssh by default. This means:

- **First connection to an unknown host:** the host key is silently accepted and pinned into `~/.ssh/known_hosts`. No interactive prompt.
- **Subsequent connections:** ssh verifies normally; a changed key fails the connection.

This is convenient for spinning up new dev VPSes but trusts the network on first contact (TOFU — Trust On First Use). For stricter operation (require the host key to already be in `known_hosts`, e.g. pre-seeded via `ssh-keyscan`):

- PowerShell: add `-StrictHostKey`
- bash: add `--strict-host-key`

That switches the option to `StrictHostKeyChecking=yes`.

## Project Info

GitHub description:

```text
Bidirectional rsync-over-ssh sync between a remote server (any host you can SSH into) and your local machine. Windows-first, Docker-container aware, with delete safety on both directions and no secrets in the scripts.
```

Suggested GitHub topics:

```text
rsync ssh sync server remote vps deployment dev-tools powershell bash windows docker wsl developer-tools oss ai-tools claude-code
```

## License

MIT License. See [LICENSE](LICENSE).
