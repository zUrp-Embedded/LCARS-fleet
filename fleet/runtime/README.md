# LCARS Fleet Runtime

**Date** : 2026-05-09
**Dernière révision** : 2026-07-15
**Statut** : runtime v2 — app OTP unique `:lcars_fleet`, frontières vérifiées à la compilation (`boundary`)
**Référencé par** : —

Plan de contrôle OTP pour une flotte d'agents LLM faillibles. Le runtime *spawn*, surveille et
récolte des pods éphémères (un agent par rôle, sandboxé), et fait avancer le travail sur une forge
Git — **la forge EST la machine à états** : l'état vit dans les issues/PR/labels, pas en RAM. Un pod
qui meurt, un run raté, un crash du nœud ne perdent rien de porteur — la forge reste la vérité, la
tâche non signée re-dispatche. Le Bus (`Phoenix.PubSub`) est un fast-path *lossy* assumé, jamais une
source de vérité.

Implémentation Elixir/OTP. Les frontières inter-domaines sont **compilées** par `boundary` (le graphe
de dépendances est vérifié à la compilation, pas tenu par discipline) ; `mix gate` vert = compile strict
+ suite ExUnit + contrats inter-modules + Dialyzer.

## Architecture — un graphe de dépendances vérifié à la compilation

Le runtime est **une seule** app OTP. Ses ex-apps umbrella sont devenues des *domaines*, étagés en
**rings** = strates du graphe de dépendances compile réel. La règle est mécanique, pas
disciplinaire : une dépendance va vers le **bas** (ring inférieur) ou reste intra-ring. La librairie
[`boundary`](https://hex.pm/packages/boundary) l'impose **à la compilation** — une arête montante
interdite casse le build, pas une revue de code.

```mermaid
flowchart TB
    subgraph R4["Ring 4 · surface externe"]
        API["Fleet.API<br/>REST + WS"]
        OBS["Fleet.Observation<br/>deck read-only"]
    end
    subgraph R3["Ring 3 · driver forge"]
        PILOT["Fleet.Pilot<br/>dispatcher forge→workflow"]
    end
    subgraph R2["Ring 2 · coordination + policy"]
        MCP["Fleet.MCP"]
        WF["Fleet.Workflow"]
        COORD["Fleet.Coord"]
        SF["Fleet.Starfleet<br/>audit + boot"]
    end
    subgraph R1["Ring 1 · primitives pod"]
        SPAWN["Fleet.Spawner<br/>cycle de vie du pod"]
        CRED["Fleet.Credentials"]
        SPB["Fleet.SPBuilder"]
        PB["Fleet.ProjectBootstrap"]
        TQ["Fleet.TaskQueue<br/>broker de mandats"]
    end
    subgraph R0["Ring 0 · substrat"]
        BUS["Fleet.EventRouter<br/>Bus PubSub"]
        CAP["Fleet.CapProfile + Slug"]
        PRIM["primitives pures<br/>Event · GitRef · Layout · SchemaCache"]
    end

    API --> PILOT & MCP & SPAWN & SF
    OBS --> SPAWN
    PILOT --> WF & SPAWN
    WF --> SPAWN & TQ
    SF --> COORD & SPAWN
    MCP --> SPAWN & TQ
    SPAWN --> CRED & SPB & PB & TQ
    R1 --> R0
    R2 --> R0

    SPAWN -. "seam runtime" .-> MCP
    MCP -. "seam runtime" .-> PILOT

    linkStyle 19,20 stroke:#cc9944,stroke-width:2px
```

Deux besoins *montants* existent (`spawner → mcp` pour provisionner la socket MCP du pod ;
`mcp → pilot` pour le onboarding forge). Ce ne sont **pas** des dépendances compile : ils passent par
un **dispatch dynamique injecté au runtime** (module résolu par config, appelé via une variable). Le
graphe boundary le prouve — `Fleet.Spawner` n'a aucune arête vers `Fleet.MCP`, `Fleet.MCP` aucune
vers `Fleet.Pilot`. Le compilateur refuserait l'alias compile-time ; le seam reste explicite et
testable.

Le graphe complet des frontières est régénérable :

```bash
mix boundary.visualize   # → boundary/app.dot (graphviz)
```

### Frontières vendor (N0 / N1)

Tout ce qui parle à un vendor précis (Claude SDK) est **N1**, isolé derrière un launcher shell
(`bin/claude_launch.sh`). Le reste est **N0**, vendor-agnostic. Un pod tourne sandboxé (`bwrap`,
mounts RO + tmpfs `/home` + bind credentials) ou host-native selon son cap-profile. Nouveau vendor →
nouveau `bin/<vendor>_launch.sh`, même forme d'arguments ; aucun flag vendor ne fuite en N0.

## Le gate

`mix gate` est le verrou unique — CI et pré-push jouent la même chose :

```
mix gate
├─ compile --warnings-as-errors   # + le compilateur boundary (arêtes montantes = build cassé)
├─ test                            # suite ExUnit hermétique (aucune socket, aucun spawn réel)
├─ tests hors-mix                  # bridge MCP stdio (python) + tests bats des launchers (bwrap/claude)
├─ lcars.contracts.check          # contrats inter-modules — 20 invariants à cliquet
└─ dialyzer                        # strict (unmatched_returns, error_handling, extra_return…)
```

`lcars.contracts.check` mérite un mot : chaque contrat qui a un jour dérivé (un consumer resté sur
l'ancien format d'event, un handler fantôme, une frontière wire cassée) devient un **check mécanique**
qui relit le vrai code (grep/introspection) et refuse le build s'il rouvre. Une invariant promue de
« fermeture documentaire » à « fermeture mécanique » : un agent qui re-dérive casse le gate.

## Build / run

```bash
mix deps.get
mix compile --warnings-as-errors
mix test

MIX_ENV=prod mix release        # → _build/prod/rel/fleet_umbrella (self-contained, ERTS bundlé)
```

Le runtime est lancé **par un humain** via `bin/fleet_v2` (pas de `systemd User=lcars` : l'humain
lance sa flotte, les pods héritent son UID). La procédure deploy/run et le catalogue d'env vars sont
dans `etc/README.md` + `etc/fleet_v2.env.template`.

## Où lire la suite

- **`CLAUDE.md`** — guide de navigation du dépôt : rings détaillés, invariants, conventions.
- **Contrat d'un domaine** — le `@moduledoc` de sa façade `Fleet.<Domaine>` (SSoT machine-visible :
  `h Fleet.Coord`). Les `README.md` des domaines sont des **cartes** (index de modules + pointeurs),
  jamais une copie du contrat.
