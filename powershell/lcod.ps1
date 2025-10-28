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

$IsWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
$IsMacOS = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)

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

function Add-OrUpdateKernel([string]$KernelId, [string]$KernelVersion, [string]$KernelPath) {
    $config = Get-Config
    $kernels = @()
    foreach ($kernel in $config.installedKernels) {
        if ($kernel.id -ne $KernelId) {
            $kernels += $kernel
        }
    }
    $entry = [pscustomobject]@{
        id      = $KernelId
        version = if ($KernelVersion) { $KernelVersion } else { $null }
        path    = $KernelPath
    }
    $kernels += $entry
    $config.installedKernels = $kernels
    if ([string]::IsNullOrEmpty($config.defaultKernel)) {
        $config.defaultKernel = $KernelId
    }
    Save-Config $config
}

function Remove-KernelEntry([string]$KernelId) {
    $config = Get-Config
    $kernels = @()
    foreach ($kernel in $config.installedKernels) {
        if ($kernel.id -ne $KernelId) {
            $kernels += $kernel
        }
    }
    $config.installedKernels = $kernels
    if ($config.defaultKernel -eq $KernelId) {
        if ($kernels.Length -gt 0) {
            $config.defaultKernel = $kernels[0].id
        }
        else {
            $config.defaultKernel = $null
        }
    }
    Save-Config $config
}

function Get-KernelPath([object]$Config, [string]$KernelId) {
    foreach ($kernel in $Config.installedKernels) {
        if ($kernel.id -eq $KernelId) {
            return $kernel.path
        }
    }
    return $null
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

function Clear-QuarantineIfNeeded([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    if ($IsMacOS -and (Get-Command xattr -ErrorAction SilentlyContinue)) {
        try {
            & xattr -cr -- $Path 2>$null
        }
        catch {
            Write-Warn ("Failed to clear quarantine on {0}" -f $Path)
        }
    }
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
  kernel install <id>   Install or update a kernel from a local path.
  kernel remove <id>    Remove a kernel from the manifest.
  kernel default <id>   Set the default kernel.
  cache clean           Clear cached artefacts.
  self-update           Force immediate update check (placeholder).
  help                  Show this help message.

Most commands are still placeholders until installation logic lands.
"@
}

function Kernel-Install([string[]]$Args) {
    if ($Args.Length -lt 2) {
        Write-ErrorMessage "Usage: lcod kernel install <kernel-id> --path <binary> [--version <version>] [--force]"
        exit 1
    }

    $kernelId = $Args[1]
    $sourcePath = $null
    $kernelVersion = $null
    $force = $false

    for ($i = 2; $i -lt $Args.Length; $i++) {
        switch ($Args[$i]) {
            "--path" {
                if ($i + 1 -ge $Args.Length) {
                    Write-ErrorMessage "--path requires a value."
                    exit 1
                }
                $sourcePath = $Args[$i + 1]
                $i++
            }
            "--version" {
                if ($i + 1 -ge $Args.Length) {
                    Write-ErrorMessage "--version requires a value."
                    exit 1
                }
                $kernelVersion = $Args[$i + 1]
                $i++
            }
            "--force" {
                $force = $true
            }
            "-h" { Write-Info "Usage: lcod kernel install <kernel-id> --path <binary> [--version <version>] [--force]"; return }
            "--help" { Write-Info "Usage: lcod kernel install <kernel-id> --path <binary> [--version <version>] [--force]"; return }
            default {
                Write-ErrorMessage ("Unknown option '{0}' for kernel install." -f $Args[$i])
                exit 1
            }
        }
    }

    if (-not $sourcePath) {
        Write-ErrorMessage "--path is required for kernel install."
        exit 1
    }

    if (-not (Test-Path $sourcePath)) {
        Write-ErrorMessage ("Source binary not found at {0}" -f $sourcePath)
        exit 1
    }

    Ensure-State

    $destination = Join-Path $BinDir $kernelId
    if ((Test-Path $destination) -and -not $force) {
        Write-ErrorMessage ("Kernel '{0}' already installed at {1} (use --force to overwrite)." -f $kernelId, $destination)
        exit 1
    }

    Copy-Item -LiteralPath $sourcePath -Destination $destination -Force

    if (-not $IsWindows) {
        try {
            & chmod +x $destination 2>$null
        }
        catch { }
    }

    Clear-QuarantineIfNeeded $destination
    Add-OrUpdateKernel -KernelId $kernelId -KernelVersion $kernelVersion -KernelPath $destination

    Write-Info ("Kernel '{0}' installed at {1}" -f $kernelId, $destination)
    if ($kernelVersion) {
        Write-Info ("Recorded version {0}" -f $kernelVersion)
    }
}

function Kernel-Remove([string[]]$Args) {
    if ($Args.Length -lt 2) {
        Write-ErrorMessage "Usage: lcod kernel remove <kernel-id>"
        exit 1
    }

    $kernelId = $Args[1]
    Ensure-State
    $config = Get-Config

    if (-not (Kernel-Exists $config $kernelId)) {
        Write-Warn ("Kernel '{0}' not registered; nothing to remove." -f $kernelId)
        return
    }

    $existingPath = Get-KernelPath $config $kernelId
    if ($existingPath -and (Test-Path $existingPath)) {
        if ($existingPath.StartsWith($BinDir)) {
            Remove-Item -LiteralPath $existingPath -Force
            Write-Info ("Removed binary {0}" -f $existingPath)
        }
        else {
            Write-Warn ("Skipping deletion of {0} (outside managed bin directory)." -f $existingPath)
        }
    }

    Remove-KernelEntry -KernelId $kernelId
    Write-Info ("Kernel '{0}' removed from manifest." -f $kernelId)
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
            "install" { Kernel-Install $Args }
            { $_ -in @("remove", "rm", "delete") } { Kernel-Remove $Args }
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
