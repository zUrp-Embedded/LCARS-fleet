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
  return readdirSync(dir).filter((f) => f.endsWith('.yaml')).map((f) => {
    const d = readYaml(join(dir, f));
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
  return readdirSync(dir).filter((f) => f.endsWith('.yaml')).map((f) => {
    const d = readYaml(join(dir, f));
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
