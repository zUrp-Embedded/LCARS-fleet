# boot-startup-probes

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §2 "BOOT" + §3 "Système READY"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : DRAFT
**Référencé par** : `contrat-runtime-minimal/README.md`

## Contrat

Au boot, fleet-pilot exécute séquentiellement 6 probes :

1. `runtime_exists` — `/local/LCARS` existe et contient `fleet/`
2. `specs_readable` — `fleet-system.yaml` + `capability-profiles/` parsables
3. `credentials_avail` — `/home/private/.credentials.json` lisible
4. `event_log_writable` — `/home/fleet-state/` writable
5. `pool_users_exist` — `pod_0..pod_N` existent (`getent passwd`)
6. `fleet_pilot_up` — daemon répond (PID alive + HTTP healthcheck)

Si toutes True → `READY`, accepte les spawns.
Si une échoue → mode dégradé (API répond pour diagnostics, refuse les
spawns).

Log explicite : quelle probe a échoué et pourquoi.

## Observable

- Chaque probe prise isolément : comportement binaire testable
- Le `mode dégradé` : comportement d'API spécifique (refuse spawn,
  répond status/diagnostics)
- Logging explicite : le log doit nommer la probe échouée

## Ce que le test vérifiera

Impl-python d'un `probe_runner` qui :
- Prend la liste des 6 probes
- Exécute chacune dans un env contrôlé (bind mounts ou chroot-léger
  pour simuler chemins absents)
- Retourne un map `{probe_name: True/False + message}`
- Test cases : tout True → READY ; une False → degraded ; tout False → degraded

Le vrai fleet-pilot reprendra ce `probe_runner` tel quel.

## Pourquoi DRAFT

Les probes elles-mêmes ne sont pas encore codées. Plus facile de les
écrire comme fonctions Python isolées dans `impl-python/probes.py`
dès maintenant, avec leur test unitaire. Devient le premier morceau
de fleet-pilot.
