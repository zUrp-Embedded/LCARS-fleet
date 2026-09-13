# ${REPO_NAME}

**Date** : ${YEAR}-${MONTH}-${DAY}
**Dernière révision** : ${YEAR}-${MONTH}-${DAY}
**Statut** : actif — conventions de ce dépôt, lues par la fleet à chaque spawn
**Référencé par** : les pods de la fleet (extraction sélective, voir plus bas)

> ${REPO_DESCRIPTION}

## Ce fichier est lu par une machine, et voilà laquelle

**Les sections ci-dessous naissent vides et sont à remplir** — c'est une consigne au lecteur, pas
un état du fichier. Elle vivait dans le `**Statut**`, où elle devenait FAUSSE le jour où quelqu'un
faisait le travail : mesuré le 2026-08-12, un dépôt dont les sept sections étaient remplies par un
producteur annonçait encore « squelette d'onboarding, à remplir » dans son en-tête. Un statut décrit
un état durable ; une instruction s'adresse à celui qui lit. Qui remplit une section met aussi à
jour la **Dernière révision** — c'est la seule ligne de l'en-tête qui a le droit de bouger.


À chaque spawn, la fleet lit ce fichier et recopie dans le `CLAUDE.md` du pod **sept sections de
niveau 2, et sept seulement** :

`## Stack` · `## Build` · `## Test` · `## Doc` · `## Conventions` · `## Commands` · `## Gotchas`

Aucune autre ne voyage — un titre nommé autrement ne part pas au pod. Une section recopiée devient
une **directive** pour l'agent qui produit sur ce dépôt : ce qui est écrit ici est ce qu'il tiendra
pour vrai, sans pouvoir le vérifier ailleurs.

**Une huitième section existe, et elle ne voyage PAS** : `## Harness`, décrite plus bas. Ce n'est
pas une directive pour l'agent, c'est un fait que le **rail** lit pour mesurer. La distinction n'est
pas cosmétique : ce qui part au pod, l'agent le tient pour vrai sans recours ; ce qui reste ici sert
à une machine qui vérifie.

**Elles ne sont pas pré-remplies exprès.** Une section présente mais creuse ferait croire à la fleet
qu'elle a du contexte, et à l'agent qu'il a une commande. Tant qu'elles n'existent pas, le runtime
le DIT à chaque spawn (`RepoSections: … NO section matched …`) — un silence eût été pire.

**La plus chère est `## Test`** : sans elle, un producteur ne sait pas comment prouver ce qu'il
livre, et son protocole lui interdit de prétendre l'avoir prouvé. Écris-y la commande EXACTE qui
joue la suite de ce projet, et rien d'autre.

**Et cette commande DOIT être celle du workflow CI** (`.gitea/workflows/ci.yml`, quand le projet en
a un) — la même, à l'identique. Le producteur la joue chez lui (sa boucle interne) ; le runner la
rejoue sur le sha livré (la preuve de référence, crue sur parole par tout le rail). Deux commandes
différentes font deux verts qui ne se prédisent pas : « vert chez moi » cesse de vouloir dire
quelque chose, et le premier rouge du runner sur un vert local part en diagnostic au mauvais
étage. Qui réécrit l'un met l'autre à jour dans le même geste.

**`## Doc` est sa jumelle, sur l'autre moitié de la même obligation.** `## Test` dit comment
prouver ce qu'on livre ; `## Doc` dit **où va la documentation livrée et ce qu'on y attend**. Sans
elle, `docs/` est un dossier que tout projet possède et qu'aucun producteur ne reçoit jamais la
consigne de nourrir : la doc qui sort finit écrite par qui la remarque, ou pas écrite du tout.

⚠ Ne pas confondre avec la face **atelier** (`workshop`). Là-bas vivent les brouillons, le backlog
et les plans — le matériau dont ce projet est fait, qui **ne part avec aucune release**. Ici, dans
`docs/`, vit ce qui **sort** : doc utilisateur, doc mainteneur, doc de fork. Le critère n'est pas la
nature de l'artefact (de la prose reste de la prose) mais sa **destination** — et ce qui sort se
fait juger comme n'importe quel autre livrable.

⚠ Et **n'ouvre pas** ces titres pour les laisser vides : un `## Test` qui contient « (à compléter) »
matche, donc l'avertissement s'éteint, donc la fleet croit avoir du contexte et l'agent croit avoir
une commande. Un titre absent est un manque visible ; un titre creux est un mensonge silencieux.

## `## Harness` — la huitième section, celle qui sépare le code de la preuve

Elle liste les chemins qui sont de la **preuve** dans ce dépôt, un par ligne ou séparés par des
espaces. Rien d'autre :

```
## Harness

tests/
```

**À quoi elle sert.** La sonde `.gitea/workflows/probe-test-relevance.yml` remet le code d'une
livraison à son état de base **en gardant sa suite**, et regarde si la suite s'en aperçoit. Pour
faire ça, il faut savoir lesquels de tes fichiers sont du code et lesquels sont la preuve. C'est la
seule chose que cette section dit.

**Pourquoi tu la déclares au lieu de laisser deviner.** Une heuristique (`test/`, `spec/`,
`*_test.*`) marche partout et se trompe en silence — et se tromper ici veut dire remettre à leur
état de base des fichiers qui étaient ta preuve, donc **accuser ta livraison à tort**. Un fait faux
qui se présente comme une mesure coûte plus cher que pas de mesure du tout. Absente, la sonde se
déclare *inapplicable* et le dit ; elle ne devine jamais.

**Elle suit tes tests, elle ne les commande pas.** Si tu déplaces ta suite, mets-la à jour dans le
même geste — même obligation que `## Test` avec `.gitea/workflows/ci.yml`. Une déclaration qui a
dérivé fait mesurer autre chose que ce qu'on croit mesurer, et la sonde n'a aucun moyen de le
savoir : elle CITE ce qu'elle a lu, précisément pour qu'un juge qui vient de lire le diff puisse
écarter le fait.

⚠ Elle ne s'appelle **pas** `## Test paths`, et ce n'est pas un choix de style : la fleet reconnaît
`## Test` sur une frontière de mot, donc `## Test paths` serait extraite comme une **deuxième**
section `## Test` et partirait au pod. Le producteur y lirait des chemins là où son contrat promet
« la commande EXACTE, et rien d'autre ».
