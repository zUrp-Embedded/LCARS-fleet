# monks — les profils de Memory-X au schéma courant (feature gelée, hors de la boucle de boot)

**Date** : 2026-06-19
**Dernière révision** : 2026-07-04
**Statut** : ARCHIVÉ / gelé — hors scan cap-profiles, hors boot permanent
**Référencé par** : `priv/memory-x/README.md`

## Pourquoi ici

Ces cap-profiles (`archivist` + monks `alpha`/`beta`/`monk-*`, le sous-système **Memory-X**) ne
vivent PAS dans `cap-profiles/monks/` d'un catalogue : `Fleet.CapProfile.Catalog.name_index/1` ne
scanne pas `monks/` (le registre est lu à part, par `Fleet.SPBuilder.Monk`), et un profil
`boot_at_start: true` dans le catalogue ferait booter **~17 pods permanents** (1 arch + 16
monks/archivist) à chaque `fleet start`, pas juste l'arch.

**Décision (2026-06-19)** : Memory-X doit être **per-project ET system-wide, sous `lcars` côté OS — PAS
per-fleet/user**. Sinon on spawne la flotte de monks ×(nb de fleets) sur le même corpus. Gelé ici en
attendant le re-home propre.

## Effet

Hors de `cap-profiles/` → pas scanné → ne boote pas. Seul `architect` est `boot_at_start` (le
gatekeeper boote via la workflow-map). Le **code** d'injection monk (`SPBuilder.resolve_monk_injection`)
reste en place, juste non sollicité. Témoins gelés (`@moduletag skip`) : `test/fleet/sp_builder_monk_test.exs`,
`test/fleet/cap_profile/monks_frozen_test.exs`, `test/fleet/cap_profile/monks_conformance_test.exs`.

## Restaurer (au re-home)

`git mv priv/memory-x/monks <cible per-project/system-wide>` + re-pointer les fixtures de test + retirer les
`@moduletag skip`. Ne PAS juste remettre dans `cap-profiles/monks/` (ça re-introduit le bug per-fleet).
