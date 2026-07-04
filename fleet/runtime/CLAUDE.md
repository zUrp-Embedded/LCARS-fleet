# CLAUDE.md

**Date** : 2026-05-26
**Dernière révision** : 2026-07-04 (expurgé : data dupliquée sortie vers ses sources, fonction primaire = guide de navigation)
**Statut** : guide runtime v2.
**Référencé par** : —

Ce fichier oriente un agent (Claude Code) dans ce dépôt : où vivent les choses, les invariants à ne pas casser, les conventions. Il ne recopie PAS ce qui a une source de vérité ailleurs (env vars, contrats d'app) — il y pointe.

## Project

LCARS Fleet runtime — umbrella Elixir/OTP, couche runtime du projet LCARS (`/home/projects/LCARS/`), lancée par humain via `bin/fleet_v2`. Les design-notes qui pilotent chaque app vivent dans `04_design-notes/` (une par « chantier »). Chaque app `apps/fleet_*/` correspond à un chantier numéroté, et **son `README.md` est le contrat canonique** (sous-modules, API publique, knobs de config, dépendances). Pour comprendre une app, lis son README d'abord.

## Build / test / release

```bash
mix deps.get
mix compile --warnings-as-errors    # gate obligatoire

mix test                            # umbrella complet
( cd apps/fleet_api && mix test )   # une app — ⚠ PAS `mix test apps/fleet_api` depuis la racine
                                    #   (Mix n'y trouve aucun fichier de test → 0 lancé = faux-vert)
( cd apps/fleet_api && mix test test/fleet/api/rest_test.exs:42 )   # un seul test (n° de ligne)

MIX_ENV=prod mix release            # _build/prod/rel/fleet_umbrella (self-contained, ERTS bundlé)
```

Elixir `~> 1.18`. Le release `fleet_umbrella` embarque toutes les apps en `:permanent` (cf. `mix.exs`). La procédure deploy/run (lancement `bin/fleet_v2`, env file, install des launchers) est dans `etc/README.md` — ne pas la re-dériver.

## Architecture

### Umbrella + rings

Les apps `apps/fleet_*/` (chacune un OTP app normal, `lib/fleet/<name>/application.ex` = son superviseur) sont étagées en **rings** (couches de substrat, déclarées dans chaque README). De bas en haut :

- **Ring 0 — substrat OS** : lancement per-humain via `bin/fleet_v2` (dans `etc/` + `bin/`, pas une app). Modèle = **l'humain lance sa fleet** (pas de service systemd `User=lcars`).
- **Ring 1 — primitives pod + frontière vendor** : `fleet_spawner`, `fleet_credentials`, `fleet_cap_profile`, `fleet_sp_builder`, `fleet_project_bootstrap` + les launchers shell `bin/` (voir Pod sandboxing).
- **Ring 2 — backbone d'orchestration** : `fleet_event_router` (bus PubSub `fleet.events`), `fleet_task_queue` (broker de mandats `get_task`/`submit_result`), `fleet_pilot` (dispatcher forge→pipeline, off par défaut — **client du core**, dépend du Ring 3 `fleet_pipeline`). Le read-model/observabilité est tenu par `fleet_observation` (l'ancienne app `fleet_task_monitor`, dormante, a été supprimée le 2026-07-04).
- **Ring 3 — coordination + policy** : `fleet_coord`, `fleet_pipeline`, `fleet_starfleet` (audit), `fleet_mcp`.
- **Ring 4 — surface externe** : `fleet_api` (REST + WS, **no-auth par design** — la frontière est l'isolation réseau/container, cf. `Fleet.API.Rest` § Auth) ; `fleet_observation` (observation deck read-only — dépend vers le bas, rien du core ne dépend de lui).

Les ports et chemins concrets sont posés par `bin/fleet_v2` / lus dans `config/runtime.exs` — pas listés ici.

### Frontière vendor (N0 / N1)

Tout ce qui parle à un vendor précis (Claude SDK, futur OpenAI) est **N1**, isolé derrière un launcher shell dans `bin/` (`claude_launch.sh`). **Il n'y a pas d'app `fleet_claude_bridge` : la frontière vendor N1 EST le script `bin/`.** Tout le reste est **N0** (vendor-agnostic). Nouveau vendor → nouveau `bin/<vendor>_launch.sh` co-localisé, même forme d'arguments. Mélanger des flags vendor dans du code N0 casse le contrat.

### Pod sandboxing

Un pod (process agent par rôle) est lancé par l'un des deux launchers N0, choisi par `metadata.containment` du cap-profile :
- `bin/bwrap_launch.sh` (défaut, `containment: bwrap`) — sandbox bwrap (mounts RO + tmpfs `/home` + bind credentials). **Ne JAMAIS éditer `bwrap_launch.sh` (sanctuaire)** : un nouveau besoin de containment = un nouveau launcher N0 co-localisé, même forme d'arguments.
- `bin/host_launch.sh` (`containment: none`) — même mécanique tmux **sans** sandbox : le pod tourne sur l'hôte *comme* l'humain (`HOME` = home réel → `~/.claude` natif). Pour l'architecte-interactif / starfleet.

Les deux `exec` le launcher vendor `claude_launch.sh`. Le pod tourne *comme* l'humain par **héritage d'UID** : le BEAM est lancé par l'humain → le Port du pod hérite l'UID (pas de `systemd-run --uid`, pas de drop). Le pod_dir est **`/home/<humain>/pods/pod_<id>`** (per-humain, `0700`, isolé par l'ownership OS — pas un dossier partagé, pas sous `/tmp` que le tmpfs bwrap orphelinerait). bwrap exige les syscalls `unshare`/`mount`/`setns`/`pivot_root` → le **container** doit les accorder (cap-add/seccomp).

### Bus d'événements

`Fleet.EventRouter.Bus` (Phoenix.PubSub) est l'unique substrat broadcast/subscribe. Les apps publient sur `fleet.events` et consomment via `subscribe/1`. En `:test`, l'hermétisme vient des consumers coupés + `load_event_registry: false` (le Bus skip la validation), pas d'un backend de remplacement (cf. Test hermeticity).

## Configuration layering

Trois fichiers de config, évalués dans cet ordre :

1. `config/config.exs` — défauts compile-time (backend event = PubSub en prod/dev).
2. `config/<env>.exs` — `test.exs` pose le baseline hermétique (StubBackend, consumers off, `load_event_registry: false`, `start_listener: false`).
3. `config/runtime.exs` — config de boot, lit les env vars de l'env humain (`~/.lcars/fleet_v2.env`, posé par `bin/fleet_v2`). **C'est la source de vérité des env vars** ; le catalogue complet (noms + valeurs par défaut) est dans `etc/fleet_v2.env.template`.

**Invariant critique** dans `config/runtime.exs` : tout le fichier est wrappé dans `if config_env() != :test do … end`. Sans ce garde, `mix test` évalue runtime.exs (Mix le lit dans tous les envs), met `start_listener: true`, et Cowboy tente de bind le port → crash du boot umbrella. Toute config runtime ajoutée reste DANS le garde, sauf si tu veux vraiment l'éval en test.

Plusieurs env vars ont été **retirées** (plus aucun lecteur, ou dangereuses) — ne pas les réintroduire : le transport MCP HTTP-loopback partagé (remplacé par une socket AF_UNIX par-pod), le vault de credentials, le routing par label, le drop-UID / TmuxBackend hors-bwrap. Le modèle actuel (socket par-pod, UID runtime hérité) les remplace.

## Test hermeticity

`config/test.exs` impose un baseline hermétique dont les autres tests dépendent. Ne pas l'affaiblir :

- `fleet_api, start_listener: false` — les tests REST passent par `Plug.Test`, WS par callbacks Cowboy directs, jamais une vraie socket.
- consumers off (`start_*: false`) + `load_event_registry: false` — pas de broadcast Bus parasite en async.
- `fleet_spawner, launch_backend: StubBackend` — pas de vrai spawn bwrap ; les tests le re-posent en `setup` et **ne le suppriment pas** en `on_exit` (d'autres tests comptent sur le défaut).
- `fleet_starfleet, start_audit_consumer: false` + `start_boot_orchestrator: false`, `fleet_spawner, start_publish_consumer: false` — consumers off par défaut ; un test qui en a besoin le démarre manuellement avec des opts isolés.

Quand un test a besoin du vrai backend, il l'instancie directement (`start_supervised` avec args explicites), il ne flippe pas la config globale.

## Code conventions

- Le `README.md` de chaque app est le **contrat** (sous-modules, API publique, knobs de config, dépendances). Quand tu ajoutes un module, mets à jour le README.
- En-têtes des scripts shell au format LCARS (`SOURCE: / AUTHOR: / STARDATE: / STATUS:`). La stardate est posée par la skill `/push-github` — ne pas l'éditer à la main avant de pousser.
- **Commentaires self-contained** : un commentaire doit se comprendre en lisant CE fichier seul — pas de tag cryptique (`#578`, `BL-050`, codes de grille…) ni de pointeur vers les specs. Inline le POURQUOI / l'invariant / le piège en clair ; le code EST la doc (lecteur primaire = un agent). Porte le sens, pas une coordonnée d'incident.
- `apps/*/tmp/` = artefacts ExUnit `@tag :tmp_dir` gitignorés — ne jamais committer.
