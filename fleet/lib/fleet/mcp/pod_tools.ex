defmodule Fleet.MCP.PodTools do
  @moduledoc """
  Pod-facing MCP TOOL layer — the RPCs the pod (Claude MCP client) calls to
  talk to the fleet, without scraping or keyboard injection. THIS module is the
  **routing table**: the `deftool` schemas + the `handle_tool_call/3` dispatch
  (argument guards, typed refusals, MCP content format `json`/`text`).

  Schema SDK vs transport (swappable): the `deftool` schemas come from the `ExMCP`
  SDK, but the pod-facing TRANSPORT is NOT ExMCP's — it is our own per-pod AF_UNIX
  `:gen_tcp` socket (`Fleet.MCP.PodSocketAcceptor`; ExMCP offers no per-pod socket).
  So the schema SDK is swappable (e.g. Hermes) without touching the transport or the
  tool consumers.

  The domain logic lives in two sub-modules with disjoint consumers:

    * `Fleet.MCP.PodTools.WorkItems` — work-item drive (every pod):
      - `get_work_item`  : IN  channel — the pod PULLs its brief from `Fleet.TaskQueue`.
        `{"done": true}` when there is no brief (the pod stops). Otherwise
        `{"done": false, "work_item": {"work_item_id", "issue_id", "role", "brief", ...}}`.
      - `submit_result` : OUT channel — the pod PUSHes its deliverable (`payload`),
        `work_item_id` MANDATORY (correlator).
    * `Fleet.MCP.PodTools.Delegation` — forge delegation (architect only, server-side
      `require_architect` gate):
      - `issue_create`     : the arch delegates an implementation brick (forge issue).
      - `project_create`   : the arch starts a fresh project (repo + three faces + scaffold).
      - `project_install`   : the arch imports an EXISTING forge repo (three faces, main content
        intact — ≠ create_project which starts a fresh one).
      - `project_revise_card` : revises an existing project's validation card (BL-6-29 — the
        engraved declaration gets a tracked revision path; future tickets only).
      - `project_close`    : parks a project (BL-6-30 — marker issue holds the state, the
        poller skips the repo; disk + forge intact, `project_open` reopens).
      - `project_adopt`    : publishes a DISK-only project to the forge (BL-6-32 — the inverse
        of import; local content never overwritten).
      - `project_import` : repatriates a GitHub/GitLab repo through the adoption gate (BL-6-31).
      - `project_publish`   : phase-2 publish of a project to its linked external forge as a rolling
        PR/MR (ASYNC — returns queued, outcome on the bus; the token stays host-side).
      - `issue_status` : the arch tracks a delegation (issue + PR, `outcome`).
      - `escalation_list` : the arch reads its escalation inbox (awaits-arch issues).
      - `issue_list`      : the arch reads its project's open-ticket board (BL-6-28: the
        write channel existed without its read half — a radio that transmits but not receives).
      - `issue_get`        : the arch reads ONE ticket in full (body + comment thread).
      - `issue_comment`    : the arch replies on an in-flight ticket (in the role's name).
      - `dependency_add` / `dependency_remove` : the arch states the order between two tickets
        AFTER creation. The result SAYS what it does not do — on a ticket already in flight the
        edge blocks the CLOSURE, it does not stop the run.
      - `issue_retire`     : the arch abandons a ticket with NO replacement — the live PR is
        closed, the dependents are told and RELEASED (a supersede carries its edges, a
        retirement lifts them), `stage/retired`.
      - `project_list`    : the READ half of the project surface — the onboarder could destroy a
        project it had no way to enumerate.
      - `emergency_stop`   : the brake. Mass CLOSE of everything in flight, fleet-wide (never a
        kill: killing pods leaves the tickets open and the poller re-dispatches).
      - `project_open`     : the inverse of `project_close` (the parking marker is lifted).
      - `project_delete`   : destroys a project. Disarmed by deployment flag.
      - `card_list` : the validation cards a project can be onboarded against.
      - `catalogue_list` : the catalogues this box SERVES — the offer a card is picked FROM
        (`project_create` refuses a catalogue that is not installed here).
      - `forge_list`        : the human's registered external forges (the publish pool) — read-only.
      - `forge_link`      : link a project to a forge (writes its publish binding) — reversible intent,
        not a push (the human's `lcars approve` + PR merge stay the gates).

  ⚠ The list above is a READING MAP and it has drifted before (three tools were missing when
  `issue_retire` was added). The authority is the `deftool` set itself, and the gate reads it from
  the AST: `mcp.tools_gated` in `lcars.contracts.check` refuses any tool that is neither pod-scoped
  nor role-gated, and any dispatch clause with no schema. A tool absent from this prose is a stale
  comment; a tool absent from that check does not exist.

  Server-side mediation: the pod never touches the TaskQueue nor the forge directly
  (the queue, its schema, its storage stay invisible to the pod); everything goes through
  these tools. Identity (which pod) is the CHANNEL: `state.pod_id` is carried by the socket
  acceptor (one pod = one socket), never read from the wire — the clauses here check its
  presence (`:pod_id_required`, fail-closed), the architect gate lives in `Delegation`.

  The `Fleet.TaskQueue` broker itself broadcasts `%Fleet.Event{work_item.completed}` on
  `fleet.events` — this module emits NO event of its own (the broker is the single
  emitter of the completion lifecycle).
  """

  use ExMCP.Server

  alias Fleet.MCP.PodTools.Delegation
  alias Fleet.MCP.PodTools.Probe
  alias Fleet.MCP.PodTools.WorkItems

  # F-C138
  @base_tool_names ["get_work_item", "submit_result"]

  @doc "The universal pod-interface tool names (task-worker base), exposed to every role."
  @spec base_tool_names() :: [String.t()]
  def base_tool_names, do: @base_tool_names

  # L'EFFET DE CHAQUE OUTIL SUR LE MONDE, DECLARE ICI ET NULLE PART AILLEURS (6-106).
  #
  # ⚠ Ce que ca remplace : une liste de CINQ mots nus dans un sigil, chez l'acceptor. Elle ne
  # ressemblait a aucune autre occurrence d'un nom d'outil du depot (ni chaine citee, ni
  # `mcp__fleet__`, ni prose), donc le renommage objet-d'abord du 2026-08-11 l'a manquee EN SILENCE
  # et le dedup single-flight a cesse de reconnaitre les mutations. Une liste qui ne s'ecrit pas
  # comme les autres est une liste qu'un renommage rate.
  #
  # Elle vit desormais A COTE des definitions — donc un renommage la traverse — et son exhaustivite
  # est MECANIQUE : `mix lcars.contracts.check` lit les `deftool` par l'AST et refuse un outil sans
  # effet declare, ou un effet declare pour un outil qui n'existe pas. C'est la seule forme qui
  # empeche d'ajouter un mutateur et de l'oublier ; une liste, meme bien rangee, ne le peut pas.
  #
  # TROIS effets, parce qu'il y a trois natures et que les confondre est ce qui a coute la fiche :
  #
  #   * `:mutation` — l'appel change le MONDE (forge, disque, projets). Deux appels identiques
  #     concurrents doivent s'effondrer en un : c'est le retry MCP, le double-clic logique, la
  #     re-emission apres le timeout de 30 s du pont stdio.
  #   * `:protocol` — le canal IN/OUT du pod (`get_work_item`, `submit_result`). Il mute bien la
  #     FILE, mais sa re-emission est un comportement CONCU, pas un accident : le pull est l'ACK
  #     durable du wake, et un re-submit rejoue honnetement tant que la diffusion n'a pas ete
  #     confirmee (c'est ce qui repare une completion perdue). La `TaskQueue` est deja l'autorite de
  #     ces semantiques ; poser un second arbitre devant donnerait deux proprietaires a un seul
  #     mecanisme.
  #   * `:read` — ne change rien ; rien a arbitrer.
  #
  # ⚠ Et le motif que l'action prescrite invoque pour tout idempotencer NE TIENT PAS sur ce
  # mecanisme, verifie dans son code : `Fleet.MCP.Idempotency` est un single-flight, il ne met
  # JAMAIS en cache un resultat abouti (`handle_cast({:publish, …})` supprime l'entree, et son
  # moduledoc le dit : « completed results are never cached, so later intentions run against the
  # current world »). Un resultat en echec promeut exactement un attendant, qui retente. Etendre
  # cette protection ne supprime donc aucun rejeu — ce qui la borne est ci-dessus, pas un cache.
  @tool_effects %{
    "get_work_item" => :protocol,
    "submit_result" => :protocol,
    "issue_create" => :mutation,
    "project_create" => :mutation,
    "project_open" => :mutation,
    "project_install" => :mutation,
    "deposit_list" => :read,
    "deposit_import" => :mutation,
    "project_adopt" => :mutation,
    "project_import" => :mutation,
    "project_publish" => :mutation,
    "project_close" => :mutation,
    "project_revise_card" => :mutation,
    "project_reset_ci_rail" => :mutation,
    "project_delete" => :mutation,
    "issue_status" => :read,
    "scratch" => :mutation,
    "escalation_list" => :read,
    "card_list" => :read,
    "catalogue_list" => :read,
    "issue_list" => :read,
    "issue_get" => :read,
    "issue_comment" => :mutation,
    "dependency_add" => :mutation,
    "dependency_remove" => :mutation,
    "emergency_stop" => :mutation,
    "project_list" => :read,
    "issue_retire" => :mutation,
    "forge_list" => :read,
    "forge_link" => :mutation,
    "toolchain_request" => :mutation,
    # ⚠ `:mutation` ET PAS `:read`, malgre un nom qui sonne comme une lecture. Un dispatch FAIT
    # TOURNER UN RUNNER : deux appels identiques concurrents jouent la sonde deux fois — observable,
    # facture, et sans autre effet que de doubler l'attente du juge. Le single-flight de l'acceptor
    # est exactement le bon arbitre. Ce qu'elle ne change pas, c'est l'etat du PROJET : la sonde ne
    # pousse rien, ne commente rien, ne decide rien.
    "run_probe" => :mutation
  }

  @doc """
  The declared world-effect of each tool: `:mutation`, `:protocol` or `:read`.

  `:unknown` for a name this module does not declare — the acceptor treats it as a mutation, which
  is the safe direction, and `mix lcars.contracts.check` refuses the omission at the gate.
  """
  @spec tool_effect(String.t()) :: :mutation | :protocol | :read | :unknown
  def tool_effect(tool) when is_binary(tool), do: Map.get(@tool_effects, tool, :unknown)

  @doc false
  @spec declared_tool_effects() :: %{String.t() => atom()}
  def declared_tool_effects, do: @tool_effects

  deftool "get_work_item" do
    # vitrine: Tire de la fleet la prochaine tâche à traiter ; réponse vide = plus rien à faire, le pod s'arrête.
    meta do
      name("Get Work Item")

      description(
        "Fetch your next task from the LCARS fleet. Returns " <>
          "{\"done\":true} when there is no task left (you then stop), " <>
          "otherwise {\"done\":false,\"work_item\":{...}}."
      )
    end

    input_schema(%{"type" => "object", "properties" => %{}})
  end

  deftool "submit_result" do
    # vitrine: Rend à la fleet le résultat structuré de ta tâche, corrélé au ticket que tu clôts.
    meta do
      name("Submit Result")

      description(
        "Return a task's structured result to the LCARS fleet, in `payload`. `work_item_id` REQUIRED = " <>
          "the `work_item_id` returned by `get_work_item` (the task you are closing): the fleet correlates " <>
          "your deliverable to THIS specific task, never to \"the most recent one\"."
      )
    end

    # ⚠ `payload` ÉTAIT UN `object` NU, ET C'EST LÀ QUE LA CHARGE MACHINE DES JUGES SE PERDAIT.
    # MESURÉ le 2026-08-19 au banc, sur deux juges indépendants (probe-rails PR#34 puis PR#37) :
    # trois verdicts rendus, trois gravures en prose, ZÉRO `details.findings_v1`. La consigne
    # existe pourtant — `core/judge-verdict` la compose dans le SP de chaque juge — mais elle vit
    # dans un bloc de prose lu au démarrage, à des centaines de lignes du moment où l'agent
    # remplit CET appel. Ce que l'agent a sous les yeux en agissant, c'est ce schéma, et il
    # disait « un objet ». Un objet, c'est tout ce qu'il rendait.
    #
    # Le schéma reste PERMISSIF (aucun `required` ajouté, aucun `additionalProperties: false`) :
    # `submit_result` sert tous les rôles, et la forme d'un livrable de producteur n'est pas celle
    # d'un verdict de juge. On ne contraint pas, on NOMME — la description est le seul endroit qui
    # atteint l'agent au bon instant.
    input_schema(%{
      "type" => "object",
      "properties" => %{
        "payload" => %{
          "type" => "object",
          "description" =>
            "Le résultat structuré de ta tâche. SI TU ES UN JUGE : l'enveloppe de verdict " <>
              "(`decision`, `reason`, …) ET, sous `details.findings_v1`, la charge MACHINE de tes " <>
              "findings — `%{\"findings\" => [%{\"severity\" => \"critical\"|\"important\"|" <>
              "\"minor\", \"category\" => …, \"description\" => …}, …]}`. Ta prose est lue par " <>
              "des humains ; cette charge est lue par le RAIL : c'est elle qui permet à la carte du " <>
              "projet de peser ton verdict au lieu de seulement le compter. L'omettre ne casse rien " <>
              "et ne perd que ça — mais elle est perdue pour de bon."
        },
        "work_item_id" => %{"type" => "string"}
      },
      "required" => ["payload", "work_item_id"]
    })
  end

  deftool "run_probe" do
    # vitrine: Fait jouer une sonde nommée sur la forge et rend son fait brut : le juge mesure le livrable au lieu de seulement l'opiner.
    meta do
      name("Run Probe")

      description(
        "MESURE le livrable que tu juges, au lieu d'en avoir seulement l'opinion. Le rail joue la " <>
          "sonde nommée sur la forge et te rend son FAIT brut ; il ne te donne aucun accès et ne " <>
          "juge rien à ta place.\n\n" <>
          "`probe` = `\"test-relevance\"` : remet le code de cette livraison à son état de base EN " <>
          "GARDANT sa suite de tests, et regarde si la suite s'en aperçoit. `verdict=relevant` = la " <>
          "suite prouve le code livré. `verdict=blind` = elle reste VERTE sans lui, donc elle ne le " <>
          "prouve pas. `verdict=inapplicable` = rien n'était mesurable, et le `reason` dit quoi " <>
          "(suite déjà rouge sur la tête, aucun chemin de preuve déclaré…).\n\n" <>
          "⚠ `blind` N'EST PAS un verdict sur la livraison, c'est un fait sur la SUITE — à toi de " <>
          "décider ce que ça vaut ici. Et `inapplicable` n'est pas un vert : c'est l'absence de " <>
          "mesure, qui ne se raconte pas comme une mesure réussie.\n\n" <>
          "Tu ne fournis NI dépôt, NI PR, NI SHA, NI chemins : ils viennent de ton canal et des " <>
          "déclarations du projet. Un juge qui choisirait sa base choisirait celle qui l'arrange."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "probe" => %{
          "type" => "string",
          "enum" => Fleet.MCP.PodTools.Probe.known(),
          "description" => "Le NOM de la sonde à jouer."
        },
        "inputs" => %{
          "type" => "object",
          "description" =>
            "Entrées ADDITIONNELLES déclarées par la sonde. Les clés que le rail calcule " <>
              "(`base_sha`, `head_sha`, `harness`, `test_cmd`) ne sont jamais écrasées."
        }
      },
      "required" => ["probe"]
    })
  end

  deftool "issue_create" do
    # vitrine: Délègue une brique d'implémentation à la fleet : ouvre un ticket prêt à livrer (engineer → PR → revue → merge).
    meta do
      name("Create Issue")

      description(
        "Delegate an implementation brick of YOUR project to the LCARS fleet: creates a work ticket " <>
          "ready for delivery (engineer → PR → review → merge). Use it to DELEGATE rather than code " <>
          "yourself (the fleet delivers better and preserves your context). `brief` = the FULL brief " <>
          "for the engineer. The system commits your `brief` as the authored doc in your " <>
          "project's ops and the ticket then carries `summary` + the pinned pointer " <>
          "(`Brief: <ref> @ <commit>`); if that materialization cannot complete it DEGRADES to your " <>
          "`brief` INLINE in the ticket instead (logged loud) — never a wall — so ALSO pass " <>
          "`summary`: 2-6 lines, human-facing, " <>
          "what/why/done-when (without it the ticket shows a raw excerpt). If you ALREADY " <>
          "authored+committed the doc yourself (multi-doc brief), pass `brief_ref` (entry doc, e.g. " <>
          "`briefs/<slug>.md`) + `brief_sha` (introducing COMMIT sha) and `brief` then carries the " <>
          "human summary, unchanged. Inline `brief` → the SYSTEM owns the commit; `brief_ref`/" <>
          "`brief_sha` supplied → they name a doc ALREADY on the forge — this pointer is NEVER a " <>
          "vehicle to get your local commits pushed: to hand FILES to the producer, use `lot`. " <>
          "Returns {\"status\":\"issue_created\",\"issue\":N," <>
          "\"title\":<echoed as registered — confirm your number-to-title association on it>}. " <>
          "REWORK of a rejected/abandoned ticket: pass `supersedes: <old issue number>` — the " <>
          "fleet then RETIRES the old ticket itself (system comment + close; never two live " <>
          "tickets for one brick, never close anything yourself — you have no close tool). " <>
          "Refused if the old ticket has a LIVE PR (let it land or escalate). The result echoes " <>
          "{\"supersedes\":N}; a \"supersede_warning\" means the old ticket could NOT be closed — " <>
          "relay it to your human. " <>
          "ORDER between tickets: `depends_on: [N, ...]` — the fleet writes the edges and the " <>
          "admission holds the ticket back while a blocker is open. Declare the SAME constraint " <>
          "in the brief's precondition block: the edge binds the machine, the prose binds the " <>
          "agent, and neither stands in for the other."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "brief" => %{"type" => "string"},
        "criteria" => %{
          "type" => "string",
          "description" =>
            "THE JUDGE'S criteria — a SUMMARY OF THE EXPECTED, self-contained. Distinct from " <>
              "`brief`: `brief` tells the producer HOW to use the material (it may reference the " <>
              "workshop it mounts); `criteria` states WHAT the delivery must satisfy, and it must " <>
              "stand alone — the judge mounts nothing, so a criterion that points to a doc it " <>
              "cannot reach is not a criterion. Committed under `gate-briefs/`, resolved for the " <>
              "judge at dispatch. Omit for a `workshop` ticket (no jury judges it — you close the " <>
              "loop yourself). Required in practice for a `code` ticket: a judge without criteria " <>
              "approves, the one false GREEN this rail exists to refuse."
        },
        "summary" => %{"type" => "string"},
        "brief_ref" => %{"type" => "string"},
        "brief_sha" => %{"type" => "string"},
        "lot" => %{
          "type" => "string",
          "description" =>
            "THE MATTER this ticket works on, when it is FILES rather than words: several " <>
              "documents, a directory, images. Commit them on your workshop face (do not push — " <>
              "you cannot, and you do not have to), then name the lot here with a slug " <>
              "(`[a-z0-9][a-z0-9_-]*`, e.g. `morse-ui-v2`). The fleet publishes your commits as " <>
              "`lcars/lot-<slug>` and the producer's workspace STARTS from them — it receives the " <>
              "files, not a description of them. `brief` still says what to DO with the matter. " <>
              "A lot that cannot be published REFUSES the ticket: a ticket naming matter it " <>
              "cannot carry would send a producer to work against material it never saw."
        },
        "supersedes" => %{"type" => "integer"},
        "depends_on" => %{
          "type" => "array",
          "items" => %{"type" => "integer"},
          "description" =>
            "Ticket numbers this one MUST NOT start before. The fleet writes the edges on the " <>
              "forge, which refuses to close a blocked ticket, AND the admission refuses to " <>
              "dispatch it while a blocker is open (wait/depends). This does NOT replace the " <>
              "precondition block of your brief: the producer is forge-blind, it never sees the " <>
              "edge — the edge holds the machine, the prose tells the agent what to assume."
        },
        "destination" => %{
          "type" => "string",
          "enum" => ["code", Fleet.Labels.destination_workshop_token()],
          "description" =>
            "WHERE THE DELIVERABLE LANDS — not what kind of artefact it is. \"workshop\" = it stays " <>
              "in the project's workshop face: backlog, plans, specs in progress, design " <>
              "notes — material the project is built FROM, which never ships with it. Routed to " <>
              "the scribe, direct path: no scoper (you authored the brief, you judge the return " <>
              "in your own mount), no PR jury (nothing leaves the project, so there is no absent " <>
              "reader to protect — you close the loop yourself). \"code\" or absent = the " <>
              "deliverable SHIPS, on the project's declared card, jury included.\n" <>
              "A ticket whose deliverable is documentation destined for `docs/` — user guide, " <>
              "maintainer or fork doc — is a \"code\" ticket: it ships, so it is written on the " <>
              "code face and judged like any other delivery. Prose is not the criterion; " <>
              "destination is."
        }
      },
      "required" => ["title", "brief"]
    })
  end

  deftool "project_create" do
    # vitrine: Crée un projet : dépôt sur la forge, ses trois faces, le scaffold, et lance son architecte.
    meta do
      name("Create Project")

      description(
        "Start a NEW project: creates the repo on the forge + the THREE face folders " <>
          "(`/home/projects/<name>` on `main` = the deliverable, `/home/projects.ops/<name>` on " <>
          "`ops` = the record the runtime keeps, `/home/projects.workshop/<name>` on `workshop` = " <>
          "the workshop your drafts live in) + " <>
          "the base scaffold, and pushes it. Use it when the human wants to LAUNCH a fresh project. " <>
          "`name` = kebab-case slug. THE CARD CHOICE IS THE CRITICALITY DECLARATION: present the " <>
          "catalogue first (`card_list`, which names the CATALOGUE of every card) and pass " <>
          "the human's chosen card as `workflow_map` plus its `catalogue` — the project lives in that " <>
          "catalogue's forge org, and the binding is FIXED FOR ITS LIFE — so `catalogue` is REQUIRED, never " <>
          "inferred: the listing hands you each card WITH its catalogue, copy both. Two catalogues may " <>
          "both ship a `standard`, and a name alone then designates nothing. The card carries the " <>
          "whole gate (which judges, which CI, which verdict policy); `justification` " <>
          "records the WHY in prose. You MAY ask the framing questions (mains voltage? cuts fingers? " <>
          "how long will it live?) — rubber-duck, not assessor: you NEVER weigh criticality yourself, " <>
          "you relay the human's card choice. If the human declares NOTHING (no card), pass nothing: " <>
          "the project is recorded undeclared on the default card. " <>
          "Returns {\"status\":\"onboarded\",\"repo\":...}; then use `issue_create` to deliver bricks " <>
          "INTO this project — the repo comes from your pod's binding, `issue_create` takes NO " <>
          "`project` parameter."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "pitch" => %{"type" => "string"},
        "description" => %{"type" => "string"},
        "justification" => %{"type" => "string"},
        "catalogue" => %{"type" => "string"},
        "workflow_map" => %{"type" => "string"}
      },
      "required" => ["name", "catalogue"]
    })
  end

  deftool "project_open" do
    # vitrine: Relance un projet déjà sur la boîte : remet son architecte debout (idempotent), sans écrire forge ni disque.
    meta do
      name("Open Project")

      description(
        "OPEN (relaunch) a project ALREADY on the agent machine: ensures its per-project architect is " <>
          "up (idempotent — alive = no-op; dead/never — fleet restart, crash — = fresh spawn, its context " <>
          "comes back via its stable slot). Use it to RESUME working on an existing project (e.g. after " <>
          "the fleet was restarted). No forge/disk write. `full_name` = `owner/name`. Dirs absent → " <>
          "error (that project needs `project_install`, or `project_create` if it does not exist). " <>
          "Returns {\"status\":\"opened\",\"repo\":...,\"architect\":{...}}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "full_name" => %{"type" => "string"}
      },
      "required" => ["full_name"]
    })
  end

  deftool "project_install" do
    # vitrine: Importe un dépôt déjà dans l'org : monte ses trois faces + le gate, sans toucher au contenu de main.
    meta do
      name("Install Project")

      description(
        "Import an EXISTING repo (already on the forge, in the org — pushed outside the fleet or by a human) " <>
          "into the agent machine: the three faces (`/home/projects/<name>` on `main`, " <>
          "`/home/projects.ops/<name>` on `ops`, `/home/projects.workshop/<name>` on `workshop`) + " <>
          "forge-enforced gate, WITHOUT touching the content " <>
          "of `main` (it stays intact). Use it for a project that already exists (≠ project_create, which " <>
          "starts a FRESH project). `full_name` = `owner/name` (e.g. `fleet/deja-la`) — must already be in " <>
          "the fleet org, default branch `main`. Returns {\"status\":\"imported\",\"repo\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "full_name" => %{"type" => "string"}
      },
      "required" => ["full_name"]
    })
  end

  deftool "deposit_list" do
    # vitrine: Liste ce que ton humain a poussé dans son espace perso et que la fleet ne porte pas encore.
    meta do
      name("List Deposits")

      description(
        "What your human has PUSHED to their personal space on this forge and that the fleet does " <>
          "not carry yet — the deposit candidates. There is no registry behind this: a repo " <>
          "outside every catalogue org is a candidate, a repo inside one is enrolled, and the " <>
          "LOCATION is the state. A candidate already carried under the same name by an org is " <>
          "filtered out (importing takes a COPY and leaves the original with its owner, so " <>
          "without that filter it would be offered again on every pass). " <>
          "Takes NO argument: the human is the one this fleet runs for. " <>
          "Returns {\"status\":\"listed\",\"human\":...,\"candidates\":[\"<login>/<name>\", ...]}. " <>
          "An unreachable org makes this REFUSE rather than return a short list — a list missing " <>
          "an org would offer to import what is already in."
      )
    end

    input_schema(%{"type" => "object", "properties" => %{}})
  end

  deftool "forge_list" do
    # vitrine: Liste les forges externes enregistrées par ton humain — le pool de publication, lecture seule.
    meta do
      name("List Forges")

      description(
        "The human's registered EXTERNAL forges (the pool they built with `lcars forge add`) — where a " <>
          "project could be published. Read-only; takes NO argument. Use it to PRESENT the forges before " <>
          "proposing to link a project (`forge_link`). Whether each forge's CLI is authenticated is a " <>
          "SEPARATE host check (`lcars forge status`), not this. Returns " <>
          "{\"status\":\"listed\",\"forges\":[{\"name\",\"host\",\"dest_host\",\"owner\"}, ...]}."
      )
    end

    input_schema(%{"type" => "object", "properties" => %{}})
  end

  deftool "forge_link" do
    # vitrine: Lie un projet à une forge : déclare où il publie ; ne publie rien (l'approve + le merge humain restent les gates).
    meta do
      name("Link Publish Target")

      description(
        "LINK a project to a registered forge — declare WHERE it publishes, the reversible intent. It " <>
          "does NOT publish: nothing goes external until the human runs `lcars approve` (first populate, " <>
          "the hard host gate) and merges the PR/MR. Use it after `project_create`/`project_import` to " <>
          "capture the destination the human picked from `forge_list`. `full_name` = the internal " <>
          "`owner/name`; " <>
          "`forge` = a name from `forge_list`; `as` = the destination repo name (becomes " <>
          "`<forge.owner>/<as>` on the forge). Returns {\"status\":\"linked\",\"repo\":...,\"dest\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "full_name" => %{"type" => "string"},
        "forge" => %{"type" => "string"},
        "as" => %{"type" => "string"}
      },
      "required" => ["full_name", "forge", "as"]
    })
  end

  deftool "deposit_import" do
    # vitrine: Adopte dans un catalogue un dépôt déposé par ton humain ; gate d'adoption à l'entrée, l'original reste chez lui.
    meta do
      name("Import Deposit")

      description(
        "Adopt a repo your human DEPOSITED in their personal space (`<login>/<name>`, from " <>
          "`deposit_list`) into a catalogue's org — the third import door, and the only one that " <>
          "takes a repo from outside every org. `catalogue` names the destination (its org IS its " <>
          "name). The full ADOPTION GATE runs on the way in: a foreign `.claude/` tree is refused " <>
          "en bloc, every `CLAUDE.md` goes through the reception filter, and the default branch is " <>
          "normalized to `main`. The source is NOT consumed — your human keeps their repo, the " <>
          "fleet works on its copy. Use `project_install` instead for a repo ALREADY in an org. " <>
          "FRAME IT ON THE WAY IN: `workflow_map` + `justification` declare the card and " <>
          "the WHY, exactly as on `project_create` — the card IS the criticality. Undeclared is " <>
          "not forbidden — the project lands on the default card and the declaration says " <>
          "it was never declared, which is a readable state rather than a hole. " <>
          "Returns {\"status\":\"imported\",\"repo\":...,\"from\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "source" => %{"type" => "string"},
        "catalogue" => %{"type" => "string"},
        "justification" => %{"type" => "string"},
        "workflow_map" => %{"type" => "string"}
      },
      "required" => ["source", "catalogue"]
    })
  end

  deftool "project_adopt" do
    # vitrine: Publie sur la forge un projet qui n'existait que sur le disque — l'inverse de l'import, le local jamais écrasé.
    meta do
      name("Adopt Project")

      description(
        "ADOPT a project that lives on the agent machine's DISK but not on the forge — the " <>
          "inverse of project_import: publishes the existing local content (repo created EMPTY, " <>
          "the local main is pushed as-is, ops face brought up, forge gate placed). Use it " <>
          "for a project someone built locally (or whose forge was lost) that the fleet should " <>
          "now work. The local content is NEVER overwritten. `name` = the local dirs' basename " <>
          "(kebab-case). The card/criticality declaration relays like project_create (present " <>
          "the catalogue first when the human declares; an existing committed declaration in the " <>
          "project is kept as-is). Refusals name the right verb: repo already on the forge → use " <>
          "project_import or project_open; no local main → nothing to adopt. Returns " <>
          "{\"status\":\"adopted\",\"repo\":...} like project_create."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "description" => %{"type" => "string"},
        "justification" => %{"type" => "string"},
        "workflow_map" => %{"type" => "string"}
      },
      "required" => ["name", "catalogue"]
    })
  end

  deftool "project_import" do
    # vitrine: Rapatrie un dépôt d'une forge externe (GitHub/GitLab) : historique complet, sens unique, via le gate d'adoption.
    meta do
      name("Import External Project")

      description(
        "IMPORT a repo from an EXTERNAL forge (GitHub or GitLab ONLY — https URL) into the " <>
          "fleet: full history repatriated, repo created in the org, the three faces + " <>
          "forge gate like project_import. ONE-WAY: the external origin is left behind (this " <>
          "is an import, never a mirror). THE ADOPTION GATE runs first (a foreign repo is the " <>
          "found-USB-key of the parking lot): a repo shipping a `.claude/` tree is REFUSED en " <>
          "bloc (we never adopt someone else's hooks), and every CLAUDE.md must pass the " <>
          "mechanical reception filter — on refusal NOTHING reaches the org; the human expurges " <>
          "at the source and retries. Default branch is normalized to `main` (a half-migrated " <>
          "repo with BOTH master and main is refused — the human settles which is real). " <>
          "Private repos: auth is the operator's WIRED git credential helper (gh/glab auth login, " <>
          "or their own helper) — the host clones with it, no token in chat, no env token. `url` = " <>
          "https repo URL; `name` = the kebab-case project " <>
          "name in our org. The card/criticality declaration relays like project_create. " <>
          "Returns {\"status\":\"imported_external\",\"repo\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "catalogue" => %{"type" => "string"},
        "url" => %{"type" => "string"},
        "name" => %{"type" => "string"},
        "justification" => %{"type" => "string"},
        "workflow_map" => %{"type" => "string"}
      },
      "required" => ["url", "name", "catalogue"]
    })
  end

  deftool "project_publish" do
    # vitrine: Publie un projet interne vers sa forge externe liée, en PR/MR roulante — async, le token reste côté hôte.
    meta do
      name("Publish to External Forge")

      description(
        "PHASE 2 — publish an internal project to its LINKED external forge (GitHub or GitLab, both " <>
          "first-class) as a rolling PR/MR. ASYNC: returns " <>
          "{\"status\":\"queued\",\"repo\":...} immediately (a full history rewrite is minutes on a " <>
          "large repo), " <>
          "and the outcome — the PR/MR url or a failure — arrives later on the fleet bus " <>
          "(project_publish.done / .failed). The external token NEVER enters a pod: the rail runs " <>
          "host-side. PREREQUISITE: the project must already be LINKED by the human via " <>
          "`lcars approve <repo> --forge <name> --as <dest>` — an unlinked repo returns queued " <>
          "and then fails on the bus (no destination). Force-updates ONE rolling branch " <>
          "(`lcars/publish`) and its single open PR/MR; the human merges it on the forge's web UI. " <>
          "`full_name` = the internal `owner/name`."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "full_name" => %{"type" => "string"}
      },
      "required" => ["full_name"]
    })
  end

  deftool "project_close" do
    # vitrine: Met un projet en pause : la fleet s'arrête dessus, disque et forge intacts, réversible (≠ delete).
    meta do
      name("Close Project")

      description(
        "CLOSE a project: stops the fleet ON it — disk and forge stay INTACT (≠ project_delete: " <>
          "nothing is destroyed, this is a pause, fully reversible). The running brick finishes; " <>
          "the NEXT ticket never starts. Mechanics: an OPEN marker issue (`[lcars-parked]` title) " <>
          "holds the closed state on the forge — visible in the UI, no hidden state. The " <>
          "project's architect stops (it comes back at reopen). REOPEN: `project_open` (immediate " <>
          "full reopen, clears the marker), or a human closing the marker issue in the forge UI " <>
          "(the rail resumes; the architect self-respawns at the first pending escalation). " <>
          "`full_name` = `owner/name`. Returns {\"status\":\"closed\",\"outcome\":\"closed\"|" <>
          "\"already_closed\",\"marker_issue\":N,\"architect\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "full_name" => %{"type" => "string"}
      },
      "required" => ["full_name"]
    })
  end

  deftool "project_revise_card" do
    # vitrine: Révise la carte de validation : la criticité gravée reçoit une révision tracée, sur les tickets futurs.
    meta do
      name("Revise Project Card")

      description(
        "REVISE the validation card of an EXISTING project: the declaration engraved at " <>
          "project_create gets a tracked revision (a C0 PoC that grew serious no longer keeps its " <>
          "fast-track for life). Same doctrine as project_create: PRESENT the catalogue first " <>
          "(`card_list`) and let the HUMAN choose — the card choice IS the criticality " <>
          "declaration, you advise, you never decide. `justification` REQUIRED: the WHY of the " <>
          "revision, committed with the declaration in the project's repo (git history is the " <>
          "ledger). The branch protection re-sizes itself on the new card's jury in the same act. " <>
          "RELAY to the human: tickets already routed keep their engraved card — the revision " <>
          "applies to FUTURE tickets only. `full_name` = `owner/name`. Returns " <>
          "{\"status\":\"card_revised\",\"outcome\":\"revised\"|\"unchanged\",\"card\":...," <>
          "\"previous_card\":...}; \"unchanged\" = the identical declaration already stands " <>
          "(honest no-op, nothing pushed). OPTIONAL `max_fan` = how many tickets THIS project may " <>
          "run at once (1..15). Omit it and the fleet default answers; set it to 1 to watch one " <>
          "pipeline end to end WITHOUT slowing the other projects down."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "full_name" => %{"type" => "string"},
        "workflow_map" => %{"type" => "string"},
        "justification" => %{"type" => "string"},
        "max_fan" => %{"type" => "integer", "minimum" => 1, "maximum" => 15}
      },
      "required" => ["full_name", "workflow_map", "justification"]
    })
  end

  deftool "project_reset_ci_rail" do
    # vitrine: Remet le rail CI d'un projet a l'etat livre — la sortie quand un ci.yml casse bloque toutes les PR.
    meta do
      name("Reset Project CI Rail")

      description(
        "REWRITES the project's CI rail on `main` from the shipped template, and pushes it. THE " <>
          "ESCAPE HATCH OF THE FLOOR: `main` protection requires a `CI / *` status from EVERY " <>
          "project, and a BROKEN `ci.yml` (image without `node`, a `runs-on:` no runner serves, " <>
          "the workflow renamed away from `CI`) produces none — so NO pull request can merge, and " <>
          "nobody can repair it on the forge: humans are `read` there. This verb puts back the " <>
          "shipped rail, green by construction. IT OVERWRITES, and that is its whole point: the " <>
          "existing file IS the defect. `justification` REQUIRED — it replaces someone's work, it " <>
          "is not played by accident. RELAY to the human: a pull request ALREADY open keeps its " <>
          "own rail until its producer fixes it or it rebases; this repairs the SOURCE the next " <>
          "branches inherit. `full_name` = `owner/name`. Returns {\"status\":\"ci_rail_reset\"," <>
          "\"outcome\":\"reset\"|\"unchanged\",\"files\":[...]}; \"unchanged\" = the shipped " <>
          "rail already stands (honest no-op, nothing pushed)."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "full_name" => %{"type" => "string"},
        "justification" => %{"type" => "string"}
      },
      "required" => ["full_name", "justification"]
    })
  end

  deftool "project_delete" do
    # vitrine: Détruit un projet entièrement. Irréversible, fail-closed (force), désarmé par défaut.
    meta do
      name("Delete Project")

      description(
        "DELETE a project entirely: stops its architect, deletes the forge repo (branch-protection " <>
          "falls with it), and removes the 3 local face folders. IRREVERSIBLE, and it destroys " <>
          "WHATEVER `full_name` you pass → FAIL-CLOSED: it does NOTHING unless you pass `force: true` to " <>
          "confirm the destruction (there is no safe auto-detect — an imported repo has real content with " <>
          "0 fleet issues/PRs). Use it to RETIRE a project, or to clean up a FAILED `project_create` " <>
          "(`force: true`) then re-create on clean ground. `full_name` = `owner/name`. Without force → " <>
          "error `force_required`. DISARMED BY DEFAULT on most deployments: if you get " <>
          "`delete_project_disabled`, the tool is switched off for this whole fleet — that is not " <>
          "something you can work around, and it is not a reason to reach for another gesture. " <>
          "Report it to your human and stop. Returns {\"status\":\"deleted\",\"repo\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "full_name" => %{"type" => "string"},
        "force" => %{"type" => "boolean"}
      },
      "required" => ["full_name"]
    })
  end

  deftool "issue_status" do
    # vitrine: Donne l'état d'un ticket délégué (issue + PR) : outcome, revue, verdicts — la trace survit au merge.
    meta do
      name("Get Issue Status")

      description(
        "Check the state of a delegated issue of YOUR project (issue + linked PR). " <>
          "`number` = the issue number. Returns {\"issue\":N,\"title\":...,\"outcome\":...} " <>
          "plus \"pr\" only when there is something true to say. `outcome` values: " <>
          "\"merged\" (closed BY the merge — the delivery proof; only chain issue N+1 on this) | " <>
          "\"closed_without_merge\" (closed WITHOUT delivery: abandon/rejection — do NOT chain) | " <>
          "\"in_review\" (PR open, review running) | \"open\" (no PR yet) | " <>
          "\"unknown\" (forge unreachable — retry, decide nothing on it). " <>
          "`pr` = {number,state,merged,review,verdicts,reviews} of the fleet PR — the review trail " <>
          "SURVIVES the merge (how it was judged stays readable after delivery). `review` is the " <>
          "merge gate's own predicate: \"approved\" | \"pending\" | \"changes_requested\" | " <>
          "\"no_jury\" | \"unknown\" (read failed). `verdicts` maps each judge to its verdict; " <>
          "`reviews` gives the SUBSTANCE of each one — [{\"login\",\"verdict\"," <>
          "\"submitted_at\",\"body\"}], oldest first. Two approvals are the same value in " <>
          "`verdicts` and are not the same thing: read `body` and `submitted_at` before treating " <>
          "a verdict as a judgement. An empty `body` is a fact, not a missing field. The " <>
          "`reviews` key is ABSENT when no verdict is in force. The `pr` key is ABSENT when no " <>
          "fleet PR exists (nothing to say); {\"error\":\"forge_unreachable\"} means the PR read " <>
          "failed — never confuse it with 'no PR'."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "number" => %{"type" => "integer"}
      },
      "required" => ["number"]
    })
  end

  deftool "scratch" do
    # vitrine: Pose une pensée dans le brouillon du workshop, geste réflexe : le système commit/pousse ; ça ajoute seulement, ne coupe jamais.
    meta do
      name("Scratch")

      description(
        "Park a thought in your workshop scratchpad — one argument, no ceremony, and the system " <>
          "commits and pushes it for you. Your note lands as its own markdown block, stamped and " <>
          "closed by a rule, so it stays readable however you wrote it: keep your line breaks, " <>
          "your lists, your snippet. USE IT AS A REFLEX, not as a decision: the moment a " <>
          "point stabilises in a conversation (a conclusion, an arbitration, a constat, a " <>
          "reasoned refusal), drop it here and go on with the next point. The criterion is the " <>
          "NATURE of the exchange, never how important it feels — an importance judgement, late " <>
          "in a context, always answers 'not enough'. " <>
          "WHY IT EXISTS: your session level is ephemeral by definition and a compaction eats it " <>
          "whole; the vendor's own memory is OFF for every pod here. What you did not write is " <>
          "gone, and you will not know it is gone. " <>
          "This tool only ADDS — that is what makes the file trustworthy while the flow runs. " <>
          "Cleaning it is a separate, deliberate act: at triage you open the file yourself and " <>
          "cut, sending what remains to be done to `backlog.md`, what is specified to `plans/`. " <>
          "Notes belong to THIS project's workshop; there is no other place to aim."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "note" => %{"type" => "string"}
      },
      "required" => ["note"]
    })
  end

  deftool "escalation_list" do
    # vitrine: Liste les escalades de ton projet qui attendent ton arbitrage.
    meta do
      name("List Escalations")

      description(
        "List the escalations of YOUR project awaiting YOUR arbitration (issues labelled " <>
          "`lcars-awaits-arch`): a role (scoper/engineer/gatekeeper) hit `escalate_user` and " <>
          "handed the decision back to you. The wake (\"ton tour\") only signals THAT there is work; " <>
          "THIS reads WHAT. Returns each awaiting issue with `number`, `title` and `verdict` (the " <>
          "worker's escalation comment — the reasoning). Then act: fix + re-`issue_create`, say your " <>
          "decision on the thread with `issue_comment`, or bring it to your human. " <>
          "⚠ NONE OF THOSE RESOLVES THE ESCALATION. Only `submit_result` on this work item " <>
          "does: it is what drains the `lcars-awaits-arch` label and lets the poller serve the " <>
          "next step. Comment and stop, and the ticket stays in your inbox forever while the " <>
          "fleet re-kicks you about it. Speaking is not deciding. " <>
          "No arguments — it is your project's inbox."
      )
    end

    input_schema(%{"type" => "object", "properties" => %{}, "required" => []})
  end

  deftool "toolchain_request" do
    # vitrine: Demande un outil que la boîte n'a pas (compilateur, runtime, cross) ; un humain admin approuve — pas pour une dépendance de projet.
    meta do
      name("Request a Toolchain")

      description(
        "ASK FOR A TOOL THE BOX DOES NOT HAVE — a compiler, a language runtime, a cross " <>
          "toolchain, a system library your build needs. Use it ONLY when you are BLOCKED: you " <>
          "tried, and the tool is absent. Not to tidy an environment you find sparse.\n" <>
          "⚠ THIS IS NOT HOW YOU INSTALL A PROJECT DEPENDENCY. A python module, an npm package, a " <>
          "crate belong to your project's OWN manifest (`pyproject.toml`, `package.json`, " <>
          "`Cargo.toml`): you commit them there and they install in your workspace, with no " <>
          "privilege and no approval. This tool is for what lives OUTSIDE your project and is " <>
          "shared by EVERY pod on this box — which is exactly why a human has to say yes.\n" <>
          "WHAT HAPPENS: the fleet renders your fields as a declaration, opens a pull request on " <>
          "the box's manifest, and A HUMAN ADMIN APPROVES OR REFUSES IT. Nothing installs until " <>
          "they do. If you are working a WORK ITEM, it is put on hold and RE-DISPATCHED once the " <>
          "tool is there — you do not wait for it: you stop, and a later pod picks the item up " <>
          "with the tool in place. If you have NO work item (you are anticipating a need rather " <>
          "than blocked on one), the request still opens: nothing is put on hold, and nothing is " <>
          "re-dispatched, because there is no ticket waiting.\n" <>
          "EXACTLY ONE of `apt`, `installer` or `sysroot` per request — they act on different " <>
          "places, and two in one diff would make the human approve one effect for another.\n" <>
          "`evidence` is read BY THE HUMAN and by nobody else: paste the error that stopped you, " <>
          "VERBATIM. It is what they judge on, and a request whose evidence is a paraphrase gets " <>
          "refused for lack of one.\n" <>
          "Returns {\"status\":\"toolchain_requested\",\"pr\":N}. A refusal comes back on your " <>
          "ticket; it is not a failure of this call."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "ecosystem" => %{
          "type" => "string",
          "pattern" => "^[a-z][a-z0-9-]{1,31}$",
          "description" =>
            "What this enables, in one token — `python`, `node`, `rust`, `cross-arm64`. It names " <>
              "the FAMILY, not the package: it is the key the box converges on, and the word the " <>
              "human reads first."
        },
        "apt" => %{
          "type" => "object",
          "description" =>
            "HOST packages, native architecture, into the box's /usr. Monotone: adding one never " <>
              "breaks what worked.",
          "properties" => %{
            "packages" => %{
              "type" => "array",
              "items" => %{"type" => "string", "pattern" => "^[a-z0-9][a-z0-9+.:-]*$"}
            }
          },
          "required" => ["packages"],
          "additionalProperties" => false
        },
        "installer" => %{
          "type" => "object",
          "description" =>
            "An OFFICIAL installer for an SDK apt cannot serve (rustup, a Zephyr/west workspace, " <>
              "esp-idf). The human approves the installer's IDENTITY and its pin, not each command " <>
              "it runs.",
          "properties" => %{
            "name" => %{"type" => "string", "pattern" => "^[a-z][a-z0-9-]{1,31}$"},
            "url" => %{"type" => "string", "pattern" => "^https://"},
            "version" => %{"type" => "string"},
            "sha256" => %{"type" => "string", "pattern" => "^[a-f0-9]{64}$"},
            "env_script" => %{
              "type" => "string",
              "description" =>
                "Path, RELATIVE to the installed tree, of the script the SDK ships to set its " <>
                  "environment. Your pod never runs it: the box plays it once and freezes the " <>
                  "result. Without it the SDK installs and no pod can use it."
            }
          },
          "required" => ["name", "url", "version", "sha256"],
          "additionalProperties" => false
        },
        "sysroot" => %{
          "type" => "object",
          "description" =>
            "A cross-compilation sysroot, ASSEMBLED from the target's own repositories — never " <>
              "taken off a running board. Declare the sources the target itself uses and the " <>
              "packages you link against; the closure is resolved for you.",
          "properties" => %{
            "arch" => %{"type" => "string", "pattern" => "^[a-z0-9]+$"},
            "sources" => %{"type" => "array", "items" => %{"type" => "string"}},
            "keyring" => %{"type" => "string"},
            "packages" => %{
              "type" => "array",
              "items" => %{"type" => "string", "pattern" => "^[a-z0-9][a-z0-9+.:-]*$"}
            }
          },
          "required" => ["arch", "sources", "packages"],
          "additionalProperties" => false
        },
        "egress_hosts" => %{
          "type" => "array",
          "items" => %{"type" => "string", "pattern" => "^[*a-zA-Z0-9._-]+$"},
          "description" =>
            "The registry hosts this ecosystem needs — a package manager the box has installed " <>
              "but cannot reach is a tool you still do not have. Hostnames only: no scheme, no " <>
              "port, no path."
        },
        "evidence" => %{
          "type" => "string",
          "description" =>
            "THE ERROR THAT STOPPED YOU, verbatim. Read by the human who decides, never by the " <>
              "machine that applies."
        }
      },
      "required" => ["ecosystem", "evidence"],
      "additionalProperties" => false
    })
  end

  deftool "card_list" do
    # vitrine: Liste le catalogue des cartes de validation, à présenter au cadrage : choisir la carte, c'est déclarer la criticité.
    meta do
      name("List Workflow Cards")

      description(
        "List the validation-card catalogue (the canon workflow maps). Use it DURING project framing, " <>
          "BEFORE project_create: the card choice IS the criticality declaration (naming a card = declaring), " <>
          "so PRESENT the catalogue to the human and let THEM choose — you may pre-filter or advise from the " <>
          "framing facts (mains voltage? cuts fingers? how long will it live?), you never decide for them. " <>
          "Each entry carries `name` (the LOADABLE id — pass it as project_create's `workflow_map`), " <>
          "`declared_name` (the card's self-declared label, reference only), `presentation` (FR, show it " <>
          "to the human VERBATIM — it states the card's positioning and judges), " <>
          "`jury` (the PR judges the card convenes) and `steps`. Cards marked TECHNIQUE are fleet tooling, " <>
          "not for real projects. It REFUSES rather than hand back an empty offer: no installed " <>
          "catalogue carries cards (a DEPLOYMENT fact — ask `catalogue_list` what this box serves), " <>
          "or the catalogue was scanned and offers nothing declarable. Never work around a refusal " <>
          "with a card of your own: naming a card IS declaring criticality. No arguments."
      )
    end

    input_schema(%{"type" => "object", "properties" => %{}, "required" => []})
  end

  deftool "catalogue_list" do
    # vitrine: Liste les catalogues que cette boîte sert — l'offre dans laquelle un projet est enrôlé, en amont du choix de la carte.
    meta do
      name("List Catalogues")

      description(
        "The catalogues this box SERVES — the offer a project is enrolled INTO. Present it BEFORE " <>
          "`card_list` during framing: a card belongs to a catalogue, and `project_create` REFUSES a " <>
          "catalogue that is not installed here. Each entry carries `name` (the catalogue's DECLARED " <>
          "identity — pass it as project_create's `catalogue`; it is also its forge org), `bundled` " <>
          "(ships inside the release, so always available and never removable) and `default_card` " <>
          "(the card a project takes when it declares none — absent when the catalogue ships no " <>
          "card). `unreadable` names installed material whose manifest yields no declared name — " <>
          "absent, unparseable or without one: it is served by nothing, the cause is `lcars " <>
          "catalogue verify`'s to name. Do NOT derive this list from " <>
          "`card_list` — a catalogue shipping no card is invisible there. It REFUSES rather than " <>
          "hand back an empty offer: this box always serves at least the catalogue carried by the " <>
          "release, so an empty one means its material is broken, not absent. The result is " <>
          "DISPLAYED as it stands: do not repeat it, answer what was asked of it. No arguments."
      )
    end

    input_schema(%{"type" => "object", "properties" => %{}, "required" => []})
  end

  deftool "issue_list" do
    # vitrine: Liste les tickets ouverts de ton projet — le tableau de situation, pas seulement ta boîte.
    meta do
      name("List Issues")

      description(
        "List the OPEN tickets of YOUR project — the situation board, not just your inbox " <>
          "(`escalation_list` shows ONLY the issues awaiting YOUR arbitration; this shows " <>
          "everything in flight, including tickets a human opened without you). Each entry: " <>
          "`number`, `title`, `labels` (the `stage/*` and `genre/*` markers carry the pipeline " <>
          "state). Closed tickets do not appear — track a specific delegation with " <>
          "`issue_status`, read a full thread with `issue_get`. No arguments — it is your " <>
          "project's board."
      )
    end

    input_schema(%{"type" => "object", "properties" => %{}, "required" => []})
  end

  deftool "issue_get" do
    # vitrine: Lit un ticket en entier : corps + fil de commentaires, la conversation.
    meta do
      name("Get Issue")

      description(
        "READ a ticket of YOUR project in full: body + comment thread, oldest first — the " <>
          "CONVERSATION, where `issue_status` renders a tracking VERDICT. Use it before " <>
          "replying with `issue_comment` (never answer a thread you have not read), and to read " <>
          "what a human or a worker wrote back to you. `number` = the issue number. Returns " <>
          "{\"issue\":N,\"title\",\"state\",\"body\",\"labels\",\"comments\":[{\"author\"," <>
          "\"body\",\"created_at\"}]}. If \"comments\" is ABSENT and \"comments_error\":" <>
          "\"forge_unreachable\" is set, the THREAD read failed — retry; never treat it as an " <>
          "empty thread."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "number" => %{"type" => "integer"}
      },
      "required" => ["number"]
    })
  end

  deftool "issue_comment" do
    # vitrine: Poste un commentaire sur un ticket, en ton nom — typiquement pour répondre à une escalade.
    meta do
      name("Comment Issue")

      description(
        "Post a comment on an issue of YOUR project IN YOUR OWN NAME (the architect role account) — " <>
          "your reply on a ticket in flight, typically to answer an escalation surfaced by " <>
          "`escalation_list`. `number` = the issue number. `body` = your comment (markdown). " <>
          "Returns {\"status\":\"commented\",\"number\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "number" => %{"type" => "integer"},
        "body" => %{"type" => "string"}
      },
      "required" => ["number", "body"]
    })
  end

  deftool "dependency_add" do
    # vitrine: Déclare qu'un ticket dépend d'un autre, après coup — bloque la clôture du dépendant tant que le bloqueur est ouvert.
    meta do
      name("Add Dependency")

      description(
        "Declare that a ticket of YOUR project DEPENDS ON another, after both exist. " <>
          "`number` = the ticket that waits. `blocker` = the ticket it waits for. Use it when the " <>
          "order between two bricks becomes clear only after you created them — stated in a brief " <>
          "instead, the constraint holds only as long as someone reads it. READ THE `portee` FIELD " <>
          "OF THE ANSWER: if `number` is ALREADY in flight, this edge does NOT stop it (the " <>
          "admission gate reads blockers when a step STARTS, and that reading already happened) — " <>
          "what it blocks is the CLOSURE of `number` until the blocker is resolved. To order work " <>
          "that has not started, use `issue_create` with `depends_on`. Returns " <>
          "{\"issue\":N,\"blocker\":N,\"edge\":\"added\",\"portee\":\"...\"}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "number" => %{"type" => "integer"},
        "blocker" => %{"type" => "integer"}
      },
      "required" => ["number", "blocker"]
    })
  end

  deftool "dependency_remove" do
    # vitrine: Lève une dépendance ; lever le dernier bloqueur rend le ticket clôturable.
    meta do
      name("Remove Dependency")

      description(
        "LIFT a dependency between two tickets of YOUR project — the inverse of " <>
          "`dependency_add`. `number` = the ticket that was waiting. `blocker` = what it waited " <>
          "for. Lifting the LAST blocker makes `number` closable immediately: the forge holds " <>
          "nothing back any more. Use it when an order you declared turns out not to apply — not " <>
          "to unblock a ticket whose blocker is simply late (that one is still real work). " <>
          "Returns {\"issue\":N,\"blocker\":N,\"edge\":\"removed\",\"portee\":\"...\"}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "number" => %{"type" => "integer"},
        "blocker" => %{"type" => "integer"}
      },
      "required" => ["number", "blocker"]
    })
  end

  deftool "emergency_stop" do
    # vitrine: Le frein : ferme tout ce que la fleet a en vol — pour casser un emballement. Le travail en cours est perdu.
    meta do
      name("Emergency Stop")

      description(
        "STOP everything the fleet has in flight, across every open project. Use it to break a " <>
          "runaway — a dispatch loop, pods respawning without end. It CLOSES tickets, it does not " <>
          "kill pods: killing pods resets nothing (the tickets stay open and the poller " <>
          "re-dispatches on the next tick), whereas a closed ticket leaves the poller by " <>
          "construction and its pods are collected on their own. Each ticket gets its live pull " <>
          "request closed then the ticket retired — the trace says nothing was delivered, because " <>
          "nothing was. `reason` = why you are pulling the brake; it is posted on every ticket and " <>
          "it is what a human will read tomorrow. WORK IN PROGRESS IS LOST — that is the trade: " <>
          "you save the fleet, not the tickets. Projects closed with `project_close` are skipped. " <>
          "A ticket that resists does NOT stop the sweep: it is listed in `failures` and the rest " <>
          "still stops. Re-run to finish the job — what is already retired is not listed again. " <>
          "Returns {\"stopped\":N,\"failed\":N,\"projects\":[...],\"skipped_not_open\":[...]}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{"reason" => %{"type" => "string"}},
      "required" => ["reason"]
    })
  end

  deftool "project_list" do
    # vitrine: Liste les projets de la boîte : nom, dépôt, carte, état.
    meta do
      name("List Projects")

      description(
        "LIST the projects on this box — the counterpart of the project gestures you already " <>
          "have. Takes no argument. Returns {\"count\":N,\"projects\":[{\"name\",\"repo\"," <>
          "\"card\",\"card_source\",\"state\"}]}. `card_source` says whether the " <>
          "validation card was DECLARED by a human (`declared`), never declared (`undeclared` — " <>
          "the fleet default applies at burn time), or unreadable (`invalid`/`unreadable`): a " <>
          "project that declared nothing is NOT the same as one that chose the default. `state` " <>
          "is `open`, `parked` (closed by `project_close`, reopen with `project_open`), or " <>
          "`unknown` with `state_error` when the forge could not be read — an unknown state is " <>
          "never reported as open."
      )
    end

    input_schema(%{"type" => "object", "properties" => %{}})
  end

  deftool "issue_retire" do
    # vitrine: Retire un ticket sans le remplacer : travail abandonné, PR fermée, dépendants libérés (≠ supersedes).
    meta do
      name("Retire Issue")

      description(
        "RETIRE a ticket of YOUR project WITHOUT replacing it: the work is abandoned, not moved. " <>
          "Use it when a ticket should never have existed, or no longer should — obsolete, " <>
          "duplicated, out of scope. To replace a ticket by a corrected one, use " <>
          "`issue_create` with `supersedes` instead: that one CARRIES the dependencies onto the " <>
          "successor, this one LIFTS them. `number` = the issue number. `reason` = why, in one " <>
          "or two sentences — it is posted on the ticket and it is the only trace of your " <>
          "decision. What happens: the live pull request is closed, every ticket that depended " <>
          "on this one is commented and released, the reason is posted, the ticket is closed as " <>
          "`stage/retired` (NOT delivered) and its pods are reaped. Any failure ABORTS and leaves " <>
          "the ticket open. An already-closed ticket returns \"retired\":false and changes " <>
          "nothing. Returns {\"issue\":N,\"retired\":true,\"released\":[...],\"pr_closed\":N|null}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "number" => %{"type" => "integer"},
        "reason" => %{"type" => "string"}
      },
      "required" => ["number", "reason"]
    })
  end

  # ============================================================
  # Dispatch — work-item drive (Fleet.MCP.PodTools.WorkItems)
  # ============================================================

  @impl true
  def handle_tool_call("get_work_item", _arguments, %{pod_id: pod_id} = state)
      when is_binary(pod_id) and pod_id != "" do
    # Identity = the channel: `pod_id` comes from the socket acceptor (one pod = one socket), never from the wire.
    # So we do NOT read any identity from the arguments — there is nothing to prove, the socket discriminates.
    {:ok, %{content: [json(WorkItems.get_work_item(pod_id))]}, state}
  end

  def handle_tool_call("get_work_item", _arguments, state) do
    # `pod_id` absent from the state = acceptor anomaly (it MUST always carry it). Typed error, not a
    # brief-exhaustion masked as done:true (otherwise the pod would stop believing it had finished). Fail-closed.
    {:error, :pod_id_required, state}
  end

  def handle_tool_call("submit_result", %{"payload" => payload} = args, %{pod_id: pod_id} = state)
      when is_map(payload) and is_binary(pod_id) and pod_id != "" do
    # Identity = the channel (`state.pod_id`, carried by the acceptor). The correlation contract
    # (`work_item_id` MANDATORY, looked up top-level then in payload) and the mapping of the typed refusals
    # (:no_active_work_item, :work_item_id_mismatch, :broadcast_failed — never a failure masked as a
    # success) live in `WorkItems.submit_result/3`.
    case WorkItems.submit_result(pod_id, args, payload) do
      {:ok, message} -> {:ok, %{content: [text(message)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("submit_result", %{"payload" => payload}, state) when is_map(payload) do
    # Valid payload but `pod_id` absent from the state = acceptor anomaly → typed refusal, never an
    # anonymous fallback (a deliverable with no identified pod has nowhere to go).
    {:error, :pod_id_required, state}
  end

  def handle_tool_call("submit_result", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  # ============================================================
  # Dispatch — mesure demandee par un juge (Fleet.MCP.PodTools.Probe)
  # ============================================================

  # POD-SCOPE, comme `get_work_item`/`submit_result` et pour la meme raison : le SUJET de l'appel
  # (depot, PR, SHAs) est derive du canal, jamais du fil. Le seul parametre du juge est le NOM de la
  # sonde — et un nom inconnu est refuse en enumerant ceux qui existent.
  def handle_tool_call("run_probe", %{"probe" => probe} = args, %{pod_id: pod_id} = state)
      when is_binary(probe) and is_binary(pod_id) and pod_id != "" do
    inputs = Map.get(args, "inputs", %{})
    inputs = if is_map(inputs), do: inputs, else: %{}

    case Probe.run(pod_id, probe, inputs) do
      {:ok, facts} -> {:ok, %{content: [json(facts)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("run_probe", %{"probe" => probe}, state) when is_binary(probe) do
    # `pod_id` absent de l'etat = anomalie d'acceptor. Refus type : une mesure sans pod identifie
    # n'a pas de sujet, et en inventer un serait sonder le depot de quelqu'un d'autre.
    {:error, :pod_id_required, state}
  end

  def handle_tool_call("run_probe", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  # ============================================================
  # Dispatch — architect forge delegation (Fleet.MCP.PodTools.Delegation)
  # ============================================================

  # The architect gate (require_architect: role AND repo resolved from the channel — the pod's spawn
  # binding — never from the wire) is applied INSIDE Delegation, before any forge mechanics. Since the
  # 2026-07-19 reorg there is NO `project` wire param on the delegation tools: the arch has "the
  # project", the system knows which — a param to refuse would itself leak that other repos exist.

  def handle_tool_call("issue_create", %{"title" => title, "brief" => brief} = args, state)
      when is_binary(title) and is_binary(brief) do
    # Pointer args are a PAIR: one without the other, or an out-of-scheme value, is a
    # STRUCTURAL REFUSAL — never a ticket with a half-pointer.
    if valid_brief_pointer_args?(args) do
      summary =
        case args["summary"] do
          s when is_binary(s) and s != "" -> s
          _ -> nil
        end

      case Delegation.create_issue(
             title,
             brief,
             state,
             brief_pointer(args),
             summary,
             args["supersedes"],
             args["destination"],
             args["depends_on"],
             args["lot"],
             args["criteria"]
           ) do
        {:ok, result} -> {:ok, %{content: [json(result)]}, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error,
       {:invalid_brief_pointer,
        "`brief_ref`+`brief_sha` come TOGETHER: ref = ops brief path " <>
          "(e.g. `briefs/<slug>.md`), sha = the introducing 40-hex COMMIT sha"}, state}
    end
  end

  def handle_tool_call("issue_create", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("project_create", %{"name" => name} = args, state) when is_binary(name) do
    case Delegation.create_project(name, args, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("project_create", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("project_install", %{"full_name" => full_name}, state)
      when is_binary(full_name) and full_name != "" do
    if valid_repo_ref?(full_name) do
      case Delegation.import_project(full_name, state) do
        {:ok, result} -> {:ok, %{content: [json(result)]}, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error,
       {:invalid_full_name,
        "`full_name` must be an `owner/name` repo (got #{inspect(full_name)})"}, state}
    end
  end

  def handle_tool_call("project_open", %{"full_name" => full_name}, state)
      when is_binary(full_name) and full_name != "" do
    if valid_repo_ref?(full_name) do
      case Delegation.open_project(full_name, state) do
        {:ok, result} -> {:ok, %{content: [json(result)]}, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error,
       {:invalid_full_name,
        "`full_name` must be an `owner/name` repo (got #{inspect(full_name)})"}, state}
    end
  end

  def handle_tool_call("project_open", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("project_install", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  # No wire parameter, by construction: the human is the one this fleet runs for. A login on the
  # wire would turn an import tool into an enumerator of other people's personal spaces.
  def handle_tool_call("deposit_list", _args, state) do
    case Delegation.list_deposits(state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("toolchain_request", args, %{pod_id: pod_id} = state)
      when is_map(args) and is_binary(pod_id) and pod_id != "" do
    # Identity = the channel. `pod_id` comes from the socket acceptor (one pod = one socket) and
    # the work item is DERIVED from it — nothing in the arguments names a ticket, so there is
    # nothing to prove: the socket discriminates. That is also what stops a pod requesting on
    # another's behalf.
    case Delegation.request_toolchain(args, pod_id) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("toolchain_request", _args, state) do
    # `pod_id` absent = acceptor anomaly (it MUST always carry it). Typed refusal rather than a
    # request nobody could attach to a ticket — a manifest whose origin is unknown is one no human
    # can judge and no merge can be traced back to.
    {:error, :pod_id_required, state}
  end

  def handle_tool_call("forge_list", _args, state) do
    case Delegation.list_forges(state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("forge_link", %{"full_name" => _, "forge" => _, "as" => _} = args, state) do
    case Delegation.publish_link(args, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("forge_link", _bad_args, state),
    do: {:error, :invalid_arguments, state}

  def handle_tool_call(
        "deposit_import",
        %{"source" => source, "catalogue" => catalogue} = args,
        state
      )
      when is_binary(source) and is_binary(catalogue) and catalogue != "" do
    if valid_repo_ref?(source) do
      case Delegation.import_deposit(source, catalogue, args, state) do
        {:ok, result} -> {:ok, %{content: [json(result)]}, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error,
       {:invalid_source,
        "`source` must be a `<login>/<name>` repo of a personal space (got #{inspect(source)})"},
       state}
    end
  end

  def handle_tool_call("deposit_import", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("project_adopt", %{"name" => name} = args, state) when is_binary(name) do
    case Delegation.adopt_project(name, args, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("project_adopt", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("project_import", %{"url" => url, "name" => name} = args, state)
      when is_binary(url) and is_binary(name) and url != "" and name != "" do
    case Delegation.import_external_project(url, name, args, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("project_import", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("project_publish", %{"full_name" => full_name} = args, state)
      when is_binary(full_name) do
    case Delegation.project_publish(args, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("project_publish", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("project_close", %{"full_name" => full_name}, state)
      when is_binary(full_name) and full_name != "" do
    if valid_repo_ref?(full_name) do
      case Delegation.close_project(full_name, state) do
        {:ok, result} -> {:ok, %{content: [json(result)]}, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error,
       {:invalid_full_name,
        "`full_name` must be an `owner/name` repo (got #{inspect(full_name)})"}, state}
    end
  end

  def handle_tool_call("project_close", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("project_revise_card", %{"full_name" => full_name} = args, state)
      when is_binary(full_name) and full_name != "" do
    if valid_repo_ref?(full_name) do
      case Delegation.revise_project_card(full_name, args, state) do
        {:ok, result} -> {:ok, %{content: [json(result)]}, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error,
       {:invalid_full_name,
        "`full_name` must be an `owner/name` repo (got #{inspect(full_name)})"}, state}
    end
  end

  def handle_tool_call("project_revise_card", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("project_reset_ci_rail", %{"full_name" => full_name} = args, state)
      when is_binary(full_name) and full_name != "" do
    if valid_repo_ref?(full_name) do
      case Delegation.reset_project_ci_rail(full_name, args, state) do
        {:ok, result} -> {:ok, %{content: [json(result)]}, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error,
       {:invalid_full_name,
        "`full_name` must be an `owner/name` repo (got #{inspect(full_name)})"}, state}
    end
  end

  def handle_tool_call("project_reset_ci_rail", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("project_delete", %{"full_name" => full_name} = args, state)
      when is_binary(full_name) and full_name != "" do
    if valid_repo_ref?(full_name) do
      case Delegation.delete_project(full_name, args, state) do
        {:ok, result} -> {:ok, %{content: [json(result)]}, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error,
       {:invalid_full_name,
        "`full_name` must be an `owner/name` repo (got #{inspect(full_name)})"}, state}
    end
  end

  def handle_tool_call("project_delete", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("issue_status", %{"number" => number}, state)
      when is_integer(number) do
    case Delegation.issue_status(number, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("issue_status", _bad, state) do
    {:error, :invalid_arguments, state}
  end

  # Escalation inbox (architect gate inside Delegation, from the CHANNEL identity — never the wire).
  def handle_tool_call("scratch", %{"note" => note}, state) when is_binary(note) do
    case Delegation.scratch(state, note) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("scratch", _bad, state) do
    {:error, {:invalid_arguments, "scratch attend `note` (string non vide)"}, state}
  end

  def handle_tool_call("escalation_list", _arguments, state) do
    case Delegation.list_escalations(state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Project board + full-thread read (BL-6-28): the arch's READ half — architect gate inside
  # Delegation, repo from the channel binding (never the wire), like every delegation tool.
  def handle_tool_call("issue_list", _arguments, state) do
    case Delegation.list_issues(state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("issue_get", %{"number" => number}, state) when is_integer(number) do
    case Delegation.get_issue(number, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("issue_get", _bad, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("card_list", _arguments, state) do
    case Delegation.list_workflow_cards(state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("catalogue_list", _arguments, state) do
    case Delegation.list_catalogues(state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("issue_comment", %{"number" => number, "body" => body}, state)
      when is_integer(number) and is_binary(body) and body != "" do
    case Delegation.comment_issue(number, body, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("issue_comment", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  # Order between tickets, declared after creation (architect gate inside Delegation).
  def handle_tool_call("dependency_add", %{"number" => n, "blocker" => b}, state)
      when is_integer(n) and is_integer(b) do
    case Delegation.add_dependency(n, b, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, why} -> {:error, why, state}
    end
  end

  def handle_tool_call("dependency_add", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("dependency_remove", %{"number" => n, "blocker" => b}, state)
      when is_integer(n) and is_integer(b) do
    case Delegation.remove_dependency(n, b, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, why} -> {:error, why, state}
    end
  end

  def handle_tool_call("dependency_remove", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  # The brake (onboarder gate inside Delegation) — a mass CLOSE, never a kill.
  def handle_tool_call("emergency_stop", %{"reason" => reason}, state)
      when is_binary(reason) and reason != "" do
    case Delegation.emergency_stop(reason, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, why} -> {:error, why, state}
    end
  end

  def handle_tool_call("emergency_stop", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  # The READ half of the project surface (onboarder gate inside Delegation).
  def handle_tool_call("project_list", _arguments, state) do
    case Delegation.list_projects(state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Retirement without a replacement (architect gate inside Delegation, repo from the channel).
  def handle_tool_call("issue_retire", %{"number" => number, "reason" => reason}, state)
      when is_integer(number) and is_binary(reason) and reason != "" do
    case Delegation.retire_issue(number, reason, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("issue_retire", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call(_unknown, _arguments, state) do
    {:error, :unknown_tool, state}
  end

  # A forge repo ref is a gitea `owner/name` full-name (R2-03): exactly one `/`, both sides non-empty and
  # whitespace-free. A guardrail that rejects a manifestly-broken ref EARLY with a clear error (before the
  # forge call fails obscurely) — NOT the full gitea naming authority, same spirit as `Fleet.GitRef`.
  defp valid_repo_ref?(ref) when is_binary(ref) do
    case String.split(ref, "/") do
      [owner, name] -> owner != "" and name != "" and not String.match?(ref, ~r/\s/)
      _ -> false
    end
  end

  # Both absent → inline brief (fine). Both present and well-formed → pointer. Anything
  # else → refusal (cf. the create_issue handler). The ref/sha SHAPES come from the Layout truth.
  defp valid_brief_pointer_args?(args) do
    case {Map.get(args, "brief_ref"), Map.get(args, "brief_sha")} do
      {nil, nil} ->
        true

      {ref, sha} when is_binary(ref) and is_binary(sha) ->
        Fleet.Layout.valid_brief_ref?(ref) and Regex.match?(~r/\A[0-9a-f]{40}\z/, sha)

      _ ->
        false
    end
  end

  defp brief_pointer(args) do
    case {Map.get(args, "brief_ref"), Map.get(args, "brief_sha")} do
      {ref, sha} when is_binary(ref) and is_binary(sha) -> {ref, sha}
      _ -> nil
    end
  end
end
