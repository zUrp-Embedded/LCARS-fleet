# fleet/services/human.d — les modules de convergence d'un humain

**Date** : 2026-09-03
**Dernière révision** : 2026-09-03
**Statut** : EN SERVICE — posé en `/opt/lcars/fleet/services/human.d/`
**Référencé par** : `fleet/services/human-converger.sh` (les exécute) ·
`deploy/modules.d/62-runtime-helpers.sh` (les pose avec le reste de `services/`)

## Ce que ce répertoire est

Ce qu'il faut poser **dans le home d'un humain** pour qu'il puisse travailler : son binaire
`claude`, son identité git, ses projets. Un module par sujet, numéroté, idempotent.

Ils ont vécu dans `deploy/modules.d/` et n'y avaient pas leur place. Le critère est le **moment
d'exécution**, pas la ressemblance de forme : un module de `deploy/` converge la MACHINE une fois,
depuis le checkout, et le checkout peut disparaître ensuite. Ceux-ci convergent un HUMAIN — à
chaque nouveau login, longtemps après l'install, sans checkout. Ils doivent donc partir avec la
boîte, et c'est ce que `fleet/services/` veut dire.

## Le protocole

Chaque module est un exécutable qui répond à deux gestes — `<module> check|apply` — et rien
d'autre. C'est le protocole des modules de provisionnement, décrit une seule fois dans
`deploy/README.md` ; il vaut ici à l'identique.

Ce qui change, c'est **qui appelle**. Sous `deploy/`, c'est `provision` qui fournit les helpers
(`p_ok`, `p_chg`, `p_drift`, `verdict_apply`…). Ici c'est `human-converger.sh`, qui les
redéfinit dans un sous-shell et pose `PROV_HUMAN` avant de sourcer le module. Un module ne sait
donc **pas** lequel des deux le lance, et ne doit pas chercher à le savoir : il n'appelle que les
helpers du protocole, jamais un chemin de `deploy/`.

Le verdict d'`apply` est un code de sortie : `0` convergé, `2` drift constaté et non réparable,
autre chose = échec. Le convergeur ne tient l'échec que pour ce qui n'est ni `0` ni `2` — un drift
sur un humain n'arrête pas la convergence des suivants.
