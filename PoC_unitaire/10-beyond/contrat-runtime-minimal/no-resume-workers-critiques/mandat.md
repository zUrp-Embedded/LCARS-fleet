# no-resume-workers-critiques

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §5 "Arbitrage V2.16 --resume banni" + `04-phase-1-core/doctrine-runtime-workers-critiques.md`
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : PARTIEL — PoC-01 couvre `--no-session-persistence` empirique. Reste à couvrir le comportement `--resume` sur session absente.
**Référencé par** : `contrat-runtime-minimal/README.md`

## Contrat

Les workers critiques (qualifier, reviewer, consultant, builder,
researcher) tournent avec `--no-session-persistence`. La session JSONL
**n'existe pas**. `--resume` est donc kernel-inapplicable — pas de
fichier de session à reprendre.

Conséquence sur le recovery : pas de réattachement cognitif. Le
recovery LCARS est mécanique (event log + PodStatus + artefacts),
jamais cognitif (pas de continuation de session agent).

## Observable

Couvert par PoC-01 :
- `--no-session-persistence` : aucun artefact session dans `$HOME/.claude/`
  après run ✓
- `--setting-sources ""` : hooks `SessionStart` non exécutés ✓
- Stream NDJSON propre, pas d'ANSI, stderr distinct ✓

Non couvert :
- [GAP] `--resume <session-id>` sur un `$HOME/.claude/` vide (aucune
  session) → comportement attendu : erreur claire, pas de comportement
  indéterminé
- [GAP] Retry with brief enrichi (outputs partiels extraits event log
  réinjectés dans nouveau brief) — ça c'est du design fleet-pilot

## Finding adjacent (PoC-01)

`CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` silencieusement ignoré en 2.1.114.
Garantie effective = hygiène home worker (home vide, pas de CLAUDE.md
posé). Voir `work/beyond/findings/2026-04-20-claude-code-disable-claude-mds-dead.md`.

## Ce que le test vérifie

Passe: `test.sh` relance PoC-01 et vérifie les 3 comportements
confirmés (no-session-persistence, setting-sources vide, stream clean).
Ajoute un test dédié `--resume` sur home vide.
