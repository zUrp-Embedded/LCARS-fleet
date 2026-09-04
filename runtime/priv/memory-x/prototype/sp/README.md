# priv/memory-x/prototype/sp/ — system prompts du prototype d'origine (Memory-X, feature gelée)

**Date** : 2026-05-22 (bascule run #4)
**Statut** : copie versionnée des SPs cap-profile archivist/monk — **GELÉS (F-C153), non chargés par le runtime** (les profils archivist/monk sont hors catalogue actif).

## Contenu

- `archivist.md` — system prompt cap-profile archivist (instance memory)
- `monk.md` — system prompt cap-profile monk (workers instance memory)

## Statut

Ces fichiers sont la **copie canonique versionnée** depuis le filesystem `/local/LCARS-v1.5/sp/` au moment de la bascule run #4.

Les cap-profiles YAML (`priv/memory-x/prototype/cap-profiles/{archivist,monk}.yaml`) référencent encore le path historique `/local/LCARS-v1.5/sp/archivist.md`. À la migration vers résolution relative (via `:code.priv_dir(:fleet_cap_profile)` ou env var `LCARS_CANON_ROOT`), ces fichiers `priv/memory-x/sp/` deviendront la source de vérité au runtime.

## Dette ouverte

Ticket à ouvrir post-bascule : migrer la résolution de path dans `fleet_cap_profile` du hardcoded `/local/LCARS-v1.5/sp/` vers un mécanisme paramétré utilisant `priv/memory-x/sp/` du repo. Cf. DN `discipline-userland-clean.md` DRAFT (§3.1 grille audit, item "path système hardcoded vs XDG/relatif").
