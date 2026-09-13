// LECTURE DES OUTILS MCP — meme regle que `catalogue.js` et `cli.js` : on lit les fichiers du
// produit, on ne les paraphrase pas.
//
// TROIS SOURCES, ET C'EST LE CROISEMENT QUI PORTE L'INFORMATION :
//   1. `pod_tools.ex`  — les `deftool` : le nom, la description, le schema d'entree.
//   2. les cap-profiles — `spec.scope.allowedTools` : ce qu'un role peut appeler sans demander.
//   3. `delegation.ex` — le gate serveur de chaque outil : la seule vraie barriere.
//
// La description est celle que lit L'AGENT. On la sert TELLE QUELLE, sous son vrai nom, plutot
// que d'en tenir une deuxieme pour la vitrine : une prose de plus qu'aucun test ne relit perime,
// et perimerait ici en public.
//
// UN FICHIER QUI CHANGE DE FORME CASSE LE BUILD — mêmes gardes que partout ailleurs ici.
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import yaml from 'js-yaml';

const here = dirname(fileURLToPath(import.meta.url));
const ROOT = join(here, '..', '..', '..', '..');
const MCP = join(ROOT, 'runtime', 'lib', 'fleet', 'mcp');
const PRIV = join(ROOT, 'runtime', 'priv');

// Les cap-profiles vivent dans les catalogues. On lit les DEUX — le systeme porte la mecanique,
// le metier porte les roles du produit — parce que la question « qui peut appeler quoi » n'a de
// reponse qu'en regardant l'ensemble de ce que le conteneur embarque.
const PROFILE_DIRS = [
  ['système', join(PRIV, 'catalogue-system', 'cap_profile', 'cap-profiles')],
  ['métier', join(PRIV, 'catalogue', 'cap_profile', 'cap-profiles')]
];

/** Les outils declares, dans l'ordre du fichier — nom, description agent, schema d'entree. */
export function declaredTools() {
  const src = readFileSync(join(MCP, 'pod_tools.ex'), 'utf8');
  const out = [];

  for (const m of src.matchAll(/deftool "([a-z_]+)" do\n([\s\S]*?)\n  end\n/g)) {
    const [, name, body] = m;
    out.push({ name, vitrine: extractVitrine(body), description: extractDescription(body), ...extractSchema(body) });
  }

  if (out.length === 0) throw new Error('tools.js: aucun `deftool` lu dans pod_tools.ex');
  // GARDE DE VITRINE — meme esprit que les autres murs de cette page : un outil sans presentation
  // FR fait ECHOUER le build, plutot que d'afficher un nom nu en public. La ligne `# vitrine:` vit
  // dans le deftool, jamais dans le payload de l'agent (un commentaire n'est pas compile).
  const naked = out.filter((t) => !t.vitrine).map((t) => t.name);
  if (naked.length) {
    throw new Error(`tools.js: deftool sans "# vitrine:" — ${naked.join(', ')} (poser une ligne de presentation FR dans le deftool)`);
  }
  return out;
}

// La ligne `# vitrine:` du deftool : la presentation FR de l'outil, ecrite POUR CETTE PAGE et
// jamais envoyee a l'agent (un commentaire n'est pas compile, il ne peut pas polluer le payload
// MCP). C'est la seule prose de cette page qui n'est pas deja celle que l'agent lit.
function extractVitrine(body) {
  const m = body.match(/#\s*vitrine:\s*(.+)/);
  return m ? m[1].trim() : '';
}

// Recolle une valeur Elixir concatenee (`"…" <> "…"`) en une chaine, litteraux intacts.
function joinLiterals(text) {
  return [...text.matchAll(/"((?:[^"\\]|\\.)*)"/g)]
    .map((s) => s[1].replace(/\\"/g, '"').replace(/\\n/g, '\n'))
    .join('')
    .replace(/\s+/g, ' ')
    .trim();
}

// La description est une concatenation Elixir (`"…" <> "…"`). On recolle les litteraux et on
// laisse le texte intact : c'est celui que l'agent recoit, il n'y a rien a lisser.
function extractDescription(body) {
  const d = body.match(/description\(\s*([\s\S]*?)\s*\)\s*\n/);
  return d ? joinLiterals(d[1]) : '';
}

// La valeur d'une cle `"key" => "…" <> "…"` (ou simple), recollee. '' si absente.
function keyString(text, key) {
  const m = text.match(new RegExp(`"${key}"\\s*=>\\s*((?:"(?:[^"\\\\]|\\\\.)*"\\s*(?:<>\\s*)?)+)`));
  return m ? joinLiterals(m[1]) : '';
}

// Contenu d'un bloc `%{ … }` — `open` = index juste APRES le `{`. Compte les accolades en
// IGNORANT celles qui vivent dans une chaine : une `description` peut contenir un `%{…}` litteral
// (submit_result en a un), et un comptage naif le prendrait pour une vraie ouverture.
function braceSlice(str, open) {
  let depth = 1;
  let inStr = false;
  let i = open;
  for (; i < str.length; i++) {
    const c = str[i];
    if (inStr) {
      if (c === '\\') i++;
      else if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') inStr = true;
    else if (c === '{') depth++;
    else if (c === '}' && --depth === 0) break;
  }
  return str.slice(open, i);
}

// Les FLAGS de l'outil : par propriete de premier niveau, {name, type, required, description}. La
// description existe DEJA dans le schema (c'est ce que l'agent recoit) — on ne la double pas, on
// l'affiche. Un outil sans schema en rend zero, ce qui est un fait, pas une panne.
function extractSchema(body) {
  const s = body.match(/input_schema\(([\s\S]*)$/);
  if (!s) return { flags: [] };
  const block = s[1];

  const p = block.match(/"properties"\s*=>\s*%\{/);
  if (!p) return { flags: [] };
  const propsStart = p.index + p[0].length;
  const propsBody = braceSlice(block, propsStart);

  // Le `required` de PREMIER NIVEAU vit APRES le bloc des proprietes : le chercher dans `block`
  // entier attraperait un `required` imbrique (toolchain_request en a, dans `apt`/`installer`).
  const afterProps = block.slice(propsStart + propsBody.length);
  const req = afterProps.match(/"required"\s*=>\s*\[([^\]]*)\]/);
  const required = new Set(req ? [...req[1].matchAll(/"([a-z_]+)"/g)].map((r) => r[1]) : []);

  const flags = [];
  const re = /"([a-z_]+)"\s*=>\s*%\{/g;
  let m;
  while ((m = re.exec(propsBody)) !== null) {
    const name = m[1];
    const inner = braceSlice(propsBody, re.lastIndex);
    re.lastIndex += inner.length + 1; // sauter tout le bloc : ses cles imbriquees ne sont pas des flags
    const type = (inner.match(/"type"\s*=>\s*"([a-z]+)"/) || [])[1] || '';
    flags.push({ name, type, required: required.has(name), description: keyString(inner, 'description') });
  }
  return { flags };
}

/** Les roles, avec leurs capacites et les outils fleet de leur allowlist. */
export function roles() {
  const out = [];
  for (const [origin, dir] of PROFILE_DIRS) {
    if (!existsSync(dir)) continue;
    for (const f of readdirSync(dir).filter((f) => f.endsWith('.yaml')).sort()) {
      const d = yaml.load(readFileSync(join(dir, f), 'utf8'));
      const scope = d?.spec?.scope ?? {};
      out.push({
        name: d?.metadata?.name ?? basename(f, '.yaml'),
        origin,
        capabilities: d?.spec?.capabilities ?? [],
        tools: (scope.allowedTools ?? [])
          .filter((t) => typeof t === 'string' && t.startsWith('mcp__fleet__'))
          .map((t) => t.replace('mcp__fleet__', ''))
      });
    }
  }
  if (out.length === 0) throw new Error('tools.js: aucun cap-profile lu');
  return out;
}

/**
 * Les outils UNIVERSELS, ajoutes par le lanceur a tout pod quel que soit son role.
 * Lus dans le launcher, pas dans un cap-profile : c'est lui qui les ajoute, et une liste
 * recopiee ici divergerait le jour ou il en ajoute un troisieme.
 */
export function universalTools() {
  const src = readFileSync(join(ROOT, 'runtime', 'bin', 'claude_launch.sh'), 'utf8');
  const m = src.match(/ALLOWED_TOOLS="\$\{ALLOWED_TOOLS[^"]*?\}((?:mcp__fleet__[a-z_]+,?)+)"/);
  if (!m) throw new Error('tools.js: la liste universelle n’est plus lisible dans claude_launch.sh');
  return m[1].split(',').filter(Boolean).map((t) => t.replace('mcp__fleet__', ''));
}

/**
 * Nom d'outil -> fonction de delegation, lu dans la TABLE DE ROUTAGE.
 *
 * Les deux ne coincident pas toujours : l'outil `get_issue_status` route vers `issue_status`.
 * Apparier par le nom seul rendait donc « pas de gate » pour un verbe qui en a un — une page
 * qui pretend dire qui peut appeler quoi ne peut pas se permettre cette approximation.
 */
function routing() {
  const src = readFileSync(join(MCP, 'pod_tools.ex'), 'utf8');
  const out = new Map();
  // `Delegation.Issues.create_issue(` : la famille est decoupee en sous-modules, le nom de la
  // fonction est le dernier segment.
  for (const m of src.matchAll(/handle_tool_call\(\s*"([a-z_]+)"[\s\S]{0,700}?Delegation\.(?:[A-Z][A-Za-z]*\.)*([a-z_]+[?!]?)\(/g)) {
    if (!out.has(m[1])) out.set(m[1], m[2]);
  }
  return out;
}

/**
 * Les sources de la famille delegation, concatenees : la facade `delegation.ex` et ses canaux
 * sous `delegation/`. Depuis le decoupage de la facade, un gate vit dans le canal qui porte son
 * verbe ; lire la facade seule rendait « aucun gate » et tuait le build de la doc, donc l'image
 * et le rail poste (44-media). Lecture RECURSIVE : un glob mono-niveau est encore une adresse,
 * et la prochaine coupe la rendrait fausse sans un mot.
 */
function delegationSources() {
  const root = join(MCP, 'pod_tools');
  const walk = (dir) =>
    readdirSync(dir, { withFileTypes: true })
      .sort((a, b) => a.name.localeCompare(b.name))
      .flatMap((e) =>
        e.isDirectory() ? walk(join(dir, e.name)) : e.name.endsWith('.ex') ? [join(dir, e.name)] : [],
      );
  const family = join(root, 'delegation');
  const files = [join(root, 'delegation.ex'), ...(existsSync(family) ? walk(family) : [])];
  return files.map((f) => readFileSync(f, 'utf8')).join('\n');
}

/**
 * Vrai si `delete_project` est desarme par defaut — un refus VOULU, pas un oubli.
 *
 * C'est une garde EN PLUS de son gate, pas a sa place : le verbe porte bien `require_onboarder`,
 * dans la branche qui suit le test de desarmement. Meme son porteur legitime est refuse tant que
 * le reglage n'est pas pose.
 */
/**
 * La FAMILLE delegation, pas une adresse : `delegation.ex` est une facade et les verbes vivent
 * dans `delegation/**`. Lire le seul fichier de tete rendait zero gate, zero route et « delete
 * arme » — trois reponses fausses sur la page qui dit qui peut appeler quoi.
 */
export function deleteDisarmed() {
  const src = delegationSources();
  return /defp delete_armed\?, do: Application\.get_env\([^)]*,\s*false\)/.test(src);
}

/**
 * Le gate SERVEUR de chaque outil — la seule vraie barriere (`tools/list` est de la decouverte,
 * l'allowlist evite une demande de confirmation). Lu dans la fonction de chaque verbe.
 */
export function gates() {
  const src = delegationSources();
  const out = new Map();

  // Decoupe par TETE de fonction publique, chacune jusqu'a la suivante : une fenetre de taille
  // fixe ratait les verbes dont le gate vient apres une longue entete, et un verbe a plusieurs
  // clauses ne portait le gate que sur l'une d'elles. Les deux se lisaient comme « pas de
  // gate » — l'exact contraire de la verite, sur la page qui prétend dire qui peut appeler quoi.
  // Bornage sur `def` ET `defp` : sans les privees, le corps d'une fonction publique s'etendait
  // jusqu'a la prochaine PUBLIQUE et avalait les privees intercalees — leur `require_*` etait
  // alors attribue au verbe d'avant. Mesure : `delete_project` heritait d'un gate qu'il n'a pas
  // (il est desarme par configuration) et `remove_dependency` en heritait d'un faux.
  // BORNES D'ABORD, NOMS ENSUITE. Toute ligne commencant par `  def ` ou `  defp ` ouvre une
  // fonction, quelle que soit sa forme ensuite — parenthese, virgule, `do:` en une ligne. Exiger
  // une forme particuliere rendait certaines definitions invisibles, et le corps de la fonction
  // precedente s'etendait alors par-dessus : elle heritait d'un gate qui n'etait pas le sien.
  const heads = [...src.matchAll(/^  defp? [a-z_]/gm)].map((m) => m.index);

  heads.forEach((start, i) => {
    const end = i + 1 < heads.length ? heads[i + 1] : src.length;
    const body = src.slice(start, end);
    const head = body.match(/^  (defp?) ([a-z_]+[?!]?)/);
    if (!head || head[1] !== 'def') return;

    const g = body.match(/(?:Gate\.)?require_(architect|onboarder)\(/);
    if (!g) return;
    const cap = g[1] === 'architect' ? 'project_delegate' : 'onboarder';
    // Plusieurs clauses : la premiere qui porte un gate fait foi, et une divergence entre
    // clauses serait un defaut du runtime, pas un cas d'affichage.
    if (!out.has(head[2])) out.set(head[2], cap);
  });

  if (out.size === 0) throw new Error('tools.js: aucun gate `require_*` lu dans la famille delegation');
  return out;
}

/**
 * Le croisement : chaque outil avec son porteur, son gate, et la nature de sa disponibilite.
 *
 * `carrier` est le role dont l'allowlist porte l'outil. Un outil GATE mais que personne ne liste
 * est `orphan` : il existe, il est garde, et aucun agent ne peut l'atteindre. Ce n'est pas une
 * subtilite d'affichage — sous le mode de permission en vigueur, un outil hors liste declenche
 * une demande de confirmation a laquelle personne ne repond dans un pod.
 */
export function toolMap() {
  const tools = declaredTools();
  const rs = roles();
  const universal = new Set(universalTools());
  const g = gates();
  const route = routing();
  const disarmed = deleteDisarmed();

  const carriers = new Map();
  for (const r of rs) for (const t of r.tools) {
    if (!carriers.has(t)) carriers.set(t, []);
    carriers.get(t).push(r.name);
  }

  return tools.map((t) => {
    const carrier = carriers.get(t.name) ?? [];
    const gate = g.get(route.get(t.name) ?? t.name) ?? null;
    const kind = universal.has(t.name)
      ? 'universal'
      : carrier.length > 0
        ? 'carried'
        : t.name === 'delete_project' && disarmed
          ? 'disarmed'
          : 'orphan';
    return { ...t, carrier, gate, kind };
  });
}

/** Ce que la page annonce en tete : des comptes, tous derives. */
export function counts() {
  const m = toolMap();
  return {
    total: m.length,
    universal: m.filter((t) => t.kind === 'universal').length,
    carried: m.filter((t) => t.kind === 'carried').length,
    orphan: m.filter((t) => t.kind === "orphan").length,
    disarmed: m.filter((t) => t.kind === "disarmed").length,
    roles: roles().length
  };
}
