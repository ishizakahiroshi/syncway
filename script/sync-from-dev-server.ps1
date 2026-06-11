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

    # Extra rsync exclude patterns (",git/" is always excluded unless -IncludeGit).
    [string[]]$Exclude = @(),

    [switch]$NoDelete,

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

function Invoke-Rsync {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$RsyncArgs
    )

    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($wsl) {
        & wsl.exe sh -lc "command -v rsync >/dev/null 2>&1"
        if ($LASTEXITCODE -eq 0) {
            $wslLocalPath = Convert-ToWslPath -Path $LocalPath
            New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null

            $argsForWsl = @("rsync") + $RsyncArgs[0..($RsyncArgs.Count - 2)] + @($wslLocalPath.TrimEnd("/") + "/")
            & wsl.exe @argsForWsl
            return $LASTEXITCODE
        }
    }

    $rsync = Get-Command rsync.exe -ErrorAction SilentlyContinue
    if (-not $rsync) {
        throw "rsync was not found. Install WSL with rsync, or install rsync.exe for Windows."
    }

    New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null
    & $rsync.Source @RsyncArgs
    return $LASTEXITCODE
}

$source = ("{0}:{1}" -f $Remote, $RemotePath.TrimEnd("/") + "/")
$destination = ([System.IO.Path]::GetFullPath($LocalPath).TrimEnd("\") + "\")

$rsyncArgs = @("-av")

if (-not $NoDelete) {
    $rsyncArgs += "--delete"
}

if ($DryRun) {
    $rsyncArgs += "--dry-run"
}

if (-not $IncludeGit) {
    $rsyncArgs += "--exclude"
    $rsyncArgs += ".git/"
}

foreach ($pattern in $Exclude) {
    if (-not [string]::IsNullOrWhiteSpace($pattern)) {
        $rsyncArgs += "--exclude"
        $rsyncArgs += $pattern
    }
}

$rsyncArgs += $source
$rsyncArgs += $destination

Write-Host ("Syncing {0} -> {1}" -f $source, $destination)
$exitCode = Invoke-Rsync -RsyncArgs $rsyncArgs

if ($exitCode -ne 0) {
    exit $exitCode
}

Write-Host "Sync completed."
