# CONSOLIDATION PHASE 5 — 25 PERCE-doc (3 workers vérif)

**Date** : 2026-07-11
**Statut** : 20 CONFIRM-STALE sûrs (à appliquer) · 5 CODE-ISSUE/décision (→ user) · 2 couplages test↔doc
**Référencé par** : `CARNET-DE-BORD.md`, `LEDGER.csv`

## 20 CONFIRM-STALE sûrs (doc/commentaire/moduledoc/README/schéma) — ANCIEN/NOUVEAU dans les rapports workers
F-C002 (cap_profile Exit codes :catalogue_missing) · F-C003 (catalog.ex comment) · F-C004 (cap_profile moduledoc apiVersion) ·
F-C008 (event.ex source vs events.yaml) · F-C009 (bus.ex early-boot window) · F-C012 (SignalsOS inert : event_router+events.yaml) ·
F-C014 (allowed_graph 37→38) · F-C067 (gatekeeper_seal doc) · F-C071 (forge_client Idempotence GET+POST) ·
F-C072 (forge_client Pagination) · F-C088 (chain_integration_test comments) · F-C090 (test_helper ×2 comment) ·
F-C128 (.dialyzer_ignore comment) · F-C131 (README 15→14) · F-C134 (Fleet.Workflow.GitRef→Fleet.GitRef) ·
F-C148 (brainstorming NO EXCEPTIONS) · F-C158 (coord-policies schema 05_data-canon) · F-C162 (DESIGN auth HMAC→no-auth) ·
F-C132-doc (etc/README /etc sélectif) · F-C137-doc (host_launch.sh SP hors argv)

## 2 couplages test↔doc (log + assertion ensemble, run le test)
- **F-C017** : role_token.ex (doc + 3 logs + comment) + README + **role_token_test.exs:28** `assert log =~ "fallback to system token"` → changer le log ET l'assertion (le comportement `==nil` reste correct).
- **F-C070** : repo.ex doc + **forge_client_test.exs:77** (NOM de test seul, pas d'assertion) → renommer.

## 5 CODE-ISSUE / DÉCISION (→ user, PAS doc-only)
- **F-C006** : `cap_profile_v25_conformance_test.exs:93` — test « apiVersion manquant rejeté » passe pour une MAUVAISE raison (metadata/spec vides) → fausse couverture. Fork : renommer (refléter la vraie raison) VS vrai test « apiVersion inconnu rejeté » (additionalProperties:false).
- **F-C132-test** : `test/integration/sandbox_notrace_test.sh` partirait ROUGE (auth token_arg retirée→exit1, assert oauth_token=set sans injection, préconds .credentials.json/MCP absentes) → réécriture complète du contrat sandbox. (Test shell d'intégration, hors gate mix.)
- **F-C137-test** : `test/integration/host_launch_test.sh` VERT mais asserte la forme argv inline-SP retirée (argc=4, sp inline) → réécrire commande factice + asserts en 3-args + .lcars/system-prompt.md.
- **F-C151** : prose canon dual-review + subagent-templates décrivent un modèle juge obsolète vs sp_drafts (autorité courante). VÉRIFIER si le bundle dual-review est LIVE-assemblé (→ vrai fix) ou dormant (→ doc). Réécriture prose canon = décision.
- **F-C087** : scaffold génère `**Date**: 2026-06-14` hardcodé dans CHAQUE nouveau projet → besoin d'un seam horloge (mini code-change + test), pas doc-only. Ou omettre la métadonnée date.
