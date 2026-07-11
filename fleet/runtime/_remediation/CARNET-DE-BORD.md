# CARNET DE BORD — état résumable (LIRE EN PREMIER si reprise)

**Date** : 2026-07-10
**Dernière révision** : 2026-07-11 ~02h45 (relevé · **BORD FACTUEL ATTEINT** — plus aucun travail non-bloqué)
**Statut** : mécanique 100% close · **DOCTRINE : D1/D2/D4/D5 traités + F-C124/F-C006/F-C167-inventaire faits** · reste STRICTEMENT décisions user
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

**PHASE DOCTRINE — BORD FACTUEL ATTEINT.** Tous les items fork-indépendants sont faits. Le reste est STRICTEMENT décisionnel (fork user) → continuer à re-analyser = churn (R-13). **Je présente l'état et j'attends la décision** (homme-mort actif, PAS un stop-and-wait : le chantier actionnable est réellement épuisé).

**Traité : D1, D2, D4, D5 + F-C124 + F-C006 + inventaire F-C167.** Pattern : ~1 fix/cluster, le code applique déjà la doctrine.
- **F-C124 FIXÉ** (D2, additif) : `/api/projection` expose `_status` (:live|:unavailable) via `projection_status/0`. read-model DOWN ≠ fleet calme.
- **F-C006 FIXÉ** (test-integrity) : test « apiVersion » menteur → garde de migration réel (profil valide + apiVersion → rejeté, additionalProperties:false).
- **F-C167 inventaire** : gate creux (`check_app` défini-jamais-appelé → exit 0 sans grep). 7 refs `05_data-canon` = TOUTES mentions historiques, 0 dep vivante. modops:62 (seul misleading indep-fork) FIXÉ. **Fork réduit → reco : supprimer le scaffold** (câbler ferait des faux-positifs sur les commentaires exacts). Détail : DECISION-BRIEF.md §D7.

**CE QUI RESTE = 100% DÉCISION USER** (rien d'actionnable sans toi) :
- **D3** (canon Memory-X/legacy) · **D6** (SSOT cross-surface) = connaissance produit.
- **D7** : fork gate F-C167 (supprimer-vs-câbler) + rallumer Credo/Sobelow/Dialyzer.
- **Design-forks** : F-C050 (state-split publishing) · F-C083 (typed-per-kind judge) · F-C066 (catch-all promote) · F-C118 (contrat public 501) · F-C135 (provisioning N0, sanctuaire).
- **Forward-guards (1 ligne)** : D1 (rail escalate_human sans jumeau forge → fail-loud) · F-C034/036/056 (R-08 require-vs-soft).
- **F-C151** (dernier PERCE-doc) : dual-review canon — autorité juge = sp_drafts vs bundle ? (produit, D3).

**43 fixes livrés** (16 code + 27 doc/test) : 13 code pré-« go » (166/160/097/098/059/069/119/018/044/035/037/086/087) + F-C041/F-C125/F-C124 (code doctrine) + 22 doc pré-« go » + F-C046/051/102/006/167-modops (doc/test doctrine).
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
| **PERCE-doc** | 25 (**24 FIXÉS** ✅ + 1 décision produit : F-C151) |
| **DOCTRINE** (→ user) | **87** (7 clusters D1-D7 + ajouts pass-2/2b + F-C059-b ; D1/D2/D4/D5 traités, reste D3/D6/D7-forks) |
| THEORIQUE (WONTFIX) | 42 |
| DEJA-FIXE | 1 |
| **fixés (commit)** | **43** (16 code + 27 doc/test) |
| verrous posés | `boot_enabled?/2`, `encode_line/1` fail-safe, `safe_pod_info` :unknown, jury `:unexpected_review_shape`, `validate_issue_id`, `strip_control(role)`, `emit_spawn_failed` sur {:error} |
| règles méta posées | R-01 → R-13 |

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
