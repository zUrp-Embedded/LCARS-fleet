# Header template — gabarit de qualification v6

**Date** : 2026-03-28
**Dernière révision** : 2026-03-28
**Statut** : actif — référence pour tous les scripts fleet
**Référencé par** : v6-rings-and-interfaces.md

---

## Principe

Chaque script fleet porte son header entre la ligne `#!/bin/bash` et `# --- END HEADER ---`.
Le header contient deux blocs :

1. **Bloc cosmétique** (ASCII panel LCARS) — géré par `lcars-header.py`, pas modifié à la main.
2. **Bloc man page [EN]** — rédigé à la main, extrait par `--help` via sed.

Le bloc [EN] est le **contrat humain** du script. La section INTERFACE est le **contrat machine**.
Les deux disent la même chose — l'un pour l'humain, l'autre pour l'outillage.

Le mécanisme `--help` est identique sur tous les scripts :

```bash
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}
```

Exception : les scripts sourcés (fleet-env.sh) n'ont pas de `--help` runtime
car ils ne sont pas exécutés directement (sauf mode `--json`).

---

## Niveau A — API publique

Scripts appelés par d'autres scripts, par l'user, ou exposant une interface
consommée par d'autres rings. Tous les scripts kernel de chaque ring.

```
#     [FR]
#     Résumé en une ligne, en français.
#
#     [EN]
#     NAME
#         fleet-xxx.sh — description one-liner
#
#     SYNOPSIS
#         fleet-xxx.sh [options] <positional args>
#         source fleet-xxx.sh
#
#     DESCRIPTION
#         2-5 lignes : ce que fait le script, quand l'utiliser,
#         comportement principal.
#
#     INTERFACE
#         Ring:    N
#         Input:   fichiers/variables consommés
#         Output:  fichiers/stdout produits
#         JSON:    --json → { description du format }
#         Exporte: variables et fonctions exportées (si library)
#
#     OPTIONS
#         --json       Sortie machine-readable (si applicable)
#         --dry-run    Simule sans écrire (si applicable)
#         <arg>        Description des positionnels
#
#     EXIT CODES
#         0    Succès
#         1    Erreur (détail stderr)
#
#     EXAMPLES
#         fleet-xxx.sh --json
#         fleet-xxx.sh profile_name
#         source fleet-xxx.sh && fleet_roles
#
#     SEE ALSO
#         fleet-yyy.sh, fleet-zzz.sh
#
# --- END HEADER ---
```

### Règles

- **INTERFACE** est OBLIGATOIRE (Décision 4). C'est le contrat de stabilité.
- **Ring** est déclaré dans le header — pas besoin de consulter le plan.
- **Input/Output** : fichiers et variables, pas l'implémentation interne.
- **JSON** : format de sortie --json si le script le supporte. Sinon : `JSON: non`.
- **Exporte** : uniquement pour les scripts sourcés (fleet-env.sh). Lister les variables
  ET les fonctions exportées. C'est l'API publique du script.
- **OPTIONS** : documenter TOUS les flags et positionnels acceptés.
- **EXAMPLES** : 2-3 exemples concrets couvrant les cas d'usage principaux.
- **SEE ALSO** : les scripts directement liés (appelants ou appelés).
- Les sections vides sont omises (pas de "OPTIONS: none").
- L'ordre des sections est fixe — ne pas réarranger.

---

## Niveau B — script interne

Scripts appelés uniquement par un orchestrateur (deploy.d/, provision.d/),
helpers, hooks CC, utilitaires internes. Pas d'appel direct par l'user.

```
#     [FR]
#     Résumé en une ligne, en français.
#
#     [EN]
#     NAME
#         deploy-xxx.sh — description one-liner
#
#     INTERFACE
#         Ring:    N
#         Input:   ce qu'il consomme
#         Output:  ce qu'il produit/modifie
#
#     EXIT CODES
#         0    Succès
#         1    Erreur
#
# --- END HEADER ---
```

### Règles

- NAME + INTERFACE + EXIT CODES = le minimum. Pas de SYNOPSIS, DESCRIPTION,
  OPTIONS, EXAMPLES, SEE ALSO sauf si le script est non-trivial.
- Même format INTERFACE que niveau A (Ring, Input, Output, JSON si applicable).

---

## Bloc cosmétique (rappel)

Le bloc ASCII LCARS (MODULE, SUBSYSTEM, LICENSE, STARDATE) est au-dessus de [EN].
Il est géré par `lcars-header.py` / `apply-headers.py`. Jamais modifié à la main
pendant la qualification. Le STARDATE est mis à jour par `update-header-dates.sh`
au push via le skill `/push-github`.

---

## Checklist qualification par script

Pour chaque script du kernel chain :

1. [ ] Header [EN] niveau A rédigé (ou B si interne)
2. [ ] Section INTERFACE complète et exacte
3. [ ] Ring déclaré dans le header
4. [ ] `--help` fonctionne (si exécutable directement)
5. [ ] Tests IN/OUT existent (contrat datasheet, pas implémentation)
6. [ ] Les tests existants passent après modification du header
