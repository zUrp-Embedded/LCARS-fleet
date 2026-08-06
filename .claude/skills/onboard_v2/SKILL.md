---
name: onboard_v2
description: >
  Onboarding sequence for fresh LCARS install. Security + GitHub setup + deploy.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
when_to_use: >
  Auto-triggered when .deploy_ok is absent at session start.
  Should not be invoked manually on an already-deployed system.
  See fleet/system-prompt/sources/roles/starfleet.md for trigger logic.
---
# Skill: /onboard_v2

**Date** : 2026-03-21
**Dernière révision** : 2026-08-07
**Statut** : actif
**Scope** : starfleet only

Single-pass onboarding. Conversational, professional (vouvoyer l'user — premier contact).
Writes `/home/fleet-state/.deploy_ok` when gates are validated.
Hard gates: ① GitHub auth (PAT) · ② C:\ isolation.
Enforcement always-on: pre-push hook (git integrity).
Idempotent — can be re-run safely. Skips steps already completed (preflight).

---

## Step 0 — Credentials sanity check

```bash
[ -f ~/.claude/.credentials.json ] && echo "ANTHROPIC_AUTH=OK" || echo "ANTHROPIC_AUTH=MISSING"
```

If `ANTHROPIC_AUTH=MISSING`:

```
[ERREUR] Credentials Anthropic absentes sur cette instance.
Vérifiez que post-reboot.sh a tourné correctement (voir /home/private/post-reboot.log).
Si le problème persiste :
  sudo cp /home/private/.credentials.json ~/.claude/.credentials.json
  sudo chown $(whoami):$(whoami) ~/.claude/.credentials.json
```

Do NOT proceed. Deployment error, not user error.

---

## Step 1 — Pre-flight

```bash
fleet/deploy/provision doctor          # v1 onboard-preflight.sh retire 2026-08-06 (excommunion) ; la sonde read-only v2 est `doctor`
```

Parse all KEY=VALUE output. If `DEPLOY_OK=true`: onboarding already complete, offer re-run. STOP.

---

## Step 2 — Welcome

Output verbatim:

```
       ______________________________________________________
      /          LCARS FLEET - FEDERATION DATABASE           \
     |   ________   __________________________________________\
     |  |  2026  |  | ONBOARDING
     |  |________|  |
     |   ________   | 10 agents prêts. Deux étapes de
     |  |  v5.4  |  | configuration avant de lancer la fleet.
     |  |________|  |
     |              |
      \    "To boldly go where no code has gone before..."     /
       \______________________________________________________/

  La fleet a besoin de deux choses pour fonctionner :

  ① Un accès GitHub
    Les agents créent des repos et poussent du code.
    Un token dédié limite leurs droits — votre compte
    GitHub (clés SSH, settings, repos perso) reste intact.

  ② L'isolation Windows
    Votre disque C:\ doit être verrouillé en lecture seule.
    Sans ça, un agent pourrait accéder à vos fichiers Windows.
    (Un reboot WSL suffit — c'est configuré automatiquement.)

  La sécurité git (intégrité de l'historique) est assurée en
  permanence par un hook pre-push — rien à configurer.

  [Tapez OK pour commencer]
```

Wait for user confirmation.

---

## Step 3 — Pre-flight status report

From Step 1 KEY=VALUE output, report each item. Do NOT pause — continue immediately.

- `BARRIER1` OK → `✓ C:\ verrouillé`
- `BARRIER1` PEND → `⚠ C:\ sera verrouillé au prochain reboot WSL (wsl --shutdown)`
- `BARRIER1` FAIL → `✗ C:\ accessible — relancer install.sh puis wsl --shutdown`
- `READY_ROOM` MOUNTED → `✓ ready-room monté`
- `READY_ROOM` NOT_MOUNTED → `⚠ sera monté au prochain reboot WSL`
- `DEPLOY_ALL` true → `✓ Agents déployés`
- `DEPLOY_ALL` false → list FAIL roles

---

## Step 4 — Git identity (skip if GIT_ID=OK)

If `GIT_ID=OK`: `✓ identité git configurée` — skip.

If `GIT_ID=MISSING`:

<instructions>
Expliquer que les agents commitent sous une identité dédiée pour distinguer leurs commits
de ceux de l'user sur GitHub. Demander un nom et un email. Suggérer "LCARS-<prénom>" pour le nom
et l'email GitHub de l'user pour l'email. Vouvoyer.
</instructions>

Once user provides values:

```bash
sudo tee /home/private/git-identity.conf > /dev/null << EOF
GIT_USER_NAME=<name>
GIT_USER_EMAIL=<email>
EOF
```

`✓ identité git configurée`

---

## Step 5 — GitHub setup (skip if GH_AUTH=OK)

If `GH_AUTH=OK`: `✓ GitHub authentifié (<login>)` — skip to Step 5.4 (org choice if not configured).

### Step 5.1 — PAT creation + auth (FIRST — before any GitHub API call)

The PAT must be created and authenticated BEFORE listing orgs or making any choice.
The PAT is always classic (ghp_) — simpler, works everywhere.

<instructions>
Guider l'user pas à pas dans la création du token. Être TRÈS explicite —
c'est la partie la plus technique de l'onboarding, et un token mal configuré
bloque toute la fleet.

PAT classique (les deux modes) :
- Lien direct : https://github.com/settings/tokens/new
- Expliquer que c'est un "mot de passe dédié" — pas le mot de passe du compte
- Paramètres EXACTS à remplir (l'user ne doit pas chercher) :
  1. Note/Name : "LCARS-fleet"
  2. Expiration : au choix (recommander 90 jours pour commencer — renouvelable)
  3. Scopes : cocher "repo" (le premier de la liste, "Full control of private
     repositories") ET "admin:org" (plus bas, "Full control of orgs and teams").
     Ces deux scopes sont nécessaires — repo pour le code, admin:org pour
     l'authentification gh CLI et la gestion d'organisation.
     NE PAS cocher delete_repo, user, gist, etc.
- Cliquer "Generate token"
- ATTENTION : le token s'affiche UNE SEULE FOIS. Le copier immédiatement.
- Coller ici.

Vouvoyer. Être patient — c'est le moment où l'user peut décrocher si c'est confus.
</instructions>

Once user pastes token:

```bash
# Store token securely
sudo tee /home/private/.github-token > /dev/null <<< "<token>"
sudo chmod 640 /home/private/.github-token

# Authenticate gh
printf '%s\n' "<token>" | gh auth login --with-token --hostname github.com
GH_LOGIN=$(gh api user --jq '.login' 2>/dev/null)

if [ -n "$GH_LOGIN" ]; then
    echo "✓ GitHub authentifié — $GH_LOGIN"

    # Setup git credential helper
    gh auth setup-git

    # Persist auth mode
    yq -i '.fleet.github.auth = "pat-classic"' ~/.lcars/fleet/fleet-system.yaml
else
    echo "✗ Token invalide — vérifiez et réessayez"
fi
```

If error: show it, explain what went wrong, ask to retry. Loop until auth succeeds.

### Step 5.2 — Org vs Personal choice (AFTER auth — needs API access)

If `github.mode` already set in fleet-system.yaml: skip this step, use existing value.

```bash
# List user's existing orgs (now possible — we're authenticated)
EXISTING_ORGS=$(gh api user/orgs --jq '.[].login' 2>/dev/null || true)
```

<instructions>
Expliquer les deux options. Vouvoyer. Être factuel, pas vendeur.

Option A — GitHub perso : les projets fleet vont dans le même espace que les repos existants.
Simple. Adapté si l'user a peu de repos ou préfère tout centralisé.

Option B — Organisation dédiée : un espace séparé sur GitHub, gratuit, dont l'user est
propriétaire. Les projets fleet sont rangés à part. Le profil personnel reste propre.
Adapté si l'user a beaucoup de repos ou veut séparer fleet / perso.

Si l'user a déjà des orgs (EXISTING_ORGS non vide), les mentionner :
"Vous avez déjà une organisation : <org>. Vous pouvez l'utiliser ou en créer une nouvelle."

Demander A ou B. Si l'user hésite, recommander B (plus propre à long terme).
Si B : demander le nom de l'org — soit une existante, soit un nouveau nom.
Exemples pour nouveau nom : <user>-lab, <user>-fleet, <user>-projects.
</instructions>

### Step 5.3 — Org creation (mode org only)

Only if user chose B.

```bash
ORG_NAME="<user input from Step 5.2>"
GH_LOGIN=$(gh api user --jq '.login' 2>/dev/null)

# Check org status: exists? user is owner?
ORG_ROLE=$(gh api "/orgs/$ORG_NAME/memberships/$GH_LOGIN" --jq '.role' 2>/dev/null || true)

if [[ "$ORG_ROLE" == "admin" ]]; then
    echo "✓ Organisation $ORG_NAME existe — vous en êtes propriétaire"
    # Confirm with user: "Utiliser cette org existante pour les projets fleet ?"
elif gh api "/orgs/$ORG_NAME" --jq '.login' &>/dev/null; then
    echo "✗ Le nom $ORG_NAME est déjà pris par quelqu'un d'autre sur GitHub"
    # Ask user for a different name and RESTART this step — do NOT proceed
else
    # Org doesn't exist — GitHub does NOT support org creation via API
    # (only Enterprise Cloud has GraphQL createEnterpriseOrganization)
    # Guide user to create manually via web UI
    echo "L'org $ORG_NAME n'existe pas encore."
    echo ""
    echo "Créez-la maintenant (30 secondes) :"
    echo "  1. Ouvrez : https://github.com/organizations/plan"
    echo "  2. Choisissez le plan Free"
    echo "  3. Nom : $ORG_NAME"
    echo "  4. Email de contact : le vôtre"
    echo "  5. Type : Personal account"
    echo "  6. Validez"
    echo ""
    echo "Dites-moi quand c'est fait."
    # WAIT for user confirmation, then re-check:
    # ORG_ROLE=$(gh api "/orgs/$ORG_NAME/memberships/$GH_LOGIN" --jq '.role' 2>/dev/null || true)
    # if [[ "$ORG_ROLE" != "admin" ]]; then error — org not found or not owner; fi
fi

# Create .github repo (org profile page) — doubles as permission check
# If this fails, the user doesn't have repo creation rights in the org
gh repo create "$ORG_NAME/.github" --public \
    --description "$ORG_NAME organization profile" 2>/dev/null || true

# Persist org mode — repo stays where it is (user's personal fork)
# Transfer is a manual operation (requires admin scope, not worth the complexity)
yq -i ".fleet.github.mode = \"org\"" ~/.lcars/fleet/fleet-system.yaml
yq -i ".fleet.github.org = \"$ORG_NAME\"" ~/.lcars/fleet/fleet-system.yaml
# repo stays at current location — new project repos go to the org
```

<instructions>
IMPORTANT: Do NOT set fleet.repo to the org. The LCARS fork stays where it was
forked (user's personal account). Only NEW project repos created by the fleet
go into the org. Explain this briefly to the user:

"Votre fork LCARS-fleet reste dans votre espace personnel — c'est votre copie
de configuration. Les projets créés par la fleet iront dans l'org <org-name>."
</instructions>

### Step 5.4 — Persist personal mode (if not org)

If mode personal:

```bash
GH_LOGIN=$(gh api user --jq '.login' 2>/dev/null)
yq -i '.fleet.github.mode = "personal"' ~/.lcars/fleet/fleet-system.yaml
yq -i '.fleet.github.org = null' ~/.lcars/fleet/fleet-system.yaml
yq -i ".fleet.repo = \"$GH_LOGIN/LCARS-fleet\"" ~/.lcars/fleet/fleet-system.yaml
```

---

## Step 5.5 — Offline bootstrap (conditional)

Only if `OFFLINE_BOOTSTRAP=true` from preflight:

```bash
FLEET_USER=$(_yq '.fleet.identity.fleet_user' ~/.lcars/fleet/fleet.yaml)
gh auth token --hostname github.com \
    | sudo -u "$FLEET_USER" gh auth login --with-token --hostname github.com 2>/dev/null || true
sudo fleet/deploy/provision apply      # v1 post-install-offline.sh retire 2026-08-06 ; un seul geste idempotent remplace la chaine
```

Report result.

---

## Step 6 — Propagate auth to fleet

```bash
# Propagate PAT to fleet_user + all pushing agents
FLEET_USER=$(yq '.fleet.identity.fleet_user' ~/.lcars/fleet/fleet-system.yaml 2>/dev/null)
PAT=$(cat /home/private/.github-token 2>/dev/null)
if [ -n "$PAT" ]; then
    for _user in "$FLEET_USER" $(yq '.instances[] | select(.scope == "code" or .sudo == "full") | .role' ~/.lcars/fleet/fleet.yaml 2>/dev/null); do
        printf '%s\n' "$PAT" | sudo -u "$_user" gh auth login --with-token --hostname github.com 2>/dev/null \
            && sudo -u "$_user" gh auth setup-git 2>/dev/null
    done
    echo "✓ Authentification propagée aux agents"
fi

# Rebuild fleet.yaml (github fields may have changed)
bash ~/.lcars/fleet/fleet-build-yaml.sh

# Redeploy (propagates git config, remotes, credentials)
sudo fleet/deploy/provision apply 2>&1 | tail -5   # v1 deploy.sh retire 2026-08-06 ; meme geste que ci-dessus, idempotent
```

---

## Step 7 — Security gate evaluation

Evaluate from preflight + steps completed:

```
=== Évaluation sécurité ===

  ① GitHub auth       : [result from Step 5]
  ② Isolation C:\     : [result from preflight BARRIER1]
  ③ Intégrité git     : ✓ pre-push hook actif (automatique)
```

If ① OK AND (② OK or PEND):

```bash
sudo touch /home/fleet-state/.deploy_ok
echo "✓ Fleet opérationnelle"
```

If ② PEND: note reboot needed for full C:\ lockdown, fleet is functional meanwhile.

If ① FAIL: explain PAT issue, do NOT write `.deploy_ok`.
If ② FAIL: explain C:\ issue, do NOT write `.deploy_ok`.

---

## Step 8 — Final summary

Output verbatim:

```
       ______________________________________________________
      /          LCARS FLEET - FEDERATION DATABASE           \
     |   ________   __________________________________________\
     |  | READY  |  | ONBOARDING COMPLETE
     |  |________|  |
     |   ________   | ✓ GitHub (<mode>: <owner>)
     |  |  v5.4  |  | ✓ Isolation C:\
     |  |________|  | ✓ Git integrity (pre-push hook)
     |              | ✓ Agents déployés
      \    "To boldly go where no code has gone before..."     /
       \______________________________________________________/

  Commandes disponibles :
    ~/start      — dashboard tmux complet
    fleet-arch   — parler à Architect (vos projets)
    fleet-sf     — parler à StarFleet (maintenance)
    claude       — Claude vanilla (hors fleet)
```

Fill `<mode>` and `<owner>` from fleet-system.yaml github fields.
Fill status lines from actual gate results (✓/⚠/✗).

**CRITICAL: After displaying the summary, exit immediately with `/exit`. StarFleet's onboarding role is complete — remaining as a free agent is a containment violation.**
