/**
 * UN LIEN INTERNE PASSE PAR ICI, SANS EXCEPTION.
 *
 * Le meme source produit DEUX sites : celui de GitHub Pages, servi a la racine, et celui qui part
 * dans l'image et que le deck sert sous `/doc/`. Un `href="/manuel/"` ecrit en dur est juste pour
 * le premier et faux pour le second — et faux en silence : la page s'affiche, ses liens partent
 * ailleurs, et la copie locale devient un labyrinthe.
 *
 * Astro expose la base dans `import.meta.env.BASE_URL` ; il ne reecrit PAS les chaines litterales.
 * D'ou cette fonction, et la garde qui va avec dans `Site.astro` : le lien se compose, il ne
 * s'ecrit pas.
 */
const BASE = import.meta.env.BASE_URL || '/';

/** `/manuel/` -> `/manuel/` a la racine, `/doc/manuel/` sous une base. */
export function u(path) {
  if (typeof path !== 'string' || !path.startsWith('/')) {
    throw new Error(`href.js: chemin interne attendu, absolu et relatif au site : ${path}`);
  }
  return (BASE.endsWith('/') ? BASE.slice(0, -1) : BASE) + path;
}

/** La base elle-meme, normalisee avec son slash final — pour comparer un `current`. */
export const base = BASE.endsWith('/') ? BASE : BASE + '/';
