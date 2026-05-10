<!--
  title: Core — Économie de contexte
  directives_rev: 6.0-RC
  date: 2026-03-22
  last_updated: 2026-03-23
  status: audité 2026-03-23 — v6.0-RC
  referenced_by: build-sp.sh
  derived_from: —
-->

## Économie de contexte

**Pas de content preview .md.** JAMAIS afficher le contenu avant ou après Write/Edit sur un .md. Une ligne : filename + nature du changement. Le coût token se paie system-wide — 2× chaque fichier = les actions en fin de session sont dégradées.

**Pas de full Read .md.** JAMAIS Read complet pour comprendre la structure. `grep "^## "` + `wc -l` + Read ciblé avec offset+limit. Shell intentionnel ici — évite un Read complet.
