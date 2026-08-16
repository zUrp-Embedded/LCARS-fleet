# CLAUDE.md — conventions de ${REPO_NAME}

**Date** : ${YEAR}-${MONTH}-${DAY}
**Statut** : à compléter — ce fichier est un gabarit

> **Ce fichier est le plus rentable du dépôt.** Les sections de niveau deux ci-dessous sont
> **extraites automatiquement** et injectées dans le contexte de chaque agent qui travaille sur ce
> projet. Ce que vous n'écrivez pas ici, six agents le devineront différemment.
>
> Sept titres sont lus, et seulement ceux-là : `## Stack`, `## Build`, `## Test`, `## Doc`,
> `## Conventions`, `## Commands`, `## Gotchas`. Un titre différent n'est pas une erreur — il est
> simplement ignoré. Écrivez ce que vous voulez ailleurs dans le fichier, ça reste pour les humains.

## Stack

<!-- Ce que le projet utilise, et les VERSIONS. Un agent qui ignore votre version de framework
     écrira du code de la version qu'il connaît le mieux. -->

- Langage :
- Framework :
- Gestionnaire de paquets :
- Base de données :

## Build

<!-- La commande qui installe, et celle qui construit. Exactement, copiables. -->

```bash
npm install
npm run build
```

## Test

<!-- LA SECTION LA PLUS IMPORTANTE. Chaque agent doit jouer les tests avant de rendre, et il lit
     cette section pour savoir comment. Si elle est absente, il livrera SANS les jouer et le dira
     — c'est le contrat : il ne devine pas une commande de test. -->

```bash
npm test
```

Un seul fichier :

```bash
npm test -- chemin/du/fichier.test.js
```

## Doc

<!-- Où va la documentation, et laquelle va où.
     La distinction qui compte n'est pas la nature du document mais sa DESTINATION :
     ce qui part avec le produit vit ici, dans le dépôt ; ce qui sert à fabriquer
     (brouillons, plans, notes) vit dans l'atelier et ne part jamais. -->

- `docs/` — la documentation qui part avec le produit : installation, usage, API.
- `README.md` — la porte d'entrée : ce que c'est, comment on le lance en cinq minutes.

## Conventions

<!-- Ce qu'un nouveau développeur doit savoir avant sa première ligne. Écrivez les RÈGLES, pas
     l'inventaire de ce qui existe : un inventaire devient faux au premier changement, et personne
     ne le verra. -->

- Nommage des fichiers :
- Structure des dossiers :
- Style de commit :
- Branches :

## Commands

<!-- Les commandes du quotidien qu'on ne devine pas. -->

```bash
npm run dev        # serveur de développement
npm run lint       # analyse statique
```

## Gotchas

<!-- Les pièges. C'est la section qu'on remplit APRÈS s'être fait avoir, et c'est celle qui
     rapporte le plus : elle évite qu'un agent refasse une erreur qu'un humain a déjà payée.
     Une ligne par piège, avec ce qui se passe si on tombe dedans. -->

-
