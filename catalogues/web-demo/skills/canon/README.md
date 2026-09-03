# skills/canon — les procédures montées dans les pods

**Date** : 2026-08-10
**Statut** : actif — arbre vide dans ce catalogue, et c'est délibéré

## Ce qu'est une skill

Une **procédure nommée** qu'un agent peut charger quand il en a besoin : un dossier
`<nom>/SKILL.md`, monté en lecture seule dans le pod.

Un rôle ne les reçoit pas toutes. Il déclare celles qu'il veut, par leur nom :

```yaml
knowledge:
  skills: [deploiement, revue-securite]
```

La liste est une **liste blanche** : `[]` — ce que font les quatre rôles de ce catalogue — veut dire
qu'aucune skill n'est montée. Un nom qui ne correspond à aucun dossier ici fait échouer le
lancement du pod, en le nommant.

## Pourquoi cet arbre est vide

Une skill est utile quand une procédure est **longue, exacte et rejouée** : une séquence de
déploiement, une grille de revue, un rituel de mise en production. Écrite dans le prompt d'un rôle,
elle occupe son contexte à chaque tâche même quand il n'en a pas besoin. Mise ici, elle est
disponible sans être imposée.

Ce catalogue n'en a aucune, parce qu'aucun de ses quatre rôles ne le justifie encore. Ajouter une
skill vide « pour l'exemple » aurait rempli l'arbre sans rien apprendre.

## Ce qui distingue une skill d'un mode opératoire

Les deux sont du texte ajouté à un agent, et on les confond au début.

| | mode opératoire (`modop-bundles/`) | skill (ici) |
|---|---|---|
| Change | la **manière** de travailler | ce que l'agent **sait faire** |
| Portée | tout le travail du rôle, ou une étape | chargée quand elle sert |
| Qui décide | le rôle, ou la carte | l'agent, dans sa liste blanche |
| Exemple | travailler en test-d'abord | la procédure de mise en production |

En cas de doute : si ça décrit **comment** travailler, c'est un mode opératoire ; si ça décrit une
**tâche précise** qu'on refait à l'identique, c'est une skill.
