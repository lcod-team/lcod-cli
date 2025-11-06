param(
    [string]$ComposeId = "lcod://tooling/json/decode_object@0.1.0"
)

function Write-Skip {
    param([string]$Message)
    Write-Host "[skip] $Message"
}

if (-not (Split-Path -Parent $PSCommandPath)) {
    Write-Skip "Cannot resolve script directory."
    exit 0
}

$RootDir = Resolve-Path (Join-Path (Split-Path -Parent $PSCommandPath) "..")
$CliPath = Join-Path $RootDir "powershell/lcod.ps1"

if (-not (Test-Path $CliPath)) {
    Write-Skip "CLI PowerShell entrypoint not found ($CliPath)."
    exit 0
}

$KernelPath = if ($env:LCOD_TEST_KERNEL_PATH) { $env:LCOD_TEST_KERNEL_PATH } else { Join-Path $HOME ".lcod/bin/rs" }
if (-not (Test-Path $KernelPath)) {
    Write-Skip "Kernel binary not found at $KernelPath."
    exit 0
}

if (-not (Get-Command ConvertTo-Json -ErrorAction SilentlyContinue)) {
    Write-Skip "PowerShell JSON cmdlets unavailable."
    exit 0
}

$stateDir = Join-Path ([System.IO.Path]::GetTempPath()) ("lcod-cli-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$configPath = Join-Path $stateDir "config.json"

$config = @{
    defaultKernel   = "test-rs"
    installedKernels = @(
        @{
            id      = "test-rs"
            version = "dev-local"
            path    = $KernelPath
        }
    )
    lastUpdateCheck = $null
}
$config | ConvertTo-Json -Depth 5 | Set-Content -Path $configPath -Encoding UTF8

$env:LCOD_STATE_DIR = $stateDir
$env:LCOD_BIN_DIR = Join-Path $stateDir "bin"
$env:LCOD_CACHE_DIR = Join-Path $stateDir "cache"
$env:LCOD_AUTO_UPDATE_INTERVAL = "31536000"
New-Item -ItemType Directory -Path $env:LCOD_BIN_DIR -Force | Out-Null
New-Item -ItemType Directory -Path $env:LCOD_CACHE_DIR -Force | Out-Null

$specRepo = $env:LCOD_TEST_SPEC_PATH
if (-not $specRepo) {
    $candidate = Join-Path $RootDir "..\\lcod-spec"
    if (Test-Path $candidate) {
        $specRepo = (Resolve-Path $candidate).Path
    }
}
if ($specRepo) {
    $env:SPEC_REPO_PATH = $specRepo
    $env:LCOD_HOME = $specRepo
    $env:LCOD_RESOLVER_PATH = Join-Path $specRepo "resolver"
}

try {
    $stdout = & $CliPath run $ComposeId 'text={"success":true}'
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "lcod run exited with code $exitCode"
    }

    $result = $stdout | ConvertFrom-Json
    if (-not $result) {
        throw "Unable to parse CLI output as JSON."
    }

    $keys = @($result.PSObject.Properties.Name | Sort-Object)
    $expected = @('error','value','warnings')
    if (($keys -join ',') -ne ($expected | Sort-Object -join ',')) {
        throw ("Unexpected JSON keys: {0}" -f ($keys -join ', '))
    }

    if ($result.error -ne $null) {
        throw "Expected null error field."
    }

    if (-not ($result.value.success -eq $true)) {
        throw "Expected value.success == true."
    }

    $warnings = $result.warnings
    if ($warnings -and $warnings.Count -ne 0) {
        throw "Expected warnings array to be empty."
    }

    Write-Host "[pass] PowerShell projection test"
}
finally {
    if (Test-Path $stateDir) {
        Remove-Item $stateDir -Recurse -Force
    }
}
