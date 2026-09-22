# runtime/services/human.d — les modules de convergence d'un humain

**Date** : 2026-09-03
**Dernière révision** : 2026-09-03
**Statut** : EN SERVICE — posé en `/opt/lcars/services/human.d/`
**Référencé par** : `runtime/services/human-converger.sh` (les exécute) ·
`deploy/modules.d/62-runtime-helpers.sh` (les pose avec le reste de `services/`)

## Ce que ce répertoire est

Ce qu'il faut poser **dans le home d'un humain** pour qu'il puisse travailler : son binaire
`claude`, son identité git, ses projets. Un module par sujet, numéroté, idempotent.

Ils ne sont pas dans `deploy/modules.d/`, malgré la forme commune. Le critère est le **moment
d'exécution**, pas la ressemblance de forme : un module de `deploy/` converge la MACHINE, à
l'installation. Ceux-ci convergent un HUMAIN — à chaque nouveau login, longtemps après l'install,
sans l'installeur. Ils partent donc avec le produit, et c'est ce que `runtime/services/` veut dire.

## Le protocole

Chaque module répond à deux gestes — `<module> check|apply` — et rien d'autre, sur le protocole
de `../lib/human-protocol.sh`, que le module source lui-même (`LCARS_HUMAN_PROTOCOL`).

Un seul lanceur : `human-converger.sh`. L'installeur n'en joue aucun. Le convergeur **source**
chaque module dans un sous-shell (`. <module> apply`), pour l'humain de `LCARS_LOGIN` et sous son
identité. Un module n'appelle que les helpers du protocole, jamais un chemin de `deploy/`. Le
corollaire est pratique : pas de `$0`, pas de `cd` — il déplacerait le répertoire courant du
convergeur pour tous les modules suivants — et `${BASH_SOURCE[0]}` pour se localiser, seule forme
qui dise vrai quand le fichier est sourcé comme quand un témoin le joue par `bash <module>`.

Les modules ne portent pas le bit exécutable : `bash <fichier>` et `.` lisent un fichier, ils ne
l'exécutent pas.

Le verdict d'`apply` est un code de sortie : `0` convergé, `2` drift constaté et non réparable,
autre chose = échec. Le convergeur ne tient l'échec que pour ce qui n'est ni `0` ni `2` — un drift
sur un humain n'arrête pas la convergence des suivants.
