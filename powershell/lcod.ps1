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
$CliUpdateCache = Join-Path $StateDir "cli-update.json"
$KernelUpdateCache = Join-Path $StateDir "kernel-update.json"
$AutoUpdateInterval = if ($env:LCOD_AUTO_UPDATE_INTERVAL) { [int]$env:LCOD_AUTO_UPDATE_INTERVAL } else { 86400 }

$IsWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
$IsMacOS = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)
$IsLinux = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)

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

function Get-DetectedPlatform {
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
    if ($IsLinux) {
        switch ($arch) {
            "X64" { return "linux-x86_64" }
            "Arm64" { return "linux-arm64" }
            default { throw "Unsupported Linux architecture: $arch" }
        }
    }
    elseif ($IsMacOS) {
        switch ($arch) {
            "X64" { return "macos-x86_64" }
            "Arm64" { return "macos-arm64" }
            default { throw "Unsupported macOS architecture: $arch" }
        }
    }
    elseif ($IsWindows) {
        switch ($arch) {
            "X64" { return "windows-x86_64" }
            "Arm64" { return "windows-arm64" }
            default { throw "Unsupported Windows architecture: $arch" }
        }
    }
    else {
        throw "Unsupported OS platform."
    }
}

function Get-AssetExtension([string]$Platform) {
    if ($Platform -like "windows-*") { return "zip" }
    return "tar.gz"
}

function Get-ReleaseManifestRepo {
    if ($env:LCOD_RELEASE_MANIFEST_REPO) { return $env:LCOD_RELEASE_MANIFEST_REPO }
    return "lcod-team/lcod-release"
}

function Get-ManifestCacheDir {
    return (Join-Path $CacheDir "manifests")
}

function Get-ReleaseManifest([string]$Version) {
    $cacheDir = Get-ManifestCacheDir
    if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir | Out-Null }
    $manifestPath = Join-Path $cacheDir ("release-{0}.json" -f $Version)
    if (Test-Path $manifestPath) { return $manifestPath }

    $repo = Get-ReleaseManifestRepo
    $url = "https://github.com/$repo/releases/download/v$Version/release-manifest.json"
    $tmp = "$manifestPath.tmp"
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -ErrorAction Stop | Out-Null
        Move-Item -LiteralPath $tmp -Destination $manifestPath -Force
        return $manifestPath
    }
    catch {
        if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force }
        return $null
    }
}

function Resolve-ManifestAssetUrl([string]$Version, [string]$KernelKey, [string]$AssetName) {
    $manifest = Get-ReleaseManifest $Version
    if (-not $manifest) { return $null }
    try {
        $json = Get-Content -Path $manifest -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch { return $null }

    $entry = $json.kernels.$KernelKey
    if (-not $entry) { return $null }
    foreach ($asset in $entry.assets) {
        if ($asset.name -eq $AssetName -and $asset.download_url) {
            return $asset.download_url
        }
    }
    return $null
}

function List-ManifestAssets([string]$Version, [string]$KernelKey) {
    $manifest = Get-ReleaseManifest $Version
    if (-not $manifest) { return @() }
    try {
        $json = Get-Content -Path $manifest -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch { return @() }
    $entry = $json.kernels.$KernelKey
    if (-not $entry) { return @() }
    return @($entry.assets | ForEach-Object { $_.name })
}

function Select-ManifestPlatformAsset([string]$Version, [string]$KernelKey, [string[]]$Prefixes) {
    $manifest = Get-ReleaseManifest $Version
    if (-not $manifest) { return $null }
    try {
        $json = Get-Content -Path $manifest -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch { return $null }
    $entry = $json.kernels.$KernelKey
    if (-not $entry) { return $null }
    foreach ($asset in $entry.assets) {
        $name = $asset.name
        foreach ($prefix in $Prefixes) {
            if ($name -like "$prefix*") {
                if ($asset.download_url) {
                    return [pscustomobject]@{ Name = $name; Url = $asset.download_url }
                }
            }
        }
    }
    return $null
}

function Get-ReleaseAssetUrl([string]$Repo, [string]$Version, [string]$Platform) {
    $ext = Get-AssetExtension $Platform
    return "https://github.com/$Repo/releases/download/lcod-run-v$Version/lcod-run-$Platform.$ext"
}

function Get-DefaultKernelRepo([string]$KernelId) {
    switch ($KernelId) {
        { $_ -in @('rs','rust') } { return $env:LCOD_RS_RELEASE_REPO ?? 'lcod-team/lcod-kernel-rs' }
        { $_ -in @('node','js') } { return $env:LCOD_NODE_RELEASE_REPO ?? 'lcod-team/lcod-kernel-js' }
        { $_ -in @('java','jvm') } { return $env:LCOD_JAVA_RELEASE_REPO ?? 'lcod-team/lcod-kernel-java' }
        default { return $null }
    }
}

function Get-LatestRuntimeVersion([string]$Repo) {
    $api = "https://api.github.com/repos/$Repo/releases/latest"
    try {
        $json = (Invoke-WebRequest -Uri $api -UseBasicParsing -ErrorAction Stop).Content | ConvertFrom-Json
        if (-not $json.tag_name) { throw "" }
        $tag = $json.tag_name -replace '^lcod-run-v', ''
        $tag = $tag -replace '^v', ''
        return $tag
    }
    catch {
        Write-ErrorMessage ("Unable to determine latest release for {0}" -f $Repo)
        return $null
    }
}

function Download-File([string]$Url, [string]$Destination) {
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
}

function Extract-Archive([string]$Archive, [string]$Destination) {
    if ($Archive.ToLower().EndsWith(".zip")) {
        Expand-Archive -Path $Archive -DestinationPath $Destination -Force
    }
    elseif ($Archive.ToLower().EndsWith(".tar.gz")) {
        if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
            throw "tar command is required to extract $Archive"
        }
        tar -xzf $Archive -C $Destination | Out-Null
    }
    else {
        throw "Unsupported archive format: $Archive"
    }
}

function Write-CliUpdateCache([string]$Version, [int]$Timestamp) {
    $payload = @{ version = $Version; lastCheck = $Timestamp }
    $payload | ConvertTo-Json | Set-Content -Path $CliUpdateCache -Encoding UTF8
}

function Get-CliUpdateCache {
    if (Test-Path $CliUpdateCache) {
        try {
            return (Get-Content -Path $CliUpdateCache -Raw | ConvertFrom-Json)
        }
        catch { return $null }
    }
    return $null
}

function Invoke-CliAutoUpdate {
    if ($env:LCOD_DISABLE_AUTO_UPDATE -eq '1') { return }
    if (Test-Path (Join-Path $RepoRoot '.git')) { return }

    $cache = Get-CliUpdateCache
    $lastCheck = if ($cache -and $cache.lastCheck) { [int]$cache.lastCheck } else { 0 }
    $cachedVersion = if ($cache -and $cache.version) { $cache.version } else { '' }
    $now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    if ($AutoUpdateInterval -gt 0 -and ($now - $lastCheck) -lt $AutoUpdateInterval) {
        return
    }

    $scriptPath = $MyInvocation.MyCommand.Path
    $tmp = [System.IO.Path]::GetTempFileName()
    $cliUrl = if ($env:LCOD_CLI_SCRIPT_URL) { $env:LCOD_CLI_SCRIPT_URL } else { "https://raw.githubusercontent.com/lcod-team/lcod-cli/main/dist/lcod" }

    try {
        $remoteVersion = Fetch-LatestVersion -Repo 'lcod-team/lcod-cli'
    }
    catch {
        $remoteVersion = $cachedVersion
    }

    try {
        Invoke-WebRequest -Uri $cliUrl -OutFile $tmp -UseBasicParsing
        Copy-Item -LiteralPath $tmp -Destination $scriptPath -Force
        if ($remoteVersion) { $cachedVersion = $remoteVersion }
        Write-Info ("CLI auto-updated to {0}." -f $cachedVersion)
        try {
            $libTmp = [System.IO.Path]::GetTempFileName()
            $libUrl = if ($env:LCOD_CLI_LIB_URL) { $env:LCOD_CLI_LIB_URL } else { "https://raw.githubusercontent.com/lcod-team/lcod-cli/main/scripts/lib/common.sh" }
            Invoke-WebRequest -Uri $libUrl -OutFile $libTmp -UseBasicParsing
            $libDir = Join-Path (Split-Path $scriptPath -Parent) "lib"
            New-Item -ItemType Directory -Path $libDir -Force | Out-Null
            Copy-Item -LiteralPath $libTmp -Destination (Join-Path $libDir "common.sh") -Force
            Remove-Item -Force $libTmp
        }
        catch {
            Write-Warn "Failed to refresh CLI support library."
        }
    }
    catch {
        Write-Warn "CLI auto-update failed (insufficient permissions?)."
    }
    finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $tmp
    }

    Write-CliUpdateCache $cachedVersion $now
}

function Get-KernelCache([string]$KernelId) {
    if (Test-Path $KernelUpdateCache) {
        try {
            $cache = Get-Content -Path $KernelUpdateCache -Raw | ConvertFrom-Json
            if ($cache.kernels) { return $cache.kernels.$KernelId }
        }
        catch { return $null }
    }
    return $null
}

function Write-KernelCache([string]$KernelId, [string]$Version, [int]$Timestamp) {
    $cache = if (Test-Path $KernelUpdateCache) {
        try { Get-Content -Path $KernelUpdateCache -Raw | ConvertFrom-Json }
        catch { @{ kernels = @{} } }
    } else { @{ kernels = @{} } }
    if (-not $cache.kernels) { $cache.kernels = @{} }
    $cache.kernels.$KernelId = @{ version = $Version; lastCheck = $Timestamp }
    $cache | ConvertTo-Json -Depth 6 | Set-Content -Path $KernelUpdateCache -Encoding UTF8
}

function AutoUpdate-KernelIfNeeded([string]$KernelId) {
    if ($env:LCOD_DISABLE_AUTO_UPDATE -eq '1') { return }

    $repo = Get-DefaultKernelRepo $KernelId
    if (-not $repo) { return }

    $cacheEntry = Get-KernelCache $KernelId
    $lastCheck = if ($cacheEntry -and $cacheEntry.lastCheck) { [int]$cacheEntry.lastCheck } else { 0 }
    $now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    if ($AutoUpdateInterval -gt 0 -and ($now - $lastCheck) -lt $AutoUpdateInterval) {
        return
    }

    $config = Get-Config
    $kernelEntry = $config.installedKernels | Where-Object { $_.id -eq $KernelId } | Select-Object -First 1
    if (-not $kernelEntry) {
        Write-KernelCache $KernelId $null $now
        return
    }

    $currentVersion = $kernelEntry.version
    try {
        $remoteVersion = Get-LatestRuntimeVersion $repo
    }
    catch {
        Write-KernelCache $KernelId $currentVersion $now
        return
    }

    if ($remoteVersion -and $remoteVersion -ne $currentVersion) {
        Write-Info ("Auto-updating kernel '{0}' to {1}." -f $KernelId, $remoteVersion)
        Kernel-Install @($KernelId, '--from-release', '--version', $remoteVersion, '--repo', $repo, '--force')
        $currentVersion = $remoteVersion
    }

    Write-KernelCache $KernelId $currentVersion $now
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
  kernel install <id>   Install or update a kernel (local path or release asset).
  kernel remove <id>    Remove a kernel from the manifest.
  kernel default <id>   Set the default kernel.
  run [options]         Execute the default kernel runtime with the given arguments.
  cache clean           Clear cached artefacts.
  self-update           Force immediate update check (placeholder).
  help                  Show this help message.

Most commands are still placeholders until installation logic lands.
"@
}

function Kernel-Install([string[]]$Args) {
    if ($Args.Length -lt 2) {
        Write-ErrorMessage "Usage: lcod kernel install <kernel-id> [--path <binary> | --from-release] [--version <version>] [--platform <id>] [--repo <owner/repo>] [--force]"
        exit 1
    }

    $kernelId = $Args[1]
    $sourcePath = $null
    $kernelVersion = $null
    $force = $false
    $fromRelease = $false
    $platformId = $null
    $releaseRepo = $env:LCOD_RELEASE_REPO
    $tempDir = $null
    $assetPath = $null
    $fromReleaseDefault = $false

    if (-not $releaseRepo) {
        $mappedRepo = Get-DefaultKernelRepo $kernelId
        if ($mappedRepo) {
            $releaseRepo = $mappedRepo
            $fromReleaseDefault = $true
        }
    }

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
            "--from-release" { $fromRelease = $true }
            "--version" {
                if ($i + 1 -ge $Args.Length) {
                    Write-ErrorMessage "--version requires a value."
                    exit 1
                }
                $kernelVersion = $Args[$i + 1]
                $i++
            }
            "--platform" {
                if ($i + 1 -ge $Args.Length) {
                    Write-ErrorMessage "--platform requires a value."
                    exit 1
                }
                $platformId = $Args[$i + 1]
                $i++
            }
            "--repo" {
                if ($i + 1 -ge $Args.Length) {
                    Write-ErrorMessage "--repo requires a value."
                    exit 1
                }
                $releaseRepo = $Args[$i + 1]
                $i++
            }
            "--force" { $force = $true }
            "-h" { Write-Info "Usage: lcod kernel install <kernel-id> [--path <binary> | --from-release] [--version <version>] [--platform <id>] [--repo <owner/repo>] [--force]"; return }
            "--help" { Write-Info "Usage: lcod kernel install <kernel-id> [--path <binary> | --from-release] [--version <version>] [--platform <id>] [--repo <owner/repo>] [--force]"; return }
            default {
                Write-ErrorMessage ("Unknown option '{0}' for kernel install." -f $Args[$i])
                exit 1
            }
        }
    }

    Ensure-State
    $config = Get-Config
    $existingEntry = $config.installedKernels | Where-Object { $_.id -eq $kernelId } | Select-Object -First 1
    $existingVersion = if ($existingEntry) { $existingEntry.version } else { $null }
    $destination = Join-Path $BinDir $kernelId

    if (-not $fromRelease -and -not $sourcePath -and $fromReleaseDefault) {
        $fromRelease = $true
    }

    if ($fromRelease) {
        if (-not $releaseRepo) {
            Write-ErrorMessage "No release repository configured; use --repo <owner/repo>."
            exit 1
        }

        if (-not $kernelVersion) {
            $kernelVersion = Get-LatestRuntimeVersion $releaseRepo
            if (-not $kernelVersion) {
                exit 1
            }
        }

        if (-not $force -and $existingVersion -and $existingVersion -eq $kernelVersion) {
            Write-Info ("Kernel '{0}' already installed at {1} (version {2}). Nothing to do." -f $kernelId, $destination, $existingVersion)
            return
        }

        $cacheDir = Join-Path $CacheDir (Join-Path "releases" $kernelVersion)
        if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir | Out-Null }

        $assetName = $null
        $assetUrl = $null
        $tag = $null

        switch -Regex ($kernelId) {
            '^(rs|rust)$' {
                if (-not $platformId -or $platformId -eq "auto") {
                    try {
                        $platformId = Get-DetectedPlatform
                    }
                    catch {
                        Write-ErrorMessage $_.Exception.Message
                        exit 1
                    }
                }
                $selection = Select-ManifestPlatformAsset $kernelVersion "rs" @("lcod-run-$platformId")
                if ($selection) {
                    $assetName = $selection.Name
                    $assetUrl = $selection.Url
                }
                if (-not $assetName) {
                    $extension = Get-AssetExtension $platformId
                    $assetName = "lcod-run-$platformId.$extension"
                    $assetUrl = Resolve-ManifestAssetUrl $kernelVersion "rs" $assetName
                    if (-not $assetUrl) {
                        $tag = "lcod-run-v$kernelVersion"
                        $assetUrl = Get-ReleaseAssetUrl $releaseRepo $kernelVersion $platformId
                        $available = List-ManifestAssets $kernelVersion "rs"
                        if ($available -and -not $force) {
                            $list = ($available -join ", ")
                            Write-ErrorMessage ("No release asset '{0}' found in manifest. Available assets: {1}" -f $assetName, $list)
                            exit 1
                        }
                    }
                }
                if (-not $assetUrl) {
                    $tag = "lcod-run-v$kernelVersion"
                    $assetUrl = Get-ReleaseAssetUrl $releaseRepo $kernelVersion $platformId
                }
                break
            }
            '^(node|js)$' {
                $tag = "v$kernelVersion"
                $selection = Select-ManifestPlatformAsset $kernelVersion "js" @("lcod-kernel-js-runtime-$kernelVersion", "lcod-kernel-js-runtime")
                if ($selection) {
                    $assetName = $selection.Name
                    $assetUrl = $selection.Url
                }
                if (-not $assetName) {
                    $assetName = "lcod-kernel-js-runtime-$kernelVersion.tar.gz"
                    $assetUrl = Resolve-ManifestAssetUrl $kernelVersion "js" $assetName
                    if (-not $assetUrl) {
                        $available = List-ManifestAssets $kernelVersion "js"
                        if ($available -and -not $force) {
                            $list = ($available -join ", ")
                            Write-ErrorMessage ("Node runtime asset '{0}' missing in manifest. Available assets: {1}" -f $assetName, $list)
                            exit 1
                        }
                        $assetUrl = "https://github.com/$releaseRepo/releases/download/$tag/$assetName"
                    }
                }
                break
            }
            '^(java|jvm)$' {
                $tag = "v$kernelVersion"
                $selection = Select-ManifestPlatformAsset $kernelVersion "java" @("lcod-run-$kernelVersion")
                if ($selection) {
                    $assetName = $selection.Name
                    $assetUrl = $selection.Url
                }
                if (-not $assetName) {
                    $assetName = "lcod-run-$kernelVersion.jar"
                    $assetUrl = Resolve-ManifestAssetUrl $kernelVersion "java" $assetName
                    if (-not $assetUrl) {
                        $available = List-ManifestAssets $kernelVersion "java"
                        if ($available -and -not $force) {
                            $list = ($available -join ", ")
                            Write-ErrorMessage ("Java runtime asset '{0}' missing in manifest. Available assets: {1}" -f $assetName, $list)
                            exit 1
                        }
                        $assetUrl = "https://github.com/$releaseRepo/releases/download/$tag/$assetName"
                    }
                }
                break
            }
            default {
                Write-ErrorMessage "Kernel '${kernelId}' is not supported for release installation."
                exit 1
            }
        }

        $assetPath = Join-Path $cacheDir $assetName

        if ($force -or -not (Test-Path $assetPath)) {
            Write-Info ("Downloading {0}" -f $assetUrl)
            try { Download-File $assetUrl $assetPath }
            catch {
                Write-ErrorMessage ("Failed to download {0}" -f $assetUrl)
                exit 1
            }
        }
        else {
            Write-Info ("Using cached asset {0}" -f $assetPath)
        }

        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("lcod-cli-" + [System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $tempDir | Out-Null

        switch -Regex ($kernelId) {
            '^(rs|rust)$' {
                try { Extract-Archive $assetPath $tempDir }
                catch {
                    if ($tempDir) { Remove-Item -Recurse -Force $tempDir }
                    Write-ErrorMessage $_.Exception.Message
                    exit 1
                }

                $candidate = Get-ChildItem -Path $tempDir -Recurse -File |
                    Where-Object { $_.Name -match '^lcod-run(\.exe)?$' } |
                    Select-Object -First 1

                if (-not $candidate) {
                    if ($tempDir) { Remove-Item -Recurse -Force $tempDir }
                    Write-ErrorMessage "Unable to locate lcod-run binary inside the archive."
                    exit 1
                }
                $sourcePath = $candidate.FullName
                break
            }
            '^(node|js)$' {
                try { Extract-Archive $assetPath $tempDir }
                catch {
                    if ($tempDir) { Remove-Item -Recurse -Force $tempDir }
                    Write-ErrorMessage $_.Exception.Message
                    exit 1
                }

                $runtimeManifest = Get-ChildItem -Path $tempDir -Recurse -Filter manifest.json -File | Select-Object -First 1
                if (-not $runtimeManifest) {
                    if ($tempDir) { Remove-Item -Recurse -Force $tempDir }
                    Write-ErrorMessage "Downloaded runtime archive does not contain a manifest (lcod-kernel-js-runtime)."
                    exit 1
                }
                $runtimeRoot = Split-Path -Parent $runtimeManifest.FullName
                $kernelCacheDir = Join-Path $CacheDir (Join-Path "kernels" (Join-Path $kernelId $kernelVersion))
                if (Test-Path $kernelCacheDir) { Remove-Item -LiteralPath $kernelCacheDir -Recurse -Force }
                New-Item -ItemType Directory -Path $kernelCacheDir | Out-Null
                $runtimeDestination = Join-Path $kernelCacheDir "runtime"
                Move-Item -LiteralPath $runtimeRoot -Destination $runtimeDestination

                $sourceCacheDir = Join-Path $CacheDir (Join-Path "sources" $kernelId)
                if (-not (Test-Path $sourceCacheDir)) { New-Item -ItemType Directory -Path $sourceCacheDir | Out-Null }
                $sourceArchive = Join-Path $sourceCacheDir ("{0}.tar.gz" -f $kernelVersion)
                $tag = if ($tag) { $tag } else { "v$kernelVersion" }
                $sourceArchiveUrl = "https://github.com/$releaseRepo/archive/refs/tags/$tag.tar.gz"
                if ($force -or -not (Test-Path $sourceArchive)) {
                    Write-Info ("Downloading Node kernel sources from {0}" -f $sourceArchiveUrl)
                    $tmpSource = "$sourceArchive.tmp"
                    try {
                        Download-File $sourceArchiveUrl $tmpSource
                        Move-Item -LiteralPath $tmpSource -Destination $sourceArchive -Force
                    }
                    catch {
                        if (Test-Path $tmpSource) { Remove-Item -LiteralPath $tmpSource -Force }
                        if ($tempDir) { Remove-Item -Recurse -Force $tempDir }
                        Write-ErrorMessage ("Failed to download Node kernel sources from {0}" -f $sourceArchiveUrl)
                        exit 1
                    }
                }
                else {
                    Write-Info ("Using cached Node kernel sources {0}" -f $sourceArchive)
                }

                $sourceRootDir = Join-Path $kernelCacheDir "source"
                if (Test-Path $sourceRootDir) { Remove-Item -LiteralPath $sourceRootDir -Recurse -Force }
                New-Item -ItemType Directory -Path $sourceRootDir | Out-Null
                try { Extract-Archive $sourceArchive $sourceRootDir }
                catch {
                    if ($tempDir) { Remove-Item -Recurse -Force $tempDir }
                    Write-ErrorMessage "Unable to extract Node kernel sources archive"
                    exit 1
                }

                $nodeSourceRoot = Get-ChildItem -Path $sourceRootDir -Directory | Select-Object -First 1
                if (-not $nodeSourceRoot) {
                    if ($tempDir) { Remove-Item -Recurse -Force $tempDir }
                    Write-ErrorMessage "Unable to locate Node kernel source directory after extraction"
                    exit 1
                }

                Write-Info "Installing Node kernel dependencies via npm"
                Push-Location $nodeSourceRoot.FullName
                try {
                    & npm ci --omit=dev *> $null
                }
                catch {
                    try { & npm install --production *> $null }
                    catch {
                        Pop-Location
                        if ($tempDir) { Remove-Item -Recurse -Force $tempDir }
                        Write-ErrorMessage "Failed to install Node kernel dependencies"
                        exit 1
                    }
                }
                Pop-Location

                $wrapperPath = Join-Path $tempDir "lcod-run.ps1"
                $runtimePath = $runtimeDestination
                $nodeSourcePath = Join-Path $nodeSourceRoot.FullName "bin/run-compose.mjs"
                $wrapperContent = @"
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]`
    `$Forward
)

$env:LCOD_HOME = "${runtimePath}"
$env:SPEC_REPO_PATH = "${runtimePath}"
if (-not $env:LCOD_RESOLVER_PATH) {
    $env:LCOD_RESOLVER_PATH = "${runtimePath}\resolver"
}

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-Error "Node.js is required to run this kernel."
    exit 1
}

& $node.Path "${nodeSourcePath}" --core --resolver @Forward
exit $LASTEXITCODE
"@
                Set-Content -Path $wrapperPath -Value $wrapperContent -Encoding UTF8
                $sourcePath = $wrapperPath
                break
            }
            '^(java|jvm)$' {
                $kernelCacheDir = Join-Path $CacheDir (Join-Path "kernels" (Join-Path $kernelId $kernelVersion))
                if (Test-Path $kernelCacheDir) { Remove-Item -LiteralPath $kernelCacheDir -Recurse -Force }
                New-Item -ItemType Directory -Path $kernelCacheDir | Out-Null
                $javaJar = Join-Path $kernelCacheDir ("lcod-run-$kernelVersion.jar")
                Copy-Item -LiteralPath $assetPath -Destination $javaJar -Force
                $sourcePath = $javaJar
                break
            }
        }
    }

    if (-not $sourcePath) {
        Write-ErrorMessage "Provide --path <binary> or --from-release."
        if ($tempDir) { Remove-Item -Recurse -Force $tempDir }
        exit 1
    }

    if (-not (Test-Path $sourcePath)) {
        if ($tempDir) { Remove-Item -Recurse -Force $tempDir }
        Write-ErrorMessage ("Source binary not found at {0}" -f $sourcePath)
        exit 1
    }

    if ((Test-Path $destination) -and -not $force) {
        if ($existingVersion -and $kernelVersion -and $existingVersion -eq $kernelVersion) {
            Write-Info ("Kernel '{0}' already installed at {1} (version {2}). Nothing to do." -f $kernelId, $destination, $existingVersion)
            if ($tempDir) { Remove-Item -Recurse -Force $tempDir }
            return
        }
        if ($tempDir) { Remove-Item -Recurse -Force $tempDir }
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
    if ($fromRelease -and $assetPath) {
        Write-Info ("Source: {0}" -f $assetPath)
    }

    if ($tempDir) { Remove-Item -Recurse -Force $tempDir }

    $timestamp = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Write-KernelCache $kernelId $kernelVersion $timestamp
}

function Get-KernelType([string]$Path, [string]$KernelId) {
    if ($KernelId -in @('node','js')) { return 'node' }
    if ($KernelId -in @('java','jvm')) { return 'java' }
    if (-not $Path) { return "native" }
    $lower = $Path.ToLowerInvariant()
    if ($lower.EndsWith(".jar")) { return "java" }
    switch -Wildcard ($lower) {
        "*.cmd" { return "node" }
        "*.bat" { return "node" }
        "*.ps1" { return "node" }
        "*.mjs" { return "node" }
        "*.cjs" { return "node" }
        "*.js"  { return "node" }
        "*.exe" { return "native" }
    }
    try {
        $firstLine = Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop
        if ($firstLine -match '^\#!/') { return "node" }
    }
    catch { }
    return "native"
}

function Convert-KeyValuePairsToJson([string[]]$Pairs) {
    if (-not $Pairs -or $Pairs.Count -eq 0) { return $null }
    $map = [ordered]@{}
    foreach ($pair in $Pairs) {
        if (-not $pair.Contains("=")) {
            return $null
        }
        $split = $pair.Split("=", 2)
        $key = $split[0]
        $raw = $split[1]
        $trimmed = $raw.Trim()
        if ($trimmed -match '^(?i)(json:|@json:).*') {
            $payload = $trimmed.Substring($trimmed.IndexOf(':') + 1)
            try {
                $map[$key] = $payload | ConvertFrom-Json -ErrorAction Stop
                continue
            }
            catch { }
        }
        if ($trimmed -match '^(?i)(true|false|null)$') {
            try {
                $map[$key] = $trimmed | ConvertFrom-Json -ErrorAction Stop
                continue
            }
            catch { }
        }
        if ($trimmed -match '^[-+]?[0-9]+(\.[0-9]+)?$') {
            try {
                $map[$key] = $trimmed | ConvertFrom-Json -ErrorAction Stop
                continue
            }
            catch { }
        }
        $map[$key] = $raw
    }
    return ($map | ConvertTo-Json -Depth 10 -Compress)
}

function Requires-FlagValue([string]$Flag) {
    $flags = @('--compose','-c','--state','-s','--modules','-m','--bind','-b','--project','--config','--output','--cache-dir','--sources','--timeout','--log-level','--input','--kernel')
    return $flags -contains $Flag
}

function Invoke-JsonExtraction([string]$Path) {
    if (-not (Test-Path $Path)) { return $false }
    $data = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrEmpty($data)) { return $false }
    $candidate = $null
    for ($pos = 0; $pos -lt $data.Length; $pos++) {
        if ($data[$pos] -ne "{") { continue }
        $substring = $data.Substring($pos)
        try {
            $doc = [System.Text.Json.JsonDocument]::Parse($substring)
        }
        catch { continue }
        $jsonText = $doc.RootElement.GetRawText()
        $endPos = $pos + $jsonText.Length
        if (-not $candidate -or $endPos -gt $candidate.End) {
            if ($candidate) { $candidate.Doc.Dispose() }
            $candidate = [pscustomobject]@{ Start = $pos; End = $endPos; JsonText = $jsonText; Doc = $doc }
        }
        else {
            $doc.Dispose()
        }
    }
    if (-not $candidate) { return $false }
    $start = $candidate.Start
    $end = $candidate.End
    $logs = ""
    if ($start -gt 0) { $logs += $data.Substring(0, $start) }
    if ($end -lt $data.Length) { $logs += $data.Substring($end) }
    if (-not [string]::IsNullOrWhiteSpace($logs)) {
        [Console]::Error.Write($logs)
        if (-not $logs.EndsWith("`n")) { [Console]::Error.WriteLine() }
    }
    $stream = [System.IO.MemoryStream]::new()
    $options = [System.Text.Json.JsonWriterOptions]::new()
    $options.Indented = $true
    $writer = [System.Text.Json.Utf8JsonWriter]::new($stream, $options)
    $candidate.Doc.RootElement.WriteTo($writer)
    $writer.Flush()
    $output = [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
    Write-Output $output
    $writer.Dispose()
    $stream.Dispose()
    $candidate.Doc.Dispose()
    return $true
}
function Run-Kernel([string[]]$Args) {
    Ensure-State
    $kernelId = $null
    $forward = @()

    for ($i = 0; $i -lt $Args.Length; $i++) {
        $arg = $Args[$i]
        if ($arg -eq "--kernel") {
            if ($i + 1 -ge $Args.Length) {
                Write-ErrorMessage "--kernel requires a value."
                exit 1
            }
            $kernelId = $Args[$i + 1]
            $i++
            continue
        }
        elseif ($arg -eq "--help" -or $arg -eq "-h") {
            Write-Info "Usage: lcod run [--kernel <id>] [--] <args...>"
            return
        }
        elseif ($arg -eq "--") {
            if ($i + 1 -lt $Args.Length) {
                $forward = $Args[($i + 1)..($Args.Length - 1)]
            }
            break
        }
        else {
            $forward = $Args[$i..($Args.Length - 1)]
            break
        }
    }

    if (-not $kernelId) {
        $kernelId = (Get-Config).defaultKernel
    }

    if (-not $kernelId) {
        Write-ErrorMessage "No default kernel configured. Install one or pass --kernel <id>."
        exit 1
    }

    $config = Get-Config
    if (-not (Kernel-Exists $config $kernelId)) {
        Write-ErrorMessage ("Kernel '{0}' is not registered. Install it first." -f $kernelId)
        exit 1
    }

    AutoUpdate-KernelIfNeeded $kernelId
    $config = Get-Config

    $kernelPath = Get-KernelPath $config $kernelId
    if (-not $kernelPath -or -not (Test-Path $kernelPath)) {
        Write-ErrorMessage ("Kernel binary for '{0}' not found at {1}." -f $kernelId, $kernelPath)
        exit 1
    }

    $kernelType = Get-KernelType $kernelPath $kernelId

    $hasComposeFlag = $false
    foreach ($arg in $forward) {
        if ($arg -eq "--compose" -or $arg -eq "-c") {
            $hasComposeFlag = $true
            break
        }
    }

    $composeValue = $null
    $kvPairs = New-Object System.Collections.Generic.List[string]
    $remaining = New-Object System.Collections.Generic.List[string]
    $afterDelim = $false
    $expectComposeValue = $false
    $expectFlagValue = $false

    foreach ($arg in $forward) {
        if ($afterDelim) {
            $remaining.Add($arg)
            continue
        }
        if ($expectComposeValue) {
            $remaining.Add($arg)
            $expectComposeValue = $false
            continue
        }
        if ($expectFlagValue) {
            $remaining.Add($arg)
            $expectFlagValue = $false
            continue
        }
        switch ($arg) {
            "--" {
                $afterDelim = $true
                $remaining.Add($arg)
                continue
            }
            "--compose" {
                $remaining.Add($arg)
                $expectComposeValue = $true
                continue
            }
            "-c" {
                $remaining.Add($arg)
                $expectComposeValue = $true
                continue
            }
        }
        if ($arg.StartsWith("-")) {
            $remaining.Add($arg)
            if (Requires-FlagValue($arg)) {
                $expectFlagValue = $true
            }
            continue
        }
        if (-not $hasComposeFlag -and -not $composeValue) {
            $composeValue = $arg
            continue
        }
        if (-not $hasComposeFlag -and $arg.Contains("=")) {
            $kvPairs.Add($arg)
            continue
        }
        $remaining.Add($arg)
    }

    $inlineJson = $null
    if ($kvPairs.Count -gt 0) {
        $inlineJson = Convert-KeyValuePairsToJson $kvPairs.ToArray()
        if (-not $inlineJson) {
            Write-Warn "Unable to parse inline arguments into JSON; forwarding raw values."
            foreach ($pair in $kvPairs) { $remaining.Add($pair) }
            $inlineJson = $null
        }
    }

    $finalArgs = New-Object System.Collections.Generic.List[string]
    if ($composeValue) {
        $finalArgs.Add("--compose")
        $finalArgs.Add($composeValue)
    }
    if ($inlineJson) {
        $flag = if ($kernelType -eq "node") { "--state" } else { "--input" }
        $finalArgs.Add($flag)
        $finalArgs.Add($inlineJson)
    }
    if ($remaining.Count -gt 0) {
        $finalArgs.AddRange($remaining)
    }
    $forward = $finalArgs.ToArray()

    $command = $null
    $cmdArgs = @()
    switch -Wildcard ($kernelPath.ToLower()) {
        "*.jar" {
            $command = "java"
            $cmdArgs = @("-jar", $kernelPath)
        }
        "*.mjs" { $command = "node"; $cmdArgs = @($kernelPath) }
        "*.cjs" { $command = "node"; $cmdArgs = @($kernelPath) }
        "*.js"  { $command = "node"; $cmdArgs = @($kernelPath) }
        "*.ps1" {
            $command = (Get-Command pwsh -ErrorAction SilentlyContinue) ? "pwsh" : "powershell"
            $cmdArgs = @("-File", $kernelPath)
        }
        "*.cmd" { $command = $kernelPath }
        "*.bat" { $command = $kernelPath }
        default {
            $command = $kernelPath
        }
    }

    if ($forward) {
        $cmdArgs += $forward
    }

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    & $command @cmdArgs 1> $stdoutFile 2> $stderrFile
    $status = $LASTEXITCODE
    if ((Get-Item $stderrFile).Length -gt 0) {
        [Console]::Error.Write((Get-Content -LiteralPath $stderrFile -Raw))
    }
    if (-not (Invoke-JsonExtraction $stdoutFile)) {
        if ((Get-Item $stdoutFile).Length -gt 0) {
            Get-Content -LiteralPath $stdoutFile
        }
    }
    Remove-Item $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
    exit $status
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
Invoke-CliAutoUpdate

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
    "run" { Run-Kernel $Args }
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
