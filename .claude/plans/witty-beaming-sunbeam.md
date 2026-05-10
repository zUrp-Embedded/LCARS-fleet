# Plan — Absorption WSL-setup + archivage anciens repos

## Contexte

Deux anciens repos (`#0_Claude-directives`, `#0_WSL-setup`) coexistent avec le nouveau canonical `#0_LCARS-fleet`.
LCARS-fleet contient déjà une copie de WSL-setup dans `provisioning/wsl2/` — mais cette copie est **stale** :
elle référence encore l'ancien repo `Claude-directives` et le chemin `.claude-directives` au lieu de `.lcars`.

Objectif : mettre à jour LCARS-fleet pour qu'il soit auto-suffisant (bootstrap sans dépendance externe),
puis archiver les deux anciens repos et nettoyer les références résiduelles.

---

## Phase 1 — Corriger les références dans LCARS-fleet/provisioning/wsl2/

**Fichiers à modifier** (`/home/wsl-root/#0_LCARS-fleet/provisioning/wsl2/`) :

### 1a. `post-install.sh`
- Remplacer : clone de `Claude-directives` → clone de `LCARS-fleet`
- Remplacer : chemin `.claude-directives` → `.lcars`
- Remplacer : toute référence à `wsl-setup` path externe → chemin interne `provisioning/wsl2/`

### 1b. `wsl-setup.sh`
- Remplacer : `DIRECTIVES_MNT=".claude-directives"` → `.lcars`
- Vérifier : toute autre référence à l'ancien nom de repo

### 1c. Autres scripts modules (`post-install-*.sh`)
- Grep `claude-directives\|WSL-setup\|Clone.*directives` — corriger toute occurrence

**Commit** : `fix(provisioning): .claude-directives → .lcars, Claude-directives → LCARS-fleet`

---

## Phase 2 — Corriger lordzurp home

**Fichiers à modifier :**

### 2a. `/home/lordzurp/CLAUDE.md` (projet-level, dans `#0_LCARS-fleet/CLAUDE.md`)
- Ligne : `git -C "$HOME/.claude-directives" pull` → `git -C "$HOME/.lcars" pull`

### 2b. `/home/lordzurp/.bashrc`
- Ligne ~133 : `_POST_SCRIPT="$HOME/.wsl-setup/post-install.sh"` → supprimer ou pointer vers source LCARS-fleet

**Commit** : `fix(lordzurp): CLAUDE.md + .bashrc — supprimer refs anciens repos`
**Deploy** : `bash /home/wsl-root/#0_LCARS-fleet/deploy.sh` (propagation à tous les agents)

---

## Phase 3 — Vérification agents

Pour chaque instance (dev, build-arm, build-x86-64, starfleet, architect, qualifier) :

```bash
# Pattern de vérif par instance :
wsl -d <instance> --exec bash -c "
  grep -r 'claude-directives\|wsl-setup' ~/.bashrc ~/.claude/CLAUDE.md 2>/dev/null
  ls -la ~/.claude-directives ~/.wsl-setup 2>/dev/null && echo 'STALE FOUND' || echo 'OK'
"
```

**Actions si stale trouvé** :
- Supprimer `~/.claude-directives` et/ou `~/.wsl-setup` dans l'instance concernée
- Ces dirs sont des clones locaux des anciens repos — jamais créés par le deploy LCARS-fleet

---

## Phase 4 — Archivage des anciens repos

```bash
# Archive
mv /home/wsl-root/#0_Claude-directives /home/wsl-root/#9_archives/Claude-directives-$(date +%Y%m%d)
mv /home/wsl-root/#0_WSL-setup         /home/wsl-root/#9_archives/WSL-setup-$(date +%Y%m%d)

# Nettoyage home lordzurp
rm -rf /home/lordzurp/.claude-directives
rm -rf /home/lordzurp/.wsl-setup
```

> Repos GitHub (`lordzurp/Claude-directives`, `lordzurp/WSL-setup`) : marquer "archived" sur GitHub
> (action manuelle, hors scope de cette session).

---

## Phase 5 — Vérification ISO

Simuler un état "fresh deploy" :

```bash
# 1. Vérifier aucune ref résiduelle dans LCARS-fleet
grep -r "claude-directives\|WSL-setup" /home/wsl-root/#0_LCARS-fleet/ \
  --include="*.sh" --include="*.md" --include="*.py" \
  | grep -v ".git" | grep -v "#9_archives"

# 2. Vérifier deploy.sh produit le bon état
bash /home/wsl-root/#0_LCARS-fleet/deploy.sh --dry-run 2>/dev/null

# 3. Vérifier home lordzurp propre
ls -la ~/.claude-directives ~/.wsl-setup 2>&1  # doit retourner "No such file"
grep "claude-directives\|wsl-setup" ~/.bashrc   # doit être vide
```

---

## Ordre d'exécution et dépendances

```
Phase 1 (provisioning) ──┐
Phase 2 (lordzurp home) ─┼── commit + deploy ──> Phase 3 (agents vérif) ──> Phase 4 (archive) ──> Phase 5 (ISO check)
```

Phase 2 et Phase 1 peuvent être faites dans le même commit si les changements sont cohérents.
Phase 4 ne se fait qu'après validation de Phase 3.

---

## Fichiers critiques

| Fichier | Action |
|---|---|
| `#0_LCARS-fleet/provisioning/wsl2/post-install.sh` | Corriger refs repo + chemin |
| `#0_LCARS-fleet/provisioning/wsl2/wsl-setup.sh` | Corriger DIRECTIVES_MNT |
| `#0_LCARS-fleet/provisioning/wsl2/post-install-*.sh` | Grep + corriger |
| `#0_LCARS-fleet/CLAUDE.md` | `.claude-directives` → `.lcars` |
| `/home/lordzurp/.bashrc` | Supprimer `_POST_SCRIPT` wsl-setup |
| Tous homes agents | Vérif + nettoyage stale dirs |

---

## Rollback

- Les anciens repos sont déplacés dans `#9_archives/`, pas supprimés → rollback par `mv` inverse
- Commits atomiques par phase → `git revert` ciblé si besoin
