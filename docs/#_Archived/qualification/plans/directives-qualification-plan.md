# Plan de qualification directives LCARS v1.0

**Date** : 2026-03-25
**Derniere revision** : 2026-03-25
**Statut** : TODO — passe 2 appliquee
**Reference par** : work/TODO/v6-qualification-plan.md (hors scope runtime, plan separe)
**Derive de** : work/TODO/directives-audit-findings.md (21 findings)

---

## Discipline documentaire

Meme discipline que le plan runtime : journal anti-chronologique en fin de plan,
template par action, lien retour vers les findings, checkpoint journal dans chaque gate.

---

## Objet

Qualification du corpus directif LCARS : 39 fichiers, ~3 000 LOC de .md + .yaml qui
forment le "firmware comportemental" de la fleet. Un bug dans les directives se
propage a TOUS les agents a chaque deploy. La criticite est au moins egale au runtime.

**Principe** : le meme que pour le runtime — 100% bug-free. Pas de "c'est du texte,
c'est moins grave". Une contradiction dans les directives produit un comportement
non-deterministe chez TOUS les agents simultanement. C'est PIRE qu'un bug dans un script.

**Difference fondamentale avec le runtime** : pas de shellcheck/bats. Les "tests"
sont des verifications semantiques (contradictions, ambiguites, references cassees,
scope leaks). L'outillage est : grep + audit humain/LLM + checks automatisables.

---

## Modes de defaillance des directives

| # | Mode | Severite | Detection | Exemples trouves (audit) |
|---|------|----------|-----------|--------------------------|
| D-01 | Contradiction entre fichiers | CRITICAL | Audit croise | REF-04, REF-05, REF-11 |
| D-02 | Non-recouvrement viole (meme regle, 2 endroits) | HIGH | grep + audit semantique | REF-06, REF-07, REF-08 |
| D-03 | Reference cassee (GO-N, section, fichier) | HIGH | grep automatisable | REF-01, REF-02 |
| D-04 | Ambiguite (2 interpretations LLM possibles) | HIGH | Audit semantique | REF-09, REF-16 |
| D-05 | Regle morte (inapplicable) | MEDIUM | Audit croise scope/roles | REF-10, REF-20 |
| D-06 | Scope leak (role decrit permission hors scope) | HIGH | Matrice croisee | REF-11, REF-13 |
| D-07 | Drift source → deploye | MEDIUM | diff automatisable | REF-21 (actuellement OK) |
| D-08 | Build chain break (assemblage SP incomplet) | HIGH | Test idempotence | REF-03, REF-14, REF-15 |
| D-09 | Profil incoherent (agent absent, SP manquant) | MEDIUM | Cross-check fleet.yaml/roles | REF-03, REF-17, REF-19 |

---

## Perimetres et phases

### Phase D0 — Bootstrap checks (2h)

Qui : starfleet.

Ecrire les 4 scripts de check AVANT de commencer les corrections. Ca donne un filet
de securite : chaque fix est valide immediatement. Pas de phase de fix sans verification.

```
1. Ecrire tests/directives/check_references.sh (references croisees GO-N, roles, fichiers)
2. Ecrire tests/directives/check_profiles.sh (agents↔roles↔SP coherence)
3. Ecrire tests/directives/check_drift.sh (source vs deploye — local only)
4. Ecrire tests/directives/check_non_recouvrement.sh (doublons regles cles)
5. Integrer les 3 premiers dans CI (quality.yml — nouveau job "directives")
   Note : check_drift.sh = local only (besoin des homes agents, pas dispo en CI)
6. Lancer les 4 checks sur l'etat actuel → baseline des failures
```

**Gate Phase D0 :**
```
[ ] 4 scripts ecrits et executables
[ ] CI : job "directives" dans quality.yml (3 checks)
[ ] Baseline documentee (N failures par check)
[ ] Journal a jour
```

---

### Phase D1 — Corrections findings (8h)

Qui : starfleet (fixes mecaniques) + architect (decisions sur contradictions).
Branche : quick-fix ou feature selon boundary.

**Processus par finding** :
```
1. Relire le finding dans directives-audit-findings.md
2. Relire le(s) fichier(s) concerne(s) — Read complet de la section
3. Classifier : fix mecanique (starfleet seul) ou decision archi (escalade architect)
4. Appliquer le fix
5. Lancer les checks D0 → confirmer que le fix ne casse rien
6. Marquer le finding comme resolu dans la tracking table
7. Commit (1 commit par groupe de findings lies)
```

**Vague D1.1 — Contradictions et scope leaks (5 findings HIGH)** — 5h
```
REF-04 (HIGH) : Engineer scope "maintenance LCARS" — trancher la formulation
REF-05 (HIGH) : StarFleet "interaction user directe interdite" vs realite
REF-11 (MEDIUM) : Dev "INTERDIT compiler" vs scope "build"
REF-13 (MEDIUM) : Quality scope "test" vs description "GO-7 compliance"
REF-19 (LOW)  : StarFleet stateless: true — verifier et corriger si besoin

Decision archi requise : architect tranche REF-04 et REF-05 (la formulation
doit refleter la realite operationnelle, pas un ideal non tenu).
```

**Vague D1.2 — Non-recouvrement (3 findings MEDIUM)** — 3h
```
REF-06 (MEDIUM) : "Read avant Write" — garder dans 1 seul fichier
REF-07 (MEDIUM) : "Architect INTERDIT implementer" — 1 seul endroit canonique
REF-08 (MEDIUM) : "Push direct interdit" — 1 seul endroit canonique

Principe : identifier l'endroit canonique, supprimer les doublons, mettre une
reference ("voir §X dans fichier Y") si le contexte l'exige.
```

**Vague D1.3 — References cassees et GO disperses (2 findings HIGH)** — 3h
```
REF-01 (HIGH) : GO-4 et GO-7 hors de general-orders.md
REF-02 (HIGH) : GO-5 hors de general-orders.md

Decision : soit regrouper tous les GO dans un seul fichier (index central),
soit documenter la dispersion avec un index dans #1_general-orders.md.
L'index est preferable (evite un fichier monstre, mais donne la carte).
```

**Vague D1.4 — Profiles et build chain (5 findings)** — 3h
```
REF-03 (HIGH)   : builder/deployer sans fichier role — creer les stubs ou retirer du profile
REF-14 (MEDIUM) : Engineer SP manque infrastructure.md — ajouter
REF-15 (MEDIUM) : Dev SP manque topologie + infrastructure — ajouter si pertinent
REF-17 (LOW)    : fleet.yaml reference dans fleet-system — clarifier
REF-20 (LOW)    : Matrice agent×commande incomplete — completer
```

**Vague D1.5 — Reste (6 findings LOW/MEDIUM)** — 1h
```
REF-09  : terminologie wakeable/non-wakeable — unifier
REF-10  : consultant hors profiles — decision : ajouter ou documenter l'exclusion
REF-12  : header reviewer non conforme — fix mecanique
REF-16  : emojis protocole — verifier l'impact, decision user
REF-18  : side quest → work/doing vs work/TODO — clarifier le cycle
REF-21  : direction de maintenance source↔deploye — clarifier dans axiomes
```

**Tracking table** — etat par finding :

| Finding | Severite | Vague | Statut | Commit |
|---------|----------|-------|--------|--------|
| REF-01 | HIGH | D1.3 | [ ] | |
| REF-02 | HIGH | D1.3 | [ ] | |
| REF-03 | HIGH | D1.4 | [ ] | |
| REF-04 | HIGH | D1.1 | [ ] | |
| REF-05 | HIGH | D1.1 | [ ] | |
| REF-06 | MEDIUM | D1.2 | [ ] | |
| REF-07 | MEDIUM | D1.2 | [ ] | |
| REF-08 | MEDIUM | D1.2 | [ ] | |
| REF-09 | MEDIUM | D1.5 | [ ] | |
| REF-10 | MEDIUM | D1.5 | [ ] | |
| REF-11 | MEDIUM | D1.1 | [ ] | |
| REF-12 | MEDIUM | D1.5 | [ ] | |
| REF-13 | MEDIUM | D1.1 | [ ] | |
| REF-14 | MEDIUM | D1.4 | [ ] | |
| REF-15 | MEDIUM | D1.4 | [ ] | |
| REF-16 | MEDIUM | D1.5 | [ ] | |
| REF-17 | LOW | D1.4 | [ ] | |
| REF-18 | LOW | D1.5 | [ ] | |
| REF-19 | LOW | D1.1 | [ ] | |
| REF-20 | LOW | D1.4 | [ ] | |
| REF-21 | LOW | D1.5 | [ ] | |

**Gate Phase D1 :**
```
[ ] 21/21 findings resolus ou explicitement acceptes (tracking table)
[ ] Les 4 checks D0 passent (0 failure)
[ ] Zero contradiction entre fichiers (re-audit croise)
[ ] Zero non-recouvrement (chaque regle en 1 seul endroit)
[ ] Zero reference cassee (index GO complet)
[ ] Tous les roles ont un fichier .md
[ ] Tous les agents dans les profiles ont un role et un SP coherent
[ ] build-sp.sh produit un output identique si relance (idempotence)
[ ] deploy.sh deploie sans erreur sur tous les agents
[ ] CI verte (job directives)
[ ] Journal a jour
```

---

### Phase D2 — Audit independant + release (3h)

Qui : consultant (audit) + starfleet (resolution).

Les checks automatises sont deja en place (Phase D0). Phase D2 est l'audit final.

```
1. Brief d'audit (meme format que Phase 1 runtime)
2. Consultant audit cold-start : relit les directives post-fix
3. Verifie : checks D0 passent, findings resolus, pas de regression
4. Findings → resolution
5. Gate finale
```

**Gate Phase D2 (finale) :**
```
[ ] Audit independant : 0 finding CRITICAL/HIGH
[ ] Les 4 checks passent (3 CI + 1 local)
[ ] deploy.sh complet sans erreur sur tous les agents
[ ] Zero drift source → deploye (check_drift.sh)
[ ] build-sp.sh idempotent (2 runs consecutifs → meme output)
[ ] Tag LCARS avec mention "directives qualified"
[ ] Journal complet
```

---

## Budget

| Phase | Heures | Qui |
|-------|--------|-----|
| D0 — Bootstrap checks | 2h | starfleet |
| D1 — Corrections findings | 8h | starfleet + architect |
| D2 — Audit + release | 3h | consultant + starfleet |
| **Total** | **13h** | |

---

## Ce plan ne couvre PAS

- Revision du contenu semantique des directives (est-ce que les GO sont les bons GO ?)
  → c'est une decision architecturale, pas de la qualification
- Protocole : revision des mots-cles → decision user, pas qualification
- Anthropic base SP (anthropic-lcars.md) → upstream, read-only
- Traduction/internationalisation des directives → hors scope

---

## Journal

(vide — a remplir au fur et a mesure de l'execution)
