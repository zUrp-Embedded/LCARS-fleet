# CARNET DE BORD — état résumable (LIRE EN PREMIER si reprise)

**Date** : 2026-07-10
**Dernière révision** : 2026-07-10 (phase 2 en cours — 4 workers re-vérif en vol)
**Statut** : PHASE 1 CLOSE · PHASE 2 EN COURS (constructeurs + re-vérif consequence-check déléguée)
**Référencé par** : `PLAYBOOK.md`

> Si tu reprends ce chantier après un crash : lis ce fichier, puis `LEDGER.csv`, puis `META-DEBRIEF.md`
> (règles R-01→R-09), puis `DECISION-BRIEF.md`, puis le dernier bloc de `JOURNAL.md`.
> **Ne t'appuie PAS sur ta mémoire de contexte — l'état est ici.**

## Où on en est (MAINTENANT)

- **Worktree** : `/home/lordzurp/wt-remediation`, branche `remediation-ssot` off `main` (1f53f030b). Commit-local, ZÉRO push. ~19 commits.
- **cwd shell** : se reset à `/home/lordzurp/audit/LCARS-13761e19/fleet/runtime` après chaque bash → TOUJOURS `cd /home/lordzurp/wt-remediation/fleet/runtime` ou `git -C`.
- **Phase 0 CLOSE** : 167/167 vérifiés (verdicts dans `verdicts/lot-*.md`, distribution dans `CONSOLIDATION.md`).
- **Phase 1 CLOSE** : hollow-gates. F-C166 fixé (bwrap sentinel), F-C160 fixé (brief-gate coverage), F-C164→THEORIQUE (install.sh clone tout, mal-localisé), F-C167→DOCTRINE D7 (gate creux + invariant violé), F-C165→DOCTRINE D6 (liste rôles).
- **Phase 2 EN COURS** : F-C097 fixé (1er constructeur `boot_enabled?/2`). Config-int re-scopée. **4 workers re-vérif consequence-check des 37 PERCE ouverts en vol** (agentIds : a2535b81, ac2b5f71, a3529a97, a9dcee08 — lancés 22:31, verdicts attendus).
- **DECISION-BRIEF.md livré** : 7 clusters doctrine prêts à trancher pour l'user.

## Prochaine action précise

**Attendre les 4 verdicts workers** (consequence-check : CLEAN-FIX / DOWNGRADE / DOCTRINE / RESIDUAL par finding).
Dès qu'ils rendent → **consolider dans LEDGER.csv** (reclasser selon verdicts) → **attaquer la shortlist CLEAN-FIX**
en TDD (RED→verrou amont→GREEN→supprimer default case→gate→commit→journal), un finding par unité, re-vérif-moi-même
sur les points critiques. **Rien ne bouge sur un finding non-confirmé-percé-ET-conséquence-matérialisée.**

Si workers figés (158 o) au prochain watchdog SANS notification → vrai stall → investiguer/relancer.

## Reclassements depuis phase 0 (verify-the-verifier + consequence-check)

- F-C099/104/117/082 : PERCE→**DOCTRINE (D4)** — clés config jamais posées, garde-anti-misconfig (R-08).
- F-C010 : PERCE→**DOCTRINE (D5)** — `|| "fleet/lcars"` backward-compat documentée (fix = choix design).
- F-C060 : PERCE→**THEORIQUE** — churn non-matérialisée (seal ferme l'issue + réconciliation réclame) (R-09).
- F-C164 : PERCE→THEORIQUE (déjà en phase 0).

## Compteurs (LEDGER à jour)

| | valeur |
|---|---|
| findings totaux | 167 |
| vérifiés (1er passage) | 167 / 167 |
| **PERCE** (verify_verdict) | **44** (dont 3 fixés + 2 flaggés-doctrine dedans → ~37 ouverts en re-vérif) |
| PERCE-doc | 25 |
| **DOCTRINE** (→ user) | **75** (7 clusters D1-D7, voir DECISION-BRIEF.md) |
| THEORIQUE (WONTFIX) | 22 |
| DEJA-FIXE | 1 |
| **fixés (commit)** | **3** (F-C166, F-C160, F-C097) |
| constructeurs de frontière posés | 1 (`boot_enabled?/2`) |
| règles méta posées | R-01 → R-09 |

## Crons (session-only — à SUPPRIMER en fin de chantier)

- watchdog 10 min : `a73c2099`
- relevé horaire (:47) : `b1dc7bc3`

## Décisions en attente (pour le user)

- **7 clusters DOCTRINE (D1-D7)** — voir `DECISION-BRIEF.md` (prêt à trancher, ma reco par cluster). Non-bloquant
  pour phases 1-2-4 ; D1/D6/D7 débloquent la phase 3.
