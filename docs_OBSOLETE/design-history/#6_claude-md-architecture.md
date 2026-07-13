# Architecture CLAUDE.md par rôle — directives

**Date** : —
**Dernière révision** : 2026-03-08
**Statut** : guide opérationnel
**Référencé par** : steward-notes, token-optimization.md, insights-paperclip

---

## Contrainte réelle (à ne jamais oublier)

Context window : **200k tokens**. Le "32k" est le `token_budget` configurable (génération), pas la lecture.

**Consommation du contexte** :
- System prompt Claude Code : ~2-5k tokens
- Fichiers injectés (CLAUDE.md, imports en cascade, @file) : variable
- Historique conversation + code lu via outils

**Lost in the middle** : au-delà de ~20-30k tokens de contexte total, les instructions en milieu sont moins bien suivies. Les extrémités (début et fin) sont mieux retenues.

**Question directrice** : "est-ce que chaque token de directive est utile à ce rôle dans cette tâche"

---

## Architecture cible

### Structure

1. `CLAUDE.md` racine : **50-80 lignes max**, conventions globales toujours pertinentes
2. Fichiers rôle-spécifiques : injectés via imports, chargés uniquement pour ce rôle
3. Instructions critiques (scope, IPC, interdictions) : en **début ET fin** de chaque fichier directive
4. Zéro redondance inter-fichiers : une règle dans 3 fichiers = gaspillage + risque incohérence au patch

### Matrice fichiers par rôle (technique T1)

| Instance | Son CLAUDE.md | Reçoit complet | Reçoit STATE-only | N'injecte pas |
|---|---|---|---|---|
| dev | home_claude_CLAUDE.md | steward-notes, to-dev | builder-handoff (STATE) | to-build, steward-handoff |
| builder | home_claude_CLAUDE.md + CLAUDE-builder.md | to-build, steward-notes | — | to-dev, steward-handoff |
| steward | home_claude_CLAUDE.md | to-steward, to-build, to-dev | — | steward-notes (il l'écrit) |
| qualifier | home_claude_CLAUDE.md + CLAUDE-qualifier.md | to-qualifier, steward-notes | — | handoffs builder |

### Progressive disclosure (technique T5)

| Section | Destination | Déclencheur dans CLAUDE.md |
|---|---|---|
| Builders escalade (~400 tokens) | `memory/builder-rules.md` | `IMPORTANT : lire builder-rules.md avant toute action de build` |
| Table de tests (~150 tokens) | `memory/test-policy.md` | `Politique de tests dans test-policy.md` |

Le trigger `IMPORTANT` est nécessaire : confirmé empiriquement (données Vercel : 56% de non-invocation sans trigger sur les skills).

### Variables par rôle (technique T8)

| Variable | dev/StarFleet | builder |
|---|---|---|
| `MAX_THINKING_TOKENS` | 16000 | 8000 |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | 70 | 50 |

---

## Patterns de placement des instructions critiques

Les instructions critiques (scope, IPC, interdictions strictes) doivent apparaître :
1. En début du fichier (premières lignes)
2. ET en fin du fichier (dernières lignes)

Justification : lost-in-the-middle effect — les extrémités du contexte sont mieux mémorisées.

---

## Skill injection contextuelle (paperclip pattern)

Pour fleet-init-project.sh : créer un tmpdir de skills projet + domain et démarrer Claude avec `--add-dir`.
Plus propre qu'ajouter les skills dans CLAUDE.md global — évite la pollution cross-context.

```bash
# Concept fleet-init-project.sh
SKILL_DIR=$(mktemp -d)
ln -s ~/.claude/skills/cross-arm64 "$SKILL_DIR/"
ln -s ~/domains/rpi-embedded/skills/* "$SKILL_DIR/"
claude --add-dir "$SKILL_DIR" --project cDs
```

---

## Fichiers à créer / modifier

- `home_claude_CLAUDE-glossary-machine.md` : glossaire machine par rôle (voir #2_directives/glossaire-systeme.md)
- Mise à jour `deploy.sh` : distribuer CLAUDE-glossary-machine.md
- Validation qualifier sur tout nouveau fichier CLAUDE.md ou directive modifiée
