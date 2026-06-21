defmodule Fleet.MCP.PodTools do
  @moduledoc """
  Couche TOOL MCP pod-facing (drive métier ADR-G) — les RPC que le pod (client MCP
  claude) appelle pour communiquer avec le fleet, sans scraping ni injection clavier :
    - `get_task`      : canal IN  — le pod PULL son mandat depuis `Fleet.TaskQueue`.
      `{"done": true}` quand aucun mandat (le pod s'arrête). Sinon
      `{"done": false, "task": {"task_id", "ticket_id", "role", "brief", ...}}`.
    - `submit_result` : canal OUT — le pod PUSH son livrable (`payload`).

  Médiation serveur-side (ADR-C III.2) : le pod ne touche jamais la TaskQueue
  directement ; tout passe par ces tools. Le serveur est **passeur de
  `correlation_id`** (DN `drive/mcp-server` §A) : `task_id` exposé côté `get_task`,
  validé côté `submit_result` (le broker rejette un `task_id` ≠ mandat actif).

  Le broker `Fleet.TaskQueue` broadcast lui-même `%Fleet.Event{task_completed}` sur
  `fleet.events` (consommé par `fleet_spawner`/`fleet_coord`) — ce module n'émet
  plus d'event string-topic (`pod.result_submitted` supprimé).
  """

  use ExMCP.Server

  require Logger

  alias Fleet.TaskQueue

  deftool "get_task" do
    meta do
      name("Get Task")

      description(
        "Récupère ta prochaine tâche auprès du fleet LCARS. Retourne " <>
          "{\"done\":true} quand il n'y a plus de tâche (tu t'arrêtes alors), " <>
          "sinon {\"done\":false,\"task\":{...}}."
      )
    end

    input_schema(%{"type" => "object", "properties" => %{}})
  end

  deftool "submit_result" do
    meta do
      name("Submit Result")
      description("Retourne le résultat structuré d'une tâche au fleet LCARS, dans `payload`.")
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{"payload" => %{"type" => "object"}},
      "required" => ["payload"]
    })
  end

  deftool "create_ticket" do
    meta do
      name("Create Ticket")

      description(
        "Délègue une brique d'implémentation à la fleet LCARS : crée un ticket (issue forge) prêt " <>
          "pour la livraison forge-native (engineer → PR → review → merge). Utilise-le pour DÉLÉGUER " <>
          "plutôt que de coder toi-même (la fleet livre mieux et préserve ton contexte). " <>
          "`brief` = le mandat clair pour l'engineer. `project` (optionnel) = le repo `owner/name` SUR " <>
          "lequel délivrer — passe-le quand l'humain désigne un projet (ex. celui que `create_project` " <>
          "vient de retourner). Omis → le dernier projet sur lequel l'humain a travaillé. " <>
          "Retourne {\"status\":\"ticket_created\",...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "brief" => %{"type" => "string"},
        "project" => %{"type" => "string"}
      },
      "required" => ["title", "brief"]
    })
  end

  deftool "create_project" do
    meta do
      name("Create Project")

      description(
        "Démarre un NOUVEAU projet : crée le repo sur la forge + les 2 dossiers dual-dir " <>
          "(`/home/projects/<name>` sur `main`, `/home/projects.work/<name>` sur `work/ops`) + " <>
          "le scaffold de base, et le pousse. Utilise-le quand l'humain veut LANCER un projet neuf. " <>
          "`name` = slug kebab-case. Retourne {\"status\":\"onboarded\",\"repo\":...} ; enchaîne ensuite " <>
          "`create_ticket` en lui passant `project: <le repo retourné>` pour livrer DANS ce projet."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "pitch" => %{"type" => "string"},
        "description" => %{"type" => "string"}
      },
      "required" => ["name"]
    })
  end

  deftool "get_ticket_status" do
    meta do
      name("Get Ticket Status")

      description(
        "Consulte l'état d'un ticket délégué (issue + PR liée) du projet de délégation courant : " <>
          "issue ouverte/fermée, PR mergée ou non, verdicts de review. Utilise-le pour SUIVRE un " <>
          "ticket avant d'enchaîner — ex. valider la livraison (issue fermée par le merge) du ticket N " <>
          "AVANT de poster le ticket N+1. `number` = le numéro d'issue. " <>
          "Retourne {\"delivered\":bool,\"issue_state\":...,\"pr\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{"number" => %{"type" => "integer"}},
      "required" => ["number"]
    })
  end

  @impl true
  def handle_tool_call("get_task", arguments, state) do
    case pod_id(arguments) do
      nil ->
        # F045 : pod_id absent = erreur de config (LCARS_POD_ID perdu), PAS une fin de mandat.
        # Symétrique avec submit_result. Ne jamais masquer en {"done": true} — sinon le pod
        # s'arrête en croyant avoir tout fini alors qu'il n'a jamais pu s'identifier.
        {:error, :pod_id_required, state}

      pid ->
        result =
          case TaskQueue.get_for_pod(pid) do
            {:ok, task} -> %{"done" => false, "task" => envelope(task)}
            {:error, :no_task} -> %{"done" => true}
          end

        {:ok, %{content: [json(result)]}, state}
    end
  end

  def handle_tool_call("submit_result", %{"payload" => payload} = args, state)
      when is_map(payload) do
    case pod_id(args) do
      nil ->
        {:error, :pod_id_required, state}

      pid ->
        # Le broker valide pod_id ↔ task_id (si présent) et broadcast %Fleet.Event{task_completed}.
        case TaskQueue.submit_result(pid, payload) do
          {:ok, _task} ->
            {:ok, %{content: [text("Resultat recu par le fleet. Tache close.")]}, state}

          {:error, :no_active_task} ->
            # F046 : pas de mandat actif = le livrable n'a NULLE PART où aller (jamais assigné, ou clos/
            # réassigné depuis) → DROP. Le signaler isError (comme :task_id_mismatch / :pod_id_required F045)
            # plutôt que masquer en {:ok "ok"} : sinon le pod croit son livrable accepté (classe F045).
            # (≠ :double_submit_ignored, qui reste :ok — idempotent, le 1er submit EST déjà enregistré.)
            {:error, :no_active_task, state}

          {:error, :double_submit_ignored} ->
            {:ok, %{content: [text("Resultat deja recu (ignore).")]}, state}

          {:error, :task_id_mismatch} ->
            {:error, :task_id_mismatch, state}
        end
    end
  end

  def handle_tool_call("submit_result", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  # create_ticket — canal DÉLÉGATION : l'architecte délègue une brique d'implémentation à la fleet.
  # Modèle forge-state-machine (BL-050) : pose une issue PRÊTE pour le poller — auteur=arch (traça),
  # **assignee=humain owner** (point fixe DN §1) — et S'ARRÊTE. Plus de `start_pipeline` (rail RAM
  # retiré). Le POLLER prend le relais : issue assignée non verrouillée → spawn le rôle PRODUCTEUR
  # (`:producer_role`, invariant DN §1 — pas de marqueur par-ticket : un label `lcars-stage:` ré-
  # encoderait une constante). Dispatch runtime via modules-en-variable (pas de dep compile-time pilot).
  def handle_tool_call("create_ticket", %{"title" => title, "brief" => brief} = args, state)
      when is_binary(title) and is_binary(brief) do
    forge = Application.get_env(:fleet_mcp, :forge_client, Fleet.Pilot.ForgeClient)
    repo = resolve_target_repo(args, forge)

    # L'arch poste l'issue EN SON NOM : token du compte de rôle de l'APPELANT — résolu depuis
    # `_lcars_role` (injecté par le pont MCP, = le `metadata.name` du cap-profile appelant). Agnostique :
    # JAMAIS un rôle hardcodé. nil/introuvable → fallback token système (loggué — dégradé, pas masquage).
    # Pas d'en-tête « Délégué par l'architecte » : l'arch EST l'auteur de l'issue (→ avatar, traça vraie).
    role = Map.get(args, "_lcars_role")

    author_opts =
      case Fleet.Credentials.RoleToken.token(role) do
        t when is_binary(t) ->
          [token: t]

        _ ->
          Logger.warning(
            "create_ticket: token de rôle introuvable pour #{inspect(role)} — issue postée par le compte système"
          )

          []
      end

    # assignee = l'HUMAIN owner (point fixe DN §1 : routing + ownership, jamais le rôle). Login forge
    # = login OS de l'humain qui lance la fleet (doctrine : tout dérive de l'OS, pas de catalogue ;
    # Gitea matche l'assignee insensible à la casse → `starfleet` résout `Starfleet`). Pas de label :
    # le rôle producteur est un invariant côté poller, pas un sticker par-ticket.
    case Fleet.Credentials.Human.current() do
      {:ok, human} ->
        issue_opts = Keyword.put(author_opts, :assignees, [human])

        case apply(forge, :create_issue, [repo, title, brief, issue_opts]) do
          {:ok, number} ->
            # #5.2 D2 — DÉCOUPLAGE : create_ticket CRÉE seulement (auteur=arch, assignee=humain). Le ROUTAGE
            # (graver la carte) n'est PLUS ici : c'est la responsabilité du SYSTÈME — le POLLER grave la carte
            # par défaut (mandate-gate) sur toute issue assignée routeless (cf. fleet_pilot). Un seul acteur
            # crée+assigne ; le système route. (Uniforme : un ticket humain routeless est onboardé pareil.)
            # type:feature = ÉTIQUETTE de visu (humain), best-effort — JAMAIS du routing.
            _ = apply(forge, :add_label, [repo, number, "type:feature", []])

            result = %{
              "status" => "ticket_created",
              "ticket" => "#{repo}##{number}",
              "repo" => repo,
              "assignee" => human
            }

            {:ok, %{content: [json(result)]}, state}

          {:error, reason} ->
            {:error, {:ticket_creation_failed, inspect(reason)}, state}
        end

      {:error, reason} ->
        {:error, {:human_unresolved, inspect(reason)}, state}
    end
  end

  def handle_tool_call("create_ticket", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  # create_project (Rail 1 e2e 2026-06-14) — canal ONBOARDING : l'architecte démarre un projet neuf.
  # Le SYSTÈME exécute la séquence mécanique (repo forge + dual-worktree main/work-ops + scaffold + push)
  # via Fleet.Pilot.ProjectOnboard, dispatch runtime (pas de dep compile-time fleet_pilot). Le projet créé
  # est posé comme `:delegation_repo` = **contexte/fallback** (lu par get_ticket_status + ultime recours de
  # create_ticket) — PLUS le défaut primaire de create_ticket (devenu `last_worked_repo`, F-037). L'arch
  # référence le projet en passant `project:` explicite (cf. description du tool).
  def handle_tool_call("create_project", %{"name" => name} = args, state) when is_binary(name) do
    onboard = Fleet.Pilot.ProjectOnboard
    org = Application.get_env(:fleet_mcp, :delegation_org, "fleet")
    pitch = Map.get(args, "pitch") || Map.get(args, "description", "")

    opts = [org: org, description: Map.get(args, "description", pitch), pitch: pitch]

    case apply(onboard, :onboard, [name, opts]) do
      {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir}} ->
        Application.put_env(:fleet_mcp, :delegation_repo, repo)

        result = %{
          "status" => "onboarded",
          "repo" => repo,
          "project_dir" => pdir,
          "work_dir" => wdir,
          "delegation_target" => repo
        }

        {:ok, %{content: [json(result)]}, state}

      {:error, reason} ->
        {:error, {:onboard_failed, inspect(reason)}, state}
    end
  end

  def handle_tool_call("create_project", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  # get_ticket_status — canal SUIVI (architecte). Lit l'état d'un ticket délégué pour séquencer le
  # multi-ticket. « Livré » = issue fermée par le merge (`Closes #N`). Lecture seule (ForgeClient).
  def handle_tool_call("get_ticket_status", %{"number" => number}, state)
      when is_integer(number) do
    repo = Application.get_env(:fleet_mcp, :delegation_repo, "fleet/fleet-test")
    forge = Application.get_env(:fleet_mcp, :forge_client, Fleet.Pilot.ForgeClient)

    issue_state =
      case forge.get_issue(repo, number, []) do
        {:ok, issue} -> Map.get(issue, "state", "unknown")
        _ -> "unknown"
      end

    result = %{
      "repo" => repo,
      "issue" => number,
      "issue_state" => issue_state,
      # « livré » = la PR a fermé l'issue (merge FF `Closes #N`). Signal de séquencement multi-ticket :
      # l'arch n'enchaîne le ticket N+1 que sur `delivered: true`.
      "delivered" => issue_state == "closed",
      "pr" => ticket_pr_status(forge, repo, number)
    }

    {:ok, %{content: [json(result)]}, state}
  end

  def handle_tool_call("get_ticket_status", _bad, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call(_unknown, _arguments, state) do
    {:error, :unknown_tool, state}
  end

  # #5.2 D2 — `delegation_carte` + `grave_initial_route` RETIRÉS : le routage (graver la carte) a migré
  # côté système (fleet_pilot : le poller onboarde toute issue assignée routeless sur la carte par défaut,
  # cf. StageDispatcher.ensure_carte_or_onboard). create_ticket ne fait plus QUE créer+assigner.

  # La PR EN COURS du ticket #n (parmi les open). Livré (mergé) → la PR n'est plus open → `nil`
  # (l'info « livré » vient alors de l'issue close). Sinon : numéro + merged + verdicts de review.
  # F-037 producteur — repo cible de `create_ticket`, par priorité :
  #   1. `args["project"]` EXPLICITE (l'arch désigne le repo — ex. celui que `create_project` vient de
  #      retourner, ou « fais X sur projet A »). Cas user-facing : l'arch voit tous les projets.
  #   2. sinon le DERNIER projet TRAVAILLÉ par l'humain, scopé aux repos où il est COLLABORATEUR
  #      (`forge.last_worked_repo`) — et NON « le dernier créé » (un global qui traîne = mauvais défaut).
  #   3. ultime fallback `:delegation_repo` (projet courant posé par create_project ; sinon config) — fleet
  #      neuve / forge down / humain irrésoluble.
  defp resolve_target_repo(args, forge) do
    fallback = fn -> Application.get_env(:fleet_mcp, :delegation_repo, "fleet/fleet-test") end

    case args["project"] do
      p when is_binary(p) and p != "" ->
        p

      _ ->
        with {:ok, human} <- Fleet.Credentials.Human.current(),
             {:ok, repo} <- forge.last_worked_repo(human, []) do
          repo
        else
          _ -> fallback.()
        end
    end
  end

  defp ticket_pr_status(forge, repo, number) do
    # Feature-branch du ticket = `lcars/issue-<n>-<role>` ; le `-` final distingue #1 de #12. Match
    # inline (pas de call cross-app vers fleet_pilot : fleet_mcp dispatch le forge en runtime).
    prefix = "lcars/issue-#{number}-"

    case forge.list_open_pulls(repo, []) do
      {:ok, pulls} ->
        Enum.find_value(pulls, fn pr ->
          head = get_in(pr, ["head", "ref"]) || ""

          if String.starts_with?(head, prefix) do
            verdicts =
              case forge.pr_review_verdicts(repo, pr["number"],
                     head_sha: get_in(pr, ["head", "sha"])
                   ) do
                {:ok, v} -> v
                _ -> %{}
              end

            %{"number" => pr["number"], "merged" => pr["merged"], "verdicts" => verdicts}
          end
        end)

      _ ->
        nil
    end
  end

  # Le pont stdio (`fleet-mcp-stdio-bridge`) injecte `_lcars_pod_id` dans tous les tool calls.
  defp pod_id(args) do
    case Map.get(args || %{}, "_lcars_pod_id") do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  # JSON envelope du mandat exposé au pod (DN drive/mcp-server §A) — task_id = correlation_id.
  defp envelope(%Fleet.TaskQueue.Task{} = t) do
    %{
      "task_id" => t.id,
      "ticket_id" => t.ticket_id,
      "role" => t.role,
      "brief" => t.brief,
      "deadline" => iso(t.deadline),
      "retry_count" => t.retry_count
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
