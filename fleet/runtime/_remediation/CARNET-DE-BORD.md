# CARNET DE BORD — état résumable (LIRE EN PREMIER si reprise)

**Date** : 2026-07-10
**Dernière révision** : 2026-07-10 (pass-2 consolidé · 9 fixés · shortlist CLEAN-FIX en cours)
**Statut** : PHASE 1 CLOSE · PHASE 2/4 EN COURS (9 CLEAN-FIX livrés, 6 PERCE ouverts)
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

**Continuer la shortlist CLEAN-FIX** en TDD (RED→verrou amont→GREEN→commit→journal), verify-moi avant chaque fix.
**Restent 6 PERCE ouverts** :
- **F-C035** (broker `:unknown` → brief admin.spawn droppé ; jumeau `brief_slot` 3-state + branche `:free`)
- **F-C037** (hiccup TaskQueue consomme `:result_deadline` ; jumeau `brief_slot` 3-state + `rearm_deadline`)
- **F-C086** (scaffold `mkdir_p!` viole @spec typé ; jumeau `File.write` in-fn ; faible enjeu)
- **F-C031** (plugin skill whitespace lossy ; jumeau `Fleet.Slug` ; basse prio, danger déjà rattrapé par bwrap)
- **F-C075, F-C076** (Sysadmin escalation/assignee) — **JAMAIS re-vérifiés (oubli délégation)** → consequence-check MOI-MÊME avant tout fix.
**Rien ne bouge sur un finding non-confirmé-percé-ET-conséquence-matérialisée.**

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
| **PERCE** (verify_verdict) | **15** (4 FIXÉ + 11 ouverts : 9 CLEAN-FIX + F-C075/076 à re-vérif) |
| PERCE-doc | 25 |
| **DOCTRINE** (→ user) | **85** (7 clusters D1-D7 + 7 ajouts pass-2, voir DECISION-BRIEF.md) |
| THEORIQUE (WONTFIX) | 41 |
| DEJA-FIXE | 1 |
| **fixés (commit)** | **6** (F-C166, F-C160, F-C097, F-C098, F-C059, **F-C069**) |
| constructeurs de frontière posés | 3 (`boot_enabled?/2`, `encode_line/1`, `safe_pod_info` :unknown) |
| règles méta posées | R-01 → R-09 |

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
