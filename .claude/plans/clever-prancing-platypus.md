# Plan — fleet-sanitize-memory + fleet-check-coherence

## Contexte

Deux hooks starfleet non implémentés (`docs_and_plans/work/todo/starfleet-hooks-sanitize.md`) :
1. **Sanitize MEMORY.md** : protège contre la contamination croisée — agents qui écrivent des règles dans MEMORY.md alors que c'est interdit (CLAUDE.md). Risque concret : architect et architect partagent le même MEMORY.md (même $HOME = lordzurp).
2. **Cohérence CLAUDE.md** : détecte les dérives entre les fichiers déployés dans les homes d'instances et la source LCARS-fleet (commit sans deploy.sh oublié, corruption manuelle, etc.).

**Décision d'implémentation** : les deux scripts tournent dans le branch `*architect)` de session-startup.sh — pas starfleet. Raison : architect tourne comme lordzurp → accès garanti à `/local/LCARS-fleet/` (source) et `/home/wsl-root/#2_Home/` (déployés). Filesystem starfleet non documenté pour ces chemins.

---

## Fichiers modifiés

| Fichier | Nature |
|---|---|
| `fleet/fleet-sanitize-memory.sh` | NOUVEAU |
| `fleet/fleet-check-coherence.sh` | NOUVEAU |
| `.claude/hooks/session-startup.sh` | +2 appels dans branch `*architect)` |
| `deploy.sh` | +2 entrées dans `INSTANCE_UTILS` |
| `docs_and_plans/work/todo/starfleet-hooks-sanitize.md` | déplacer → done/ |

---

## Script 1 — fleet-sanitize-memory.sh

**Déclenchement** : session-startup architect (sentinel = pas de re-run dans la même session).

**Logique** :
```
MEMORY_PATHS = [
  /home/wsl-root/#2_Home/{dev,builder,starfleet,Architect,qualifier}/.claude/projects/-home-lordzurp/memory/MEMORY.md
  /home/lordzurp/.claude/projects/-home-lordzurp/memory/MEMORY.md
]

Pour chaque fichier :
  - Parser par sections (## headers)
  - Whitelist : garder uniquement sections ## Identity + ## Completed
  - Garder tout contenu avant le premier ## (titre h1, etc.)
  - Écriture atomique : awk > /tmp/mem_sanitize_$$.tmp && mv
  - Si modifié : log dans /home/commons/logs/fleet-state.log
  - Si fichier absent ou inaccessible : skip silencieux
```

**awk core** :
```awk
BEGIN { in_keep = 1 }
/^## / { in_keep = ($0 ~ /Identity|Completed/) }
in_keep { print }
```
`in_keep=1` au départ → le contenu avant le premier `## ` (titre document) est conservé.

**Contraintes** :
- Jamais bloquant, exit 0 toujours
- Pas de Write/Edit tool (script bash) → pas de bug drvfs
- Skip si MEMORY.md < 3 lignes (évite écraser un fichier quasi-vide)

---

## Script 2 — fleet-check-coherence.sh

**Déclenchement** : session-startup architect. Sentinel journalier `/tmp/coherence-check-$(date +%Y-%m-%d)` — une seule exécution par jour même si architect redémarre plusieurs fois.

**Mapping source → déployé** (hardcodé, source : `fleet-env.sh`) :
```
$LCARS_ROOT/home_claude_CLAUDE.md          → $HOMES_ROOT/dev/.claude/CLAUDE.md
$LCARS_ROOT/home_claude_CLAUDE.md          → $HOMES_ROOT/starfleet/.claude/CLAUDE.md
$LCARS_ROOT/home_claude_CLAUDE.md          → $HOMES_ROOT/Architect/.claude/CLAUDE.md
$LCARS_ROOT/home_claude_CLAUDE.md          → $HOME/.claude/CLAUDE.md  (architect)
$LCARS_ROOT/home_claude_CLAUDE-builder.md  → $HOMES_ROOT/builder/.claude/CLAUDE.md
$LCARS_ROOT/home_claude_CLAUDE-qualifier.md       → $HOMES_ROOT/qualifier/.claude/CLAUDE.md
```

**Logique** :
```
Pour chaque paire (source, déployé) :
  - Si déployé absent : alerte "missing"
  - Si md5sum différent : alerte "drift"

Si au moins une alerte :
  - Append dans to-engineer.md :
    ### YYYY-MM-DD HH:MM — [auto] CLAUDE.md drift detected
    - <instance> : <source> → <raison>
  - Log dans /home/commons/logs/fleet-state.log
  - touch /tmp/coherence-check-YYYY-MM-DD (sentinel)
```

**Contraintes** :
- Jamais bloquant, exit 0 toujours
- Ne corrige pas — escalade only
- Écriture to-engineer.md : append atomique via `fleet-append.sh` si disponible, sinon `>>` direct

---

## session-startup.sh — modification

Dans le branch `*architect)`, **avant** les `inject_*` calls (après `starfleet-notes-check.sh`) :

```bash
# Hook: sanitize MEMORY.md (whitelist Identity + Completed)
if [ -x "$HOME/.local/bin/fleet-sanitize-memory.sh" ]; then
    bash "$HOME/.local/bin/fleet-sanitize-memory.sh"
fi

# Hook: check CLAUDE.md coherence across instances
if [ -x "$HOME/.local/bin/fleet-check-coherence.sh" ]; then
    bash "$HOME/.local/bin/fleet-check-coherence.sh"
fi
```

Pattern identique aux appels existants (`starfleet-notes-check.sh`).

---

## deploy.sh — modification

Ligne 265, array `INSTANCE_UTILS` :
```bash
INSTANCE_UTILS=("fleet-notify.sh" ... "starfleet-notes-check.sh" \
    "fleet-sanitize-memory.sh" "fleet-check-coherence.sh")
```
→ distribués dans `.local/bin/` de toutes les instances.

---

## Vérification

1. `bash deploy.sh` → vérifier `~/.local/bin/fleet-sanitize-memory.sh` présent + exécutable
2. **Test sanitize** : injecter `## BadRules\nrègle: always do X` dans un MEMORY.md test → exécuter → vérifier section supprimée, Identity + Completed intact
3. **Test coherence** : modifier un caractère dans `$HOMES_ROOT/dev/.claude/CLAUDE.md` → exécuter → vérifier entrée dans `to-engineer.md` ; relancer le même jour → vérifier sentinel bloque le double-report
4. QA : valider les deux scripts selon protocole standard avant push
