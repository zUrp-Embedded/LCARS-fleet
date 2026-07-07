defmodule Fleet.MCP.PodTools do
  @moduledoc """
  Couche TOOL MCP pod-facing — les RPC que le pod (client MCP claude) appelle pour
  communiquer avec le fleet, sans scraping ni injection clavier. CE module est la
  **table de routage** : les schémas `deftool` + le dispatch `handle_tool_call/3`
  (guards d'arguments, refus typés, format de contenu MCP `json`/`text`). Les métiers
  vivent dans deux sous-modules aux consommateurs disjoints :

    * `Fleet.MCP.PodTools.WorkItems` — drive work-item (tout pod) :
      - `get_work_item`  : canal IN  — le pod PULL son brief depuis `Fleet.TaskQueue`.
        `{"done": true}` quand aucun brief (le pod s'arrête). Sinon
        `{"done": false, "work_item": {"work_item_id", "issue_id", "role", "brief", ...}}`.
      - `submit_result` : canal OUT — le pod PUSH son livrable (`payload`),
        `work_item_id` OBLIGATOIRE (corrélateur).
    * `Fleet.MCP.PodTools.Delegation` — délégation forge (architecte only, gate
      `require_architect` serveur-side) :
      - `create_issue`     : l'arch délègue une brique d'implémentation (issue forge).
      - `create_project`   : l'arch démarre un projet neuf (repo + dual-dir + scaffold).
      - `get_issue_status` : l'arch suit une délégation (issue + PR, `delivered`).

  Médiation serveur-side : le pod ne touche jamais la TaskQueue ni la forge directement
  (la queue, son schéma, son stockage restent invisibles au pod) ; tout passe par ces
  tools. L'identité (quel pod) est le CANAL : `state.pod_id` est porté par l'accepteur
  de socket (un pod = une socket), jamais lu du wire — les clauses ici vérifient sa
  présence (`:pod_id_required` fail-closed), la gate architecte vit dans `Delegation`.

  Le broker `Fleet.TaskQueue` broadcast lui-même `%Fleet.Event{work_item.completed}` sur
  `fleet.events` (consommé par `fleet_spawner`/`fleet_coord`) — ce module n'émet
  plus d'event string-topic (`pod.result_submitted` supprimé).
  """

  use ExMCP.Server

  alias Fleet.MCP.PodTools.Delegation
  alias Fleet.MCP.PodTools.WorkItems

  deftool "get_work_item" do
    meta do
      name("Get Work Item")

      description(
        "Récupère ta prochaine tâche auprès du fleet LCARS. Retourne " <>
          "{\"done\":true} quand il n'y a plus de tâche (tu t'arrêtes alors), " <>
          "sinon {\"done\":false,\"work_item\":{...}}."
      )
    end

    input_schema(%{"type" => "object", "properties" => %{}})
  end

  deftool "submit_result" do
    meta do
      name("Submit Result")

      description(
        "Retourne le résultat structuré d'une tâche au fleet LCARS, dans `payload`. `work_item_id` REQUIS = " <>
          "le `work_item_id` rendu par `get_work_item` (la tâche que tu clôs) : le fleet corrèle ton livrable à CETTE " <>
          "tâche précise, jamais à « la dernière en date »."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "payload" => %{"type" => "object"},
        "work_item_id" => %{"type" => "string"}
      },
      "required" => ["payload", "work_item_id"]
    })
  end

  deftool "create_issue" do
    meta do
      name("Create Issue")

      description(
        "Délègue une brique d'implémentation à la fleet LCARS : crée une issue forge prête " <>
          "pour la livraison forge-native (engineer → PR → review → merge). Utilise-le pour DÉLÉGUER " <>
          "plutôt que de coder toi-même (la fleet livre mieux et préserve ton contexte). " <>
          "`brief` = le brief clair pour l'engineer. `project` = le repo `owner/name` OÙ LIVRER, **REQUIS** : " <>
          "le repo retourné par `create_project`, ou le projet désigné par l'humain. La fleet ne route PLUS par " <>
          "défaut — sans `project`, le issue est REFUSÉ (jamais de misroute silencieux vers un autre projet). " <>
          "Retourne {\"status\":\"issue_created\",\"repo\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "brief" => %{"type" => "string"},
        "project" => %{"type" => "string"}
      },
      "required" => ["title", "brief", "project"]
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
          "`create_issue` en lui passant `project: <le repo retourné>` pour livrer DANS ce projet."
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

  deftool "import_project" do
    meta do
      name("Import Project")

      description(
        "Importe un repo EXISTANT (déjà sur la forge, dans l'org — poussé hors-fleet ou par un humain) " <>
          "dans la machine à agents : dual-dir (`/home/projects/<name>` sur `main`, " <>
          "`/home/projects.work/<name>` sur `work/ops`) + gate forge-enforcé, SANS toucher au contenu " <>
          "de `main` (il reste intact). Utilise-le pour un projet qui existe déjà (≠ create_project, qui " <>
          "démarre un projet NEUF). `full_name` = `owner/name` (ex. `fleet/deja-la`) — doit déjà être dans " <>
          "l'org fleet, branche par défaut `main`. Retourne {\"status\":\"imported\",\"repo\":...}."
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

  deftool "get_issue_status" do
    meta do
      name("Get Issue Status")

      description(
        "Consulte l'état d'un issue délégué (issue + PR liée) : issue ouverte/fermée, PR mergée " <>
          "ou non, verdicts de review. Utilise-le pour SUIVRE un issue avant d'enchaîner — ex. valider " <>
          "la livraison (issue fermée par le merge) du issue N AVANT de poster le issue N+1. " <>
          "`number` = le numéro d'issue. `project` = le repo `owner/name` DU issue, **REQUIS** : le repo " <>
          "retourné par `create_project` (ou celui passé à `create_issue`). La fleet ne route PLUS par " <>
          "défaut — sans `project`, la lecture est REFUSÉE (jamais d'état lu sur le mauvais projet). " <>
          "Retourne {\"delivered\":bool,\"issue_state\":...,\"pr\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "number" => %{"type" => "integer"},
        "project" => %{"type" => "string"}
      },
      "required" => ["number", "project"]
    })
  end

  # ============================================================
  # Dispatch — drive work-item (Fleet.MCP.PodTools.WorkItems)
  # ============================================================

  @impl true
  def handle_tool_call("get_work_item", _arguments, %{pod_id: pod_id} = state)
      when is_binary(pod_id) and pod_id != "" do
    # Identité = le canal : `pod_id` vient de l'accepteur de socket (un pod = une socket), jamais du wire.
    # On ne lit donc PAS d'identité dans les arguments — il n'y a rien à prouver, la socket discrimine.
    {:ok, %{content: [json(WorkItems.get_work_item(pod_id))]}, state}
  end

  def handle_tool_call("get_work_item", _arguments, state) do
    # `pod_id` absent du state = anomalie de l'accepteur (il DOIT toujours le porter). Erreur typée, pas une
    # fin de brief masquée en done:true (sinon le pod s'arrêterait en croyant avoir fini). Fail-closed.
    {:error, :pod_id_required, state}
  end

  def handle_tool_call("submit_result", %{"payload" => payload} = args, %{pod_id: pod_id} = state)
      when is_map(payload) and is_binary(pod_id) and pod_id != "" do
    # Identité = le canal (`state.pod_id`, porté par l'accepteur). Le contrat de corrélation
    # (`work_item_id` OBLIGATOIRE, cherché top-level puis payload) et le mapping des refus typés
    # (:no_active_work_item, :work_item_id_mismatch, :broadcast_failed — jamais un échec masqué en
    # succès) vivent dans `WorkItems.submit_result/3`.
    case WorkItems.submit_result(pod_id, args, payload) do
      {:ok, message} -> {:ok, %{content: [text(message)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("submit_result", %{"payload" => payload}, state) when is_map(payload) do
    # Payload valide mais `pod_id` absent du state = anomalie de l'accepteur → refus typé, jamais de
    # fallback anonyme (un livrable sans pod identifié n'a nulle part où aller).
    {:error, :pod_id_required, state}
  end

  def handle_tool_call("submit_result", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  # ============================================================
  # Dispatch — délégation forge architecte (Fleet.MCP.PodTools.Delegation)
  # ============================================================

  # La gate architecte (require_architect : rôle résolu du canal, jamais du wire) est appliquée
  # DANS Delegation, avant toute mécanique forge. Ici : guards de forme des arguments + refus
  # structurels `project` REQUIS (pas de routage par défaut).

  def handle_tool_call(
        "create_issue",
        %{"title" => title, "brief" => brief, "project" => repo},
        state
      )
      when is_binary(title) and is_binary(brief) and is_binary(repo) and repo != "" do
    case Delegation.create_issue(repo, title, brief, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # create_issue SANS `project` valide → REFUS STRUCTUREL. La bonne volonté ne s'impose pas : pas de routage
  # par défaut (un `project` omis routait en silence vers le dernier projet travaillé → misroute). `project`
  # est REQUIS ; sans lui, AUCUN issue n'est créé.
  def handle_tool_call("create_issue", %{"title" => title, "brief" => brief}, state)
      when is_binary(title) and is_binary(brief) do
    {:error,
     {:project_required,
      "create_issue REFUSÉ — `project` est REQUIS (le repo `owner/name` où livrer). Aucun routage par " <>
        "défaut. Passe `project` = le repo retourné par create_project, ou le projet désigné par l'humain."},
     state}
  end

  def handle_tool_call("create_issue", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("create_project", %{"name" => name} = args, state) when is_binary(name) do
    case Delegation.create_project(name, args, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("create_project", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("import_project", %{"full_name" => full_name}, state)
      when is_binary(full_name) and full_name != "" do
    case Delegation.import_project(full_name, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("import_project", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call(
        "get_issue_status",
        %{"number" => number, "project" => repo},
        state
      )
      when is_integer(number) and is_binary(repo) and repo != "" do
    case Delegation.issue_status(repo, number, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # get_issue_status SANS `project` valide → REFUS STRUCTUREL (miroir de create_issue). Pas de routage
  # par défaut : un `project` omis lirait l'état sur le dernier projet onboardé → état faux, le multi-issue
  # est mis-séquencé. `project` est REQUIS ; sans lui (ou vide), AUCUNE lecture.
  def handle_tool_call("get_issue_status", %{"number" => number}, state)
      when is_integer(number) do
    {:error,
     {:project_required,
      "get_issue_status REFUSÉ — `project` est REQUIS (le repo `owner/name` du issue). Aucun routage " <>
        "par défaut. Passe `project` = le repo retourné par create_project, ou celui passé à create_issue."},
     state}
  end

  def handle_tool_call("get_issue_status", _bad, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call(_unknown, _arguments, state) do
    {:error, :unknown_tool, state}
  end
end
