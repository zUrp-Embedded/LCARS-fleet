# fleet_mcp

**Date** : 2026-05-18
**Dernière révision** : 2026-07-07 (resync D2 contre le code : ring 2, PodSocketRegistry + sonde readiness documentés, knobs de délégation ajoutés ; éclatement PodTools → WorkItems + Delegation, dispatch conservé)
**Statut** : implémenté — serveur MCP pod-facing (`get_work_item` / `submit_result`)
**Référencé par** : `04_design-notes/` (ring4/fleet_mcp)

Serveur MCP LCARS (Ring 2) — frontière vendor `mcp_*` (ADR-C) : wrappe le SDK
`ex_mcp` derrière un contrat opaque et expose aux pods les outils MCP du runtime.

## Modules

- `Fleet.MCP.PodTools` — la **table de routage** des outils MCP pod-facing : schémas
  `deftool` + dispatch `handle_tool_call/3` (guards d'arguments, refus typés
  `:invalid_arguments`/`:pod_id_required`/`:project_required`, format de contenu MCP
  `json`/`text`). Fonctions pures, réutilisables hors transport ; l'identité du pod arrive
  par le `state` (`%{pod_id: ...}`), jamais par les arguments. Reste wrappé derrière
  `use ExMCP.Server` pour le DSL `deftool` / `json` / `text`. Les métiers vivent dans deux
  sous-modules aux consommateurs disjoints :
  - `Fleet.MCP.PodTools.WorkItems` — drive work-item (tout pod) : `get_work_item` (le pod
    tire son brief depuis la TaskQueue), `submit_result` (le pod rend son livrable,
    corrélateur `work_item_id` obligatoire + mapping des refus typés).
  - `Fleet.MCP.PodTools.Delegation` — délégation forge (architecte only) : `create_issue`
    (l'arch délègue une implémentation), `create_project` (l'arch onboard un projet neuf),
    `import_project` (WS4 — l'arch importe un repo EXISTANT, sans toucher à `main`),
    `get_issue_status` (l'arch suit une délégation) + la gate `require_architect` commune.
- `Fleet.MCP.PodSocketAcceptor` — accepteur d'**une** socket AF_UNIX par pod. Un pod = un
  process = une socket : toute ligne reçue vient de CE pod (son `pod_id` est l'état immuable
  de l'accepteur, porté au démarrage). Décode le JSON-RPC newline-framed et dispatche les
  `tools/call` vers `PodTools.handle_tool_call/3`. **Chaque connexion acceptée est servie dans
  sa propre `Task`** (via `Fleet.MCP.ConnectionTaskSupervisor`, socket transférée par
  `controlling_process`) et l'accepteur re-`accept` aussitôt : un handler lent (ex. un appel
  forge qui pend) ne gèle PAS le pod — les connexions suivantes sont servies en parallèle, pas
  coincées dans le backlog kernel (sinon `readline` timeout côté pont, cf. test « accepteur
  CONCURRENT »). Contrat wire : buffer de ligne 1 MiB (une ligne plus longue arrive tronquée) ;
  ligne JSON invalide → réponse `-32700` + warning, JAMAIS avalée en silence ; `tools/call`
  > 5 s loggé LENT (forensics côté serveur).
- `Fleet.MCP.ConnectionTaskSupervisor` — `Task.Supervisor` (`restart: :temporary`,
  `max_children: 32`) des workers de connexion, un par connexion acceptée. Sépare le SERVICE
  d'une connexion (potentiellement lent) de la BOUCLE d'`accept` ; la borne E4 refuse (loggé)
  la connexion en trop d'un bridge qui fuit, au lieu d'accumuler tasks+FDs sans limite.
- `Fleet.MCP.PodSocketRegistry` — Registry unique (clé = `pod_id` → accepteur, noms `:via`) :
  résolution idempotente des accepteurs, démarré AVANT le DynamicSupervisor qui s'y enregistre.
- `Fleet.MCP.PodSocketSupervisor` — DynamicSupervisor des accepteurs (fan-out un-par-pod) +
  API de cycle de vie pour le spawner (`ensure_pod_socket` / `release_pod_socket`) +
  `base_dir/0`/`socket_path/1` (chemins).
- `Fleet.MCP.Server` — **garde de boot ADR-C** : `start_link/1` refuse
  (`{:error, :forbidden_in_pod}`) si `boot_environment == :pod` → `fleet_mcp` ne boote
  jamais côté pod. L'ancienne API husk `register_channel`/`list_channels` (push channel) est
  **retirée** (morts chantier 7, 0 appelant prod).
- `Fleet.MCP.Supervisor` / `Fleet.MCP.Application` — supervision de l'app (`:one_for_one`,
  `max_restarts: 3` / `max_seconds: 60`). `Fleet.MCP.Supervisor.pod_facing_status/0` = état
  LIVE du substrat pod-facing pour la readiness (consommé par `Fleet.API.Readiness`) : sonde le
  PROCESS réel + les fichiers socket sur disque (F6 anti-vert-creux : plus de socket-fichiers
  que d'acceptors vivants = pods sourds → `:degraded`, jamais un vert de config).

## Identité du pod — l'identité EST le canal (R9)

Le transport pod-facing est une **socket AF_UNIX par pod** : chaque pod a la sienne, montée
dans son seul sandbox. Donc « quelle socket reçoit » = « quel pod » — le `pod_id` est porté
par l'accepteur (du nom du socket), il n'est **jamais** lu du wire. Il n'y a plus rien à
prouver : pas de capability à présenter, pas de `pod_id` à comparer. Un pod ne peut pas lire
le brief d'un autre ni clôturer sa tâche, par **construction** (il n'a pas l'autre socket) —
même un `_lcars_pod_id` forgé dans les arguments est ignoré (le central lit `state.pod_id`).

> Contexte : l'ex-transport HTTP loopback était PARTAGÉ par tous les pods → le `pod_id` y était
> devinable (déterministe `<repo>-issue-<n>-<role>`), d'où une **capability** par-pod (secret
>256 bits vérifié serveur-side) pour fermer le trou d'usurpation. La socket per-pod rend cette
> capability inutile : le canal discrimine. HTTP loopback + capability **retirés**.

`handle_tool_call/3` lit `state.pod_id` directement pour `get_work_item`/`submit_result`. Le `pod_id`
absent du state = anomalie de l'accepteur → `:pod_id_required` (fail-closed, jamais d'accès anonyme).

## API socket (seam `fleet_spawner → fleet_mcp`)

`Fleet.MCP.PodSocketSupervisor` expose au spawner :

- `ensure_pod_socket(pod_id) :: {:ok, socket_path} | {:error, _}` — démarre l'accepteur de ce
  pod (crée le listener + le fichier socket) et rend le **chemin host**. Idempotent (re-appel =
  même chemin, pas de doublon). Le fichier existe au retour (le bind bwrap échouerait sinon).
- `release_pod_socket(pod_id) :: :ok` — arrête l'accepteur ET **`File.rm`** le fichier socket
  (fermer le socket libère le FD, PAS le fichier → fuite sinon). Idempotent.

Chemin : `<base>/<pod_id>/sock` (`base` = config `:sock_base`, défaut `/run/lcars/mcp`). Le dir
per-pod + le filename court tiennent le chemin sous la limite `sun_path` (108 octets) — même
structure que la socket-dir tmux des pods.

## Autorisation architecte — tools privilégiés (gate serveur-side)

`create_project`, `import_project`, `create_issue` et `get_issue_status` sont des actes d'**architecte** :
créer/importer un repo forge, écrire/pousser dans `/home/projects`, déléguer, suivre une délégation. Le garde
`require_architect/1` (dans `Fleet.MCP.PodTools.Delegation`, appliqué AVANT toute mécanique forge)
résout le **rôle** depuis l'identité du canal (`state.pod_id` → registre du
Spawner, `Fleet.Spawner.pod_info`, seam test `:pod_resolver`) **puis** exige `architect`. Le rôle
vient du spawn, jamais d'un champ du wire. Tout rôle autre (engineer, reviewer, rôle nil/inconnu) →
`{:error, :forbidden_not_architect}` ; pod absent du registre → `:pod_unknown` ; state sans pod_id →
`:pod_id_required`. Fail-closed : aucun cas ne retombe sur un accès autorisé.

## Outils MCP (pod-facing)

- `get_work_item` — le pod récupère son brief (corrélé `pod_id` du canal).
- `submit_result` — le pod soumet son livrable (`payload`) ; **`work_item_id` OBLIGATOIRE** = le `work_item_id`
  rendu par `get_work_item` (le broker corrèle sur CE brief précis, jamais « la dernière active » du pod —
  verrou orthogonal au transport). work_item_id absent → `:work_item_id_required` ; ≠ brief actif → `:work_item_id_mismatch`.
- `create_issue` (délégation, **architecte only**) — crée l'issue forge **prête pour le poller**
  (`Fleet.Pilot.ForgeClient.create_issue`, dispatch runtime). Gate `require_architect`. Fail-closed :
  worker → `:forbidden_not_architect` ; pod inconnu → `:pod_unknown` ; token de rôle absent →
  `:role_token_unavailable` (jamais en système). auteur=arch (token du compte de rôle), **assignee=humain**
  owner (login OS), puis **STOP** (le poller prend le relais). Seams test : `:forge_client`, `:pod_resolver`.
- `create_project` (onboarding, **architecte only**) — `Fleet.Pilot.ProjectOnboard.onboard/2`
  (repo forge + dual-worktree `main`/`work/ops` + scaffold + push). Gate `require_architect` **avant**
  toute création/écriture. Le repo créé est RENDU dans le résultat (`repo`/`delegation_target`) → l'arch
  le passe explicitement à `create_issue`/`get_issue_status`. Seams test : `:project_onboard`, `:pod_resolver`.
- `import_project` (WS4, **architecte only**) — `Fleet.Pilot.ProjectOnboard.import/2` (repo EXISTANT :
  MÊME dual-worktree/gate, mais `main` reste INTACT — pas de création/scaffold). Gate `require_architect`.
  Préconditions fail-loud côté `ProjectOnboard` (déjà dans l'org, branche par défaut `main`). `full_name`
  = `"owner/name"`. Même contrat de retour que `create_project` (`status: "imported"`). Seams test :
  `:project_onboard`, `:pod_resolver`.
- `get_issue_status` (suivi, **architecte only**) — lit l'état d'un issue (issue + PR) du repo passé
  en `project` (**REQUIS** ; sans lui → `:project_required`, jamais d'état lu sur le mauvais projet). Gate
  `require_architect`. Lecture seule (`ForgeClient`). Seams test : `:forge_client`, `:pod_resolver`.

NB **bridge stdio** (`bin/fleet_mcp_stdio_bridge.py`) : sert `initialize`/`tools/list` localement et
forwarde chaque `tools/call` au central. Sa surface de tools (`TOOLS`, dérivée du rôle) reste un miroir
manuel des schémas du central. Le câblage du pont vers la socket per-pod (et le provisioning spawner
`ensure_pod_socket`) vit dans le sous-bloc adjacent, PAS ici.

## Configuration

- `:fleet_mcp, :sock_base` — racine des sockets pod-facing (défaut `/run/lcars/mcp` ; surchargé
  par l'env `LCARS_FLEET_MCP_SOCK_BASE` dans `config/runtime.exs` — fleet lancée par un humain,
  `/run/lcars` n'est pas writable sans privilège → base sous son home).
- `:fleet_mcp, :boot_environment` — environnement injecté au boot du serveur (`:pod` → refus).
- `:fleet_mcp, :pod_resolver` — seam test : `pod_id → {:ok, %{role: role}}`. Défaut = dispatch runtime
  vers `Fleet.Spawner.pod_info/1`.
- `:fleet_mcp, :forge_client` — seam : client forge (défaut `Fleet.Pilot.ForgeClient`, dispatch
  runtime — pas de dep compile-time fleet_pilot).
- `:fleet_mcp, :project_onboard` — seam : séquence d'onboarding projet (défaut
  `Fleet.Pilot.ProjectOnboard`, dispatch runtime).
- `:fleet_mcp, :delegation_org` — org forge des projets onboardés (défaut `"fleet"`).

## Frontière vendor

`mcp_*` = N1 (ADR-C) : le SDK `ex_mcp` est wrappé derrière `Fleet.MCP.PodTools`
(`use ExMCP.Server`, tools `get_work_item`/`submit_result`) pour les schémas + le format de contenu.
Le **transport** pod-facing est une socket AF_UNIX per-pod gérée en `:gen_tcp` brut
(`Fleet.MCP.PodSocketAcceptor`) — ExMCP ne fournit pas de socket per-pod ; bascule du SDK de
schéma (Hermes) possible sans toucher les consommateurs.
