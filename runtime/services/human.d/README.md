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
d'exécution**, pas la ressemblance de forme : un module de `deploy/` converge la MACHINE une fois,
depuis le checkout, et le checkout peut disparaître ensuite. Ceux-ci convergent un HUMAIN — à
chaque nouveau login, longtemps après l'install, sans checkout. Ils doivent donc partir avec la
boîte, et c'est ce que `runtime/services/` veut dire.

## Le protocole

Chaque module répond à deux gestes — `<module> check|apply` — et rien d'autre. C'est le protocole
des modules de provisionnement, décrit une seule fois dans `deploy/README.md` ; il vaut ici à
l'identique.

Ce qui change, c'est **comment on l'invoque**, et l'écart est réel :

|  | `deploy/provision` | `human-converger.sh` |
|---|---|---|
| invocation | `bash <module> <geste>` — un processus | `. <module> apply` — sourcé dans un sous-shell |
| helpers | fournis par `provision-lib.sh` | redéfinis par le convergeur |
| cible | la machine, ou un humain via `as_human` | l'humain de `LCARS_LOGIN`, sous root |

Un module ne sait donc **pas** lequel des deux le lance, et ne doit pas chercher à le savoir : il
n'appelle que les helpers du protocole, jamais un chemin de `deploy/`. Le corollaire est
pratique, et il ne se déduit pas de la lecture d'un seul des deux appelants : pas de `$0`, pas de
`cd` — il déplacerait le répertoire courant du convergeur pour tous les modules suivants — et
`${BASH_SOURCE[0]}` pour se localiser, seule forme qui dise vrai sous les deux invocations.

Aucun des deux n'exige le bit exécutable, et les modules ne le portent pas : `bash <fichier>` et
`.` lisent un fichier, ils ne l'exécutent pas. Le poser suggérerait un troisième appelant qui
n'existe pas.

Le verdict d'`apply` est un code de sortie : `0` convergé, `2` drift constaté et non réparable,
autre chose = échec. Le convergeur ne tient l'échec que pour ce qui n'est ni `0` ni `2` — un drift
sur un humain n'arrête pas la convergence des suivants.
