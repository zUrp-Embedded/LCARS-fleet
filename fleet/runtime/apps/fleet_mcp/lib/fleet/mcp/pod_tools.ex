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
        "Délègue une tâche d'implémentation à la fleet LCARS : crée un ticket (issue forge) ET " <>
          "lance le pipeline de réalisation (engineer → gates → livré). Utilise-le pour DÉLÉGUER " <>
          "plutôt que de coder toi-même (la fleet livre mieux et préserve ton contexte). " <>
          "`brief` = le mandat clair pour l'engineer. Retourne {\"status\":\"delegated\",...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "brief" => %{"type" => "string"},
        "pipeline" => %{"type" => "string"}
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
          "`name` = slug kebab-case. Le projet créé devient la cible de délégation : enchaîne ensuite " <>
          "`create_ticket` pour l'implémentation. Retourne {\"status\":\"onboarded\",\"repo\":...}."
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

  # create_ticket (Rail 2 e2e 2026-06-14) — canal DÉLÉGATION : l'architecte délègue une
  # implémentation à la fleet. Crée l'issue forge (traçabilité) + lance le pipeline. Dispatch
  # runtime via modules-en-variable (pas de dep compile-time fleet_pilot/fleet_pipeline).
  def handle_tool_call("create_ticket", %{"title" => title, "brief" => brief} = args, state)
      when is_binary(title) and is_binary(brief) do
    repo = Application.get_env(:fleet_mcp, :delegation_repo, "fleet/fleet-test")

    pipeline =
      Map.get(args, "pipeline") ||
        Application.get_env(:fleet_mcp, :delegation_pipeline, "poc-helloworld")

    forge = Fleet.Pilot.ForgeClient
    pipe = Fleet.Pipeline

    # L'arch poste l'issue EN SON NOM : token du compte forge `Architect` (→ avatar, traça honnête).
    # Plus d'en-tête « Délégué par l'architecte » — l'arch EST l'auteur de l'issue ; le stamp textuel
    # était un proxy faute de token de rôle (raccourci PoC). Le `brief` est le corps tel quel.
    ticket_id =
      case apply(forge, :create_issue, [repo, title, brief, role_token_opts("architect")]) do
        {:ok, number} -> "#{repo}##{number}"
        _ -> "deleg-#{System.unique_integer([:positive])}"
      end

    case apply(pipe, :start_pipeline, [pipeline, %{ticket_id: ticket_id, ask: brief}]) do
      {:ok, pipeline_id} ->
        result = %{
          "status" => "delegated",
          "ticket" => ticket_id,
          "pipeline" => pipeline,
          "pipeline_id" => pipeline_id
        }

        {:ok, %{content: [json(result)]}, state}

      {:error, reason} ->
        {:error, {:delegation_failed, inspect(reason)}, state}
    end
  end

  def handle_tool_call("create_ticket", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  # create_project (Rail 1 e2e 2026-06-14) — canal ONBOARDING : l'architecte démarre un projet neuf.
  # Le SYSTÈME exécute la séquence mécanique (repo forge + dual-worktree main/work-ops + scaffold + push)
  # via Fleet.Pilot.ProjectOnboard, dispatch runtime (pas de dep compile-time fleet_pilot). Le projet créé
  # devient la cible de délégation courante (`:delegation_repo`) → le `create_ticket` suivant livre dedans
  # (mono-projet actif, KISS v1 ; le routage multi-projet = follow-up).
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

  def handle_tool_call(_unknown, _arguments, state) do
    {:error, :unknown_tool, state}
  end

  # Le pont stdio (`fleet-mcp-stdio-bridge`) injecte `_lcars_pod_id` dans tous les tool calls.
  defp pod_id(args) do
    case Map.get(args || %{}, "_lcars_pod_id") do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  # Token forge du compte de RÔLE (le rôle poste/commente EN SON NOM → avatar honnête). Lu de
  # `<role_tokens_dir>/<role>.token` (défaut `~/.lcars/role-tokens/`). `[]` si absent → `create_issue`
  # retombe sur le token système (dette à provisionner — pas un masquage, le rôle existe comme compte).
  defp role_token_opts(role) do
    dir =
      Application.get_env(:fleet_mcp, :role_tokens_dir) ||
        Path.join(System.user_home() || "/home/starfleet", ".lcars/role-tokens")

    case File.read(Path.join(dir, "#{role}.token")) do
      {:ok, content} ->
        case String.trim(content) do
          "" -> []
          token -> [token: token]
        end

      _ ->
        []
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
