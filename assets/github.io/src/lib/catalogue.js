// LECTURE DU CATALOGUE — la seule raison d'etre du build.
//
// Le site vit dans le depot du produit, donc il lit les MEMES fichiers que le runtime :
// pas de copie, pas d'extrait, pas de snapshot a resynchroniser. Une carte ajoutee apparait
// sur le site ; une carte renommee s'y renomme ; un fichier deplace CASSE LE BUILD — et c'est
// le comportement voulu. Une plaquette qui ne trouve plus ce qu'elle decrit doit echouer
// bruyamment, pas servir la version d'avant.
//
// CE QU'ON NE LIT JAMAIS : le texte de prompt des cap-profiles. C'est du package SP, ecrit en
// francais pour calibrer un comportement agentique, explicitement hors perimetre de publication
// (cf. runtime/CLAUDE.md). On ne prend que les champs STRUCTURELS des sieges.
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import yaml from 'js-yaml';

const here = dirname(fileURLToPath(import.meta.url));
const PRIV = join(here, '..', '..', '..', '..', 'fleet', 'priv');
const CANON = join(PRIV, 'catalogue');

const readYaml = (p) => yaml.load(readFileSync(p, 'utf8'));

/** Les cartes, avec la `presentation:` que le catalogue ecrit DEJA pour un humain. */
export function cards() {
  const dir = join(CANON, 'workflow', 'canon', 'workflow_maps');
  return readdirSync(dir).filter((f) => f.endsWith('.yaml'))
    .map((f) => ({ f, d: readYaml(join(dir, f)) }))
    // MEME filtre que l'autorite interne (`status == "canon"` apres normalisation, ou le loader
    // pose "canon" quand la cle est absente) : une carte de fumee ou de demo n'est pas une carte
    // qu'un projet peut choisir, et une vitrine qui la publie promet plus que le produit n'offre.
    .filter(({ d }) => (d.metadata?.status ?? 'canon') === 'canon')
    .map(({ f, d }) => {
    return {
      name: d.metadata?.name ?? f.replace(/\.yaml$/, ''),
      presentation: d.metadata?.presentation ?? d.metadata?.description ?? '',
      levels: d.metadata?.applicable_intensity ?? [],
      jury: d.spec?.jury ?? [],
      rounds: d.spec?.max_rework_rounds ?? null,
      steps: Object.keys(d.spec?.steps ?? {})
    };
  }).sort((a, b) => a.name.localeCompare(b.name));
}

/** Les sieges — champs STRUCTURELS uniquement, jamais le prompt. */
export function seats() {
  const dir = join(CANON, 'cap_profile', 'canon', 'cap-profiles');
  return readdirSync(dir).filter((f) => f.endsWith('.yaml'))
    .map((f) => ({ f, d: readYaml(join(dir, f)) }))
    // Un `ReservedSeat` est une place TENUE, pas un siege qu'on peut occuper : il ne recoit ni
    // mandat ni outils, et le spawn le refuse. La page dit « chaque siege recoit un mandat » —
    // publier une place reservee rendrait cette phrase fausse pour l'une d'elles.
    .filter(({ d }) => d.kind === 'CapabilityProfile')
    .map(({ f, d }) => {
    const inv = d.spec?.invocation ?? {};
    return {
      name: d.metadata?.name ?? f.replace(/\.yaml$/, ''),
      lifetime: inv.lifetime_scope ?? null,
      slot: inv.slot_scope ?? null,
      desktop: inv.remote_control !== false,
      judge: (d.spec?.brief_kind ?? 'worker') === 'judge'
    };
  }).sort((a, b) => a.name.localeCompare(b.name));
}

/** Les cinq verdicts, lus dans l'enum du schema de decision. */
export function verdicts() {
  const p = join(PRIV, 'workflow', 'schema', 'gate-decision-v1.json');
  return JSON.parse(readFileSync(p, 'utf8')).properties.decision.enum;
}

// ─── LE LAYOUT DU CATALOGUE — pour la page de manuel ────────────────────────
// Les arbres, les versions supportees, les surcharges fines et les chemins d'installation
// viennent des DEUX modules qui en sont l'autorite. Une liste recopiee dans une page perimerait
// a la premiere addition d'arbre, et personne ne relit une page de manuel pour verifier.
import { existsSync } from 'node:fs';

const CATALOGUE_EX = join(here, '..', '..', '..', '..', 'fleet', 'lib', 'fleet', 'catalogue.ex');
const LAYOUT_EX = join(here, '..', '..', '..', '..', 'fleet', 'lib', 'fleet', 'layout.ex');

/** Les arbres d'un catalogue : leur nom d'atome et leur chemin relatif, dans l'ordre du module. */
export function trees() {
  const src = readFileSync(CATALOGUE_EX, 'utf8');
  const out = [...src.matchAll(/^\s*@rel_([a-z_]+)\s+"([^"]+)"/gm)]
    .map((m) => ({ key: m[1], path: m[2] }));
  if (out.length === 0) throw new Error('catalogue.js: aucun arbre `@rel_*` lu');
  return out;
}

/** Les generations de contrat que ce runtime sait consommer. */
export function supportedApiVersions() {
  const src = readFileSync(CATALOGUE_EX, 'utf8');
  const m = src.match(/@supported_api_versions\s+\[([^\]]+)\]/);
  if (!m) throw new Error('catalogue.js: `@supported_api_versions` illisible');
  return m[1].split(',').map((v) => v.trim()).filter(Boolean);
}

/** Le nom reserve du catalogue metier livre dans le release. */
export function bundledName() {
  const src = readFileSync(CATALOGUE_EX, 'utf8');
  const m = src.match(/@bundled_name\s+"([^"]+)"/);
  if (!m) throw new Error('catalogue.js: `@bundled_name` illisible');
  return m[1];
}

/** Les arbres qui portent une surcharge FINE — ceux qu'on peut deplacer seuls. */
export function fineOverrides() {
  const src = readFileSync(CATALOGUE_EX, 'utf8');
  const block = src.match(/@fine_overrides\s+%\{([\s\S]*?)\n  \}/);
  if (!block) throw new Error('catalogue.js: `@fine_overrides` illisible');
  return [...block[1].matchAll(/^\s*([a-z_]+):/gm)].map((m) => m[1]);
}

/**
 * Ou vivent les catalogues.
 *
 * ⚠ IL Y AVAIT UNE TROISIEME ENTREE ICI, `active`, ET SA DISPARITION A CASSE CE BUILD — ce qui est
 * le comportement voulu (cf. le README du site : une plaquette qui ne trouve plus ce qu'elle decrit
 * doit echouer, pas servir la version d'avant). ⚖ user 2026-08-16 : la declaration d'activite
 * (`~/.lcars/catalogues.active`, un nom par ligne, l'ordre faisant precedence) est MORTE avec les
 * verbes qui l'ecrivaient. Un catalogue est INSTALLE — la forge porte son org et sa source, tout le
 * monde est servi — ou DISPONIBLE. Il n'y a pas de troisieme etat et pas d'ordre a tenir.
 */
/**
 * Les etats d'un catalogue, LUS dans la CLI qui les traduit — jamais recopies ici.
 *
 * `bin/lcars` porte le seul endroit ou le mot de la porte (`INSTALLED`) et le mot de l'operateur
 * (`installe`) se rencontrent. Les lire la garde la plaquette d'accord avec ce que l'utilisateur
 * verra a l'ecran, et fait ECHOUER ce build le jour ou un quatrieme etat apparait sans que
 * personne ne l'ait dit ici.
 */
const LCARS_CLI = join(here, '..', '..', '..', '..', 'fleet', 'bin', 'lcars');

export function states() {
  const src = readFileSync(LCARS_CLI, 'utf8');
  const out = [...src.matchAll(/^\s*([A-Z]+)\)\s+printf\s+'\s+%-16s %-11s[^']*'\s+"\$name" "([^"]+)"/gm)]
    .map((m) => ({ door: m[1], shown: m[2] }));
  if (out.length === 0) throw new Error('catalogue.js: aucun etat de catalogue lu dans bin/lcars');
  return out;
}

export function paths() {
  const src = readFileSync(LAYOUT_EX, 'utf8');
  const pick = (name) => {
    const m = src.match(new RegExp(`@${name}\\s+"([^"]+)"`));
    if (!m) throw new Error(`catalogue.js: @${name} illisible dans layout.ex`);
    return m[1];
  };
  const dir = pick('catalogues_dirname');
  return {
    shipped: `${pick('platform_root')}/${dir}`,
    operator: `~/.lcars/${dir}`
  };
}

/** Combien de roles porte le catalogue SYSTEME — la mecanique, jamais le metier. */
export function systemRoleCount() {
  const dir = join(PRIV, 'catalogue-system', 'cap_profile', 'canon', 'cap-profiles');
  if (!existsSync(dir)) throw new Error('catalogue.js: catalogue-system introuvable');
  return readdirSync(dir).filter((f) => f.endsWith('.yaml')).length;
}
