# Findings — Campagne Intégrité #2 (P2/P3/P5)

**Date** : 2026-07-09
**Dernière révision** : 2026-07-09
**Statut** : **CAMPAGNE CLOSE — B 9/9 ✅ · A 4/4 ✅ · D 3/3 ✅ · C/Q2 (Cat-5 draft) ✅ · P4 7/7 ✅**

## P4 — 7 Tier-2 muets (avalage silencieux d'un échec load-bearing, souvent + un log menteur) — ✅ 7/7

| # | Site | Fix | Commit |
|---|---|---|---|
| 7 | `incident_registry.ex` read_wal | WAL corrompu → amnésie cross-session ; `decode` avalait Jason en `%{}` (fix au mauvais endroit dans le rapport) → Jason.decode direct + log LOUD. **Test.** | `122a036fd` |
| 8 | `wake_recovery.ex` | `_ = note` + log « recorded » menteur → case + log LOUD si l'ancre pas posée. **Test.** | `122a036fd` |
| 6 | `poller/reconciliation.ex` | « reclaimed » AVANT l'écriture + remove_label non vérifié → « reclaiming » + log LOUD sur échec (vérifié-lecture) | `122a036fd` |
| 1 | `permanent_boot.ex` base_seed_uuid | `rescue → nil` confond base absente/corrompue (UUID session fixe perdu) → `File.exists?` + log LOUD | `ce5aa998b` |
| 4 | `spawner.ex` safe_clear_for_pod | repli fail-safe du kill sans trace (release load-bearing du mandat → boucle) → log LOUD rescue/catch | `ce5aa998b` |
| 5 | `brief.ex` + `task_probe.ex` | `no_pending_brief?` collapse erreur broker en `false` → brief droppé silencieux → sonde 3-états `brief_slot` + log LOUD :unknown | `ce5aa998b` |
| 2 | `mcp/supervisor.ex` | scan sockets `rescue → 0` = hollow green → log LOUD (check aveugle) | `42f2988c2` |
| 3 | `observation/read_model.ex` | ReadModel mort → `empty()` = flotte-calme → distingue table absente + log LOUD | `42f2988c2` |

Note : `escalation.ex:66` confirmé **déjà-fait** (B-#5). Orphelins d'events (spawn.failed 0-consumer, gitea.* 0-réacteur) = chantier séparé (hors Tier-2 muets).
**Référencé par** : `_plan-integrite-2.md`, `soft-defaults-audit.md`

## Avancement remédiation (triage user Q1 « Mensonges + 9 Tier-1 + tests-clés », Q2 « câbler producteurs Cat-5 draft »)

| Lot | Item | Commit | Test |
|---|---|---|---|
| B | #1 webhooks_gitea → 422 | `62a600925` | seam `webhook_emit_fun` |
| B | #2/#8/#9 spawn safe_wake/pod_alive/pod_info | `df8ce9b36` | — (rescue surface + fail-closed) |
| B | #4 gatekeeper_seal close raté (+ mensonge A-#2) | `416ee81a9` | `CloseFailForge` + worktree_test |
| B | #5 escalation label error_system (+ mensonge A-#1) | `d09cbd0f0` | — |
| B | #3 arch_escalation label awaits-arch | `a64ff67b1` | `arch_escalation_test` (LabelFailForge) |
| B | #6 state_fs rm_rf tombstone | `8542389dd` | `pod_test` rm_rf-eacces déterministe |
| B | #7 pod /clear REPL bleed | `6cafaa58d` | vérifié-par-lecture (PodTmux sans seam) |
| A | #1 (dans B-#5) / #2 (dans B-#4) | ✅ | corrigés avec leurs fixes B |
| A | #4 events.yaml git.* menteur → clés retirées | `691f9a92e` | `contracts.check` keys_aligned PASS |
| A | #3 drift_monitor « audit.verdict live » → dit vrai | `2ae205aec` | résolu par Q2 (producteur draft) |
| C/Q2 | producteurs Cat-5 draft (workflow_map.failed + audit.verdict) | `dbbf4870e`/`2ae205aec`/`7b0b6a096`/`4b8d77a91` | pilot 355 / starfleet 64 (anti-spoof) / coord 18 |

**B 9/9 ✅ · A 4/4 ✅ · D 3/3 ✅ · C/Q2 ✅ (ça clignote).** Reste **P4** (Tier-2 muets : permanent_boot, mcp hollow-green, observation LED, safe_clear_for_pod, task_probe, reconciliation).

## Le fil rouge des 3 passes : le MENSONGE

Comme le doc-EN (commentaires) et les soft-defaults (défauts), le pattern qui revient = **quelque chose prétend
couvrir/vivre/fail-loud alors que c'est mort**. Priorité : **fixer les mensonges d'abord, ils CACHENT le reste.**

### A. Les 4 mensonges (cheap, high-value — corriger la doc/registre pour dire la vérité)
1. `pilot/incident_registry/escalation.ex:66` — commentaire « add_label fail-loud » → FAUX (aucun log, juste un tuple).
2. `pilot/gatekeeper_seal.ex:102` — commentaire « a failed close invalidates nothing » → FAUX (close raté = brique re-dispatchée).
3. `starfleet/drift_monitor.ex:13` — « `audit.verdict` is the live path » → FAUX (0 producteur ; consumer câblé jusqu'au backend prod).
4. `event_router/priv/events.yaml` bloc `git.*` — « consumed by AuditConsumer » → FAUX (clause razée, `audit_consumer.ex:100`).

## B. P2 — 9 TIER-1 : avalage d'une garantie load-bearing → succès mensonger
1. `event_router/webhooks_gitea.ex:67` — `Bus.emit {:error}` jeté → ACK 200 sur webhook droppé.
2. `pilot/spawn.ex:222` — `safe_wake rescue→:ok` → wake raté = tally dispatched faux.
3. `pilot/arch_escalation.ex:146` — `add_label(awaits-arch)` jeté → throttle pas posé → re-dispatch churn (« escalated » menteur).
4. `pilot/gatekeeper_seal.ex:102` — `close_issue` jeté → brique MERGÉE reste OUVERTE → re-dispatchée chaque tick.
5. `pilot/incident_registry/escalation.ex:66` — label `error_system` jeté sous faux `{:ok}` → alarme sysadmin invisible.
6. `spawner/pod/state_fs.ex:113` — `File.rm_rf` tombstone jeté → si state.json survit → boucle non-lancement silencieuse. (P1 a mis `:ok` = hygiène dialyzer, PAS le vrai fix.)
7. `spawner/pod.ex:452` — `send_keys("/clear")` jeté → bleed de contexte REPL inter-issues.
8-9. `pilot/spawn.ex:246/336` — `pod_alive?/pod_info rescue` → pod VIVANT classé mort → double-spawn / kill eng vivant / corruption workspace.

+ ~15 TIER-2 muets (safe_clear_for_pod sans log, task_probe→skip-enqueue, reconciliation under-report, permanent_boot muet, mcp hollow-green, coord/emitter, wake_recovery note…). ~30 sites OK vérifiés (best-effort légitime).

## C. P3 — le filet Cat-5/coord MORT de bout en bout (DOCTRINE) — ⚡ Q2 : ÇA CLIGNOTE (2/4 câblés)
Trigger (pod.drift/workflow_map.failed/oauth.refresh.failed) = 0 producteur → Cat5Escalator (0 consumer dédié)
→ CoordBackend (prod ✓) → Coord.Emitter (ne fire jamais, amont mort). Une revue croit l'escalade active. Rien
ne circule. + orphelins : `spawn.failed` (0 consumer → alarme drop-silencieux ignorée), `workflow_map.step.completed`
(fantôme total 0-référence), 10 `gitea.*` (0 réacteur métier).

**Q2 RÉSOLU (choix user « + audit.verdict aussi » ; draft honnête) — `dbbf4870e`/`2ae205aec`/`7b0b6a096`/`4b8d77a91` :**
- 2 producteurs DRAFT dans `StepRunConsumer` (source :workflow, best-effort) : `workflow_map.failed`
  (sur `:workflow_map_load_failed`) → Cat5Escalator ; `audit.verdict` (verdict juge escalade-digne,
  traduit decision-v1 escalate/audit_verdict) → CoordBackend.handle_decision. La chaîne blink de bout en
  bout jusqu'à `coord.notification_routed` (chaque maillon testé : pilot 355 / starfleet 64 / coord 18).
- DriftMonitor : `source: :workflow` anti-spoof sur les 2 clauses + 2 tests anti-spoof. **Mensonge A-#3
  corrigé** (moduledoc « audit.verdict live path » → dit vrai : dormant→draft, statut par event).
- events.yaml aligné (registre = réalité). `pod.drift`/`oauth.refresh.failed` restent dormants : aucun
  signal réel à fabriquer honnêtement aujourd'hui (documentés tels quels).
- RESTE (hors Q2) : orphelins spawn.failed / workflow_map.step.completed / gitea.* (P4 ou chantier séparé).

## D. P5 — faux-vert (localisé, suite globalement solide) — ✅ 3/3 durcis (`6863c4943`)
- 2 TAUTOLOGIQUES ✅ : `mcp_watcher_test:46` (is_binary OR is_nil → attendu calculé Application.spec ex_mcp) ; `blocks_test:11/19` (boucles vacues → guard `map_size(roles)>0` avant chaque `for`).
- SÉCU n°1 ✅ : `step_run_completer_test:361` — invariant `refute_received {:comment}` sur le fail-path 409 + PrFailForge rendu signalant. VÉRIFIÉ : le sceau EST merge-first (pas de bug, trou de test comblé).
- ~15 FAIBLE (count/return-sans-contenu) + `poller_test refute_received {:spawned}` inertes (message → mailbox Poller). Suite ok par ailleurs.
