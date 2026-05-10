# work-ops-single-writer

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §5 "Sérialisation work/ops (AC-03)"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : PARTIAL — flock exclusif PROVEN ; inbox state machine et interdiction git push pod restent en `[GAP]`
**Référencé par** : `contrat-runtime-minimal/README.md`

## Contrat

`work/ops` est une branche git partagée. Writers multiples = conflits
merge garantis.

**Règle** : fleet-pilot est le **seul writer** de `work/ops`. Les pods
déposent leurs mutations dans un inbox :

```
/home/fleet-state/work-ops-inbox/
  <timestamp>-<pod_id>-<action>.yaml   # mutation proposée
  .processing/                          # en cours
```

Fleet-pilot consolide l'inbox périodiquement (30s ou sur demande) :
1. Lock `work/ops` (flock interne fleet-pilot)
2. Pour chaque mutation : appliquer dans worktree + commit
3. `git push work/ops`
4. Déplacer mutations dans `.processing/.consumed/`
5. Unlock

Les commits apparaissent sous l'identité du pod (co-author) mais
l'exécution git est centralisée.

## Observable

- Flock interne fleet-pilot : si 2 instances de consolidation
  concurrentes → l'une bloque sur flock
- Pas d'opération git directe depuis un pod (pod n'a pas le droit
  `git push` sur work/ops — permission OS ou credentials restreints)
- Mutation atomique : le fichier inbox est soit traité, soit dans
  `.processing/`, soit dans `.consumed/` — pas disparu sans trace

## Ce que le test vérifiera

- Flock Python : 2 subprocess tentent la section critique, seul 1
  passe à la fois
- Inbox state machine : mutation entre `inbox/`, `.processing/`,
  `.consumed/` sans perte
- (hors scope test unitaire) Bench merge conflicts sur N writers
  concurrents — mesure qualitative, pas quantitative
