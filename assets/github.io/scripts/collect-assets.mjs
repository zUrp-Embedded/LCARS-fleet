// Recopie les assets DU DEPOT dans public/, qui est gitignore.
// Pourquoi un script plutot qu'une copie commitee : les avatars et le favicon ont deja un
// proprietaire (assets/avatars, assets/favicon). Les dupliquer sous le site en ferait un
// second exemplaire, qui divergerait le jour ou l'un des deux serait corrige.
import { cp, mkdir, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const repoAssets = join(here, '..', '..');          // <repo>/assets
const pub = join(here, '..', 'public');

await rm(pub, { recursive: true, force: true });
await mkdir(pub, { recursive: true });
await cp(join(repoAssets, 'avatars'), join(pub, 'avatars'), { recursive: true });
await cp(join(repoAssets, "favicon"), join(pub, "favicon"), { recursive: true });
await mkdir(join(pub, "styles"), { recursive: true });
await cp(join(here, "..", "src", "styles", "lcars.css"), join(pub, "styles", "lcars.css"));
console.log('collect-assets: avatars + favicon copies depuis assets/ du depot');
