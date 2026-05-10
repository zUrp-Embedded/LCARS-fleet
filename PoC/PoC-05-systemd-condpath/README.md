# PoC-05 — systemd ConditionPathExists sous WSL2

**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : done — 7/7 PASS, hypothèse validée
**Référencé par** : `work/beyond/poc-plan.md §PoC-05`
**Branche** : `feature/poc-05-systemd-condpath`

## Hypothèse

Le hard gate systemd `ConditionPathExists=` fonctionne sous WSL2 exactement comme sur Linux natif : sans le fichier sentinelle, `systemctl start` skip l'unit (pas de ExecStart) ; avec le fichier, l'unit démarre. C'est la base de T-B0.9 (V2.17 P1-4 — double-guard onboarding).

## Méthode

Script `test_condpath.sh` qui :
- installe une unit oneshot `/etc/systemd/system/poc05-condpath.service` avec `ConditionPathExists=$GATE`
- enchaîne : start sans gate (T1), touch gate + start (T2), rm gate + start (T3), répétition T4
- vérifie pour chaque phase : `ConditionResult` + présence du marker créé par `ExecStart` + journal systemd

Observation d'ingénierie : `systemctl show ... ConditionResult` retourne `no` après un oneshot réussi qui est retourné à `inactive/dead`. Le journal contient la vérité canonique (`was skipped because of an unmet condition check` vs. `Starting/ran/Finished`). Le test s'appuie sur journal + marker-file pour trancher.

## Résultats

| Test | Ce qu'on vérifie | PASS |
|---|---|---|
| T1 | sans gate : ConditionResult=no, pas de marker | PASS |
| T2 | avec gate : journal sans "condition failed", marker créé | PASS |
| T3 | gate retirée : systemd refuse à nouveau, marker pas créé | PASS |
| T4 | idempotence : 3 starts consécutifs sans gate = tous skippés | PASS |

Journal type d'un cycle T1→T2 :
```
poc05-condpath.service - PoC-05 ConditionPathExists gate was skipped because
  of an unmet condition check (ConditionPathExists=/tmp/.poc05-gate-5092).
Starting poc05-condpath.service - PoC-05 ConditionPathExists gate...
ran
poc05-condpath.service: Deactivated successfully.
Finished poc05-condpath.service - PoC-05 ConditionPathExists gate.
```

## Conclusion

Hypothèse validée. `ConditionPathExists=` est correctement honoré par systemd sous WSL2 (kernel 6.6.87.2-microsoft-standard-WSL2, systemd PID 1). T-B0.9 / V2.17 P1-4 (double-guard onboarding via sentinelle `/tmp/.deploy_ok` ou équivalent) est techniquement viable.

Pas de finding. Chemin libre pour implémentation B2 gates.

## Note d'ingénierie pour B2

- `systemctl show ... -p ConditionResult` n'est **pas** un oracle fiable post-run pour un `Type=oneshot` — systemd retourne `no` après deactivation. Utiliser journal ou effets observables (marker file, signal, etc.).
- Pour les gates LCARS, ne pas se baser sur `systemctl is-active` pour oneshot : c'est `inactive` normalement. Le bon canari est : "le service a été lancé via start **ET** son ExecStart a touché un marker" OU "journal contient `Finished`".
- `ConditionPathExists` est un no-op silencieux : pas d'exit code non-zéro sur `systemctl start`, aucun mail, aucune alerte. Si B2 veut alerter quand un start échoue à cause de la condition, il faut un handler séparé (ex. `OnFailure=` ne se déclenche pas non plus, puisque le service n'a pas échoué — il n'a simplement pas démarré).

## Livrables

- `test_condpath.sh` — harness reproductible (requiert `sudo` passwordless)

## Hors scope

- `ConditionFirstBoot`, `ConditionHost`, `ConditionArchitecture`, autres `Condition*=` — pas utilisés dans le design LCARS connu.
- Comportement après redémarrage WSL (persistance du marker) — le gate sera probablement sous `/var/lib/fleet/.deploy_ok` ou similaire (pas `/tmp` qui est effacé). Test du gate persistant à traiter en B2.
- Interaction avec `systemd --user` — bus dbus-user absent dans cette instance ; non applicable aux gates système.
