# FORMAT — le vocabulaire des relevés

**Date** : 2026-07-31
**Dernière révision** : 2026-07-31
**Statut** : actif — contrat de sortie du toolkit `state_of_the_fleet`
**Référencé par** : `SKILL.md`, `probes/lib.sh`

> Ce fichier décrit ce que le toolkit **dit**. Ce qu'il *fait* est dans le code, et le code fait foi :
> si les deux divergent, c'est ce fichier qui est périmé.

---

## 1. Une ligne = un JSON, huit champs

Chaque sonde émet une ligne JSON par constat, sur stdout. Le JSONL est **la source de vérité** ; le
rendu ne fait que le présenter, donc un bug d'affichage ne peut jamais inventer ni cacher un verdict.

| champ | rôle |
|---|---|
| `probe` | identifiant pointé, **stable d'un run à l'autre** — c'est lui qui rend deux relevés comparables |
| `plane` | `instruments` · `fleet` · `pods` · `forge` · `projects` · `self` · `capacites` |
| `verdict` | les cinq valeurs du §2 |
| `vantage` | d'où la mesure a été prise : `local` · `reseau` · `hote-http` · `hote-socket` |
| `method` | la commande exacte, pour que le lecteur puisse la rejouer |
| `evidence` | **verbatim**, tronqué et marqué comme tel, jamais paraphrasé |
| `cannot_conclude` | ce que cette ligne ne prouve pas — **obligatoire** |
| `ts` | UTC |

`evidence` est verbatim par contrat, et verbatim veut dire **non fiable en tant que chaîne** : elle
est encodée avec `jq`, si bien qu'un guillemet ou un retour ligne dans la réponse d'un serveur ne
peut pas casser le format du rapport qui le cite.

---

## 2. Les cinq verdicts

Le vocabulaire n'a pas été conçu, il a été **forcé** par deux spécimens : la première version sortait
cinq lignes rouges décrivant un daemon que personne n'avait demandé à exister sur un conteneur
parfaitement saine. Une fausse alarme déguisée en constat — la pire espèce, elle a l'air d'un
diagnostic.

| verdict | rendu | ce que ça dit |
|---|---|---|
| `operational` | `OK` | mesure prise, résultat conforme |
| `inactive` | `OFF` | **rien de déclaré à atteindre** — absence légitime, ne dégrade pas le run |
| `degraded` | `DRIFT` | mesure prise, **résultat mauvais** |
| `unreachable` | `AVEUG` | **mon instrument est cassé** — aucun constat sur la cible |
| `unknown` | `?` | **ambiguïté déclarée** : la mesure a eu lieu, elle ne tranche pas |

### Les trois confusions à ne jamais faire

**`unreachable` n'est pas `degraded`.** Si `curl` manque, la fleet n'est pas dégradée : **je suis
aveugle**. Les confondre est le mensonge exact que ce toolkit existe pour empêcher.

**`inactive` n'est pas `degraded`.** Aucune forge configurée, aucune fleet démarrée, un rôle qui ne
monte pas une racine : ce sont des absences **par construction**. Les peindre en rouge apprend à
ignorer le rouge.

**`unknown` n'est pas un échec.** Une ambiguïté *déclarée* est un résultat honnête — un 404 anonyme
sur une forge ne distingue pas « absent » de « invisible sans jeton », et une sonde qui trancherait
inventerait un fait. `unknown` seul ne fait pas échouer le run.

---

## 3. Codes de sortie

    0   conforme    ni drift ni aveugle
    1   drift       au moins un `degraded`
    2   erreur      au moins un `unreachable`

**L'erreur l'emporte sur le drift.** Un run qui n'a pas pu mesurer est pire qu'un run qui a trouvé un
problème, parce que son silence a l'air sain. Convention alignée sur `provision doctor` — ne pas
diverger.

Le code se dérive **du flux**, jamais de compteurs internes : les sondes tournent dans des processus
séparés.

---

## 4. `cannot_conclude` — le champ qui vieillit le plus mal

Obligatoire à l'émission. Une sonde incapable d'énoncer sa limite ne rentre pas dans le toolkit : une
limite vide se lit comme « ceci prouve tout », et c'est l'affirmation qu'on ne veut jamais faire par
omission.

C'est aussi le champ qu'on perd en citant. D'où l'asymétrie des deux rendus :

- **terminal** — un coup d'œil. La limite n'apparaît que là où un lecteur pourrait **sur-lire**,
  c'est-à-dire sur tout ce qui n'est pas vert. `--full` les force toutes.
- **markdown** — un relevé. **Toutes**, toujours, y compris sur les lignes vertes. Un rapport archivé
  sans elles se lit six mois plus tard comme un certificat de bonne santé.

Deux rendus du même JSONL sont identiques à l'octet près, sauf l'horodatage de l'en-tête.

---

## 5. Le plan `capacites` — verdicts de `diag`

Une capacité n'est pas une mesure de plus : c'est une **projection** sur les verdicts déjà émis. Sa
chaîne distingue deux natures de maillon, et les confondre produirait le pire rapport possible.

| | ce que c'est | effet si rouge |
|---|---|---|
| **bloquant** | ce que je constate d'autorité : mon canal MCP, ce que la fleet publie d'elle-même | n'entreprends pas |
| **indicatif** | ce que je mesure **depuis ma place**, qui ne prouve rien du geste de la fleet | je ne peux pas confirmer — jamais « c'est cassé », jamais un vert |

La raison : un outil `mcp__fleet__*` **n'est pas exécuté par le pod**. Il l'appelle, la fleet
l'exécute — avec ses credentials, ses montages, son réseau. `forge.credentials` est `inactive` dans
*tout* pod par design ; l'inscrire en bloquant déclarerait `project_create` mort en permanence sur
une fleet parfaitement capable de le faire.

Préséance, et elle répond à « que dois-je faire », pas à « quelle est la couleur moyenne » :

    degraded  >  unreachable  >  inactive  >  unknown  >  operational

`degraded` passe devant `unreachable` parce qu'un fait constaté est plus actionnable qu'un trou.
`inactive` passe derrière les deux parce qu'une absence légitime n'a pas à masquer une panne.

Une chaîne qui désigne une sonde **disparue du flux alors que son plan a tourné** rend `unreachable`
en la nommant : c'est le détecteur de dérive de la chaîne elle-même. Sans lui, renommer une sonde
rendrait silencieusement toutes les capacités vertes.

---

## 6. Comment lire un relevé

1. **`instruments` d'abord.** Il mesure les angles morts du lecteur, pas la fleet. Ce qui suit ne
   vaut que ce qu'il dit.
2. **Les `aveugles` avant les `drift`.** Un `unreachable` invalide tout raisonnement fondé sur le
   silence de sa cible.
3. **Ne jamais conclure au-delà du `cannot_conclude`.**
4. **Zéro n'est pas une panne.** Zéro pod, zéro projet, zéro événement : états légitimes d'une fleet
   au repos ou d'un conteneur neuf.
5. **Une absence de rouge n'est pas une conformité** quand la déclaration n'a pas pu être lue : les
   lignes concernées sortent en `unknown`, et c'est délibéré.

---

## 7. Ce que le format ne porte pas

Aucune **sévérité**, aucune **priorité**, aucun **conseil de réparation**. Les trois demanderaient un
jugement que le toolkit n'a pas les moyens de rendre, et une sévérité fausse est plus nuisible qu'une
sévérité absente : elle décide à la place du lecteur.

Aucun **état persistant**, aucun **cache**. Un relevé porte son horodatage et rien d'autre — deux
runs se comparent en les diffant, pas en interrogeant une mémoire qui pourrait mentir.
