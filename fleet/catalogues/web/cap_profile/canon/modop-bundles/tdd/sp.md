# Mode opératoire — TDD

**Statut** : actif — proposé en option au rôle `dev` (`modop_set.optional`).

> **Note pour l'auteur du catalogue.** Un mode opératoire est un fragment de texte ajouté au prompt
> d'un rôle pour changer sa **méthode**, pas ses permissions. Une carte peut le demander par étape
> (`steps.<étape>.modops: [tdd]`), ou un rôle peut le porter en permanence
> (`modop_set.default`). C'est le levier le moins cher du catalogue : un fichier, aucun code.

---

## La règle

**Aucune ligne de code de production avant un test qui échoue.**

Du code écrit avant son test est supprimé et réécrit. Pas de négociation, pas d'exception au motif
que « le travail est déjà fait » — un code déjà écrit n'est pas un acquis, c'est un code dont
personne n'a prouvé qu'il répondait à un besoin exprimé.

## Le cycle — six étapes, pas trois

Les deux étapes de vérification ne sont pas des sous-étapes : ce sont les seules qui produisent une
preuve.

### 1. Écris UN test qui échoue

Un seul. Minimal. Un nom qui dit le comportement attendu (`retourne X quand Y`). Il teste **un**
comportement, pas trois. Pas de simulacre sauf impossibilité — un test qui ne teste que des
simulacres teste ta configuration de simulacres.

### 2. Vérifie qu'il échoue — obligatoire

Lance-le. Puis confirme trois choses :

- il échoue sur une **assertion**, pas sur une erreur de syntaxe ou d'import ;
- le message d'échec correspond bien à l'absence de la fonctionnalité ;
- il échoue **parce que la fonctionnalité manque**, pas parce que le lanceur de tests est cassé.

S'il passe : tu testes un comportement qui existe déjà. Le test ne prouve rien — corrige-le.

### 3. Écris le minimum qui le fait passer

Le minimum. Pas la version générale, pas la gestion des cas que personne n'a demandés. Ce qui manque
sera réclamé par le prochain test.

### 4. Vérifie qu'il passe — obligatoire

Lance **toute** la suite, pas seulement ton test. Un test qui passe pendant que deux autres tombent
n'est pas un progrès.

### 5. Nettoie

Maintenant seulement. Renomme, factorise, supprime la duplication. Les tests sont ton filet : tu
peux réarranger sans crainte parce qu'ils sont verts, et ils doivent le rester à chaque étape.

### 6. Recommence

Comportement suivant.

## Les pièges

- **Écrire trois tests d'un coup.** Tu perds le lien entre un échec et la ligne qui le cause.
- **Écrire le test après le code, puis prétendre le contraire.** Le test écrit après un code qui
  marche est écrit pour passer, pas pour attraper. Il ne trouvera jamais rien.
- **Tester l'implémentation au lieu du comportement.** Un test qui casse à chaque réorganisation
  interne, sans qu'aucun comportement n'ait changé, sera supprimé par exaspération dans six mois.
- **Sauter l'étape 2.** C'est celle qu'on saute, et c'est la seule qui prouve que le test sert à
  quelque chose.

## Quand ne PAS l'appliquer

L'exploration. Quand tu ne sais pas encore ce que tu cherches, écris du code jeté. Puis **jette-le
vraiment**, et recommence en TDD avec ce que tu as appris. Le piège n'est pas d'explorer, c'est de
garder le brouillon.
