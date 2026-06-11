#!/usr/bin/env bash

set -euo pipefail

REMOTE="${1:-}"
REMOTE_PATH="${REMOTE_PATH:-}"
LOCAL_PATH="${LOCAL_PATH:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY="${SSH_KEY:-}"
SSH_KEY_RSYNC="$SSH_KEY"
CONTAINER="${CONTAINER:-}"
EXTRA_EXCLUDES="${EXCLUDES:-}"
DRY_RUN=""
DELETE=""
CONFIRM_DELETE=""
UPDATE=""
INCLUDE_GIT=""
USING_CWRSYNC=0

usage() {
	cat <<'HELP'
Generic dev-server uploader (local -> remote, rsync over ssh).

Safety: deletions are OFF by default. --delete only PREVIEWS (forced dry-run);
add --confirm-delete to actually remove remote files absent locally.

Usage:
  ./sync-to-dev-server.sh user@host [options]

Options:
  --dry-run, -d            Preview only, make no changes.
  --delete                 Mirror: remove remote files absent locally (PREVIEW unless --confirm-delete).
  --confirm-delete         Required with --delete to actually delete.
  --update                 Skip files newer on the remote (rsync --update).
  --container=NAME         Push into a Docker container via docker exec rsync.
  --include-git            Do not exclude .git/.

REMOTE_PATH and LOCAL_PATH are required (pass them as environment variables).

Examples:
  REMOTE_PATH=/home/<user>/dev/myproj/ LOCAL_PATH=/c/projects/myproj/ \
    ./sync-to-dev-server.sh ubuntu@dev.example.com --dry-run
  REMOTE_PATH=/home/<user>/work/myproj/ LOCAL_PATH=/c/projects/myproj/ \
    ./sync-to-dev-server.sh ubuntu@dev.example.com --container=aac-ishiz

Environment variables:
  REMOTE_PATH=/home/<user>/dev/myproj/   (required)
  LOCAL_PATH=/c/projects/myproj/              (required)
  SSH_PORT=22
  SSH_KEY=/c/projects/.ssh/id_ed25519
  CONTAINER=container_name               (or pass --container=name)
  EXCLUDES="node_modules/ dist/"         (space-separated extra rsync excludes)
HELP
}

if [ -z "$REMOTE" ] || [ "$REMOTE" = "--help" ] || [ "$REMOTE" = "-h" ]; then
	usage
	exit 0
fi

shift

for arg in "$@"; do
	case "$arg" in
		--dry-run|-d) DRY_RUN="--dry-run" ;;
		--delete) DELETE="--delete" ;;
		--confirm-delete) CONFIRM_DELETE=1 ;;
		--update) UPDATE="--update" ;;
		--container=*) CONTAINER="${arg#--container=}" ;;
		--include-git) INCLUDE_GIT=1 ;;
		*) printf 'Unknown option: %s\n' "$arg" >&2; usage >&2; exit 1 ;;
	esac
done

if [ -z "$REMOTE_PATH" ] || [ -z "$LOCAL_PATH" ]; then
	printf 'REMOTE_PATH and LOCAL_PATH must be set.\n\n' >&2
	usage >&2
	exit 1
fi

# Delete safety: --delete alone is preview-only; needs --confirm-delete to apply.
DELETE_PREVIEW_ONLY=0
if [ -n "$DELETE" ] && [ -z "$CONFIRM_DELETE" ]; then
	DELETE_PREVIEW_ONLY=1
	DRY_RUN="--dry-run"
fi

LOCAL_PATH_RSYNC="$LOCAL_PATH"

# Build the exclude argument list (.git is excluded unless --include-git).
EXCLUDE_ARGS=()
if [ -z "$INCLUDE_GIT" ]; then
	EXCLUDE_ARGS+=(--exclude='.git/')
fi
for pat in $EXTRA_EXCLUDES; do
	EXCLUDE_ARGS+=("--exclude=$pat")
done

CWRSYNC_BIN="$HOME/scoop/apps/cwrsync/current/bin"
if [ -x "$CWRSYNC_BIN/rsync.exe" ]; then
	export PATH="$CWRSYNC_BIN:$PATH"
	export MSYS_NO_PATHCONV=1
	to_cyg() { printf '%s\n' "$1" | sed 's|^/\([a-zA-Z]\)/|/cygdrive/\1/|'; }
	LOCAL_PATH_RSYNC="$(to_cyg "$LOCAL_PATH")"
	if [ -n "$SSH_KEY" ]; then
		SSH_KEY_RSYNC="$(to_cyg "$SSH_KEY")"
	fi
	USING_CWRSYNC=1
fi

SSH_OPTS="-p $SSH_PORT -o StrictHostKeyChecking=accept-new"
if [ -n "$SSH_KEY_RSYNC" ]; then
	SSH_OPTS="-i $SSH_KEY_RSYNC $SSH_OPTS"
fi

RSYNC_ARGS=(-avz)
[ -n "$DELETE" ] && RSYNC_ARGS+=("$DELETE")
[ -n "$UPDATE" ] && RSYNC_ARGS+=("$UPDATE")
[ -n "$DRY_RUN" ] && RSYNC_ARGS+=("$DRY_RUN")
RSYNC_ARGS+=("${EXCLUDE_ARGS[@]}")
if [ -n "$CONTAINER" ]; then
	RSYNC_ARGS+=(--rsync-path="docker exec -i $CONTAINER rsync")
fi

# Warn before any destructive operation.
if [ "$DELETE_PREVIEW_ONLY" -eq 1 ]; then
	printf 'WARNING: --delete will REMOVE remote files absent locally.\n' >&2
	printf 'WARNING: this run is a PREVIEW ONLY (forced --dry-run); nothing will change.\n' >&2
	printf 'WARNING: review the "deleting ..." lines, then re-run with --confirm-delete.\n' >&2
elif [ -n "$DELETE" ] && [ -n "$CONFIRM_DELETE" ]; then
	printf 'WARNING: --delete --confirm-delete: remote files absent locally WILL be deleted.\n' >&2
fi

if [ -n "$CONTAINER" ]; then
	printf 'Uploading %s -> %s:%s (in container %s)\n' "$LOCAL_PATH" "$REMOTE" "$REMOTE_PATH" "$CONTAINER"
else
	printf 'Uploading %s -> %s:%s\n' "$LOCAL_PATH" "$REMOTE" "$REMOTE_PATH"
fi
[ -n "$DRY_RUN" ] && printf '(dry-run: no changes will be made)\n'

rsync "${RSYNC_ARGS[@]}" \
	-e "ssh $SSH_OPTS" \
	"$LOCAL_PATH_RSYNC" \
	"$REMOTE:$REMOTE_PATH"

if [ "$DELETE_PREVIEW_ONLY" -eq 1 ]; then
	printf 'Preview complete. Re-run with --confirm-delete to apply deletions.\n'
else
	printf 'Upload completed.\n'
fi
