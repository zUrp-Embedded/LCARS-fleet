# monks — les profils de Memory-X au schéma courant (feature gelée, hors de la boucle de boot)

**Date** : 2026-06-19
**Dernière révision** : 2026-07-04
**Statut** : ARCHIVÉ / gelé — hors scan cap-profiles, hors boot permanent
**Référencé par** : work/backlog.md (LCARS), #5.2/JOURNAL-session

## Pourquoi ici

Ces cap-profiles (`archivist` + monks `alpha`/`beta`/`monk-*`, le sous-système **Memory-X V1**) étaient
dans `cap-profiles/monks/`, donc scannés par `Fleet.CapProfile` (`name_index` globbe `monks/`) et
sélectionnés au boot permanent (`boot_at_start: true`). Résultat : `fleet start` **tentait de booter
~17 pods permanents** (1 arch + 16 monks/archivist), pas juste l'arch.

**Décision (2026-06-19)** : Memory-X doit être **per-project ET system-wide, sous `lcars` côté OS — PAS
per-fleet/user**. Sinon on spawne la flotte de monks ×(nb de fleets) sur le même corpus. Gelé ici en
attendant le re-home propre. cf. `work/backlog.md`.

## Effet

Déplacé hors de `cap-profiles/` → plus scanné → ne boote plus. Seul `architect` reste `boot_at_start`
(le gatekeeper boote via fleet_workflow). Le **code** d'injection monk (`SPBuilder.resolve_monk_injection`)
reste en place, juste non sollicité. Tests monk gelés (`@moduletag skip`) : `sp_builder_monk_test`,
`cap_profile_monks_f041_test`, `monks_v25_conformance_test`.

## Restaurer (au re-home)

`git mv priv/memory-x/monks <cible per-project/system-wide>` + re-pointer les fixtures de test + retirer les
`@moduletag skip`. Ne PAS juste remettre dans `cap-profiles/monks/` (ça re-introduit le bug per-fleet).
