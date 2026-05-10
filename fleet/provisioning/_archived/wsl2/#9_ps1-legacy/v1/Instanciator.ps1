# Instanciator.ps1 — Cree et configure une nouvelle instance WSL
# Usage: .\Instanciator.ps1 [-Name <n>] [-Username <user>] [-InstanceType <type>]
#        Sans arguments : mode interactif
#
# Prerequis :
#   - config.local.ps1 present (cree automatiquement au premier run — demande WSL_ROOT)
#   - $WSL_ROOT\#9_sources\ contient le rootfs Ubuntu (.wsl ou .tar.gz)
#     => .\Fetch-Rootfs.ps1   (telecharge automatiquement)
#   - wsl-setup.sh present dans le meme dossier que ce script (provisioning\wsl2\)
#   - Cles SSH dans $env:USERPROFILE\.ssh\ (jamais dans ce repo)

param(
    [string]$Name         = "",
    [string]$Username     = "",
    [string]$InstanceType = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Colours ──────────────────────────────────────────────────────────────────
function info  { param($m) Write-Host "[INFO]  $m" -ForegroundColor Green  }
function warn  { param($m) Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function error { param($m) Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

# ─── Interactive prompts ───────────────────────────────────────────────────────
$validTypes = @("base", "dev", "builder", "starfleet", "architect-fleet", "qa")

if (-not $Name) {
    $Name = (Read-Host "Instance name").Trim()
    if (-not $Name) { error "Instance name is required" }
}

if (-not $Username) {
    $defaultUser = $env:USERNAME.ToLower()
    $inp = (Read-Host "Linux username [$defaultUser]").Trim()
    $Username = if ($inp) { $inp } else { $defaultUser }
}

if (-not $InstanceType) {
    Write-Host "Instance type:"
    for ($i = 0; $i -lt $validTypes.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $validTypes[$i])
    }
    $inp = (Read-Host "Choice [1]").Trim()
    $idx = if ($inp) { [int]$inp - 1 } else { 0 }
    if ($idx -lt 0 -or $idx -ge $validTypes.Count) { error "Invalid choice '$inp'" }
    $InstanceType = $validTypes[$idx]
} elseif ($InstanceType -notin $validTypes) {
    error "Invalid -InstanceType '$InstanceType'. Valid: $($validTypes -join ', ')"
}

# ─── Config locale (WSL_ROOT — chemin par machine, non versionné) ─────────────
$ConfigFile = "$PSScriptRoot\..\..\config.local.ps1"
if (Test-Path $ConfigFile) {
    . (Resolve-Path $ConfigFile)
} else {
    warn "config.local.ps1 not found — first run setup"
    $wslRootInput = (Read-Host "WSL root directory (ex: C:\Users\$env:USERNAME\WSL)").Trim()
    if (-not $wslRootInput) { error "WSL root is required" }
    "# config.local.ps1 — local config, gitignored`n`$WSL_ROOT = '$wslRootInput'" |
        Set-Content (Resolve-Path "$PSScriptRoot\..\..").Path"\config.local.ps1"
    $WSL_ROOT = $wslRootInput
    info "config.local.ps1 created — will be reused on next run"
}

# ─── Paths ────────────────────────────────────────────────────────────────────
$SOURCES_DIR = "$WSL_ROOT\#9_sources"
$INSTANCES   = "$WSL_ROOT\#1_Instances"
$HOMES       = "$WSL_ROOT\#2_Home"
$COMMONS     = "$WSL_ROOT\#3_Commons"
$PRIVATE     = "$WSL_ROOT\#4_Private"
$SETUP_SH    = "$PSScriptRoot\wsl-setup.sh"

# ─── 1. Verifications prealables ──────────────────────────────────────────────
info "Checking prerequisites"

if (-not (Test-Path $SETUP_SH)) {
    error "wsl-setup.sh not found at $SETUP_SH"
}

$rootfs = Get-ChildItem -Path $SOURCES_DIR -Include "*.wsl","*.tar.gz","*.tar.xz" -Recurse | Select-Object -First 1
if (-not $rootfs) {
    error "No rootfs found in $SOURCES_DIR`n  Run: .\provisioning\wsl2\Fetch-Rootfs.ps1"
}
info "Using rootfs: $($rootfs.Name)"

$existing = wsl --list --quiet 2>$null | Where-Object { $_ -eq $Name }
if ($existing) {
    error "WSL instance '$Name' already exists"
}

# ─── 2. Creer les dossiers ────────────────────────────────────────────────────
$instanceDir = "$INSTANCES\$Name"
$homeDir     = "$HOMES\$Name"

info "Creating directories"
New-Item -ItemType Directory -Force -Path $instanceDir | Out-Null
New-Item -ItemType Directory -Force -Path $homeDir     | Out-Null
New-Item -ItemType Directory -Force -Path $COMMONS     | Out-Null
New-Item -ItemType Directory -Force -Path $PRIVATE     | Out-Null

# ─── 3. wsl --import ─────────────────────────────────────────────────────────
info "Importing WSL instance '$Name' from $($rootfs.Name)"
wsl --import $Name $instanceDir $rootfs.FullName
if ($LASTEXITCODE -ne 0) { error "wsl --import failed" }
info "Instance '$Name' imported"

# ─── 4. wsl-setup.sh ─────────────────────────────────────────────────────────
# Chemin WSL du script et de WSL_ROOT (conversion C:\ -> /mnt/c/)
$setupWslPath  = $SETUP_SH   -replace "^C:\\", "/mnt/c/" -replace "\\", "/"
$wslRootPath   = $WSL_ROOT   -replace "^C:\\", "/mnt/c/" -replace "\\", "/"

info "Running wsl-setup.sh inside '$Name' (type: $InstanceType)"
$setupArgs = @("bash", $setupWslPath, "--hostname", $Name, "--user", $Username, "--wsl-root", $wslRootPath, "--instance-type", $InstanceType)
wsl -d $Name -u root -- @setupArgs
if ($LASTEXITCODE -ne 0) { error "wsl-setup.sh failed" }

# ─── 5. Home Windows — dossier cible du montage drvfs ────────────────────────
info "Ensuring home directory exists: $homeDir"
if (-not (Test-Path $homeDir)) {
    New-Item -ItemType Directory -Force -Path $homeDir | Out-Null
}
info "Home dir ready (will be mounted via fstab/drvfs at boot)"

# ─── 5b. Copie SSH vers #2_Home/<instance>/.ssh ──────────────────────────────
# Source : $env:USERPROFILE\.ssh (jamais dans ce repo)
# La copie depuis Windows evite les problemes de permissions NTFS sur drvfs.
$sshSrc = "$env:USERPROFILE\.ssh"
$sshDst = "$homeDir\.ssh"
if (Test-Path $sshSrc) {
    info "Copying SSH keys from $sshSrc"
    New-Item -ItemType Directory -Force -Path $sshDst | Out-Null
    # SEC-06: selective copy — private keys + known_hosts only, not config/authorized_keys
    foreach ($f in @("id_ed25519", "id_ed25519.pub", "id_rsa", "id_rsa.pub", "known_hosts")) {
        $src = Join-Path $sshSrc $f
        if (Test-Path $src) {
            Copy-Item -Path $src -Destination $sshDst -Force
        }
    }
    info "SSH keys copied to $sshDst"
} else {
    warn "SSH source not found ($sshSrc) - skipping"
}


# ─── 6. Terminate pour appliquer wsl.conf ────────────────────────────────────
info "Terminating instance to apply wsl.conf"
wsl --terminate $Name

# ─── 7. Summary ───────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "---------------------------------------------" -ForegroundColor Green
info "Instance '$Name' ready"
Write-Host "  Instance dir  : $instanceDir"
Write-Host "  Home (host)   : $homeDir (drvfs via fstab)"
Write-Host "  Commons       : $COMMONS (drvfs -> /home/commons)"
Write-Host "  Private       : $PRIVATE (drvfs -> /home/private)"
Write-Host "  User          : $Username"
Write-Host "  Instance type : $InstanceType"
Write-Host "  SSH source    : $sshSrc"
Write-Host ""
warn "Open a new Windows Terminal tab with '$Name' to start (don't use 'wsl -d' from existing tab)"
Write-Host "---------------------------------------------" -ForegroundColor Green
