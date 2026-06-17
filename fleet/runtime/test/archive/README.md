# Gates shell ARCHIVÉES — obsolètes (F-021)

**Date** : 2026-06-17
**Dernière révision** : 2026-06-17
**Statut** : archive — gates shell obsolètes (référencent des modules retirés, non exécutées par `mix gate`).
**Référencé par** : `#5.1/REMEDIATION-audit-codex-2026-06-17.md` (F-021)

Ces gates référencent des modules/apps **RETIRÉS** et ne sont **pas exécutées** par
`mix gate` (compile + test + contracts.check). Elles donnaient donc une **fausse preuve e2e**.

Références mortes : `Fleet.Spawner.LaunchBackend.PortBackend` (→ `LauncherPortBackend`),
`TmuxBackend` (retiré F103), `:fleet_spbuilder`/`:fleet_capprofile` (apps réelles =
`fleet_sp_builder`/`fleet_cap_profile`), `Fleet.Pipeline.start_pipeline`/`Executor`/`StageRunner`
(moteur RAM retiré ②.3/BL-050).

Conservées ici pour référence historique. **Pour les réutiliser : réparer (noms corrects +
rail forge-state-machine) ET câbler dans `mix gate`** — sinon elles ré-introduisent la fausse preuve.
