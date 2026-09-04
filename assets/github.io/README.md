# Site vitrine LCARS

**Date** : 2026-08-05
**Dernière révision** : 2026-08-18
**Statut** : actif — la plaquette publique, construite depuis le code du produit
**Référencé par** : `.github/workflows/site.yml`

Le site public (`github.io`) : huit pages, construites par Astro, publiées par GitHub Pages.

## La pile

Trois choses, et rien d'autre :

| | |
|---|---|
| **Astro 5** | générateur statique — zéro JS envoyé au navigateur, pas de framework d'interface |
| **js-yaml** | pour lire les YAML du catalogue |
| **Node 24** | la version que le workflow épingle (`setup-node`) |

Pas de CMS, pas de base, pas d'API : le build lit des fichiers du dépôt et écrit du HTML.

## Ce qu'il LIT — dans le vrai code, jamais recopié

C'est la propriété qui justifie que ce site vive dans le dépôt du produit : **même arbre, même
commit**, donc il ne peut pas décrire une autre version que celle qui est là. Pas d'épinglage à
tenir, pas de snapshot à resynchroniser, pas d'affichage de fraîcheur à maintenir.

| source | ce qu'on en tire |
|---|---|
| `runtime/priv/catalogue/workflow/workflow_maps/` | les cartes, avec la `presentation:` que le catalogue écrit déjà pour un humain |
| `runtime/priv/catalogue/cap_profile/cap-profiles/` | les sièges — champs **structurels** seulement |
| `runtime/priv/catalogue-system/cap_profile/cap-profiles/` | les rôles de mécanique, comptés |
| `runtime/priv/workflow/schema/gate-decision.json` | les verdicts, lus dans l'`enum` |
| `runtime/lib/fleet/catalogue.ex` | les 13 arbres d'un catalogue, les générations d'API, le nom réservé, les surcharges fines |
| `runtime/lib/fleet/layout.ex` | où vivent les catalogues |
| `runtime/bin/lcars`, `runtime/bin/fleet_v2` | les verbes de la console, et les trois états d'un catalogue |
| `runtime/lib/fleet/mcp/pod_tools*.ex` | les outils, par porteur |
| `runtime/bin/claude_launch.sh` | la frontière vendor |

**Ce qui n'est JAMAIS lu** : le texte de prompt des cap-profiles. C'est du package SP, écrit en
français pour calibrer un comportement agentique, explicitement hors périmètre de publication.

### Les gardes — le build ÉCHOUE plutôt que de mentir

Elles ne sont pas décoratives : elles ont attrapé trois dérives réelles le 2026-08-18, sur un site
que personne ne construisait plus.

- un **arbre** ajouté à `Fleet.Catalogue` sans libellé ici → build rouge, plutôt qu'un nom d'atome
  affiché en public ;
- un **verbe** de la console sans prose, ou une prose sans verbe → build rouge, dans les deux sens ;
- un **attribut** disparu du code (`@active_catalogues_basename`, mort avec le modèle d'activité)
  → build rouge, avec le nom de ce qui manque.

Corollaire assumé : déplacer ou renommer le catalogue **casse ce build**. C'est voulu. Une plaquette
qui ne trouve plus ce qu'elle décrit doit échouer bruyamment, pas servir la version d'avant.

## Ce qu'il CRÉE

`dist/` — 8 pages HTML statiques, ~300 Ko, une URL par dossier :

    /            l'entrée            /catalogues/     machine et métier
    /equipage/   les sièges          /mecaniques/     du brief au livrable
    /manuel/     la console          /outils/         les outils par porteur
    /mettre-en-route/                /travailler-avec/

`public/` est **entièrement généré** par `scripts/collect-assets.mjs`, qui recopie
`assets/avatars/`, `assets/favicon/` et la feuille depuis leurs propriétaires. Les dupliquer sous le
site en ferait un second exemplaire, qui divergerait le jour où l'un des deux serait corrigé.

`node_modules/`, `dist/` et `public/` sont gitignorés.

## Ajouter une page

Le mode d'emploi complet vit dans [`src/pages/_README.md`](src/pages/_README.md) — là où le geste se
fait. En deux lignes : **poser le fichier** (`src/pages/machin.astro` → `/machin/`, aucune liste de
pages à construire nulle part), puis **le ranger dans le rail** (`src/layouts/Site.astro`, `PAGES`
ou `MANUAL`). Le second geste n'est pas optionnel et le build le vérifie dans les deux sens : le
rail porte le groupe et l'ordre de lecture, qu'un nom de fichier ne dit pas.

## Comment ça tourne sur GitHub

`.github/workflows/site.yml` — le workflow vit à la racine parce qu'Actions ne lit que là, et il
pointe ici par `working-directory`.

    push sur main, si assets/** ou le catalogue ou le schéma de verdict ont bougé
      -> checkout, setup-node 24 (cache npm), npm ci, npm run build
      -> upload-pages-artifact (dist/) -> deploy-pages

Permissions minimales (`contents: read`, `pages: write`, `id-token: write`), un seul déploiement à
la fois (`concurrency: pages`), et `workflow_dispatch` pour le jouer à la main.

## Comment le faire tourner en local

    cd assets/github.io
    npm ci
    npm run build      # -> dist/
    npm run preview    # sert dist/ localement

    npm run dev        # rechargement à chaud pendant l'écriture

`prebuild`/`predev` jouent `collect-assets.mjs` : rien à copier à la main.

## À décider avant publication

L'org et le nom du dépôt — ils fixent l'URL servie (`site:` dans `astro.config.mjs`) — et si GitHub
reçoit le dépôt tel quel ou un miroir réécrit par `runtime/bin/publish-transform.sh`.
