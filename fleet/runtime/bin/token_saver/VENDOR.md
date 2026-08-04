# token_saver — brique vendorée

**Dérivé de** : [`ppgranger/token-saver`](https://github.com/ppgranger/token-saver) @ `098873e04c6c49cbdc25c1c5f795986f5f170f16` (v2.6.3, 2026-06-02) — **Apache-2.0**
**Forme d'emprunt** : `import` (vendoring de `src/` + `tests/`)
**Analyse** : reverse complet → `#3_ponce-reverse/token-saver/` (specs, architecture, harnais de mesure)
**Vendoré le** : 2026-08-04

---

## Ce que c'est

Compression d'output de commandes CLI **avant** son entrée dans le contexte de l'agent. 36 processeurs spécialisés (git, pytest, docker, kubectl, terraform, cargo, npm…), compression mesurée entre 85 % et 99 % sur les sorties qui saturent un contexte.

**Python pur, zéro dépendance runtime** (`requires-python >= 3.10`, stdlib seule). Tourne avec le `python3` de l'image de pod — déjà présent pour `fleet_mcp_stdio_bridge.py`.

## Pourquoi `import` et non `recode`

Le précédent GitWand (`recode` en Elixir pur, décision « ni fork, ni dep npm — pas de pile Node ») ne s'applique pas : GitWand devait tourner **dans le BEAM**. token-saver s'exécute **dans le pod**, en sous-processus du hook Claude Code, exactement comme le bridge MCP stdio. Aucune pile nouvelle n'entre dans le runtime Elixir.

Le précédent superpowers (`dep` + pin de version) ne s'applique pas non plus : il voyage par `LCARS_SKILLS_PLUGINS`, qui transporte des **skills**. token-saver n'expose aucune skill — il expose un **hook**, dont le véhicule est `fleet/v1/hooks.yaml`.

## Découpage retenu

| Amont | Ici | Raison |
|---|---|---|
| `src/` (10 041 l) | `vendor_src/` — **copié tel quel** | moteur + 36 processeurs, ne pas réécrire |
| `tests/` (9 931 l) | `vendor_tests/` — copié | arbitre les merges amont, 853 verts |
| `scripts/hook_pretool.py` | **réécrit** → `hook_pretool.py` | décision de routage = notre I-CBC, nos exclusions |
| `scripts/wrap.py` | **réécrit** → `wrap.py` | exécution + placement sous notre autorité |
| `installers/`, `.claude-plugin/`, `antigravity/`, `docs/`, `bin/` | **jeté** | mécanisme de plugin marketplace — on câble par `hooks.yaml` |

`vendor_src/` s'importe seul : vérifié, `core.compress()` fonctionne sans `scripts/`. Les deux seuls couplages `src → scripts` sont des imports **différés** et ne concernent que `should_compress()` / `explain_decision()`, c'est-à-dire la décision de routage — que nous réécrivons.

## Modifications du sous-arbre vendoré

Conformément à Apache-2.0 § 4(b), toute modification d'un fichier de `vendor_src/` doit porter une mention visible en tête de fichier.

**État : aucun fichier modifié.** Les correctifs vivent dans l'adapter (voir ci-dessous). C'est délibéré — le merge amont reste trivial.

## Correctifs portés dans l'adapter (hors sous-arbre)

Findings issus du reverse. Le harnais `#3_ponce-reverse/token-saver/tools/probe_loss.py` est le critère de recette : **14/24 témoins conformes en configuration native, objectif 24/24**.

| # | Finding | Traitement |
|---|---|---|
| **F4** | `user_processors_dir` réglable depuis le `.token-saver.json` d'un dépôt → exécution du code du dépôt (confirmé empiriquement) | **adapter** : la config projet n'est jamais lue |
| **F3** | `_DEFAULT_ERROR_RE` ignore `OOMKilled`, `CrashLoopBackOff`, `connection refused`, `FAILED`, `undefined reference` → échecs supprimés des sorties longues | **adapter** : réassignation de la constante de module |
| **F5** | `min_compression_ratio: 0.0` — garde-fou de gain désarmé | **adapter** : configuration figée |
| **F7 / F9** | `search` plafonné à 15 fichiers ; `kubectl` perd le pod en échec au-delà de ~120 | **adapter** : seuils relevés |
| **F6** | `build` répond `'Build succeeded.'` sur une sortie contenant `undefined reference` — **inversion de sens** | post-traitement adapter (à défaut : patch amont) |
| **F10** | `db_query` tronque **sans marqueur** — seule violation du principe « toute perte laisse une trace » | processeur désactivé jusqu'au correctif |

## Suivi amont

Le projet est actif (124 commits depuis 2026-02-17), Apache-2.0, mono-mainteneur. F3, F6 et F10 sont remontables en PR ; le vendoring n'en dépend pas.

Procédure de mise à jour : re-copier `src/` et `tests/` depuis le tag amont, relancer `vendor_tests` puis `probe_loss.py`. Aucun patch à rejouer tant que la table ci-dessus reste vide.
