# deploy/tests — le corpus de l'installeur

**Date** : 2026-08-30
**Dernière révision** : 2026-08-30
**Statut** : actif — carte du corpus, pas un contrat
**Référencé par** : `fleet/test/README.md`

## La question que ce corpus pose

**« Le déploiement pose-t-il correctement ? »** — jamais « ce fichier se comporte-t-il
correctement ». C'est ce qui distingue ce dossier de `fleet/test/`, et c'est la seule règle de
rangement ici.

⚠ **La cible d'un témoin n'indique donc PAS son domaine.** `supervise.bats` mesurait
`services/supervise.sh` et testait sa borne de relance : c'était un témoin du projet, il est parti.
`console_socket_topology.bats` mesure `services/console.sh` aussi — et il reste, parce qu'il le
confronte au `Dockerfile` de la boîte. La différence n'est pas dans le fichier mesuré, elle est
dans la question. Lire l'en-tête d'un témoin ne suffit pas à trancher : sa prose raconte souvent le
motif historique, pas ce que le corps exerce.

## Ce qui est parti vers `fleet/test/` le 2026-08-30

Six témoins n'exerçaient que du code du projet et ne touchaient AUCUN artefact de l'installeur —
ils faisaient dépendre le corpus de deploy du comportement du projet, dans un dossier qui doit
pouvoir en être indépendant : `authority_ask`, `console_creds_drift`, `console_helpers`,
`forge_demote_owner`, `forge_publicize`, `supervise`.

Quatre autres, mesurés comme eux, sont RESTÉS : `console_socket_topology` (→ `docker/Dockerfile`),
`forge_gestures` (→ `box`), `lcars_catalogue` (→ `system.manifest`) et `toolchain_converger`
(→ `lib/provision-lib.sh`). Les déplacer aurait créé la dépendance inverse — le projet vers
l'installeur — qui est précisément celle qu'on refuse. `forge_host_reach`, `human_converger` et
`enroll_catalogue` sont dans le même cas depuis toujours.

## Pourquoi il n'y a pas de miroir ici

`fleet/test/` reflète `lib/`, `bin/`, `etc/`, `services/` fichier par fichier. Ce corpus, non, et
c'est mesuré : **41 de ses 67 suites touchent deux fichiers ou plus** (jusqu'à onze pour
`forge_host_reach`). `deploy_manifest.bats` confronte d'un seul geste le manifeste, `install.sh`,
le Dockerfile, `provision-lib.sh` et deux modules. Choisir une « cible dominante » pour ranger un
tel témoin serait arbitraire, et le nom qu'il porte aujourd'hui — ce qu'il prouve — dit plus qu'un
nom de fichier.

## Le helper

`refute.bash` vit ici, et une copie identique vit en `fleet/test/support/`. Les deux corpus sont
indépendants par construction : aucun ne charge le fichier de l'autre. `tests.refute_copies_agree`
(`mix lcars.contracts.check`) hache les lignes non-commentaires des deux et refuse qu'elles
divergent — une correction posée d'un seul côté rendrait un corpus plus permissif que l'autre sans
casser le moindre test.

## Joué par

`fleet/test/shell_gate.sh`, câblé dans `mix gate`, qui découvre récursivement tous les `.bats` de ce
dossier. `bats` absent n'échoue pas : le compte des suites manquées est ANNONCÉ, et
`BATS_MISSING_FATAL=1` durcit le jour où `bats-core` est un prérequis posé partout.
