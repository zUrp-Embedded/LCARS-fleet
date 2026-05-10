# pipeline-dag-no-cycle

**Source** : `work/moon-shot/10-beyond/beyond-objets-runtime-v2.md` §3 "Invariants du pipeline" (Invariant 1)
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : PROVEN
**Référencé par** : `objets-runtime/README.md`

## Contrat

Un Pipeline a des stages qui déclarent leurs dépendances via `needs`. L'ensemble (stages, needs) forme un DAG (graphe acyclique dirigé).

**Invariant 1** : pas de cycle. Fleet-pilot valide à la lecture du Pipeline YAML et **refuse** le pipeline si un cycle est détecté.

Cycles directs (A needs A) et transitifs (A needs B, B needs A ; A needs B, B needs C, C needs A) doivent être détectés.

## Observable

- Fonction `validate_dag(pipeline_stages: dict) -> None | raise CycleDetected`
- Détection via tri topologique (Kahn) ou DFS avec marqueurs
- Les noms de stages peuvent être n'importe quelle string ; `needs` référence des noms définis

## Ce que le test vérifie

- DAG valide (3 stages en chaîne) : passe
- DAG valide (diamant A→{B,C}→D) : passe
- Cycle direct (A needs A) : raise
- Cycle à 2 (A needs B, B needs A) : raise
- Cycle à 3 (A→B→C→A) : raise
- Référence vers stage inexistant : raise (fail-closed)
- Pipeline vide : passe (vacuously DAG)
- Pipeline sans needs (stages indépendants) : passe
