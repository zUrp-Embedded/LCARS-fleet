# priv/canon/sp/ — system prompts canon (versionnés)

**Date** : 2026-05-22 (bascule run #4)
**Statut** : copie versionnée des SPs cap-profile, **runtime actuel les charge encore depuis `/local/LCARS-v1.5/sp/`** (path historique).

## Contenu

- `archivist.md` — system prompt cap-profile archivist (instance memory)
- `monk.md` — system prompt cap-profile monk (workers instance memory)

## Statut

Ces fichiers sont la **copie canonique versionnée** depuis le filesystem `/local/LCARS-v1.5/sp/` au moment de la bascule run #4.

Les cap-profiles YAML (`priv/canon/cap-profiles/{archivist,monk}.yaml`) référencent encore le path historique `/local/LCARS-v1.5/sp/archivist.md`. À la migration vers résolution relative (via `:code.priv_dir(:fleet_capprofile)` ou env var `LCARS_CANON_ROOT`), ces fichiers `priv/canon/sp/` deviendront la source de vérité au runtime.

## Dette ouverte

Ticket à ouvrir post-bascule : migrer la résolution de path dans `fleet_capprofile` du hardcoded `/local/LCARS-v1.5/sp/` vers un mécanisme paramétré utilisant `priv/canon/sp/` du repo. Cf. DN `discipline-userland-clean.md` DRAFT (§3.1 grille audit, item "path système hardcoded vs XDG/relatif").
