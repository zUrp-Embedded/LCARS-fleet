# Plan de qualification LCARS v1.0

**Date** : 2026-03-24
**Dernière révision** : 2026-03-25
**Statut** : EN COURS — Phase 1 DONE + auditée, Phase 2 prête
**Référencé par** : work/TODO/v6-release-quality-preliminary.md
**Dérivé de** : session starfleet 2026-03-24 (prospection + FMEA + budgétisation)

---

## Discipline documentaire

**Règle** : chaque action significative (gate, audit, fix, décision, refactoring) est
documentée dans ce plan au moment où elle se produit. Dans 3 semaines, on doit pouvoir
relire le journal et comprendre ce qui a été fait, pourquoi, et quel était le résultat.

Le plan est vivant : les gates se cochent, les findings s'inscrivent, les décisions
se tracent. Un plan figé = un plan mort.

### Template journal — une entrée par vague ou action significative

```
### YYYY-MM-DD — Phase N.M : <titre court>

**Action** : ce qui a été fait (1-3 lignes)
**Résultat** : PASS | FAIL | CONDITIONAL | EN COURS
**Findings** : (si applicable)
- FN (SEVERITY) : description courte. Résolution : <action>. Commit : <hash>.
**FMEA** : (si applicable)
- <ID> (RPN N) : mitigé par <test ou fix>. Re-score : N → N'. Commit : <hash>.
**Décisions** : (si applicable)
- <décision prise et pourquoi>
**Commits** : <hash range ou liste>
**Rapport** : <path si audit ou livrable externe>
```

Champs optionnels : ne pas remplir les sections vides. Le template est un squelette,
pas un formulaire bureaucratique. Une vague sans finding ni décision archi = juste
Action + Résultat + Commits.

### Lien retour FMEA

Quand un fix ou un test adresse un mode de défaillance FMEA :
1. Le journal mentionne l'ID FMEA + RPN original
2. Le fichier FMEA correspondant (`docs/qualification/fmea/FMEA-*.md`) est mis à jour :
   colonne Mitigation + Résidu re-scoré
3. Si RPN résiduel < 100 → mode considéré mitigé. Si toujours >= 100 → reste à traiter.

La FMEA est un document vivant. Un mode "mitigé par test X" a plus de valeur
qu'un mode théorique jamais vérifié.

### Checkpoint journal par gate

Chaque gate de phase inclut un item obligatoire :
```
[ ] Journal à jour (toutes les vagues documentées, FMEA mise à jour)
```
L'auditeur vérifie le journal en même temps que les livrables. Un journal
incomplet = gate FAIL, même si le code est parfait.

---

## Objet

Plan opérationnel pour amener les 77 scripts LCARS (11 116 LOC) à un niveau de qualité
100% — zéro défaut, zéro compromis. Standard inspiré ferro/aéro, adapté au contexte :
la rigueur est dans le code et les tests, pas dans la paperasse.

**Budget** : 180h (user + agents). ~36h user (supervision, validation, décisions archi)
+ ~144h agent compute (mécanique). ~12 jours bien remplis.

**Principe** : le test EST la spec. Pas de REQ formels, pas de matrice de traçabilité
maintenue à la main. `test_fleet_send_rejects_invalid_role` est plus clair que
REQ-IPC-003. La couverture 100% kcov est la preuve de traçabilité.

**FMEA** : les 12 fichiers FMEA agents (`docs/qualification/fmea/`) sont un guide de
design permanent. On les consulte pour savoir où concentrer l'effort (RPN élevé = plus
de tests adversariaux). On les met à jour quand une mitigation est implémentée. Pas de
re-scoring formel à chaque gate.

**Règle S ≥ 9** : tout mode de défaillance scoré Sévérité ≥ 9 dans la FMEA fait l'objet
d'un test spécifique, quel que soit le RPN. Un mode catastrophique à faible probabilité
reste catastrophique.

---

## Outils

### shellcheck — analyse statique bash

Analyseur statique. ~400 règles. Détecte : variables non quotées, globbing accidentel,
commandes dans des conditionnels, useless use of cat/echo, variables inutilisées,
declare+assign combinés, etc.

Ne détecte PAS : logique métier incorrecte, chemins inexistants, contrats d'interface
violés, race conditions, boucles infinies.

```bash
# Installation
apt install shellcheck

# Usage
shellcheck -x -S style script.sh    # -x = follow sources, -S style = all severities
```

Retourne 0 si clean. Si un warning est ignoré volontairement : directive dans le script
avec justification (`# shellcheck disable=SCXXXX # raison`).

### Politique d'exceptions shellcheck

**Principe** : zéro warning résiduel. Chaque finding est soit fixé, soit disable avec
justification. Pas de troisième voie.

**Toujours fixer** (la majorité des codes) :
- SC2086 (word splitting) — JAMAIS disable
- SC2046 (globbing) — JAMAIS disable
- SC2091 (invocation accidentelle) — JAMAIS disable
- SC2005 (useless echo) — toujours fixer, trivial
- SC2015 (A && B || C n'est pas if/then/else) — réécrire en if/then/else
- SC2016 (single quotes vs double quotes) — fixer ou justifier inline
- SC2024 (sudo + redirections) — réécrire correctement

**Disable autorisé avec justification inline** :
- SC1091 (not following: source non résolvable statiquement) — fleet-env.sh est
  résolu au runtime via PATH ou readlink. Justification : `# shellcheck source=fleet-env.sh`
  (directive source plutôt que disable — informe shellcheck du chemin).
- SC1090 (can't follow non-constant source) — même cas : variable résolue au runtime.
  Utiliser `# shellcheck source=...` si le fichier est connu.
- SC2317 (unreachable code) — pattern `return 1 2>/dev/null || exit 1` (fonctionne
  en source ET en exec). Disable sur la ligne avec justification.

**Format disable** : toujours sur la ligne, jamais en bloc fichier.
```bash
# shellcheck disable=SC2317  # dual-mode: return in source, exit in exec
return 1 2>/dev/null || exit 1
```

**Inventaire kernel Phase 2** : 28 findings sur 16 scripts. Détail :
SC1091 (10) → directive source. SC2317 (7) → disable justifié. SC2015 (6) → réécrire.
SC2024 (2) → réécrire. SC2016 (1) → fixer. SC2005 (1) → fixer. SC1090 (1) → directive.

### bats-core — tests unitaires bash

Framework de test. Un fichier `.bats` = un ensemble de tests. Chaque test : nom, setup,
exécution, assertion.

```bash
# Installation (git submodule, zéro dépendance)
git submodule add https://github.com/bats-core/bats-core.git tests/.bats/bats-core
git submodule add https://github.com/bats-core/bats-assert.git tests/.bats/bats-assert
git submodule add https://github.com/bats-core/bats-file.git tests/.bats/bats-file

# Usage
./tests/.bats/bats-core/bin/bats tests/unit/

# Exemple de test
@test "fleet-send rejects invalid role" {
  run fleet-send.sh nonexistent_role "test subject"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown role"* ]]
}

@test "fleet-send creates message file in spool" {
  run fleet-send.sh engineer "test subject" <<< "body content"
  [ "$status" -eq 0 ]
  [ -f "$TEST_SPOOL/inbox/engineer/"* ]
}

@test "fleet-send atomic write — no partial file on interrupt" {
  # Simule un kill pendant l'écriture
  timeout 0.01 fleet-send.sh engineer "test" <<< "body" || true
  # Pas de fichier .tmp résiduel
  [ ! -f "$TEST_SPOOL/inbox/engineer/"*".tmp" ]
}
```

### kcov — couverture de code bash

Instrumente l'exécution, compte les lignes exécutées par les tests. Rapport HTML coloré
(vert = couvert, rouge = pas couvert).

```bash
# Installation
apt install kcov

# Usage
kcov --include-path=fleet/,\.claude/hooks/ coverage/ \
  ./tests/.bats/bats-core/bin/bats tests/unit/

# Résultat : coverage/index.html avec % par fichier
# fleet-send.sh : 100%  ✓
# fleet-env.sh  :  87%  ✗ — lignes 145-152 non couvertes
```

Objectif : 100% statement coverage sur chaque script. Un script à 98% = non qualifié.
Les 2% manquants sont soit du code mort (à supprimer) soit des branches non testées
(à tester).

---

## Périmètre — 5 modules

Détail complet dans `v6-release-quality-preliminary.md`.

| Module | Scripts | LOC | Criticité |
|---|---|---|---|
| 1. Kernel | 16 | 2 456 | Fleet down si cassé |
| 2. Safety | 6 | 471 | Fleet unsafe si cassé |
| 3. Deploy | 25 | 3 564 | Fleet figée si cassé |
| 4. Operations | 16 | 3 234 | Fleet pénible si cassé |
| 5. Utilities | 14 | 1 391 | Impact marginal |
| **Total** | **77** | **11 116** | |

---

## Architecture fleet/ — réorganisation par couches

Décision session 2026-03-25. Principe UNIX (McIlroy) : "Make each program do one
thing well." La structure du répertoire encode le DAG de dépendances. Couche N ne
peut sourcer/appeler QUE couche < N + lib/. Vérifiable en CI.

### Structure cible

```
fleet/
├── fleet-env.sh              ← couche 0 : bootstrap (racine)
├── core/                     ← couche 1 : dépend de fleet-env uniquement
│   ├── fleet-state.sh
│   ├── fleet-session-log.sh
│   └── fleet-build-yaml.sh
├── ipc/                      ← couche 2 : dépend de fleet-env + core/
│   ├── fleet-send.sh
│   ├── fleet-inbox-read.sh
│   ├── wake-instance.sh
│   └── fleet-alert.sh
├── dispatch/                 ← couche 3 : dépend de fleet-env + core/ + ipc/
│   ├── fleet-dispatch.sh        (dispatcher)
│   ├── dispatch-async.sh
│   └── dispatch-headless.sh
├── lifecycle/                ← couche 3 : dépend de fleet-env + core/ + ipc/
│   ├── light_on.sh
│   ├── light_off.sh
│   ├── fleet-launch.sh
│   ├── fleet-restart.sh
│   └── fleet-shutdown-clean.sh
├── ops/                      ← couche 4 : dépend de tout ce qui est au-dessus
│   ├── fleet-plan.sh            (dispatcher)
│   ├── plan.d/                  (subcommands atomiques)
│   │   ├── plan-new.sh
│   │   ├── plan-start.sh
│   │   ├── plan-done.sh
│   │   ├── plan-check.sh
│   │   ├── plan-list.sh
│   │   ├── plan-append.sh
│   │   └── plan-audit.sh
│   ├── fleet-scrub.sh           (dispatcher)
│   ├── scrub.d/
│   │   ├── scrub-scratchpad.sh
│   │   ├── scrub-backlog.sh
│   │   └── scrub-init.sh
│   ├── fleet-doctor.sh          (dispatcher)
│   ├── doctor.d/
│   │   ├── doctor-prereqs.sh
│   │   ├── doctor-users.sh
│   │   ├── doctor-permissions.sh
│   │   ├── doctor-symlinks.sh
│   │   ├── doctor-deploy.sh
│   │   ├── doctor-git.sh
│   │   ├── doctor-ipc.sh
│   │   ├── doctor-wsl.sh
│   │   └── doctor-runtime.sh
│   ├── fleet-maintenance.sh
│   ├── fleet-lock-cleanup.sh
│   ├── fleet-sanitize-memory.sh
│   ├── fleet-check-coherence.sh
│   ├── fleet-context-check.sh
│   ├── drift-check.sh
│   └── fleet-wake-notify.sh
├── utils/                    ← couche 5 : dépend de fleet-env + lib/
│   ├── fleet-init-project.sh
│   ├── fleet-l2-hits.sh
│   ├── fleet-inject.sh
│   ├── fleet-fetch.sh
│   ├── fleet-bug.sh
│   ├── fleet-arch.sh
│   ├── fleet-sf.sh
│   ├── handoff-check-utf8.sh
│   ├── handoff-trim.sh
│   ├── starfleet-notes-check.sh
│   ├── herald.sh
│   ├── lcars-test.sh
│   └── watch-handoff.sh
├── lib/                      ← bibliothèques (sourcées, jamais exécutées)
│   ├── plan-lib.sh
│   ├── scrub-lib.sh
│   └── doctor-lib.sh
├── provisioning/             ← couche deploy (dépend de tout, inchangé)
├── system-prompt/            ← lot directives (gelé)
├── profiles/                 ← lot directives (gelé)
├── git-hooks/                ← inchangé
├── hooks/                    ← inchangé
└── toolbox/                  ← standalone, hors couches
```

### Règle de dépendance (vérifiable en CI)

```
core/      → fleet-env.sh + lib/
ipc/       → fleet-env.sh + core/ + lib/
dispatch/  → fleet-env.sh + core/ + ipc/ + lib/
lifecycle/ → fleet-env.sh + core/ + ipc/ + lib/
ops/       → fleet-env.sh + core/ + ipc/ + dispatch/ + lifecycle/ + lib/
utils/     → fleet-env.sh + lib/ (+ optionnellement le reste)
provisioning/ → tout (elle installe tout)
```

Test CI : `test_layer_deps.bats` grep les sources dans chaque couche et vérifie
qu'aucun script ne remonte les couches (pas de source ops/ depuis core/).

### Migration source fleet-env.sh

Changer le pattern de résolution dans les 39 scripts :
```bash
# AVANT (résolution relative — casse si on déplace le script)
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-env.sh"

# APRÈS (résolution PATH — fonctionne partout)
source "$(command -v fleet-env.sh)" || { echo "FATAL: fleet-env.sh not in PATH" >&2; exit 1; }
```

Fonctionne :
- Au runtime : deploy copie tout dans ~/.local/bin/ (flat, en PATH)
- En dev : fleet/ en PATH (ou wrapper)
- En test : mock chargé directement, pas de résolution

### Atomisation — pattern .d/

Les monolithes sont atomisés pendant la qualification (pas avant) :
- fleet-plan.sh (712L) → dispatcher + plan.d/ (7 subcommands)
- fleet-scrub.sh (657L) → dispatcher + scrub.d/ (3 subcommands)
- fleet-doctor.sh (623L) → dispatcher + doctor.d/ (9 sections)
- fleet-dispatch.sh (241L) → dispatcher + dispatch.d/ (2 modes)

Le dispatcher garde l'interface existante. Les subcommands sont testables isolément.

---

## Mocks — le nerf de la guerre

Tester du bash qui source fleet-env.sh (qui dépend de yq + fleet.yaml + users Linux)
demande un harness de mocking sérieux. Sans mocks, on ne teste rien en isolation.

### mock_fleet_env.bash

Exporte les mêmes variables que fleet-env.sh mais depuis des fixtures statiques.
Pas de yq, pas de fleet.yaml réel, pas d'appel système.

```bash
# Exemple
export FLEET_INSTANCE="starfleet"
export FLEET_ROLE="starfleet"
export FLEET_TIER="0"
export FLEET_YAML="$BATS_TEST_TMPDIR/fixtures/fleet.yaml"
export FLEET_BIN="$BATS_TEST_TMPDIR/bin"
export FLEET_SPOOL="$BATS_TEST_TMPDIR/spool"
export FLEET_HANDOFFS="$BATS_TEST_TMPDIR/handoffs"
export FLEET_HOMES="$BATS_TEST_TMPDIR/homes"
# ... toutes les variables exportées par fleet-env.sh
```

Critique : ce mock doit reproduire EXACTEMENT l'interface de fleet-env.sh.
Si fleet-env.sh exporte une nouvelle variable, le mock doit être mis à jour.
Test de cohérence : un test qui compare `env | grep FLEET_` entre le vrai et le mock.

### mock_tmux.bash

Simule tmux send-keys, list-panes, has-session, etc.

```bash
tmux() {
  case "$1" in
    has-session) return 0 ;;  # session existe toujours
    send-keys)  echo "MOCK: tmux send-keys ${*:2}" >> "$MOCK_LOG" ;;
    list-panes) echo "starfleet:0.0: [200x50]" ;;
    *)          echo "MOCK: tmux $*" >> "$MOCK_LOG" ;;
  esac
}
export -f tmux
```

### mock_yq.bash

Simule yq en retournant des valeurs depuis les fixtures.

```bash
yq() {
  # Route les queries communes vers des réponses hardcodées
  case "$*" in
    *".instances | keys"*) echo -e "0\n1\n2" ;;
    *".instances[0].role"*) echo "starfleet" ;;
    *) echo "MOCK_YQ_UNHANDLED: $*" >&2; return 1 ;;
  esac
}
export -f yq
```

### mock_claude.bash

Simule claude -p (headless dispatch).

```bash
claude() {
  echo '{"result": "mock headless output", "exit_code": 0}'
  return 0
}
export -f claude
```

### test_helpers.bash

Setup/teardown partagé.

```bash
setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  # Créer l'arborescence spool
  mkdir -p "$TEST_TMPDIR/spool/inbox"/{starfleet,engineer,dev,qualifier,reviewer}
  mkdir -p "$TEST_TMPDIR/spool/inbox"/{starfleet,engineer,dev}/.processing
  mkdir -p "$TEST_TMPDIR/spool/inbox"/{starfleet,engineer,dev}/.consumed
  mkdir -p "$TEST_TMPDIR/handoffs"
  mkdir -p "$TEST_TMPDIR/homes"/{starfleet,engineer,dev}
  mkdir -p "$TEST_TMPDIR/bin"

  # Charger les mocks
  source "$BATS_TEST_DIRNAME/../helpers/mock_fleet_env.bash"
  source "$BATS_TEST_DIRNAME/../helpers/mock_tmux.bash"
  source "$BATS_TEST_DIRNAME/../helpers/mock_yq.bash"
  source "$BATS_TEST_DIRNAME/../helpers/mock_claude.bash"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}
```

### fixtures/

```
fixtures/
├── fleet-system.yaml    ← config minimale mais valide
├── fleet.yaml           ← yaml généré (copie de ce que fleet-build-yaml produit)
└── spool/               ← messages IPC de test
    ├── valid-message.md
    ├── malformed-message.md
    └── ping-message.md
```

---

## Checklist de revue — par script

Appliquée par l'agent pour chaque script. Pas de rapport formel — les findings sont
fixés dans le même commit.

```
[ ] set -euo pipefail présent (ou justification documentée si absent)
[ ] Header GO-7 conforme
[ ] Contrat documenté en commentaire :
    # PURPOSE: ...
    # INPUTS: ...
    # OUTPUTS: ...
    # EXIT CODES: 0=ok, 1=usage, 2=runtime
    # DEPENDENCIES: yq, fleet-env.sh
[ ] Toutes les variables quotées ("${var}")
[ ] Toutes les variables de fonction déclarées local
[ ] Zéro chemin hardcodé (tout via fleet-env.sh ou variable en tête)
[ ] Zéro sed -i (atomic write : tmp + mv)
[ ] Zéro 2>/dev/null sur commandes diagnostiques (sauf échec attendu documenté)
[ ] Préconditions vérifiées (fail-fast si prérequis absent)
[ ] Exit codes explicites et distincts
[ ] Chaque branche conditionnelle a un else ou un commentaire # intentional-fallthrough
[ ] Zéro variable globale non documentée
[ ] Zéro side-effect non documenté
[ ] Dépendances externes testées (command -v avant usage)
[ ] Zéro TODO/FIXME/HACK non résolu
[ ] Zéro code mort
[ ] shellcheck -x -S style retourne 0
```

---

## Plan détaillé

### Phase 1 — Outillage                                          8h

Qui : starfleet (user + moi).
Branche : `#0_v6-qualification`

```
1.1  apt install shellcheck kcov                                 │ 15 min
1.2  git submodule add bats-core + bats-assert + bats-file       │ 30 min
1.3  Écrire tests/helpers/mock_fleet_env.bash                    │ 2h
     Le mock le plus critique — reproduit l'interface fleet-env.
     Valider : lister toutes les variables exportées par le vrai
     fleet-env.sh, les reproduire dans le mock.
1.4  Écrire tests/helpers/mock_tmux.bash                         │ 45 min
1.5  Écrire tests/helpers/mock_yq.bash                           │ 45 min
1.6  Écrire tests/helpers/mock_claude.bash                       │ 15 min
1.7  Écrire tests/helpers/test_helpers.bash                      │ 30 min
     Setup/teardown : tmpdir, arborescence spool, chargement mocks.
1.8  Écrire tests/fixtures/                                      │ 30 min
     fleet-system.yaml + fleet.yaml minimaux + messages IPC test.
1.9  Écrire tests/run-tests.sh                                   │ 30 min
     Exécute bats sur tous les .bats, affiche résumé.
1.10 Écrire tests/run-shellcheck.sh                              │ 30 min
     shellcheck sur tous les .sh du repo, exit 1 si warning.
1.11 Écrire 1 test trivial pour valider le harness               │ 15 min
     test_smoke.bats : source le mock, vérifie que FLEET_INSTANCE
     est défini, vérifie que le tmpdir existe.
1.12 GitHub Actions CI (.github/workflows/quality.yml)           │ 1h
     Job shellcheck + job bats + job kcov rapport.
```

**Gate Phase 1 :** PASSED 2026-03-25 (audit indépendant consultant → CONDITIONAL GO → conditions résolues → GO)
```
[x] shellcheck installé et fonctionne
[x] bats installé (submodule) et le test smoke passe (21/21)
[x] kcov installé et produit un rapport
[x] Mocks complets (4 fichiers + helpers)
[x] Fixtures présentes (fleet.yaml + 3 messages IPC)
[x] run-tests.sh et run-shellcheck.sh fonctionnels
[x] CI GitHub Actions verte (bats+kcov green, shellcheck continue-on-error temporaire)
```

**Audit Phase 1** (consultant, 2026-03-25) — rapport : `ready-room/outbox/audits/phase1-audit-report.md`
- F1 (MEDIUM) : brief décrivait "pre-commit shellcheck" mais le hook fait GO-7 headers. Erreur de cadrage du brief — le plan place pre-commit en Phase 3. Acknowledgeé, pas un défaut livrable.
- F2 (LOW) : CI rouge permanente (shellcheck 65/87 fail). Fix : `continue-on-error: true` sur job shellcheck (commit ea79237). Temporaire — à retirer après Phase 2.

---

### Phase 2 — Kernel (16 scripts, 2 456 LOC)                    50h

Qui : agent dev (headless dispatch par vague), user valide entre les vagues.
Branche : `#0_v6-qualification` (continue)

**Processus par script** (l'agent fait tout sauf les décisions archi) :
```
1. Read complet du script
2. Consulter phase2-failure-modes.md → lire les modes du script (HIGH/MEDIUM/LOW)
3. shellcheck -x -S style → lister les findings
   (appliquer la politique d'exceptions : cf. section "Politique d'exceptions shellcheck")
4. Checklist revue (15 items) → lister les findings
5. Fix TOUS les findings (shellcheck + checklist)
6. Écrire les tests bats (copier tests/unit/TEMPLATE.bats) :
   - 1 test nominal par fonction significative ou path d'exécution principal
   - 1 test d'erreur par fonction significative
   - 1 test par branche conditionnelle (if/elif/else, case arms)
   - 1 test adversarial par mode HIGH dans phase2-failure-modes.md
   - 1 test adversarial par mode MEDIUM (sauf justification documentée)
   - 1 test par mode FMEA S ≥ 9 cross-référencé (obligatoire quel que soit le RPN)
   - Format nom de test : "<script>: [XXX-NN] <description>" pour les adversariaux
7. Exécuter bats tests/unit/ COMPLET (pas juste le nouveau fichier) → régression
8. kcov → vérifier 100% statement coverage sur le script
   (lignes non couvertes = code mort à supprimer OU branche non testée à tester)
9. Commit — 1 commit par script, message normalisé :
   qual(kernel): <script> — shellcheck clean + N tests + 100% kcov
```

**Stratégie de commit** :
- 1 commit par script qualifié (granularité optimale pour bisect et rollback)
- Exception : refactoring (dispatch split, session-startup split) = commit séparé AVANT
  les tests, avec message `refactor(kernel): <script> — <description du split>`
- Message normalisé pour les commits de qualification :
  `qual(kernel): <script> — shellcheck clean + N tests + 100% kcov`

**Protection régression** :
- Avant chaque commit, exécuter `bats tests/unit/` COMPLET (tous les fichiers)
- Si un test préexistant casse → STOP, analyser, fixer AVANT de continuer
- La CI le fait aussi, mais le dev headless le fait AVANT commit (fail-fast local)

**Registre de modes** : `work/TODO/phase2-failure-modes.md` — table croisée
script → modes de défaillance → tests adversariaux obligatoires. Le dev consulte
ce fichier à l'étape 2 pour savoir exactement quels tests adversariaux écrire.

**Tracking table** — état d'avancement par script :

| Script | SC | Checklist | Fix | Tests | kcov | Commit |
|--------|----|-----------|-----|-------|------|--------|
| fleet-env.sh | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| fleet-build-yaml.sh | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| fleet-session-log.sh | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| fleet-state.sh | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| fleet-send.sh | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| fleet-inbox-read.sh | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| wake-instance.sh | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| fleet-dispatch.sh | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| fleet-launch.sh | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| fleet-shutdown-clean.sh | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| light_on.sh | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| light_off.sh | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| fleet-restart.sh | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| on-stop.sh | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| on-prompt.sh | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| session-startup.sh | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |

**Vague 2.1 — Fondation (2 scripts, 316L)**                     10h
```
fleet-env.sh               206L   SPOF absolu
fleet-build-yaml.sh        110L   Génère fleet.yaml

fleet-env.sh en premier : tout en dépend, et le mock doit
correspondre exactement à son interface. On en profite pour
figer le contrat (variables exportées, fonctions publiques).
Mise à jour du mock si écarts détectés.

FMEA focus : SF-06 (yq absent, RPN 40), fleet.yaml absent (RPN 150).
Tests adversariaux : yq manquant, fleet.yaml manquant, fleet.yaml
malformé, variables déjà définies dans l'environnement (collision).
```
User : valide le contrat fleet-env.sh (c'est la fondation de tout).

**Vague 2.2 — État + IPC (5 scripts, 681L)**                    12h
```
fleet-session-log.sh        88L   Standalone
fleet-state.sh             124L   Dépend de session-log
fleet-send.sh              145L   Coeur IPC
fleet-inbox-read.sh        126L   Lecture IPC
wake-instance.sh           157L   Wake tmux

FMEA focus : rôle invalide (RPN 224), spool plein, wake timeout,
message malformé dans inbox, race condition 2 writers.
Tests adversariaux : rôle inexistant, fichier message tronqué,
inbox vide, inbox avec fichiers non-YAML, wake sur pane inexistante.
```
User : valide les tests IPC (c'est le coeur de la fleet).

**Vague 2.3 — Dispatch + Lifecycle (6 scripts, 897L)**          15h
```
fleet-dispatch.sh          241L   Routing + headless
fleet-launch.sh            187L   Launch instance
fleet-shutdown-clean.sh     79L   Cleanup instance
light_on.sh                128L   Boot fleet
light_off.sh               213L   Shutdown fleet
fleet-restart.sh            49L   Restart

REFACTORING : fleet-dispatch.sh — couper la dépendance vers
fleet-plan.sh. Dispatch doit fonctionner même si le système
de plans est down. Extraire l'appel plan dans un bloc optionnel
fail-safe.

FMEA focus : dispatch multi-scope (RPN 144), écriture concurrente
(RPN 120), headless max_turns.
Tests adversariaux : dispatch vers rôle invalide, dispatch
headless qui timeout, light_on avec fleet.yaml absent,
shutdown avec agents toujours actifs.
```
User : valide le refactoring dispatch (décision archi).

**Vague 2.4 — Session hooks (3 scripts, 603L)**                 10h
```
on-stop.sh                  82L   Le plus simple
on-prompt.sh               151L   Cycle prompt
session-startup.sh         370L   Le plus complexe

REFACTORING : session-startup.sh — extraire les appels non-kernel
(drift-check, fleet-check-coherence, fleet-sanitize-memory,
fleet-lock-cleanup, handoff-check-utf8, fleet-wake-notify) dans
session-startup-checks.sh. Le script principal appelle les checks
via : `bash session-startup-checks.sh || true`
Si les checks plantent, la session démarre quand même.

REFACTORING : on-prompt.sh — extraire fleet-context-check en
appel fail-safe.

FMEA focus : fan-out 10 de session-startup (tout mode de défaillance
d'un sous-script peut bloquer le boot), perte de contexte compact.
Tests : startup avec chaque dépendance absente (fleet-env OK mais
drift-check manquant → session démarre quand même).
```
User : valide les splits core/support (décision archi majeure).

**Vague 2.5 — Confirmation couverture**                          3h
```
kcov sur l'ensemble du kernel.
Identifier et combler les trous.
Audit croisé : relire les tests les plus critiques
(fleet-env, fleet-send, session-startup).
```

**Gate Phase 2 :**
```
[ ] Tracking table : 16/16 scripts toutes colonnes cochées
[ ] 16/16 scripts shellcheck clean (politique d'exceptions appliquée)
[ ] 16/16 scripts checklist revue complète (15 items chacun)
[ ] Tests bats écrits et passent (1 fichier .bats par script, depuis TEMPLATE)
[ ] Tous les modes HIGH de phase2-failure-modes.md couverts par un test
[ ] Tous les modes FMEA S ≥ 9 cross-référencés couverts par un test
[ ] kcov 100% statement coverage sur les 16 scripts
[ ] Test mock coherence passe (test_mock_coherence.bats — 6/6)
[ ] Refactoring dispatch : fleet-dispatch indépendant de fleet-plan
[ ] Refactoring hooks : session-startup-checks.sh extrait, fail-safe
[ ] Refactoring hooks : on-prompt fleet-context-check fail-safe
[ ] Cycle IPC/notification borné (max retries)
[ ] 6 bugs potentiels (phase2-failure-modes.md §Bugs) fixés ou justifiés
[ ] bats tests/unit/ complet : 0 failure, 0 skip
[ ] CI verte (3 jobs)
[ ] Journal à jour (toutes les vagues documentées, FMEA mise à jour)
[ ] Registre de modes mis à jour (résidu HIGH/MEDIUM après fixes)
```

---

### Phase 3 — Safety (6 scripts, 471 LOC)                       12h

Qui : agent dev (headless).
Branche : continue `#0_v6-qualification`

```
runtime-guard.sh           100L   Protège filesystem
agent-guard.sh              65L   Filtre spawns Agent tool
check-secrets.sh            83L   Bloque fuites secrets
pre-commit-lcars.sh         67L   Gate pre-commit
hook-config.sh              61L   Config hooks
install-hooks.sh            95L   Installation hooks
```

**Focus tests adversariaux** (sécurité = chaque guard testé avec des inputs
malveillants) :
```
- runtime-guard : écriture sur /local/LCARS/, sur ~/.claude/, sur /home/autre_agent/
- runtime-guard : bypass via chemin relatif, symlink, ../ traversal
- agent-guard : spawn d'un subagent_type non autorisé
- agent-guard : spawn sans subagent_type (fork interdit)
- check-secrets : token en clair dans du code, dans un heredoc, dans une variable
- check-secrets : faux positif (mot "token" dans un commentaire)
- pre-commit : fichier .sh sans header, fichier .md sans date
- pre-commit : fichier dans _archived (doit être ignoré)
```

**Gate Phase 3 :**
```
[ ] 6/6 shellcheck clean
[ ] 6/6 checklist revue complète
[ ] Tests bats + tests adversariaux passent
[ ] kcov 100%
[ ] Chaque guard testé avec au moins 3 inputs malveillants
[ ] CI verte
[ ] Journal à jour (toutes les vagues documentées, FMEA mise à jour)
```

---

### Phase 4 — Deploy (25 scripts, 3 564 LOC)                    45h

Qui : agent dev (headless par vague).

**Vague 4.1 — Framework deploy (3 scripts, 327L)**               8h
```
deploy-lib.sh               88L   Fonctions partagées
deploy-migrations.sh       111L   Migrations inter-versions
deploy.sh                  128L   Orchestrateur

Tests : deploy sur filesystem simulé (tmpdir avec structure homes).
Vérifier : chaque module deploy.d/ est sourcé, erreur dans un module
ne bloque pas les suivants (ou bloque — documenter le comportement
attendu).
```

**Vague 4.2 — Deploy modules (7 scripts, 1 077L)**              15h
```
deploy-restore.sh           69L
deploy-claude.sh           244L   SP, credentials, CLAUDE.md
deploy-fleet.sh             88L   fleet/ → homes
deploy-bashrc.sh           203L   Patches .bashrc
deploy-hooks.sh             60L   Protocol + hook wiring
deploy-infra.sh            255L   Spool, systemd, symlinks, chown
build-sp.sh                139L   Génère system-prompt.md

deploy-claude.sh et deploy-infra.sh sont les plus complexes.
FMEA focus : deploy partiel (SF-13, RPN 96), credentials écrasés,
symlinks cassés, permissions incorrectes après chown.
Tests : deploy sur filesystem simulé, vérifier permissions,
vérifier que les fichiers sensibles ne sont pas écrasés si
le flag --dry-run est passé.
```

**Vague 4.3 — Provision system (8 scripts, 863L)**              12h
```
provision-packages.sh       93L
provision-groups.sh         60L
provision-sudoers.sh        88L
provision-directories.sh    74L
provision-claude-bin.sh     64L
provision-git.sh           231L   PAT + SSH + remote
provision-wsl.sh            93L
provision-system.sh        160L   Orchestrateur

provision-git.sh est le plus complexe (auth multi-mode).
Tests : provision sur filesystem simulé, vérifier que les
prérequis sont vérifiés (fail-fast si absent).
Mock : apt, useradd, groupadd (on ne crée pas de vrais users).
```

**Vague 4.4 — Provision users + lifecycle (7 scripts, 1 297L)** 10h
```
provision-users.sh         325L   Le plus gros du module
provision-fleet.sh         191L   Installer principal
onboard-preflight.sh       119L
post-install-offline.sh    136L
post-reboot.sh             203L
entrypoint.sh              209L   Docker
fleet-update.sh            134L   Le pont (fait en dernier)

fleet-update.sh fait en dernier car il orchestre tout le module.
Test d'intégration : fleet-update → build-yaml → provision → deploy
sur filesystem simulé.
```

**Gate Phase 4 :**
```
[ ] 25/25 shellcheck clean
[ ] 25/25 checklist revue complète
[ ] Tests bats passent
[ ] kcov 100%
[ ] Test d'intégration : fleet-update chaîne complète sur fs simulé
[ ] CI verte
[ ] Journal à jour (toutes les vagues documentées, FMEA mise à jour)
```

---

### Phase 5 — Operations (16 scripts, 3 234 LOC)                25h

Qui : agent dev (headless).

**Vague 5.1 — Work management (4 scripts, 1 531L)**             12h
```
fleet-done.sh               76L
fleet-action-done.sh        86L
fleet-plan.sh              712L   Plus gros script du runtime
fleet-scrub.sh             657L   2e plus gros

REFACTORING : casser le cycle fleet-plan ↔ fleet-scrub.
Extraire la partie commune (dispatch reviewer) dans un helper
fleet-review-dispatch.sh. Les deux scripts appellent le helper
au lieu de s'appeler mutuellement.

REFACTORING : borner le cycle fleet-plan → fleet-dispatch →
fleet-plan. Guard counter : max 1 niveau de récursion.

fleet-plan et fleet-scrub font 42% du module. C'est la zone
de risque maximale.
```

**Vague 5.2 — Diagnostics (4 scripts, 900L)**                    6h
```
drift-check.sh              64L
fleet-check-coherence.sh   111L
fleet-context-check.sh     102L
fleet-doctor.sh            623L   6 dépendances externes

fleet-doctor.sh : chaque dépendance externe (yq, jq, python3,
claude, systemctl, inotifywait) testée avec command -v avant
usage. Test : doctor avec chaque dépendance absente → message
d'erreur clair, pas crash.
```

**Vague 5.3 — Notification + maintenance + hooks (8 scripts)**   7h
```
fleet-alert.sh             113L
fleet-wake-notify.sh        96L
fleet-maintenance.sh       127L
fleet-lock-cleanup.sh       86L
fleet-sanitize-memory.sh   105L
post-scope-check.sh        128L
post-directional-handoff-reminder.sh  60L
pre-compact-harvest.sh      88L

REFACTORING : borner le cycle wake-instance ↔ fleet-wake-notify
↔ fleet-alert. Max 2 retries, puis log + abandon.
```

**Gate Phase 5 :**
```
[ ] 16/16 shellcheck clean
[ ] 16/16 checklist revue complète
[ ] Tests bats passent
[ ] kcov 100%
[ ] Cycles cassés : plan↔scrub (helper extrait), wake↔notify (borné)
[ ] CI verte
[ ] Journal à jour (toutes les vagues documentées, FMEA mise à jour)
```

---

### Phase 6 — Utilities (14 scripts, 1 391 LOC)                 10h

Qui : agent dev (headless) + starfleet (nettoyage).

```
fleet-init-project.sh     223L
fleet-l2-hits.sh          112L
fleet-inject.sh           122L
fleet-fetch.sh            130L
fleet-bug.sh               62L
fleet-arch.sh              52L
fleet-sf.sh                63L
handoff-check-utf8.sh      93L
handoff-trim.sh           104L
starfleet-notes-check.sh  139L
herald.sh                  63L
lcars-test.sh              92L
watch-handoff.sh           52L
rpi-img-mount.sh           84L   → exclure ou déplacer toolbox/

REFACTORING : casser le cycle fleet-init-project ↔ fleet-l2-hits.
Décision : rpi-img-mount.sh → fleet/toolbox/ (hors fleet runtime).
```

**Gate Phase 6 :**
```
[ ] 13/13 shellcheck clean (rpi-img-mount exclu)
[ ] 13/13 checklist revue complète
[ ] Tests bats passent
[ ] kcov 100%
[ ] rpi-img-mount.sh déplacé dans toolbox/
[ ] CI verte
[ ] Journal à jour (toutes les vagues documentées, FMEA mise à jour)
```

---

### Phase 7 — Intégration + système                              20h

Qui : starfleet + agent dev.

**7.1 — Tests d'intégration cross-modules (tests/integration/)** 10h
```
test_chain_ipc.bats
  send → inbox-read → wake → alert → notify
  Scénario complet : agent A envoie message à agent B,
  B est réveillé, lit le message, envoie ACK.

test_chain_lifecycle.bats
  light_on → launch → dispatch → execute → shutdown
  Scénario complet : boot fleet simulée, launch un "agent"
  (mock), dispatch une tâche headless, vérifier résultat,
  shutdown propre.

test_chain_deploy.bats
  fleet-update → build-yaml → provision → deploy
  Scénario complet : simuler un update sur filesystem simulé,
  vérifier que tous les "agents" ont reçu les bons fichiers.

test_chain_session.bats
  session-startup → on-prompt (×3) → on-stop
  Scénario complet : simuler le lifecycle d'une session
  Claude Code. Vérifier state transitions.
```

**7.2 — Tests système (tests/system/)**                          8h
```
test_fleet_e2e.bats
  Environnement : Docker container ou tmpdir structuré complet.

  Scénarios :
  - Boot fleet → dispatch tâche → vérifier résultat → shutdown
  - fleet-update depuis un "remote" simulé (git bare repo local)
  - Injection de fautes : kill agent mid-task → vérifier recovery
  - Injection de fautes : fleet.yaml corrompu → vérifier fail-fast
  - Injection de fautes : spool plein → vérifier comportement
```

**7.3 — Couverture globale + nettoyage**                          2h
```
kcov global (unit + intégration + système).
Identifier et combler les derniers trous.
Supprimer le code mort identifié pendant les revues.
Vérifier .gitignore.
```

**Gate Phase 7 :**
```
[ ] Tests d'intégration passent (4 chaînes)
[ ] Tests système passent (5 scénarios)
[ ] kcov 100% global
[ ] Zéro code mort
[ ] Zéro TODO/FIXME/HACK dans le code
[ ] CI verte sur les 3 niveaux de tests (unit + intégration + système)
[ ] shellcheck 77/77 (ou 76 si rpi-img-mount exclu)
[ ] Journal à jour (toutes les phases documentées, FMEA à jour)
```

---

### Phase 8 — Polish + release                                   10h

Qui : starfleet.

```
8.1  FMEA mise à jour                                            │ 2h
     Re-scorer les modes mitigés par les corrections des phases
     2-7. Vérifier : zéro RPN ≥ 200 résiduel (sauf les 4
     irréductibles LLM acceptés).

8.2  Nettoyage fichiers _archived                                │ 1h
     Confirmer inutiles ou archiver proprement.

8.3  Documentation vitrine                                       │ 4h
     README avec badges (CI, couverture).
     Table FMEA vanilla → mitigation LCARS (angle doc publique).
     ADR pour les décisions non-évidentes (pourquoi bash,
     pourquoi file IPC, pourquoi users Linux).

8.4  Baseline + audit final                                      │ 3h
     Tag git : v1.0.0-qualified.
     Audit croisé final sur instance fraîche.
```

**Gate Phase 8 (finale) :**
```
[ ] FMEA à jour — zéro RPN ≥ 200 résiduel non accepté
[ ] README vitrine avec badges
[ ] ADR documentés
[ ] Tag v1.0.0-qualified posé
[ ] Audit final sur instance fraîche : 0 finding
[ ] Journal complet — traçabilité bout en bout Phase 0 → Phase 8
```

---

## Budget récapitulatif

| Phase | Heures | Scripts | Qui |
|---|---|---|---|
| 1. Outillage | 8 | — | starfleet |
| 2. Kernel | 50 | 16 | dev headless + user |
| 3. Safety | 12 | 6 | dev headless |
| 4. Deploy | 45 | 25 | dev headless + user |
| 5. Operations | 25 | 16 | dev headless |
| 6. Utilities | 10 | 14 | dev headless + starfleet |
| 7. Intégration | 20 | — | starfleet + dev |
| 8. Polish | 10 | — | starfleet |
| **Total** | **180** | **77** | |

User actif : ~36h (phases 1, 2 validations, 4 validations, 7, 8).
Agent compute : ~144h (phases 2-6 mécanique, 7 tests).

---

## Arborescence tests cible

```
tests/
├── .bats/
│   ├── bats-core/           ← git submodule
│   ├── bats-assert/         ← git submodule
│   └── bats-file/           ← git submodule
├── helpers/
│   ├── mock_fleet_env.bash
│   ├── mock_tmux.bash
│   ├── mock_yq.bash
│   ├── mock_claude.bash
│   └── test_helpers.bash
├── fixtures/
│   ├── fleet-system.yaml
│   ├── fleet.yaml
│   └── spool/
│       ├── valid-message.md
│       ├── malformed-message.md
│       └── ping-message.md
├── unit/
│   ├── test_fleet_env.bats
│   ├── test_fleet_send.bats
│   ├── test_fleet_inbox_read.bats
│   ├── ... (1 fichier .bats par script)
│   └── test_herald.bats
├── integration/
│   ├── test_chain_ipc.bats
│   ├── test_chain_lifecycle.bats
│   ├── test_chain_deploy.bats
│   └── test_chain_session.bats
├── system/
│   └── test_fleet_e2e.bats
├── run-tests.sh
└── run-shellcheck.sh
```

---

## Ce plan ne couvre PAS (hors scope, décisions futures)

- Lot Directives (sources .md + .yaml) → plan séparé, après runtime
- Toolbox scripts (fleet/toolbox/*.sh) → hors qualification sauf si décision contraire
- Refonte architecturale (ex: migration IPC vers socket) → v2
- Tests de performance (combien de messages/seconde) → non pertinent
- Couverture multi-plateforme (natif Linux, macOS) → Ubuntu LTS / WSL2 uniquement

---

## Journal

### 2026-03-25 — Preparation Phase 2 : formalisation complete

**Action** : investissement front-loaded dans la preparation Phase 2. Objectif :
zero question non resolue pendant l'execution. 7 chantiers realises :
1. Politique shellcheck (28 findings classes, 3 categories, regles de disable)
2. Registre de modes par script (137 modes sur 16 scripts, 34 HIGH, 6 bugs detectes)
3. Template bats (TEMPLATE.bats — sections nominal/erreur/adversarial/FMEA/regression)
4. Test coherence mock (test_mock_coherence.bats — 6 tests, detecte drift mock↔reel)
5. Tracking table (16 lignes × 6 colonnes dans le plan)
6. Strategie commit (1 commit/script, message normalise, refactoring separe)
7. Protection regression (bats complet avant chaque commit)
+ Mise a jour gate Phase 2 (17 items, referencant les nouveaux outils)
**Resultat** : PASS — 27/27 tests green (21 smoke + 6 coherence)
**Decisions** :
- FMEA script-level = registre de modes (pas FMEA formelle par script — cout/valeur)
- MC/DC coverage exclue (kcov ne supporte pas, criticite ne justifie pas)
- Review croisee 2 agents exclue (budget) — 1 audit independant par gate suffit
**Artefacts produits** :
- work/TODO/phase2-failure-modes.md (386L, 137 modes)
- tests/unit/TEMPLATE.bats (patron pour les 16 fichiers de tests)
- tests/unit/test_mock_coherence.bats (6 tests, garde la coherence mock↔reel)

### 2026-03-25 — Phase 1 : audit independant + GO

**Action** : audit independant Phase 1. Brief redige par starfleet (15 points de
controle), dispatche vers consultant (Tier 2, advisory, cold-start). Discipline
documentaire formalisee dans le plan. Migration WSL verifiee (21/21 smoke OK).
**Resultat** : CONDITIONAL GO → conditions resolues → GO
**Findings** :
- F1 (MEDIUM) : brief decrivait "pre-commit shellcheck" — erreur de cadrage du brief, le plan place pre-commit en Phase 3. Hook reel fait GO-7 headers. Resolution : acknowledge, pas un defaut livrable.
- F2 (LOW) : CI rouge permanente (shellcheck 65/87 fail attendu). Resolution : `continue-on-error: true` sur job shellcheck. Commit : ea79237.
**Decisions** :
- GO Phase 2 prononce apres resolution F1+F2
- Discipline documentaire formalisee : template journal, lien retour FMEA, checkpoint journal dans chaque gate
**Commits** : ea79237
**Rapport** : `ready-room/outbox/audits/phase1-audit-report.md`

### 2026-03-25 — Phase 1 : implementation + CI

**Action** : implementation complete par starfleet en session interactive. Outillage
(shellcheck, bats submodules, kcov from source), harness (4 mocks, helpers, 3 fixtures
IPC), smoke (21/21), CI (quality.yml, 3 jobs), pre-commit hook (GO-7 headers).
**Resultat** : PASS
**Findings** :
- Submodule fantome (claude-plugins-official) bloquait CI checkout. Resolution : retire de l'index. Commit : 77eddb7.
- kcov absent des repos Ubuntu. Resolution : build from source dans CI. Commits : 61b2c3a, eaa635d.
**Commits** : 4fc76fa, 35c9986, 52e45c1, 77eddb7, 61b2c3a, eaa635d

### 2026-03-24 — Phase 0 : prospection + FMEA + plan

**Action** : session de prospection qualite (starfleet + user). Production du plan
operationnel, de l'analyse preliminaire, et des FMEA agents.
**Resultat** : PASS — plan valide par user, pret a demarrer
**Decisions** :
- 8 phases, 180h budget, principe "le test EST la spec"
- FMEA comme guide de design permanent (pas de re-scoring formel par gate)
- Regle S >= 9 : test specifique obligatoire quel que soit le RPN
**Commits** : non commite (work/ gitignored par design, FMEA committed separement)
