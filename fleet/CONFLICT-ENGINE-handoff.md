# Transmission — moteur de résolution de conflits déterministe

**Date** : 2026-07-30
**Dernière révision** : 2026-07-30
**Statut** : transmission — P1→P4 livrés, testés, gate vert. Prêt pour PR `feat/conflict-engine` → `main`.
**Référencé par** : PR `feat/conflict-engine` → `main` ; `ready-room/outbox/#3_ponce-reverse/GitWand/`
**Branche** : `feat/conflict-engine` (basée sur `main`)
**Destinataire** : l'agent qui gère le projet (merge + suite du chantier).

---

## 1. En un paragraphe

On a sondé/reversé/audité l'app externe **GitWand** (moteur TS de résolution auto de conflits git). Verdict d'audit : **6.5/10** — un CŒUR déterministe excellent (8.5/10), mais des couches périphériques dangereuses (12 résolveurs format-aware = 14 CRIT de perte de données silencieuse, MCP sans confinement). Décision (user) : **recoder le tier sain en Elixir pur**, jeter le reste, et le brancher **derrière notre propre boucle jury** — ce qui neutralise le motif de perte de données (rien n'est écrit sans re-jugement). Résultat : un moteur `foundation` pur + un diagnostic git + une auto-résolution + un câblage tier-0→2 dans `Remediation`, **derrière un flag off par défaut**.

Toute la chaîne d'analyse est dans `ready-room/outbox/#3_ponce-reverse/GitWand/` (brief sonde, `GitWand-specs.md`, `GitWand-architecture.md`, `audit-report/` avec le bilan, `GitWand-plan-recode.md`).

---

## 2. Les commits (dans l'ordre)

```
feat(conflict): deterministic trivial-conflict engine -- P1 slice        (parser+fix CRLF, 3 patterns certains, trace, score)
feat(conflict): the 5 heuristic patterns + Diff/Utils -- P1 complete      (les 8 patterns, Diff LCS, Utils quote-aware/semver)
feat(conflict): ConflictProbe -- git-backed tier-0 diagnosis (P2)         (diagnostic read-only, 2 pièges audit évités)
feat(conflict): tier-0 wiring in Remediation + auto-resolve write path (P3)(routage + ConflictApply worktree/push)
feat(conflict): tier-2 gatekeeper stage before the arch (P4)              (une passe gatekeeper avant escalade humaine)
```

(`git log --oneline feat/conflict-engine` pour les hashes exacts.)

---

## 3. Architecture

### Le moteur — `Fleet.Conflict` (domaine `foundation`, `deps: []`, PUR)

Aucun I/O, aucun process. `lib/fleet/conflict/` :
- `Parser` — marqueurs → segments (diff2/diff3/zdiff3). **Fix du bug CRLF** de l'audit (séparateur `=======\r`).
- `Classifier` — registre de 9 patterns par priorité, premier match, `DecisionTrace` (le refus tracé autant que la résolution).
- `Patterns.*` — 8 patterns triviaux (same_change, one_side_change, delete_no_change, non_overlapping, whitespace_only, reorder_only, insertion_at_boundary, value_only_change) + complex (fallback total).
- `Patterns.Utils` — tokenizer quote-aware, détection de valeurs volatiles, comparaison semver/datetime (les subtilités disséquées à l'audit).
- `Diff` — LCS (DP) + merge 3-way non-overlapping.
- `Score` — LA formule composite **en exemplaire unique** (l'audit avait trouvé 3 copies divergentes chez GitWand).
- `Assemble` — merge textuel par type. `Report` — {merged, hunks, stats}.

Contrat : `Fleet.Conflict.resolve(content, opts)` → `{:ok, %Report{}}`. `merged` non-nil **seulement** si tout franchit le seuil `:min_confidence` (défaut `:high`) — le seul signal « safe to write ».

### La plomberie — domaine `Fleet.Pilot`

- `ConflictProbe` (`lib/fleet/pilot/conflict_probe.ex`) — diagnostic git READ-ONLY : `git merge-tree`-style via fetch dans un ref jetable + `merge-file` sur blobs temp (object store only, working tree jamais touché → pas de course avec `WorktreeSync`). Agrège en `{trivial, complex, all_trivial?, none_trivial?}`. **Les 2 pièges de l'audit évités** : `git show` lu untrimmed (sinon perte du newline final → conflits EOF invisibles), `merge-file` capturé malgré son exit non-zéro.
- `ConflictApply` (`lib/fleet/pilot/conflict_apply.ex`) — le write path : worktree jetable → `git merge origin/main` → RE-résout chaque fichier dans la vraie orientation → **seulement si TOUT résout**, commit + push. Jamais partiel (`merge --abort` au premier résiduel).

### Le câblage — `Remediation` (`.../review_lifecycle/remediation.ex`)

Le pipeline à 4 étages, gated par `:fleet_pilot, :conflict_diagnosis?` (off par défaut) :

```
conflit :conflict
  │
  ▼  (flag ON)
T0 déterministe (runtime, ms)   -- tier0_decision(diagnosis) [PURE, testé]
  ├─ none_trivial? (tout sémantique) → escalade arch directe (rounds économisés)
  ├─ all_trivial?  → ConflictApply (auto-résolution + push) ; le jury re-juge
  └─ mixte / probe KO / apply KO   → fall-through ▼
T1 producteur conflict-rework (pod) -- inchangé, borné max_rework_rounds
  └─ budget épuisé → producer_exhausted ▼  (flag ON)
T2 gatekeeper (pod, 1 passe d'inférence) -- gatekeeper_stage_decision [PURE, testé]
  └─ passe épuisée / count illisible → escalade arch ▼
T3 arch (humain) -- lcars-awaits-arch
```

Flag OFF → `legacy_conflict_rework` (producteur → arch), **byte-for-byte identique à avant**.

---

## 4. Activer en production

```elixir
# config/runtime.exs (dans le garde config_env() != :test), ou config/config.exs
config :fleet_pilot, conflict_diagnosis?: true
```

Seams injectables (test/override) : `:conflict_diagnoser` (défaut `Fleet.Pilot.ConflictProbe`), `:conflict_applier` (défaut `Fleet.Pilot.ConflictApply`).

**Rollout recommandé** (prudent) :
1. Activer le flag → observer l'audit-log des classifications (T0 route mais n'écrit qu'en all_trivial?).
2. Vérifier sur de vrais conflits que le classement trivial/complexe est juste (invariant clé : **0 faux positif sur complex** — un sémantique classé trivial serait le seul vrai danger ; le corpus l'épingle).
3. Une fois confiance établie, laisser l'auto-résolution et le gatekeeper actifs.

---

## 5. Merge / intégration

- **Branche** `feat/conflict-engine`, basée sur `main`. Les commits vivent dans le `.git` partagé de LCARS (persistants). Le chantier a été mené dans un **worktree git isolé** (scratchpad) pour ne pas partager le checkout — **l'autre chantier `remediation-images` n'a jamais été touché**.
- **Pour intégrer** : PR `feat/conflict-engine` → `main` par le workflow habituel. Fichiers ajoutés disjoints de l'existant (nouveau domaine `Fleet.Conflict` + 2 modules pilot + tests) ; les seules modifs de fichiers existants : `lib/fleet/pilot.ex` (dep boundary), `lib/fleet/conflict.ex` export, `remediation.ex` (câblage), `lib/mix/tasks/lcars.topology.ex` (déclaration `@layers`), les 2 README (topologie régénérée). Rebase trivial si `remediation-images` merge avant.
- **Gate** : `mix compile --warnings-as-errors` (dont boundary), `mix test`, topologie régénérée, hooks doctrine (footers `**Last revised**`) — tout passe.

---

## 6. Couverture de tests — ce qui est prouvé, ce qui ne l'est pas (honnêteté)

**Prouvé hermétiquement** :
- Le moteur : corpus porté + un test par pattern + units (Diff, Utils, semver). ~26 cas.
- `ConflictProbe` : 5 tests dont un vrai `merge-file` sur repo temp.
- `ConflictApply` : 2 tests contre un **remote bare RÉEL** (trivial → poussé ; complexe → refusé, branche intacte).
- Décisions de routage : `tier0_decision` (4 cas) + `gatekeeper_stage_decision` (3 cas), pures.
- **Non-régression : suite runtime complète verte** (1638 tests, flag off = legacy inchangé).

**NON prouvable en test hermétique (à valider en réel)** :
- Le **comportement du POD gatekeeper** résolvant un vrai conflit — c'est un agent LLM, aucun test hermétique ne peut le couvrir. Le mécanisme de dispatch (T2) réutilise le chemin producteur ÉPROUVÉ ; ce qui reste à valider est que le gatekeeper, avec ce workspace + brief, résout effectivement.

---

## 7. Reste à faire (finitions, par priorité)

1. **Brief gatekeeper dédié (P4 finition)** — `dispatch_gatekeeper_rework` réutilise aujourd'hui le brief conflit du PRODUCTEUR (qui parle de « ton brief »), sémantiquement bancal pour un juge d'exception. La mécanique (workspace, résolution, push, re-jugement) est correcte ; seule la PROSE du brief est à adapter (voix exception-judge). Voir la `NOTE (handoff)` inline dans `remediation.ex`. Nécessite probablement une variante dans `BriefBuilder`/`RoleDispatch`.
2. **Validation réelle** — activer le flag sur un projet pilote, provoquer un conflit trivial (2 tickets concurrents, cas déjà vu en prod) et vérifier bout-en-bout : diagnostic → auto-résolution → push → re-jugement jury. Idem pour un conflit sémantique → gatekeeper → arch.
3. **Doc coherence** — la puce `:conflict` de la moduledoc `route_merge_failure` dit encore « Tier 2 … is a later increment » ; à actualiser (tier-0 existe, tier-2 câblé).
4. **Optim (optionnel)** — porter le backend **Histogram** de diff (meilleurs splits sur du code → meilleur taux de `non_overlapping`). Le LCS DP actuel est correct, pas optimal. Non urgent.
5. **Config discoverability** — ajouter `config :fleet_pilot, conflict_diagnosis?: false` explicite dans `config/config.exs` (aujourd'hui c'est le défaut du `get_env` — fonctionne, mais moins visible).

**Volontairement NON porté** (décisions d'audit, ne pas « compléter » sans raison) : les 12 résolveurs format-aware (14 CRIT — un merge LCARS ne résout jamais un lockfile/dotenv/Dockerfile), le merge structurel AST (tree-sitter, 2 CRIT), le fallback LLM (c'est le rôle du gatekeeper), RefMerge (bug confirmé), le pattern `generated_file`.

---

## 8. Décisions & garde-fous clés (à ne pas casser)

- **Le jury re-juge toujours le head poussé** → l'écriture runtime (auto-résolution) est sûre par construction : une résolution triviale fausse est rattrapée au jugement. C'est LE garde-fou que GitWand seul n'avait pas — l'argument central qui autorise l'écriture.
- **Fail-safe partout** : toute erreur de probe/apply/git → fall-through vers le comportement legacy. Le tier-0/2 ne peut que RACCOURCIR un chemin, jamais le casser.
- **Flag off par défaut** → zéro impact tant que non activé. La non-régression le prouve (1638 tests verts).
- **Boundary** : `Fleet.Conflict` en `foundation` (`deps: []`) ; `Pilot → Conflict` déclaré (geste visible). Ne pas élargir sans raison.
- **Invariant de sécurité de l'auto-résolution** : `merged` non-nil ⟺ 100% des hunks résolus ≥ seuil. Jamais de merge partiel. `ConflictApply` re-vérifie dans la vraie orientation et `merge --abort` au premier résiduel.
- **Les 2 pièges git de l'audit** (show trimmé, merge-file exit non-zéro) sont évités par construction dans `ConflictProbe`/`ConflictApply` — ne pas « simplifier » en repassant par `GitOps.read` sur ces deux appels.

---

## 9. Où regarder pour comprendre

- Le moteur : `h Fleet.Conflict` + `test/fleet/conflict/`.
- Le diagnostic/apply : `Fleet.Pilot.ConflictProbe` / `ConflictApply` moduledocs.
- Le câblage + le pipeline : `Fleet.Pilot.StepDispatcher.ReviewLifecycle.Remediation` (fonctions `conflict_rework`, `tier0_decision`, `gatekeeper_stage_decision`).
- L'analyse amont : `ready-room/outbox/#3_ponce-reverse/GitWand/`.
