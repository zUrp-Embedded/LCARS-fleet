# Protocole de qualification projet — directive L4

**Date** : 2026-03-25
**Derniere revision** : 2026-03-25
**Statut** : TODO — passe 2 appliquee, a valider puis encoder
**Reference par** : v6-qualification-plan.md (instance LCARS)
**Derive de** : experience LCARS v6 qualification Phase 1 + preparation Phase 2

---

## Objet

Procedure standard que l'Architect deroule pour qualifier un projet. Reproductible,
independante du langage ou de la stack. Produit les memes artefacts normalises pour
tout projet, que ce soit 500 LOC de Python ou 11k LOC de bash.

Ce document sera encode dans les directives L4 (core/#2_qualite.md ou fichier dedie)
apres validation. En attendant, c'est un plan dans work/TODO/.

---

## Declenchement

La qualification se declenche dans les cas suivants :

| Declencheur | Qui initie | Action |
|-------------|------------|--------|
| Nouveau projet (`/new-project`) | Architect | Kickoff qualification integre au bootstrap |
| Adoption projet (`/adopt-project`) | Architect | Etape 1 (analyse preliminaire) declenchee automatiquement |
| Pre-release (tag version) | Architect ou StarFleet | Verification : plan de qualification existe et gates passees |
| User demande explicitement | Architect | Deroule la procedure |
| Projet > 500 LOC sans plan de qualification | StarFleet (drift-audit) | Alerte → Architect initie |

Un projet sans plan de qualification NE PEUT PAS etre tague en release.
Un projet < 500 LOC peut avoir un plan simplifie (cf. seuils), mais le plan doit exister.

---

## Principe directeur

**On part haut, on allegera plus tard.** Le processus par defaut est strict. Alleger
une etape = decision documentee avec justification. JAMAIS l'inverse. Un projet qui
"saute" la FMEA parce que "c'est petit" doit le justifier dans son plan de
qualification. Un projet qui saute la FMEA sans le dire a viole le protocole.

**L'Architect ne code pas.** L'Architect produit le plan, les specs, les criteres.
L'execution est deleguee (engineer → dev, qualifier, consultant). L'Architect valide
les gates. L'implementeur ne signe pas son propre GO.

**Le test EST la spec.** Pas de REQ-xxx formels, pas de matrice de tracabilite Word.
Un test bien nomme est la meilleure spec. La couverture 100% est la preuve de tracabilite.

---

## Seuils d'applicabilite

Le processus complet s'applique par defaut. Les allegements ci-dessous sont les
SEULS autorises, et chaque allegement est trace dans le plan de qualification du projet.

| Critere projet | Allegement autorise | Justification |
|----------------|---------------------|---------------|
| < 500 LOC, 1 langage | FMEA simplifiee (liste de risques, pas de scoring S/O/D) | Scoring formel disproportionne |
| < 1 000 LOC | Registre de modes par module (pas par fichier) | Granularite fichier excessif |
| 1 seul fichier executable | Pas de tracking table (1 seule ligne) | Overhead > valeur |
| Pas de fleet dispatch | Pas d'audit independant (auto-review + user review) | Consultant inaccessible |
| Script one-shot (pas de maintenance prevue) | Pas de CI pipeline (tests locaux suffisent) | CI pour un script jetable = sur-ingenierie |

**Tout allegement non liste ci-dessus necessite une approbation user explicite.**

---

## Artefacts obligatoires par projet

L'Architect produit ou fait produire les artefacts suivants. Chaque artefact a un
format normalise (template ci-dessous ou herite de LCARS).

| # | Artefact | Qui produit | Quand | Template |
|---|----------|-------------|-------|----------|
| 1 | Analyse preliminaire | Architect | kickoff | §Analyse preliminaire |
| 2 | Plan de qualification | Architect | apres analyse | §Plan de qualification |
| 3 | Registre de modes de defaillance | Responsable projet (Architect pour les projets, StarFleet pour LCARS) | avant Phase 2 equiv | §Registre de modes |
| 4 | Harness de test | Dev (sur spec Architect) | Phase 1 equiv | adapte au langage |
| 5 | CI pipeline | Dev ou StarFleet | Phase 1 equiv | adapte au projet |
| 6 | Brief d'audit par gate | Responsable projet (Architect pour les projets, StarFleet pour LCARS) | chaque gate | §Brief d'audit |
| 7 | Journal de qualification | Continu | continu | meme template que LCARS |

---

## Procedure — etape par etape

### Etape 1 : Analyse preliminaire (~2h)

L'Responsable projet (Architect pour les projets, StarFleet pour LCARS) produit un document qui repond a :

```
1. Inventaire : combien de fichiers, combien de LOC, quels langages
2. Dependances : quelles libs, quels services, quels outils de build
3. Criticite : qu'est-ce qui casse si un bug passe ? (fleet down, data loss, UX degradee...)
4. Modules : decoupage fonctionnel, graphe de dependances
5. Risques : les 5-10 pires choses qui peuvent arriver (pre-FMEA informel)
6. Outillage existant : tests actuels ? CI ? linter ?
7. Seuils applicables : quels allegements du tableau s'appliquent ?
```

**Output** : `work/TODO/<projet>-qualification-preliminary.md`
**Gate** : user valide l'analyse avant de continuer.

### Etape 2 : FMEA ou analyse de risques (~3-5h)

Pour un projet > 1000 LOC ou criticite HIGH : FMEA formelle par composant.
Pour un projet < 1000 LOC : liste de risques avec severite (HIGH/MEDIUM/LOW).

```
Par composant/module :
1. Lister les modes de defaillance (input invalide, dep manquante, race condition, ...)
2. Scorer : Severite × Occurrence × Detection = RPN (si FMEA formelle)
3. Identifier les mitigations existantes
4. Identifier les mitigations manquantes → tests a ecrire
```

**Output** : `docs/qualification/fmea/` (FMEA) ou section dans le plan (liste risques)

### Etape 3 : Plan de qualification (~3h)

L'Architect redige le plan. Structure obligatoire :

```
1. Discipline documentaire (copier la section du plan LCARS)
2. Objet + principes
3. Outils (linter, test framework, coverage tool — adaptes au langage)
4. Politique d'exceptions linter (quelles regles disable, pourquoi)
5. Perimetre (modules, LOC, criticite)
6. Processus par fichier/module (N etapes, adapte au langage)
7. Phases (regroupement en vagues)
8. Registre de modes (reference ou inline si petit projet)
9. Tracking table
10. Strategie de commit
11. Protection regression
12. Gates par phase (avec checkpoint journal obligatoire)
13. Budget
14. Hors scope
15. Journal (vide, a remplir)
```

**Output** : `work/TODO/<projet>-qualification-plan.md`
**Gate** : user valide le plan.

### Etape 4 : Phase 1 — Outillage (~8h)

L'Architect spec, le dev/starfleet implemente :

```
1. Installer les outils (linter, test framework, coverage)
2. Ecrire le harness de test (mocks, helpers, fixtures adaptes au projet)
3. Ecrire les smoke tests (valider le harness)
4. Configurer la CI
5. Pre-commit hooks si applicable
```

**Gate Phase 1** : audit independant (consultant ou reviewer).
L'implementeur ne signe pas son propre GO.

### Etape 5 : Phase 2+ — Qualification par module

Execution mecanique du plan. Le dev deroule le processus par fichier/module.
L'Architect ne touche plus rien — il valide les gates.

```
Par module :
1. Lire le code
2. Consulter le registre de modes
3. Linter → fixer
4. Checklist revue → fixer
5. Ecrire les tests (nominal + erreur + adversarial)
6. Coverage 100%
7. Regression (suite complete)
8. Commit
```

**Gate par phase** : consultant audit cold-start.

### Etape 6 : Release

```
1. Audit final (consultant, instance fraiche)
2. Tous les checks CI passent
3. Coverage 100% global
4. Zero finding CRITICAL/HIGH non resolu
5. Tag version qualifiee
6. Journal complet
```

---

## Correspondance langages

Le processus est le meme. Seuls les outils changent.

| Aspect | Bash | Python | C/C++ | TypeScript |
|--------|------|--------|-------|------------|
| Linter | shellcheck | ruff/flake8 | clang-tidy | eslint |
| Test framework | bats | pytest | ctest/gtest | jest/vitest |
| Coverage | kcov | coverage.py | gcov/lcov | c8/istanbul |
| Mocking | fonctions bash exportees | unittest.mock | gmock | jest.mock |
| Pre-commit | shellcheck staged .sh | ruff check | clang-format | eslint --fix |

---

## Anti-patterns

| Anti-pattern | Pourquoi c'est un probleme | Regle |
|---|---|---|
| "On verra les tests plus tard" | Plus tard = jamais. La dette de test est la pire | Tests dans le meme commit que le code |
| "C'est un petit projet, pas besoin de plan" | Petit projet = petit plan, pas pas-de-plan | Plan obligatoire, allegement si < 500 LOC |
| "Le dev review son propre code" | Biais de confirmation. Il voit ce qu'il croit avoir ecrit | Audit independant obligatoire par gate |
| "Coverage 95% c'est suffisant" | Les 5% sont exactement les branches d'erreur | 100% ou justification documentee par fichier |
| "On documente a la fin" | A la fin, on a oublie les decisions | Journal continu, pas retrospectif |
| "Les tests passent, c'est bon" | Tests qui testent le mauvais comportement = faux vert | Noms de tests explicites, review des tests eux-memes |
| Fixer les symptomes sans comprendre la cause | Le bug revient sous une autre forme | Root cause dans le registre de modes |

---

## Integration fleet

Quand l'Architect recoit une demande de qualification pour un projet :

```
1. Verifier que le projet est dans la fleet (/home/projects/<projet>/)
2. Verifier que work/ existe (sinon fleet-plan.sh init)
3. Derouler les etapes 1-6 ci-dessus
4. Toute implementation passe par : fleet-send.sh engineer → engineer dispatche
5. Tout audit passe par : dispatch consultant (headless ou interactif)
6. Les artefacts vivent dans work/TODO/ du projet (gitignored) et docs/qualification/
```

---

## Encoding prevu

Ce protocole sera encode dans :
- `fleet/system-prompt/sources/core/#2_qualite.md` — reference au protocole
- Un fichier dedie (nouveau) si trop long pour #2_qualite
- Skill /qualify-project — Architect skill qui deroule la procedure

La decision d'encoding exact est prise apres validation user du contenu.
