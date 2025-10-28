param(
    [string]$InstallDir
)

$ErrorActionPreference = 'Stop'

function Write-Info($Message) {
    Write-Host "[install] $Message"
}

function Write-Err($Message) {
    Write-Error $Message
}

$baseUrl = if ($env:LCOD_BASE_URL) { $env:LCOD_BASE_URL } else { "https://raw.githubusercontent.com/lcod-team/lcod-cli/main" }
$scriptName = "lcod.ps1"
$cmdShimName = "lcod.cmd"
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("lcod-cli-" + [Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tmpDir | Out-Null
try {
    if ($env:LCOD_SOURCE -and (Test-Path (Join-Path $env:LCOD_SOURCE "powershell/$scriptName"))) {
        Copy-Item -LiteralPath (Join-Path $env:LCOD_SOURCE "powershell/$scriptName") -Destination (Join-Path $tmpDir $scriptName)
    }
    else {
        $psUrl = "$baseUrl/powershell/$scriptName"
        Invoke-WebRequest -Uri $psUrl -OutFile (Join-Path $tmpDir $scriptName) -UseBasicParsing
    }

    function Get-Candidates {
        param([string]$Override)
        $list = @()
        if ($Override) { $list += $Override }
        if ($env:LCOD_INSTALL_DIR) { $list += $env:LCOD_INSTALL_DIR }
        $existing = Get-Command lcod -ErrorAction SilentlyContinue
        if ($existing) { $list += (Split-Path $existing.Path) }
        $list += (Join-Path $HOME ".local\bin")
        $list += (Join-Path $HOME "bin")
        $list += (Join-Path $HOME "AppData\Local\lcod\bin")
        foreach ($entry in ($env:PATH -split ';')) {
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            if ($entry.StartsWith($HOME)) { $list += $entry }
        }
        $list | Where-Object { $_ } | Select-Object -Unique
    }

    function Ensure-Directory([string]$Dir) {
        if (-not (Test-Path $Dir)) {
            New-Item -ItemType Directory -Path $Dir | Out-Null
        }
        $acl = Get-Acl $Dir
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        return (Test-Path $Dir -PathType Container) -and ((Get-Acl $Dir).Access | Where-Object { $_.IdentityReference -eq $user -and $_.FileSystemRights.ToString().Contains('Write') })
    }

    $installed = $false
    foreach ($dir in (Get-Candidates -Override $InstallDir)) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        if (-not (Test-Path $dir)) {
            try { New-Item -ItemType Directory -Path $dir | Out-Null } catch { continue }
        }
        if (-not (Test-Path $dir -PathType Container)) { continue }
        try {
            $dest = Join-Path $dir $scriptName
            Copy-Item -LiteralPath (Join-Path $tmpDir $scriptName) -Destination $dest -Force
            $cmdContent = "@echo off`npwsh -NoProfile -File `"%~dp0\$scriptName`" %*"
            Set-Content -Path (Join-Path $dir $cmdShimName) -Value $cmdContent -Encoding ASCII
            Write-Info "Installed lcod to $dir"
            if (($env:PATH -split ';') -notcontains $dir) {
                Write-Info "Add $dir to your PATH if it's not present already."
            }
            $installed = $true
            break
        }
        catch {
            continue
        }
    }

    if (-not $installed) {
        Write-Err "Could not find a writable directory to install lcod. Set LCOD_INSTALL_DIR to override."
        exit 1
    }
}
finally {
    Remove-Item -Recurse -Force $tmpDir
}
