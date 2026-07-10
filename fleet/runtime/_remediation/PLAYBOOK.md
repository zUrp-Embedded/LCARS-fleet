# PLAYBOOK — remédiation SSOT/irrepr (mon protocole)

**Date** : 2026-07-10
**Dernière révision** : 2026-07-10
**Statut** : actif — garant : Claude (Opus 4.8), branche `remediation-ssot`
**Référencé par** : `CARNET-DE-BORD.md`, `PLAN.md`

> Ceci est **mon** protocole, construit depuis l'`amorce` (beyond_#5.1) + la discipline exécutée cette
> session (campagnes soft-defaults + intégrité #2). L'amorce dit : *construire câble la gâchette, recevoir
> non*. Donc ce doc n'est pas une spec reçue — c'est le mien, vivant, je l'enrichis depuis la friction.
> **Si je le lis comme un manuel à dérouler, je rejoue la session-échec.** Il tient parce que je l'ai écrit.

## Mission (une ligne)

Remédier les **167 findings Codex** (SSOT/irreprésentabilité, `source-codex/findings-campaign.md`) — pas en
167 point-fixes, mais en **~15-20 constructeurs de frontière** qui rendent des familles entières
inreprésentables — chaque finding **vérifié percé** avant tout fix, moi garant, workers en fan-out.

## RÈGLE CARDINALE (le premier filtre, non-négociable)

**On ne fixe pas un truc qui n'est pas percé.** Aucun code ne bouge sur un finding avant :
1. **Vérif : la brèche est-elle RÉELLE et ATTEIGNABLE ?** Pas « état invalide constructible en théorie » —
   un chemin réel doit y mener. Verdict ∈ `PERCÉ` / `théorique-non-atteignable` / `déjà-fixé` / `doctrine`.
2. **Vérifier le vérificateur.** Le rapport ment aussi sur *OÙ* va le fix (leçon WAL : Codex situait le fix
   dans `read_wal`, mais `decode/1` avalait déjà l'erreur → branche morte). Lire **le vrai chemin de
   données**, pas la ligne pointée.
3. **Citations obligatoires.** Un verdict sans citation de code = rejeté. *On ne cite pas une preuve qui
   n'existe pas.*

`théorique-non-atteignable` → documenté WONTFIX (ou verrou si cheap, jamais fix-fantôme).
`déjà-fixé` → référencer le commit (ma campagne intégrité/soft-defaults a peut-être couvert).
`doctrine` → je flag, je ne tranche pas seul.

## Pipeline par finding

```
vérifier(percé?) → concevoir le VERROU AMONT (pas un raise au site) → RED → GREEN → gate → commit/unité → journal
```

- **Verrou amont** = rendre le vide inreprésentable à la construction/schéma (smart-ctor, champ requis,
  parse-au-bord, fail-closed-au-boot). Puis **supprimer le cas par défaut**. Symptôme-fix (repli→raise) =
  inférieur ; quand le vide est un transitoire externe, fail-CLOSED au point le plus tôt.
- **Un verrou tue une FAMILLE.** Ne pas fixer 90× le même pattern B5 — poser LE smart-ctor d'entrée
  (load cap-profile, load workflow-map, parse forge-id, parse config/env, decode payload event) et laisser
  la famille s'effondrer, test prouvant que le vieux mauvais état ne se construit plus.

## Délégation (moi garant, workers en fan-out)

| Délégable (workers) | Je me garde (critique) |
|---|---|
| Vérif adversariale des findings (percé/théorique/déjà/doctrine + citations) | Design des **constructeurs de frontière** (B5, load-bearing) |
| Fixes mécaniques (doc-drift, narratif menteur) en lots | Les **calls doctrine** (flag, pas trancher) |
| Écriture des tests RED | La **vérif finale + le gate** de chaque unité |
| Recon de chemin de données | Le **PLAN** (le canard) — jamais délégué |

Un worker rend : verdict + citations + (si percé) le vrai chemin de données + proposition de verrou. **Je
relis avant tout commit.** Je ne commit jamais un fix que je n'ai pas relu.

## Phasage (cf. PLAN.md pour le détail vivant)

0. **Verify-sweep** — fan-out, trier les 167.
1. **Hollow-gates** — les gates qui mentent (vert-sans-check) = poison de la couche de vérif → d'abord.
2. **B5 constructeurs de frontière** — la famille dominante (~90).
3. **B3 contrat d'events** — schéma payload + source-match + classification lifecycle + politique Cat-5.
4. **B2 échecs-avalés→faux-succès** — ma classe intégrité, exhaustive.
5. **Batch doc/narratif** — B4 dérive + mensonges.

Checkpoint (relevé + user) entre phases.

## NON-NÉGOCIABLES (seed 8 — je ne les dérive pas ; si le code diverge, je FLAG, je n'inverse pas)

- **commit-local, ZÉRO push** sans OK explicite du user.
- Doctrine : verrou-amont · pas de repli · cache = mensonge (staleness) · **pas d'outbox** (2e SSOT ;
  Codex l'a rétractée) · event-driven-avec-trou = niet · Bus lossy fast-path, forge+poll = substrat durable.
- Frontières vendor. Ne jamais **inverser un invariant** pour faire passer un test = signature exacte de la dérive.
- Ne pas broad-refactor (pas de migration umbrella). Additif : fermer un finding OU poser un mécanisme
  de frontière qui rend une famille inreprésentable.

## Mes gâchettes de dérive (les stops, dans ma voix)

- Je me surprends à « je fais vite ce bout-là » → **STOP**, c'est un signal, pas un réflexe. Un raccourci
  vient d'un déficit d'outil/règle, **jamais** d'un manque de temps/budget. Le budget est un filet.
- Un worker me rend un verdict **sans citation** → rejeté, re-délégué.
- Je m'apprête à fixer un finding **sans avoir lu le vrai chemin de données** → STOP, je vérifie d'abord.
- Je m'apprête à **inverser un invariant** ou **assouplir un test** pour faire passer → STOP, je FLAG au user.
- Verbaliser au point de décision dur-à-défaire : (a) le problème, (b) ce que je propose, (c) **ce qui
  pourrait clocher**. Si je ne trouve rien sur (c), je n'ai pas regardé.

## Cadence & externalisation d'état (seed 4)

- `CARNET-DE-BORD.md` = l'état **résumable** (à lire EN PREMIER si reprise après crash). Tenu à jour à
  chaque unité et à chaque relevé.
- `JOURNAL.md` = chronologique (ce qui est fait, les commits).
- `META-DEBRIEF.md` = boucle de débrief : chaque dérive évitée → règle datée (garde le protocole vivant).
- `LEDGER.csv` = l'état des 167 (verdict de vérif + phase + statut).
- **Crons** (retirés à la fin) : watchdog 10 min (liveness/progrès) + relevé de poste horaire (checkpoint écrit).

## Reprise après crash (le point de l'externalisation)

Si une session repart de zéro : lire dans l'ordre → `CARNET-DE-BORD.md` (où j'en suis, prochaine action) →
`LEDGER.csv` (état des 167) → `PLAN.md` (phases) → `JOURNAL.md` (dernier commit) → continuer. **Ne jamais
s'appuyer sur la mémoire de contexte volatile — l'état est dans le FS, versionné.**

## Fin de chantier

Retirer les crons (un watchdog qui sonne sans personne = du bruit). Relevé final. Le user range.
