# extract-primitives-fs

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §5 AC-01 (partiel — primitives seulement)
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : PROVEN (primitives FS isolées seulement)
**Référencé par** : `contrat-runtime-minimal/README.md`

## Histoire du renommage

Auparavant nommée `extract-atomicity/`, renommée sur reprise consultant R-03a (audit fonctionnel 2026-04-20) pour lever l'ambiguïté. Le nom d'origine suggérait que l'atomicité complète du pipeline AC-01 était testée, ce qui n'est pas le cas — seuls les primitives FS isolées le sont. Le pipeline complet a sa propre unité DRAFT `extract-pipeline/`.

## Contrat (primitives seules)

Trois primitives FS dont le pipeline AC-01 dépend :

1. **rename-after-write sur fichier** — écrire `target.tmp`, `fsync`, `rename(target.tmp, target)`. Atomique sur ext4 tant que source et destination sont sur le même FS.
2. **rename sur répertoire** — `rename(staging, final)` suivi de `fsync` sur le parent. Atomique ext4.
3. **inode preserve pour reader ouvert pré-rename** — un reader qui a `open(target)` avant le rename voit toujours l'ancien contenu (inode maintenu par son FD), même après rename vers un autre contenu.

Ces propriétés sont les briques sur lesquelles le pipeline AC-01 s'appuie. Leur validation isolée ne prouve pas que le pipeline est atomique — juste que les briques le permettent.

## Observable

- `rename()` retourne sans erreur et le FS montre le nouveau nom
- `fsync(dir_fd)` persiste le rename à travers crash (non testé ici — coût disproportionné)
- `open()` sur fichier `A`, puis rename `B → A`, puis read sur le FD original → ancien contenu

## Ce que le test vérifie

Trois assertions isolées sur les primitives, exécutables dans `/tmp` sans setup runtime :
- T1 : écriture via tmp + rename donne le bon contenu
- T2 : rename de dir avec fsync parent atomique
- T3 : reader ouvert pré-rename voit l'ancien inode

## Ce que le test NE vérifie PAS (delegated to extract-pipeline/)

- Séquence stricte des 7 étapes `staging → rename → fsync → event append → fsync log → PodStatus .tmp → rename → transition phase`
- Crash simulé à chaque étape + recovery event-log-based
- Règle de rollback (artefacts sans event → supprimer) / escalade (event sans artefacts → fatal)

Ces vérifications exigent un pipeline Python qui joue les 7 étapes et un simulateur de crash. Elles vivent dans l'unité distincte `extract-pipeline/` (DRAFT) quand fleet-pilot aura un skeleton exécutable.
