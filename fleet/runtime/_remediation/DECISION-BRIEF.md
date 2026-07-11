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

> **INVENTAIRE D3 FAIT (2 workers read-only, cité, consequence-check).** Aucun de ces 13 findings n'est un fix
> mécanique fork-indépendant : tous se réduisent à « canon dormant → décision archive/keep » ou à une divergence
> de direction (SSOT). Le tableau collapse ta décision :
>
> | Finding | Verdict factuel (consommateur/cible réel) | Ta décision |
> |---|---|---|
> | **F-C138** | **DUPLIQUÉ-AUTORITÉ, DIVERGENT + LIVE** — bridge Python (transport pod↔central de PROD) répond `tools/list` depuis une liste HARDCODÉE de 5 outils ; l'autorité Elixir `pod_tools.ex` en a **6** → **`import_project` invisible aux pods** (appelable si forwardé, mais non-découvrable). | **D6 : quel SSOT ?** dériver le catalogue Python de l'autorité (bon fix) vs sync-manuel (entérine le 2e SSOT). Conséquence live = à prioriser. |
> | **F-C159** | **schéma exige `profile`, runtime l'IGNORE** (prod lit `step["role"]` ; grep `["profile"]` prod = 0). Touche AUSSI les maps actives standard-qa/audit-only/brief-gate. | **fork jumeau F-C161/167 : durcir runtime (consommer profile) vs relâcher schéma** (retirer le require). |
> | **F-C144** | ORPHELIN — noop en 2 copies ; `canon/modop/noop` sous aucune racine, `cap-profiles/modop/noop` atteint QUE via `compose/2` = test-only. Prod = `CapProfile.load/1` (0 modop). | archivable |
> | **F-C145** | ORPHELIN — overlays modop lus QUE par `read_modops`←`compose/2` (test-only). Prod = `SPBuilder.compose(cap, [], …)` (0 overlay). | archivable |
> | **F-C146** | TEST-ONLY — prod passe modops=`[]` → `read_modop_fragments([])` ne lit rien ; `:modop_root` jamais configuré (`{:error, :modop_root_unconfigured}`, verrouillé moduledoc « never required in prod »). Seul lecteur : `modops_consumption_test.exs`. | archivable OU câbler la feature modop (dormante par conception) |
> | **F-C147** | TEST-ONLY — `subagent-templates/*.md` lus par AUCUN code prod (grep hors-test = 0). Seul lecteur : `modops_consumption_test.exs:39`. | archivable / keep-wire |
> | **F-C152** | dormant (dépend de F-C146) — `subagent-driven` listé `engineer.yaml:106 modop_set.optional` MAIS modop_set jamais assemblé en prod (cf F-C146) → référence morte. Doc-drift « cap-profile implementer » (n'existe pas ; = subagent-template sur engineer) inutile à fixer tant que dormant. | suit la décision modop-bundle (F-C146) |
> | **F-C157** | GELÉ — injection monk lit `cap-profiles/monks/` (`monk.ex:52`) = **dir inexistant** ; `_frozen-monks/` non-scanné ; tous les cap-profiles prod ont `monk_registry: null` → `:not_a_monk`. Alpha/beta divergents vivent tous sous `_frozen-monks/`. | archivable (gel délibéré, documenté) |
> | **F-C156** | ORPHELIN — `priv/canon/` RACINE (8 fichiers : README, cap-profiles/{archivist,monk}, fleets/*, sp/*) lu par AUCUN code prod ; vrai canon = `apps/fleet_cap_profile/…`. Forme non-v2.5. | relocate vs **supprimer** (doublon legacy, 0 risque) |
> | **F-C133** | DOC-DRIFT (sur README de F-C156) — décrit `Fleet.Instance.Loader` **jamais écrit** (0 occurrence) + source v1.5 morte `/local/LCARS-v1.5/sp/`. | part avec F-C156 (si supprimé) sinon réécrire |
> | **F-C139** | CIBLE-ABSENTE — `get_task` retiré (autorité = `get_work_item`, work_item_id MANDATORY). Fixture `mcp_submit_server.py` + gate inc4 **morts** (inc4.sh non-exec, hors-CI). | supprimer le harnais legacy vs réécrire vers get_work_item |
> | **F-C140** | gate `inc3b1` vise une cible VIVANTE (`pod_tools_test.exs`) mais toute la famille R-CORE.comm est non-exécutable + non-câblée CI (gates manuels orphelins). | rendre exec + câbler CI vs archiver (doublon `mix test`) |
> | **F-C153** | CIBLE-ABSENTE — `cap-profiles/monks/` inexistant ; glob `catalog.ex:111` = scaffolding INERTE documenté ; `_FROZEN-README` honnête (« ne PAS remettre dans monks/ »). | rien de cassé ; nettoyer avec F-C157 si archive monks |
>
> **Synthèse** : 7 archivables (dormant/gelé/test-only : 144/145/146/147/152/157 + racine 156/133) · 2 gates/fixtures morts (139/140) · **2 divergences de direction à trancher (138 live D6, 159 schéma-vs-runtime D7-twin)**. Rien ne bouge sans ta ligne archive/keep/wire — mais la décision est maintenant à plat.

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

> **Inventaire F-C167 (fait, data concrète — le fork est réduit)** :
> - **Le gate est ENCORE PLUS creux que le préview ne disait** : `check_app()` est **défini mais JAMAIS
>   appelé** (le bloc `mcp` l.33-36 n'est qu'un commentaire). `FAIL` reste 0 → `exit 0` inconditionnel,
>   AUCUN `grep` exécuté. (Ma note préview « le gate A un check qui tourne » était fausse — corrigée.)
> - **Les 7 refs `05_data-canon` sont TOUTES des mentions historiques/provenance, ZÉRO dépendance vivante** :
>   permanent_boot.ex:199 (commentaire-rationale du mismatch évité, EXACT), permanent_boot_test.exs:280
>   (« Plus de path 05_data-canon »), events_schema_test.exs:7 (« @canon_path **pointait** », historique),
>   coord_policies_schema_test.exs:8 (« Repath fix »), intensity-v1.json:5 + coord-policies-v1.json:5
>   (`description` schéma, provenance ; coord dit déjà « ancien chemin doctrine, repath post-bascule »).
>   **Aucun `@canon_path` vivant hors-repo, aucun READ cassé** — l'invariant fonctionnel est DÉJÀ satisfait.
> - **1 seul ref misleading-indépendamment-du-fork → DÉJÀ FIXÉ** : modops:62 (message d'échec nommait
>   `05_data-canon/cap-profiles/` alors que le path testé est `@cap_profiles` in-repo) → imprime `cp_path`.
>
> → **Fork réduit** : puisqu'il n'y a AUCUNE dépendance vivante, « câbler le grep-gate » ferait des
> FAUX POSITIFS sur les commentaires historiques EXACTS (« Plus de path 05_data-canon » tripperait le grep).
> **Ma reco affinée : SUPPRIMER le scaffold** (`test/gate-r0.8-canon.sh` — hollow + grep trop naïf pour
> distinguer dep-vivante d'une note historique) ; garder les 6 mentions (doc de migration valable). Si tu
> tiens à un garde, il doit chercher un `@canon_path`/`File.read` vivant vers `05_data-canon`, pas la string
> nue. **Action = ton call** (supprimer un gate CI = direction outillage).

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

### D1 RÉSOLU (2 workers, 12 rails classés) — 0 FAIL-LOUD
Résultat honnête : **le code applique DÉJÀ ta doctrine** — chaque event LIVE double son event lossy d'un jumeau DURABLE. Aucun rail n'est event-only avec conséquence vivante.
- **9 BEST-EFFORT-OK** (lossy-assumé + backstop réel) : F-C019/046 (TaskQueue persisté + `Reconciliation` reclaim→re-dispatch ; le faux-succès était DÉJÀ fermé en `{:error,:broadcast_failed}`), F-C058 (`stage/*` = human-only, PAS la state-machine ; workflow PR-driven), F-C101 (rail Logger = sa propre surface `:degraded`), F-C102 (boot events = observabilité ; fait durable via spawner+`PermanentWarden`), F-C051 (Cat-5 draft = accélérateur sur `freeze_to_arch` forge), F-C091 (`coord.*` = dashboard ; `escalate_human` dormant), F-C093 (prod câble `Fleet.Coord` + Readiness `:degraded`), F-C103 (poll `mcp.pod_facing` live-state).
- **3 DOWNGRADE** : F-C089 (empty-registry test-only, prod `Catalog.load!` avant Bus), F-C095 (rails dormants + producteurs live=payloads valides), F-C105 (Shutdown INERT + prod câble `AggregateDispatcher`).
- **0 code-fix fail-loud.** Mon estimation « ~4-5 » était fausse.

**LE VRAI livrable D1 = un FORWARD-GUARD (ta décision, 1 ligne)** : *tout futur rail `escalate_human` câblé SANS jumeau forge durable (livraison = uniquement l'event lossy) DOIT fail-loud (propager l'échec broadcast OU ancrer un fait forge avant `:ok`).* Aujourd'hui aucun rail ne le viole. C'est une règle de design à graver, pas un fix.

**Résidus doc (je nettoie, PERCE-doc-like)** : F-C046 (`work_items.ex:57-60` sur-affirme « re-submit → re-emit » ; en vrai recovery = poller reconciliation), F-C051 (`cat5_escalator.ex:22-26` dit « no producer » alors que `step_run_consumer:453/717` en a un live → aligner sur `drift_monitor.ex`), F-C102 (`@spec run/1 :: :ok` = « orchestrateur exécuté » ≠ « boot réussi », clarté).
**Optionnel R-08 défensif (ta décision)** : F-C089 prod fail-closed, F-C093/F-C105 forward-guards de dé-câblage — rien de cassé aujourd'hui.

### D4 RÉSOLU (worker vérif + moi) — 1 FIX + 3 R-08-défensifs
Grep config cardinal (R-08) : aucune des 4 clés n'est posée MALFORMÉE par un config réel.
- **F-C041 `launch_backend` = FIX-ENVPARSE** (le seul) : knob ACTIVEMENT configuré (test.exs) + dispatch dynamique SANS garde → un module typo lève `UndefinedFunctionError` qui **crashe le gen_statem SANS transition_failed** (orphelin), ET la sonde Readiness le classe `:operational` (**hollow-green**). Jumeau bâti+testé : `McpProvision.conforming_provisioner`. → garde `resolved_conforming/0` (Code.ensure_loaded + function_exported?(:launch,2)) pliée sur transition_failed AU SEAM (pas `resolved/0`, R-10) + Readiness `:degraded`.
- **F-C034 `:claude_dir`** = R-08-DÉFENSIF (test-only, single-human, ≈downgrade) → ta décision.
- **F-C036 `mcp_server_spec`** = R-08-DÉFENSIF (config = map littérale figée bien-formée ; malformé = édition-main) → ta décision.
- **F-C056 roles accessors** = R-08-DÉFENSIF (defaults sûrs + reviewer_roles valide ; malformé = opts-test ; aval fail-closed rattrape) → ta décision.
→ Je fixe F-C041 (atteignable + jumeau). Les 3 défensifs : « durcir en parse-au-bord OU laisser » = ton call require-vs-soft (rien de cassé aujourd'hui).

### D5 RÉSOLU (2 workers, 11 tolérances) — 0 FIX MÉCANIQUE
Test « masque un load-bearing SANS backstop ? » → **toutes légitimes** (documentées + LOUD + backstoppées) sauf 2 résidus réels dont le fix est un design-fork.
- **KEEP-DOCUMENTED (7)** : F-C001 (over-strict fail-closed, masque rien), F-C016 (LOUD + git rc≠0 aval), F-C033 (warning + QA-gated aval), F-C045 (recall REFUSE, ≠ F-C043 qui procède), F-C048 (transitoire + re-poll + propriété primaire vérifiée, ≠ F-C041), F-C080 (re-wake=autorité), F-C081 (malformé inatteignable, forge garantit owner/name + mono-org).
- **DOWNGRADE (1)** : F-C021 (prod `persist:false` → `from_map` jamais appelé ; divergence du jumeau F-C037 qui était atteignable en ops live). Mon phase-0 « atteignable via recovery » était faux.
- **2 RÉSIDUS RÉELS → TA DÉCISION (design-fork, la forme naïve régresse)** :
  - **F-C050 (le plus dur, high)** : un `:completed` de pipe-projet + crash de l'offload mid-publication (Task `:temporary`) + N = DERNIÈRE issue → lock `lcars-in-flight` **orphelin PERMANENT, silencieux** (la reconciliation compte `:completed` comme owning → jamais reclaim). Fix correct = **state-split durable `active|publishing|published`**, **JAMAIS** exclure `:completed` (ça régresse la fenêtre de publication normale = churn). Le seul du lot avec perte durable possible.
  - **F-C083 (high)** : `build_judge_brief` sur read-error forge → `request: nil` → judge sans CRITÈRE mais avec le diff → risque d'approbation criterion-less (faux GREEN), backstop LLM soft non-garanti. Fix = retour de dispatch typé par brief_kind (read-error ≠ absence), pas un fallback silencieux.
→ Ma reco : garder les 8, et pour F-C050/F-C083 = **oui à resserrer** mais via le design correct (state-split / typed-per-kind), pas la forme naïve. C'est ton call require-vs-effort.

### D2 RÉSOLU (2 workers + moi) — 1 FIXÉ + 1 fix additif + 1 décision publique
- **F-C125 FIXÉ** ✅ : deck role-table surface le catalogue-error (échec avalé) au lieu de mentir « aucun rôle ». Purement mécanique (re-propager le fail-loud que CapProfile.list produit déjà).
- **F-C124 (à fixer, additif)** : `/api/projection` renvoie empty-200 quand le read-model est down/deaf (indistinct d'une fleet calme). Fix additif = champ `status: live|unavailable|deaf` + `subscribed?` (le DOWN log déjà LOUD, on le surface). Dans mon autorité, je le fais.
- **F-C118 (→ TA décision)** : `/api/pods|issues|workflow_runs` = stubs empty-200 sur surface PUBLIQUE. 200→501 = **changement de contrat public** → câbler (chantier) vs 501-explicit vs supprimer les stubs orphelins. Ma reco : 501 (honnête) ou supprimer (aucun consommateur in-repo).
- **KEEP-DOCUMENTED (4)** : F-C038 (state.json LOUD+forge-backstop), F-C042 (pod mort→reconciliation réclame), F-C126 (policy Memory-X user-validée documentée), F-C135 (bwrap SANCTUAIRE — fix=N0/provisioning, déféré décision user datée).
- **DOWNGRADE (2)** : F-C120 (buildinfo cosmétique non-atteignable), F-C136 (iron-law enforced en amont via :projecting/McpProvision).
