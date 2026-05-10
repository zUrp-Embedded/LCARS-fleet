# no-deploy-ok-flag

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §3 "Système READY"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : DRAFT (invariant de design plus que comportement runtime)
**Référencé par** : `contrat-runtime-minimal/README.md`

## Contrat

Citation corpus :
> Pas de `.deploy_ok`. Pas de flag. La conjonction des probes EST
> l'état READY, vérifié dynamiquement.

L'invariant est : **fleet-pilot NE consulte PAS de fichier sentinelle**
pour décider de son état READY. Il consulte uniquement les résultats
dynamiques des 6 probes. Un `.deploy_ok` posé sur le FS ne doit pas
faire passer le système en READY si une probe échoue ; inversement,
l'absence d'un `.deploy_ok` ne doit pas bloquer le système si les
probes réussissent.

## Ce qui prête à confusion

PoC-05 (systemd `ConditionPathExists`) teste l'**onboarding**
double-guard (V2.17 P1-4), où un `.deploy_ok` **est** utilisé par
systemd pour lancer fleet-pilot. Ce n'est pas la même sentinelle :
- V2.17 / systemd : `ConditionPathExists` pour le **launch**, pas pour
  le READY runtime.
- Fleet-pilot runtime READY : conjonction des 6 probes dynamiques.

Les deux sentinelles peuvent coexister sans contradiction.

## Observable

- [GAP] Statique : `grep -r "deploy_ok" /home/projects/LCARS/fleet/v2/`
  doit revenir vide ou uniquement dans des chemins systemd/provisioning,
  jamais dans le code du daemon fleet-pilot
- [GAP] Runtime : avec `.deploy_ok` présent + une probe False →
  fleet-pilot NON READY

## Pourquoi DRAFT

Pas encore de fleet-pilot runtime à inspecter. Le test statique peut
s'écrire quand le code du daemon arrive. Pour l'instant, c'est une
note d'invariant pour quand on miroire `fleet-pilot-architecture.md`.
