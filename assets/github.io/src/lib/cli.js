// LECTURE DES DEUX CLI — meme regle que `catalogue.js` : le site vit dans le depot du produit,
// donc il lit les MEMES fichiers que ce qui est installe. Pas de copie, pas d'extrait, pas de
// snapshot a resynchroniser.
//
// CE QU'ON EXTRAIT, ET CE QU'ON N'EXTRAIT PAS. Les NOMS de commande, leur SYNOPSIS et leurs
// OPTIONS viennent du script : ce sont des faits enumerables, exactement comme les cartes et les
// sieges. La prose de la page reste ecrite a la main — un `usage()` dit ce que fait une commande,
// il ne dit pas pourquoi elle refuse ce qu'elle refuse.
//
// UN SCRIPT QUI CHANGE DE FORME CASSE LE BUILD. C'est le comportement voulu : un manuel qui
// perime en silence est pire qu'un manuel absent, parce que personne ne le relit pour verifier
// qu'il dit encore vrai. Les gardes ci-dessous sont donc des `throw`, jamais des valeurs par
// defaut.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const BIN = join(here, '..', '..', '..', '..', 'runtime', 'bin');

const read = (name) => readFileSync(join(BIN, name), 'utf8');

/**
 * Les verbes de `fleet`, lus dans la ligne `usage: fleet {a|b|c}` de son bloc d'aide.
 * C'est la SEULE enumeration du fichier qui soit destinee a etre lue — le `case` du dispatch
 * dirait la meme chose, mais il est du code, et un jour il portera un alias non documente.
 */
export function fleetVerbs() {
  const src = read('fleet');
  const m = src.match(/^usage: fleet \{([^}]+)\}/m);
  if (!m) throw new Error('cli.js: fleet n’expose plus de ligne `usage: fleet {…}`');
  return m[1].split('|').map((v) => v.trim()).filter(Boolean);
}

/**
 * Les options de `fleet start`, avec leur explication — le seul verbe qui en porte.
 * Forme lue : une ligne `    --nom …` puis ses lignes de continuation, plus indentees.
 */
export function fleetStartOptions() {
  const src = read('fleet');
  const block = src.match(/^usage: fleet[\s\S]*?^USAGE$/m);
  if (!block) throw new Error('cli.js: bloc d’aide de fleet introuvable');

  const opts = [];
  let cur = null;
  for (const line of block[0].split('\n')) {
    const start = line.match(/^\s{16,}(--[a-z-]+(?: [A-Z])?)\s*:?\s*(.*)$/);
    if (start) {
      if (cur) opts.push(cur);
      cur = { flag: start[1].trim(), text: start[2].trim() };
    } else if (cur) {
      const cont = line.match(/^\s{20,}(\S.*)$/);
      if (cont) cur.text += ' ' + cont[1].trim();
      else if (line.trim() === '' || /^USAGE$/.test(line)) { opts.push(cur); cur = null; }
    }
  }
  if (cur) opts.push(cur);
  if (opts.length === 0) throw new Error('cli.js: aucune option lue dans fleet start');
  return opts;
}

/**
 * Les entrees de `lcars`, lues dans son `usage()`.
 *
 * La forme est reguliere et c'est ce qui la rend lisible par une machine : deux espaces = un
 * SYNOPSIS, six espaces = sa description. `$PROG` est resolu ici, une fois — le script l'ecrit
 * ainsi pour que son aide porte le nom sous lequel on l'a invoque.
 *
 * Le synopsis est decoupe en trois natures pour que la page puisse les distinguer sans
 * re-analyser du texte : le verbe (`lcars catalogue install`), les arguments obligatoires
 * (`<source>`) et les optionnels (`[nom]`).
 */
export function lcarsEntries() {
  const src = read('lcars');
  const block = src.match(/^usage\(\) \{[\s\S]*?^\}/m);
  if (!block) throw new Error('cli.js: `usage()` de lcars introuvable');

  const body = block[0].replace(/\$PROG/g, 'lcars');
  const entries = [];
  let cur = null;

  for (const line of body.split('\n')) {
    if (/^USAGE$|^ENV$|^EOF$/.test(line.trim()) && !line.startsWith('  ')) {
      if (cur) { entries.push(cur); cur = null; }
      continue;
    }
    const syn = line.match(/^ {2}(lcars .+)$/);
    if (syn) {
      if (cur) entries.push(cur);
      cur = { synopsis: syn[1].trim(), text: '' };
      continue;
    }
    const desc = line.match(/^ {6}(\S.*)$/);
    if (desc && cur) cur.text += (cur.text ? ' ' : '') + desc[1].trim();
  }
  if (cur) entries.push(cur);
  if (entries.length === 0) throw new Error('cli.js: aucune entree lue dans l’usage de lcars');

  return entries.map((e) => ({ ...e, ...splitSynopsis(e.synopsis) }));
}

// `lcars catalogue install <source> [nom]` -> verbe / requis / optionnels.
// Le verbe s'arrete au premier token qui n'est pas un mot nu : tout ce qui suit est un argument.
function splitSynopsis(synopsis) {
  const tokens = synopsis.split(/\s+/);
  const verb = [];
  const args = [];
  for (const t of tokens) {
    if (args.length === 0 && /^[a-z][a-z-]*$/.test(t)) verb.push(t);
    else args.push(t);
  }
  return {
    verb: verb.join(' '),
    args: args.join(' '),
    required: args.filter((a) => a.startsWith('<')),
    optional: args.filter((a) => a.startsWith('['))
  };
}

/**
 * Les variables d'environnement des deux CLI, avec leur defaut.
 *
 * Lues sur la forme `${LCARS_X:-defaut}` — celle qui EST le contrat : une variable qu'un script
 * consulte avec un repli est une variable qu'un operateur peut poser. Chercher dans les
 * commentaires rendrait ce que les auteurs ont pense a citer ; chercher ici rend ce que le code
 * lit vraiment.
 *
 * Le defaut est capture avec, parce que la moitie de l'information utile est la : savoir qu'une
 * variable existe sans savoir vers quoi elle pointe par defaut ne sert a personne.
 */
export function envVars() {
  const out = new Map();
  for (const [file, scope] of [['fleet', 'fleet'], ['lcars', 'lcars']]) {
    for (const m of read(file).matchAll(/\$\{(LCARS_[A-Z0-9_]+):-([^}]*)\}/g)) {
      const [, name, fallback] = m;
      if (out.has(name)) { out.get(name).scope = 'les deux'; continue; }
      out.set(name, { name, scope, fallback: fallback.trim() });
    }
  }
  if (out.size === 0) throw new Error('cli.js: aucune variable LCARS_* lue dans les deux CLI');
  return [...out.values()].sort((a, b) => a.name.localeCompare(b.name));
}
