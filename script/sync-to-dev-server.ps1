[CmdletBinding()]
param(
    # SSH target, e.g. ubuntu@dev.example.com
    [Parameter(Mandatory = $true)]
    [string]$Remote,

    # Remote destination directory (trailing slash recommended).
    [Parameter(Mandatory = $true)]
    [string]$RemotePath,

    # Local source directory.
    [Parameter(Mandatory = $true)]
    [string]$LocalPath,

    # SSH private key path (optional; falls back to ssh defaults).
    [string]$SshKey,

    [int]$Port = 22,

    # Extra rsync exclude patterns (".git/" is always excluded unless -IncludeGit).
    [string[]]$Exclude = @(),

    # Push into a Docker container on the remote host via:
    #   --rsync-path="docker exec -i <Container> rsync"
    # Requires rsync to be installed inside the container. Keeps dry-run / delete
    # preview / update protection fully working (unlike a tar-stream copy).
    [string]$Container,

    # Skip files that are newer on the remote (rsync --update). Protects against
    # clobbering changes made on the server with an older local copy.
    [switch]$Update,

    # Delete remote files that no longer exist locally (full mirror).
    # SAFETY: by itself this only PREVIEWS (forced dry-run). Add -ConfirmDelete to apply.
    [switch]$Delete,

    # Required alongside -Delete to actually perform deletions.
    [switch]$ConfirmDelete,

    [switch]$IncludeGit,

    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Convert-ToWslPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $drive = $fullPath.Substring(0, 1).ToLowerInvariant()
    $rest = $fullPath.Substring(2).TrimStart("\") -replace "\\", "/"
    return "/mnt/$drive/$rest"
}

function Get-SshCommand {
    param([string]$KeyPath)

    $parts = @("ssh")
    if (-not [string]::IsNullOrWhiteSpace($KeyPath)) {
        $parts += @("-i", $KeyPath)
    }
    $parts += @("-p", "$Port", "-o", "StrictHostKeyChecking=accept-new")
    return ($parts -join " ")
}

function Invoke-Rsync {
    param(
        # rsync flags + excludes + --rsync-path (everything except -e and src/dest).
        [Parameter(Mandatory = $true)]
        [string[]]$Flags
    )

    $localFull = [System.IO.Path]::GetFullPath($LocalPath)
    $remoteDest = ("{0}:{1}" -f $Remote, $RemotePath.TrimEnd("/") + "/")

    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($wsl) {
        & wsl.exe sh -lc "command -v rsync >/dev/null 2>&1"
        if ($LASTEXITCODE -eq 0) {
            $wslSource = $localFull.TrimEnd("\") + "\" | ForEach-Object { (Convert-ToWslPath -Path $_).TrimEnd("/") + "/" }
            $wslKey = if (-not [string]::IsNullOrWhiteSpace($SshKey)) { Convert-ToWslPath -Path $SshKey } else { "" }
            $sshCmd = Get-SshCommand -KeyPath $wslKey

            $argsForWsl = @("rsync") + $Flags + @("-e", $sshCmd, $wslSource, $remoteDest)
            & wsl.exe @argsForWsl
            return $LASTEXITCODE
        }
    }

    $rsync = Get-Command rsync.exe -ErrorAction SilentlyContinue
    if (-not $rsync) {
        throw "rsync was not found. Install WSL with rsync, or install rsync.exe for Windows."
    }

    $nativeSource = $localFull.TrimEnd("\") + "\"
    $sshCmd = Get-SshCommand -KeyPath $SshKey
    & $rsync.Source @Flags "-e" $sshCmd $nativeSource $remoteDest
    return $LASTEXITCODE
}

# --- Build rsync flags -------------------------------------------------------

$flags = @("-avz")

# Delete safety: -Delete alone is preview-only; -Delete -ConfirmDelete applies.
$deletePreviewOnly = $false
if ($Delete) {
    $flags += "--delete"
    if (-not $ConfirmDelete) {
        $deletePreviewOnly = $true
    }
}

$effectiveDryRun = $DryRun -or $deletePreviewOnly
if ($effectiveDryRun) {
    $flags += "--dry-run"
}

if ($Update) {
    $flags += "--update"
}

if (-not $IncludeGit) {
    $flags += @("--exclude", ".git/")
}

foreach ($pattern in $Exclude) {
    if (-not [string]::IsNullOrWhiteSpace($pattern)) {
        $flags += @("--exclude", $pattern)
    }
}

if (-not [string]::IsNullOrWhiteSpace($Container)) {
    $flags += "--rsync-path=docker exec -i $Container rsync"
}

# --- Warn before any destructive operation -----------------------------------

if ($Delete -and -not $ConfirmDelete) {
    Write-Warning "-Delete will REMOVE remote files that are absent locally."
    Write-Warning "This run is a PREVIEW ONLY (forced --dry-run); nothing will be changed."
    Write-Warning "Review the 'deleting ...' lines below, then re-run with -ConfirmDelete to apply."
}
elseif ($Delete -and $ConfirmDelete) {
    Write-Warning "-Delete -ConfirmDelete: remote files absent locally WILL be deleted."
}

$srcLabel = ([System.IO.Path]::GetFullPath($LocalPath).TrimEnd("\") + "\")
$dstLabel = if ($Container) { "{0}:{1} (in container '{2}')" -f $Remote, $RemotePath, $Container }
           else { "{0}:{1}" -f $Remote, $RemotePath }
Write-Host ("Uploading {0} -> {1}" -f $srcLabel, $dstLabel)
if ($effectiveDryRun) { Write-Host "(dry-run: no changes will be made)" }

$exitCode = Invoke-Rsync -Flags $flags

if ($exitCode -ne 0) {
    exit $exitCode
}

if ($deletePreviewOnly) {
    Write-Host "Preview complete. Re-run with -ConfirmDelete to apply deletions."
}
else {
    Write-Host "Upload completed."
}
