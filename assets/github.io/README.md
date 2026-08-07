# Site vitrine LCARS

**Date** : 2026-08-05
**Dernière révision** : 2026-08-07
**Statut** : actif — importé du chantier uiux-deck (jules, `e37ebc013`), recâblé sur `fleet/priv/`
au déménagement du 2026-08-07
**Référencé par** : `.github/workflows/site.yml`

Le site public (`github.io`), construit par Astro et publie par GitHub Pages.

## Pourquoi il vit ici

Son build **lit le catalogue du produit** — `fleet/priv/catalogue/` — pour en tirer les
cartes avec leur `presentation:`, les sieges avec leur qualite de juge, et les cinq verdicts lus
dans l'enum de `gate-decision-v1.json`.

Meme arbre, meme commit : le site ne peut pas decrire une autre version que celle qui est la. Pas
d'epinglage a tenir, pas de snapshot a resynchroniser, pas d'affichage de fraicheur a maintenir —
ces trois mecanismes n'existaient que pour compenser une separation qu'on n'a pas faite.

**Corollaire assume** : deplacer ou renommer le catalogue CASSE ce build. C'est voulu. Une
plaquette qui ne trouve plus ce qu'elle decrit doit echouer bruyamment, pas servir la version
d'avant.

## Ce qui n'est jamais lu

Le texte de prompt des cap-profiles. C'est du package SP, ecrit en francais pour calibrer un
comportement agentique, explicitement hors perimetre de publication. Seuls les champs
**structurels** des sieges sont pris : nom, `lifetime_scope`, `slot_scope`, `remote_control`,
`brief_kind`.

## Ce qui n'est pas commite

`node_modules/`, `dist/` et `public/` sont gitignores. `public/` est **entierement genere** par
`scripts/collect-assets.mjs`, qui recopie `assets/avatars/`, `assets/favicon/` et la feuille depuis
leurs proprietaires. Les dupliquer sous le site en ferait un second exemplaire, qui divergerait le
jour ou l'un des deux serait corrige.

## Construire

    npm ci
    npm run build      # -> dist/, 5 pages, URL par dossier

En production, personne ne lance ca a la main : `.github/workflows/site.yml` le fait au push sur
`main` quand `assets/**` ou le catalogue bougent.

## Etat

Les cinq pages viennent des brouillons relus dans
`work/beyond_#6/chantier-uiux-deck-tmux-2026-08-02/artefacts-maison/`. La prose a ete reprise telle
quelle ; ce qui a change, c'est que les faits enumerables (cartes, sieges, verdicts) ne sont plus
recopies mais lus.

**A decider avant publication** : l'org et le nom du depot (ils fixent l'URL servie, `site:` dans
`astro.config.mjs`), et si GitHub recoit le depot tel quel ou un miroir reecrit par
`fleet/etc/publish-to-github.sh`.
