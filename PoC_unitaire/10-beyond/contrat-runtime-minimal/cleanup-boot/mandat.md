# cleanup-boot

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §5 "Cleanup boot"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : DRAFT
**Référencé par** : `contrat-runtime-minimal/README.md`

## Contrat

Au démarrage de fleet-pilot, après startup probes :

1. Pour chaque `pod_N` dans le pool :
   - Si `.credentials.json` existe dans `~/.claude/` → `rm -f`
     (fenêtre INJECT→RELEASE orpheline)
2. Pour chaque PodStatus en phase `Running`/`Unknown` :
   - Lancer procédure recovery (unité `recovery-orphan-handling/`)
3. Pour chaque staging dir `/home/fleet-state/events/*/.staging/` :
   - `rm -rf` (extract orphelin, data non consolidée)

## Observable

- Fonction `cleanup_orphan_credentials(pool_users)` — liste + rm
- Fonction `cleanup_staging_dirs(events_root)` — rm des `.staging/`
- Idempotence : second appel ne plante pas (fichiers déjà absents)

## Ce que le test vérifiera

Harness qui :
- Crée un `pool_user` temporaire avec `.credentials.json` orphelin
- Crée des `.staging/` orphelins dans un event root
- Invoque cleanup → les artefacts orphelins sont supprimés
- Réinvoque → pas d'erreur, état stable

## Pourquoi DRAFT

Besoin de fonctions fleet-pilot non encore codées. Test est
straightforward mais dépend d'un squelette d'implémentation.
