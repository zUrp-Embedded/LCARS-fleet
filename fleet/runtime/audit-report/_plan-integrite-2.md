# Plan — Campagne « Intégrité #2 »

**Date** : 2026-07-09
**Dernière révision** : 2026-07-09
**Statut** : en cours — P1 dialyzer (PLT en fond) + fan-out P2/P3/P5
**Référencé par** : `soft-defaults-audit.md`, `PLAYBOOK-finition.md`

Méthodo : recon (fan-out/outil) → VÉRIF code par finding → classé → TDD (RED→verrou amont→GREEN) → gate → commit/unité → tracé.

- [ ] **P1 Dialyzer** (@spec mentent) : PLT en fond → `mix dialyzer` umbrella → tri (bug vs spec-à-préciser) → remédie. `dialyzer-audit.md`.
- [ ] **P2 Sweep `_ =`** (avalage silencieux) : fan-out ~58 sites `_ = <call>` + rescue/catch-qui-rendent → discard justifié vs panne load-bearing avalée.
- [ ] **P3 Graphe d'events** (rails morts) : registry `events.yaml` ∪ producteurs ∪ consumers → orphelins (produit-jamais-consommé / consommé-jamais-produit).
- [ ] **P4 Tier-2 vivants** (scoutés) : permanent_boot muet, webhooks ACK-200-drop, mcp hollow-green, incident amnésie, observation LED-verte.
- [ ] **P5 Qualité tests** (faux-vert) : tautologiques, passe-sur-code-supprimé, co-édités-verrouillant-faux, async:false-couplage.

Ordre : PLT dialyzer en fond ∥ fan-out P2+P3+P5 → remédiation convergente (dialyzer + P4 + fan-out).
