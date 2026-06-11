#!/usr/bin/env bash

set -euo pipefail

REMOTE="${1:-}"
REMOTE_PATH="${REMOTE_PATH:-}"
LOCAL_PATH="${LOCAL_PATH:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY="${SSH_KEY:-}"
SSH_KEY_RSYNC="$SSH_KEY"
DOCKER_CONTAINER="${DOCKER_CONTAINER:-}"
EXTRA_EXCLUDES="${EXCLUDES:-}"
DRY_RUN=""
USING_CWRSYNC=0

usage() {
	cat <<'HELP'
Generic dev-server downloader (rsync over ssh, optional Docker tar mode).

Usage:
  ./sync-from-dev-server.sh user@host [--dry-run|-d] [--docker=CONTAINER]

REMOTE_PATH and LOCAL_PATH are required (pass them as environment variables).

Examples:
  REMOTE_PATH=/home/<user>/dev/myproj/ LOCAL_PATH=/c/projects/myproj/ \
    ./sync-from-dev-server.sh ubuntu@dev.example.com
  REMOTE_PATH=/srv/app/ LOCAL_PATH=/c/projects/app/ \
    ./sync-from-dev-server.sh ubuntu@dev.example.com --dry-run

Environment variables:
  REMOTE_PATH=/home/<user>/dev/myproj/   (required)
  LOCAL_PATH=/c/projects/myproj/              (required)
  SSH_PORT=22
  SSH_KEY=/c/projects/.ssh/id_ed25519
  DOCKER_CONTAINER=container_name        (or pass --docker=name)
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
		--docker=*) DOCKER_CONTAINER="${arg#--docker=}" ;;
		*) printf 'Unknown option: %s\n' "$arg" >&2; usage >&2; exit 1 ;;
	esac
done

if [ -z "$REMOTE_PATH" ] || [ -z "$LOCAL_PATH" ]; then
	printf 'REMOTE_PATH and LOCAL_PATH must be set.\n\n' >&2
	usage >&2
	exit 1
fi

LOCAL_PATH_NATIVE="$LOCAL_PATH"
LOCAL_PATH_RSYNC="$LOCAL_PATH"

# Build the exclude argument list (.git is always excluded).
EXCLUDE_ARGS=(--exclude='.git/')
for pat in $EXTRA_EXCLUDES; do
	EXCLUDE_ARGS+=("--exclude=$pat")
done

CWRSYNC_BIN="$HOME/scoop/apps/cwrsync/current/bin"
if [ -x "$CWRSYNC_BIN/rsync.exe" ]; then
	export PATH="$CWRSYNC_BIN:$PATH"
	export MSYS_NO_PATHCONV=1
	to_cyg() { printf '%s\n' "$1" | sed 's|^/\([a-zA-Z]\)/|/cygdrive/\1/|'; }
	LOCAL_PATH_RSYNC="$(to_cyg "$LOCAL_PATH_NATIVE")"
	if [ -n "$SSH_KEY" ]; then
		SSH_KEY_RSYNC="$(to_cyg "$SSH_KEY")"
	fi
	USING_CWRSYNC=1
fi

mkdir -p "$LOCAL_PATH_NATIVE"

SSH_OPTS="-p $SSH_PORT -o StrictHostKeyChecking=accept-new"
if [ -n "$SSH_KEY_RSYNC" ]; then
	SSH_OPTS="-i $SSH_KEY_RSYNC $SSH_OPTS"
fi

if [ -n "$DOCKER_CONTAINER" ]; then
	if [ -n "$DRY_RUN" ]; then
		printf 'Dry-run is not available in Docker tar mode.\n' >&2
		exit 1
	fi

	tmp_parent="$(dirname "$LOCAL_PATH_NATIVE")"
	tmp_dir="$(mktemp -d "$tmp_parent/.dev-vps-sync.XXXXXX")"
	trap 'rm -rf "$tmp_dir"' EXIT
	tmp_source="$tmp_dir/$(basename "$REMOTE_PATH")/"
	if [ "$USING_CWRSYNC" -eq 1 ]; then
		tmp_source="$(to_cyg "$tmp_source")"
	fi

	printf 'Copying %s:%s from Docker container %s -> %s\n' "$REMOTE" "$REMOTE_PATH" "$DOCKER_CONTAINER" "$LOCAL_PATH_NATIVE"
	ssh $SSH_OPTS "$REMOTE" \
		"docker exec '$DOCKER_CONTAINER' tar --exclude='.git' -C '$(dirname "$REMOTE_PATH")' -czf - '$(basename "$REMOTE_PATH")'" |
		tar -xzf - -C "$tmp_dir"

	rsync -av --delete \
		"${EXCLUDE_ARGS[@]}" \
		"$tmp_source" \
		"$LOCAL_PATH_RSYNC"

	printf 'Sync completed.\n'
	exit 0
fi

RSYNC_ARGS=(
	-avz
	--delete
	"${EXCLUDE_ARGS[@]}"
)

if [ -n "$DRY_RUN" ]; then
	RSYNC_ARGS+=("$DRY_RUN")
fi

printf 'Syncing %s:%s -> %s\n' "$REMOTE" "$REMOTE_PATH" "$LOCAL_PATH_NATIVE"

rsync "${RSYNC_ARGS[@]}" \
	-e "ssh $SSH_OPTS" \
	"$REMOTE:$REMOTE_PATH" \
	"$LOCAL_PATH_RSYNC"

printf 'Sync completed.\n'
