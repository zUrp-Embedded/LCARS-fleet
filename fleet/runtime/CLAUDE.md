# CLAUDE.md

**Date** : 2026-05-26
**Dernière révision** : 2026-07-15 (règle GRAVÉE : langue du code = anglais, sans exception — cf. Code conventions ; migration single-app + boundary du 2026-07-12 toujours en vigueur)
**Statut** : guide runtime v2.
**Référencé par** : —

Ce fichier oriente un agent (Claude Code) dans ce dépôt : où vivent les choses, les invariants à ne pas casser, les conventions. Il ne recopie PAS ce qui a une source de vérité ailleurs (env vars, contrats de module) — il y pointe.

## Project

LCARS Fleet runtime — **app Elixir/OTP unique `:lcars_fleet`** (monolithe modulaire, frontières compilées par [boundary](https://hexdocs.pm/boundary)), couche runtime du projet LCARS (`/home/projects/LCARS/`), lancée par humain via `bin/fleet_v2`. Les design-notes qui pilotent chaque domaine vivent dans `04_design-notes/`. Le contrat de chaque module vit dans son `@moduledoc` (SSoT, machine-visible via `h`/ExDoc) ; le `README.md` d'un domaine (`lib/fleet/<dom>/README.md`) est une **carte** (index + pointeurs), PAS une copie du contrat. Pour comprendre un domaine : le `@moduledoc` de sa façade `Fleet.<Dom>` (ex. `h Fleet.Coord`) + la carte. **Pour comprendre le workflow entier : le récit des 5 phases dans `Fleet.Pilot` (@moduledoc) + son spécimen exécutable `test/fleet/pilot/chain_integration_test.exs` — LE point d'entrée de lecture transverse.**

## Build / test / release

```bash
mix deps.get
mix compile --warnings-as-errors    # gate obligatoire — inclut BOUNDARY (violation d'architecture = warning = échec)

mix test                            # suite complète (plus d'umbrella : un seul projet, un seul mix test)
mix test test/fleet/api/rest_test.exs:42    # un seul test (n° de ligne) — le footgun `mix test apps/…` est MORT avec apps/

mix gate                            # gate complet : compile strict + suite + shell_gate + contracts + dialyzer
MIX_ENV=prod mix release            # _build/prod/rel/fleet_umbrella (self-contained, ERTS bundlé)
```

Elixir `~> 1.18`. Le release s'appelle **`fleet_umbrella`** (nom CONSERVÉ au collapse : `bin/fleet_v2` pointe dessus — historique, pas descriptif). La procédure deploy/run (lancement `bin/fleet_v2`, env file, install des launchers) est dans `etc/README.md` — ne pas la re-dériver.

## Architecture

### App unique + boundaries (post-collapse 2026-07-12/13)

L'ex-umbrella (14 apps) est collapsée en une app unique ; les ex-apps sont des **domaines** sous `lib/fleet/<dom>/`, et les frontières sont **COMPILÉES** par boundary — trois invariants que `mix compile` refuse de laisser violer :

1. **Direction des deps** : chaque façade `Fleet.<Dom>` déclare ses deps dans son `use Boundary`. Le graphe est un DAG (boundary interdit les cycles). Ajouter une dep inter-domaines = l'ajouter à la déclaration (geste VISIBLE en review), pas contourner.
2. **Surface d'appel** : les `exports:` de chaque boundary = la surface cross-domaine MESURÉE (~25 modules pour toute la fleet). Tout le reste est inatteignable d'un autre domaine. Élargir un export = décision d'API, pas un réflexe.
3. **Frontière libs sensibles** : `ex_mcp` (mcp seul), `req` (pilot/starfleet), `plug*` (api/observation/event_router), `phoenix_pubsub` (event_router seul) — fencées via `boundary: [default: [check: [apps: […]]]]` du mix.exs. Une réf nouvelle = à déclarer dans la boundary utilisatrice.

**Boot** : `Fleet.Application` (l'UNIQUE callback OTP) démarre les superviseurs de domaine dans un ordre qui EST l'invariant (cicatrice F8 inline : event_router premier, mcp avant spawner). Le spawn des pods permanents (BootOrchestrator) est déclenché POST-boot par la racine — après le `start_link` OK, fleet entière prouvée up (acte4 A-08 ; « post-readiness » mécanique, plus une promesse). `max_restarts: 0` au sommet = mort d'un domaine → mort du node (sémantique umbrella conservée, cf. D-17 du chantier migration). Le check `boot.order_f8` de `mix lcars.contracts.check` verrouille l'ordre.

**Strates (mémo de lecture, l'enforcement est dans boundary)** : utils Ring-0 (`Fleet.Slug`, `EnvParse`, `GitRef`, `Layout`, `Event`, `SchemaCache`, `Shutdown.Quiesce` — deps: []) ; substrat (`event_router` = Bus PubSub `fleet.events`, `cap_profile`) ; primitives pod (`credentials`, `sp_builder`, `project_bootstrap`, `task_queue` broker de mandats, `spawner` + launchers `bin/`) ; coordination (`mcp`, `workflow`, `coord`, `starfleet`) ; driver forge (`pilot` — client du core, off sans `:step_dispatch?`) ; surfaces (`api` REST/WS no-auth by design, `observation` read-only).

**Seams runtime ASSUMÉS** (injection de module via config, PAS des deps compile — boundary les rend mécaniques : un appel littéral à la place = `forbidden reference`) : `spawner→mcp` (`:mcp_socket_provisioner` — un littéral fermerait un cycle) ; `mcp→pilot` (`:forge_client`/`:project_onboard` — Pilot ∉ deps de MCP) ; `starfleet→coord` (`:coord_backend`, relais d'escalade doctrine D1 — la trace durable est l'audit log, écrit AVANT le routage ; un routage raté est loggué warning par Cat5Escalator/DriftMonitor) ; `:launch_backend` (hermétisme test).

### Frontière vendor (N0 / N1)

Tout ce qui parle à un vendor précis (Claude SDK, futur OpenAI) est **N1**, isolé derrière un launcher shell dans `bin/` (`claude_launch.sh`). **Il n'y a pas de module `fleet_claude_bridge` : la frontière vendor N1 EST le script `bin/`.** Tout le reste est **N0** (vendor-agnostic). Nouveau vendor → nouveau `bin/<vendor>_launch.sh` co-localisé, même forme d'arguments. Mélanger des flags vendor dans du code N0 casse le contrat. (Le jumeau compilé de cette frontière : le fencing boundary des libs wire, cf. ci-dessus.)

### Pod sandboxing

Un pod (process agent par rôle) est lancé par l'un des deux launchers N0, choisi par `metadata.containment` du cap-profile :
- `bin/bwrap_launch.sh` (défaut, `containment: bwrap`) — projette le **sanctuaire du pod**. RENVERSEMENT de la sandbox : bwrap ne CAGE pas l'agent pour protéger le monde de lui, il protège l'**agent du monde** (mounts RO + tmpfs `/home` + bind credentials → l'agent a EXACTEMENT ce dont il a besoin, ne peut rien casser). Le *sanctuaire* est le monde projeté POUR l'agent ; **le fichier, lui, est du code ordinaire — édité et testé (bats) comme le reste. Aucun code n'est sacré.** Un containment différent = un launcher N0 de plus (un launcher par mode, même forme d'arguments) : motif d'extension propre, PAS une intouchabilité.
- `bin/host_launch.sh` (`containment: none`) — même mécanique tmux **sans** sandbox : le pod tourne sur l'hôte *comme* l'humain (`HOME` = home réel → `~/.claude` natif). Pour l'architecte-interactif / starfleet.

Les deux `exec` le launcher vendor `claude_launch.sh`. Le pod tourne *comme* l'humain par **héritage d'UID** : le BEAM est lancé par l'humain → le Port du pod hérite l'UID (pas de `systemd-run --uid`, pas de drop). Le pod_dir est **`/home/<humain>/pods/pod_<id>`** (per-humain, `0700`, isolé par l'ownership OS — pas un dossier partagé, pas sous `/tmp` que le tmpfs bwrap orphelinerait). bwrap exige les syscalls `unshare`/`mount`/`setns`/`pivot_root` → le **container** doit les accorder (cap-add/seccomp).

### Bus d'événements

`Fleet.EventRouter.Bus` (Phoenix.PubSub) est l'unique substrat broadcast/subscribe. Les domaines publient sur `fleet.events` et consomment via `subscribe/1`. Le Bus est le fast-path LOSSY ; la vérité durable vit dans le substrat forge+poll (doctrine D1). ⚠ Le « double-hop » de complétion (`work_item.completed` broker→pod, puis `pod.completed` pod→pilot enrichi) est un RELAIS fonctionnel, pas une redondance — cicatrice dans `pod.ex`, ne pas « simplifier ». Le webhook `gitea.*` est un ACCÉLÉRATEUR de poll (hint coalescé, Z6e), jamais une source de vérité. En `:test`, l'hermétisme vient des consumers coupés + `load_event_registry: false`.

## Configuration layering

Trois fichiers de config, évalués dans cet ordre :

1. `config/config.exs` — défauts compile-time.
2. `config/<env>.exs` — `test.exs` pose le baseline hermétique (StubBackend, consumers off, `load_event_registry: false`, `start_listener: false`).
3. `config/runtime.exs` — config de boot, lit les env vars de l'env humain (`~/.lcars/fleet_v2.env`, posé par `bin/fleet_v2`). **C'est la source de vérité des env vars** ; le catalogue complet est dans `etc/fleet_v2.env.template`.

**Invariant critique** dans `config/runtime.exs` : tout le fichier est wrappé dans `if config_env() != :test do … end`. Sans ce garde, `mix test` évalue runtime.exs, met `start_listener: true`, et Cowboy tente de bind le port → crash du boot. Toute config runtime ajoutée reste DANS le garde.

**Les atoms de config `:fleet_<dom>` sont LEGACY et VALIDES** (`config :fleet_spawner, …` marche sans app OTP réelle — la config ETS est keyed par atom ; décision D-07 du chantier migration). Ne pas les « corriger » en `:lcars_fleet` au détour d'un patch — migration de namespace = chantier dédié si un jour.

Plusieurs env vars ont été **retirées** (plus aucun lecteur, ou dangereuses) — ne pas les réintroduire : le transport MCP HTTP-loopback partagé (remplacé par une socket AF_UNIX par-pod), le vault de credentials, le routing par label, le drop-UID / TmuxBackend hors-bwrap.

## Test hermeticity

`config/test.exs` impose un baseline hermétique dont les autres tests dépendent. Ne pas l'affaiblir :

- `fleet_api, start_listener: false` — les tests REST passent par `Plug.Test`, WS par callbacks Cowboy directs, jamais une vraie socket.
- consumers off (`start_*: false`) + `load_event_registry: false` — pas de broadcast Bus parasite en async. (Même logique : `subscribe_gitea` du Poller est opt-in, défaut false, câblé true par `step_children!` seul.)
- `fleet_spawner, launch_backend: StubBackend` — pas de vrai spawn bwrap ; les tests le re-posent en `setup` et **ne le suppriment pas** en `on_exit`.
- `fleet_starfleet, start_audit_consumer: false` + `start_boot_orchestrator: false`, `fleet_spawner, start_publish_consumer: false` — un test qui en a besoin démarre manuellement avec des opts isolés.

Quand un test a besoin du vrai backend, il l'instancie directement (`start_supervised` avec args explicites), il ne flippe pas la config globale. Les modules de support vivent sous `test/support/<dom>/` (compilés via `elixirc_paths(:test)`).

## Code conventions

- **Langue du code = ANGLAIS, sans exception** (pré-requis, PAS une préférence). Toute prose qui VIT dans un fichier source — commentaire inline, `@moduledoc`, `@doc`, docstring, nom de variable/fonction, message de log/rail opérateur — est en **anglais**. Le français est STRICTEMENT réservé au contenu rendu pour l'**œil de l'humain final** : corps des commentaires/issues/PR postés sur la forge, texte du dashboard, message user-facing affiché à l'opérateur. Un log interne reste EN (debug/rail, pas l'interface). **EXCEPTION GRAVÉE — les fichiers de SYSTEM-PROMPT / doctrine d'agent** (`priv/sp_builder/**`, `priv/cap_profile/canon/modop-bundles/*/sp.md`, `priv/cap_profile/canon/subagent-templates/**`, `priv/cap_profile/canon/cap-profiles/*.yaml` côté *contenu* SP) **restent en FRANÇAIS, définitivement** : le SP est LE point de contrôle critique des agents — l'humain (francophone) doit pouvoir le lire et le CALIBRER PRÉCISÉMENT → langue maternelle obligatoire. Ce n'est PAS du code (ni compilé, ni logique runtime), c'est la **surface de contrôle humain sur le comportement agentique**. Un agent NE TRADUIT JAMAIS un SP en EN (ce serait casser le contrôle user) ; le futur gate anti-FR DOIT exempter ces chemins. (NB : les cap-profile `.yaml` restent EN pour leurs commentaires de DONNÉE/structure — seul le *texte de prompt* injecté est FR.) RAISON, non négociable : LCARS est la **vitrine de sa propre thèse — « du code propre, 100% généré par des agents »** — donc un commentaire français dans `lib/`/`test/`/`bin/` n'est pas un détail de style, c'est un **contre-exemple signé de la main de l'auteur** qui falsifie la thèse. Corollaire : un agent qui édite le runtime N'INTRODUIT JAMAIS de français dans le code, et traduit vers l'EN tout FR qu'il touche au passage (jamais une retraduction partielle en vrac — reliquat = chantier dédié). L'i18n du user-facing est un chantier SÉPARÉ et ULTÉRIEUR (d'abord un projet qui tourne). Un gate `shell_gate` rejettera mécaniquement le FR-dans-le-code — **mur, pas consigne** (la doctrine LCARS appliquée à LCARS).
- **Logger levels — doctrine** : `error` = perte réelle ou condition terminale (donnée NON gravée, event load-bearing NON émis, HALT, corruption) ; `warning` = dégradé/retry/anomalie non-fatale ; `info` = jalon de lifecycle ; les ticks nominaux sont SILENCIEUX.
- **Préfixe des messages de log** : le préfixe est le **rail opérateur** — le nom que l'opérateur greppe pour suivre un flux. Un module autonome loggue sous son dernier segment (`Poller:`, `ReadModel:`) ; un sous-module EXTRAIT d'une façade loggue sous la FAÇADE de son rail (`Emissions`/`Spawn`/`GateEngine` → `StepRunCompleter:`/`StepDispatcher:`/`StepRunConsumer:`) — extraire un cluster ne fragmente jamais la trace, et un même module n'utilise qu'UN préfixe (le nom de fonction, s'il porte du signal, descend dans le corps du message). Exceptions nommées : `AUDIT <event.type>` et `pod <id> …` (rails délibérés), `MCP.Supervisor:` (dernier segment trop générique seul), `LCARS config:` (message operator-facing du parsing env).
- Le contrat de chaque module = son `@moduledoc` (SSoT). Le `README.md` d'un domaine est une **carte qui POINTE, jamais une copie**. Nouveau module → une ligne dans la carte ; le contrat reste dans son `@moduledoc`.
- **Boundary fait partie du contrat** : toucher `use Boundary` (deps/exports) = changement d'API du domaine — le motiver dans le commit comme tel. Ne JAMAIS « réparer » une `forbidden reference` en élargissant la boundary sans comprendre pourquoi l'appel n'était pas prévu.
- En-têtes des scripts shell au format LCARS (`SOURCE: / AUTHOR: / STARDATE: / STATUS:`). La stardate est posée par la skill `/push-github` — ne pas l'éditer à la main.
- **Commentaires self-contained** (doctrine BL-058) : la CICATRICE — le POURQUOI / l'invariant / le piège — vit INLINE et autonome, en forme PRINCIPE pas histoire. L'ANCRE de régression (`#578`, `BL-055`, `F-C…`, `Z…` du chantier migration) se GARDE. Un commentaire périmé = mensonge → tuer/corriger.
- `tmp/` racine = artefacts ExUnit `@tag :tmp_dir` gitignorés — ne jamais committer.
