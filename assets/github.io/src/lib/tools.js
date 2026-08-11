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
const MCP = join(ROOT, 'fleet', 'lib', 'fleet', 'mcp');
const PRIV = join(ROOT, 'fleet', 'priv');

// Les cap-profiles vivent dans les catalogues. On lit les DEUX — le systeme porte la mecanique,
// le metier porte les roles du produit — parce que la question « qui peut appeler quoi » n'a de
// reponse qu'en regardant l'ensemble de ce que la boite embarque.
const PROFILE_DIRS = [
  ['système', join(PRIV, 'catalogue-system', 'cap_profile', 'canon', 'cap-profiles')],
  ['métier', join(PRIV, 'catalogue', 'cap_profile', 'canon', 'cap-profiles')]
];

/** Les outils declares, dans l'ordre du fichier — nom, description agent, schema d'entree. */
export function declaredTools() {
  const src = readFileSync(join(MCP, 'pod_tools.ex'), 'utf8');
  const out = [];

  for (const m of src.matchAll(/deftool "([a-z_]+)" do\n([\s\S]*?)\n  end\n/g)) {
    const [, name, body] = m;
    out.push({ name, description: extractDescription(body), ...extractSchema(body) });
  }

  if (out.length === 0) throw new Error('tools.js: aucun `deftool` lu dans pod_tools.ex');
  return out;
}

// La description est une concatenation Elixir (`"…" <> "…"`). On recolle les litteraux et on
// laisse le texte intact : c'est celui que l'agent recoit, il n'y a rien a lisser.
function extractDescription(body) {
  const d = body.match(/description\(\s*([\s\S]*?)\s*\)\s*\n/);
  if (!d) return '';
  return [...d[1].matchAll(/"((?:[^"\\]|\\.)*)"/g)]
    .map((s) => s[1].replace(/\\"/g, '"').replace(/\\n/g, '\n'))
    .join('')
    .replace(/\s+/g, ' ')
    .trim();
}

// Le schema d'entree est une map Elixir litterale. On n'en tire que ce qu'une page affiche :
// les noms de proprietes et lesquelles sont obligatoires. Un outil sans schema en rend zero,
// ce qui est un fait, pas une panne.
function extractSchema(body) {
  // Jusqu'a la FIN du corps : le `end` du `deftool` a deja ete consomme par l'extraction du
  // bloc, donc l'ancrer dessus ne matche jamais — et rendait un schema vide pour les 24 outils,
  // en silence. Une extraction qui echoue doit rendre du vide VISIBLE, pas du vide plausible.
  const s = body.match(/input_schema\(([\s\S]*)$/);
  if (!s) return { properties: [], required: [] };
  const block = s[1];

  const props = block.match(/"properties"\s*=>\s*%\{([\s\S]*?)\n\s*\},?\s*\n\s*"required"/);
  const properties = props
    ? [...props[1].matchAll(/"([a-z_]+)"\s*=>\s*%\{/g)].map((p) => p[1])
    : [...block.matchAll(/"([a-z_]+)"\s*=>\s*%\{"type"/g)].map((p) => p[1]);

  const req = block.match(/"required"\s*=>\s*\[([^\]]*)\]/);
  const required = req ? [...req[1].matchAll(/"([a-z_]+)"/g)].map((r) => r[1]) : [];

  return { properties: [...new Set(properties)], required };
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
  const src = readFileSync(join(ROOT, 'fleet', 'bin', 'claude_launch.sh'), 'utf8');
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
  for (const m of src.matchAll(/handle_tool_call\(\s*"([a-z_]+)"[\s\S]{0,700}?Delegation\.([a-z_]+[?!]?)\(/g)) {
    if (!out.has(m[1])) out.set(m[1], m[2]);
  }
  return out;
}

/**
 * Vrai si `delete_project` est desarme par defaut — un refus VOULU, pas un oubli.
 *
 * C'est une garde EN PLUS de son gate, pas a sa place : le verbe porte bien `require_onboarder`,
 * dans la branche qui suit le test de desarmement. Meme son porteur legitime est refuse tant que
 * le reglage n'est pas pose.
 */
export function deleteDisarmed() {
  const src = readFileSync(join(MCP, 'pod_tools', 'delegation.ex'), 'utf8');
  return /defp delete_armed\?, do: Application\.get_env\([^)]*,\s*false\)/.test(src);
}

/**
 * Le gate SERVEUR de chaque outil — la seule vraie barriere (`tools/list` est de la decouverte,
 * l'allowlist evite une demande de confirmation). Lu dans la fonction de chaque verbe.
 */
export function gates() {
  const src = readFileSync(join(MCP, 'pod_tools', 'delegation.ex'), 'utf8');
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

    const g = body.match(/require_(architect|onboarder)\(/);
    if (!g) return;
    const cap = g[1] === 'architect' ? 'project_delegate' : 'onboarder';
    // Plusieurs clauses : la premiere qui porte un gate fait foi, et une divergence entre
    // clauses serait un defaut du runtime, pas un cas d'affichage.
    if (!out.has(head[2])) out.set(head[2], cap);
  });

  if (out.size === 0) throw new Error('tools.js: aucun gate `require_*` lu dans delegation.ex');
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
