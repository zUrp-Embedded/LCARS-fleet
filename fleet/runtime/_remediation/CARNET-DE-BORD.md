# CARNET DE BORD — état résumable (LIRE EN PREMIER si reprise)

**Date** : 2026-07-10
**Dernière révision** : 2026-07-10 (montage initial)
**Statut** : PHASE 0 — verify-sweep, sur le point de lancer
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

Lancer la **phase 0** : fan-out de workers Explore, chacun un lot de ~20-25 findings, chaque worker
VÉRIFIE contre la source (percé + atteignable + citations + vrai chemin de données), rend un verdict par
finding. Puis je consolide dans `LEDGER.csv`.

## Compteurs

| | valeur |
|---|---|
| findings totaux | 167 |
| vérifiés | 0 / 167 |
| percés confirmés | — |
| fixés (commit) | 0 |
| constructeurs de frontière posés | 0 |

## Crons

- watchdog 10 min : (à créer sur montage)
- relevé horaire : (à créer sur montage)

## Décisions en attente (pour le user)

- (aucune pour l'instant)
