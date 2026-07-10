# CARNET DE BORD — état résumable (LIRE EN PREMIER si reprise)

**Date** : 2026-07-10
**Dernière révision** : 2026-07-10 (phase 0 CLOSE)
**Statut** : PHASE 0 CLOSE (167/167 vérifiés) — CHECKPOINT user en attente ; phase 1 prête
**Référencé par** : `PLAYBOOK.md`

> Si tu reprends ce chantier après un crash : lis ce fichier, puis `LEDGER.csv`, puis `PLAN.md`, puis le
> dernier bloc de `JOURNAL.md`. **Ne t'appuie PAS sur ta mémoire de contexte — l'état est ici.**

## Où on en est (MAINTENANT)

- **Worktree** : `/home/lordzurp/wt-remediation`, branche `remediation-ssot` off `main` (1f53f030b). Commit-local, ZÉRO push.
- **Source d'entrée** : `source-codex/findings-campaign.md` (167 findings F-C001→167, autorité) + `frontiers.md` (carte B1-B5).
- **Ledger** : `LEDGER.csv` — 167 findings, tous `verify_verdict=PENDING`, `phase=unassigned`. Rien vérifié encore.
- **Phase courante** : **0 — verify-sweep** (fan-out workers pour trier les 167 : percé / théorique / déjà-fixé / doctrine).
- **Code touché** : AUCUN. (Règle cardinale : rien ne bouge avant vérif percé.)

## Prochaine action précise

**Phase 0 CLOSE.** Verdicts consolidés dans `LEDGER.csv` + `CONSOLIDATION.md` (distribution + 6 familles de
verrous PERCE + 7 clusters DOCTRINE + WONTFIX théoriques). Détail par lot dans `verdicts/`.

**Checkpoint user posté** : (a) le fait 43 % DOCTRINE (te revient, 7 clusters D1-D7), (b) go/no-go phase 1.

**Dès GO** : PHASE 1 — hollow-gates F-C167 (gate-r0.8 vert-sans-check), F-C166 (bwrap secret-absent),
F-C164 (install.sh identity), F-C165 (provision-role-tokens divergent), F-C160 (brief-gate coverage).
Chacun : re-vérif moi-même (spot) → fix → test/gate → commit → journal. Rien avant re-vérif.

## Compteurs

| | valeur |
|---|---|
| findings totaux | 167 |
| vérifiés | **167 / 167** |
| PERCE code | 49 (6 familles) |
| PERCE doc | 25 |
| DOCTRINE (→ user) | 71 (7 clusters) |
| THEORIQUE (WONTFIX) | 21 |
| DEJA-FIXE | 1 |
| fixés (commit) | 2 (F-C166, F-C160) |
| constructeurs de frontière posés | 0 |

## Crons (session-only — à SUPPRIMER en fin de chantier)

- watchdog 10 min : `a73c2099`
- relevé horaire (:47) : `b1dc7bc3`

## Décisions en attente (pour le user)

- (aucune pour l'instant)
