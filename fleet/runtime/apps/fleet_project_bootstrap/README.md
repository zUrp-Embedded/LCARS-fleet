# fleet_project_bootstrap — à écrire

**Date** : 2026-05-18
**Statut** : placeholder — app à implémenter post-session
**Dérivé de** : 04_design-notes/ + session 2026-05-17/18 (rings finalisés)

Cette app fait partie du **core V2 cible** (rings finalisés cette session) mais n'est pas encore implémentée.

## Scope V2 — core du pod

Prépare le pod_dir AVANT spawn :
- Branch feature isolante depuis main projet
- `/init` mimic : workspace + CLAUDE.md vanilla
- Bind credentials role-scopés
- Mount-bind plugins host-side (superpowers + LCARS overlay si gardé)

L'agent dans le pod ne sait pas qu'il y a eu mécanique — il découvre un projet vanilla post-/init.

Pattern central V2. Pas optionnel : c'est le core du pod.
