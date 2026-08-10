# Faire tourner ce catalogue, et en faire le vôtre

**Date** : 2026-08-10
**Dernière révision** : 2026-08-10
**Statut** : actif — guide d'accompagnement du catalogue web
**Référencé par** : `catalogues/README.md`

Vous savez utiliser git et vous avez déjà travaillé avec un agent. Vous n'avez pas besoin de
connaître le fonctionnement interne de LCARS pour lire cette page — ni pour modifier ce catalogue.

---

## 1. Ce que vous avez entre les mains

Une **équipe** : six rôles et trois façons de traiter un ticket. Le runtime n'en connaît aucun. Il
exécute le catalogue qu'on lui désigne, et ce catalogue-ci décrit une petite équipe de développement
web.

Ce n'est pas un exemple réduit du catalogue de LCARS : c'est un autre métier. Chaque fichier
commente ses choix, et là où deux fichiers ne diffèrent que par une clé, cette différence est
l'explication.

## 2. Le modèle, en une phrase

> **Le rôle dit ce qu'un agent a le droit de faire et combien de temps il vit.
> La carte dit qui fait quoi, dans quel ordre, sur quelle branche, et qui juge quoi.**

C'est la seule chose à retenir avant d'ouvrir un fichier, et c'est ce qui surprend au début :
beaucoup de ce qu'on croit être une propriété du rôle appartient en fait à la carte.

Le `writer` de ce catalogue n'est pas « le rédacteur d'atelier ». C'est un rédacteur — et la carte
`content` l'envoie travailler dans l'atelier. Une autre carte pourrait l'envoyer produire de la
documentation qui part avec le produit, sur la branche principale, avec une relecture.

Conséquence pratique : **quand vous voulez changer un comportement, demandez-vous d'abord si c'est
une propriété de l'agent ou une propriété du traitement.** La réponse vous dit quel fichier ouvrir.

## 2 bis. Ce qu'un rôle n'est pas

C'est le contresens le plus coûteux, et il se fait dans la première heure.

**Un rôle n'est pas un modèle spécialisé.** Il n'y a pas un « modèle relecteur » plus doué pour la
revue et un « modèle développeur » plus doué pour le code. C'est **le même modèle sous les six**.
Ce qui les distingue est entièrement dans le catalogue : des outils différents, un prompt différent,
une place différente dans le pipeline, une durée de vie différente.

**Les noms sont donc là pour vous.** `dev`, `writer`, `maintainer` disent à un humain qui regarde un
ticket avancer ce que fait l'agent qui le tient. C'est de la lisibilité, pas de la capacité.
Renommer `code-reviewer` en `relecteur` ne change strictement rien à ce qu'il sait faire.

**Corollaire, et c'est ce qui vous fera écrire de bons profils** : un cap-profile décrit **ce qu'un
rôle fait et comment il opère** — ce qu'il a le droit de toucher, ce qu'il reçoit, ce qu'il rend,
combien de temps il vit. Il ne décrit **jamais** ce dont le modèle est capable.

Alors quand un résultat vous déçoit, l'ordre des questions est :

1. **Le prompt** (`agent-<rôle>-base.md`) — lui ai-je dit ce que j'attends ? C'est presque toujours
   là.
2. **Le brief** — le ticket disait-il assez pour qu'on n'ait pas à deviner ?
3. **Les outils** — a-t-il eu de quoi vérifier ce qu'il affirmait ? Un relecteur sans terminal juge
   à la lecture.
4. **`effort` et `model`** — en dernier. C'est la manette qu'on tourne en premier par réflexe, et
   celle qui rattrape le moins un rôle mal décrit.

(Le jour où un autre fournisseur de modèle est câblé, cette page gagnera une nuance. Elle n'en a pas
besoin aujourd'hui.)

## 3. Le faire tourner

Deux variables :

```bash
LCARS_CATALOGUE_ROOT=/opt/lcars/catalogues/web
LCARS_WORKSHOP_CARD=content
```

La première apporte le catalogue entier — chaque arbre en dérive son chemin.

La seconde désigne la carte d'**atelier**. Elle est nécessaire parce que c'est la seule chose de
tout le contrat qu'un catalogue ne peut pas encore déclarer lui-même : les rôles se résolvent par
capacité (§6), cette carte-là se désigne par son nom, et le nom par défaut est celui du catalogue de
LCARS. Sans cette variable, la flotte démarre — avec un avertissement explicite — mais aucun ticket
d'atelier n'atteint la carte.

Avant de démarrer quoi que ce soit :

```bash
mix lcars.catalogue.verify /chemin/vers/le/catalogue
```

Cette commande **rejoue tous les contrôles que le démarrage exécute**, sans démarrer de flotte : le
manifeste, les images gelées, la preuve que chaque rôle peut être lancé, la cohérence des cartes et
des rôles structurels, les politiques d'escalade. Elle rend `0` ou `1`.

C'est votre contrat de sortie. **Si elle passe, la flotte démarre dessus.** Lancez-la après chaque
modification : elle est instantanée et elle vous évite de découvrir une faute de frappe trois heures
plus tard, dans un pod.

## 4. Les six rôles

| Rôle | Ce qu'il fait | Vit |
|---|---|---|
| `tech-lead` | parle à l'humain, ouvre les tickets, arbitre | tant que le projet |
| `dev` | écrit le code | le temps d'un ticket |
| `writer` | rédige la documentation et les notes | le temps d'un ticket |
| `spec-reviewer` | relit la **demande**, avant qu'on code | le temps d'un verdict |
| `code-reviewer` | relit le **code livré** | le temps d'un verdict |
| `maintainer` | signe la fusion, tranche les exceptions | le temps d'un verdict |

Ordre de lecture conseillé : **`dev.yaml` en entier** (il commente chaque clé une fois), puis les
cinq autres — chacun ne commente que ce qui change chez lui.

Chaque rôle a deux fichiers, et la distinction compte :

- `cap_profile/canon/cap-profiles/<rôle>.yaml` — ses **permissions** et son cycle de vie ;
- `sp_builder/sp_drafts/agent-<rôle>-base.md` — sa **compétence**, en français, adressée à lui.

`dev` et `writer` ont des permissions presque identiques. Ce qui en fait deux métiers, c'est le
second fichier.

## 5. Les trois cartes

| Carte | Étapes | Jury | Intégration continue | Pour |
|---|---|---|---|---|
| `quick-fix` | `dev` | aucun | ignorée | ce qu'on refait sans regret |
| `standard` | `spec-reviewer` → `dev` | `code-reviewer` | exigée | tout ce qui vit |
| `content` | `writer` (atelier) | aucun | ignorée | ce qui ne part pas avec le produit |

**Le niveau d'exigence est le contenu de ces trois colonnes**, pas un réglage du runtime. Deux
tickets du même projet peuvent être traités avec deux niveaux de soin différents.

Comparez `quick-fix` et `standard` : trois lignes changent, et rien d'autre.

## 6. Les cinq capacités — la partie qui rend vos noms libres

Le runtime ne connaît aucun nom de rôle. Quand il a besoin de savoir qui produit ou qui signe, il
cherche le rôle qui **déclare la capacité** correspondante.

| Capacité | Répond à | Combien |
|---|---|---|
| `producer` | qui fabrique le livrable | **au moins un** — plusieurs est normal, les cartes choisissent |
| `exception_judge` | qui signe la fusion | **exactement un** |
| `conflict_resolver` | qui tranche un blocage épuisé | **exactement un** |
| `project_delegate` | qui arbitre pour un projet | **exactement un** |
| `onboarder` | qui peut accueillir un projet | — |

Zéro ou deux sur une capacité unique : **le démarrage refuse et nomme le problème.** C'est voulu —
un catalogue incohérent doit tomber au déploiement, pas au premier ticket.

Deux conséquences, et ce sont les deux bonnes nouvelles de ce modèle :

1. **Renommer un rôle ne casse rien** tant que la capacité reste déclarée. `dev` peut devenir
   `frontend`. Il faut juste renommer aussi son fichier de prompt et les cartes qui l'appellent —
   `verify` vous dira si vous en avez oublié.
2. **Une capacité se pose sur le rôle que votre métier a**, pas un rôle par capacité. Ici,
   `tech-lead` en porte trois : dans une équipe de cinq personnes, l'accueil, l'arbitrage et la
   résolution de conflit sont la même personne. Le catalogue de LCARS les répartit sur trois rôles
   parce qu'il modélise une organisation plus grande. Les deux sont valides.

## 7. Les gestes courants

**Ajouter un juge sur une carte** — un nom dans `jury`. Le rôle doit exister ; le démarrage vérifie.

```yaml
jury: [code-reviewer, securite]
```

**Durcir un projet** — changez la carte que ses tickets prennent, pas le runtime.

**Renommer un rôle** — trois endroits : `metadata.name`, le nom du fichier de prompt
(`agent-<nom>-base.md`), et les cartes qui le nomment. Puis `verify`.

**Ajouter un mode opératoire** — deux fichiers, aucun code :
`cap_profile/canon/cap-profiles/modop/<nom>/profile.yaml` (contenant `{}`) et
`cap_profile/canon/modop-bundles/<nom>/sp.md` (le texte). Puis listez-le dans le `modop_set.optional`
d'un rôle, et demandez-le par étape dans une carte (`modops: [<nom>]`).

**Changer le modèle ou l'effort d'un rôle** — `invocation.model` et `invocation.effort`. Ce sont les
deux premières manettes à bouger si le coût ou la qualité ne conviennent pas.

**Retirer une étape** — supprimez-la des `steps` et retirez-la des `needs` de ses successeurs. Le
rôle reste dans le catalogue, simplement plus personne ne l'appelle. Rien à supprimer par ailleurs.

## 8. Ce qui n'est PAS à vous

Deux arbres restent au runtime et ne se remplacent pas :

- les **schémas** — les contrats contre lesquels votre catalogue est validé ;
- la **base de sécurité** — les planchers qu'un catalogue ne peut pas abaisser.

Même règle pour les deux : *ce qu'un opérateur ne doit pas pouvoir remplacer est un contrat, et un
contrat qu'on peut remplacer ne contraint rien.*

De la même façon, une carte gouverne le **jugement** — combien de relecteurs, quelle exigence — mais
jamais le **plancher mécanique** : identité de l'auteur, absence de secrets, la branche descend bien
de sa base. `jury: []` ne désactive rien de tout ça.

## 9. Les limites, aujourd'hui

Trois, nommées plutôt que découvertes :

**Le socle des prompts est recopié six fois.** La partie commune aux six rôles — le protocole de
boucle, le sanctuaire, la règle de preuve — est identique dans chaque `agent-<rôle>-base.md`. Le
catalogue de LCARS la compose depuis des blocs partagés ; l'outil qui fait ça ne sert que lui. Si
vous modifiez le socle, modifiez-le partout : rien ne vous préviendra.

**Les comptes forge de vos rôles se dérivent, mais il faut le demander.** Vos rôles ont besoin d'un
compte et d'un jeton sur la forge, sinon rien n'est commité à leur nom. La liste ne se devine pas
au démarrage — elle se lit depuis votre catalogue, une fois, au provisionnement :

```bash
etc/enroll-catalogue.sh --catalogue /chemin/vers/mon-catalogue --tofu-dir <recette-forge>
```

Le script écrit les entrées de la recette forge (`roles.auto.tfvars.json`) et vous rend la ligne
`PROV_ROLES` à poser avant la frappe des jetons. Vous pouvez aussi lire la liste seule :

```bash
mix lcars.catalogue.roles /chemin/vers/mon-catalogue
```

Ce que le script **n'écrit pas** : la recette elle-même. Ce qu'un compte a le droit d'être — créer
une organisation, poser un hook serveur, les équipes — appartient au runtime. Votre catalogue nomme
ses gens ; il ne décide pas de ce qu'être l'un d'eux permet.

**Le catalogue de référence part quand même avec la boîte.** `LCARS_CATALOGUE_ROOT` décide de ce
qui est **lu**, pas de ce qui est **livré**. Les deux coexistent dans l'image ; c'est la variable qui
tranche. Vérifiez la ligne `Catalogue: verified (root=…)` dans les journaux de démarrage — elle dit
lequel tourne.

## 10. Où sont les fichiers

```
catalogue.yaml                              le manifeste (version de contrat)
cap_profile/canon/cap-profiles/             les six rôles
cap_profile/canon/cap-profiles/modop/       les modes opératoires (déclaration)
cap_profile/canon/modop-bundles/            les modes opératoires (le texte)
cap_profile/canon/subagent-templates/       les sous-agents
cap_profile/canon/config/                   le gabarit de criticité d'un projet
sp_builder/sp_drafts/                       les prompts, un par rôle, + les protocoles
sp_builder/templates/                       les deux gabarits qui assemblent tout prompt
workflow/canon/workflow_maps/               les trois cartes
workflow/brief_templates/                   ce qu'on remet aux agents et aux juges
coord/config/coord-policies.yaml            que faire quand ça se passe mal
project_template/{main,workshop,ops}        le squelette d'un projet accueilli
skills/canon/                               les procédures montées à la demande (vide ici)
```
