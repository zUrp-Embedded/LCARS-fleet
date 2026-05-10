<!--
  title: Core — Édition / règles livrable
  directives_rev: 7.0-beta
  date: 2026-03-22
  last_updated: 2026-03-31
  status: v7 restructuration — enrichi (exceptions édition depuis workflow), renvoi GO-7 retiré
  referenced_by: build-sp.sh
  derived_from: —
-->

## Édition — règles livrable

**En-tête déclaratif.** CRITICAL: Tout fichier versionné qui supporte un format de commentaire DOIT porter un en-tête déclaratif. Un fichier sans en-tête est implicite, donc inexistant au sens GO-0. Le pre-commit hook vérifie la présence des headers et bloque si absents — aucun auto-fix sur le contenu. Exception : le hook auto-met à jour les dates (STARDATE ou `Dernière révision`) — c'est du bookkeeping de métadonnées, pas une correction de contenu. Format : voir conventions (#6).

**Read avant Write.** CRITICAL: Le contenu du fichier DOIT être dans le contexte (via Read tool) avant tout Write sur un fichier existant. Claude Code ne lit pas automatiquement — sans Read, l'agent écrase avec du contenu imaginé.

**Exceptions Read-avant-Write.** Si le fichier a été Read plus tôt dans la session ET aucun outil ne l'a modifié depuis, un re-Read n'est pas requis. Exception `.md` en réécriture complète → `bash cat <file> > /dev/null` pour confirmer l'existence, puis Write. Exception `scratchpad` : append `bash >>` uniquement. Exception `/home/commons/` : TOUJOURS re-Read (multi-writer, stale possible). `bash cat/head/tail` ne comptent PAS comme Read.

**Edit consécutifs.** Pour des Edits consécutifs sans modification intervenante, le Read initial suffit.

**Lire avant coder.** Lire les fichiers existants AVANT de produire du code. JAMAIS supposer la structure.

**Edit old_string exact.** L'exact old_string DOIT provenir d'un Read output de cette session. Copier caractère par caractère — espaces, indentation, tout.

**Opérations destructives.** Avant rm, ln -sf, truncation : lire la cible, confirmer que le contenu existe ailleurs, le déclarer explicitement.

**MEMORY.md = éphémère.** INTERDIT d'y écrire des règles, conventions, contraintes, ou décisions architecturales. MEMORY.md = contexte de session local uniquement.

**/home/tmp/ JAMAIS pour du livrable.** Tout travail livrable va dans `/home/projects/`. tmp = uniquement scratch technique jetable.

**drvfs (9p).** Edit tool vide silencieusement les fichiers sous drvfs (ready-room, mounts Windows). Workaround : `cp <file> /tmp/`, éditer, copier avec `dd`.

**Triangle strict.** Source → GitHub → runtime. Aucun raccourci. Aucun transfert direct (cp, rsync, scp, symlink, patch manuel) entre le clone dev et le runtime.

**Commit graph immuable.** Violations : `push --force` sur branche partagée, `commit --amend` sur commit poussé, `rebase` sur branche fetchée. Exception : `--force-with-lease` sur branche feature personnelle non-partagée.
