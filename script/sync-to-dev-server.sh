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
STRICT_HOST_KEY=""

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
                           NAME must match [A-Za-z0-9][A-Za-z0-9_.-]*.
  --include-git            Do not exclude .git/.
  --strict-host-key        Require the remote host key to already be in
                           ~/.ssh/known_hosts (ssh StrictHostKeyChecking=yes).
                           Default is accept-new (TOFU on first contact).
  --help, -h               Show this help and exit.

REMOTE_PATH and LOCAL_PATH are required (pass them as environment variables).

Examples:
  REMOTE_PATH=/home/<user>/dev/myproj/ LOCAL_PATH=/c/projects/myproj/ \
    ./sync-to-dev-server.sh ubuntu@dev.example.com --dry-run
  REMOTE_PATH=/home/<user>/work/myproj/ LOCAL_PATH=/c/projects/myproj/ \
    ./sync-to-dev-server.sh ubuntu@dev.example.com --container=my_container

Environment variables:
  REMOTE_PATH=/home/<user>/dev/myproj/   (required)
  LOCAL_PATH=/c/projects/myproj/              (required)
  SSH_PORT=22
  SSH_KEY=/c/projects/.ssh/id_ed25519
  CONTAINER=container_name               (or pass --container=name)
  EXCLUDES="node_modules/ dist/"         (space-separated extra rsync excludes)

Notes:
  SSH_KEY paths and EXCLUDES patterns cannot contain whitespace or single quotes.
  SSH option StrictHostKeyChecking=accept-new is used (TOFU on first contact).
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
		--strict-host-key) STRICT_HOST_KEY=1 ;;
		--help|-h) usage; exit 0 ;;
		*) printf 'Unknown option: %s\n' "$arg" >&2; usage >&2; exit 1 ;;
	esac
done

if [ -z "$REMOTE_PATH" ] || [ -z "$LOCAL_PATH" ]; then
	printf 'REMOTE_PATH and LOCAL_PATH must be set.\n\n' >&2
	usage >&2
	exit 1
fi

# Validate CONTAINER (Docker name rules) so user-supplied value cannot inject
# shell metacharacters into the remote --rsync-path string.
if [ -n "$CONTAINER" ]; then
	if ! printf '%s' "$CONTAINER" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]*$'; then
		printf 'Invalid --container value: %s\n' "$CONTAINER" >&2
		printf 'Container name must match [A-Za-z0-9][A-Za-z0-9_.-]*\n' >&2
		exit 1
	fi
fi

# Local source must exist before we try to upload it.
if [ ! -d "$LOCAL_PATH" ]; then
	printf 'LOCAL_PATH does not exist or is not a directory: %s\n' "$LOCAL_PATH" >&2
	exit 1
fi

# Delete safety: --delete alone is preview-only; needs --confirm-delete to apply.
DELETE_PREVIEW_ONLY=0
if [ -n "$DELETE" ] && [ -z "$CONFIRM_DELETE" ]; then
	DELETE_PREVIEW_ONLY=1
	DRY_RUN="--dry-run"
fi

# Normalize REMOTE_PATH to have exactly one trailing slash, matching the .ps1
# variant so `myproj` and `myproj/` behave the same across shells.
REMOTE_PATH="${REMOTE_PATH%/}/"

LOCAL_PATH_NATIVE="$LOCAL_PATH"
LOCAL_PATH_RSYNC="$LOCAL_PATH"

# Build the exclude argument list (.git is excluded unless --include-git).
# Disable pathname expansion around the loop so wildcard patterns in EXCLUDES
# (e.g. "*.log") are not glob-expanded against the current working directory.
EXCLUDE_ARGS=()
if [ -z "$INCLUDE_GIT" ]; then
	EXCLUDE_ARGS+=(--exclude='.git/')
fi
set -f
for pat in $EXTRA_EXCLUDES; do
	EXCLUDE_ARGS+=("--exclude=$pat")
done
set +f

# Locate cwrsync-style rsync.exe. Priority:
#   1. SYNCWAY_RSYNC env (explicit path to rsync.exe)
#   2. Scoop default: $HOME/scoop/apps/cwrsync/current/bin/rsync.exe
#   3. rsync.exe on PATH while running under MINGW/MSYS/CYGWIN bash
# When found, enable cygdrive path translation, MSYS_NO_PATHCONV, and PATH prepend.
CWRSYNC_BIN=""
if [ -n "${SYNCWAY_RSYNC:-}" ] && [ -x "${SYNCWAY_RSYNC:-}" ]; then
	CWRSYNC_BIN="$(dirname "$SYNCWAY_RSYNC")"
elif [ -x "$HOME/scoop/apps/cwrsync/current/bin/rsync.exe" ]; then
	CWRSYNC_BIN="$HOME/scoop/apps/cwrsync/current/bin"
elif command -v rsync.exe >/dev/null 2>&1 && uname -s 2>/dev/null | grep -qE '^(MINGW|MSYS|CYGWIN)'; then
	CWRSYNC_BIN="$(dirname "$(command -v rsync.exe)")"
fi

if [ -n "$CWRSYNC_BIN" ]; then
	export PATH="$CWRSYNC_BIN:$PATH"
	export MSYS_NO_PATHCONV=1
	to_cyg() {
		# Reject Windows-native paths up front so the user gets a clear error
		# instead of a misleading "Could not resolve hostname C" from rsync.
		case "$1" in
			[A-Za-z]:[\\/]*|[A-Za-z]:)
				printf 'Windows-native path "%s" is not supported by the bash variant.\n' "$1" >&2
				printf 'Use POSIX form like /c/projects/myproj/ instead (or run the .ps1 variant).\n' >&2
				return 1
				;;
		esac
		printf '%s\n' "$1" | sed 's|^/\([a-zA-Z]\)/|/cygdrive/\1/|'
	}
	LOCAL_PATH_RSYNC="$(to_cyg "$LOCAL_PATH_NATIVE")"
	if [ -n "$SSH_KEY" ]; then
		SSH_KEY_RSYNC="$(to_cyg "$SSH_KEY")"
	fi
fi

# Build the ssh command for rsync's -e. rsync forwards this string to /bin/sh
# which re-splits on whitespace, so single-quote the key path to survive paths
# containing spaces (common on Windows: %USERPROFILE%\.ssh\...).
if [ -n "$STRICT_HOST_KEY" ]; then
	SSH_HOST_KEY_OPT="StrictHostKeyChecking=yes"
else
	SSH_HOST_KEY_OPT="StrictHostKeyChecking=accept-new"
fi
SSH_OPTS="-p $SSH_PORT -o $SSH_HOST_KEY_OPT"
if [ -n "$SSH_KEY_RSYNC" ]; then
	SSH_OPTS="-i '$SSH_KEY_RSYNC' $SSH_OPTS"
fi

RSYNC_ARGS=(-avz)
[ -n "$DELETE" ] && RSYNC_ARGS+=("$DELETE")
[ -n "$UPDATE" ] && RSYNC_ARGS+=("$UPDATE")
[ -n "$DRY_RUN" ] && RSYNC_ARGS+=("$DRY_RUN")
RSYNC_ARGS+=("${EXCLUDE_ARGS[@]+"${EXCLUDE_ARGS[@]}"}")
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
	printf "Uploading %s -> %s:%s (in container '%s')\n" "$LOCAL_PATH_NATIVE" "$REMOTE" "$REMOTE_PATH" "$CONTAINER"
else
	printf 'Uploading %s -> %s:%s\n' "$LOCAL_PATH_NATIVE" "$REMOTE" "$REMOTE_PATH"
fi
[ -n "$DRY_RUN" ] && printf '(dry-run: no changes will be made)\n'

# Capture rsync exit so benign non-zero codes (23 partial, 24 vanished source)
# still let us print the post-run delete-preview reminder instead of aborting.
set +e
rsync "${RSYNC_ARGS[@]}" \
	-e "ssh $SSH_OPTS" \
	"$LOCAL_PATH_RSYNC" \
	"$REMOTE:$REMOTE_PATH"
rsync_rc=$?
set -e

if [ "$rsync_rc" -ne 0 ] && [ "$rsync_rc" -ne 23 ] && [ "$rsync_rc" -ne 24 ]; then
	exit "$rsync_rc"
fi

if [ "$DELETE_PREVIEW_ONLY" -eq 1 ]; then
	printf 'Preview complete. Re-run with --confirm-delete to apply deletions.\n'
else
	printf 'Upload completed.\n'
fi
