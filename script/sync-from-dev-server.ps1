[CmdletBinding()]
param(
    # SSH target, e.g. ubuntu@dev.example.com
    [Parameter(Mandatory = $true)]
    [string]$Remote,

    # Remote source directory (trailing slash recommended).
    [Parameter(Mandatory = $true)]
    [string]$RemotePath,

    # Local destination directory.
    [Parameter(Mandatory = $true)]
    [string]$LocalPath,

    # SSH private key path (optional; falls back to ssh defaults).
    [string]$SshKey,

    [int]$Port = 22,

    # Extra rsync exclude patterns (".git/" is always excluded unless -IncludeGit).
    [string[]]$Exclude = @(),

    # Pull from a Docker container on the remote host via:
    #   --rsync-path="docker exec -i <Container> rsync"
    # RemotePath is then interpreted INSIDE the container. Requires rsync to be
    # installed inside the container. Keeps dry-run / delete preview working.
    [string]$Container,

    # Delete local files that no longer exist on the remote (full mirror).
    # SAFETY: by itself this only PREVIEWS (forced dry-run). Add -ConfirmDelete to apply.
    [switch]$Delete,

    # Required alongside -Delete to actually perform deletions.
    [switch]$ConfirmDelete,

    [switch]$IncludeGit,

    # rsync engine: by default native rsync.exe (e.g. cwrsync) is used and WSL is
    # never started automatically. Pass -UseWsl / SYNCWAY_USE_WSL=1 to opt in to
    # WSL's rsync instead.
    [switch]$UseWsl,

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

function Convert-ToCygPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $drive = $fullPath.Substring(0, 1).ToLowerInvariant()
    $rest = $fullPath.Substring(2).TrimStart("\") -replace "\\", "/"
    return "/cygdrive/$drive/$rest"
}

# Locate a native rsync.exe (preferring cwrsync). Returns the exe path or $null.
function Get-NativeRsync {
    $cwrsync = Join-Path $HOME "scoop\apps\cwrsync\current\bin\rsync.exe"
    if (Test-Path $cwrsync) { return $cwrsync }
    $cmd = Get-Command rsync.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
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
    $remoteSource = ("{0}:{1}" -f $Remote, $RemotePath.TrimEnd("/") + "/")

    $forceWsl = $UseWsl -or -not [string]::IsNullOrWhiteSpace($env:SYNCWAY_USE_WSL)

    # Opt-in only: use WSL's rsync when explicitly requested (-UseWsl). WSL is never
    # started automatically, so it does not spin up the VM behind your back.
    if ($forceWsl) {
        $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
        if ($wsl) {
            & wsl.exe sh -lc "command -v rsync >/dev/null 2>&1"
            if ($LASTEXITCODE -eq 0) {
                New-Item -ItemType Directory -Path $localFull -Force | Out-Null
                $wslDest = (Convert-ToWslPath -Path $localFull).TrimEnd("/") + "/"
                $wslKey = if (-not [string]::IsNullOrWhiteSpace($SshKey)) { Convert-ToWslPath -Path $SshKey } else { "" }
                $sshCmd = Get-SshCommand -KeyPath $wslKey

                $argsForWsl = @("rsync") + $Flags + @("-e", $sshCmd, $remoteSource, $wslDest)
                & wsl.exe @argsForWsl
                return
            }
        }
        throw "WSL rsync was requested (-UseWsl) but WSL or its rsync was not found."
    }

    # Default: native rsync.exe only (e.g. cwrsync). No automatic WSL fallback.
    $rsyncExe = Get-NativeRsync
    if (-not $rsyncExe) {
        throw "rsync.exe was not found. Install it (e.g. 'scoop install rsync'), or pass -UseWsl / SYNCWAY_USE_WSL=1 to use WSL's rsync."
    }
    New-Item -ItemType Directory -Path $localFull -Force | Out-Null
    # cwrsync is cygwin-based: a Windows "C:\..." path is read as host:path,
    # so convert dest + key to /cygdrive form and use cwrsync's own ssh.
    $cygDest = (Convert-ToCygPath -Path $localFull).TrimEnd("/") + "/"
    $cygKey = if (-not [string]::IsNullOrWhiteSpace($SshKey)) { Convert-ToCygPath -Path $SshKey } else { "" }
    $sshCmd = Get-SshCommand -KeyPath $cygKey
    $savedPath = $env:PATH
    $env:PATH = (Split-Path $rsyncExe) + ";" + $env:PATH
    try {
        # Let rsync's output stream to the console; read exit via $LASTEXITCODE.
        & $rsyncExe @Flags "-e" $sshCmd $remoteSource $cygDest
        return
    }
    finally {
        $env:PATH = $savedPath
    }
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
    Write-Warning "-Delete will REMOVE local files that are absent on the remote."
    Write-Warning "This run is a PREVIEW ONLY (forced --dry-run); nothing will be changed."
    Write-Warning "Review the 'deleting ...' lines below, then re-run with -ConfirmDelete to apply."
}
elseif ($Delete -and $ConfirmDelete) {
    Write-Warning "-Delete -ConfirmDelete: local files absent on the remote WILL be deleted."
}

$srcLabel = if ($Container) { "{0}:{1} (in container '{2}')" -f $Remote, $RemotePath, $Container }
           else { "{0}:{1}" -f $Remote, $RemotePath }
$dstLabel = ([System.IO.Path]::GetFullPath($LocalPath).TrimEnd("\") + "\")
Write-Host ("Downloading {0} -> {1}" -f $srcLabel, $dstLabel)
if ($effectiveDryRun) { Write-Host "(dry-run: no changes will be made)" }

Invoke-Rsync -Flags $flags
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    exit $exitCode
}

if ($deletePreviewOnly) {
    Write-Host "Preview complete. Re-run with -ConfirmDelete to apply deletions."
}
else {
    Write-Host "Download completed."
}
