# JOURNAL — remédiation SSOT/irrepr (chronologique)

**Date** : 2026-07-10
**Dernière révision** : 2026-07-11
**Statut** : actif
**Référencé par** : `CARNET-DE-BORD.md`

## 2026-07-10

### Montage (phase 0 amorcée)
- Worktree `remediation-ssot` créé off `main` (1f53f030b) dans `/home/lordzurp/wt-remediation`. Commit-local.
- Source Codex copiée dans `source-codex/` (findings-campaign + frontiers + final-report + coverage) — self-contained pour la reprise.
- Ledger `LEDGER.csv` généré : **167 findings** (36 high / 79 medium / 37 low / 15 hygiene), tous `PENDING`.
- Docs de campagne posés : `PLAYBOOK` (mon protocole), `CARNET-DE-BORD` (ancre reprise), `PLAN` (canard), ce journal, `META-DEBRIEF`.
- Lecture de l'`amorce` (beyond_#5.1) : construire mon protocole depuis les graines, pas dérouler une spec. Fait.
- **Aucun code touché** (règle cardinale : rien avant vérif percé).

### Phase 0 — verify-sweep LANCÉ
- Crons armés : watchdog `a73c2099` (`3-59/10 * * * *`), relevé `b1dc7bc3` (`47 * * * *`). Session-only → à supprimer en fin.
- **8 workers Explore** lancés en fan-out (F-C001→167, ~21 chacun) : vérif adversariale contre le code réel du worktree, verdict PERCE/THEORIQUE/DEJA-FIXE/DOCTRINE + citations + vrai chemin de données.
- Attente : consolidation des verdicts dans `LEDGER.csv` dès retour des workers, puis spot-vérif moi-même des PERCE à fort enjeu, puis regroupement B5 en familles de constructeurs.

### Phase 0 CLOSE — 167/167 vérifiés
- 8 workers rentrés. Verdicts capturés par lot dans `verdicts/lot-*.md` (durable), consolidés dans `LEDGER.csv` + `CONSOLIDATION.md`.
- **Distribution** : 71 DOCTRINE (42,5 %) · 49 PERCE-code · 25 PERCE-doc · 21 THEORIQUE · 1 DEJA-FIXE.
- **Gain règle cardinale** : 21 THEORIQUE dissous (schéma verrouille déjà à l'entrée / producteur passe valide / prose non-assemblée) → 21 non-brèches non-fixées. Plusieurs localisations corrigées (vrai verrou un niveau au-dessus).
- **PERCE code → 6 familles** : F gates(5) · C ingress-parse(10) · B config-parse(6) · D identité(4) · E schéma(2) · A fail-closed(22). Le « constructeur » (B/C/D/E ~22) = ~5-6 smart-ctors ; A ~22 edits fail-closed (pattern intégrité prouvé).
- **DOCTRINE → 7 clusters** (D1 fiabilité-events · D2 stubs-MVP · D3 canon-legacy · D4 config-boot · D5 tolérances · D6 SSOT-cross-surface · D7 outillage) — checkpoint user.
- **Aucun code touché.** → attente GO phase 1 + steer triage doctrine.

### Phase 1 — hollow-gates (en cours)
- **F-C166 FIXÉ** (`2d6cee826`) : gate-r0.1-bwrap sentinelle host déterministe → fin du faux-vert ISO. bash -n OK (gate complet non-runnable ici : bwrap/vendor absents).
- **F-C167 → doctrine-tail (flag user, D7)** : re-vérif → `05_data-canon` encore référencé dans 5 tests → le gate câblé ÉCHOUERAIT. Fix = re-câbler / supprimer le scaffold / marquer = choix de design sur un gate CI. Non touché.
- **F-C165 → doctrine-tail (flag user, D6)** : la bonne liste = rôles `needs_role_token`, pas swap vulcan→starfleet. Non touché.
- **F-C164** : à re-vérifier (install.sh copie-list) — probablement propre. **F-C160** : couverture test brief-gate (Elixir) — avec les tests.
- Règles R-06/R-07 ajoutées au méta-débrief (re-vérif = 2 mis-fixes évités ; hollow-green masque un vrai rouge).

### Phase 1 — F-C164 reclassé FAUX (verify-the-verifier)
- **F-C164 → THEORIQUE** : `bin/claude_launch.identity` = constante vendor COMMITTÉE (NAME/EMAIL, trackée), pas un secret à générer. `install.sh` clone tout le repo → présente ; `publish-to-github.sh` la résout relativement (`etc/../bin`). Citation Codex `install.sh:50 copie sélective` factuellement fausse (install.sh ne copie rien, il clone+délègue). Aucune brèche → PAS de fix.
- **Bilan phase 1** : 5 « hollow-gates clairs » → 1 fix propre (F-C166), 2 doctrine-tails (F-C167 D7, F-C165 D6), 1 FAUX (F-C164), 1 restant (F-C160 couverture test brief-gate). La règle cardinale a évité 1 mis-fix + 2 fix-mal-formés sur 4.
- Distribution ledger : PERCE 48, THEORIQUE 22 (F-C164 migré).

### Phase 1 CLOSE
- **F-C160 FIXÉ** (couverture brief-gate, 12 tests/0). brief_kind:judge survit à la normalisation (bonus : confirme F-C109 = MAP-level seulement).
- **Bilan phase 1 (5 findings)** : 2 FIXÉS (F-C166 sentinelle bwrap, F-C160 conformance brief-gate) · 2 DOCTRINE-TAIL (F-C167→D7, F-C165→D6) · 1 FAUX (F-C164). La règle cardinale a évité 3 fixes erronés sur 5 (2 mal-formés + 1 non-brèche).
- → PHASE 2 : constructeurs de frontière (B/C/D/E). Je commence par re-vérifier une famille + concevoir le smart-ctor.

---
## RELEVÉ DE POSTE #1 — 2026-07-10 (~22:47)

**Phase** : 2 — constructeurs de frontière (B5), tout juste entamée.
**Compteurs** : 167/167 vérifiés · PERCE 48 · PERCE-doc 25 · DOCTRINE 71 · THEORIQUE 22 · DEJA-FIXE 1 · **fixés : 2** (F-C166, F-C160) · **constructeurs posés : 0**.
**Bougé cette heure** :
- Montage complet (worktree, 6 docs, ledger, 2 crons, build-env vert).
- Phase 0 : 8 workers → 167/167 vérifiés, consolidés (LEDGER + CONSOLIDATION + verdicts/lot-*.md).
- Phase 1 CLOSE : F-C166 + F-C160 fixés ; F-C167→D7, F-C165→D6 (doctrine-tails) ; F-C164 faux/reclassé.
**Dérive attrapée** : aucune dérive de MA part. Mais la vérif a évité **3 actions erronées / 5** en phase 1 (règles R-06/R-07 déjà posées ; F-C164 = énième « rapport mal-localisé », couvert par R-01). Discipline tenue.
**Décision(s) en attente user** : les **7 clusters DOCTRINE D1-D7** (71 findings) — dont **F-C167 (D7)** et **F-C165 (D6)** remontés de la phase 1. Non-bloquant pour phases 1-2-4 (code clair) ; bloquant pour phase 3 + une part de 4.

### Phase 2 — F-C097 (1er constructeur)
- **F-C097 FIXÉ** : `Fleet.Starfleet.Application.boot_enabled?/2` — booléen strict fail-loud, route les 6 knobs `:start_*`. Test dédié 3/0 + suite starfleet 67/0.
- 1 constructeur posé, 1 finding tué. Pattern éprouvé (verrou amont config-boot). Prochain : la famille config-int (F-C099/104/117/082) — voir si un helper `Fleet.EnvParse` partagé consolide, ou site-par-site.

### Phase 2 — re-scoping famille config-int (verify-the-verifier)
- F-C099/104/117/082 : clés config JAMAIS posées (runtime/config/test) → défaut hardcodé toujours utilisé → malformé non-atteignable → **reclassés DOCTRINE (D4)**. Pas de fix unilatéral (règle R-08).
- F-C097 gardé (knobs activement configurés + doctrine EnvParse établie). La famille B « config-parse » s'effondre : 1 fix légitime (F-C097), le reste → D4 user.
- → Phase 2 se recentre sur les familles DATA-FLOW (C ingress-parse, D identité, E schéma) = vraies brèches atteignables par données réelles (webhook/forge/champ-schéma-ouvert).
- Distribution : PERCE 44, DOCTRINE 75.

### F-C060 — verify-the-verifier : churn non-matérialisée → THEORIQUE
- Tracé : seal_and_merge FERME l'issue (l.43/80/84) ; poller dispatch seulement issues ouvertes → pas de re-dispatch ; Réconciliation réclame les orphan-locks (producteur killé). La brèche décrite (churn load-bearing) ne survient pas. Résidu = label cosmétique sur issue fermée + log imprécis → pas de fix (harness disproportionné). R-09 posée.
- PATTERN de campagne confirmé (3 cas de suite : F-C010 doctrine-tail, config-int non-atteignable, F-C060 conséquence-nulle) → je délègue la re-vérif des PERCE restants avec la discipline consequence-check.

### PASS-2 consolidé — 4 workers re-vérif consequence-check (35 PERCE)
- Résultat : **9 CLEAN-FIX · 18 DOWNGRADE→THEORIQUE · 7 DOCTRINE · 1 RESIDUAL(→theo, F-C062)**. Détail cité dans `CONSOLIDATION-PASS2.md`.
- Distribution finale : 85 DOCTRINE · 41 THEORIQUE · 25 PERCE-doc · 15 PERCE (4 FIXÉ) · 1 DEJA-FIXE.
- **F-C098 FIXÉ** (1er CLEAN-FIX du pass-2) : AuditLog.write rescue encode → contrat no-crash honoré. Vérifié moi-même : le fix worker (`Jason.encode` non-bang) aurait été INCOMPLET (protocol-undefined lève aussi) → `rescue` requis. RED=Protocol.UndefinedError, GREEN, starfleet 68+1/0.
- Bookkeeping corrigé : F-C097/160/166 marqués FIXÉ ; F-C165/167 → DOCTRINE (D6/D7).
- **Oubli assumé** : F-C075/F-C076 jamais assignés à un lot → à re-vérifier moi-même avant tout fix.
- Motif méta : l'intégrité a déjà posé les logs LOUD ; le substrat durable (forge-sync/re-wake/poller-rescan/scoped-label-mutex) neutralise le faux-succès ; les vrais CLEAN-FIX sont des FINITIONS de verrous à moitié posés (jumeau existant). F-C059 = le plus sérieux (retour ment + kill destructif).
- Prochain : F-C059 (verify-moi + TDD).

### F-C059 FIXÉ — safe_pod_info raise → :unknown → pipe DEFER (le plus sérieux du pass-2)
- Vérifié moi-même : asymétrie réelle documentée (pod_alive? assume-ALIVE vs safe_pod_info :error→:dead→spawn destructif). Fix = variante `:unknown → :busy` (defer), miroir pod_alive?, implémente le TODO l.355 du code.
- RED = spawn frais destructif d'un pipe vivant ; GREEN. fleet_pilot 358+2+1/0.
- **Couche-2 flaggée DOCTRINE** : `pod_info` conflate absent vs timeout-vivant (tous deux `{:error,:not_found}`) → un pipe vivant-mais-lent peut encore être classé :dead. Non fixable au niveau safe_pod_info (un pod vraiment mort resterait :busy = wedge) → exige un split de contrat pod_info côté spawner = décision design (ajouté DECISION-BRIEF).
- Prochain : F-C069 (jury 2xx corrompu → merge/half-jury).

### F-C069 FIXÉ — reviews 2xx non-liste → fail-loud (jumeau paginate)
- Vérifié moi-même : 3 clauses `{:ok, _non_list} -> {:ok, vide}` contredisaient le jumeau paginate (fail-loud :unexpected_page_shape, commentaire explicite l.211-213). Callers vérifiés (pas de CaseClauseError) : pr_review_state wrap {:error}, count escalate_rework, feedback "". Conséquence confirmée : merge sur jury vide + budget sous-compté.
- Fix = `{:error, {:unexpected_review_shape, path, non_list}}`. RED×3 (ok/0/[]/%{vide}), GREEN. fleet_pilot 361+2+1/0.
- Enchaîne (homme-mort ≠ cadence) → F-C119.

### F-C119 FIXÉ — admission issue_id is_binary (miroir pod_id) + clause handler
- Vérifié moi-même : issue_id optionnel pris cru vs pod_id strictement gardé (même module). Pas path-bound (path=pod_id). Conséquence modeste (mis-corrélation/control-bytes logs) mais trou de typage à un ingress no-auth.
- RED a attrapé un CaseClauseError : do_admin_spawn (rest.ex) sans catch-all → nouvelle forme {:invalid_issue_id} non gérée → 500. Ajouté la clause 422. (Leçon intégrité : nouvelle forme de retour = vérifier TOUS les callers.)
- fleet_api 74/0. Enchaîne → F-C018.

### F-C018 FIXÉ — strip_control(role) sink-side (R1-14, miroir champs humains)
- Vérifié moi-même : role brut dans coauthor_trailer(l.133)+role_email(l.177) vs champs humains strip_control (l.222/229). launch_env met GIT_* depuis l'humain (pas role brut) → seul sink de role = trailer/email. RoleIdentity (jumeau) n'a pas ce pattern.
- Choix sink-side strip_control (vs schéma-pattern) : plus sûr (19 profils, 2 modules) + mirror exact de la défense R1-14 du module + source-agnostique. RED→GREEN, 48+2/0.
- Enchaîne → F-C044.

### F-C044 FIXÉ — emit spawn.failed sur les {:error} ordinaires
- Vérifié moi-même : 3 branches log-warn-seul, jumeau emit_spawn_failed n'était appelé qu'au rescue. read_model consomme tout %Fleet.Event → spawn.failed alimente la vue admin. Fix = emit dans spawn-fail + load-fail. name-missing = edge quasi-mort (admission F-C119 garantit le name) → laissé.
- RED×2, GREEN, fleet_spawner 215/0. Enchaîne → F-C035/F-C037 (finitions brief_slot 3-state).

---
## RELEVÉ DE POSTE — 2026-07-10 ~23h
- **Phase** : 2/4 — shortlist CLEAN-FIX (pass-2 consolidé).
- **Compteurs** : 167/167 vérifiés (1er+2e passage) · PERCE 15 (9 FIXÉ + 6 ouverts) · DOCTRINE 85 · THEORIQUE 41 · PERCE-doc 25 · DEJA-FIXE 1. Verrous posés : 9.
- **Bougé cette heure** : 5 CLEAN-FIX livrés en continu (F-C059 pipe-DEFER, F-C069 reviews fail-loud, F-C119 admission issue_id, F-C018 strip_control(role), F-C044 emit spawn.failed). Chacun verify-moi + TDD + non-régression suite complète + commit.
- **Dérive attrapée** : (1) j'avais traité le watchdog comme un CADENCEUR (« 1 fix puis j'attends le tick ») — le user a corrigé : c'est un HOMME-MORT (réveil si bloqué), on bosse en continu → mémoire posée [[watchdog-is-deadman-not-pacer]] + je ne finis plus un tour par « j'attends ». (2) F-C119 : une nouvelle forme de retour `{:invalid_issue_id}` a percuté `do_admin_spawn` sans catch-all → CaseClauseError → règle R-10.
- **Décision en attente user** : 85 findings DOCTRINE (`DECISION-BRIEF.md`, 7 clusters + 7 ajouts pass-2 + F-C059-b contrat pod_info). Non-bloquant pour la shortlist en cours.

### F-C035 FIXÉ — brief slot :unknown → fail-closed (plus de pod idle)
- Vérifié moi-même : :unknown → :ok laissait un pod admin.spawn idle sans brief (seul enqueue, pas de réconciliation). Fail-closed {:error} → with :projecting échoue avant launch → retry. R-10 appliqué : else du with générique ({:error,reason}→transition_failed) → safe.
- Couture enqueue_by_slot/3 extraite (test :unknown sans TaskQueue down). TDD 2-phases RED→GREEN, fleet_spawner 217/0.
- Prochain : F-C037 (JUMEAU — result_deadline 3-state ; touche le gen_statem pod.ex, à faire à tête reposée).

### F-C037 FIXÉ — :result_deadline 3-state (:unknown broker → re-arm)
- Vérifié moi-même : le no-kill sur :error est délibéré+correct, mais le LAPSE (consommer le deadline) orphelinait un pod hung dont le broker blip au fire. Fix distinct : garder no-kill, transformer lapse→re-arm. active_task_state/1 (3-state) + couture result_deadline_fire/2 (testable, gen_statem). pod_has_active_task? gardé pour le champ pod_info (l.428).
- TDD 2-phases RED→GREEN, fleet_spawner 219/0. Enchaîne → F-C086 (faible enjeu).

### F-C086 FIXÉ — scaffold mkdir_p! → typed (honore le @spec)
- Vérifié moi-même : 3 mkdir_p! bang violaient le @spec {:scaffold_write}. R-10 : onboard/2 with SANS else → aujourd'hui le raise crashe, après fix {:error} retourné ; onboard @spec = {:error,term()} + retourne déjà des {:error} variés → safe. Nouveau test scaffold_test (aucun n'existait). RED (File.Error)→GREEN, fleet_pilot 364/0.
- Enchaîne → F-C031 (plugin slug, dernier CLEAN-FIX worker) puis re-vérif F-C075/076.

### F-C031 → DOWNGRADE (THEORIQUE) — protocole plugin whitespace non-exercé
- Verify-the-verifier : ZÉRO skill plugin-qualifié dans le canon (6/7 `skills: []`, architect = 3 skills simples sans `:`). skills_plugins_env retourne `%{}` partout → le protocole whitespace-lossy n'est exercé par AUCUN config réel (R-08). Le danger sécu (traversal/mount) est déjà rattrapé par l'allowlist bwrap (bwrap_launch.sh:204-207). Résidu = fidélité pure sur un chemin inexistant. Fix fail-loud propre = changement de contrat de skills_plugins_env (map→result) disproportionné. → défensif-si-adopté, pas percé-aujourd'hui. Cohérent avec le re-scope config-int.

### F-C075 + F-C076 → DOCTRINE (consequence-check moi-même, les 2 oubliés de délégation)
- F-C075 : escalade a lieu (issue créée+assignée+Logger.error LOUD sur échec-label). Propager {:error} → risque DOUBLONS (issue existe). {:ok,number} correct, résidu surfacé. Fork : assignee+log suffisant vs label-load-bearing+dédup → DOCTRINE (D1).
- F-C076 : retry-sans-assignee sur toute erreur = documenté « escalation precedence over naming » (l.14-15/84). Le fix classify+propager-transitoire réduirait la fiabilité d'escalade (plus d'issue sur transitoire) = tradeoff design → DOCTRINE (D1). Consequence narrow (transitoire-qui-clear) + mitigée (label-findable).
- **SHORTLIST CLEAN-FIX COMPLÈTE** : 12 fixés, les 2 derniers PERCE → doctrine. Plus aucun PERCE ouvert.

### Vérif milestone — gate complet vert & déterministe (12 fixes)
- `mix compile --warnings-as-errors` a attrapé 2 warnings clause-grouping (F-C037 result_deadline_fire/2, F-C119 validate_issue_id/1 inséraient une fonction au milieu d'un groupe de clauses) → déplacées, comportement inchangé. LEÇON : lancer --warnings-as-errors après chaque ajout de def public entre des clauses groupées.
- `mix test` complet a révélé 1 flaky (arch_escalation_test refute log =~ "NOT added" — chaîne partagée avec IncidentRegistry.Escalation, bleed async capture_log). PAS ma régression (passe isolé). Durci sur token arch-unique "ArchEscalation:". → gate déterministe.
- Résultat : umbrella 0 échec (fleet_pilot 364, fleet_spawner 219, fleet_api 74, fleet_credentials 48, fleet_starfleet 68 + doctests/properties), compile clean.

---
## RELEVÉ DE POSTE — 2026-07-11 ~00h10
- **Phase** : 5 — batch PERCE-doc (3 workers vérif en vol).
- **Compteurs** : 167/167 vérifiés · PERCE 12 (**TOUS FIXÉS**) · DOCTRINE 87 · THEORIQUE 42 · PERCE-doc 25 (en vérif) · DEJA-FIXE 1. Verrous posés : 7 (+ R-01→R-12).
- **Bougé cette heure** : F-C037 + F-C086 fixés (TDD) → **JALON code-fix TERMINÉ (12 fixés, 0 PERCE ouvert)**. F-C031→theo (plugin non-exercé), F-C075/076→doctrine (escalade a lieu, fix=fork). Gate complet VERT & DÉTERMINISTE (0 échec umbrella, --warnings-as-errors clean). Phase 5 lancée (3 workers).
- **Dérive attrapée** : (1) 2 warnings clause-grouping (--warnings-as-errors) introduits par F-C037/F-C119 → R-11. (2) 1 flaky async capture_log bleed (arch_escalation, chaîne partagée avec IncidentRegistry) → R-12. Les DEUX attrapés seulement au gate COMPLET (compile-force + mix test umbrella), pas aux runs app-par-app.
- **Décision en attente user** : 87 DOCTRINE (`DECISION-BRIEF.md`, 7 clusters + ajouts) = le GROS du reste. Non-bloquant pour phase 5.
