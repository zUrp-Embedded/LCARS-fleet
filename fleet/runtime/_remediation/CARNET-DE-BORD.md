# CARNET DE BORD — état résumable (LIRE EN PREMIER si reprise)

**Date** : 2026-07-10
**Dernière révision** : 2026-07-11 ~08h45 (relevé horaire · attente stable, rien bougé · **BORD VÉRIFIÉ+AUDITÉ** — 0 unassigned, 49 fixes)
**Statut** : mécanique 100% close · **DOCTRINE : D1-D7 tous inventoriés+tagués · 49 fixes · reste STRICTEMENT décisions user (2 flags « bloqués » revérifiés : F-C026 fixé, F-C023 doc-intentionnel)**
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

**INVENTAIRES D3 + D6 FAITS (2+2 workers, cités).** TOUS les clusters D1-D7 ont désormais une table décision fact-backed dans DECISION-BRIEF.md. **Bord factuel DÉFINITIF.**
- **D3** : aucun fix mécanique fork-indep ; 7 archivables (dormant/gelé/test-only) + 2 gates morts (139/140) + 2 divergences (138-live, 159-schéma).
- **D6** : **4 doc-drifts FIXÉS** (F-C108/111/011/109-comment) + 1 PERCE blanchie (F-C112, backstop WakeRecovery) + 6 décisions direction (F-C110 fail-open HIGH · F-C143 · F-C138/142 dual-SSOT · F-C165 stale-vulcan ops · F-C007 sécurité · F-C013 test-infra).

**CE QUI RESTE = 100% DÉCISION USER** (rien d'actionnable sans toi) :
- **D3** : archive/keep/wire par item (tableau prêt) · **D6** : forks durcir-vs-relâcher + dual-SSOT (tableau prêt).
- **D7** : fork gate F-C167 (supprimer-vs-câbler) + rallumer Credo/Sobelow/Dialyzer + F-C161.
- **Design-forks** : F-C050 (state-split publishing) · F-C083 (typed-per-kind judge) · F-C066 (catch-all promote) · F-C118 (contrat public 501) · F-C135 (provisioning N0, sanctuaire).
- **Forward-guards (1 ligne)** : D1 (rail escalate_human sans jumeau forge → fail-loud) · F-C034/036/056 (R-08 require-vs-soft).
- **Sécurité/latent notables** : F-C110 (knobs escalade sans effet = fail-open silencieux) · F-C007 (architect a `fleet-forge.*` + `git_ops_denied:[]`).
- **F-C151** (dernier PERCE-doc) : dual-review canon — autorité juge = sp_drafts vs bundle ? (produit, D3).

**49 fixes livrés** (16 code + 33 doc/test) : 13 code pré-« go » (166/160/097/098/059/069/119/018/044/035/037/086/087) + F-C041/F-C125/F-C124 (code doctrine) + 22 doc pré-« go » + F-C046/051/102/006/167-modops + F-C108/111/011/109 + F-C040 + F-C026 (doc/test doctrine).
**Sweep watchdog-catch #3-4** : 29 lignes DOCTRINE non-taguées → toutes taguées (0 unassigned). F-C049 = correction R-14 de mon propre brief (dep PAS vestigiale, verify-before-fix). F-C061 = edge-case fail-open vérifiée (juge fleet affamé par humain en tête de pending) → D-review-fork. **F-C026 = punt levé → FIXÉ** (protocole actif, pointeur mort corrigé). **F-C023 = vraie décision, prémisse vérifiée** (architect SP hors block-SoT documenté-intentionnel, sp-map.yaml:8).
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
| **fixés (commit)** | **49** (16 code + 33 doc/test) |
| verrous posés | `boot_enabled?/2`, `encode_line/1` fail-safe, `safe_pod_info` :unknown, jury `:unexpected_review_shape`, `validate_issue_id`, `strip_control(role)`, `emit_spawn_failed` sur {:error} |
| règles méta posées | R-01 → R-15 |

## Crons — SUPPRIMÉS par l'user (2026-07-11 ~09h) — NE PAS RÉ-ARMER

> ⛔ L'user a explicitement coupé le watchdog + le relevé horaire (« stop tes cron ») une fois le bord
> factuel atteint : le factuel était fini, les crons ne faisaient plus que du bruit (confirmations « rien
> bougé » toutes les 10 min). **En reprise de session : NE recrée PAS ces crons.** Le chantier attend
> désormais une DÉCISION user, pas un heartbeat autonome. Si l'user veut relancer un dispositif autonome,
> il le demandera explicitement.

- ~~watchdog 10 min `a73c2099`~~ — supprimé (CronDelete).
- ~~relevé horaire :47 `b1dc7bc3`~~ — supprimé (CronDelete).

## Décisions en attente (pour le user)

- **7 clusters DOCTRINE (D1-D7)** — voir `DECISION-BRIEF.md` (prêt à trancher, ma reco par cluster). Non-bloquant
  pour phases 1-2-4 ; D1/D6/D7 débloquent la phase 3.
