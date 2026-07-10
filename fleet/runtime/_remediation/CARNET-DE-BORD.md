# CARNET DE BORD — état résumable (LIRE EN PREMIER si reprise)

**Date** : 2026-07-10
**Dernière révision** : 2026-07-11 ~00h30 (JALON : remédiation MÉCANIQUE complète — 12 code + 22 doc)
**Statut** : PHASES 1-5 CODE+DOC CLOSES · reste = DÉCISIONS USER (87 doctrine + 5 doc-forks) + cleanup crons
**Référencé par** : `PLAYBOOK.md`

> Si tu reprends ce chantier après un crash : lis ce fichier, puis `LEDGER.csv`, puis `META-DEBRIEF.md`
> (règles R-01→R-09), puis `DECISION-BRIEF.md`, puis le dernier bloc de `JOURNAL.md`.
> **Ne t'appuie PAS sur ta mémoire de contexte — l'état est ici.**

## Où on en est (MAINTENANT)

- **Worktree** : `/home/lordzurp/wt-remediation`, branche `remediation-ssot` off `main` (1f53f030b). Commit-local, ZÉRO push. ~19 commits.
- **cwd shell** : se reset à `/home/lordzurp/audit/LCARS-13761e19/fleet/runtime` après chaque bash → TOUJOURS `cd /home/lordzurp/wt-remediation/fleet/runtime` ou `git -C`.
- **Phase 0 CLOSE** : 167/167 vérifiés (verdicts dans `verdicts/lot-*.md`, distribution dans `CONSOLIDATION.md`).
- **Phase 1 CLOSE** : hollow-gates. F-C166 fixé (bwrap sentinel), F-C160 fixé (brief-gate coverage), F-C164→THEORIQUE (install.sh clone tout, mal-localisé), F-C167→DOCTRINE D7 (gate creux + invariant violé), F-C165→DOCTRINE D6 (liste rôles).
- **Pass-2 CONSOLIDÉ** (4 workers rendus, `CONSOLIDATION-PASS2.md`) : 9 CLEAN-FIX, 18→theo, 7→doctrine.
- **9 FIXÉS** (TDD, committés) : F-C166, F-C160, F-C097, F-C098, F-C059, F-C069, F-C119, F-C018, F-C044.
- **DECISION-BRIEF.md livré** : 7 clusters doctrine (+7 ajouts pass-2 + F-C059-b) prêts à trancher pour l'user.

## Prochaine action précise

**REMÉDIATION MÉCANIQUE COMPLÈTE (12 code + 22 doc, gate vert).** Il ne reste que des DÉCISIONS USER + cleanup :
1. **TRIAGE DOCTRINE (87 findings)** : `DECISION-BRIEF.md` (7 clusters D1-D7 + ajouts pass-2/2b + F-C151/F-C059-b),
   prêt à décider, ma reco par cluster. **C'est le GROS du reste → attend l'user.**
2. **5 doc-forks (→ user, petits)** : F-C006 (test conformance fausse-couverture : renommer vs vrai test apiVersion-inconnu),
   F-C132-test + F-C137-test (tests intégration SHELL asserte un contrat retiré — hors gate mix, réécriture),
   F-C151 (canon dual-review live vs sp_drafts → D3), F-C087 (dates hardcodées scaffold → mini seam horloge, cosmétique).
3. **CLEANUP fin** : `CronDelete a73c2099 b1dc7bc3`.

**12 CODE-FIXÉS (TDD)** : F-C166/160/097/098/059/069/119/018/044/035/037/086.
**22 DOC-FIXÉS** : F-C002/003/004/008/009/012/014/017/067/070/071/072/088/090/128/131/134/148/158/162 (+ F-C132/137 part-doc).
**Reclassés re-vérif** : F-C031→theo · F-C075/076→doctrine · (voir Reclassements ↓).

## Reclassements (verify-the-verifier + consequence-check R-09)

- **Phase 1-2 solo** : F-C099/104/117/082 PERCE→DOCTRINE (D4, R-08) · F-C010 PERCE→DOCTRINE (D5) · F-C060 PERCE→THEORIQUE (R-09) · F-C164 THEORIQUE.
- **Pass-2 (4 workers)** : 18 PERCE→THEORIQUE (022/027/028/029/055/062/068/073/074/079/092/100/106/107/113/114/115/116)
  · 7 PERCE→DOCTRINE (043/047/053/066/084/141/161) · F-C165/167 PERCE→DOCTRINE (D6/D7, flaggés phase 1).
- **Motif** : substrat durable rattrape (forge-sync/re-wake/poller-rescan/scoped-label-mutex), ou site sans caller vivant, ou valeur déjà valide amont, ou fork de contrat.

## Compteurs (LEDGER à jour)

| | valeur |
|---|---|
| findings totaux | 167 |
| vérifiés (1er + 2e passage) | 167 / 167 |
| **PERCE** (verify_verdict) | **12** (TOUS FIXÉS ✅) |
| **PERCE-doc** | 25 (**22 FIXÉS** ✅ + 3 décisions : F-C006/087/151) |
| **DOCTRINE** (→ user) | **87** (7 clusters D1-D7 + ajouts pass-2/2b + F-C151 + F-C059-b, voir DECISION-BRIEF.md) |
| THEORIQUE (WONTFIX) | 42 |
| DEJA-FIXE | 1 |
| **fixés (commit)** | **34** (12 code + 22 doc) |
| verrous posés | `boot_enabled?/2`, `encode_line/1` fail-safe, `safe_pod_info` :unknown, jury `:unexpected_review_shape`, `validate_issue_id`, `strip_control(role)`, `emit_spawn_failed` sur {:error} |
| règles méta posées | R-01 → R-12 |

## Crons (session-only — MEURENT au crash de session → RÉ-ARMER EN PREMIER si reprise)

> ⚠️ `durable` sans effet : ces crons vivent en mémoire de session. **Si tu reprends ce chantier dans une
> session fraîche, ta TOUTE PREMIÈRE action est de recréer le watchdog** (sinon plus aucun heartbeat, le
> dispositif autonome est mort). Vérifie d'abord avec `CronList` : s'il manque, recrée-le AVANT tout le reste.

- **watchdog 10 min** : `a73c2099` — cron `3-59/10 * * * *`. Ré-arme via `CronCreate` avec ce prompt exact :
  > WATCHDOG remédiation-ssot (10 min). Relis /home/lordzurp/wt-remediation/fleet/runtime/_remediation/CARNET-DE-BORD.md. Check court : est-ce que j'avance sur le plan ? un worker délégué est-il fini ou bloqué (si fini → consolide dans LEDGER.csv + avance à l'unité suivante) ? suis-je en train de dériver (« je fais vite ce bout ») ou d'attendre bêtement ? RÈGLE CARDINALE : aucun code ne bouge sur un finding non vérifié-percé (cf. PLAYBOOK.md). Si tout tourne bien, ne fais qu'un check et continue le travail en cours — ne churn pas. Si le chantier est en pause sans raison, relance l'étape suivante du PLAN.md.
- **relevé horaire (:47)** : `b1dc7bc3` — cron `47 * * * *` — checkpoint horaire (pause + écriture d'état).
- **À SUPPRIMER en fin de chantier** (CronDelete a73c2099 + b1dc7bc3).
- ⚠️ auto-expiration cron : 7 jours (ré-armer si le chantier dépasse).

## Décisions en attente (pour le user)

- **7 clusters DOCTRINE (D1-D7)** — voir `DECISION-BRIEF.md` (prêt à trancher, ma reco par cluster). Non-bloquant
  pour phases 1-2-4 ; D1/D6/D7 débloquent la phase 3.
