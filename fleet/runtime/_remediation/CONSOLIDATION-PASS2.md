# CONSOLIDATION PASS-2 — re-vérif consequence-check des PERCE (R-09)

**Date** : 2026-07-10
**Dernière révision** : 2026-07-10
**Statut** : 35 PERCE re-vérifiés par 4 workers délégués (read-only, cités) + verify-moi sur F-C098
**Référencé par** : `CARNET-DE-BORD.md`, `LEDGER.csv`, `PLAN.md`

> 2e passage PLUS STRICT que phase 0 : chaque PERCE re-tracé jusqu'au **mauvais résultat observable**
> (R-09), et son fix jugé **mécanique vs doctrine** (R-06). Motif dominant : le faux-succès ne cache
> **pas** de perte durable — un chemin parallèle rattrape, ou le site n'a pas de caller vivant, ou la
> valeur est déjà valide en amont, ou le fix est un fork de contrat.

## Résultat : 35 PERCE re-vérifiés → 9 CLEAN-FIX · 18 DOWNGRADE · 7 DOCTRINE · 1 RESIDUAL(→theo)

| Finding | Verdict pass-2 | Raison tracée (citée) | Jumeau mécanique |
|---|---|---|---|
| **F-C098** | **CLEAN-FIX ✅ FIXÉ** | `Jason.encode!` viole le contrat no-crash du module (Cat-5) | `File.write` non-bang (in-fn) |
| **F-C069** | **CLEAN-FIX** | 2xx corrompu non-liste → merge/half-jury (`step_dispatcher.ex:337-342`) | `paginate` `{:unexpected_page_shape}` |
| **F-C119** | **CLEAN-FIX** | issue_id non-binaire admis à `POST /api/admin/spawn` no-auth | pod_id `is_binary` (`spawn_admission.ex:135`) |
| **F-C018** | **CLEAN-FIX** | `metadata.name` sans pattern → rôle brut dans trailer/email git | `strip_control`/`Fleet.Slug` (champs humains) |
| **F-C059** | **CLEAN-FIX** | `pod_info` raise/timeout → `:dead` → **kill destructif** d'un pipe vivant | `pod_alive?` « assume ALIVE » (`spawn.ex:251`) |
| **F-C035** | **CLEAN-FIX** | broker `:unknown` → brief admin.spawn droppé (seul enqueue) | `brief_slot` 3-state + branche `:free` |
| **F-C037** | **CLEAN-FIX** | hiccup TaskQueue consomme `:result_deadline` (seul watchdog des briefs sans deadline) | `brief_slot` 3-state + `rearm_deadline` |
| **F-C044** | **CLEAN-FIX** | `spawn.failed` non-émis sur `{:error}` load/spawn (202 muet) | `emit_spawn_failed` + read_model |
| **F-C086** | **CLEAN-FIX** (faible) | `mkdir_p!` viole le @spec typé `{:scaffold_write}` | `File.write` non-bang (in-fn) |
| **F-C031** | **CLEAN-FIX** (basse prio) | protocole whitespace lossy plugin (danger rattrapé par allowlist bwrap) | `Fleet.Slug` (skills plain) |
| F-C022 | DOWNGRADE | `stable_sha256` **zéro consommateur** (affichage seul) | — |
| F-C027 | DOWNGRADE | slug droppé → `feature/work` **local** ; push = `lcars/issue-N-role` | — |
| F-C028 | DOWNGRADE | `base_sha` hors-schéma, `project_resolver` pin toujours | — |
| F-C029 | DOWNGRADE | `work_branch` **sans producteur prod** (dormant) + fail-loud typé | GitRef si parité voulue |
| F-C055 | DOWNGRADE | fleet **mono-org** → slug injectif (collision cross-owner inexistante) | — |
| F-C068 | DOWNGRADE | mid-route half-state **inatteignable** (mutex scoped-label Gitea) + ré-onboard idempotent | — |
| F-C073 | DOWNGRADE | durabilité par **sync forge** (WAL redondant), déjà LOUD | — |
| F-C074 | DOWNGRADE | read-KO → `put_file` sha-nil échoue safe + LOUD + retry | parité `read_wal` si voulu |
| F-C079 | DOWNGRADE | ancre manquée bornée 1 cycle + LOUD, registre-down only ; `:ok` honnête pour le wake | — |
| F-C092 | DOWNGRADE | 0 consommateur (`events.yaml` « INTENDED ASYMMETRY ») | — |
| F-C100 | DOWNGRADE | `events_count` **jamais lu** (état mort) | — |
| F-C106 | DOWNGRADE | Shutdown **inerte** (0 caller) ; à co-designer avec le futur trigger | — |
| F-C107 | DOWNGRADE | inerte + misconfig-future (R-08) ; readiness sonde le dispatcher | — |
| F-C113 | DOWNGRADE | `kill_holder` `@spec :: :ok` (jamais `{:error}`) + re-wake = autorité | jumeau F-C080 |
| F-C114 | DOWNGRADE | sites fautifs (payload / `Git.publish`) **sans caller vivant** ; git_native déjà typé | — |
| F-C115 | DOWNGRADE | branche déjà **system-owned** amont + rejets protégés exclus | fork si durci |
| F-C116 | DOWNGRADE | seul caller git_native **signe déjà** (`step_run_build.ex:187`) | verrou cheap optionnel |
| F-C062 | RESIDUAL→theo | log déjà LOUD ; poller re-scan **auto-guérit** (propager ≠ heal) | — |
| **F-C043** | **DOCTRINE** | corruption artefact commité (R-08) ; fork fail-closed vs degrade | jumeau F-C045 (déjà doctrine) |
| **F-C047** | **DOCTRINE** | `delivered` = fermeture≠merge ; fix = capacité forge merge-proof / contrat champ | — |
| **F-C053** | **DOCTRINE** | misconfig (R-08) ; fix = contrat `deliverable_mode_fun` threadé ; pire cas rattrapé `:no_producer_branch` | — |
| **F-C066** | **DOCTRINE** | close-KO déjà LOUD + garde `stage/merged` ; propager **casse** `StepRunCompleter.promote` (CaseClauseError) + policy unlock | — |
| **F-C084** | **DOCTRINE** | clobber = mésusage `create_project` vs `import` ; change l'idempotence documentée | `import/2` |
| **F-C141** | **DOCTRINE** | `allowedTools` : fail-loud-déjà (jq exit 1) + fix schéma-requis vs invariant | `disallowedTools` (invariant) |
| **F-C161** | **DOCTRINE** | schéma exige `reason`, runtime non ; fork durcir-vs-relâcher | jumeau F-C167 |

## Ce que le pass-2 apprend (méta)

- **La campagne intégrité a déjà posé les logs LOUD** partout dans la famille fail-closed → il ne reste
  souvent qu'un **contrat de retour** imprécis, dont la propagation n'est jamais gratuite (CaseClauseError
  F-C066 ; 3e état sémantique F-C073/079 ; cosmétique car auto-heal F-C062).
- **Le substrat durable rattrape** : forge-sync (F-C073), re-wake liveness (F-C079/113), poller re-scan
  (F-C062), stage/merged guard (F-C066/068), Gitea scoped-label mutex (F-C068). C'est la doctrine maison
  (« Bus lossy, forge+poll durable ») qui neutralise le faux-succès en pratique.
- **Les vrais CLEAN-FIX sont des FINITIONS** de verrous à moitié posés : le jumeau existe déjà
  (`brief_slot` 3-state, `pod_alive?` fail-closed, `emit_spawn_failed`, `paginate`, `Fleet.Slug`, pod_id
  `is_binary`) → le fix = câbler la branche manquante, pas inventer.
- **F-C059 est le plus sérieux** : le retour ment ET pilote une action DESTRUCTIVE (kill d'un pipe vivant),
  non self-healing → priorité haute.

## Restes à traiter

- **9 CLEAN-FIX** worker-confirmés (verify-moi avant chaque fix) : F-C069, F-C119, F-C018, F-C059, F-C035,
  F-C037, F-C044, F-C086, F-C031. Ordre proposé par valeur : **F-C059** (destructif) → F-C069 (merge) →
  F-C119 (ingress no-auth) → F-C018 (injection identité) → F-C044/035/037 (observabilité spawn/admin) →
  F-C086/031 (faible enjeu).
- **F-C075, F-C076** : **oubli de délégation** (jamais assignés à un lot) → à re-vérifier consequence-check
  avant tout fix (Sysadmin escalation `{:escalated}` + assignee droppé).
- **7 nouveaux DOCTRINE** (F-C043/047/053/066/084/141/161) → ajoutés au `DECISION-BRIEF.md`.
