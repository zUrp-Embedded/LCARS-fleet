# CLAUDE.md

**Date** : 2026-05-26
**Dernière révision** : 2026-07-21 (règle de langue : ce qui part avec la boîte est en anglais — cf. Code conventions ; migration single-app + boundary du 2026-07-12 toujours en vigueur)
**Statut** : guide runtime v2.
**Référencé par** : —

Ce fichier oriente un agent (Claude Code) dans ce dépôt : où vivent les choses, les invariants à ne pas casser, les conventions. Il ne recopie PAS ce qui a une source de vérité ailleurs (env vars, contrats de module) — il y pointe.

## Project

LCARS Fleet runtime — **app Elixir/OTP unique `:lcars_fleet`** (monolithe modulaire, frontières compilées par [boundary](https://hexdocs.pm/boundary)), couche runtime du projet LCARS (`/home/projects/LCARS/`), lancée par humain via `bin/fleet_v2`. Le contrat de chaque module vit dans son `@moduledoc` (SSoT, machine-visible via `h`/ExDoc) ; le `README.md` d'un domaine (`lib/fleet/<dom>/README.md`) est une **carte** (index + pointeurs), PAS une copie du contrat. Pour comprendre un domaine : le `@moduledoc` de sa façade `Fleet.<Dom>` (ex. `h Fleet.Coord`) + la carte. **Pour comprendre le workflow entier : le récit des 5 phases dans `Fleet.Pilot` (@moduledoc) + son spécimen exécutable `test/fleet/pilot/chain_integration_test.exs` — LE point d'entrée de lecture transverse.**

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

**Topologie (l'enforcement est dans boundary ; la carte est GÉNÉRÉE)** : la vue en couches vit dans `lib/fleet/README.md`, projetée depuis les `use Boundary` par `mix lcars.topology` (le gate refuse toute divergence — la carte ne peut pas mentir). Vocabulaire : la position d'un domaine ne se déclare JAMAIS en prose (elle EST sa déclaration boundary) ; une relation se nomme par DOMAINE (`Pilot.GateBrief`), jamais par numéro d'étage ; seul nom de couche mécaniquement vérifiable : **foundation** ≡ `deps: []` (le terme « Ring N » est banni du code — héritage `topologie-ring.md` #3.1, acceptions divergentes, cf. chantier doc-coherence 2026-07-18). Repères : `pilot` = driver forge (off sans `:step_dispatch?`), `api` REST/WS no-auth by design, `observation` read-only, launchers `bin/` sous `spawner`.

**Seams runtime ASSUMÉS** — deux natures distinctes. (1) Seams MONTANTS (injection de module via config, PAS des deps compile — boundary les rend mécaniques : un appel littéral à la place = `forbidden reference`) : `spawner→mcp` (`:mcp_socket_provisioner` — un littéral fermerait un cycle) ; `mcp→pilot` (`:forge_client`/`:project_onboard` — Pilot ∉ deps de MCP). (2) Seams d'INJECTION sur une dep compile EXISTANTE (swap d'implémentation, pas de frontière contournée) : `:coord_backend` (starfleet→coord, dep déclarée ; relais d'escalade doctrine D1 — la trace durable est l'audit log, écrit AVANT le routage ; un routage raté est loggué warning par Cat5Escalator/DriftMonitor ; défaut câblé `Fleet.Coord` par runtime.exs, `NotWiredYet` sinon) ; `:launch_backend` (hermétisme test).

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

- **Langue — la règle** : *ce qui part avec la boîte est en ANGLAIS ; ce que la boîte énonce une fois livrée suit la langue de son opérateur.* Le test est la **livraison**, pas l'emplacement dans l'arbre.
  - **Part avec la boîte → EN** (pré-requis, PAS une préférence) : toute prose qui vit dans un fichier source — commentaire inline, `@moduledoc`, `@doc`, nom de variable/fonction, message de log interne — **et les messages de commit**. RAISON : LCARS est la vitrine de sa propre thèse, « du code propre, 100% généré par des agents ». Cette thèse se vérifie dans le code ET dans le log, seuls endroits où l'on voit les arbitrages et ce qui a été refusé. Du français y réduit le nombre de gens qui peuvent auditer la démonstration.
  - **Énoncé par la boîte → langue de l'opérateur** : texte du dashboard, sortie CLI, message affiché à l'opérateur, corps des issues/commentaires/PR écrits par les agents sur la forge. Aujourd'hui le français y est **câblé en dur** ; la résolution par locale (i18n) est un chantier ouvert, non commencé.
    - **Les accents.** Interdits dans la prose source (commentaire, `@moduledoc`, `@doc`, log) : ils cassent les greps qu'un opérateur lance sur le code. **Pas dans les PAYLOADS émis** — un corps d'issue, un body de PR/review, un brief, une ligne de dashboard, un template de `priv/workflow/` sont de la **donnée texte**, comme un `.md` : ils gardent leurs accents (arbitrage user 2026-07-21). Le français accentué dans `lib/` et dans les assertions de test qui l'épinglent est donc CORRECT et ne se « corrige » pas.
    - **La sortie CLI d'un script shell, elle, est désaccentuée** (`bin/`, `etc/`) : elle vit dans un fichier source qu'on grep. Elle se **reformule** en français sans accent, jamais en stripant les accents — « détachée » → « daemon tmux », pas « detachee ».
  - **Un log reste EN, même lu par l'opérateur** (y compris les rails operator-facing type `LCARS config:`). Un log est un rail de debug qu'on grep, pas une interface : sa langue suit le code qu'il trace, pas le lecteur qui le consulte. C'est la frontière la plus facile à franchir par erreur.
  - **Hors périmètre — le package SP** (`priv/sp_builder/**`, `priv/cap_profile/canon/modop-bundles/*/sp.md`, `priv/cap_profile/canon/subagent-templates/**`, et le *texte de prompt* des `priv/cap_profile/canon/cap-profiles/*.yaml` — leurs commentaires de structure restent EN). Ce n'est ni du code ni de la sortie : c'est un **package de configuration**, cher à produire, livré validé avec la boîte mais pas lié à elle. Il est substituable — un autre opérateur apporte le sien — et il ne se traduit pas, il se **ré-écrit** : on ne calibre pas finement un comportement agentique dans une langue seconde. Sa langue est donc une propriété du package, pas de la boîte. Un agent NE TRADUIT JAMAIS un SP. Ce n'est pas une exception à la règle EN : c'est un artefact qui n'est pas dans son périmètre.
  - **Corollaire pour un agent qui édite le runtime** : n'introduire JAMAIS de français dans la boîte, et traduire vers l'EN le français qu'on touche au passage — jamais une retraduction partielle en vrac (reliquat = chantier dédié).
  - **État réel, à ne pas confondre avec la règle** : `bin/`, `etc/*.sh` et tout le shell de `test/` sont passés en EN (0 accent) ; la prose source de `lib/` et `test/` aussi. Ce qui reste d'accentué dans `lib/`, `test/` et `priv/workflow/` est de la **donnée émise** — exemptée ci-dessus, ce n'est pas un reliquat. L'inventaire se mesure, il ne se recopie pas : `grep -rlE '[éèêàçùôîûïœ]' lib test bin etc` (plancher : l'accent rate le français non accentué ; et il matche les payloads légitimes, donc il se lit, il ne se compte pas). **Aucun gate ne verrouille cette règle aujourd'hui** — un mur anti-FR ne pourra jamais porter que sur la prose source, et devra donc distinguer commentaire et littéral émis (le package SP en est hors, il n'a rien à y exempter).
- **Logger levels — doctrine** : `error` = perte réelle ou condition terminale (donnée NON gravée, event load-bearing NON émis, HALT, corruption) ; `warning` = dégradé/retry/anomalie non-fatale ; `info` = jalon de lifecycle ; les ticks nominaux sont SILENCIEUX.
- **Préfixe des messages de log** : le préfixe est le **rail opérateur** — le nom que l'opérateur greppe pour suivre un flux. Un module autonome loggue sous son dernier segment (`Poller:`, `ReadModel:`) ; un sous-module EXTRAIT d'une façade loggue sous la FAÇADE de son rail (`Emissions`/`Spawn`/`GateEngine` → `StepRunCompleter:`/`StepDispatcher:`/`StepRunConsumer:`) — extraire un cluster ne fragmente jamais la trace, et un même module n'utilise qu'UN préfixe (le nom de fonction, s'il porte du signal, descend dans le corps du message). Exceptions nommées : `AUDIT <event.type>` et `pod <id> …` (rails délibérés), `MCP.Supervisor:` (dernier segment trop générique seul), `LCARS config:` (message operator-facing du parsing env).
- Le contrat de chaque module = son `@moduledoc` (SSoT). Le `README.md` d'un domaine est une **carte qui POINTE, jamais une copie**. Nouveau module → une ligne dans la carte ; le contrat reste dans son `@moduledoc`.
- **Boundary fait partie du contrat** : toucher `use Boundary` (deps/exports) = changement d'API du domaine — le motiver dans le commit comme tel. Ne JAMAIS « réparer » une `forbidden reference` en élargissant la boundary sans comprendre pourquoi l'appel n'était pas prévu.
- En-têtes des scripts shell au format LCARS (`SOURCE: / AUTHOR: / STARDATE: / STATUS:`). La stardate est posée par la skill `/push-github` — ne pas l'éditer à la main.
- **Commentaires self-contained** (doctrine BL-058) : la CICATRICE — le POURQUOI / l'invariant / le piège — vit INLINE et autonome, en forme PRINCIPE pas histoire. L'ANCRE de régression (`#578`, `BL-055`, `F-C…`, `Z…` du chantier migration) se GARDE. Un commentaire périmé = mensonge → tuer/corriger.
- `tmp/` racine = artefacts ExUnit `@tag :tmp_dir` gitignorés — ne jamais committer.
