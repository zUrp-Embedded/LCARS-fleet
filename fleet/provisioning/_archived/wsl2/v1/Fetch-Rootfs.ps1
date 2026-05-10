# Fetch-Rootfs.ps1 — Downloads Ubuntu WSL rootfs to #9_sources\
#
# Source  : cdimages.ubuntu.com/ubuntu-wsl/<codename>/daily-live/current/
# Format  : .wsl (Ubuntu standard since WSL 2.4 — directly importable by wsl --import)
# Verifies SHA256 before accepting the download.
# On network failure: prints manual URL and exits with a clear message.
#
# Usage:
#   .\provisioning\wsl2\Fetch-Rootfs.ps1                          # 24.04 LTS (noble), amd64
#   .\provisioning\wsl2\Fetch-Rootfs.ps1 -Codename oracular       # 24.10, amd64
#   .\provisioning\wsl2\Fetch-Rootfs.ps1 -Codename noble -Arch arm64
#
# To update for 26.04 LTS when released: -Codename <new-codename>

param(
    [string]$Codename = "noble",
    [string]$Arch     = "amd64"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function info  { param($m) Write-Host "[INFO]  $m" -ForegroundColor Green  }
function warn  { param($m) Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function fail  { param($m) Write-Host "[ERROR] $m" -ForegroundColor Red    }

# ─── Paths ────────────────────────────────────────────────────────────────────
$ConfigFile = Join-Path $PSScriptRoot "..\..\config.local.ps1"
if (Test-Path $ConfigFile) { . (Resolve-Path $ConfigFile) }
else {
    $WSL_ROOT = (Read-Host "WSL root directory (ex: C:\Users\$env:USERNAME\WSL)").Trim()
}
$WslRoot    = $WSL_ROOT
$SourcesDir = Join-Path $WslRoot "#9_sources"

if (-not (Test-Path $SourcesDir)) {
    New-Item -ItemType Directory -Path $SourcesDir | Out-Null
    info "Created $SourcesDir"
}

# ─── URLs ─────────────────────────────────────────────────────────────────────
$BaseUrl  = "https://cdimages.ubuntu.com/ubuntu-wsl/$Codename/daily-live/current"
$Filename = "$Codename-wsl-$Arch.wsl"
$FileUrl  = "$BaseUrl/$Filename"
$SumsUrl  = "$BaseUrl/SHA256SUMS"
$DestPath = Join-Path $SourcesDir $Filename

$ManualMsg = @"

  Manual download:
    URL  : $FileUrl
    Save : $DestPath
    Then verify SHA256 against: $SumsUrl
"@

# ─── SHA256SUMS ───────────────────────────────────────────────────────────────
info "Fetching checksum from $SumsUrl"
try {
    $sumsContent = (Invoke-WebRequest -Uri $SumsUrl -UseBasicParsing -TimeoutSec 30).Content
} catch {
    fail "Cannot reach checksum file: $_"
    Write-Host $ManualMsg
    exit 1
}

$ExpectedHash = $null
foreach ($line in ($sumsContent -split "`n")) {
    if ($line.Trim() -match "^([0-9a-f]{64})\s+\*?$([regex]::Escape($Filename))$") {
        $ExpectedHash = $Matches[1]
        break
    }
}

if (-not $ExpectedHash) {
    fail "'$Filename' not found in SHA256SUMS. Available entries:"
    Write-Host $sumsContent
    Write-Host $ManualMsg
    exit 1
}
info "Expected SHA256: $ExpectedHash"

# ─── Skip if already present and valid ────────────────────────────────────────
if (Test-Path $DestPath) {
    info "File already present — verifying..."
    $actual = (Get-FileHash -Algorithm SHA256 $DestPath).Hash.ToLower()
    if ($actual -eq $ExpectedHash) {
        info "Already up to date: $DestPath"
        info "Run: .\provisioning\wsl2\Instanciator.ps1 -Name <name> -InstanceType <type>"
        exit 0
    }
    warn "Hash mismatch on existing file — re-downloading."
    Remove-Item $DestPath
}

# ─── Download ─────────────────────────────────────────────────────────────────
info "Downloading $Filename (~374 MB)"

# Prefer BITS (background transfer, native progress, restart-capable)
$usedBits = $false
try {
    Import-Module BitsTransfer -ErrorAction Stop
    Start-BitsTransfer -Source $FileUrl -Destination $DestPath `
        -Description "Ubuntu $Codename WSL rootfs" `
        -DisplayName  "Fetch-Rootfs"
    $usedBits = $true
} catch {
    warn "BITS unavailable ($($_.Exception.Message)) — falling back to Invoke-WebRequest"
}

if (-not $usedBits) {
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $FileUrl -OutFile $DestPath -UseBasicParsing -TimeoutSec 600
        $ProgressPreference = 'Continue'
    } catch {
        fail "Download failed: $_"
        if (Test-Path $DestPath) { Remove-Item $DestPath }
        Write-Host $ManualMsg
        exit 1
    }
}

# ─── Verify ───────────────────────────────────────────────────────────────────
info "Verifying SHA256..."
$actual = (Get-FileHash -Algorithm SHA256 $DestPath).Hash.ToLower()
if ($actual -ne $ExpectedHash) {
    fail "SHA256 mismatch — corrupted download."
    fail "  Expected : $ExpectedHash"
    fail "  Actual   : $actual"
    Remove-Item $DestPath
    Write-Host $ManualMsg
    exit 1
}

info "OK — $Filename saved to $DestPath"
info "Run: .\provisioning\wsl2\Instanciator.ps1 -Name <name> -InstanceType <type>"
