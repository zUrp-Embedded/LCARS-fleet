# CLAUDE.md — `runtime/`, le runtime

**Date** : 2026-05-26
**Dernière révision** : 2026-09-04
**Statut** : guide d'entrée pour un agent qui touche `runtime/`. Chargé par Claude Code au premier
fichier lu sous ce dossier, pas à l'ouverture du dépôt.
**Référencé par** : `lib/fleet/README.md`

Ce fichier dit où sont les choses, ce que le gate tient, et ce qu'il ne tient pas. Il ne recopie
aucun contrat : le contrat d'un module est son `@moduledoc`, celui d'un domaine est sa façade
`Fleet.<Dom>` plus sa carte `lib/fleet/<dom>/README.md`.

## Ce que c'est

Une app Elixir/OTP unique, `:lcars_fleet`, qui lance, surveille et récolte des pods d'agents
(un processus Claude Code par rôle, sandboxé) et fait avancer le travail sur une forge Gitea.
**La forge est la machine à états** : l'état vit dans les issues, PR et labels, jamais en RAM
seule. Le bus (`Phoenix.PubSub`) est un fast-path lossy, jamais une source de vérité.

`runtime/` est un logiciel distinct de `deploy/`, l'installeur, qui a sa propre porte
(`deploy/gate.sh`) et son propre `CLAUDE.md`. Rien ici ne parle de l'installation.

## Où sont les choses

| chemin | ce que c'est |
|---|---|
| `lib/fleet/<dom>/` | un domaine par dossier, sa façade `lib/fleet/<dom>.ex`, sa carte `README.md` |
| `lib/fleet/*.ex` sans dossier | les modules **foundation** : vocabulaire et validation purs, `deps: []` |
| `lib/mix/tasks/lcars.*` | les outils du gate : `contracts.check` (73 murs), `topology`, `catalogue.verify`, `provenance.verify`, `sp.gen` |
| `bin/` | les launchers N0/N1 des pods, `fleet_v2` (lancer la fleet), `lcars` (console opérateur), le rail de publication |
| `etc/` | lancement et release : `fleet_v2.env.template` (catalogue des env vars), `release.manifest`, `deploy-release.sh` |
| `config/` | `config.exs` défauts, `test.exs` baseline hermétique, `runtime.exs` lecture des env vars |
| `priv/catalogue/`, `priv/catalogue-system/` | les deux catalogues embarqués : métier et mécanique système |
| `priv/*/schema/`, `priv/cap_profile/baseline/` | matériel runtime, hors catalogue : contrats et planchers |
| `priv/memory-x/` | Memory-X, feature gelée (prototype d'origine + profils au schéma courant), lue par rien |
| `services/` | ce qui tourne sur la machine après l'install, souvent root : convergeurs, consoles, deck, exécuteur de catalogue |
| `vendor/token_saver/` | brique tierce vendorée, contrat dans son `VENDOR.md` |
| `test/` | ExUnit (284 fichiers), bats des launchers et services (31), `shell_gate.sh`, `fixtures/forge/` (captures Gitea réelles) |
| `git-hooks/` | pre-commit (stardate, en-têtes GO-7) et pre-push (pas de force-push sur les faces publiées) ; à installer par `install-hooks.sh` |

## Build, test, gate

```bash
mix deps.get
mix compile --warnings-as-errors      # inclut boundary : une arête interdite est un warning, donc un échec
mix test                              # un seul projet, un seul mix test
mix test test/fleet/api/control_router_test.exs:42
mix gate                              # LA porte ; la chaîne fait autorité dans mix.exs
MIX_ENV=prod mix release              # _build/prod/rel/lcars_fleet, ERTS embarqué
```

`mix gate` enchaîne, dans cet ordre : format, compile strict, ExUnit, `shell_gate` (python du
bridge MCP, bats de `test/`, `git-hooks/tests`, `.claude/skills/*/tests`, `lcars_tests` de
token-saver), `lcars.contracts.check`, `lcars.topology --check`, dialyzer strict, sobelow au seuil
`High`. Chaque étape arrête la chaîne, ExUnit compris.

Ce que le gate **ne couvre pas** : `deploy/tests` (sa porte est `deploy/gate.sh`), les sondes
manuelles de `test/probes/` et `test/integration/` (listées dans `etc/README.md`), et la règle de
langue ci-dessous.

Un message de commit qui déclare « gate vert » engage un gate relancé dans ce geste.

## Architecture

**Une app, des domaines, des frontières compilées.** Chaque façade déclare ses deps et ses
exports dans `use Boundary`. Le graphe est un DAG, une dépendance va vers le bas, et une arête
montante casse la compilation. La carte des couches est **générée** depuis ces déclarations
(`mix lcars.topology`) dans `lib/fleet/README.md`, et le gate refuse toute divergence. Le seul
nom de couche vérifiable mécaniquement est `foundation` (`deps: []`) ; les autres sont une
lecture éditoriale déclarée une fois dans `lcars.topology.ex`.

Les libs sensibles sont clôturées par boundary : `ex_mcp` (mcp seul), `req`/`finch` (forge et
ses clients légitimes), `plug*` (api, observation, event_router), `phoenix_pubsub` (event_router
seul). Une référence nouvelle se déclare dans la boundary qui l'utilise.

**Boot.** `Fleet.Application` est l'unique callback OTP. L'ordre de ses enfants est l'invariant
(event_router premier, mcp avant spawner), tenu par le mur `boot.order_f8`. `max_restarts: 0` au
sommet : un domaine qui meurt tue le nœud. Les pods permanents sont lancés après le boot, par
`Fleet.Admiral.BootOrchestrator`, jamais par un superviseur.

**Seams montants.** Quatre injections de module par config, là où l'appel direct ferait un cycle :
`:spawner_launch_backend`, `:spawner_mcp_socket_provisioner`, `:mcp_pod_reaper`,
`:admiral_completion_inflight_fun`. Un seam est un point d'injection pour les tests et le seul
chemin légal vers la couche du dessus. ⚠ Boundary ne voit que les appels littéraux : un module
posé dans un attribut et appelé via une variable lui est invisible. Déclarer la dep achète
l'honnêteté du graphe, pas une vérification du défaut de seam.

**Lecture transverse.** Le récit des cinq phases d'un cycle, détection, dispatch, exécution,
complétion, revue et merge, est dans le `@moduledoc` de `Fleet.Pilot`. Son spécimen exécutable
est `test/fleet/pilot/chain_integration_test.exs`. C'est le point d'entrée pour comprendre le
workflow entier.

## Runtime et catalogue

Le code porte la mécanique, le métier est une donnée de catalogue. `Fleet.Catalogue` est la
seule autorité de son layout : une racine (`LCARS_CATALOGUE_ROOT`, défaut `priv/catalogue`), un
manifeste `catalogue.yaml` dont l'`api_version` est vérifiée au boot avant que les images ne
gèlent quoi que ce soit, et des clés par arbre qui restent des surcharges fines.

Le discriminant est un répertoire : tout ce qui est sous une racine de catalogue
(`priv/catalogue/`, `priv/catalogue-system/`, ou celle qu'un opérateur apporte) est du catalogue,
et cela seul passe par `Fleet.Catalogue`. Tout le reste de `priv/` est runtime, résolu par
`:code.priv_dir` sans molette. **Ce qu'un opérateur ne doit pas pouvoir remplacer est un contrat,
et un contrat qu'on peut remplacer ne contraint pas.** Un plancher posé dans un catalogue part avec
l'export et ne contraint plus rien, sans qu'aucun message ne le dise. Aucun étage intermédiaire
dans un catalogue ne porte ce discriminant : la racine le porte.

`Fleet.Layout` est la même autorité pour la machine : trois faces par projet, `code`, `workshop`,
`ops`, et `~/.lcars` par humain. Ces chemins sont fixés par design, pas configurables.

## Pods

Un pod est lancé par un launcher N0 choisi par `metadata.containment` du cap-profile :
`bin/bwrap_launch.sh` (défaut) projette le **sanctuaire** du pod, mounts en lecture seule, `/home`
en tmpfs, credentials bindés ; `bin/host_launch.sh` (`containment: none`) tourne sur l'hôte sans
sandbox, et un seul cap-profile canon y a droit, `admiral`, par le geste nommé `lcars admiral`.
Tout autre chemin vers `containment: none` est refusé par `SpawnAdmission`. Les deux `exec`
`bin/claude_launch.sh`, l'unique frontière vendor N1 : pas de module bridge, la frontière est le
script. Un vendor de plus, c'est un `bin/<vendor>_launch.sh` de plus, même forme d'arguments.

Le pod tourne sous l'UID de l'humain qui a lancé le BEAM, par héritage. Son `pod_dir` est
`/home/<humain>/pods/pod_<id>`, `0700`. Un pod ne charge ni hooks ni `settings.json` humain : le
sanctuaire ne monte que `plugins/` et `skills/`, et `pod_test.exs` le vérifie. Le `.claude/` de ce
dépôt est pour l'agent qui édite le dépôt, jamais pour un pod.

## Bus

`Fleet.EventRouter.Bus` est l'unique substrat broadcast/subscribe, topic `fleet.events`, registre
`priv/event_router/events.yaml`. Le webhook Gitea est un accélérateur de poll, jamais une source
de vérité. Le double saut de complétion, `work_item.completed` broker → pod puis `pod.completed`
pod → pilot enrichi, est un relais fonctionnel : ne pas le « simplifier ».

## Configuration

Trois fichiers, dans cet ordre : `config/config.exs`, `config/<env>.exs`, `config/runtime.exs`.
`runtime.exs` lit les env vars de l'humain (`~/.lcars/fleet_v2.env`) et **tout son corps est sous
`if config_env() != :test`** : hors de ce garde, `mix test` ouvrirait un port et le boot casserait.
Toute config runtime nouvelle reste dans le garde.

Toute la config vit sous `:lcars_fleet`, la clé préfixée par son domaine
(`api_http_port`, `spawner_launch_backend`). Le préfixe évite une collision réelle entre `api` et
`observation`, et le mur `config.no_legacy_config_namespace` refuse l'ancien namespace
`:fleet_<dom>`, dont le mode de défaillance est silencieux : un site oublié lit un namespace vide
et reçoit le défaut.

## Tests

`config/test.exs` pose un baseline hermétique dont toute la suite dépend : listeners éteints,
consommateurs de bus éteints, `load_event_registry: false`, `StubBackend` comme backend de spawn,
tous les `admiral_start_*` à `false`. Un test qui a besoin du vrai comportement l'instancie
lui-même avec `start_supervised` et des opts explicites ; il ne flippe pas la config globale.
Les modules de support vivent sous `test/support/<dom>/`.

La forme du corpus est tenue par des murs, pas par discipline : `tests.dirs_mirror_source`
(`lib/<x>/<y>.ex` a ses témoins sous `test/<x>/`, préfixés `<y>`), `tests.witness_naming` (un
témoin mal nommé n'est pas ramassé, et le mur le dit), `tests.corpora_on_record` (tout corpus
bats ou python est déclaré gated ou nommé hors gate). Le gate ne réclame pas un témoin par source : `test/README.md` dit
pourquoi. Les charges Gitea des témoins se calibrent sur `test/fixtures/forge/`, seule référence
non circulaire.

## Conventions

- **`@moduledoc` = contrat, `README.md` = carte.** Une carte pointe, elle ne recopie pas. Nouveau
  module, une ligne dans la carte de son domaine ; le contrat reste dans le module.
- **`use Boundary` fait partie de l'API.** Toucher deps ou exports est un changement d'API du
  domaine, motivé comme tel dans le commit. Une `forbidden reference` ne se répare jamais en
  élargissant la boundary sans comprendre pourquoi l'appel n'était pas prévu.
- **Commentaires.** Le pourquoi et l'invariant vivent inline, au présent, en forme de règle. Ce
  qui raconte l'état d'avant, la sortie d'un instrument citée comme motif, ou un pointeur vers
  `work/` ne va pas dans le code. L'histoire a deux maisons datées : le message de commit et le
  journal du chantier. L'ancre de régression (`BL-…`, `F-…`, `#NNN`) se garde. Un commentaire faux
  oriente toutes les sessions suivantes sans date ni signature : il se tue ou se corrige, jamais
  ne se laisse.
- **Logs.** `error` = perte réelle ou condition terminale ; `warning` = dégradé ou retry ; `info` =
  jalon de lifecycle ; les ticks nominaux sont silencieux. Le préfixe d'un message est le rail que
  l'opérateur greppe : un sous-module extrait loggue sous la façade de son rail.
- **En-têtes shell** au format `SOURCE: / AUTHOR: / STARDATE: / STATUS:`. La stardate est posée
  par le pre-commit de `git-hooks/` sur les fichiers stagés ; ne pas l'éditer à la main.
- **Langue.** Ce qui part avec la boîte est en anglais : prose source, `@moduledoc`, noms, logs,
  messages de commit. Ce que la boîte énonce à un opérateur suit sa langue : sortie CLI, dashboard,
  corps d'issues et de PR. Le package SP (`<catalogue>/sp_builder/**`, modop-bundles, texte des
  cap-profiles) est hors périmètre et ne se traduit jamais. Un log reste en anglais même lu par
  l'opérateur. Pas d'accents dans la prose source, parce qu'on la greppe. **Aucun mur ne tient
  cette règle, par arbitrage : un bon commentaire en français vaut mieux qu'un mauvais en
  anglais**, et l'état réel du dépôt, log de commits compris, est majoritairement en français.
  Ne pas introduire de français dans la boîte ; ne pas lancer de passe de traduction en vrac.
- `tmp/` = artefacts ExUnit `@tag :tmp_dir`, gitignoré, jamais commité.
