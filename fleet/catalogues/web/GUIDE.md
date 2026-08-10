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

Ce catalogue est **livré avec la boîte, et inactif**. C'est délibéré, et c'est la démonstration du
mécanisme : installé ne veut pas dire actif. Il est là, lisible, copiable, et il ne fait rien tant
que personne ne le nomme.

```bash
lcars catalogue list                 # ce qui est installé, et ce qui tourne
lcars catalogue verify web           # les contrôles du démarrage, sans démarrer
lcars catalogue enable web           # ajoute une ligne à la déclaration
```

`enable` **refuse** un catalogue que `verify` ne passe pas — c'est ce qui fait de la vérification
une condition d'activation plutôt qu'un outil qu'on peut sauter. Et il ne prétend pas agir à chaud :
la flotte gèle ses images au démarrage, donc il vous rend le geste qui applique
(`fleet_v2 stop && fleet_v2 start`).

La déclaration est un fichier ordinaire, et l'**ordre des lignes EST la précédence** :

```
# ~/.lcars/catalogues.active
web        # le vôtre, devant
lcars      # le métier livré avec la boîte — retirez la ligne s'il ne sert plus
```

Le premier qui porte un fichier gagne. C'est la règle du thème enfant, appliquée à des catalogues
entiers : vous n'avez pas à tout réécrire pour changer une partie.

**Pour l'essayer sans rien activer**, une variable suffit et n'engage rien :

```bash
LCARS_CATALOGUE_ROOT=/opt/lcars/catalogues/web
```

Elle apporte le catalogue entier — chaque arbre en dérive son chemin. C'est la grosse molette : un
catalogue, une variable. La déclaration ci-dessus est ce qui permet d'en faire tourner **plusieurs**.

Une seconde variable reste nécessaire dans les deux cas :

```bash
LCARS_WORKSHOP_CARD=content
```

Elle désigne la carte d'**atelier**. Elle est nécessaire parce que c'est la seule chose de
tout le contrat qu'un catalogue ne peut pas encore déclarer lui-même : les rôles se résolvent par
capacité (§6), cette carte-là se désigne par son nom, et le nom par défaut est celui du catalogue de
LCARS. Sans cette variable, la flotte démarre — avec un avertissement explicite — mais aucun ticket
d'atelier n'atteint la carte.

Avant de démarrer quoi que ce soit — `lcars catalogue verify <nom>` depuis la boîte, ou, depuis le
dépôt, sur un chemin quelconque :

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
appartienne.** Les quatre autres, le runtime les résout tout seul, à l'échelle de la flotte, et
chacune doit avoir **exactement un** porteur.

Rien ne vous les interdit *par principe*. Ce qui est refusé, c'est le **résultat** : si votre
`code-reviewer` déclare `exception_judge`, le `gatekeeper` du système la déclare aussi, et plus
personne ne sait qui signe. Le démarrage s'arrête, et il nomme les deux :

```
Fleet.Project.Roles: 2 catalogue roles declare the gatekeeper capability
(:exception_judge): ["code-reviewer", "gatekeeper"] — this one is unique BY DESIGN
```

Même chose pour `role_index`, qui est l'emplacement du rôle dans l'identifiant de session — donc sa
classe de kill. Deux rôles sur un même emplacement, et `pkill` en atteint deux :

```
CapProfile.Image: role_index 0 claimed by starfleet, vitrine — a slot is a kill class,
and two roles sharing one make `pkill` reach both.
```

### Choisir un `role_index`

Il en existe **seize, de 0 à 15, pour tout le déploiement** — pas seize par catalogue. Ce n'est pas
un réglage : c'est la largeur du champ dans l'identifiant de session, celui qui rend
`pkill -f 'claude.*1badcafe'` capable de viser une classe de pods sans en toucher une autre.

Le catalogue système en occupe quelques-uns, celui de LCARS aussi si vous le laissez actif. **Ne
recopiez pas ici la liste de ce qui est pris** — elle sera fausse le jour où un rôle bouge. Posez
un numéro, démarrez, et lisez le refus : il **nomme les deux rôles et le slot**, ce qui est plus
fiable qu'une liste dans un guide.

Deux conséquences pratiques :

- un rôle de plus dans votre catalogue, c'est un slot de moins pour tout le monde. Si vous visez
  une grosse équipe, retirez le catalogue de LCARS de la déclaration (§3) — il en libère six ;
- `role_index: 0` n'est pas un numéro comme les autres : il **signifie** « niveau flotte, jamais
  moissonné ». C'est le seul endroit où un chiffre de votre catalogue a un sens fixé par le code.

La nuance a un usage, et c'est la porte de sortie si vous voulez vraiment votre propre signataire :
vous ne l'**ajoutez** pas, vous **remplacez** le sien. Un fichier nommé `gatekeeper.yaml` dans
votre catalogue prend la place de celui du système — un seul porteur, un seul emplacement, ça
passe. Le nom est le contrat ; le fichier système n'est qu'un défaut. Voyez §8.

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

**« Ne se remplacent pas » parle des FICHIERS.** Vous ne pouvez pas éditer le catalogue système :
il part avec la boîte, personne n'y touche, et c'est ce qui fait qu'il contraint. Mais ce que le
runtime **lit** n'est pas un dossier, c'est un chemin de recherche : le vôtre d'abord, le sien
ensuite. Un nom porté des deux côtés n'est donc pas un conflit — c'est une **surcharge**, et c'est
le vôtre qui gagne.

C'est un mécanisme, pas une permission spéciale : le même qu'un `.htaccess` à côté de la conf
d'Apache, ou qu'un thème enfant WordPress. Il gagne en existant au même chemin relatif. Rien n'est
écrit sur le disque du système, rien n'est effacé — la résolution se fait à la lecture, et si vous
retirez votre fichier, le sien réapparaît intact.

Ce que ça vous ouvre : reprendre un prompt de la mécanique et le réécrire — dans votre langue, à
votre ton — sans toucher à un octet du runtime. Ce que ça vous coûte : un nom recopié par erreur
prend silencieusement la place du sien. Un nom doit vouloir dire une seule chose.

Dans l'autre sens, l'héritage est généreux : les modes opératoires du système sont **visibles depuis
votre catalogue** sans que vous ayez à les recopier. Vous ajoutez les vôtres à côté.

De la même façon, une carte gouverne le **jugement** — combien de relecteurs, quelle exigence — mais
jamais le **plancher mécanique** : identité de l'auteur, absence de secrets, la branche descend bien
de sa base. `jury: []` ne désactive rien de tout ça.

## 9. Les limites, aujourd'hui

Deux, nommées plutôt que découvertes.

**~~Le socle des prompts est recopié dans chaque rôle.~~** ✅ **Levée.** C'était la limite la plus
coûteuse du lot, et sa forme exacte vaut d'être dite parce qu'elle explique le mécanisme.

Mesuré sur les quatre prompts de ce catalogue (432 lignes) : **27 lignes de fond sont partagées, par
DEUX ou TROIS d'entre eux — aucune par les quatre.** Le sanctuaire est dans trois, l'armement du
réveil dans deux (les juges ne vivent pas assez longtemps pour être réveillés), le contrat de
livrable dans deux (seuls les producteurs rendent du code).

C'est pour ça que `sp-map.yaml` est une **liste par rôle** et pas un préambule global : la
duplication n'a jamais eu la forme d'un socle unique recopié quatre fois, elle a la forme de
plusieurs blocs partagés par des sous-ensembles différents. La carte des blocs épouse cette forme —
chaque rôle nomme les siens.

Et modifier l'une de ces 27 lignes dans un seul prompt ne déclenchait rien.

Le composeur ne sert plus seulement au catalogue de LCARS :

```bash
mix lcars.sp.gen --catalogue /chemin/vers/mon-catalogue
```

Il lit `sp_builder/sp_blocks/sp-map.yaml` (rôle → liste ordonnée de blocs) et écrit les
`agent-<rôle>-base.md`. Et les sept blocs `core/` — ceux qui décrivent le contrat du runtime avec
son pod — sont **livrés par le système** : vous ne les recopiez pas, vous les héritez. Pour en
réécrire un, posez un fichier du même nom relatif dans votre catalogue ; le vôtre gagne, sans qu'un
octet du système bouge.

Ce catalogue-ci reste écrit à la main, et c'est légitime : **un catalogue sans `sp_blocks/` du tout
est valide**, `verify` le dit. Le composeur est un outil, pas une obligation — mais il est là le
jour où quatre copies deviennent huit.

**Passer un rôle du prompt à la main aux blocs, concrètement** — et il y a une marche, que l'outil
vous met sous le nez plutôt que de vous l'écraser :

```bash
# 1. les blocs qui vous appartiennent (core/ vient du système, ne le recopiez pas)
mkdir -p sp_builder/sp_blocks/role
$EDITOR sp_builder/sp_blocks/role/dev.md
cat > sp_builder/sp_blocks/sp-map.yaml <<'MAP'
dev:
  - core/runtime-contract
  - core/producer-output
  - role/dev
MAP

# 2. RETIRER le prompt écrit à la main de ce rôle — sinon l'outil REFUSE, pour ne pas l'écraser
rm sp_builder/sp_drafts/agent-dev-base.md

# 3. composer
mix lcars.sp.gen --catalogue "$PWD"
```

Le `agent-dev-base.md` régénéré porte les deux blocs du **système** puis le vôtre, dans l'ordre de
la liste. Vous n'avez écrit que la partie qui est de vous.

L'audit refuse les trois désaccords : un rôle sans entrée **ni** prompt, une entrée pour un rôle que
le catalogue ne porte pas, et une entrée **plus** un prompt écrit à la main — le refus de l'étape 2,
et c'est la seule chose destructrice que cet outil pourrait faire.

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

**Le catalogue de référence part quand même avec la boîte.** Ce qui est **livré** et ce qui est
**lu** sont deux questions distinctes : les deux catalogues coexistent dans l'image, et c'est la
déclaration d'activité (§3) qui tranche — ou `LCARS_CATALOGUE_ROOT` si vous n'en faites tourner
qu'un. Retirer la ligne `lcars` de la déclaration cesse de l'utiliser sans rien supprimer.

Vérifiez la ligne `Catalogue: verified (root=…)` dans les journaux de démarrage, et
`lcars catalogue list` à tout moment — elle dit ce qui tourne, dans l'ordre.

## 10. Où sont les fichiers

```
catalogue.yaml                              le manifeste (version de contrat)
cap_profile/canon/cap-profiles/             vos quatre rôles
cap_profile/canon/cap-profiles/modop/       les modes opératoires (déclaration)
cap_profile/canon/modop-bundles/            les modes opératoires (le texte)
cap_profile/canon/subagent-templates/       les sous-agents
cap_profile/canon/config/                   le gabarit de criticité d'un projet
sp_builder/sp_drafts/                       vos prompts, un par rôle, + les protocoles
sp_builder/sp_blocks/                       (facultatif) les blocs, si vous composez — cf. §9
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
