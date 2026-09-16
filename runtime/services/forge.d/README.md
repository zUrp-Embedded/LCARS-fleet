# forge.d — les gestes de forge du produit

**Date** : 2026-09-04
**Statut** : actif — lot 6 du chantier deploy-independance
**Référencé par** : `runtime/services/README.md`, `deploy/modules.d/{50-catalogues,63-forge-tokens,65-ops-branch,66-deck-oidc}.sh`

Ces quatre gestes sont joués par le **conteneur** à chaque boot et par le **poste** à l'install,
sur le protocole des modules du produit (`../lib/module-protocol.sh`). L'installeur les **appelle**
par ses modules minces `50`, `63`, `65` et `66`. Un remède qu'ils émettent vaut donc sur les deux :
il nomme le geste du poste et celui du conteneur.

| geste | ce qu'il converge | ce qu'il lit |
|---|---|---|
| `catalogues.sh` | le matériel des catalogues INSTALLÉS (signés par la forge), sous `LCARS_CATALOGUES_DIR` | `FORGE_BASE_URL`, `LCARS_PRIVATE_DIR`, `LCARS_CATALOGUES_DIR`, `LCARS_LEGACY_CATALOGUES_DIR` |
| `ops-branch.sh` | la branche orpheline `tool_request` du dépôt ops — la boîte aux lettres de l'outillage | `FORGE_BASE_URL`, `LCARS_SYSTEM_TOKEN_FILE`, `LCARS_SYSTEM_ACCOUNT`, `LCARS_OPS_REPO` |
| `deck-oidc.sh` | le client OAuth2 du deck sur la forge, et `/etc/lcars/deck-oidc.json` | `FORGE_BASE_URL`, `FORGE_PUBLIC_URL`, `LCARS_SYSTEM_TOKEN_FILE`, `LCARS_DECK_*`, `LCARS_LANDING_PORT`, `LCARS_ADVERTISE` |
| `tokens.sh` | les jetons de rôle (sondes de la forge, modes de l'autorité, roster dérivé du release par `lcars tool roles-tfvars` + catalogues installés + plancher `LCARS_ROLES` de l'appelant, mint par `../provision-role-tokens.sh`) | `FORGE_BASE_URL`, `LCARS_FORGE_ORG`, `LCARS_PRIVATE_DIR`, `LCARS_MASTER_TOKEN_FILE`, `LCARS_FORGE_SEED_FILE`, `LCARS_SYSTEM_*`, `LCARS_AUTHORITY_USER`, `LCARS_CATALOGUES_DIR`, `LCARS_ROLES`, `LCARS_LOGIN`, `LCARS_CLI` |

## Le protocole

Chaque geste répond à deux verbes — `<module> check|apply` — et rien d'autre. `check` mesure et
rend le code du doctor (`0` conforme, `1` drift, `2` échec) ; `apply` converge et rend `0`
convergé, `2` drift résiduel (un geste manque : forge, jeton — pas une panne), `1` échec. Les
lignes `OK/POSÉ/DRIFT/WARN/FAIL` sont celles du protocole ; l'hôte les relaie.

Invocation : `bash <module> check` ou `bash <module> apply`, avec `LCARS_MODULE_PROTOCOL` posé
sur `../lib/module-protocol.sh` et les `LCARS_*`/`FORGE_*` que la table ci-dessus nomme (les défauts du
protocole valent pour le reste). Sans `LCARS_MODULE_PROTOCOL`, le geste refuse à la ligne 1 en
nommant sa cause — un geste nu n'a pas d'hôte.

Les hôtes : `deploy/modules.d/50-catalogues.sh`, `63-forge-tokens.sh`, `65-ops-branch.sh`,
`66-deck-oidc.sh` sur un poste (ils passent ce que l'installeur sait de mieux — l'adresse
annoncée, le plancher de rôles) ; le boot du conteneur (`../container/boot.sh`), à chaque démarrage, dans cet ordre :
`catalogues`, `tokens`, `ops-branch`, `deck-oidc` — l'ordre du poste (modules 50, 63, 65, 66), parce que les rôles à minter viennent des catalogues installés.
