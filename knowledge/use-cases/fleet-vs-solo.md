# Fleet vs Solo Agent — critère de discrimination L2

**Date** : 2026-03-14
**Dernière révision** : 2026-03-14
**Statut** : premier draft — à enrichir par harvest
**Référencé par** : —

---

## Règle fondamentale

Un seul agent suffit → la fleet est du over-engineering. Le projet a 2+ domaines avec des contraintes de cohérence croisée → territoire LCARS.

---

## Use-cases fleet (avantage structurel)

### Tier 1 — vendables immédiatement

| # | Use-case | Domaines | Agents | Valeur fleet |
|---|---|---|---|---|
| 1 | Bi-domaine firmware + GUI | C++ embarqué + Svelte/HTML | dev-firmware, dev-frontend, builder, QA | Un seul agent perd en qualité sur l'un ou l'autre |
| 2 | EDA + firmware + driver host | Schéma KiCad + C++ firmware + driver host (INDI/libusb) | architect (cohérence pin-map), dev-fw, dev-driver, QA | 3 domaines minimum, cohérence pin-assignment critique |
| 3 | Refactor multi-langage coordonné | C++ + Python + JS + YAML | dev par langage, QA cross-langage | Changer une API = modifier 4 langages de façon coordonnée |
| 4 | Production-readiness orchestré | Audit + tests + refactor + QA | audit, test-gen, refactor, QA | Pipeline séquentiel — chaque étape produit des fichiers pour la suivante |

### Tier 2 — extensions naturelles

| # | Use-case | Domaines | Agents | Valeur fleet |
|---|---|---|---|---|
| 5 | Portage plateforme complète | Source + cible + tests | audit (read-only), portage, test | Rapport d'audit = fichier consommé par l'agent de portage |
| 6 | Doc-as-code hardware | README + pinout + BOM + wiring guide | agent par artefact, architect cohérence | Génération coordonnée multi-fichiers, cohérence cross-docs |
| 7 | CI/CD local firmware | Build multi-target + unit tests + partition check | builder par target, QA | Mini-CI local piloté par directives |
| 8 | Reverse-engineering legacy | Archéologie + doc + modernisation | archaeologist (read-only), doc-gen, modernizer | Compréhension AVANT modification — phases séquentielles |

### Tier 3 — spéculatif / niche

| # | Use-case | Domaines | Agents | Valeur fleet |
|---|---|---|---|---|
| 9 | Pipeline acquisition astrophoto | Séquenceur + plate-solve + drift + stacking | agent par étape, IPC via fichiers FITS/logs | LCARS appliqué au runtime, pas au dev |
| 10 | Multi-target build cross-platform | ESP32 + RPi + desktop | builder par toolchain, QA, architect HAL | Extension du dual build-ARM/build-x86 |

---

## Use-cases solo agent (fleet = overkill)

| Use-case | Pourquoi un seul agent suffit |
|---|---|
| Script bash one-shot | Un domaine, pas de cohérence croisée |
| Refactor mono-langage simple | Un fichier, un langage, diff lisible |
| Bug fix isolé | Scope limité, pas de cascade |
| Prototype/POC initial | Exploration, pas de contrainte de cohérence |
| Documentation simple | Un seul artefact, pas de cross-référence |

---

## Critère de décision

```
Nombre de domaines de compétence distincts dans le projet ?
├── 1 → solo agent
├── 2 → fleet si contraintes de cohérence croisée
└── 3+ → fleet, toujours
```

Contrainte de cohérence croisée = un changement dans le domaine A nécessite un changement coordonné dans le domaine B (ex: pin-map firmware↔schéma, API endpoint C++↔JS, partitions↔firmware size).

---

## Sources

Synthèse Claude web, conversations projet cDs + LCARS-fleet, patterns documentés 2024-2026.
