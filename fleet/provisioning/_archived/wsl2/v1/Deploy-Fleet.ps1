# Deploy-Fleet.ps1 — Déploiement interactif de la flotte LCARS
#
# Propose les 6 instances du template recommandé, compatibles avec la
# configuration tmux du repo (fleet-launch.sh / tmux.conf).
# Première question : simulation ou déploiement réel.
#
# Usage : .\provisioning\wsl2\Deploy-Fleet.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function info  { param($m) Write-Host "[INFO]  $m" -ForegroundColor Green  }
function warn  { param($m) Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function error { param($m) Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }
function head  { param($m) Write-Host "`n$m" -ForegroundColor Cyan          }
function dry   { param($m) Write-Host "[DRY]   $m" -ForegroundColor DarkGray }

function Ask {
    param([string]$Question, [bool]$Default = $true)
    $hint = if ($Default) { "[Y/n]" } else { "[y/N]" }
    $ans = (Read-Host "$Question $hint").Trim().ToLower()
    if ($ans -eq "") { return $Default }
    return ($ans -eq "y" -or $ans -eq "yes" -or $ans -eq "o" -or $ans -eq "oui")
}

$ScriptDir = $PSScriptRoot

# ─── Présentation ─────────────────────────────────────────────────────────────
head "═══════════════════════════════════════════════"
head " LCARS — Déploiement interactif de la flotte"
head "═══════════════════════════════════════════════"
Write-Host ""
Write-Host "  Template recommandé : dev + builder + qa + starfleet + architect-fleet"
Write-Host "  Compatible avec fleet-launch.sh et la session tmux du repo."
Write-Host ""

# ─── Simulation ou réel ───────────────────────────────────────────────────────
$DryRun = Ask "Simuler le déploiement ? (non = exécution réelle)"

if ($DryRun) {
    warn "Mode simulation — aucune action sera exécutée."
} else {
    warn "Mode réel — les instances seront créées."
}

# ─── Rootfs ───────────────────────────────────────────────────────────────────
head "── Rootfs Ubuntu WSL ──"
$fetchRootfs = Ask "Télécharger/vérifier le rootfs Ubuntu (24.04 LTS) ?"

# ─── Sélection des rôles ──────────────────────────────────────────────────────
head "── Instances à créer ──"
Write-Host "  (Entrée = valeur par défaut entre crochets)"
Write-Host ""

$roles = [ordered]@{
    "dev"        = @{ Type = "dev";        Desc = "développement, commits git";             Default = $true  }
    "builder"    = @{ Type = "builder";    Desc = "build ARM64/x86-64 (--arch flag)";       Default = $true  }
    "qa"         = @{ Type = "qa";         Desc = "tests uniquement (pytest, ctest)";       Default = $true  }
    "starfleet" = @{ Type = "starfleet"; Desc = "coordination, déblocage builders";       Default = $true  }
    "architect-fleet" = @{ Type = "architect-fleet"; Desc = "toolkit LCARS, host session tmux";       Default = $true  }
}

$selected = [ordered]@{}
foreach ($name in $roles.Keys) {
    $r = $roles[$name]
    $selected[$name] = Ask "  $name — $($r.Desc)" -Default $r.Default
}

# ─── Username ─────────────────────────────────────────────────────────────────
head "── Utilisateur ──"
$defaultUser = $env:USERNAME
$username = (Read-Host "Username Linux pour toutes les instances [$defaultUser]").Trim()
if ($username -eq "") { $username = $defaultUser }

# ─── Résumé ───────────────────────────────────────────────────────────────────
head "── Résumé ──"
$toCreate = @()
foreach ($name in $selected.Keys) {
    if ($selected[$name]) {
        Write-Host "  [✓] $name ($($roles[$name].Type))" -ForegroundColor Green
        $toCreate += $name
    } else {
        Write-Host "  [ ] $name — ignoré" -ForegroundColor DarkGray
    }
}

if ($toCreate.Count -eq 0) {
    warn "Aucune instance sélectionnée — rien à faire."
    exit 0
}

# ─── Simulation ───────────────────────────────────────────────────────────────
if ($DryRun) {
    head "── Commandes qui seraient exécutées ──"
    if ($fetchRootfs) {
        dry "& `"$ScriptDir\Fetch-Rootfs.ps1`""
    }
    foreach ($name in $toCreate) {
        dry "& `"$ScriptDir\Instanciator.ps1`" -Name $name -Username $username -InstanceType $($roles[$name].Type)"
    }
    Write-Host ""
    warn "Simulation terminée. Aucune modification effectuée."
    exit 0
}

# ─── Confirmation avant exécution ─────────────────────────────────────────────
Write-Host ""
if (-not (Ask "Lancer le déploiement de $($toCreate.Count) instance(s) ?")) {
    warn "Annulé."
    exit 0
}

# ─── Exécution ────────────────────────────────────────────────────────────────
head "── Déploiement ──"

if ($fetchRootfs) {
    info "Téléchargement du rootfs..."
    & "$ScriptDir\Fetch-Rootfs.ps1"
    if ($LASTEXITCODE -ne 0) { error "Fetch-Rootfs.ps1 a échoué — vérifier la connexion réseau." }
}

$ok     = @()
$failed = @()

foreach ($name in $toCreate) {
    $type = $roles[$name].Type
    info "Création de '$name' (type: $type)..."
    & "$ScriptDir\Instanciator.ps1" -Name $name -Username $username -InstanceType $type
    if ($LASTEXITCODE -eq 0) {
        $ok += $name
        info "'$name' créé."
    } else {
        $failed += $name
        warn "'$name' a échoué — poursuite avec les instances suivantes."
    }
}

# ─── Bilan ────────────────────────────────────────────────────────────────────
head "── Bilan ──"
foreach ($n in $ok)     { Write-Host "  [✓] $n" -ForegroundColor Green }
foreach ($n in $failed) { Write-Host "  [✗] $n — ÉCHEC" -ForegroundColor Red }

if ($failed.Count -gt 0) {
    warn "$($failed.Count) instance(s) en échec. Relancer Instanciator.ps1 manuellement pour les diagnostiquer."
    exit 1
}

Write-Host ""
info "Flotte déployée. Ouvrir un nouvel onglet Windows Terminal et lancer :"
info "  wsl -d Architect -- bash -lc '~/start'"
