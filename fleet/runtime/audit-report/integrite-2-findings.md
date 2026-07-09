# Findings — Campagne Intégrité #2 (P2/P3/P5)

**Date** : 2026-07-09
**Dernière révision** : 2026-07-09
**Statut** : remédiation en cours — **B (9 Tier-1) : 9/9 livrés** ; A mensonges 2/4 ; C (Cat-5) + D (tests) à venir
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
| A | #3 drift_monitor « audit.verdict live » | ⏳ | résolu par Q2 (Cat-5 draft) |

**B CLOS : 9/9. A : 3/4** (reste A-#3, résolu par Q2). Reste D (tests tautologiques + seal-gap), puis Q2 (producteurs Cat-5 draft, résout A-#3), puis P4 (Tier-2 muets).

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

## C. P3 — le filet Cat-5/coord MORT de bout en bout (DOCTRINE)
Trigger (pod.drift/workflow_map.failed/oauth.refresh.failed) = 0 producteur → Cat5Escalator (0 consumer dédié)
→ CoordBackend (prod ✓) → Coord.Emitter (ne fire jamais, amont mort). Une revue croit l'escalade active. Rien
ne circule. + orphelins : `spawn.failed` (0 consumer → alarme drop-silencieux ignorée), `workflow_map.step.completed`
(fantôme total 0-référence), 10 `gitea.*` (0 réacteur métier).

## D. P5 — faux-vert (localisé, suite globalement solide)
- 2 TAUTOLOGIQUES : `starfleet/mcp_watcher_test:46` (is_binary OR is_nil = accepte tout), `sp_builder/blocks_test:11/19` (boucles vacuous 0-assertion si role_map vide).
- SÉCU n°1 : `pilot/step_run_completer_test:361-371` — test FF-409 ne garde PAS contre le sceau-menteur (pas de `refute_received {:comment}` sur le fail-path). Recoupe P2-#4.
- ~15 FAIBLE (count/return-sans-contenu) + `poller_test refute_received {:spawned}` inertes (message → mailbox Poller). Suite ok par ailleurs.
