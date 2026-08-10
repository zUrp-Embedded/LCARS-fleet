# Faire tourner ce catalogue, et en faire le vôtre

**Date** : 2026-08-10
**Dernière révision** : 2026-08-10
**Statut** : actif — guide d'accompagnement du catalogue web
**Référencé par** : `catalogues/README.md`

Vous savez utiliser git et vous avez déjà travaillé avec un agent. Vous n'avez pas besoin de
connaître le fonctionnement interne de LCARS pour lire cette page — ni pour modifier ce catalogue.

---

## 1. Ce que vous avez entre les mains

Une **équipe** : quatre rôles et trois façons de traiter un ticket. Le runtime n'en connaît aucun.
Il exécute le catalogue qu'on lui désigne, et ce catalogue-ci décrit une petite équipe de
développement web.

Ce n'est pas un exemple réduit du catalogue de LCARS : c'est un autre métier. Chaque fichier
commente ses choix, et là où deux fichiers ne diffèrent que par une clé, cette différence est
l'explication.

**Quatre rôles seulement, et c'est le point.** Une flotte en fait tourner huit : les quatre d'ici,
plus quatre autres qui viennent du **catalogue système** — l'accueil, le délégué de projet, le
signataire des fusions, l'arbitre des blocages. Ceux-là ne sont pas de votre métier : ce sont les
pièces de la mécanique, ils sont livrés avec le runtime, et vous ne les écrivez pas.

C'est ce qui rend ce catalogue petit. Les quatre rôles qui restent sont ceux dont une équipe web
discute vraiment : qui écrit le code, qui rédige, qui relit la demande, qui relit le diff.

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
revue et un « modèle développeur » plus doué pour le code. C'est **le même modèle sous tous**.
Ce qui les distingue est entièrement dans le catalogue : des outils différents, un prompt différent,
une place différente dans le pipeline, une durée de vie différente.

**Les noms sont donc là pour vous.** `dev`, `writer`, `code-reviewer` disent à un humain qui regarde un
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

## 4. Les quatre rôles — et les quatre que vous héritez

**Les vôtres**, dans ce catalogue :

| Rôle | Ce qu'il fait | Vit |
|---|---|---|
| `dev` | écrit le code | le temps d'un ticket |
| `writer` | rédige la documentation et les notes | le temps d'un ticket |
| `spec-reviewer` | relit la **demande**, avant qu'on code | le temps d'un verdict |
| `code-reviewer` | relit le **code livré** | le temps d'un verdict |

**Ceux du catalogue système**, que toute flotte porte et que vous n'écrivez pas :

| Rôle | Ce qu'il fait | Pourquoi il n'est pas à vous |
|---|---|---|
| `starfleet` | l'accueil : ouvre les projets, parle à l'humain | il doit exister **avant** tout dépôt — aucun projet ne peut le porter |
| `architect` | le délégué d'un projet : arbitre, rédige les tickets | le runtime le crée par dépôt ; aucune carte ne le nomme |
| `gatekeeper` | signe la fusion | **exactement un** par flotte, rien ne le sélectionne |
| `chief` | tranche un blocage épuisé | **exactement un**, atteint par escalade |

La règle qui les sépare des vôtres se teste seule : **est-ce qu'une carte le nomme ?** Un rôle qu'une
carte nomme est du métier — c'est un producteur, c'est un juge. Un rôle que le runtime va chercher
tout seul, pour tenir sa propre mécanique, est du système.

Ordre de lecture conseillé : **`dev.yaml` en entier** (il commente chaque clé une fois), puis les
trois autres — chacun ne commente que ce qui change chez lui.

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

## 6. Les capacités — celle qui est à vous, et les quatre qui ne le sont pas

Le runtime ne connaît aucun nom de rôle. Quand il a besoin de savoir qui produit ou qui signe, il
cherche le rôle qui **déclare la capacité** correspondante. Il y en a cinq, et elles se répartissent
exactement comme les rôles :

| Capacité | Répond à | À qui |
|---|---|---|
| `producer` | qui fabrique le livrable | **à vous** — au moins un, plusieurs est normal, les cartes choisissent |
| `onboarder` | qui peut accueillir un projet | système |
| `project_delegate` | qui arbitre pour un projet | système, **exactement un** |
| `exception_judge` | qui signe la fusion | système, **exactement un** |
| `conflict_resolver` | qui tranche un blocage épuisé | système, **exactement un** |

**`producer` est la seule capacité qu'une carte sélectionne. C'est ce qui en fait la seule qui vous
appartienne.** Les quatre autres, le runtime les résout tout seul, à l'échelle de la flotte : les
déclarer dans votre catalogue reviendrait à décider qui signe les fusions de tout le monde.

Le vérificateur le refuse, et il le dit :

```
business conformance: code-reviewer declares exception_judge — these capabilities belong
to the system catalogue: the runtime resolves each of them alone and fleet-wide.
```

Il refuse aussi `role_index: 0` dans un catalogue métier — c'est l'emplacement de niveau flotte, il
appartient à la mécanique.

**Vos juges n'ont besoin d'aucune capacité.** Regardez `code-reviewer.yaml` : il n'en déclare pas.
Ce sont les cartes qui le nomment, dans leur liste `jury`. Une capacité sert à répondre à une
question que le RUNTIME se pose ; en déclarer une décorative n'ajoute que des façons de casser le
démarrage.

**La bonne nouvelle du modèle : renommer un rôle ne casse rien.** `dev` peut devenir `frontend` tant
que `producer` reste déclaré. Il faut renommer aussi son fichier de prompt et les cartes qui
l'appellent — `verify` vous dira si vous en avez oublié.

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

Trois choses restent au runtime et ne se remplacent pas :

- les **schémas** — les contrats contre lesquels votre catalogue est validé ;
- la **base de sécurité** — les planchers qu'un catalogue ne peut pas abaisser ;
- le **catalogue système** — les quatre rôles de la mécanique (§4) et les modes opératoires qu'ils
  déclarent.

Même règle pour les trois : *ce qu'un opérateur ne doit pas pouvoir remplacer est un contrat, et un
contrat qu'on peut remplacer ne contraint rien.*

Le catalogue système n'a **pas de variable** : il est embarqué, comme les schémas. Vous apportez
votre métier ; vous ne choisissez pas votre mécanique. C'est aussi ce qui rend vérifiable la phrase
« ce catalogue est complet » — le système est présent et intact, le vôtre est conforme, et les deux
questions se posent séparément.

Un nom porté des deux côtés est **refusé**, pas arbitré : votre `rubber-duck` ne remplace pas le
sien, et le sien n'écrase pas le vôtre. Renommez le vôtre. Un nom doit vouloir dire une seule chose.

Dans l'autre sens, l'héritage est généreux : les modes opératoires du système sont **visibles depuis
votre catalogue** sans que vous ayez à les recopier. Vous ajoutez les vôtres à côté.

De la même façon, une carte gouverne le **jugement** — combien de relecteurs, quelle exigence — mais
jamais le **plancher mécanique** : identité de l'auteur, absence de secrets, la branche descend bien
de sa base. `jury: []` ne désactive rien de tout ça.

## 9. Les limites, aujourd'hui

Trois, nommées plutôt que découvertes :

**Le socle des prompts est recopié dans chaque rôle.** La partie commune aux quatre — le protocole
de boucle, le sanctuaire, la règle de preuve — est identique dans chaque `agent-<rôle>-base.md`. Le
catalogue de LCARS la compose depuis des blocs partagés ; l'outil qui fait ça ne sert que lui. Si
vous modifiez le socle, modifiez-le partout : rien ne vous préviendra.

C'est la limite la plus coûteuse du lot, et le découpage système l'a **réduite sans la supprimer** :
quatre copies au lieu de six, puisque les prompts de la mécanique ne sont plus les vôtres.

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
cap_profile/canon/cap-profiles/             vos quatre rôles
cap_profile/canon/cap-profiles/modop/       les modes opératoires (déclaration)
cap_profile/canon/modop-bundles/            les modes opératoires (le texte)
cap_profile/canon/subagent-templates/       les sous-agents
cap_profile/canon/config/                   le gabarit de criticité d'un projet
sp_builder/sp_drafts/                       vos prompts, un par rôle, + les protocoles
sp_builder/templates/                       les deux gabarits qui assemblent tout prompt
workflow/canon/workflow_maps/               les trois cartes
workflow/brief_templates/                   ce qu'on remet aux agents et aux juges
coord/config/coord-policies.yaml            que faire quand ça se passe mal
project_template/{main,workshop,ops}        le squelette d'un projet accueilli
skills/canon/                               les procédures montées à la demande (vide ici)
```

Et ce qui n'est **pas** ici, parce que ce n'est pas à vous — les quatre rôles de la mécanique, leurs
prompts et les modes opératoires qu'ils déclarent vivent dans le catalogue système, livré avec le
runtime. Vous les lisez si vous voulez comprendre ; vous ne les éditez pas.
