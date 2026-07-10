# BRIEF DE DÉCISION — DOCTRINE (les arbitrages qui te reviennent)

**Date** : 2026-07-10
**Dernière révision** : 2026-07-11
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

> **Preview D7 (fait, data concrète)** — **Credo (F-C023)** : PAS « off » — 69 checks actifs ; les « désactivés »
> sont exactement la liste **standard opt-in de Credo** (controversial/experimental : SinglePipe, MultiAlias,
> ABCSize, Specs, DuplicatedCode… = style/opinion, PAS correctness). `--strict` remonterait **221 suggestions**
> (91 refactor + 36 lisibilité + 94 design) = bruit. → reco affinée : **laisser tel quel** ; au plus activer
> `Readability.Specs` si tu veux imposer les @spec (discipline). Reste à preview à l'ouverture de D7 : **Sobelow**
> (sécurité, plus load-bearing), **Dialyzer** (scope), **F-C167** (le seul vrai « garde qui ment »).

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

---

## Ajouts PASS-2 — 7 findings reclassés DOCTRINE à la re-vérif (chacun un fork de fix)

> Ces 7 étaient « PERCE » en phase 0 ; la re-vérif consequence-check (R-09) montre que leur **fix a
> plusieurs formes valides / change un contrat** → ils te reviennent. Détail tracé dans `CONSOLIDATION-PASS2.md`.

| Finding | Le fork à trancher | Ma reco | Cluster |
|---|---|---|---|
| **F-C043** | seed permanent corrompu → **fail boot** (aucun architect/gatekeeper) *vs* **session fraîche** (marche, perd l'identité resume) | fail-closed sur `présent-invalide`, degrade seulement sur `absent` (comme F-C045) | **D5** |
| **F-C047** | `get_issue_status.delivered` conflate fermeture≠merge → **exiger une preuve merge forge** (nouvelle capacité) *vs* **affaiblir le champ** (`issue_closed`, delivered=unknown) | affaiblir le champ (cheap) + noter la capacité merge-proof en backlog | **D6** |
| **F-C053** | rôle cap-profile non-chargeable classé juge-payload → typer `deliverable_mode` `{:ok\|:error}` (re-câble GateEngine) *vs* fail-closed au load | fail-closed au **load** cap-profile (verrou amont) plutôt que threader un contrat dans le GateEngine | **D4** |
| **F-C066** | gatekeeper seal rend `:ok` après close-KO → propager `{:error,{:close,_}}` **casse** `StepRunCompleter.promote` (pas de catch-all) + policy unlock-sur-close-KO | ajouter la clause catch-all chez `StepRunCompleter.promote` PUIS propager + garder `lcars-in-flight` (skip re-dispatch) | **D1** |
| **F-C084** | ProjectOnboard `already_exists`→succès avant preuve repo-mutable → change l'**idempotence documentée** ; `import/2` est le twin correct | garder l'idempotence + guider vers `import/2` (déjà documenté) ; pas de fail-closed unilatéral | **D2** |
| **F-C141** | schéma cap-profile n'exige pas `allowedTools` (que `claude_launch` hard-requiert, fail-loud jq exit 1) → **schéma-requis** *vs* **invariant sémantique** | invariant `allowedTools` (comme le jumeau `disallowedTools`), cohérent avec la codebase | **D7** |
| **F-C161** | schéma gate-decision exige `reason`, runtime non → **durcir runtime** (halt_invalid) *vs* **relâcher schéma** (directions opposées, jumeau F-C167) | durcir le runtime vers le schéma (traçabilité verdict) — à trancher AVEC F-C167 | **D7** |

**Note honnêteté** : F-C075 et F-C076 (Sysadmin escalation / assignee) ont été **oubliés** dans la délégation
de re-vérif → je les re-vérifie moi-même avant de conclure ; ils pourraient ajouter 0-2 items ici ou en CLEAN-FIX.

### Item doctrine surgi PENDANT le fix F-C059 (couche-2)
**F-C059-b (contrat `pod_info` : absent vs timeout-vivant)** — le fix F-C059 a fermé l'asymétrie du *raise*
(→ `:unknown` → defer). Mais `pod_info` rend `{:error, :not_found}` pour DEUX états indistinguables à ce niveau :
un pod **vraiment mort** ET un pod **vivant-mais-lent** dont le `GenServer.call` timeout. Donc un pipe vivant-lent
peut encore être classé `:dead` → reset/kill. **On ne peut pas** traiter `{:error,:not_found}` comme incertain au
niveau `safe_pod_info` (un pod mort resterait `:busy` = wedge du pipe). → **Le fork** : donner à `pod_info` (côté
spawner) un contrat qui **distingue `:absent` de `:timeout`** (ex : `{:error, :timeout}` vs `{:error, :not_found}`),
puis mapper `:timeout → :busy`. Ma reco : oui, split le contrat `pod_info` (verrou amont correct), cluster **D6**
(SSOT/contrat). Effort : moyen (touche le spawner + les 2 lecteurs `pod_alive?`/`safe_pod_info`).

### Ajouts pass-2b — fiabilité escalade incident (D1)
**F-C075 / F-C076** (`incident_registry/escalation.ex`) — la création d'issue sysadmin dégrade un canal de
découverte SANS perdre l'escalade (l'issue existe, logguée LOUD) :
- **F-C075** : échec du label `error_system` → issue trouvable par assignee+log mais pas par filtre-label.
  *Fork* : accepter assignee+log (garder `{:ok}`), ou fail-closed avec **dédup** (propager `{:error}` seul
  risque des doublons — l'issue existe déjà). Ma reco : garder `{:ok}` + éventuel retry-label borné.
- **F-C076** : retry-sans-assignee sur TOUTE erreur (pas seulement account-absent). *Fork* : garder la
  « précédence escalade » documentée (issue créée même sans assignee), ou classifier (préserver l'assignee
  sur transitoire, au prix de moins d'issues créées). Ma reco : garder la précédence (l'alerte prime).

### Ajout phase-5 — F-C151 canon dual-review (D3 cleanup, VÉRIFIÉ live)
**F-C151** — le modop-bundle `dual-review/sp.md` décrit « qualifier check spec compliance / reviewer check
code quality ». Or les `sp_drafts` (autorité courante, servis aux pods) disent l'INVERSE : qualifier =
valide la **preuve de test**, reviewer = valide la **conformité au brief**. Et `dual-review` est
`optional: [dual-review]` dans **qualifier.yaml + reviewer.yaml** + référencé dans `standard-qa.yaml` →
**assemblable dans un SP vivant** → contradiction d'instructions pour un pod juge, PAS juste une doc périmée.
*Fork (D3)* : (a) réécrire le bundle + les 2 subagent-templates pour matcher les sp_drafts, ou (b) supprimer
`dual-review` du modop_set (superseded par les drafts). Ma reco : aligner sur les sp_drafts (autorité), OU
retirer si le modèle dual-review est mort. Décision produit (qu'est-ce qui est l'autorité canonique du juge ?).

### Décomposition D4 (pré-classif factuelle, à vérifier-percé finding par finding)
Le cluster « config require-vs-soft » N'EST PAS homogène :
- **Mal-rangés (pas de la config)** : F-C040 = stale-README (doc-fix) · F-C049 = dep `fleet_event_router` vestigiale dans mix.exs (hygiène dep).
- **Vraie config-validation load-bearing → parse-au-bord/fail-loud** (ma reco = appliquer EnvParse, à vérifier-percé) : F-C034 (:claude_dir bypass résolution creds), F-C036 (mcp_server_spec non validé), F-C041 (launch_backend dispatch sans garde de conformité), F-C056 (role/pod-id from config non validés).
- **Config-int keys-JAMAIS-posées (R-08, défensif)** : 082/099/104/117 — garde-anti-misconfig-future ; fail-loud défensif si tu veux, mais aucune valeur malformée n'y arrive aujourd'hui.
- **Autres concerns (pas require-vs-soft)** : F-C052 (fallback legacy vs event=SSoT → fail-closed), F-C063 (default brief-gate caché = documenté), F-C064 (troncature repo-id 4 digits → identité).
→ Après vérif, D4 se réduit à ~4 fixes config-validation + 2 doc/dep + 4 défensifs + 3 autres. Ta décision : appliquer EnvParse aux 4 load-bearing ? (les 4 défensifs + autres = sous-décisions séparées.)
