# token_saver — brique vendorée

**Dérivé de** : [`ppgranger/token-saver`](https://github.com/ppgranger/token-saver) @ `098873e04c6c49cbdc25c1c5f795986f5f170f16` (v2.6.3, 2026-06-02) — **Apache-2.0**
**Forme d'emprunt** : `import` (vendoring de `src/` + `scripts/` + `tests/`)
**Analyse** : reverse complet → `#3_ponce-reverse/token-saver/` (specs, architecture, harnais de mesure)
**Vendoré le** : 2026-08-04

---

## Poids dans le dépôt

Le sous-arbre est déclaré `linguist-vendored` et `linguist-generated` dans le `.gitattributes` racine : il est **exclu des statistiques de langage** et replié par défaut dans les diffs. Le chemin contient `vendor/`, que Linguist détecte aussi nativement — la déclaration explicite garantit le comportement quel que soit l'outil (GitHub, Gitea, cloc, tokei).

La couche LCARS est ré-incluse explicitement : `adapter.py`, `lcars_*.py`, `lcars_tests/`, `run_tests.sh`, `update_vendor.sh`, `VENDOR.md`.

| | Lignes | Compté comme LCARS |
|---|---|---|
| sous-arbre vendoré (`src/`, `scripts/`, `tests/`) | ~20 000 | non |
| couche LCARS | ~540 | oui |

## Ce que c'est

Compression d'output de commandes CLI **avant** son entrée dans le contexte de l'agent. 36 processeurs spécialisés (git, pytest, docker, kubectl, terraform, cargo, npm…), compression mesurée entre 85 % et 99 % sur les sorties qui saturent un contexte.

**Python pur, zéro dépendance runtime** (`requires-python >= 3.10`, stdlib seule). Tourne avec le `python3` de l'image de pod — déjà présent pour `fleet_mcp_stdio_bridge.py`.

## Pourquoi `import` et non `recode`

Le précédent GitWand (`recode` en Elixir pur, décision « ni fork, ni dep npm — pas de pile Node ») ne s'applique pas : GitWand devait tourner **dans le BEAM**. token-saver s'exécute **dans le pod**, en sous-processus du hook Claude Code, exactement comme le bridge MCP stdio. Aucune pile nouvelle n'entre dans le runtime Elixir.

Le précédent superpowers (`dep` + pin de version) ne s'applique pas non plus : il voyage par `LCARS_SKILLS_PLUGINS`, qui transporte des **skills**. token-saver n'expose aucune skill — il expose un **hook**, dont le véhicule est `fleet/v1/hooks.yaml`.

## Découpage retenu

| Amont | Ici | Raison |
|---|---|---|
| `src/` (10 041 l) | `src/` — **copié tel quel** | moteur + 36 processeurs, ne pas réécrire |
| `scripts/` (915 l) | `scripts/` — **copié tel quel** | la décision de routage amont est excellente et testée : exclusions par danger, parseurs quote-aware, fail-open. La réécrire aurait été une perte nette |
| `tests/` (7 884 l) | `tests/` — copié | arbitre les merges amont |
| `installers/`, `.claude-plugin/`, `antigravity/`, `docs/`, `bin/` | **jeté** | mécanisme de plugin marketplace — LCARS câble par `hooks.yaml` |
| — | `adapter.py`, `lcars_processors.py`, `lcars_tests/`, `tools/`, `run_tests.sh` | **notre couche**, hors sous-arbre |

Arborescence identique à l'amont : le merge se fait par re-copie, sans renommage ni rejeu de patch.

Intention initiale révisée en cours de route : `scripts/` devait être réécrit « sous notre I-CBC ». À la lecture, la logique de décision amont s'est révélée meilleure que ce qu'on aurait produit — 460 lignes d'exclusions construites **par danger** (streaming, `sudo`, REPL, redirections, récursion), parseurs quote-aware écrits à la main, fail-open systématique. Elle est vendorée et couverte par `test_hooks.py` (récupéré du même coup). Ce que LCARS ajoute vit au-dessus, dans l'adapter.

Vérifié au reverse : `src/` s'importe seul, `core.compress()` fonctionne sans `scripts/`. Les deux seuls couplages `src → scripts` sont des imports **différés** (`should_compress()`, `explain_decision()`).

## Modifications du sous-arbre vendoré

Conformément à Apache-2.0 § 4(b), toute modification d'un fichier de `vendor_src/` doit porter une mention visible en tête de fichier.

**État : aucun fichier modifié.** Les correctifs vivent dans `adapter.py` et `lcars_processors.py`, hors sous-arbre. C'est délibéré — le merge amont reste trivial.

## Correctifs portés dans l'adapter (hors sous-arbre)

Findings issus du reverse. Le harnais `tools/probe_loss.py` est le critère de recette : **14/24 témoins en configuration amont native, 23/24 sous adapter**.

| # | Finding | Traitement |
|---|---|---|
| **F4** | `user_processors_dir` réglable depuis le `.token-saver.json` d'un dépôt → exécution du code du dépôt (confirmé empiriquement) | **adapter** : substitution du *chargeur* de configuration — `_find_project_config()` n'est jamais appelé, et aucun `reload()` ne peut rouvrir le vecteur |
| **F3** | `_DEFAULT_ERROR_RE` ignore `OOMKilled`, `CrashLoopBackOff`, `connection refused`, `FAILED`, `undefined reference` → échecs supprimés des sorties longues | **adapter** : réassignation de la constante de module |
| **F5** | `min_compression_ratio: 0.0` — garde-fou de gain désarmé | **adapter** : configuration figée |
| **F7 / F9** | `search` plafonné à 15 fichiers ; `kubectl` perd le pod en échec au-delà de ~120 | **adapter** : seuils relevés |
| **F6** | `build` répond `'Build succeeded.'` sur une sortie contenant `undefined reference` — **inversion de sens** | `lcars_processors.safe_build_process` : ne jamais affirmer un succès non constaté |
| **F10** | `db_query` tronque **sans marqueur** — seule violation du principe « toute perte laisse une trace » | **invariant adapter**, valable pour les 36 processeurs |

## Suivi amont

Le projet est actif (124 commits depuis 2026-02-17), Apache-2.0, mono-mainteneur. F3, F6 et F10 sont remontables en PR ; le vendoring n'en dépend pas.

### Procédure

```bash
./update_vendor.sh              # inspection : ce qui a bougé en amont, rien n'est écrit
./update_vendor.sh --apply      # re-copie src/ scripts/ tests/, puis passe le gate
./update_vendor.sh v2.7.0 --apply
```

**Aucun patch à rejouer** tant que la table « modifications » ci-dessus reste vide : la couche LCARS vit hors du sous-arbre, la mise à jour est une simple re-copie.

Le script refuse d'écrire si `src/`, `scripts/` ou `tests/` portent des modifications non commitées — la re-copie les écraserait.

### Ce qu'un update peut casser, et comment on le sait

La couche LCARS ne modifie rien : elle **s'accroche** à des points internes du moteur (`utils._DEFAULT_ERROR_RE`, `config._load_config`, `BuildOutputProcessor.process`, `_is_progress_line`…). Aucun ne fait partie d'une API publique — l'amont peut les renommer sans que ce soit une rupture de son point de vue.

Sans garde-fou, une mise à jour romprait ces ancrages **en silence** : `adapter.py` continuerait de tourner, ses correctifs ne s'appliqueraient plus. Un `_DEFAULT_ERROR_RE` renommé, et `OOMKilled` redisparaît des logs sans qu'aucun test ne rougisse.

`lcars_tests/test_contrat_amont.py` vérifie chaque ancrage un par un, et **dit ce qui se rouvre** quand il échoue. C'est la liste exhaustive de ce qu'`update_vendor.sh` peut casser — à lire avant tout merge amont.

---

## Le switch

```bash
TOKEN_SAVER_ENABLED=0     # coupe l'outil
LCARS_TOKEN_SAVER=off     # alias LCARS — off | 0 | false | no
```

`adapter.is_enabled()` est à interroger **avant** toute réécriture de commande. Le moteur teste bien `config.get("enabled")`, mais trop tard : à ce stade la commande est réécrite, `wrap.py` lancé, un interpréteur Python démarré. Couper là coûterait un processus par commande pour un résultat inchangé.

### Ce qui est réglable à chaud, et ce qui ne l'est jamais

Figer la configuration pour fermer F4 avait un effet de bord : plus aucun override d'environnement n'était appliqué — donc impossible de couper l'outil sans reconstruire l'image. L'environnement est rouvert, mais par **liste blanche** (`_ENV_ALLOWED`, 20 clés : seuils, fenêtres, `disabled_processors`, `debug`, le switch).

La distinction tient à la provenance :

| Source | Lue ? | Pourquoi |
|---|---|---|
| `.token-saver.json` global ou projet | **jamais** | vient d'un dépôt cloné — source non maîtrisée |
| `TOKEN_SAVER_*`, clés de la liste blanche | oui | vient de l'image et du launcher |
| `TOKEN_SAVER_USER_PROCESSORS_DIR` | **jamais** | seule clé qui fait *exécuter* du code |

Cette dernière ligne n'est pas de la prudence de principe. Mesuré : `export FOO=bar && git status` **est compressible** (`export` est silencieuse au sens de `chain_utils`), donc `wrap.py` hérite de l'environnement que l'agent vient de poser. Autoriser l'environnement en bloc rouvrirait F4 par la porte de derrière. La clé est hors liste blanche, dans `_ENV_FORBIDDEN`, et deux tests le vérifient — dont l'exploit complet avec les deux vecteurs à la fois.

## Les deux invariants LCARS

Portés par `adapter.compress()`, donc vrais pour **les 36 processeurs** — y compris un processeur amont ajouté plus tard.

1. **Aucune ligne d'échec n'est perdue.** Les lignes de la sortie originale reconnues comme échec et absentes du résultat sont réinjectées (borne : 40). L'élargissement du vocabulaire seul ne suffisait pas : il ne couvre que les cinq processeurs passant par `compress_log_lines()`, alors que `kubectl get`, `generic` et `test` ont leur propre logique de fenêtre.
2. **Toute perte de lignes laisse une trace.** Si le résultat compte moins de lignes que l'original sans porter de marqueur, une note est apposée.

C'est ce qui fait passer le harnais de **14/24 à 23/24** témoins. Le 24ᵉ est une limite acceptée, pas un défaut : `REFUND_PENDING` au milieu de 400 lignes SQL est une **donnée métier**, pas un échec — compresser un résultat de requête est le comportement voulu. Le vocabulaire n'a délibérément pas été tordu pour faire passer ce cas.

## Gate

`./run_tests.sh` — trois étapes, **deux processus distincts** :

| Étape | Portée | Attendu |
|---|---|---|
| 1 | suite amont, lib **non configurée** | 800 passed, 5 deselected |
| 2 | suite LCARS, lib **sous adapter** | 43 passed |
| 3 | harnais de mesure de perte | 23/24 témoins |

La suite LCARS couvre : les deux invariants, F4 (dont l'exploit rejoué dans un processus fils), F6, le placement, le routage, et **le contrat d'ancrage amont**.

La séparation des processus n'est pas cosmétique : importer `adapter` fige la configuration, élargit le vocabulaire d'échec et substitue la méthode du processeur `build` — état global. Exécuter les deux suites ensemble fait échouer 33 cas amont pour la seule raison que la configuration diffère.
