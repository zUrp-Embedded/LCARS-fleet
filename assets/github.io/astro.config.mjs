import { defineConfig } from 'astro/config';
import { execSync } from 'node:child_process';

// PROVENANCE — le pied de page affiche d'ou vient ce build. Le site vit DANS le depot du
// produit : il n'y a donc qu'un seul sha, et le site ne peut pas decrire une autre version
// que celle qui est la. C'est ce qui supprime toute question d'epinglage et de peremption.
// ⚠ TROIS SOURCES, DANS CET ORDRE, ET LA DERNIERE PEUT MANQUER. Le sha vient de l'appelant quand
// il le connait — `LCARS_GIT_SHA` (le build d'image, qui l'a deja en `--build-arg`), `GITHUB_SHA`
// (Actions) — et de git seulement en dernier recours. Le stage `site` du Dockerfile n'a ni git ni
// `.git` : `execSync` y mourait sur « git: not found », donc l'image entiere echouait sur le pied
// de page d'une plaquette. Un `unknown` affiche en clair coute infiniment moins qu'un build mort,
// et il se voit — c'est la meme regle que la revision de l'image, annoncee INCONNUE plutot que tue.
const gitSha = () => {
  try { return execSync('git rev-parse HEAD', { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim(); }
  catch { return 'unknown'; }
};
const commit = (process.env.LCARS_GIT_SHA || process.env.GITHUB_SHA || gitSha()).slice(0, 7);
const built = new Date().toISOString().slice(0, 16).replace('T', ' ') + 'Z';

// DEUX SORTIES, UN SEUL SOURCE. Le site part a deux endroits : GitHub Pages, servi a la racine, et
// l'image du produit, ou le deck le sert sous `/doc/`. La base est donc une ENTREE du build, pas une
// constante — et tout lien interne passe par `u()` (`src/lib/href.js`), qui la compose. Sans ca la
// copie locale s'affiche et tous ses liens partent a la racine du deck : cassee en silence.
const base = process.env.LCARS_SITE_BASE || '/';

export default defineConfig({
  // A ajuster au moment de la publication : org/nom du depot decident de l'URL servie.
  site: 'https://lcars.github.io',
  base,
  vite: { define: { __COMMIT__: JSON.stringify(commit), __BUILT__: JSON.stringify(built) } }
});
