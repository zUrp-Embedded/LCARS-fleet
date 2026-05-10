<!--
  title: Core — Édition / règles livrable
  directives_rev: 6.0-RC
  date: 2026-03-22
  last_updated: 2026-03-23
  status: audité 2026-03-23 — v6.0-RC
  referenced_by: build-sp.sh
  derived_from: —
-->

## Édition — règles livrable

**En-tête déclaratif.** CRITICAL: Tout fichier versionné qui supporte un format de commentaire DOIT porter un en-tête déclaratif. Un fichier sans en-tête est implicite, donc inexistant au sens GO-0. Le pre-commit hook bloque UNIQUEMENT — aucun auto-fix. Un hook qui corrige les violations les dissimule. Exception : STARDATE et dates dans les headers `.sh` — bookkeeping mécanique (pas du contenu), auto-corrigé par le hook. Format dans organisation/workflow.

**Read avant Write.** CRITICAL: Le contenu du fichier DOIT être dans le contexte (via Read tool) avant tout Write sur un fichier existant. Claude Code ne lit pas automatiquement — sans Read, l'agent écrase avec du contenu imaginé.

**Lire avant coder.** Lire les fichiers existants AVANT de produire du code. JAMAIS supposer la structure.

**Edit old_string exact.** L'exact old_string DOIT provenir d'un Read output de cette session. Copier caractère par caractère — espaces, indentation, tout.

**Opérations destructives.** Avant rm, ln -sf, truncation : lire la cible, confirmer que le contenu existe ailleurs, le déclarer explicitement.

**MEMORY.md = éphémère.** INTERDIT d'y écrire des règles, conventions, contraintes, ou décisions architecturales. MEMORY.md = contexte de session local uniquement.

**/home/tmp/ JAMAIS pour du livrable.** Tout travail livrable va dans `/home/projects/`. tmp = uniquement scratch technique jetable.
