# `src/pages/` — une page = un fichier

**Date** : 2026-08-18
**Statut** : actif — le mode d'emploi, AVANT l'échec de build
**Référencé par** : `assets/github.io/README.md`

> Ce fichier commence par `_` **volontairement**. Astro route tout ce qui est ici — un `README.md`
> nu deviendrait la page `/README/`. Un nom préfixé `_` n'est pas routé : c'est la seule forme sous
> laquelle une note peut vivre dans ce dossier. (Mesuré : un `.md` déposé ici sort bien en page.)

## Ajouter une page

**Deux gestes, et le second n'est pas optionnel.**

1. **Poser le fichier.** `machin.astro` ici devient `/machin/`. Rien à déclarer pour ça : Astro
   route par fichier, il n'existe aucune liste de pages à construire. `.astro`, `.md`, `.mdx` et
   `.html` sont routés pareil.

2. **Le ranger dans le rail** — `../layouts/Site.astro`, tableau `PAGES` ou `MANUAL` :

   ```js
   { href: u('/machin/'), label: 'Le machin' }
   ```

   `PAGES` = ce qu'on **présente** (on déroule, le lecteur découvre).
   `MANUAL` = ce qu'on **référence** (le lecteur arrive avec une question précise).
   L'ordre du tableau est l'ordre de lecture.

**Pourquoi ce second geste existe** : le rail porte deux choses qu'un nom de fichier ne dit pas — le
groupe et l'ordre. Il reste donc écrit. Ce qui est mécanique, c'est sa **couverture** : le build
refuse dans les deux sens, une page sans entrée de rail et une entrée de rail sans page. Sans ça, la
page serait construite, servie à son URL, et absente de toute navigation — publiée et introuvable.

**`href` passe TOUJOURS par `u()`** (`../lib/href.js`). Le même source produit deux sites : celui de
GitHub Pages, servi à la racine, et celui qui part dans l'image, que le deck sert sous `/doc/`. Un
`href="/machin/"` écrit en dur est juste pour le premier et faux pour le second, en silence.

## Ce qu'une page peut lire

`../lib/` expose les lecteurs du vrai code — `catalogue.js` (cartes, sièges, arbres, états),
`cli.js` (les verbes de la console), `tools.js` (les outils par porteur). **Une page n'écrit jamais
un fait énumérable à la main** : elle le lit. Si la source bouge, le build casse — c'est le
comportement voulu.

## Le squelette

```astro
---
import Site from '../layouts/Site.astro';
import SectionHead from '../components/SectionHead.astro';

const sections = [{ id: 'un', label: 'Le premier point' }];
---
<Site title="LCARS — Le machin" current={/* laisser vide */ undefined} sections={sections}>
  <section id="un">
    <SectionHead id="un" title="Le premier point" cap="la ligne de sous-titre" />
    <p class="intro">…</p>
  </section>
</Site>
```

`sections` alimente le troisième groupe du rail (« Cette page »), numéroté automatiquement.
