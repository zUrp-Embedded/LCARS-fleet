# CARNET DE BORD — état résumable (LIRE EN PREMIER si reprise)

**Date** : 2026-07-10
**Dernière révision** : 2026-07-10 (phase 0 lancée)
**Statut** : PHASE 0 — verify-sweep EN COURS (8 workers en fan-out)
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

**Attendre les 8 workers de vérification** (lots : C001-021 / C022-042 / C043-063 / C064-084 / C085-105 /
C106-126 / C127-147 / C148-167). Dès qu'ils rendent : **consolider les verdicts dans `LEDGER.csv`**
(verify_verdict = PERCE/THEORIQUE/DEJA-FIXE/DOCTRINE + phase), spot-vérifier moi-même les PERCE à fort
enjeu (je ne fais pas confiance aveugle aux workers non plus), puis regrouper les PERCE B5 en familles de
constructeurs. ENSUITE seulement : phase 1 (hollow-gates). Rien ne touche le code avant ça.

## Compteurs

| | valeur |
|---|---|
| findings totaux | 167 |
| vérifiés | 0 / 167 |
| percés confirmés | — |
| fixés (commit) | 0 |
| constructeurs de frontière posés | 0 |

## Crons (session-only — à SUPPRIMER en fin de chantier)

- watchdog 10 min : `a73c2099`
- relevé horaire (:47) : `b1dc7bc3`

## Décisions en attente (pour le user)

- (aucune pour l'instant)
