<#
.SYNOPSIS
    Generic dev-server uploader (local -> remote, rsync over ssh).

.DESCRIPTION
    Pushes files from a local directory into a remote SSH target using
    rsync over ssh. Safety: deletions are OFF by default. -Delete only
    PREVIEWS (forced dry-run); add -ConfirmDelete to actually remove
    remote files absent locally. -Update protects against clobbering
    files that are newer on the remote with an older local copy. By
    default uses native rsync.exe (e.g. cwrsync); WSL's rsync is never
    started automatically (opt in with -UseWsl).

.PARAMETER Remote
    SSH target, e.g. ubuntu@dev.example.com

.PARAMETER RemotePath
    Remote destination directory (trailing slash recommended; normalized).

.PARAMETER LocalPath
    Local source directory. Must exist.

.PARAMETER SshKey
    SSH private key path (optional; falls back to ssh defaults).
    Cannot contain a literal single quote.

.PARAMETER Port
    SSH port (default 22).

.PARAMETER Exclude
    Extra rsync exclude patterns. ".git/" is always excluded unless
    -IncludeGit is given.

.PARAMETER Container
    Push into a Docker container on the remote host via
    "--rsync-path=docker exec -i <Container> rsync". Must match
    [A-Za-z0-9][A-Za-z0-9_.-]*.

.PARAMETER Update
    Skip files that are newer on the remote (rsync --update). Protects
    against clobbering changes made on the server with an older local copy.

.PARAMETER Delete
    Mirror: remove remote files that are absent locally.
    SAFETY: by itself this only PREVIEWS (forced dry-run). Add
    -ConfirmDelete to actually delete.

.PARAMETER ConfirmDelete
    Required alongside -Delete to actually perform deletions.

.PARAMETER IncludeGit
    Do not exclude .git/.

.PARAMETER UseWsl
    Use WSL's rsync instead of native rsync.exe. WSL is never started
    automatically; this opts in to using it.

.PARAMETER StrictHostKey
    Require the remote host key to already be in ~/.ssh/known_hosts
    (ssh StrictHostKeyChecking=yes). Default is accept-new (TOFU on
    first contact).

.PARAMETER DryRun
    Preview only, make no changes.

.EXAMPLE
    .\sync-to-dev-server.ps1 -Remote ubuntu@dev.example.com `
        -RemotePath /home/<user>/dev/myproj/ `
        -LocalPath C:\projects\myproj\ -DryRun

.EXAMPLE
    .\sync-to-dev-server.ps1 -Remote ubuntu@dev.example.com `
        -RemotePath /home/<user>/work/myproj/ `
        -LocalPath C:\projects\myproj\ -Container my_container -Update

.NOTES
    SSH option StrictHostKeyChecking=accept-new is used (TOFU on first
    contact). For full help, run: Get-Help .\sync-to-dev-server.ps1 -Full
#>
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
    # Restricted to Docker's container-name charset so the value cannot inject
    # shell metacharacters into the remote command rsync runs.
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$|^$')]
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

    # rsync engine: by default native rsync.exe (e.g. cwrsync) is used and WSL is
    # never started automatically. Pass -UseWsl / SYNCWAY_USE_WSL=1 to opt in to
    # WSL's rsync instead.
    [switch]$UseWsl,

    # Require the remote host key to already be in known_hosts. Default is
    # accept-new (TOFU on first contact, then verify on subsequent runs).
    [switch]$StrictHostKey,

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

    # rsync forwards the -e value to /bin/sh which re-splits on whitespace, so
    # single-quote the key path to survive paths containing spaces (very common
    # on Windows: %USERPROFILE%\.ssh\...). KeyPath cannot contain a
    # literal single quote — documented in the .sh usage block.
    $parts = @("ssh")
    if (-not [string]::IsNullOrWhiteSpace($KeyPath)) {
        $parts += @("-i", "'$KeyPath'")
    }
    $hostKeyPolicy = if ($StrictHostKey) { "yes" } else { "accept-new" }
    $parts += @("-p", "$Port", "-o", "StrictHostKeyChecking=$hostKeyPolicy")
    return ($parts -join " ")
}

function Invoke-Rsync {
    param(
        # rsync flags + excludes + --rsync-path (everything except -e and src/dest).
        [Parameter(Mandatory = $true)]
        [string[]]$Flags
    )

    $localFull = [System.IO.Path]::GetFullPath($LocalPath)
    if (-not (Test-Path -LiteralPath $localFull -PathType Container)) {
        throw "LocalPath does not exist or is not a directory: $LocalPath"
    }
    $remoteDest = "{0}:{1}" -f $Remote, ($RemotePath.TrimEnd("/") + "/")

    $forceWsl = $UseWsl -or -not [string]::IsNullOrWhiteSpace($env:SYNCWAY_USE_WSL)

    # Opt-in only: use WSL's rsync when explicitly requested (-UseWsl). WSL is never
    # started automatically, so it does not spin up the VM behind your back.
    if ($forceWsl) {
        $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
        if ($wsl) {
            & wsl.exe sh -lc "command -v rsync >/dev/null 2>&1"
            if ($LASTEXITCODE -eq 0) {
                $wslSource = (Convert-ToWslPath -Path $localFull).TrimEnd("/") + "/"
                $wslKey = if (-not [string]::IsNullOrWhiteSpace($SshKey)) { Convert-ToWslPath -Path $SshKey } else { "" }
                $sshCmd = Get-SshCommand -KeyPath $wslKey

                $argsForWsl = @("rsync") + $Flags + @("-e", $sshCmd, $wslSource, $remoteDest)
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
    # cwrsync is cygwin-based: a Windows "C:\..." path is read as host:path,
    # so convert source + key to /cygdrive form and use cwrsync's own ssh.
    $cygSource = (Convert-ToCygPath -Path $localFull).TrimEnd("/") + "/"
    $cygKey = if (-not [string]::IsNullOrWhiteSpace($SshKey)) { Convert-ToCygPath -Path $SshKey } else { "" }
    $sshCmd = Get-SshCommand -KeyPath $cygKey
    $savedPath = $env:PATH
    $env:PATH = (Split-Path $rsyncExe) + ";" + $env:PATH
    try {
        # Let rsync's output stream to the console; read exit via $LASTEXITCODE.
        & $rsyncExe @Flags "-e" $sshCmd $cygSource $remoteDest
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

Invoke-Rsync -Flags $flags
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    exit $exitCode
}

if ($deletePreviewOnly) {
    Write-Host "Preview complete. Re-run with -ConfirmDelete to apply deletions."
}
else {
    Write-Host "Upload completed."
}
