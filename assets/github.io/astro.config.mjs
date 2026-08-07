import { defineConfig } from 'astro/config';
import { execSync } from 'node:child_process';

// PROVENANCE — le pied de page affiche d'ou vient ce build. Le site vit DANS le depot du
// produit : il n'y a donc qu'un seul sha, et le site ne peut pas decrire une autre version
// que celle qui est la. C'est ce qui supprime toute question d'epinglage et de peremption.
const commit = (process.env.GITHUB_SHA || execSync('git rev-parse HEAD').toString().trim()).slice(0, 7);
const built = new Date().toISOString().slice(0, 16).replace('T', ' ') + 'Z';

export default defineConfig({
  // A ajuster au moment de la publication : org/nom du depot decident de l'URL servie.
  site: 'https://lcars.github.io',
  base: '/',
  vite: { define: { __COMMIT__: JSON.stringify(commit), __BUILT__: JSON.stringify(built) } }
});
