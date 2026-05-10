# PoC-01 — recette canonique claude -p + kill switches

**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : done — 9/10 PASS, 1 FAIL structural
**Référencé par** : `work/beyond/poc-plan.md §PoC-01`, `work/beyond/findings/2026-04-20-claude-code-disable-claude-mds-dead.md`
**Version claude testée** : 2.1.114 (corpus référence 2.1.88)
**Branche** : `feature/poc-01-claude-p-recette`

## Hypothèse

Les flags et env vars de la recette canonique (`doctrine-runtime-workers-critiques.md §Recette canonique`) sont actifs et se comportent comme documenté en 2.1.114.

## Méthode

Script `test_recette.sh` qui construit plusieurs homes isolés sous `/tmp`, y copie les credentials `starfleet`, puis lance `claude -p` avec différentes combinaisons flags. Chaque test vérifie un comportement empirique (marker lu/non lu, hook exécuté/non, NDJSON valide, flag accepté par le parser + effet observable).

## Résultats

| Test | Kill switch / flag | PASS | Note |
|---|---|---|---|
| T1 | `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` | **FAIL** | env var ignorée en 2.1.114, CLAUDE.md cwd lue quand même |
| T2 | `--no-session-persistence` | PASS | aucun artefact session dans `~/.claude/` après run |
| T3 | `--setting-sources ""` | PASS | hook `SessionStart` **non** exécuté (baseline confirme qu'il tourne sans le flag) |
| T4 | stream-json propre | PASS | pas d'ANSI stdout, toutes lignes JSON valides, stderr distinct |
| T5 | `--strict-mcp-config --disable-slash-commands` | PASS | flags acceptés |
| T6 | `--system-prompt-file` / `--append-system-prompt-file` | PASS | flags cachés de `--help` mais effectifs |
| T7 | `--max-turns` | PASS | flag caché de `--help` mais accepté |

## Finding P1 — CLAUDE_CODE_DISABLE_CLAUDE_MDS sans effet

L'env var est silencieusement ignorée en 2.1.114. `CLAUDE.md` présent dans le cwd est chargé et le marker est renvoyé par le modèle, avec ou sans la variable.

Seul moyen confirmé de désactiver la découverte CLAUDE.md : `--bare`. Mais `--bare` désactive aussi la lecture keychain/OAuth, donc inutilisable pour workers authentifiés via `.credentials.json`.

**Conséquence pour la recette canonique** : la garantie repose maintenant sur **l'hygiène home** (home worker créé vide, pas de CLAUDE.md posé), pas sur l'env var. Le capital `--no-session-persistence` + `--setting-sources ""` + home propre tient. L'env var peut rester dans la recette par défense en profondeur, mais doit être marquée comme "ineffective en 2.1.114+, historique".

Finding formel : `work/beyond/findings/2026-04-20-claude-code-disable-claude-mds-dead.md`.

## Flags cachés de `--help`

Trois flags corpus ne sont pas listés dans `claude --help` top-level mais fonctionnent :
- `--system-prompt-file <path>`
- `--append-system-prompt-file <path>`
- `--max-turns <n>`

Ils sont mentionnés dans la description de `--bare` (`--system-prompt[-file]`, `--append-system-prompt[-file]`). Pas de breaking change, juste documentation partielle.

## Livrables

- `test_recette.sh` — harness reproductible
- `report.txt` (généré dans `/tmp/poc01-XXXX/`) — log complet dernière exécution

## Hors scope

- Comportement sous OAuth refresh (credentials expirés) — hors recette canonique
- Test `--fallback-model` — pas listé recette canonique
- Test `--include-hook-events` — hors scope B1 round 1
