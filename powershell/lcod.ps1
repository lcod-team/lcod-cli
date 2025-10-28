#!/usr/bin/env pwsh
param(
    [Parameter(Position = 0)]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [string[]]$Args
)

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-Path (Join-Path $ScriptRoot "..")
$VersionFile = Join-Path $RepoRoot "VERSION"

$HomeDir = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
$StateDir = if ($env:LCOD_STATE_DIR) { $env:LCOD_STATE_DIR } else { Join-Path $HomeDir ".lcod" }
$BinDir = if ($env:LCOD_BIN_DIR) { $env:LCOD_BIN_DIR } else { Join-Path $StateDir "bin" }
$CacheDir = if ($env:LCOD_CACHE_DIR) { $env:LCOD_CACHE_DIR } else { Join-Path $StateDir "cache" }
$ConfigPath = if ($env:LCOD_CONFIG) { $env:LCOD_CONFIG } else { Join-Path $StateDir "config.json" }
$UpdateStamp = Join-Path $StateDir "last-update"
$VersionCache = Join-Path $StateDir "latest-version.json"

function Write-Info($Message) {
    Write-Host "[INFO] $Message"
}

function Write-Warn($Message) {
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-ErrorMessage($Message) {
    Write-Error $Message
}

function Ensure-State {
    foreach ($dir in @($StateDir, $BinDir, $CacheDir)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir | Out-Null
        }
    }

    if (-not (Test-Path $ConfigPath)) {
        $config = @{
            defaultKernel    = $null
            installedKernels = @()
            lastUpdateCheck  = $null
        }
        $config | ConvertTo-Json -Depth 4 | Set-Content -Path $ConfigPath -Encoding UTF8
    }
}

function Get-Config {
    Ensure-State
    try {
        $raw = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @{
                defaultKernel    = $null
                installedKernels = @()
                lastUpdateCheck  = $null
            }
        }
        return $raw | ConvertFrom-Json
    }
    catch {
        Write-Warn "Failed to read config, recreating."
        $config = @{
            defaultKernel    = $null
            installedKernels = @()
            lastUpdateCheck  = $null
        }
        $config | ConvertTo-Json -Depth 4 | Set-Content -Path $ConfigPath -Encoding UTF8
        return $config
    }
}

function Save-Config([object]$Config) {
    Ensure-State
    $Config | ConvertTo-Json -Depth 8 | Set-Content -Path $ConfigPath -Encoding UTF8
}

function Touch-UpdateStamp {
    Ensure-State
    $iso = (Get-Date).ToUniversalTime().ToString("o")
    Set-Content -Path $UpdateStamp -Value $iso -Encoding UTF8
    $config = Get-Config
    $config.lastUpdateCheck = $iso
    Save-Config $config
}

function Needs-Update([int]$PeriodDays = 1) {
    if (-not (Test-Path $UpdateStamp)) {
        return $true
    }
    $stamp = (Get-Item $UpdateStamp).LastWriteTimeUtc
    $threshold = (Get-Date).ToUniversalTime().AddDays(-$PeriodDays)
    return $stamp -lt $threshold
}

function Fetch-LatestVersion([string]$Repo = "lcod-dev/lcod-release") {
    $uri = "https://raw.githubusercontent.com/$Repo/main/VERSION"
    try {
        return (Invoke-WebRequest -Uri $uri -UseBasicParsing -ErrorAction Stop).Content.Trim()
    }
    catch {
        return $null
    }
}

function Update-VersionCache([string]$Repo = "lcod-dev/lcod-release") {
    Ensure-State
    $version = Fetch-LatestVersion -Repo $Repo
    if (-not $version) {
        return $null
    }
    $iso = (Get-Date).ToUniversalTime().ToString("o")
    $payload = @{
        version   = $version
        source    = $Repo
        fetchedAt = $iso
    }
    $payload | ConvertTo-Json -Depth 4 | Set-Content -Path $VersionCache -Encoding UTF8
    Touch-UpdateStamp
    return $version
}

function Get-CachedRemoteVersion {
    if (Test-Path $VersionCache) {
        try {
            return ((Get-Content -Path $VersionCache -Raw) | ConvertFrom-Json).version
        }
        catch {
            return $null
        }
    }
    return $null
}

function Get-CachedVersionTimestamp {
    if (Test-Path $VersionCache) {
        try {
            return ((Get-Content -Path $VersionCache -Raw) | ConvertFrom-Json).fetchedAt
        }
        catch {
            return $null
        }
    }
    return $null
}

function Kernel-Exists([object]$Config, [string]$KernelId) {
    if (-not $KernelId) { return $false }
    foreach ($kernel in $Config.installedKernels) {
        if ($kernel.id -eq $KernelId) {
            return $true
        }
    }
    return $false
}

function Get-Version {
    Ensure-State
    $localVersion = if (Test-Path $VersionFile) {
        (Get-Content -Path $VersionFile -Raw).Trim()
    }
    else {
        "dev"
    }

    $remoteVersion = $null
    $fetchFailed = $false
    $fetched = $false

    if (Needs-Update 1) {
        $remoteVersion = Update-VersionCache
        if ($remoteVersion) {
            $fetched = $true
        }
        else {
            $fetchFailed = $true
        }
    }

    if (-not $remoteVersion) {
        $remoteVersion = Get-CachedRemoteVersion
    }

    Write-Host ("CLI version: {0}" -f $localVersion)
    if ($remoteVersion) {
        $status = if ($remoteVersion -eq $localVersion) { "up to date" } else { "update available" }
        $timestamp = Get-CachedVersionTimestamp
        if ($timestamp) {
            Write-Host ("Upstream release: {0} ({1}, checked {2})" -f $remoteVersion, $status, $timestamp)
        }
        else {
            Write-Host ("Upstream release: {0} ({1})" -f $remoteVersion, $status)
        }
        if ($fetched) {
            Write-Info ("Fetched latest release information ({0})." -f $remoteVersion)
        }
    }
    else {
        if ($fetchFailed) {
            Write-Warn "Could not refresh latest release information."
        }
        else {
            Write-Warn "No upstream release information cached yet."
        }
    }
}

function Show-Help {
@"
Usage: lcod <command> [options]

Commands:
  version               Print the currently installed CLI version.
  kernel ls             List available kernels from the local manifest.
  kernel default <id>   Set the default kernel.
  cache clean           Clear cached artefacts.
  self-update           Force immediate update check (placeholder).
  help                  Show this help message.

Most commands are still placeholders until installation logic lands.
"@
}

Ensure-State

switch ($Command) {
    "version" { Get-Version }
    "kernel" {
        if ($Args.Length -eq 0) {
            Write-ErrorMessage "Missing kernel subcommand."
            exit 1
        }
        $config = Get-Config
        switch ($Args[0]) {
            "ls" {
                if (-not $config.installedKernels -or $config.installedKernels.Count -eq 0) {
                    Write-Info "No kernels installed yet."
                    Write-Info "Use 'lcod kernel install <id>' once available."
                }
                else {
                    Write-Host "ID`tVersion`tPath`tDefault"
                    foreach ($kernel in $config.installedKernels) {
                        $isDefault = if ($kernel.id -eq $config.defaultKernel) { "yes" } else { "no" }
                        $id = if ($kernel.id) { $kernel.id } else { "-" }
                        $version = if ($kernel.version) { $kernel.version } else { "n/a" }
                        $path = if ($kernel.path) { $kernel.path } else { "-" }
                        Write-Host ("{0}`t{1}`t{2}`t{3}" -f $id, $version, $path, $isDefault)
                    }
                }
            }
            "default" {
                if ($Args.Length -lt 2) {
                    Write-ErrorMessage "Usage: lcod kernel default <kernel-id>"
                    exit 1
                }
                $kernelId = $Args[1]
                if (-not (Kernel-Exists $config $kernelId)) {
                    Write-Warn ("Kernel '{0}' not found in manifest; recording default anyway." -f $kernelId)
                }
                $config.defaultKernel = $kernelId
                Save-Config $config
                Write-Info ("Default kernel set to '{0}'." -f $kernelId)
            }
            default {
                Write-ErrorMessage ("Unknown kernel subcommand '{0}'." -f $Args[0])
                exit 1
            }
        }
    }
    "cache" {
        if ($Args.Length -eq 0) {
            Write-ErrorMessage "Missing cache subcommand."
            exit 1
        }
        switch ($Args[0]) {
            "clean" {
                Ensure-State
                if (Test-Path $CacheDir) {
                    Get-ChildItem -Path $CacheDir -Force | Remove-Item -Recurse -Force
                    Write-Info "Cache cleared."
                }
                else {
                    Write-Info "Cache directory not present."
                }
            }
            default {
                Write-ErrorMessage ("Unknown cache subcommand '{0}'." -f $Args[0])
                exit 1
            }
        }
    }
    "self-update" {
        Write-Info "Self-update placeholder. Will download latest release in a future iteration."
        Touch-UpdateStamp
    }
    "help" { Show-Help }
    default {
        Write-ErrorMessage ("Unknown command '{0}'." -f $Command)
        Show-Help
        exit 1
    }
}
