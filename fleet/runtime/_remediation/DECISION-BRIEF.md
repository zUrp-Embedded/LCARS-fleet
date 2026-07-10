# BRIEF DE DÉCISION — DOCTRINE (les arbitrages qui te reviennent)

**Date** : 2026-07-10
**Dernière révision** : 2026-07-10
**Statut** : actif — prêt à décider (7 clusters). Les workers re-vérif en vol peuvent ajouter des doctrine-tails (D5/D6 surtout).
**Référencé par** : `CONSOLIDATION.md`, `CARNET-DE-BORD.md`, `PLAN.md`

> Règle de la campagne : *je propose, tu tranches*. Aucun de ces findings ne bouge sans ton OK — ce ne sont pas
> des bugs mécaniques mais des choix de design (contrat, policy, SSOT, tolérance). Chaque cluster = **1 décision**,
> pas N questions. Pour chacun : la question, MA reco de garant + son ancrage doctrine, l'effort, les findings.

---

## D1 — Fiabilité events/escalades : best-effort vs load-bearing
**Findings** : 019, 046, 051, 058, 089, 091, 093, 095, 101, 102, 103, 105

**Question** : pour chaque rail (Cat-5, coord, audit, boot, incident), un échec d'émission/consommation doit-il
**fail-loud** (load-bearing) ou rester **observabilité best-effort** ?

**Ma reco** — *trancher par le substrat, pas par le rail* : la doctrine maison est déjà claire — **le Bus est un
accélérateur lossy ; la vérité durable vit dans le substrat forge+poll**. Donc :
- Rail dont le fait n'existe QUE dans l'event (aucune re-dérivation forge) → **fail-loud** : incidents, escalades
  Cat-5, anchors. Un event perdu = un fait perdu = trou → *niet*.
- Rail purement observabilité dont le fait est re-dérivable au poll (coord, audit, boot) → **best-effort assumé**,
  À CONDITION que Readiness surface `:degraded` (déjà fait pour plusieurs). Fail-loud ici = fragilité gratuite.

→ **Décision demandée** : valides-tu ce partage « fail-loud si non-re-dérivable / best-effort si observabilité +
Readiness » ? Si oui je classe chaque finding dans l'un des deux et je fixe les fail-loud (famille A).
**Effort** : ~4-5 edits fail-loud + reclassement du reste en best-effort-documenté.

---

## D2 — Stubs MVP / dormant : câbler, marquer 501, ou supprimer
**Findings** : 038, 042, 105, 118, 120, 124, 125, 126, 135, 136 (read-models obs/api, GIT_MIRROR, gatekeeper
content-agnostic, NoOpDispatcher…)

**Question** : chaque stub qui **no-op silencieusement** (a l'air câblé, ne fait rien) — on câble, on marque
inactif explicitement, ou on supprime ?

**Ma reco** — *un no-op silencieux est un mensonge* (non-négociable « ne pas faire vivre un faux-succès »). Le fix
le moins cher et honnête pour TOUS : **marquer dormant explicitement** (`{:error, :not_implemented}` / 501 / log
boot `DORMANT`) au lieu du no-op muet. Puis, séparément, tu me dis lesquels **câbler pour de vrai** (besoin
produit) vs **supprimer** (pas de nostalgie — ton mantra).

→ **Décision demandée** : (a) OK pour « explicit-dormant partout » comme baseline ? (b) lesquels câbler / jeter ?
**Effort** : baseline = ~10 marqueurs mécaniques ; câblage/suppression = selon ta liste.

---

## D3 — Canon Memory-X / legacy / modop-bundles : le grand ménage
**Findings** : 133, 138, 139, 140, 144, 145, 146, 147, 152, 153, 156, 157, 159

**Question** : le canon dormant (frozen-monks, pipelines non-v2.5, modop-bundles non-assemblés,
subagent-templates) — relocate, archiver, ou câbler ?

**Ma reco** — *je ne peux pas trancher seul* : c'est ta connaissance produit (qu'est-ce qui est encore vivant ?).
Défaut proposé : **archiver le non-v2.5 + frozen**, **garder+câbler le référencé** (ce qu'un pod consomme vraiment).
Je peux te sortir un inventaire « qui référence quoi » pour décider vite.

→ **Décision demandée** : veux-tu l'inventaire de références d'abord ? puis tu marques archive/keep/wire par item.
**Effort** : inventaire délégable ; l'action = déplacements/suppressions mécaniques une fois ta liste posée.

---

## D4 — Config opérateur : require-au-boot vs soft-default
**Findings** : 034, 036, 040, 041, 049, 052, 056, 063, 064 **+ 082, 099, 104, 117** (reclassés ici par R-08 —
clés jamais posées, garde-anti-misconfig)

**Question** : quelles clés `Application.get_env` doivent **fail-loud au boot** sur valeur malformée au lieu d'un
défaut mou ?

**Ma reco** — *appliquer la doctrine EnvParse déjà établie dans le code* : « un knob LOAD-BEARING invalide →
raise, boot refusé ». Donc split par nature :
- Knob load-bearing (topologie, containment, sécurité, budgets qui cadrent un comportement) → **require/fail-loud**.
  (C'est ce que j'ai fait pour F-C097 boot `:start_*` — précédent posé.)
- Knob de pur tuning avec défaut sûr (intervalles, spacing d'affichage) → **soft-default OK**, pas de fail-loud.

→ **Décision demandée** : valides-tu le split « load-bearing → fail-loud / tuning → soft-default » ? Je te
proposerai la liste clé-par-clé (load-bearing vs tuning) pour confirmation avant tout edit.
**Effort** : ~1 helper de parse partagé + N sites (petits), une fois le split confirmé.

---

## D5 — Tolérances délibérées : garder ou resserrer
**Findings** : 001, 016, 021, 033, 045, 048, 050, 080, 081, 083 (+ **010** doctrine-tail : webhook fabrique
`fleet/lcars` par défaut, backward-compat single-repo documentée)

**Question** : chaque dégradation **documentée-délibérée** (fallback backward-compat, tolérance) — on garde ou on
resserre en fail-closed ?

**Ma reco** — *garder par défaut, resserrer seulement si ça cache un fait load-bearing* : ces tolérances sont
documentées et intentionnelles. Le test : la tolérance **masque-t-elle une perte de vérité durable** ? Si non
(cosmétique / compat / dégradation observée) → garder. Si oui → resserrer. Cas par cas, mais je penche **garder**
la majorité (c'est du design assumé, pas de la dette accidentelle).

→ **Décision demandée** : OK pour « garder sauf si masque un load-bearing » ? Je te liste les 2-3 qui, à mon avis,
méritent un resserrage (ex : F-C010 fabrique une identité repo — borderline).
**Effort** : quasi nul si « garder » ; ~2-3 edits si resserrage ciblé.

---

## D6 — Complétude policy / SSOT cross-surface
**Findings** : 007, 011, 013, 108, 109, 110, 111, 112, 142, 143 (+ **165** : 2e liste de rôles hardcodée qui
diverge des cap-profiles canoniques)

**Question** : plusieurs surfaces encodent la même policy (rôles, catalogue Python↔Elixir, id-vs-number,
severity-knobs) — quelle surface est le **SSOT**, les autres en dérivent ?

**Ma reco** — *un SSOT par policy, les autres se dérivent ou se valident contre lui* (non-négociable SSOT). Mais la
DIRECTION (qui est la source) est ton call — ça touche des surfaces déployées (provisioning, cross-langage). Ex
F-C165 : le SSOT des rôles = les cap-profiles (`needs_role_token`) → la liste hardcodée du provisioning devrait en
dériver, pas diverger. Je propose la direction, tu confirmes avant de câbler (risque cross-surface).

→ **Décision demandée** : pour chaque paire, veux-tu que je propose la direction SSOT (avec le coût de câblage) et
tu valides une par une ? Certaines nécessitent une coordination consommateur (id-vs-number = clé de corrélation).
**Effort** : variable ; certaines mécaniques (dériver une liste), d'autres cross-cutting.

---

## D7 — Outillage : réactiver les gardes
**Findings** : 023, 026, 121, 122, 123, 127, 129 (+ **167** : gate-r0.8-canon vert sans rien checker — l'invariant
`05_data-canon` est en fait VIOLÉ dans 5 tests)

**Question** : Credo checks off, Sobelow hors-gate, Dialyzer scope réduit, exclusions test périmées, gate-canon
creux — on réactive ?

**Ma reco** — *réactiver incrémentalement, fixer ce qui remonte* : un garde désactivé est un garde qui ment. Mais
rallumer d'un coup peut faire remonter du bruit latent. Ordre proposé : (1) le gate-canon F-C167 (câbler la vraie
vérif OU supprimer le scaffold obsolète + les 5 refs mortes — **fork à trancher**), (2) exclusions test périmées
(mécanique), (3) Credo/Sobelow/Dialyzer un par un.

→ **Décision demandée** : (a) F-C167 — câbler la vérif canon réelle, ou supprimer le scaffold `05_data-canon`
obsolète (+ nettoyer les 5 refs) ? (b) OK pour rallumer Credo/Sobelow/Dialyzer incrémentalement ?
**Effort** : F-C167 selon ton fork ; le reste incrémental.

---

## Synthèse — ce dont j'ai besoin de toi

| Cluster | La décision en une ligne | Bloque |
|---|---|---|
| **D1** | fail-loud si non-re-dérivable / best-effort si observabilité+Readiness ? | Phase 3 + partie de 4 |
| **D2** | explicit-dormant baseline OK ? + lesquels câbler/jeter | — |
| **D3** | inventaire d'abord ? puis archive/keep/wire par item | — |
| **D4** | split load-bearing→fail-loud / tuning→soft-default ? | — |
| **D5** | garder sauf si masque load-bearing ? | — |
| **D6** | je propose la direction SSOT, tu valides une par une ? | id-vs-number touche corrélation |
| **D7** | F-C167 câbler-vs-supprimer ? + rallumer l'outillage incrémental ? | gate CI |

**Rien de bloquant pour les phases 1-2-4 en cours** (fixes PERCE mécaniques). Les décisions D1/D6/D7 débloquent la
phase 3. Tu peux répondre cluster par cluster, dans l'ordre que tu veux.
